--!strict
-- RaidService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Stealing + base defenses, all validated server-side.
--
-- STEAL FLOW (StealBrainrot remote, victim must be online):
--   request -> protection checks -> 3s channel (thief must stay within
--   8 studs of the channel anchor; moving / dying cancels) -> success:
--   the Brainrot leaves the victim's base and becomes "stolen, in
--   transit" (tracked in _inTransit, thief's character carries a
--   CarryingStolen attribute, and the OwnedInstances record moves to
--   the thief as an in-transit hold so BaseService.PlaceBrainrot can
--   accept it in the thief's base). Ownership is confirmed when the
--   thief places it in their own base — detected by a 5s watchdog
--   poll (PollInTransit; BaseService/CarryService never call back),
--   or directly via ConfirmDelivery. If the thief dies or drops it
--   first, the record moves back and it returns to the victim's
--   original base slot (ReturnStolen).
--
-- PROTECTIONS (IsProtected): victim level < 3, victim account age < 7
-- days, victim would be left with 0 placed Brainrots, target placed
-- < 120s ago, base shield active, or lockdown active.
--
-- BASE DEFENSES: shield (timed, blocks steal), gate (must be open for
-- a non-owner to enter), guard NPCs (RegisterGuard hook for NPCService),
-- lockdown (owner-triggered, 30s, costs coins, blocks entry).
--
-- OPTIONAL DEPENDENCIES: BaseService and CarryService are optional Init
-- args and are never hard-required. Without BaseService, placed targets
-- are read from the victim's data.Base.Placed (Types.PlacedBrainrot
-- shape; data.Placed is the legacy fallback)
-- and base positions fall back to the map "Bases" folder, then to the
-- victim's character position. Without CarryService, carrying is tracked
-- in _inTransit + the CarryingStolen attribute only. MutationService /
-- QuestService may be passed via the optional `opts` table
-- ({MutationService=..., QuestService=...}) for instance-accurate
-- ownership transfer and quest events.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Economy = require(ReplicatedStorage:WaitForChild("Economy"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local RaidService = {}

local _dataService: any = nil
local _baseService: any = nil
local _carryService: any = nil
local _mutationService: any = nil
local _questService: any = nil

local STEAL_CHANNEL = Config.StealChannelSeconds or 3
local STEAL_COOLDOWN = Config.StealCooldownSeconds or 60
local CHANNEL_RADIUS = 8
local NEW_PLAYER_LEVEL = 3
local NEW_ACCOUNT_DAYS = 7
local RECENT_PLACE_SECONDS = 120
local LOCKDOWN_DURATION = Config.BaseLockDuration or 30
local LOCKDOWN_COST = Config.LockdownCost or 250
local LOCKDOWN_COOLDOWN = Config.LockdownCooldownSeconds or 120
local SHIELD_DURATION = Config.ShieldDurationSeconds or 60
local SHIELD_COST = Config.ShieldCost or 100

-- [thiefUserId .. ":" .. victimUserId] = os.clock() of last attempt.
local _pairCooldowns: { [string]: number } = {}
-- [instanceId] = { Thief, Victim, CharacterId, Slot, PlacedAt }.
local _inTransit: { [string]: any } = {}
-- [ownerUserId] = os.clock() until which the shield / lockdown is active.
local _shields: { [number]: number } = {}
local _lockdowns: { [number]: number } = {}
local _lockdownCooldowns: { [number]: number } = {}
-- [ownerUserId] = open? (default open).
local _gates: { [number]: boolean } = {}
-- [ownerUserId] = { npcModel, ... } (registered via RegisterGuard).
local _guards: { [number]: { Model } } = {}
-- [thief] = active channel record (cancelled by movement / death).
local _channels: { [Player]: any } = {}
local _stunned: { [Humanoid]: boolean } = {}
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

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
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

-- ---------------------------------------------------------------------------
-- Base / placed lookups (BaseService first, data.Placed / map fallback).
-- ---------------------------------------------------------------------------

local function getPlacedList(victim: Player): { any }
	if _baseService and type(_baseService.GetPlaced) == "function" then
		local ok, list = pcall(function()
			return _baseService.GetPlaced(victim)
		end)
		if ok and type(list) == "table" then
			return list
		end
	end
	local data = getData(victim)
	if data then
		-- Placed Brainrots live in data.Base.Placed (BaseService's
		-- shape); data.Placed is the legacy fallback.
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			return data.Base.Placed
		end
		if type(data.Placed) == "table" then
			return data.Placed
		end
	end
	return {}
end

local function findPlaced(victim: Player, instanceId: string): any
	for _, placed in ipairs(getPlacedList(victim)) do
		if type(placed) == "table" and placed.InstanceId == instanceId then
			return placed
		end
	end
	return nil
end

local function removeFromPlacedList(data: any, instanceId: string): boolean
	local lists: { { any } } = {}
	if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
		table.insert(lists, data.Base.Placed)
	end
	if type(data.Placed) == "table" then
		table.insert(lists, data.Placed)
	end
	for _, list in ipairs(lists) do
		for index, placed in ipairs(list) do
			if type(placed) == "table" and placed.InstanceId == instanceId then
				table.remove(list, index)
				return true
			end
		end
	end
	return false
end

local function removePlaced(victim: Player, instanceId: string): boolean
	if _baseService and type(_baseService.RemovePlaced) == "function" then
		local ok, result = pcall(function()
			return _baseService.RemovePlaced(victim, instanceId)
		end)
		if ok and result then
			return true
		end
	end
	local data = getData(victim)
	if data then
		return removeFromPlacedList(data, instanceId)
	end
	return false
end

local function reinsertPlaced(victim: Player, placed: any)
	-- Insert into the REAL placed table (data.Base.Placed) and rebuild
	-- the base models. BaseService.PlaceBrainrot cannot be used here:
	-- it requires the victim to be carrying the Brainrot and standing
	-- at the pedestal, which is false for a return.
	local data = getData(victim)
	if data then
		if type(data.Base) == "table" then
			if type(data.Base.Placed) ~= "table" then
				data.Base.Placed = {}
			end
			table.insert(data.Base.Placed, placed)
		else
			if type(data.Placed) ~= "table" then
				data.Placed = {}
			end
			table.insert(data.Placed, placed)
		end
	end
	if _baseService and type(_baseService.RebuildBase) == "function" then
		pcall(function()
			_baseService.RebuildBase(victim)
		end)
	end
end

-- Move the OwnedInstances record for `instanceId` between two players.
-- Uses MutationService.MoveInstance when linked, else edits the data
-- tables directly (same shape). Returns true on success.
local function moveOwnedRecord(fromPlayer: Player, toPlayer: Player, instanceId: string): boolean
	if not fromPlayer or not toPlayer then
		return false
	end
	if _mutationService and type(_mutationService.MoveInstance) == "function" then
		local ok, moved = pcall(function()
			return _mutationService.MoveInstance(fromPlayer, toPlayer, instanceId)
		end)
		if ok and moved then
			return true
		end
	end
	local fromData = getData(fromPlayer)
	local toData = getData(toPlayer)
	if not fromData or not toData then
		return false
	end
	if type(fromData.OwnedInstances) ~= "table" then
		return false
	end
	local record: any = nil
	for index, inst in ipairs(fromData.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == instanceId then
			record = inst
			table.remove(fromData.OwnedInstances, index)
			break
		end
	end
	if not record then
		return false
	end
	record.Placed = false
	record.Slot = 0
	if type(toData.OwnedInstances) ~= "table" then
		toData.OwnedInstances = {}
	end
	table.insert(toData.OwnedInstances, record)
	return true
end

-- Placed pedestal positions for `owner` (via BaseService when linked).
-- Used for the "thief is inside the victim's base" check and the steal
-- channel anchor: pedestals are the ground truth for base location.
local function getPlacedPositions(owner: Player): { Vector3 }
	local positions: { Vector3 } = {}
	if _baseService and type(_baseService.GetPlacedPosition) == "function" then
		for _, placed in ipairs(getPlacedList(owner)) do
			if type(placed) == "table" and type(placed.InstanceId) == "string" then
				local ok, pos = pcall(function()
					return _baseService.GetPlacedPosition(owner, placed.InstanceId)
				end)
				if ok and typeof(pos) == "Vector3" then
					table.insert(positions, pos)
				end
			end
		end
	end
	return positions
end

-- Base plot position for `owner`: map Bases folder fallback (child
-- named by UserId or Name, first BasePart inside), else nil.
local function getBasePosition(owner: Player): Vector3?
	if _baseService and type(_baseService.GetBasePosition) == "function" then
		local ok, pos = pcall(function()
			return _baseService.GetBasePosition(owner)
		end)
		if ok and typeof(pos) == "Vector3" then
			return pos
		end
	end
	local bases = workspace:FindFirstChild("Bases")
	if bases then
		local plot = bases:FindFirstChild(tostring(owner.UserId)) or bases:FindFirstChild(owner.Name)
		if plot then
			for _, descendant in ipairs(plot:GetDescendants()) do
				if descendant:IsA("BasePart") then
					return descendant.Position
				end
			end
		end
	end
	return nil
end

local function getCharacterPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function isShieldActive(ownerUserId: number): boolean
	local untilTime = _shields[ownerUserId]
	return untilTime ~= nil and os.clock() < untilTime
end

local function isLockdownActive(ownerUserId: number): boolean
	local untilTime = _lockdowns[ownerUserId]
	return untilTime ~= nil and os.clock() < untilTime
end

local function applyStun(player: Player, duration: number)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or _stunned[humanoid] then
		return
	end
	_stunned[humanoid] = true
	local originalSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = 0
	character:SetAttribute("RaidStunned", true)
	task.delay(duration, function()
		_stunned[humanoid] = nil
		if humanoid.Parent then
			character:SetAttribute("RaidStunned", false)
			humanoid.WalkSpeed = originalSpeed
		end
	end)
end

local function alertSteal(victim: Player, thief: Player, characterId: string, phase: string)
	local payload = {
		Thief = thief.Name,
		ThiefUserId = thief.UserId,
		Victim = victim.Name,
		CharacterId = characterId,
		Phase = phase, -- "Started" | "Success" | "Failed" | "Returned" | "Delivered"
	}
	fireClient(_names.StealAlert, victim, payload)
	-- Nearby players (within 40 studs of the victim) hear the alarm too.
	local victimPos = getCharacterPosition(victim)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= victim and player ~= thief then
			local pos = getCharacterPosition(player)
			if victimPos and pos and (pos - victimPos).Magnitude <= 40 then
				fireClient(_names.StealAlert, player, payload)
			end
		end
	end
end

local function recordQuest(player: Player, eventName: string, amount: number)
	if _questService and type(_questService.RecordEvent) == "function" then
		pcall(function()
			_questService.RecordEvent(player, eventName, amount)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Public queries
-- ---------------------------------------------------------------------------

-- IsProtected(victim, targetPlaced): (true, reason) when any protection
-- applies. `targetPlaced` may be a placed record or an instance id.
function RaidService.IsProtected(victim: Player, target: any): (boolean, string)
	if not victim or not victim:IsA("Player") then
		return true, "invalid victim"
	end
	local data = getData(victim)
	if not data then
		return true, "no victim data"
	end
	if (tonumber(data.Level) or 1) < NEW_PLAYER_LEVEL then
		return true, "new-player protection (level < 3)"
	end
	if victim.AccountAge < NEW_ACCOUNT_DAYS then
		return true, "new-player protection (account age < 7 days)"
	end
	if isShieldActive(victim.UserId) then
		return true, "base shield active"
	end
	if isLockdownActive(victim.UserId) then
		return true, "base lockdown active"
	end
	if _baseService and type(_baseService.IsLocked) == "function" then
		local ok, locked = pcall(function()
			return _baseService.IsLocked(victim)
		end)
		if ok and locked then
			return true, "base lock active"
		end
	end
	local placedList = getPlacedList(victim)
	if #placedList <= 1 then
		return true, "starter/last-creature protection (victim would be left with 0 placed)"
	end
	local placed: any = nil
	if type(target) == "string" then
		placed = findPlaced(victim, target)
	elseif type(target) == "table" then
		placed = target
	end
	if not placed then
		return true, "target not placed in victim base"
	end
	local placedAt = tonumber(placed.PlacedAt) or 0
	if placedAt > 0 and os.time() - placedAt < RECENT_PLACE_SECONDS then
		return true, "recently-purchased protection (placed < 120s ago)"
	end
	return false, ""
end

-- GetCooldown(thief): seconds remaining on the thief's longest active
-- steal cooldown across all victims (0 when free to steal).
function RaidService.GetCooldown(thief: Player): number
	if not thief or not thief:IsA("Player") then
		return 0
	end
	local now = os.clock()
	local remaining = 0
	for key, at in pairs(_pairCooldowns) do
		if string.match(key, "^" .. tostring(thief.UserId) .. ":") then
			remaining = math.max(remaining, STEAL_COOLDOWN - (now - at))
		end
	end
	return math.max(0, remaining)
end

-- CanEnter(visitor, owner): gate + lockdown gatekeeping for base entry.
function RaidService.CanEnter(visitor: Player, owner: Player): (boolean, string)
	if not visitor or not owner then
		return false, "invalid player"
	end
	if visitor == owner then
		return true, ""
	end
	if isLockdownActive(owner.UserId) then
		return false, "base is in lockdown"
	end
	if _gates[owner.UserId] == false then
		return false, "base gate is closed"
	end
	return true, ""
end

function RaidService.GetGuards(ownerUserId: number): { Model }
	return _guards[ownerUserId] or {}
end

-- ---------------------------------------------------------------------------
-- Defenses
-- ---------------------------------------------------------------------------

-- RegisterGuard(base, npc): NPCService calls this after spawning a guard
-- so raids can see it. `base` is the owner Player or a UserId.
function RaidService.RegisterGuard(base: any, npc: Model): boolean
	local ownerUserId: number? = nil
	if type(base) == "number" then
		ownerUserId = base
	elseif typeof(base) == "Instance" and base:IsA("Player") then
		ownerUserId = base.UserId
	end
	if not ownerUserId or not npc or not npc:IsA("Model") then
		return false
	end
	_guards[ownerUserId] = _guards[ownerUserId] or {}
	table.insert(_guards[ownerUserId], npc)
	return true
end

-- ActivateShield(player, durationSeconds?): 100 coins, blocks steals
-- while active (default 60s). Returns (true) or (false, reason).
function RaidService.ActivateShield(player: Player, durationSeconds: number?): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = getData(player)
	if not data then
		return false, "no data"
	end
	if isShieldActive(player.UserId) then
		return false, "shield already active"
	end
	if (tonumber(data.Coins) or 0) < SHIELD_COST then
		return false, "not enough coins"
	end
	pcall(function()
		_dataService.AddCoins(player, -SHIELD_COST)
	end)
	_shields[player.UserId] = os.clock() + (tonumber(durationSeconds) or SHIELD_DURATION)
	return true, nil
end

-- SetGate(player, open): owner opens / closes their base gate.
function RaidService.SetGate(player: Player, open: boolean): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	_gates[player.UserId] = open == true
	return true
end

-- TriggerLockdown(player): 30s lockdown, 250 coins, 120s owner cooldown.
-- Blocks entry (CanEnter) and steals (IsProtected) while active.
function RaidService.TriggerLockdown(player: Player): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = getData(player)
	if not data then
		return false, "no data"
	end
	if isLockdownActive(player.UserId) then
		return false, "lockdown already active"
	end
	local last = _lockdownCooldowns[player.UserId] or -math.huge
	if os.clock() - last < LOCKDOWN_COOLDOWN then
		return false, "lockdown on cooldown"
	end
	if (tonumber(data.Coins) or 0) < LOCKDOWN_COST then
		return false, "not enough coins"
	end
	pcall(function()
		_dataService.AddCoins(player, -LOCKDOWN_COST)
	end)
	_lockdowns[player.UserId] = os.clock() + LOCKDOWN_DURATION
	_lockdownCooldowns[player.UserId] = os.clock()
	fireAll(_names.StealAlert, {
		Victim = player.Name,
		Phase = "Lockdown",
		Duration = LOCKDOWN_DURATION,
	})
	return true, nil
end

-- RecordDefense(victim): called when a guard / protection stops a thief.
function RaidService.RecordDefense(victim: Player)
	if not victim then
		return
	end
	recordQuest(victim, "defend_success", 1)
end

-- PollInTransit(): watchdog over stolen Brainrots. BaseService and
-- CarryService never call back into RaidService, so delivery and drops
-- are detected by polling: delivered when the instance is placed in
-- the thief's own base; dropped when the thief is no longer carrying
-- it (manual drop, or a death the Died hook missed). A 2s grace period
-- after the steal covers ForceCarry timing.
function RaidService.PollInTransit()
	local ids: { string } = {}
	for instanceId in pairs(_inTransit) do
		table.insert(ids, instanceId)
	end
	for _, instanceId in ipairs(ids) do
		local record = _inTransit[instanceId]
		if record then
			local thief = record.Thief
			if not thief or not thief.Parent then
				RaidService.ReturnStolen(instanceId)
			else
				local delivered = false
				if _baseService and type(_baseService.GetPlaced) == "function" then
					local ok, placedList = pcall(function()
						return _baseService.GetPlaced(thief)
					end)
					if ok and type(placedList) == "table" then
						for _, placed in ipairs(placedList) do
							if type(placed) == "table" and placed.InstanceId == instanceId then
								delivered = true
								break
							end
						end
					end
				end
				-- Fallback: read the thief's data directly. v1.0.0 only
				-- checked BaseService, so with BaseService unlinked a
				-- stolen Brainrot could never be delivered at all.
				if not delivered then
					local thiefData = getData(thief)
					if thiefData then
						local lists: { { any } } = {}
						if type(thiefData.Base) == "table" and type(thiefData.Base.Placed) == "table" then
							table.insert(lists, thiefData.Base.Placed)
						end
						if type(thiefData.Placed) == "table" then
							table.insert(lists, thiefData.Placed)
						end
						for _, list in ipairs(lists) do
							for _, placed in ipairs(list) do
								if type(placed) == "table" and placed.InstanceId == instanceId then
									delivered = true
									break
								end
							end
							if delivered then
								break
							end
						end
					end
				end
				if delivered then
					RaidService.ConfirmDelivery(thief, instanceId)
				elseif _carryService and os.clock() - (tonumber(record.StolenAt) or 0) > 2 then
					local carrying = false
					if type(_carryService.IsCarrying) == "function" then
						local ok, result = pcall(function()
							return _carryService.IsCarrying(thief)
						end)
						carrying = ok and result == true
					end
					if carrying and type(_carryService.GetCarried) == "function" then
						local ok, carried = pcall(function()
							return _carryService.GetCarried(thief)
						end)
						if not ok or type(carried) ~= "table" or carried.InstanceId ~= instanceId then
							carrying = false
						end
					end
					if not carrying then
						RaidService.ReturnStolen(instanceId)
					end
				end
			end
		end
	end
end

-- Setters for GameManager's tryWire injection (its generic Init passes
-- EconomyService / the map positionally, so the real services arrive
-- here instead). Each validates the interface before accepting.
function RaidService.SetBaseService(baseService: any)
	if baseService and type(baseService.GetPlaced) == "function" then
		_baseService = baseService
	end
end

function RaidService.SetCarryService(carryService: any)
	if carryService
		and (type(carryService.ForceCarry) == "function" or type(carryService.DropCarried) == "function")
	then
		_carryService = carryService
	end
end

function RaidService.SetMutationService(mutationService: any)
	if mutationService and type(mutationService.MoveInstance) == "function" then
		_mutationService = mutationService
	end
end

function RaidService.SetQuestService(questService: any)
	if questService and type(questService.RecordEvent) == "function" then
		_questService = questService
	end
end

-- ---------------------------------------------------------------------------
-- Steal flow
-- ---------------------------------------------------------------------------

-- ReturnStolen(instanceId): a stolen Brainrot in transit goes back to
-- the victim's original base slot (thief died / dropped it).
function RaidService.ReturnStolen(instanceId: string): boolean
	local record = _inTransit[instanceId]
	if not record then
		return false
	end
	_inTransit[instanceId] = nil
	local victim = record.Victim
	local thief = record.Thief
	if thief and thief.Character then
		thief.Character:SetAttribute("CarryingStolen", "")
	end
	-- Move the OwnedInstances record back to the victim (it was moved
	-- to the thief as an in-transit hold at steal time). This is what
	-- closes the duplication hole: CarryService drops the carried
	-- Brainrot as a world pickup on death, but its pickup path requires
	-- the picker to own the record — after this move the thief no
	-- longer does, so the stale drop just expires.
	-- If the victim has already left the server their data may be
	-- unreachable: then the record is DESTROYED from the thief instead
	-- of being left with them — a thief must never keep stolen goods
	-- for free just because the victim logged out mid-theft.
	if thief then
		local moved = moveOwnedRecord(thief, victim, instanceId)
		if not moved and (not victim or not victim.Parent) then
			if _mutationService and type(_mutationService.RemoveInstance) == "function" then
				pcall(function()
					_mutationService.RemoveInstance(thief, instanceId)
				end)
			else
				local thiefData = getData(thief)
				if thiefData and type(thiefData.OwnedInstances) == "table" then
					for index, inst in ipairs(thiefData.OwnedInstances) do
						if type(inst) == "table" and inst.InstanceId == instanceId then
							table.remove(thiefData.OwnedInstances, index)
							break
						end
					end
				end
			end
			warn("[RaidService] Victim left mid-theft; stolen instance "
				.. tostring(instanceId) .. " destroyed instead of kept by the thief")
		end
	end
	local placed = {
		InstanceId = instanceId,
		CharacterId = record.CharacterId,
		Slot = record.Slot,
		Level = record.Level,
		Glitched = record.Glitched,
		BankedIncome = 0,
		PlacedAt = os.time(),
	}
	if victim and victim.Parent then
		reinsertPlaced(victim, placed)
		alertSteal(victim, thief, record.CharacterId, "Returned")
	end
	print(string.format("[RaidService] Stolen %s returned to %s", instanceId, victim and victim.Name or "?"))
	return true
end

-- DropStolen(thief): CarryService calls this when the thief drops what
-- they carry; every in-transit item of that thief returns home.
function RaidService.DropStolen(thief: Player)
	if not thief then
		return
	end
	local toReturn: { string } = {}
	for instanceId, record in pairs(_inTransit) do
		if record.Thief == thief then
			table.insert(toReturn, instanceId)
		end
	end
	for _, instanceId in ipairs(toReturn) do
		RaidService.ReturnStolen(instanceId)
	end
end

-- ConfirmDelivery(thief, instanceId): the thief placed the stolen
-- Brainrot in their OWN base — ownership transfers now, and only now.
function RaidService.ConfirmDelivery(thief: Player, instanceId: string): (boolean, string?)
	local record = _inTransit[instanceId]
	if not record or record.Thief ~= thief then
		return false, "not carrying that Brainrot"
	end
	_inTransit[instanceId] = nil
	local victim = record.Victim
	if thief.Character then
		thief.Character:SetAttribute("CarryingStolen", "")
	end
	-- Transfer ownership: the OwnedInstances record already moved to
	-- the thief at steal time (in-transit hold); delivery only confirms
	-- it. The thief also gains the character in their Unlocked set so
	-- the shop / character systems agree they own it.
	-- Steal reward (v1.0.0 never paid it, even though Config promises
	-- "thief keeps half the victim's stored income"): half the banked
	-- income of that Brainrot + a rarity-scaled bonus, paid on delivery
	-- only — failed thefts pay nothing.
	local reward = Economy.StealReward(record.CharacterId, tonumber(record.BankedIncome) or 0)
	if reward > 0 then
		pcall(function()
			_dataService.AddCoins(thief, reward)
		end)
	end
	pcall(function()
		_dataService.UnlockCharacter(thief, record.CharacterId)
	end)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(victim)
			_dataService.SaveData(thief)
		end)
	end)
	if victim and victim.Parent then
		alertSteal(victim, thief, record.CharacterId, "Delivered")
	end
	recordQuest(thief, "steal_success", 1)
	print(string.format(
		"[RaidService] Theft complete: %s stole %s from %s",
		thief.Name, record.CharacterId, victim and victim.Name or "?"
	))
	return true, nil
end

-- StealBrainrot(thief, victimUserId, instanceId): full server-side flow.
function RaidService.StealBrainrot(thief: Player, victimUserId: any, instanceId: any): (boolean, string?)
	if not thief or not thief:IsA("Player") then
		return false, "invalid thief"
	end
	local cleanInstance = sanitize(instanceId)
	local victimId = tonumber(victimUserId)
	if not cleanInstance or not victimId then
		return false, "invalid target"
	end
	local victim = Players:GetPlayerByUserId(victimId)
	if not victim then
		return false, "victim must be online"
	end
	if victim == thief then
		return false, "cannot steal from yourself"
	end
	local thiefData = getData(thief)
	if not thiefData then
		return false, "no data"
	end
	local thiefCharacter = thief.Character
	local thiefHumanoid = thiefCharacter and thiefCharacter:FindFirstChildOfClass("Humanoid")
	if not thiefHumanoid or thiefHumanoid.Health <= 0 then
		return false, "not alive"
	end
	local thiefPos = getCharacterPosition(thief)
	if not thiefPos then
		return false, "no position"
	end
	-- Thief must be inside the victim's base: within 25 studs of any
	-- of the victim's placed pedestals (ground truth for base
	-- location), or the base plot / victim as fallback when no
	-- pedestals are known.
	local pedestals = getPlacedPositions(victim)
	local inBase = false
	if #pedestals > 0 then
		for _, pos in ipairs(pedestals) do
			if (thiefPos - pos).Magnitude <= 25 then
				inBase = true
				break
			end
		end
	else
		local basePos = getBasePosition(victim)
		if basePos then
			inBase = (thiefPos - basePos).Magnitude <= 25
		else
			local victimPos = getCharacterPosition(victim)
			inBase = victimPos ~= nil and (thiefPos - victimPos).Magnitude <= 20
		end
	end
	if not inBase then
		return false, "must be inside the victim's base"
	end
	-- Gate / lockdown entry check.
	local canEnter, enterReason = RaidService.CanEnter(thief, victim)
	if not canEnter then
		return false, enterReason
	end
	-- Per thief-victim cooldown (60s).
	local pairKey = tostring(thief.UserId) .. ":" .. tostring(victim.UserId)
	local lastAttempt = _pairCooldowns[pairKey] or -math.huge
	if os.clock() - lastAttempt < STEAL_COOLDOWN then
		return false, "steal on cooldown"
	end
	-- Protection checks.
	local placed = findPlaced(victim, cleanInstance)
	local protected, reason = RaidService.IsProtected(victim, placed)
	if protected then
		_pairCooldowns[pairKey] = os.clock()
		RaidService.RecordDefense(victim)
		return false, reason
	end

	-- CarryService validation hook (placed + not locked + close to the
	-- pedestal + thief not already carrying). Pure validation.
	if _carryService and type(_carryService.TryPickupStolen) == "function" then
		local ok, valid, reason = pcall(function()
			return _carryService.TryPickupStolen(thief, cleanInstance, victim)
		end)
		if ok and not valid then
			return false, tostring(reason or "cannot pick up that Brainrot")
		end
	end

	-- Channel: 3s, thief must stay within 8 studs of the anchor (the
	-- target's pedestal when known, else the base plot / victim).
	local anchor: Vector3? = nil
	if _baseService and type(_baseService.GetPlacedPosition) == "function" then
		local ok, pos = pcall(function()
			return _baseService.GetPlacedPosition(victim, cleanInstance)
		end)
		if ok and typeof(pos) == "Vector3" then
			anchor = pos
		end
	end
	local anchorPos = anchor or getBasePosition(victim) or getCharacterPosition(victim) or thiefPos
	_pairCooldowns[pairKey] = os.clock()
	alertSteal(victim, thief, placed.CharacterId, "Started")
	local channel = {
		Thief = thief,
		Victim = victim,
		InstanceId = cleanInstance,
		Placed = placed,
		Anchor = anchorPos,
		StartedAt = os.clock(),
		Cancelled = false,
	}
	_channels[thief] = channel
	local channelOk = true
	local waited = 0
	while waited < STEAL_CHANNEL do
		task.wait(0.1)
		waited += 0.1
		if channel.Cancelled or _channels[thief] ~= channel then
			channelOk = false
			break
		end
		local current = thief.Character
		local currentHumanoid = current and current:FindFirstChildOfClass("Humanoid")
		local currentPos = getCharacterPosition(thief)
		if not currentHumanoid or currentHumanoid.Health <= 0 or not currentPos then
			channelOk = false
			break
		end
		if (currentPos - anchorPos).Magnitude > CHANNEL_RADIUS then
			channelOk = false -- moving cancels the channel
			break
		end
	end
	_channels[thief] = nil
	if not channelOk then
		-- Failed theft: thief stunned 3s + the 60s cooldown stands.
		applyStun(thief, 3)
		alertSteal(victim, thief, placed.CharacterId, "Failed")
		return false, "channel interrupted"
	end
	-- Re-check protections AFTER the channel: the victim may have
	-- raised a shield or triggered lockdown during the 3s. v1.0.0
	-- checked only before the channel, so a mid-channel lockdown was
	-- ignored and the steal succeeded anyway.
	local stillProtected, protectionReason = RaidService.IsProtected(victim, placed)
	if stillProtected then
		alertSteal(victim, thief, placed.CharacterId, "Failed")
		return false, protectionReason
	end

	-- Success: remove from the victim's base, mark in transit. The
	-- Brainrot is NOT the thief's yet — see ConfirmDelivery.
	local removed = removePlaced(victim, cleanInstance)
	if not removed then
		return false, "target no longer placed"
	end
	_inTransit[cleanInstance] = {
		Thief = thief,
		Victim = victim,
		CharacterId = placed.CharacterId,
		Level = tonumber(placed.Level) or 1,
		Mutation = placed.Mutation,
		Glitched = placed.Glitched == true,
		Slot = tonumber(placed.Slot) or 0,
		PlacedAt = tonumber(placed.PlacedAt) or os.time(),
		BankedIncome = tonumber(placed.BankedIncome) or 0,
		StolenAt = os.clock(),
	}
	if thief.Character then
		thief.Character:SetAttribute("CarryingStolen", cleanInstance)
	end
	-- Carry it for real (visual + slow) so BaseService.PlaceBrainrot
	-- accepts it in the thief's own base. Prefer SetCarried: unlike
	-- ForceCarry it marks the carry Stolen, so a manual drop or death
	-- routes the Brainrot back to the victim through
	-- RaidService.DropStolen instead of dropping it as a world pickup
	-- anyone could grab. v1.0.0 used ForceCarry, so the stolen-carry
	-- drop path was a world pickup until the 5s poll noticed.
	if _carryService and type(_carryService.SetCarried) == "function" then
		pcall(function()
			_carryService.SetCarried(thief, placed)
		end)
	elseif _carryService and type(_carryService.ForceCarry) == "function" then
		pcall(function()
			_carryService.ForceCarry(thief, placed)
		end)
	end
	-- In-transit hold: move the OwnedInstances record to the thief so
	-- the instance can be placed in their base. ReturnStolen moves it
	-- back if the thief dies or drops it before delivering.
	moveOwnedRecord(victim, thief, cleanInstance)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(victim)
		end)
	end)
	alertSteal(victim, thief, placed.CharacterId, "Success")
	print(string.format(
		"[RaidService] %s stole %s from %s (in transit)",
		thief.Name, placed.CharacterId, victim.Name
	))
	return true, cleanInstance
