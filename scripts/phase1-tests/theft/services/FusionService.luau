--!strict
-- FusionService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Fusion: combine 2 owned Brainrots into the stronger character their
-- recipe produces (shared Mutations.FusionRecipes — 10 recipes, all
-- pointing at real character ids).
--
-- RULE (documented choice): both inputs must be UNPLACED instances
-- (sitting in the player's inventory, not on base slots). Fusing placed
-- Brainrots would silently tear holes in a base's income and slot
-- layout, so placed instances are rejected with "instance is placed".
--
-- COST (validated server-side, charged before the inputs are consumed):
-- Config.FusionCosts — 1000 coins + 25 Mutation Crystals (see shared
-- Economy.FusionCost, which returns nil when the pair has no recipe).
-- A pair with NO recipe is rejected ("no fusion recipe for this pair")
-- — fusion is recipe-only.
--
-- OUTCOME: the recipe's ResultId at level 1, no mutation. The two
-- inputs are REMOVED before the output instance is created, in the
-- same server step, so a crash / double-fire can never duplicate.
-- If creating the output fails, the inputs are restored AND the cost
-- is refunded, so a failed fusion never eats a player's Brainrots.
--
-- v1.0.1 QA: v1.0.0 ignored the recipe table entirely and rolled a
-- random outcome (60% level-up / 25% mutation / 15% "next rarity")
-- from a WRONG rarity ladder {"Common","Rare","Epic","Legendary",
-- "Mythic","Glitch"} that skipped Uncommon/Divine/Celestial/Secret/
-- Impossible and used "Glitch", which is not a rarity at all — and it
-- required both inputs to be the SAME character while every recipe
-- pairs two DIFFERENT characters, so no recipe could ever fire. It
-- also never charged any cost. All of that is replaced by the
-- recipe-based flow above.
--
-- Instance registry lives in MutationService (data.OwnedInstances);
-- FusionService takes it as an optional Init argument and falls back to
-- requiring the sibling module. It never touches data.Placed directly.
--
-- REMOTE: FuseBrainrot exists in Remotes.Names (RemoteEvent), so the
-- handler binds to it directly (UpgradeBrainrot is only the fallback
-- if the name ever disappears).
--
-- R4-5: the fusion result used to fire as a bare partial payload
-- {Action="FusionResult", ...} through BaseUpdate, and
-- ShopController.OnBaseUpdate assigned baseState = data
-- unconditionally — so the partial overwrote the shop's full base
-- state (upgrade levels read 0 until the next full snapshot). The
-- result now rides ON a full BaseService.GetBase snapshot fired
-- through BaseUpdate (same pattern as R3-7's MutationApplied fix),
-- so every BaseUpdate fire is a valid snapshot. If no snapshot can
-- be built (no BaseService link, or no BaseUpdate remote), the
-- result falls back to the PlayerStats remote as a notification
-- only — it never goes through BaseUpdate as a bare partial, and
-- the shop's PlayerStats listener handles it without touching
-- base state. Server-side purchase validation is unchanged and
-- remains authoritative.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Characters = require("../shared/Characters")
local Economy = require("../shared/Economy")
local Mutations = require("../shared/Mutations")
local Remotes = require("../shared/Remotes")

local _names: any = Remotes.Names

local FusionService = {}

local _dataService: any = nil
local _mutationService: any = nil
local _questService: any = nil
local _baseService: any = nil

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

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
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

-- R4-3: spendable balance — the raw balance minus any reservation
-- held for a pending reward commit (DataService.ReserveCoins).
-- Falls back to the raw balance when the DataService has no
-- reservation API (older stub). The charge below goes through
-- DataService.AddCoins, which enforces the same floor as a
-- backstop, so a reserved reward credit can never be spent here
-- while its commit's save is in flight.
local function spendableCoins(player: Player, data: any): number
	local coins = tonumber(data.Coins) or 0
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, value = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(value) == "number" then
			return value
		end
	end
	return coins
end

local function resolveMutationService(): any
	if _mutationService and type(_mutationService.FindInstance) == "function"
		and type(_mutationService.CreateInstance) == "function"
		and type(_mutationService.RemoveInstance) == "function"
	then
		return _mutationService
	end
	-- The injected value was not a MutationService (GameManager's
	-- generic Init passes EconomyService positionally) — ignore it and
	-- require the sibling module instead.
	_mutationService = nil
	pcall(function()
		local mod = script.Parent:FindFirstChild("MutationService")
		if mod then
			local candidate = require(mod)
			if type(candidate.FindInstance) == "function" then
				_mutationService = candidate
			end
		end
	end)
	return _mutationService
end

-- SetBaseService(baseService): optional link used ONLY to build the
-- full base snapshot the fusion result rides on (R4-5). GameManager's
-- cross-link pass calls this setter automatically when BaseService is
-- loaded (it tryWires SetBaseService on every optional service); the
-- lazy sibling require below covers the case where the setter was
-- never called. Without a BaseService the fusion still succeeds —
-- the result falls back to the PlayerStats notification path.
function FusionService.SetBaseService(baseService: any)
	if baseService and type(baseService.GetBase) == "function" then
		_baseService = baseService
	end
end

local function resolveBaseService(): any
	if _baseService and type(_baseService.GetBase) == "function" then
		return _baseService
	end
	-- Same lazy sibling fallback as resolveMutationService above.
	_baseService = nil
	pcall(function()
		local mod = script.Parent:FindFirstChild("BaseService")
		if mod then
			local candidate = require(mod)
			if type(candidate.GetBase) == "function" then
				_baseService = candidate
			end
		end
	end)
	return _baseService
end

-- FuseBrainrot(player, instanceIdA, instanceIdB): server-validated,
-- recipe-based fusion. Returns (true, outputInstance, "Recipe") or
-- (false, reason, nil).
function FusionService.FuseBrainrot(player: Player, instanceIdA: any, instanceIdB: any): (boolean, any, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player", nil
	end
	local idA = sanitize(instanceIdA)
	local idB = sanitize(instanceIdB)
	if not idA or not idB or idA == idB then
		return false, "invalid instance ids", nil
	end
	local ms = resolveMutationService()
	if not ms then
		return false, "mutation service unavailable", nil
	end
	local instA = ms.FindInstance(player, idA)
	local instB = ms.FindInstance(player, idB)
	if not instA or not instB then
		return false, "instance not owned", nil
	end
	if instA.Placed or instB.Placed then
		return false, "both instances must be unplaced (fuse from inventory)", nil
	end
	-- Theft integrity: an in-transit (stolen) or on-expedition
	-- instance must never be consumed. A stolen record has
	-- Placed=false, so the check above does not catch it — without
	-- this guard, fusing it and then dying/dropping it lets
	-- ReturnStolen recreate the victim's copy while the thief keeps
	-- the fusion output (one instance becomes two).
	if instA.InTransit == true or instB.InTransit == true then
		return false, "instance is in transit (stolen)", nil
	end
	if instA.OnExpedition == true or instB.OnExpedition == true then
		return false, "instance is on an expedition", nil
	end
	local characterIdA = instA.CharacterId
	local characterIdB = instB.CharacterId
	if not Characters.GetById(characterIdA) or not Characters.GetById(characterIdB) then
		return false, "unknown character", nil
	end
	-- Recipe check FIRST: no recipe for this pair means no fusion.
	-- (Recipes pair two DIFFERENT characters; same-character pairs
	-- have no recipe and are rejected here.)
	local recipe = Mutations.GetFusionRecipe(characterIdA, characterIdB)
	if not recipe then
		return false, "no fusion recipe for this pair", nil
	end
	local outCharacterId = recipe.ResultId
	if not Characters.GetById(outCharacterId) then
		return false, "fusion recipe result is not a real character", nil
	end
	-- Cost check: Economy.FusionCost is nil when there is no recipe
	-- (already excluded above); charge coins + Mutation Crystals.
	local cost = Economy.FusionCost(characterIdA, characterIdB)
	if not cost then
		return false, "no fusion recipe for this pair", nil
	end
	local data = getData(player)
	if not data then
		return false, "no data", nil
	end
	local crystals = tonumber(data.MutationCrystals) or 0
	if spendableCoins(player, data) < cost.Coins then
		return false, "not enough coins for fusion", nil
	end
	if crystals < cost.MutationCrystals then
		return false, "not enough Mutation Crystals for fusion", nil
	end

	-- Charge, then consume BOTH inputs, then grant the output, in one
	-- server step — a crash / double-fire can never duplicate.
	-- R4-3: charge through DataService.AddCoins, never by direct
	-- assignment — AddCoins clamps a debit at the reserved total, so
	-- a pending reward commit's reserved credit cannot be spent here
	-- (the affordability check above already judged spendable coins;
	-- the floor is the backstop). Init guarantees _dataService, and
	-- getData succeeding above proves it is set.
	_dataService.AddCoins(player, -cost.Coins)
	data.MutationCrystals = crystals - cost.MutationCrystals
	ms.RemoveInstance(player, idA)
	ms.RemoveInstance(player, idB)
	local output = ms.CreateInstance(player, outCharacterId, 1, nil)
	if not output then
		-- Extremely defensive: refund the cost AND restore the inputs
		-- rather than ever silently eating a player's Brainrots.
		-- R4-3: refund through AddCoins as well (same table, same
		-- floor semantics as the charge).
		_dataService.AddCoins(player, cost.Coins)
		data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + cost.MutationCrystals
		ms.CreateInstance(player, characterIdA, tonumber(instA.Level) or 1, instA.Mutation)
		ms.CreateInstance(player, characterIdB, tonumber(instB.Level) or 1, instB.Mutation)
		return false, "fusion failed, inputs restored and cost refunded", nil
	end

	-- A new character entered the collection: make sure it is in
	-- the unlocked set the rest of the game reads.
	pcall(function()
		_dataService.UnlockCharacter(player, outCharacterId)
	end)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	-- R4-5: the result rides ON a full base snapshot, never as a bare
	-- partial. GetBase returns a fresh table per call, so attaching
	-- the result fields cannot mutate any cached snapshot. The
	-- snapshot carries Placed / Unplaced / BankedIncome / Slots /
	-- IncomePerSec plus the flat upgrade levels, so the client's
	-- full-state assignment stays valid and the fuse watchdog still
	-- clears (ShopController keys the notification off
	-- Action == "FusionResult" on either shape).
	local resultFields = {
		Action = "FusionResult",
		Outcome = "Recipe",
		RecipeHint = recipe.Hint,
		InstanceId = output.InstanceId,
		CharacterId = outCharacterId,
		Level = 1,
		MutationId = nil,
		Consumed = { idA, idB },
		Cost = cost,
	}
	local snapshot: any = nil
	local bs = resolveBaseService()
	if bs and type(bs.GetBase) == "function" then
		local ok, snap = pcall(function()
			return bs.GetBase(player)
		end)
		if ok and type(snap) == "table" then
			snapshot = snap
		end
	end
	if snapshot ~= nil and getRemote(_names.BaseUpdate) then
		for key, value in resultFields do
			snapshot[key] = value
		end
		fireClient(_names.BaseUpdate, player, snapshot)
	else
		-- Degraded path: no BaseService link, snapshot build failed,
		-- or no BaseUpdate remote. The result still reaches the
		-- client, but on PlayerStats as a notification only — never
		-- as a bare partial on BaseUpdate, where it used to corrupt
		-- the shop's base state. ShopController's PlayerStats
		-- listener clears the fuse watchdog for it and touches no
		-- base state.
		fireClient(_names.PlayerStats, player, resultFields)
	end
	if _questService and type(_questService.RecordEvent) == "function" then
		pcall(function()
			_questService.RecordEvent(player, "fuse", 1)
		end)
	end
	print(string.format(
		"[FusionService] %s fused %s + %s -> %s (recipe, %d coins + %d crystals)",
		player.Name, characterIdA, characterIdB, outCharacterId, cost.Coins, cost.MutationCrystals
	))
	return true, output, "Recipe"
end

local function onUpgradeRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	-- Two call shapes: on the dedicated FuseBrainrot remote the payload
	-- is just {InstanceIdA=..., InstanceIdB=...}; on the shared
	-- UpgradeBrainrot fallback remote it carries Action="Fuse".
	if type(payload) ~= "table" then
		return
	end
	if payload.Action ~= nil and payload.Action ~= "Fuse" then
		return
	end
	if not rateOk(player, "FuseBrainrot", 1) then
		return
	end
	local ok, err = FusionService.FuseBrainrot(player, payload.InstanceIdA, payload.InstanceIdB)
	if not ok then
		warn("[FusionService] Fuse failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function FusionService.Init(dataService: any, mutationService: any?, questService: any?)
	assert(dataService ~= nil, "[FusionService] Init requires DataService")
	_dataService = dataService
	_mutationService = mutationService
	_questService = questService
	resolveMutationService()

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	local remoteName = _names.FuseBrainrot or _names.UpgradeBrainrot
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
			warn("[FusionService] Remote not found, fuse handler not wired: " .. tostring(remoteName))
		end
	end)
end

return FusionService
