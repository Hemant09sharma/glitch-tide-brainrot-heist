--!strict
-- MutationService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Mutations: spend Mutation Crystals to apply a mutation to an owned
-- Brainrot instance. All validation is server-side (ownership, crystal
-- balance, rebirth-gated tiers); the client only ever sends ids.
--
-- MUTATION DATA SOURCE: the shared `Mutations` module in
-- ReplicatedStorage is loaded when present (see loadMutationTable);
-- the local table below is only the fallback when it is absent, and it
-- is an exact copy of the shared 12 (same costs, multipliers, rebirth
-- gates). Mutation ids are keyed lowercase here ("golden"); the shared
-- module defines them capitalised ("Golden") — lookups normalise case.
-- Compatibility is enforced: a character can only take a mutation
-- listed in its MutationCompatibility (Characters.luau).
--
-- OWNED-INSTANCE MODEL: DataService only stores `Unlocked` (a set of
-- character ids, no duplicates, no levels). Mutation / fusion need real
-- instances, so this service keeps `data.OwnedInstances`:
--   { InstanceId, CharacterId, Level, Mutation (string?), Placed, Slot }
-- seeded lazily from data.Unlocked (one level-1 instance per unlocked
-- id). BaseService owns `data.Base.Placed`; this service only mirrors the
-- Placed flag via SetPlaced() so the two never fight over the same table.
--
-- REMOTE: MutateBrainrot exists in Remotes.Names (RemoteEvent), so the
-- handler binds to it directly (UpgradeBrainrot is only the fallback
-- if the name ever disappears). Visual updates come from BaseService's
-- RebuildBase full BaseUpdate snapshot (R3-7: the old partial
-- {Action = "MutationApplied"} push through the same remote was
-- deleted — no client handler ever read it, and it overwrote the
-- full snapshot in BaseController.ApplyBaseUpdate).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local MutationService = {}

local _dataService: any = nil
local _questService: any = nil
local _eventService: any = nil
-- Optional: BaseService (SetBaseService). Only used to rebuild the
-- placed models after a placed copy's Mutation is synced below;
-- GameManager's cross-link pass calls the setter automatically. The
-- data-level sync works without it.

-- Local mutation table (used ONLY when no shared Mutations module
-- exists). v1.0.1 QA: this used to be a DIFFERENT 8-entry table with
-- wrong costs/multipliers (Golden 10 crystals / 1.5x here vs 50 / 2.5x
-- in the shared module) plus two phantom mutations, Magma and Spectral,
-- that exist nowhere else — a player could buy "Magma" here and get a
-- 1x multiplier and no visuals anywhere else in the game. It is now an
-- exact copy of the shared 12 (same costs, multipliers, rebirth
-- gates), so the fallback and the shared module can never disagree.
local MUTATIONS: { [string]: { Name: string, Crystals: number, IncomeMult: number, MinRebirths: number } } = {
	golden = { Name = "Golden", Crystals = 50, IncomeMult = 2.5, MinRebirths = 0 },
	diamond = { Name = "Diamond", Crystals = 120, IncomeMult = 4, MinRebirths = 0 },
	rainbow = { Name = "Rainbow", Crystals = 200, IncomeMult = 5, MinRebirths = 2 },
	electric = { Name = "Electric", Crystals = 40, IncomeMult = 2, MinRebirths = 0 },
	frozen = { Name = "Frozen", Crystals = 40, IncomeMult = 1.8, MinRebirths = 0 },
	toxic = { Name = "Toxic", Crystals = 60, IncomeMult = 2.2, MinRebirths = 0 },
	shadow = { Name = "Shadow", Crystals = 100, IncomeMult = 3, MinRebirths = 0 },
	glitched = { Name = "Glitched", Crystals = 150, IncomeMult = 3.5, MinRebirths = 0 },
	cosmic = { Name = "Cosmic", Crystals = 180, IncomeMult = 4.5, MinRebirths = 0 },
	ancient = { Name = "Ancient", Crystals = 120, IncomeMult = 3, MinRebirths = 0 },
	void = { Name = "Void", Crystals = 300, IncomeMult = 6, MinRebirths = 1 },
	celestial = { Name = "Celestial", Crystals = 500, IncomeMult = 8, MinRebirths = 1 },
}

local _mutationSource: string = "local"
local _sharedMutations: any = nil
local _rate: { [Player]: number } = {}