end

local function onSteal(thief: Player, payload: any)
	if not thief or not thief:IsA("Player") then
		return
	end
	if not rateOk(thief, "StealBrainrot", 1) then
		return
	end
	local victimUserId: any = nil
	local instanceId: any = nil
	if type(payload) == "table" then
		victimUserId = payload.VictimUserId or payload.Victim
		instanceId = payload.InstanceId
	elseif type(payload) == "string" then
		instanceId = payload
	end
	local ok, err = RaidService.StealBrainrot(thief, victimUserId, instanceId)
	if not ok then
		warn("[RaidService] Steal failed for " .. thief.Name .. ": " .. tostring(err))
	end
end

function RaidService.Init(dataService: any, baseService: any?, carryService: any?, opts: any?)
	assert(dataService ~= nil, "[RaidService] Init requires DataService")
	_dataService = dataService
	-- GameManager's generic Init passes EconomyService / the map
	-- positionally; only accept arguments implementing the expected
	-- interface. The real services arrive via the setters above.
	if baseService and type(baseService.GetPlaced) == "function" then
		_baseService = baseService
	end
	if carryService
		and (type(carryService.ForceCarry) == "function" or type(carryService.DropCarried) == "function")
	then
		_carryService = carryService
	end
	if type(opts) == "table" then
		if opts.MutationService and type(opts.MutationService.MoveInstance) == "function" then
			_mutationService = opts.MutationService
		end
		if opts.QuestService and type(opts.QuestService.RecordEvent) == "function" then
			_questService = opts.QuestService
		end
	end

	-- A thief who dies while carrying a stolen Brainrot loses it: it
	-- returns to the victim's base slot.
	local function hookDeath(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid then
				humanoid.Died:Connect(function()
					RaidService.DropStolen(player)
				end)
			end
		end)
	end
	Players.PlayerAdded:Connect(hookDeath)
	-- Players already in-game when this service initialises (server
	-- reload) never fire PlayerAdded: hook them too, or their deaths
	-- would only be caught by the 5s poll. v1.0.0 missed them.
	for _, player in ipairs(Players:GetPlayers()) do
		hookDeath(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		_channels[player] = nil
		_rate[player] = nil
		RaidService.DropStolen(player)
	end)

	-- In-transit watchdog: delivery / drop detection (see PollInTransit).
	task.spawn(function()
		while true do
			task.wait(5)
			local ok, err = pcall(function()
				RaidService.PollInTransit()
			end)
			if not ok then
				warn("[RaidService] In-transit poll failed: " .. tostring(err))
			end
		end
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(_names.StealBrainrot)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onSteal)
		else
			warn("[RaidService] StealBrainrot remote not found, steal handler not wired")
		end
	end)
end

return RaidService