local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function rateOk(player: Player, key: string, interval: number): boolean
	if Security and Security.RateLimit then
		local ok, allowed = pcall(function()
			return Security.RateLimit(player, key, interval)
		end)
		if ok then
			return allowed
		end
	end
	local now = os.clock()
	local last = _rate[player] or -math.huge
	if now - last < interval then
		return false
	end
	_rate[player] = now
	return true
end

local function sanitize(id: any): string?
	if Security and Security.SanitizeId then
		local ok, clean = pcall(function()
			return Security.SanitizeId(id)
		end)
		if ok then
			return clean
		end
	end
	if type(id) ~= "string" or #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
end

local function getRemote(name: string): RemoteEvent?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

local function getData(player: Player): any
	if not _dataService then
		return nil
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

-- Load the shared Mutations module when it exists; otherwise keep local.
local function loadMutationTable()
	local mod = ReplicatedStorage:FindFirstChild("Mutations")
	if mod and mod:IsA("ModuleScript") then
		local ok, shared = pcall(function()
			return require(mod)
		end)
		if ok and type(shared) == "table" then
			_sharedMutations = shared
			local list: any = nil
			if type(shared.GetAll) == "function" then
				local ok2, result = pcall(function()
					return shared.GetAll()
				end)
				if ok2 then
					list = result
				end
			elseif type(shared.List) == "table" then
				list = shared.List
			elseif type(shared.Mutations) == "table" then
				list = shared.Mutations
			end
			if type(list) == "table" then
				local loaded: { [string]: any } = {}
				local count = 0
				for _, entry in pairs(list) do
					if type(entry) == "table" and type(entry.Id) == "string" then
						-- Shared Mutations use capitalised Ids ("Golden") and
						-- IncomeMultiplier; this service keys mutations
						-- lowercase ("golden") with IncomeMult. Normalise
						-- both here, or every shared mutation would load
						-- with a 1x income multiplier and an unfindable id.
						-- Rebirth gating comes from the shared def's
						-- MinRebirths field (v1.0.1: no hardcoded
						-- per-mutation special cases here).
						local key = string.lower(entry.Id)
						loaded[key] = {
							Name = entry.Name or entry.Id,
							Crystals = tonumber(entry.Crystals) or tonumber(entry.Cost) or 5,
							IncomeMult = tonumber(entry.IncomeMultiplier) or tonumber(entry.IncomeMult) or 1,
							MinRebirths = tonumber(entry.MinRebirths) or 0,
						}
						count += 1
					end
				end
				if count > 0 then
					MUTATIONS = loaded
					_mutationSource = "ReplicatedStorage.Mutations"
					print("[MutationService] Loaded " .. tostring(count) .. " mutations from shared module")
					return
				end
			end
		end
	end
	_mutationSource = "local"
end

function MutationService.GetMutationSource(): string
	return _mutationSource
end

function MutationService.GetAllMutations(): { [string]: any }
	local copy: { [string]: any } = {}
	for id, def in pairs(MUTATIONS) do
		copy[id] = {
			Name = def.Name,
			Crystals = def.Crystals,
			IncomeMult = def.IncomeMult,
			MinRebirths = def.MinRebirths,
		}
	end
	return copy
end

function MutationService.GetMutationCostMultiplier(): number
	-- Halved during a Mutation Storm (EventService hook, when linked).
	if _eventService and type(_eventService.GetMutationCostMultiplier) == "function" then
		local ok, mult = pcall(function()
			return _eventService.GetMutationCostMultiplier()
		end)
		if ok and type(mult) == "number" and mult > 0 then
			return mult
		end
	end
	return 1
end

-- SetBaseService(baseService): optional link used ONLY to rebuild the
-- placed models after MutateBrainrot syncs a placed copy's Mutation
-- (R2-1). GameManager's cross-link pass calls this setter
-- automatically when BaseService is loaded; without it the data-level
-- sync still happens and the next RebuildBase / re-place picks it up.
function MutationService.SetBaseService(baseService: any)
	if baseService and type(baseService.RebuildBase) == "function" then
		_baseService = baseService
	end
end

-- ---------------------------------------------------------------------------
-- Owned-instance registry (shared with FusionService).
-- ---------------------------------------------------------------------------

-- ensureInstances(player): seed data.OwnedInstances from data.Unlocked
-- when missing, and return the live list.
function MutationService.GetInstances(player: Player): { any }
	local data = getData(player)
	if not data then
		return {}
	end
	if type(data.OwnedInstances) ~= "table" then
		data.OwnedInstances = {}
		local unlocked = data.Unlocked
		if type(unlocked) == "table" then
			for index, characterId in ipairs(unlocked) do
				if type(characterId) == "string" and Characters.GetById(characterId) then
					table.insert(data.OwnedInstances, {
						InstanceId = "inst_" .. tostring(player.UserId) .. "_" .. characterId .. "_" .. tostring(index),
						CharacterId = characterId,
						Level = 1,
						Mutation = nil,
						Placed = false,
						Slot = 0,
					})
				end
			end
		end
		-- Mirror any BaseService-placed entries onto the matching instance.
		-- Placed lives in data.Base.Placed; data.Placed is the fallback.
		local placedLists: { { any } } = {}
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			table.insert(placedLists, data.Base.Placed)
		end
		if type(data.Placed) == "table" then
			table.insert(placedLists, data.Placed)
		end
		for _, list in ipairs(placedLists) do
			for _, placed in ipairs(list) do
				if type(placed) == "table" and type(placed.InstanceId) == "string" then
					-- Match by InstanceId, not CharacterId: two
					-- instances of the same character are distinct,
					-- and matching the first unplaced one could flag
					-- the wrong instance as placed.
					for _, inst in ipairs(data.OwnedInstances) do
						if inst.InstanceId == placed.InstanceId then
							inst.Placed = true
							inst.Slot = tonumber(placed.Slot) or 0
							inst.Level = tonumber(placed.Level) or inst.Level
							-- A glitched placed Brainrot sets the
							-- Glitched flag — it must NEVER overwrite
							-- inst.Mutation with "glitched": that
							-- would destroy a real mutation (e.g.
							-- "golden") the instance already has.
							if placed.Glitched == true then
								inst.Glitched = true
							end
							-- R3-8: a legacy placed copy can carry a
							-- Mutation the freshly seeded owned record
							-- lacks (pre-R2-1 placed copies were never
							-- synced from the owned record). Mirror it
							-- onto the seed — the owned record is
							-- authoritative for steal snapshots and
							-- the "already has" check, so it must agree
							-- with what the base displays and pays.
							-- Only the seed is healed: a live owned
							-- record is never overwritten from placed
							-- (R2-1: owned wins).
							if inst.Mutation == nil and type(placed.Mutation) == "string" then
								inst.Mutation = placed.Mutation
							end
							break
						end
					end
				end
			end
		end
	end
	return data.OwnedInstances
end

function MutationService.FindInstance(player: Player, instanceId: string): any
	if type(instanceId) ~= "string" then
		return nil
	end
	for _, inst in ipairs(MutationService.GetInstances(player)) do
		if inst.InstanceId == instanceId then
			return inst
		end
	end
	return nil
end

function MutationService.CreateInstance(player: Player, characterId: string, level: number?, mutation: string?): any
	if not Characters.GetById(characterId) then
		return nil
	end
	-- Validate the mutation before it is stored: unknown ids and
	-- mutations the character cannot take (per its
	-- MutationCompatibility list) are dropped, never stored — a stored
	-- invalid mutation would pay 1x income and render no visuals.
	local cleanMutation: string? = nil
	if type(mutation) == "string" and mutation ~= "" then
		local key = string.lower(mutation)
		if MUTATIONS[key] ~= nil and MutationService.CanMutate(characterId, key) then
			cleanMutation = key
		else
			warn("[MutationService] CreateInstance dropped invalid mutation "
				.. tostring(mutation) .. " for " .. characterId)
		end
	end
	local instances = MutationService.GetInstances(player)
	local instance = {
		InstanceId = "inst_" .. tostring(player.UserId) .. "_" .. characterId .. "_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. tostring(#instances + 1),
		CharacterId = characterId,
		Level = math.clamp(math.floor(tonumber(level) or 1), 1, 5),
		Mutation = cleanMutation,
		Placed = false,
		Slot = 0,
	}
	table.insert(instances, instance)
	return instance
end

-- CanMutate(characterId, mutationId): does this character accept this
-- mutation (shared Mutations.CanMutate when the shared module loaded,
-- else the character's own MutationCompatibility list)? Keys are
-- case-insensitive; unknown mutations are never accepted.
function MutationService.CanMutate(characterId: string, mutationId: string): boolean
	if type(characterId) ~= "string" or type(mutationId) ~= "string" then
		return false
	end
	local key = string.lower(mutationId)
	if MUTATIONS[key] == nil then
		return false
	end
	local def = Characters.GetById(characterId)
	if not def then
		return false
	end
	if _sharedMutations and type(_sharedMutations.CanMutate) == "function" then
		local ok, result = pcall(function()
			return _sharedMutations.CanMutate(def, mutationId)
		end)
		if ok and type(result) == "boolean" then
			return result
		end
	end
	local compatibility = def.MutationCompatibility
	if type(compatibility) ~= "table" then
		return false
	end
	for _, allowedId in ipairs(compatibility) do
		if string.lower(tostring(allowedId)) == key then
			return true
		end
	end
	return false
end

-- RemoveInstance(player, instanceId): returns the removed record or nil.
function MutationService.RemoveInstance(player: Player, instanceId: string): any
	local instances = MutationService.GetInstances(player)
	for index, inst in ipairs(instances) do
		if inst.InstanceId == instanceId then
			table.remove(instances, index)
			return inst
		end
	end
	return nil
end

-- SetPlaced(player, instanceId, placed, slot): BaseService calls this
-- when it places / removes a Brainrot so the Placed flag stays in sync.
function MutationService.SetPlaced(player: Player, instanceId: string, placed: boolean, slot: number?)
	local inst = MutationService.FindInstance(player, instanceId)
	if not inst then
		return false
	end
	inst.Placed = placed == true
	inst.Slot = tonumber(slot) or 0
	return true
end

-- MoveInstance(fromPlayer, toPlayer, instanceId): move the SAME record
-- (same InstanceId) between two players' OwnedInstances lists. Used by
-- RaidService for the "stolen, in transit" hold: the record moves to
-- the thief at steal time so BaseService.PlaceBrainrot can accept it in
-- the thief's base, and moves back on ReturnStolen. Returns the moved
-- record, or nil when the source does not own it.
function MutationService.MoveInstance(fromPlayer: Player, toPlayer: Player, instanceId: string): any
	if not fromPlayer or not toPlayer or fromPlayer == toPlayer then
		return nil
	end
	local record = MutationService.RemoveInstance(fromPlayer, instanceId)
	if not record then
		return nil
	end
	record.Placed = false
	record.Slot = 0
	local instances = MutationService.GetInstances(toPlayer)
	table.insert(instances, record)
	return record
end

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

-- MutateBrainrot(player, instanceId, mutationId): server-validated.
-- Returns (true, instance) on success, (false, reason) on failure.
function MutationService.MutateBrainrot(player: Player, instanceId: any, mutationId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local cleanInstance = sanitize(instanceId)
	local cleanMutation = sanitize(mutationId)
	if not cleanInstance or not cleanMutation then
		return false, "invalid id"
	end
	-- Normalise to the lowercase key the table uses, so "Golden" and
	-- "golden" are the same mutation.
	cleanMutation = string.lower(cleanMutation)
	local def = MUTATIONS[cleanMutation]
	if not def then
		return false, "unknown mutation"
	end
	local data = getData(player)
	if not data then
		return false, "no data"
	end
	local rebirths = tonumber(data.Rebirths) or 0
	if rebirths < (def.MinRebirths or 0) then
		return false, "requires " .. tostring(def.MinRebirths) .. " rebirth(s)"
	end
	local inst = MutationService.FindInstance(player, cleanInstance)
	if not inst then
		return false, "instance not owned"
	end
	-- Theft / expedition integrity: a stolen in-transit instance or
	-- an instance away on an expedition must not be mutated — the
	-- mutation would land on a record whose ownership is unresolved
	-- (and, for a stolen record, would be lost or duplicated by the
	-- return path).
	if inst.InTransit == true then
		return false, "instance is in transit (stolen)"
	end
	if inst.OnExpedition == true then
		return false, "instance is on an expedition"
	end
	if inst.Mutation == cleanMutation then
		return false, "already has this mutation"
	end
	-- R3-8 (legacy divergence): a legacy record can carry a Mutation
	-- on its PLACED copy while the owned record has none (the seed
	-- mirror below heals this only when OwnedInstances is built
	-- fresh; a return can recreate it). In that state the player
	-- already has the mutation in every observable sense — the base
	-- displays it, income pays it, and a steal snapshot falls back
	-- to it — so charging crystals for it again is a double-charge.
	-- Reject it. Narrow on purpose: only when the owned record has
	-- NO mutation. When owned holds a different mutation (e.g. a
	-- stale placed copy lagging behind a paid mutation), re-buying
	-- the displayed mutation is still allowed — it heals the
	-- divergence by making the owned record match the display.
	if inst.Mutation == nil then
		local placedLists: { { any } } = {}
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			table.insert(placedLists, data.Base.Placed)
		end
		if type(data.Placed) == "table" then
			table.insert(placedLists, data.Placed)
		end
		for _, list in ipairs(placedLists) do
			for _, placed in ipairs(list) do
				if type(placed) == "table" and placed.InstanceId == cleanInstance and placed.Mutation == cleanMutation then
					return false, "already has this mutation"
				end
			end
		end
	end
	-- v1.0.1 QA: this check was missing entirely — any character could
	-- take any mutation, ignoring the MutationCompatibility lists in
	-- Characters.luau. A mutation the character cannot take is rejected.
	if not MutationService.CanMutate(inst.CharacterId, cleanMutation) then
		return false, "character cannot take this mutation"
	end
	local cost = math.max(1, math.floor((def.Crystals or 5) * MutationService.GetMutationCostMultiplier() + 0.5))
	local crystals = tonumber(data.MutationCrystals) or 0
	if crystals < cost then
		return false, "not enough Mutation Crystals"
	end
	data.MutationCrystals = crystals - cost
	inst.Mutation = cleanMutation
	-- R3-7: the placed copy is synced above and RebuildBase (below)
	-- fires the FULL BaseUpdate snapshot, so the client's base list
	-- (which renders from that snapshot) updates too. The old code
	-- then ALSO fired a partial {Action = "MutationApplied", ...}
	-- payload through the same BaseUpdate remote — and
	-- BaseController.ApplyBaseUpdate assigns baseState = data
	-- unconditionally, so the partial (no Placed list, no
	-- BankedIncome, no Slots) overwrote the just-sent full snapshot:
	-- banked income read 0 and slots read "N / 0" until the next
	-- full update arrived. No client code ever branched on
	-- MutationApplied (verified by grep over src/client: no handler
	-- reads Action == "MutationApplied"), so the partial is deleted
	-- outright — not moved to another remote (that would need a
	-- Remotes.luau change, out of scope for this fix) and not kept
	-- as a notice. RebuildBase fires for unplaced mutations too:
	-- the full snapshot's Unplaced list is the only place the
	-- client learns an unplaced mutation, and rebuilding placed
	-- models is the price of a correct push in both cases.
	do
		local lists: { { any } } = {}
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			table.insert(lists, data.Base.Placed)
		end
		if type(data.Placed) == "table" then
			table.insert(lists, data.Placed)
		end
		for _, list in ipairs(lists) do
			for _, placed in ipairs(list) do
				if type(placed) == "table" and placed.InstanceId == cleanInstance then
					placed.Mutation = cleanMutation
				end
			end
		end
		if _baseService and type(_baseService.RebuildBase) == "function" then
			pcall(function()
				_baseService.RebuildBase(player)
			end)
		end
	end
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	if _questService and type(_questService.RecordEvent) == "function" then
		pcall(function()
			_questService.RecordEvent(player, "mutate", 1)
		end)
	end
	print(string.format(
		"[MutationService] %s mutated %s (%s) -> %s for %d crystals",
		player.Name, cleanInstance, tostring(inst.CharacterId), cleanMutation, cost
	))
	return true, inst
end

local function onUpgradeRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	-- Two call shapes: on the dedicated MutateBrainrot remote the
	-- payload is just {InstanceId=..., MutationId=...}; on the shared
	-- UpgradeBrainrot fallback remote it carries Action="Mutate".
	-- (BaseService's own UpgradeBrainrot handler ignores table payloads
	-- it cannot use, so the shared remote stays safe either way.)
	if type(payload) ~= "table" then
		return
	end
	if payload.Action ~= nil and payload.Action ~= "Mutate" then
		return
	end
	if not rateOk(player, "MutateBrainrot", 1) then
		return
	end
	local ok, err = MutationService.MutateBrainrot(player, payload.InstanceId, payload.MutationId)
	if not ok then
		warn("[MutationService] Mutate failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function MutationService.Init(dataService: any, questService: any?, eventService: any?)
	assert(dataService ~= nil, "[MutationService] Init requires DataService")
	_dataService = dataService
	_questService = questService
	_eventService = eventService
	loadMutationTable()

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	-- Wire MutateBrainrot, falling back to the existing UpgradeBrainrot
	-- remote (see header). Wait for the Remotes folder to exist first.
	local remoteName = _names.MutateBrainrot or _names.UpgradeBrainrot
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(remoteName)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onUpgradeRemote)
		else
			warn("[MutationService] Remote not found, mutate handler not wired: " .. tostring(remoteName))
		end
	end)
end

return MutationService
