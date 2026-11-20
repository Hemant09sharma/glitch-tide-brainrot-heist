--!strict
-- BaseService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Owns the personal base plots (Config.MaxBasePlots, 12 when set):
-- assignment on join, placing Brainrots on pedestals, passive income
-- (per-second tick into pending BankedIncome, banked into Coins via
-- CollectIncome), and all base upgrades.
-- Server-authoritative: slot, price, ownership and distance are all
-- checked here; the client only requests. Placed Brainrots persist in
-- player data and their physical models are rebuilt on rejoin.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require("../shared/Config")
local Characters = require("../shared/Characters")
local Remotes = require("../shared/Remotes")

local MapBuilder = require("./MapBuilderStub")

local BaseService = {}

local _dataService: any = nil
local _carryService: any = nil
local _mutationService: any = nil
local _raidService: any = nil
local _progressionService: any = nil
local _eventService: any = nil
local _economyService: any = nil
local _tideMultiplier = 1
local _running = false

local _plotOwner: { [number]: Player } = {} -- plot index -> owner
local _playerPlot: { [Player]: number } = {}
local _placedModels: { [Player]: { [string]: Model } } = {}
local _placedBaseCF: { [Player]: { [string]: CFrame } } = {}
local _placedPhase: { [Player]: { [string]: number } } = {}
-- R3-8: per-action throttle. This used to be ONE shared timestamp
-- per player across all five remote handlers, so two different
-- legitimate actions inside 250 ms (Collect then Store, Place then
-- Upgrade) silently dropped the second with no client feedback — the
-- handlers just return. Each action now has its own 250 ms budget;
-- a single action is still capped at 4/s per player, and every
-- action is server-validated, so splitting the budget cannot mint
-- anything. A burst of five different actions in one instant is
-- still possible, but each is validated independently.
local _lastCall: { [Player]: { [string]: number } } = {}

local MIN_CALL_INTERVAL = 0.25
local PLACE_DISTANCE = 12
-- v1.1 Wave 2 (Workstream C, fix 8c): the banked-income cap. The old
-- flat BANKED_CAP = 10,000 filled in under a second at top-tier
-- incomes (Void Vulture 11,000/s, Wobble King 18,000/s — audit §3
-- F11), so high-tier owners lost everything unless they collected
-- constantly. The cap now scales with progression (see bankedCapFor
-- below) — still a real cap, not infinite: base 100,000 + 5,000 per
-- level + 10,000 per rebirth + 25,000 per prestige rank. A level-1
-- player caps at 105,000 (hours of their income — the cap never binds
-- early); a level-25, 10-rebirth player caps at 325,000 (roughly a
-- minute of a strong endgame base — CollectIncome still matters).
local BANKED_CAP_BASE = 100000
local UPGRADE_KINDS = { "BaseSlot", "IncomeMultiplier", "Lock", "Turret", "ConveyorLuck" }

local _economyMod: any = nil
do
	local ok, mod = pcall(function()
		return require("../shared/Economy")
	end)
	if ok then
		_economyMod = mod
	end
end

local _synergiesMod: any = nil
do
	local found = ReplicatedStorage:FindFirstChild("Synergies")
	if found then
		local ok, mod = pcall(require, found)
		if ok then
			_synergiesMod = mod
		end
	end
end

-- Shared Mutations table (IncomeMultiplier per mutation id).
local _mutationsMod: any = nil
do
	local found = ReplicatedStorage:FindFirstChild("Mutations")
	if found then
		local ok, mod = pcall(require, found)
		if ok then
			_mutationsMod = mod
		end
	end
end

local _characterModels: any = nil
do
	local found = ReplicatedStorage:FindFirstChild("CharacterModels")
	if found then
		local ok, mod = pcall(require, found)
		if ok then
			_characterModels = mod
		end
	end
end

local function buildModelFor(def: any, scale: number): Model
	if _characterModels ~= nil then
		for _, fnName in ipairs({ "Build", "BuildModel", "BuildCharacter" }) do
			local fn = _characterModels[fnName]
			if type(fn) == "function" then
				local ok, model = pcall(fn, def)
				if ok and typeof(model) == "Instance" and model:IsA("Model") then
					return model
				end
				local ok2, model2 = pcall(fn, def.Id)
				if ok2 and typeof(model2) == "Instance" and model2:IsA("Model") then
					return model2
				end
			end
		end
	end
	local model = Instance.new("Model")
	model.Name = tostring(def.DisplayName or def.Id)
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2 * scale, 2.4 * scale, 2 * scale)
	body.Color = (def.Color :: Color3)
	body.Material = Enum.Material.SmoothPlastic
	body.Anchored = true
	body.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.6 * scale, 1.4 * scale, 1.6 * scale)
	head.Color = (def.AccentColor :: Color3)
	head.Material = Enum.Material.SmoothPlastic
	head.Anchored = true
	head.Parent = model
	body.CFrame = CFrame.new(0, 1.2 * scale, 0)
	head.CFrame = CFrame.new(0, 3.1 * scale, 0)
	model.PrimaryPart = body
	return model
end

local function getRemotesFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local ok, found = pcall(function()
		return ReplicatedStorage:WaitForChild("Remotes", 5)
	end)
	if ok and typeof(found) == "Instance" then
		return found :: Folder
	end
	return nil
end

local function getEvent(name: string): RemoteEvent?
	local folder = getRemotesFolder()
	if folder == nil then
		return nil
	end
	local child = folder:FindFirstChild(name)
	if child and child:IsA("RemoteEvent") then
		return child
	end
	return nil
end

local function getFunction(name: string): RemoteFunction?
	local folder = getRemotesFolder()
	if folder == nil then
		return nil
	end
	local child = folder:FindFirstChild(name)
	if child and child:IsA("RemoteFunction") then
		return child
	end
	return nil
end

local function rateLimited(player: Player, action: string): boolean
	local now = os.clock()
	local perPlayer = _lastCall[player]
	if perPlayer == nil then
		perPlayer = {}
		_lastCall[player] = perPlayer
	end
	local last = perPlayer[action] or 0
	if now - last < MIN_CALL_INTERVAL then
		return true
	end
	perPlayer[action] = now
	return false
end

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return (root :: BasePart).Position
end

-- R5-2 (P0): session-health gate for the player-driven place/store
-- paths. A session that cannot save (load failed, contested, lost —
-- the R5-4 GetSaveBlockedReason state) must not change
-- which Brainrots are placed: the change would live only in memory
-- until the next save refuses, and on rejoin the stored profile
-- disagrees with what the player saw. The check is LOCAL only (no
-- DataStore call): placing/storing your own Brainrot transfers
-- nothing between players, so the worst case of a merely-stale
-- local view is a lost placement, not a lost or duplicated
-- instance — the stored-lease probe is reserved for the steal /
-- delivery commit points in RaidService, where an unverified lease
-- can do real damage. When DataService has no session API (older
-- DataService / test stub), the gate is skipped (healthy fallback).
-- EXEMPT: the whole-record reinsert shape of PlaceBrainrot (a
-- table, not a string id) — that is the server-side recovery
-- restore RaidService.ReturnStolen / RecoverStaleTransit use, and
-- blocking it would strand the Brainrot the gate exists to protect.
local function sessionBlockedReason(player: Player): string?
	-- The R5-4 reason API is the ONLY local signal the gate
	-- consults. For the real DataService it is exactly equivalent
	-- to IsSaveable (GetSaveBlockedReason, DataService.luau:721,
	-- returns non-nil iff one of _loadFailed / _sessionContested /
	-- _sessionLost is set; IsSaveable, :2240, is false iff one of
	-- the same three flags is set), so nothing is lost by reading
	-- the reason instead of the boolean. A DataService WITHOUT the
	-- reason API (older / stub) falls back to healthy — the same
	-- established fallback the RaidService gate uses, and the one
	-- the theft/lifecycle suites rely on for their R2-4/R3-5
	-- reward-pending behaviour.
	if _dataService == nil then
		return nil
	end
	if type(_dataService.GetSaveBlockedReason) == "function" then
		local ok, reason = pcall(function()
			return _dataService.GetSaveBlockedReason(player)
		end)
		if ok and type(reason) == "string" and reason ~= "" then
			return reason
		end
	end
	return nil
end

-- Lazily create the heist fields DataService's default data lacks.
local function ensureBaseData(data: any): any
	-- The owned-instance registry is data.OwnedInstances (shared with
	-- MutationService); never a second list.
	if type(data.OwnedInstances) ~= "table" then
		data.OwnedInstances = {}
	end
	if type(data.BankedIncome) ~= "number" then
		data.BankedIncome = 0
	end
	if type(data.Base) ~= "table" then
		data.Base = {
			OwnerUserId = 0,
			Slots = tonumber(Config.BaseSlotsStart) or 4,
			IncomeMultiplier = tonumber(Config.BaseIncomeMultiplierStart) or 1,
			IncomeMultiplierLevel = 0,
			LockLevel = 0,
			TurretLevel = 0,
			ConveyorLuckLevel = 0,
			LockedUntil = 0,
			Placed = {},
			StoredCoins = 0,
			TotalEarned = 0,
		}
	end
	local base = data.Base
	if type(base.Placed) ~= "table" then
		base.Placed = {}
	end
	if type(base.Slots) ~= "number" then
		base.Slots = tonumber(Config.BaseSlotsStart) or 4
	end
	if type(base.IncomeMultiplier) ~= "number" then
		base.IncomeMultiplier = 1
	end
	if type(base.IncomeMultiplierLevel) ~= "number" then
		base.IncomeMultiplierLevel = 0
	end
	if type(base.LockLevel) ~= "number" then
		base.LockLevel = 0
	end
	if type(base.TurretLevel) ~= "number" then
		base.TurretLevel = 0
	end
	if type(base.ConveyorLuckLevel) ~= "number" then
		base.ConveyorLuckLevel = 0
	end
	if type(base.LockedUntil) ~= "number" then
		base.LockedUntil = 0
	end
	return base
end

local function findOwned(data: any, instanceId: string): { [string]: any }?
	if type(data.OwnedInstances) ~= "table" then
		return nil
	end
	for _, record in ipairs(data.OwnedInstances) do
		if record.InstanceId == instanceId then
			return record
		end
	end
	return nil
end

-- Keep MutationService's Placed flag in sync (its documented contract:
-- BaseService calls SetPlaced on place / remove). The record itself is
-- also flagged directly, so this is a no-op if the service is absent.
local function syncPlacedFlag(player: Player, instanceId: string, placed: boolean, slot: number): ()
	if _mutationService ~= nil and type(_mutationService.SetPlaced) == "function" then
		pcall(function()
			_mutationService.SetPlaced(player, instanceId, placed, slot)
		end)
	end
	local data = _dataService.GetData(player)
	if data ~= nil then
		local owned = findOwned(data, instanceId)
		if owned ~= nil then
			owned.Placed = placed == true
			owned.Slot = placed == true and slot or 0
		end
	end
end

-- Income multiplier for one mutation id, resolved case-insensitively
-- against the shared Mutations table (MutationService stores ids
-- lowercase, e.g. "golden"; the shared table keys them "Golden").
-- A "Glitched" mutation pays nothing extra here: the Glitched flag
-- already doubles income, and the mutation is the same effect under
-- another name. Unknown ids (e.g. MutationService's "Magma" /
-- "Spectral", absent from the shared table) pay 1 — that table drift
-- lives in MutationService, not in this formula.
local function mutationIncomeMultiplier(mutationId: any, glitched: boolean): number
	if type(mutationId) ~= "string" or mutationId == "" then
		return 1
	end
	if _mutationsMod ~= nil and type(_mutationsMod.GetAll) == "function" then
		local ok, list = pcall(_mutationsMod.GetAll)
		if ok and type(list) == "table" then
			for _, def in ipairs(list) do
				if type(def.Id) == "string" and string.lower(def.Id) == string.lower(mutationId) then
					if def.Id == "Glitched" and glitched then
						return 1
					end
					if type(def.IncomeMultiplier) == "number" then
						return def.IncomeMultiplier
					end
					return 1
				end
			end
		end
	end
	if _mutationsMod ~= nil and type(_mutationsMod.GetById) == "function" then
		for _, candidate in ipairs({ mutationId, string.lower(mutationId) }) do
			local ok, def = pcall(_mutationsMod.GetById, candidate)
			if ok and type(def) == "table" and type(def.IncomeMultiplier) == "number" then
				if candidate == "Glitched" and glitched then
					return 1
				end
				return def.IncomeMultiplier
			end
		end
	end
	return 1
end

-- v1.1 companion MutationBonus: an extra fraction on the income of
-- MUTATED Brainrots only (CompanionService.GetMutationIncomeBonus,
-- max +0.15). Resolved lazily like the other sibling services; 0
-- when CompanionService is absent or errors.
local _companionService: any = nil
local _companionResolved = false
local function companionMutationBonus(player: Player): number
	if not _companionResolved then
		_companionResolved = true
		pcall(function()
			local mod = script.Parent:FindFirstChild("CompanionService")
			if mod then
				local svc = require(mod)
				if type(svc.GetMutationIncomeBonus) == "function" then
					_companionService = svc
				end
			end
		end)
	end
	if _companionService == nil then
		return 0
	end
	local ok, bonus = pcall(_companionService.GetMutationIncomeBonus, player)
	if ok and type(bonus) == "number" then
		return math.clamp(bonus, 0, 0.15)
	end
	return 0
end

local function applyCompanionMutationBonus(player: Player, mutation: any, income: number): number
	if type(mutation) ~= "string" or mutation == "" then
		return income
	end
	local bonus = companionMutationBonus(player)
	if bonus <= 0 then
		return income
	end
	return income * (1 + bonus)
end

local function findPlaced(base: any, instanceId: string): (number?, { [string]: any }?)
	for i, record in ipairs(base.Placed) do
		if record.InstanceId == instanceId then
			return i, record
		end
	end
	return nil, nil
end

local function upgradeCost(kind: string, level: number): number?
	if _economyMod ~= nil and type(_economyMod.UpgradeCost) == "function" then
		local ok, cost = pcall(_economyMod.UpgradeCost, kind, level)
		if ok and type(cost) == "number" then
			return cost
		end
	end
	local tableRef: { number }? = nil
	if kind == "BaseSlot" then
		tableRef = Config.BaseSlotCost
	elseif kind == "IncomeMultiplier" then
		tableRef = Config.IncomeMultiplierCost
	elseif kind == "Lock" then
		tableRef = Config.LockCost
	elseif kind == "Turret" then
		tableRef = Config.TurretCost
	elseif kind == "ConveyorLuck" then
		tableRef = Config.ConveyorLuckCost
	end
	if tableRef == nil then
		return nil
	end
	local index = math.floor(level) + 1
	if index < 1 or index > #tableRef then
		return nil
	end
	return tableRef[index]
end

-- Income for one placed Brainrot. The live OwnedInstances record wins
-- for Level / Glitched / Mutation (a mutation applied after placing
-- must change income without a re-place); the placed copy is the fallback.
-- Economy.IncomePerSecond already applies level, the glitched x2 and
-- the mutation multiplier exactly once — this function must NOT multiply
-- by the mutation again (the old code did, paying Golden 6.25x instead
-- of 2.5x and glitched Brainrots 4x instead of 2x). The manual fallback
-- mirrors the same single-application math.
local function singleIncome(player: Player, placed: { [string]: any }): number
	local level = math.floor(tonumber(placed.Level) or 1)
	local glitched = placed.Glitched == true
	local mutation = placed.Mutation
	local data = _dataService.GetData(player)
	if data ~= nil then
		local owned = findOwned(data, placed.InstanceId)
		if owned ~= nil then
			level = math.floor(tonumber(owned.Level) or level)
			glitched = owned.Glitched == true
			mutation = owned.Mutation
		end
	end
	if _economyMod ~= nil and type(_economyMod.IncomePerSecond) == "function" then
		local ok, income = pcall(_economyMod.IncomePerSecond, {
			CharacterId = placed.CharacterId,
			Level = level,
			Glitched = glitched,
			Mutation = mutation,
		})
		if ok and type(income) == "number" then
			return applyCompanionMutationBonus(player, mutation, income)
		end
	end
	local def = Characters.GetById(placed.CharacterId)
	if def == nil then
		return 0
	end
	local clampedLevel = math.clamp(level, 1, tonumber(Config.MaxBrainrotLevel) or 5)
	local income = def.IncomePerSec * (1 + (clampedLevel - 1) * (tonumber(Config.BrainrotLevelIncomeBonus) or 0.25))
	if glitched then
		income *= 2
	end
	return applyCompanionMutationBonus(player, mutation, income * mutationIncomeMultiplier(mutation, glitched))
end

-- Event income multiplier: Golden Hour pays 2x while active
-- (EventService.GetIncomeMultiplier). Prefers EventService when wired
-- (SetEventService); otherwise 1. This is a SEPARATE multiplier from
-- the tide multiplier (_tideMultiplier, set via SetTideMultiplier by
-- GameManager when the Glitch Tide runs) — the two stack, and neither
-- is applied twice.
local function eventIncomeMultiplier(): number
	if _eventService ~= nil and type(_eventService.GetIncomeMultiplier) == "function" then
		local ok, value = pcall(_eventService.GetIncomeMultiplier)
		if ok and type(value) == "number" and value > 0 then
			return value
		end
	end
	return 1
end

-- Rebirth income multiplier: Config is the SINGLE source of truth —
-- +10% per rebirth (Config.RebirthRequirements.IncomeBonusPerRebirth).
-- Prefers ProgressionService when wired (SetProgressionService); its
-- GetIncomeMultiplier reads the same Config value, plus prestige
-- (+5%/rank) and mastery bonuses. Otherwise reads data.Rebirths with
-- the SAME +10% step, plus the +5% per prestige rank mirror
-- (ProgressionService.PRESTIGE_INCOME_PER_RANK). v1.0.2 fell back to
-- +25% here and its comment called Config's 0.10 "stale and unused" —
-- that was wrong: live behaviour was +10% when wired and +25% when
-- not, a silent 2.5x divergence depending on load order (audit §3
-- F2). Both paths now agree at +10%.
local function rebirthIncomeMultiplier(player: Player): number
	if _progressionService ~= nil and type(_progressionService.GetIncomeMultiplier) == "function" then
		local ok, value = pcall(_progressionService.GetIncomeMultiplier, player)
		if ok and type(value) == "number" and value > 0 then
			return value
		end
	end
	local data = _dataService.GetData(player)
	local rebirths = data ~= nil and (tonumber(data.Rebirths) or 0) or 0
	local prestige = data ~= nil and (tonumber(data.Prestige) or 0) or 0
	local perRebirth = 0.10
	if Config.RebirthRequirements and tonumber(Config.RebirthRequirements.IncomeBonusPerRebirth) then
		perRebirth = tonumber(Config.RebirthRequirements.IncomeBonusPerRebirth) :: number
	end
	return 1 + math.max(0, rebirths) * perRebirth + math.max(0, prestige) * 0.05
end

-- Banked-income cap for a player (fix 8c — see BANKED_CAP_BASE).
local function bankedCapFor(player: Player): number
	local data = _dataService.GetData(player)
	local level = data ~= nil and (tonumber(data.Level) or 1) or 1
	local rebirths = data ~= nil and (tonumber(data.Rebirths) or 0) or 0
	local prestige = data ~= nil and (tonumber(data.Prestige) or 0) or 0
	return BANKED_CAP_BASE + level * 5000 + rebirths * 10000 + prestige * 25000
end

-- Companion income multiplier (v1.1 Wave 1/2, fix 8a): the EconomyService
-- hook B documented — EconomyService.GetCompanionIncomeMultiplier
-- returns 1 + the player's capped companion IncomeBonus (max 1.25),
-- or 1 when no companion service is linked. Resolved lazily from the
-- sibling module so no GameManager edit is needed; SetEconomyService
-- below lets the integrator wire it explicitly instead.
local function resolveEconomyService(): any
	if _economyService ~= nil then
		return _economyService
	end
	pcall(function()
		local mod = script.Parent:FindFirstChild("EconomyService")
		if mod then
			local candidate = require(mod)
			if type(candidate.GetCompanionIncomeMultiplier) == "function" then
				_economyService = candidate
			end
		end
	end)
	return _economyService
end

-- Effective pedestal slots: bought slots plus the rebirth bonus
-- (+2 per rebirth, ProgressionService.GetBaseSlots), capped at the
-- pedestals the plot physically has.
local function effectiveSlots(player: Player, base: any): number
	local slots = tonumber(base.Slots) or (tonumber(Config.BaseSlotsStart) or 4)
	local data = _dataService.GetData(player)
	local rebirths = data ~= nil and (tonumber(data.Rebirths) or 0) or 0
	slots += math.max(0, rebirths) * 2
	local cap = tonumber(Config.BaseSlotsMax) or 10
	local plotIndex = _playerPlot[player]
	if plotIndex ~= nil then
		local plot = MapBuilder.GetBasePlot(plotIndex)
		if plot ~= nil and type(plot.Pedestals) == "table" then
			local count = 0
			for _ in pairs(plot.Pedestals) do
				count += 1
			end
			if count > 0 then
				cap = math.min(cap, count)
			end
		end
	end
	return math.min(slots, cap)
end

function BaseService.GetIncomePerSec(player: Player): number
	local data = _dataService.GetData(player)
	if data == nil then
		return 0
	end
	local base = ensureBaseData(data)
	local total = 0
	local characterIds: { string } = {}
	for _, placed in ipairs(base.Placed) do
		total += singleIncome(player, placed)
		table.insert(characterIds, placed.CharacterId)
	end
	total *= tonumber(base.IncomeMultiplier) or 1
	total *= _tideMultiplier
	total *= eventIncomeMultiplier()
	total *= rebirthIncomeMultiplier(player)
	-- Synergy bonus: Synergies.GetSynergyBonusForCharacters takes
	-- character ids and returns a fraction (0.35 = +35%).
	if _synergiesMod ~= nil and type(_synergiesMod.GetSynergyBonusForCharacters) == "function" then
		local ok, bonus = pcall(_synergiesMod.GetSynergyBonusForCharacters, characterIds)
		if ok and type(bonus) == "number" and bonus > 0 then
			total *= (1 + bonus)
		end
	end
	-- Companion income (v1.1 Wave 1/2, fix 8a — the one-liner B
	-- documented): multiply by EconomyService's companion income
	-- multiplier (1 + capped companion IncomeBonus, max 1.25; 1 when
	-- no companion service is linked, so unwired servers are
	-- unaffected).
	local economyService = resolveEconomyService()
	if economyService ~= nil and type(economyService.GetCompanionIncomeMultiplier) == "function" then
		local ok, mult = pcall(economyService.GetCompanionIncomeMultiplier, player)
		if ok and type(mult) == "number" and mult > 0 then
			total *= mult
		end
	end
	return total
end

function BaseService.GetBase(player: Player): { [string]: any }?
	local data = _dataService.GetData(player)
	if data == nil then
		return nil
	end
	local base = ensureBaseData(data)
	local placedCopy: { { [string]: any } } = {}
	for _, placed in ipairs(base.Placed) do
		local def = Characters.GetById(placed.CharacterId)
		table.insert(placedCopy, {
			InstanceId = placed.InstanceId,
			CharacterId = placed.CharacterId,
			Name = def and def.DisplayName or tostring(placed.CharacterId),
			Rarity = def and def.Rarity or "Common",
			Slot = placed.Slot,
			Level = placed.Level,
			Glitched = placed.Glitched,
			Mutation = placed.Mutation,
			BankedIncome = placed.BankedIncome or 0,
		})
	end
	-- Unplaced inventory (v1.0.1 integration QA): FusionService only
	-- fuses UNPLACED instances, but the client never saw them — the
	-- snapshot carried placed Brainrots only, so the Fusion tab had no
	-- InstanceIds to fire FuseBrainrot with. Expose the unplaced
	-- instances (read-only copy) so the Shop's Fusion tab can list
	-- them. Placed instances are NOT included here; they are rejected
	-- by FusionService with "instance is placed".
	local unplacedCopy: { { [string]: any } } = {}
	if _mutationService ~= nil and type(_mutationService.GetInstances) == "function" then
		local ok, instances = pcall(_mutationService.GetInstances, player)
		if ok and type(instances) == "table" then
			for _, inst in ipairs(instances) do
				if type(inst) == "table" and inst.Placed ~= true then
					local def = Characters.GetById(inst.CharacterId)
					table.insert(unplacedCopy, {
						InstanceId = inst.InstanceId,
						CharacterId = inst.CharacterId,
						Name = def and def.DisplayName or tostring(inst.CharacterId),
						Rarity = def and def.Rarity or "Common",
						Level = inst.Level or 1,
						Mutation = inst.Mutation,
					})
				end
			end
		end
	end
	return {
		PlotIndex = _playerPlot[player],
		Slots = effectiveSlots(player, base),
		IncomeMultiplier = base.IncomeMultiplier,
		IncomeMultiplierLevel = base.IncomeMultiplierLevel,
		LockLevel = base.LockLevel,
		TurretLevel = base.TurretLevel,
		ConveyorLuckLevel = base.ConveyorLuckLevel,
		LockedUntil = base.LockedUntil,
		IsLocked = os.time() < (tonumber(base.LockedUntil) or 0),
		Placed = placedCopy,
		Unplaced = unplacedCopy,
		BankedIncome = tonumber(data.BankedIncome) or 0,
		IncomePerSec = BaseService.GetIncomePerSec(player),
	}
end

function BaseService.GetPlaced(player: Player): { { [string]: any } }
	local data = _dataService.GetData(player)
	if data == nil then
		return {}
	end
	local base = ensureBaseData(data)
	local copy: { { [string]: any } } = {}
	for _, placed in ipairs(base.Placed) do
		table.insert(copy, placed)
	end
	return copy
end

function BaseService.IsSlotFree(player: Player, slot: number): boolean
	local data = _dataService.GetData(player)
	if data == nil then
		return false
	end
	local base = ensureBaseData(data)
	slot = math.floor(tonumber(slot) or 0)
	if slot < 1 or slot > effectiveSlots(player, base) then
		return false
	end
	for _, placed in ipairs(base.Placed) do
		if tonumber(placed.Slot) == slot then
			return false
		end
	end
	return true
end

function BaseService.GetPlacedPosition(player: Player, instanceId: string): Vector3?
	local plotIndex = _playerPlot[player]
	if plotIndex == nil then
		return nil
	end
	local plot = MapBuilder.GetBasePlot(plotIndex)
	if plot == nil then
		return nil
	end
	local data = _dataService.GetData(player)
	if data == nil then
		return nil
	end
	local base = ensureBaseData(data)
	local _, placed = findPlaced(base, instanceId)
	if placed == nil then
		return nil
	end
	local pedestals = plot.Pedestals :: { [number]: CFrame }
	local cf = pedestals[tonumber(placed.Slot) or 0]
	if cf == nil then
		return plot.Center :: Vector3
	end
	return cf.Position
end

function BaseService.IsLocked(player: Player): boolean
	local data = _dataService.GetData(player)
	if data == nil then
		return false
	end
	local base = ensureBaseData(data)
	return os.time() < (tonumber(base.LockedUntil) or 0)
end

function BaseService.GetConveyorLuckLevel(player: Player): number
	local data = _dataService.GetData(player)
	if data == nil then
		return 0
	end
	return tonumber(ensureBaseData(data).ConveyorLuckLevel) or 0
end

function BaseService.GetMaxConveyorLuck(): number
	local best = 0
	for _, player in ipairs(Players:GetPlayers()) do
		best = math.max(best, BaseService.GetConveyorLuckLevel(player))
	end
	return best
end

function BaseService.SetTideMultiplier(multiplier: number): ()
	_tideMultiplier = math.max(0, tonumber(multiplier) or 1)
end

function BaseService.SetCarryService(carryService: any): ()
	_carryService = carryService
end

function BaseService.SetMutationService(mutationService: any): ()
	_mutationService = mutationService
end

function BaseService.SetRaidService(raidService: any): ()
	_raidService = raidService
end

-- ProgressionService supplies the live rebirth income multiplier
-- (GetIncomeMultiplier — Config's +10%/rebirth, plus prestige and
-- mastery). Wiring is optional: without it, income falls back to
-- data.Rebirths x +10% per rebirth (same step — see
-- rebirthIncomeMultiplier above).
function BaseService.SetProgressionService(progressionService: any): ()
	_progressionService = progressionService
end

-- EconomyService supplies the live companion income multiplier
-- (GetCompanionIncomeMultiplier — 1 + capped companion IncomeBonus).
-- Wiring is optional: without it, BaseService lazily requires the
-- sibling EconomyService module itself (resolveEconomyService), and
-- without any companion service linked the multiplier is 1.
function BaseService.SetEconomyService(economyService: any): ()
	_economyService = economyService
end

-- EventService supplies the live event income multiplier
-- (GetIncomeMultiplier — 2x during Golden Hour, 1 otherwise). Wiring
-- is optional: without it, income falls back to x1 (no event bonus).
function BaseService.SetEventService(eventService: any): ()
	_eventService = eventService
end

-- Centre of the player's base plot (used by RaidService to check the
-- thief is inside the victim's base). Nil when no plot is assigned.
function BaseService.GetBasePosition(player: Player): Vector3?
	local plotIndex = _playerPlot[player]
	if plotIndex == nil then
		return nil
	end
	local plot = MapBuilder.GetBasePlot(plotIndex)
	if plot == nil then
		return nil
	end
	return plot.Center :: Vector3
end

local function fireBaseUpdate(player: Player): ()
	local snapshot = BaseService.GetBase(player)
	if snapshot == nil then
		return
	end
	local remote = getEvent(Remotes.Names.BaseUpdate)
	if remote ~= nil then
		pcall(function()
			remote:FireClient(player, snapshot)
		end)
	end
end

local function setOwnerSign(plotIndex: number, ownerName: string?): ()
	local plot = MapBuilder.GetBasePlot(plotIndex)
	if plot == nil then
		return
	end
	local sign = plot.Sign
	if typeof(sign) ~= "Instance" then
		return
	end
	local gui = (sign :: Instance):FindFirstChild("LabelGui")
	if gui == nil then
		return
	end
	local label = gui:FindFirstChild("Title")
	if label and label:IsA("TextLabel") then
		if ownerName ~= nil and ownerName ~= "" then
			(label :: TextLabel).Text = "BASE " .. tostring(plotIndex) .. "\n" .. ownerName
		else
			(label :: TextLabel).Text = "BASE " .. tostring(plotIndex) .. "\n(unclaimed)"
		end
	end
end

-- -------------------------------------------------------------------------
-- Physical placed models
-- -------------------------------------------------------------------------

local function destroyPlacedModels(player: Player): ()
	local models = _placedModels[player]
	if models ~= nil then
		for _, model in pairs(models) do
			pcall(function()
				model:Destroy()
			end)
		end
	end
	_placedModels[player] = {}
	_placedBaseCF[player] = {}
	_placedPhase[player] = {}
end

local function buildPlacedModel(player: Player, placed: { [string]: any }): ()
	local plotIndex = _playerPlot[player]
	if plotIndex == nil then
		return
	end
	local plot = MapBuilder.GetBasePlot(plotIndex)
	if plot == nil then
		return
	end
	local pedestals = plot.Pedestals :: { [number]: CFrame }
	local cf = pedestals[tonumber(placed.Slot) or 0]
	if cf == nil then
		return
	end
	local def = Characters.GetById(placed.CharacterId)
	if def == nil then
		return
	end
	local model = buildModelFor(def, tonumber(def.Scale) or 1)
	model.Name = "Placed_" .. tostring(placed.InstanceId)
	pcall(function()
		model:PivotTo(cf)
	end)
	-- Anchor everything so the bob loop owns the motion; apply the
	-- mutation look when the placed Brainrot has one.
	if _characterModels ~= nil and type(_characterModels.SetDisplayMode) == "function" then
		pcall(_characterModels.SetDisplayMode, model, true)
	end
	if _characterModels ~= nil and type(_characterModels.ApplyMutation) == "function"
		and type(placed.Mutation) == "string" and placed.Mutation ~= "" then
		pcall(_characterModels.ApplyMutation, model, placed.Mutation)
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end
	model.Parent = Workspace
	if _placedModels[player] == nil then
		_placedModels[player] = {}
	end
	if _placedBaseCF[player] == nil then
		_placedBaseCF[player] = {}
	end
	if _placedPhase[player] == nil then
		_placedPhase[player] = {}
	end
	_placedModels[player][placed.InstanceId] = model
	_placedBaseCF[player][placed.InstanceId] = cf
	_placedPhase[player][placed.InstanceId] = math.random() * math.pi * 2
end

function BaseService.RebuildBase(player: Player): ()
	destroyPlacedModels(player)
	local data = _dataService.GetData(player)
	if data == nil then
		return
	end
	local base = ensureBaseData(data)
	for _, placed in ipairs(base.Placed) do
		pcall(buildPlacedModel, player, placed)
	end
	fireBaseUpdate(player)
end

-- -------------------------------------------------------------------------
-- Assignment
-- -------------------------------------------------------------------------

function BaseService.AssignBase(player: Player): number?
	if _playerPlot[player] ~= nil then
		return _playerPlot[player]
	end
	-- Plot count comes from Config (another worker sets MaxBasePlots
	-- to 12); fall back to 12, never a hardcoded 8. Only assign plots
	-- the map actually built, so a short map can never hand out a
	-- plot with no pedestals.
	local maxPlots = tonumber(Config.MaxBasePlots) or 12
	for i = 1, maxPlots do
		if _plotOwner[i] == nil and MapBuilder.GetBasePlot(i) ~= nil then
			_plotOwner[i] = player
			_playerPlot[player] = i
			local data = _dataService.GetOrLoad(player)
			local base = ensureBaseData(data)
			base.OwnerUserId = player.UserId
			setOwnerSign(i, player.Name)
			print(string.format("[BaseService] Plot %d assigned to %s", i, player.Name))
			return i
		end
	end
	warn("[BaseService] No free base plot for " .. player.Name .. " (all " .. tostring(maxPlots) .. " claimed)")
	return nil
end

function BaseService.ReleaseBase(player: Player): ()
	local plotIndex = _playerPlot[player]
	if plotIndex ~= nil then
		_plotOwner[plotIndex] = nil
		_playerPlot[player] = nil
		setOwnerSign(plotIndex, nil)
	end
	destroyPlacedModels(player)
	_lastCall[player] = nil
end

function BaseService.GetPlotIndex(player: Player): number?
	return _playerPlot[player]
end

-- -------------------------------------------------------------------------
-- Placing / removing
-- -------------------------------------------------------------------------

-- Server-side reinsert of a placed record (RaidService.ReturnStolen
-- restoring a stolen Brainrot to its victim's base). No carry or
-- distance checks: this is a restore, not a player action. Prefers the
-- record's original slot, falls back to the first free slot; the record
-- is always preserved in data even when no pedestal is free.
local function reinsertPlacedRecord(player: Player, record: { [string]: any }): (boolean, any)
	local plotIndex = _playerPlot[player]
	local data = _dataService.GetOrLoad(player)
	local base = ensureBaseData(data)
	local _, existing = findPlaced(base, record.InstanceId)
	if existing ~= nil then
		return true, existing
	end
	-- R3-8 defence-in-depth: a whole-record reinsert must never plant
	-- a Brainrot the player does not own. The only server-side caller
	-- is RaidService's return path (via PlaceBrainrot's table shape),
	-- which moves the owned record back to the victim and clears the
	-- theft markers BEFORE reinserting — so a legitimate return always
	-- passes: the owned record exists, is not in transit, is not
	-- marked stolen from someone else, and its character matches.
	-- Anything else is refused instead of risking a duplicated
	-- Brainrot in a stranger's base. ensureBaseData above guarantees
	-- OwnedInstances is a table by this point (it creates an empty
	-- one for legacy saves), so the check always applies; a legacy
	-- record with no matching owned entry is refused and stays in
	-- inventory — no loss, no duplication — instead of being planted.
	-- Clients can never reach this shape: onPlaceBrainrot stringifies
	-- the instance id first, so a table never arrives from a remote.
	local owned = findOwned(data, record.InstanceId)
	if owned == nil then
		warn("[BaseService] Reinsert refused for " .. player.Name
			.. ": " .. tostring(record.InstanceId) .. " is not in their owned instances")
		return false, "record is not owned by this player"
	end
	if owned.InTransit == true then
		warn("[BaseService] Reinsert refused for " .. player.Name
			.. ": " .. tostring(record.InstanceId) .. " is in transit (stolen)")
		return false, "record is in transit"
	end
	local stolenFrom = tonumber(owned.StolenFromUserId)
	if stolenFrom ~= nil and stolenFrom ~= player.UserId then
		warn("[BaseService] Reinsert refused for " .. player.Name
			.. ": " .. tostring(record.InstanceId) .. " is stolen from another player")
		return false, "record is stolen from another player"
	end
	if owned.CharacterId ~= nil and record.CharacterId ~= nil
		and owned.CharacterId ~= record.CharacterId then
		warn("[BaseService] Reinsert refused for " .. player.Name
			.. ": " .. tostring(record.InstanceId) .. " character does not match owned record")
		return false, "record character does not match owned record"
	end
	local slot = math.floor(tonumber(record.Slot) or 0)
	local maxSlots = effectiveSlots(player, base)
	local buildModel = slot >= 1 and slot <= maxSlots
		and BaseService.IsSlotFree(player, slot)
	if not buildModel then
		slot = 0
		for candidate = 1, maxSlots do
			if BaseService.IsSlotFree(player, candidate) then
				slot = candidate
				buildModel = true
				break
			end
		end
		if slot == 0 then
			-- No pedestal free: keep the record in data at its original
			-- slot so nothing is lost; no model is built for it.
			slot = math.floor(tonumber(record.Slot) or 1)
			buildModel = false
		end
	end
	local placed: { [string]: any } = {
		InstanceId = record.InstanceId,
		CharacterId = record.CharacterId,
		Slot = slot,
		Level = tonumber(record.Level) or 1,
		Glitched = record.Glitched == true,
		Mutation = record.Mutation,
		BankedIncome = tonumber(record.BankedIncome) or 0,
		PlacedAt = tonumber(record.PlacedAt) or os.time(),
	}
	table.insert(base.Placed, placed)
	syncPlacedFlag(player, record.InstanceId, true, slot)
	if plotIndex ~= nil and buildModel then
		pcall(buildPlacedModel, player, placed)
	end
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	fireBaseUpdate(player)
	return true, placed
end

-- Server-side place. Returns (true, placedRecord) or (false, reason).
-- Three call shapes (all server-side, never from the client directly):
--   (player, instanceId: string, slot) — normal place from carry.
--   (player, placedRecord: table)     — RaidService.ReturnStolen
--     restoring a stolen Brainrot to its victim's base (no slot arg).
--   (player, stolenInstanceId, slot)  — the thief placing stolen goods
--     in their own base: ownership transfers first via
--     RaidService.ConfirmDelivery, then the thief's fresh instance is
--     placed on the requested slot.
function BaseService.PlaceBrainrot(player: Player, instanceId: any, slot: any): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	-- Shape 2: server-side reinsert of a whole placed record.
	-- R5-2: EXEMPT from the session-health gate below — this is the
	-- recovery restore (ReturnStolen / RecoverStaleTransit), not a
	-- player-driven place, and it must run in unhealthy sessions.
	if type(instanceId) == "table" and type(instanceId.InstanceId) == "string" then
		return reinsertPlacedRecord(player, instanceId)
	end
	-- R5-2 (P0): player-driven place (normal + stolen delivery) in
	-- an unhealthy session is refused before anything moves. The
	-- stolen-delivery branch is re-checked inside
	-- RaidService.ConfirmDelivery (stored-lease probe); this gate
	-- catches the session the local state already knows is unsaveable.
	local blockedReason = sessionBlockedReason(player)
	if blockedReason ~= nil then
		return false, "session cannot save: " .. blockedReason
	end
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid instance"
	end
	local plotIndex = _playerPlot[player]
	if plotIndex == nil then
		return false, "no base assigned"
	end
	local data = _dataService.GetOrLoad(player)
	local base = ensureBaseData(data)
	slot = math.floor(tonumber(slot) or 0)
	if slot < 1 or slot > effectiveSlots(player, base) then
		return false, "slot not unlocked"
	end
	if not BaseService.IsSlotFree(player, slot) then
		return false, "slot occupied"
	end
	-- What the player is carrying (nil when CarryService is not wired).
	local carried: { [string]: any }? = nil
	if _carryService ~= nil and type(_carryService.GetCarried) == "function" then
		carried = _carryService.GetCarried(player)
	end
	local isStolenDelivery = carried ~= nil and carried.Stolen == true
		and carried.InstanceId == instanceId
	local owned: { [string]: any }? = nil
	if isStolenDelivery then
		if carried == nil then
			return false, "not carrying that brainrot"
		end
		-- Shape 3: stolen delivery. The owned record is the SAME record
		-- the steal moved to the thief at steal time (RaidService
		-- moveOwnedRecord, flagged InTransit); resolve it by InstanceId
		-- exactly — never by CharacterId, and never mint a fallback.
		-- (The old comment claimed ConfirmDelivery "creates the thief's
		-- fresh instance": wrong — ConfirmDelivery creates nothing; it
		-- only clears the transit flag/entry and pays the reward. The
		-- old backwards CharacterId scan could therefore place a
		-- different unplaced instance of the same character, and the
		-- mint fallback could double the instance. Both are gone.)
		-- Nothing is confirmed yet: every validation below (slot,
		-- already-placed, carry, plot, pedestal, distance) runs BEFORE
		-- ConfirmDelivery (P1-2), so a failed placement leaves transit
		-- live, pays nothing, and keeps the return path open.
		owned = findOwned(data, instanceId)
		if owned == nil then
			-- No record to deliver: do NOT confirm and do NOT mint —
			-- the moved record still exists somewhere, and minting a
			-- new GUID here would double the instance.
			return false, "brainrot not owned"
		end
		if owned.OnExpedition == true then
			return false, "brainrot on expedition"
		end
		-- NOTE: owned.InTransit == true is EXPECTED here (set at steal
		-- time, cleared only by ConfirmDelivery below). The InTransit
		-- guard applies to the normal path, not to this delivery.
	else
		owned = findOwned(data, instanceId)
		if owned == nil then
			return false, "brainrot not owned"
		end
		-- Phase 1 guards: an in-transit or on-expedition instance may
		-- not be placed by the normal path — only the stolen-delivery
		-- branch above (which confirms through RaidService) may
		-- resolve an InTransit record.
		if owned.InTransit == true then
			return false, "brainrot in transit"
		end
		if owned.OnExpedition == true then
			return false, "brainrot on expedition"
		end
	end
	if owned == nil then
		return false, "brainrot not owned"
	end
	local _, alreadyPlaced = findPlaced(base, instanceId)
	if alreadyPlaced ~= nil then
		return false, "already placed"
	end
	-- Must actually be carrying it: placing straight from the
	-- inventory list, without carrying, would skip the carry slowdown
	-- and the steal risk the whole loop is built on. (For a stolen
	-- delivery the stolen carry is cleared below, once the delivery
	-- has been confirmed — there is no fresh instance.)
	if not isStolenDelivery then
		if carried == nil then
			return false, "not carrying that brainrot"
		end
		if carried.InstanceId ~= instanceId then
			return false, "not carrying that brainrot"
		end
	end
	local plot = MapBuilder.GetBasePlot(plotIndex)
	if plot == nil then
		return false, "base plot missing"
	end
	local pedestals = plot.Pedestals :: { [number]: CFrame }
	local pedestalCF = pedestals[slot]
	if pedestalCF == nil then
		return false, "bad slot"
	end
	local rootPos = rootPosition(player)
	if rootPos == nil or (rootPos - pedestalCF.Position).Magnitude > PLACE_DISTANCE then
		return false, "too far from the pedestal"
	end

	-- P1-2: ONLY now, with every validation passed (slot, ownership,
	-- already-placed, carry, plot, pedestal, distance), confirm the
	-- stolen delivery. ConfirmDelivery verifies the transit record,
	-- then clears the flag/entry and pays the reward. If it returns
	-- false the delivery is NOT confirmed: transit stays live, no
	-- reward is paid, and this placement aborts with no state change.
	if isStolenDelivery then
		if _raidService == nil or type(_raidService.ConfirmDelivery) ~= "function" then
			return false, "raid service unavailable"
		end
		local ok, delivered = pcall(function()
			return _raidService.ConfirmDelivery(player, instanceId)
		end)
		if not ok or not delivered then
			return false, "delivery failed"
		end
		-- ConfirmDelivery moves no records; the owned record resolved
		-- above is still the delivered one. Re-resolve defensively:
		-- if it vanished, abort rather than placing a stale record.
		owned = findOwned(data, instanceId)
		if owned == nil then
			return false, "brainrot not owned"
		end
	end

	local placed: { [string]: any } = {
		InstanceId = instanceId,
		CharacterId = owned.CharacterId,
		Slot = slot,
		Level = tonumber(owned.Level) or 1,
		Glitched = owned.Glitched == true,
		Mutation = owned.Mutation,
		-- Preserve the delivered instance's banked income / placement
		-- time from the owned record. For a stolen delivery,
		-- RaidService.ConfirmDelivery (called above, before this
		-- copy is built) already wrote the snapshot remainder onto
		-- the owned record: BankedIncome is the banked amount minus
		-- the reward share already paid, and PlacedAt is the delivery
		-- time — the 120-second protection window restarts on a new
		-- placement, intentionally. A normal place reads whatever
		-- the owned record already carries; the 0 / now fallbacks
		-- only apply when the owned record has no values at all.
		BankedIncome = tonumber(owned.BankedIncome) or 0,
		PlacedAt = tonumber(owned.PlacedAt) or os.time(),
	}
	table.insert(base.Placed, placed)
	syncPlacedFlag(player, instanceId, true, slot)
	if _carryService ~= nil and type(_carryService.ClearCarried) == "function" then
		pcall(function()
			_carryService.ClearCarried(player, true)
		end)
	end
	pcall(buildPlacedModel, player, placed)
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	fireBaseUpdate(player)
	print(string.format("[BaseService] %s placed %s on slot %d (plot %d)",
		player.Name, tostring(owned.CharacterId), slot, plotIndex))
	return true, placed
end

-- Remove a placed Brainrot (steal / mutation). Returns the removed record.
function BaseService.RemovePlaced(player: Player, instanceId: string): { [string]: any }?
	local data = _dataService.GetData(player)
	if data == nil then
		return nil
	end
	local base = ensureBaseData(data)
	local index, placed = findPlaced(base, instanceId)
	if placed == nil then
		return nil
	end
	table.remove(base.Placed, index :: number)
	syncPlacedFlag(player, instanceId, false, 0)
	local models = _placedModels[player]
	if models ~= nil and models[instanceId] ~= nil then
		pcall(function()
			models[instanceId]:Destroy()
		end)
		models[instanceId] = nil
	end
	if _placedBaseCF[player] ~= nil then
		_placedBaseCF[player][instanceId] = nil
	end
	if _placedPhase[player] ~= nil then
		_placedPhase[player][instanceId] = nil
	end
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	fireBaseUpdate(player)
	return placed
end

-- Store (unplace) a placed Brainrot back into the owner's inventory.
-- Returns (true, ownedRecord) or (false, reason). No sell-back reward:
-- the economy has no store payout, so none is invented here.
-- The placed copy's live fields are written back onto the OwnedInstances
-- record BEFORE removal (RemovePlaced alone only flips Placed=false,
-- which would discard a BankedIncome the placed copy held), then
-- RemovePlaced does the teardown (model destroy, flag sync, save,
-- BaseUpdate). Once stored the instance earns nothing — income sums
-- placed instances only — and it can be placed again in a free slot.
function BaseService.StoreBrainrot(player: Player, instanceId: any): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid instance"
	end
	-- R5-2 (P0): storing in an unhealthy session is refused before
	-- anything moves — the unplace would live only in memory until
	-- the next save refuses, and on rejoin the stored profile
	-- disagrees with what the player saw. (Local check only, same
	-- reasoning as PlaceBrainrot above.)
	local blockedReason = sessionBlockedReason(player)
	if blockedReason ~= nil then
		return false, "session cannot save: " .. blockedReason
	end
	local plotIndex = _playerPlot[player]
	if plotIndex == nil then
		return false, "no base assigned"
	end
	local data = _dataService.GetOrLoad(player)
	local base = ensureBaseData(data)
	-- Ownership: the base must be this player's own when the data
	-- records an owner, and the placed record must live in THIS
	-- player's base. A non-owner's data has no such placed record, so
	-- the lookup below is the real enforcement; the OwnerUserId check
	-- is defence in depth for data that records one.
	if tonumber(base.OwnerUserId) ~= nil and tonumber(base.OwnerUserId) ~= 0
		and tonumber(base.OwnerUserId) ~= player.UserId then
		return false, "not your base"
	end
	local _, placed = findPlaced(base, instanceId)
	if placed == nil then
		return false, "brainrot not placed"
	end
	local owned = findOwned(data, instanceId)
	if owned == nil then
		return false, "brainrot not owned"
	end
	-- Phase 1 guards: never store an instance mid-theft, in transit,
	-- or out on an expedition.
	if owned.InTransit == true then
		return false, "brainrot in transit"
	end
	if owned.OnExpedition == true then
		return false, "brainrot on expedition"
	end
	-- Write the placed copy's live progression back onto the owned
	-- record before the placed copy is destroyed. Level and Glitched
	-- are kept in sync between the two copies (UpgradeBrainrot updates
	-- both), so the placed values round-trip safely. Mutation is the
	-- exception: MutationService.MutateBrainrot writes the owned record
	-- ONLY, so a mutation applied after placement lives on the owned
	-- record while the placed copy is stale — overwriting it here
	-- would REVERT the mutation. The placed mutation is therefore
	-- only a fill-in when the owned record has none. BankedIncome /
	-- PlacedAt round-trip from the placed copy when present.
	-- Evolution / trait fields live only on the owned record (the
	-- placed copy never carries them), so they are copied through only
	-- if a placed copy ever does — never blanked from the owned side.
	owned.Level = tonumber(placed.Level) or tonumber(owned.Level) or 1
	owned.Glitched = placed.Glitched == true
	if (owned.Mutation == nil or owned.Mutation == "") and placed.Mutation ~= nil then
		owned.Mutation = placed.Mutation
	end
	if placed.BankedIncome ~= nil then
		owned.BankedIncome = tonumber(placed.BankedIncome) or 0
	end
	if placed.PlacedAt ~= nil then
		owned.PlacedAt = tonumber(placed.PlacedAt) or owned.PlacedAt
	end
	for _, field in ipairs({ "Evolved", "EvolutionId", "EvolvedTrait", "EvolvedFormName", "TraitLevels" }) do
		if placed[field] ~= nil then
			owned[field] = placed[field]
		end
	end
	local removed = BaseService.RemovePlaced(player, instanceId)
	if removed == nil then
		return false, "brainrot not placed"
	end
	print(string.format("[BaseService] %s stored %s from slot %d (plot %d)",
		player.Name, tostring(owned.CharacterId), tonumber(placed.Slot) or 0, plotIndex))
	return true, owned
end

-- -------------------------------------------------------------------------
-- Income
-- -------------------------------------------------------------------------

function BaseService.CollectIncome(player: Player): (boolean, number)
	if not player or not player.Parent then
		return false, 0
	end
	local data = _dataService.GetOrLoad(player)
	local banked = math.floor(tonumber(data.BankedIncome) or 0)
	if banked <= 0 then
		return false, 0
	end
	data.BankedIncome = 0
	_dataService.AddCoins(player, banked)
	local base = ensureBaseData(data)
	base.TotalEarned = (tonumber(base.TotalEarned) or 0) + banked
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	fireBaseUpdate(player)
	print(string.format("[BaseService] %s collected %d coins", player.Name, banked))
	return true, banked
end

-- -------------------------------------------------------------------------
-- Upgrades
-- -------------------------------------------------------------------------

-- Returns (true, kind) or (false, reason).
function BaseService.UpgradeBase(player: Player, kind: any): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(kind) ~= "string" then
		return false, "invalid upgrade kind"
	end
	local known = false
	for _, k in ipairs(UPGRADE_KINDS) do
		if k == kind then
			known = true
			break
		end
	end
	if not known then
		return false, "unknown upgrade kind"
	end
	local data = _dataService.GetOrLoad(player)
	local base = ensureBaseData(data)
	local level = 0
	local maxLevel = tonumber(Config.MaxUpgradeLevel) or 5
	if kind == "BaseSlot" then
		level = math.max(0, (tonumber(base.Slots) or 0) - (tonumber(Config.BaseSlotsStart) or 4))
		if (tonumber(base.Slots) or 0) >= (tonumber(Config.BaseSlotsMax) or 10) then
			return false, "max slots reached"
		end
	elseif kind == "IncomeMultiplier" then
		level = tonumber(base.IncomeMultiplierLevel) or 0
		if level >= maxLevel then
			return false, "max level reached"
		end
	elseif kind == "Lock" then
		level = tonumber(base.LockLevel) or 0
		if level >= #Config.LockCost then
			return false, "max level reached"
		end
	elseif kind == "Turret" then
		level = tonumber(base.TurretLevel) or 0
		if level >= maxLevel then
			return false, "max level reached"
		end
	elseif kind == "ConveyorLuck" then
		level = tonumber(base.ConveyorLuckLevel) or 0
		if level >= #Config.ConveyorLuckCost then
			return false, "max level reached"
		end
	end
	local cost = upgradeCost(kind, level)
	if cost == nil then
		return false, "max level reached"
	end
	-- R4-3: affordability is judged on SPENDABLE coins (balance
	-- above any reservation held for a pending reward commit), not
	-- the raw balance. AddCoins enforces the same floor as a
	-- backstop, but the check here is what keeps the player from
	-- being charged for an upgrade they cannot afford.
	local coins = tonumber(data.Coins) or 0
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, spendable = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(spendable) == "number" then
			coins = spendable
		end
	end
	if coins < cost then
		return false, "not enough coins"
	end
	_dataService.AddCoins(player, -cost)
	if kind == "BaseSlot" then
		base.Slots = (tonumber(base.Slots) or 0) + 1
	elseif kind == "IncomeMultiplier" then
		base.IncomeMultiplierLevel = level + 1
		base.IncomeMultiplier = 1 + (level + 1) * 0.25
	elseif kind == "Lock" then
		base.LockLevel = level + 1
		base.LockedUntil = os.time() + (tonumber(Config.BaseLockDuration) or 30)
	elseif kind == "Turret" then
		base.TurretLevel = level + 1
	elseif kind == "ConveyorLuck" then
		base.ConveyorLuckLevel = level + 1
	end
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	fireBaseUpdate(player)
	print(string.format("[BaseService] %s upgraded %s to level %d for %d coins",
		player.Name, kind, level + 1, cost))
	return true, kind
end

-- Upgrade one placed Brainrot's level. Returns (true, level) / (false, reason).
function BaseService.UpgradeBrainrot(player: Player, instanceId: any): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid instance"
	end
	local data = _dataService.GetOrLoad(player)
	local base = ensureBaseData(data)
	local _, placed = findPlaced(base, instanceId)
	if placed == nil then
		return false, "brainrot not placed"
	end
	local level = math.floor(tonumber(placed.Level) or 1)
	local maxLevel = tonumber(Config.MaxBrainrotLevel) or 5
	if level >= maxLevel then
		return false, "max level reached"
	end
	local cost: number? = nil
	if _economyMod ~= nil and type(_economyMod.UpgradeCost) == "function" then
		local ok, value = pcall(_economyMod.UpgradeCost, "BrainrotLevel", level)
		if ok and type(value) == "number" then
			cost = value
		end
	end
	if cost == nil then
		local tableRef = Config.BrainrotLevelCost
		if level + 1 > #tableRef then
			return false, "max level reached"
		end
		cost = tableRef[level]
	end
	local coins = tonumber(data.Coins) or 0
	-- R4-3: see UpgradeBase — affordability is judged on spendable
	-- coins (balance above any reservation), not the raw balance.
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, spendable = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(spendable) == "number" then
			coins = spendable
		end
	end
	if coins < (cost or 0) then
		return false, "not enough coins"
	end
	_dataService.AddCoins(player, -(cost :: number))
	placed.Level = level + 1
	-- Keep the owned record in sync.
	local owned = findOwned(data, instanceId)
	if owned ~= nil then
		owned.Level = level + 1
	end
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	fireBaseUpdate(player)
	return true, level + 1
end

-- -------------------------------------------------------------------------
-- Remote wiring
-- -------------------------------------------------------------------------

local function onPlaceBrainrot(player: Player, instanceId: any, slot: any): ()
	if rateLimited(player, "place") then
		return
	end
	local ok, success, reason = pcall(function()
		return BaseService.PlaceBrainrot(player, tostring(instanceId), slot)
	end)
	if not ok then
		warn("[BaseService] PlaceBrainrot error for " .. player.Name .. ": " .. tostring(success))
	elseif not success then
		warn("[BaseService] PlaceBrainrot denied for " .. player.Name .. ": " .. tostring(reason))
	end
end

local function onCollectIncome(player: Player): ()
	if rateLimited(player, "collect") then
		return
	end
	pcall(function()
		BaseService.CollectIncome(player)
	end)
end

local function onUpgradeBase(player: Player, kind: any): ()
	-- R3-8: Action envelopes for other services ({Action="Mutate"} /
	-- {Action="Rebirth"}) share this remote and are not base upgrades:
	-- they return BEFORE the throttle, so routing a mutate through
	-- here no longer consumes the player's upgrade budget.
	if type(kind) == "table" then
		-- Other services share the UpgradeBase remote with Action
		-- envelopes ({Action="Mutate"} / {Action="Rebirth"}); those are
		-- not base upgrades and are handled by their own service.
		if kind.Kind ~= nil or kind.kind ~= nil then
			kind = kind.Kind or kind.kind
		else
			return
		end
	end
	if rateLimited(player, "upgradeBase") then
		return
	end
	local ok, success, reason = pcall(function()
		return BaseService.UpgradeBase(player, kind)
	end)
	if not ok then
		warn("[BaseService] UpgradeBase error for " .. player.Name .. ": " .. tostring(success))
	elseif not success then
		warn("[BaseService] UpgradeBase denied for " .. player.Name .. ": " .. tostring(reason))
	end
end

local function onUpgradeBrainrot(player: Player, instanceId: any): ()
	-- R3-8: see onUpgradeBase — Action envelopes ({Action="Mutate"} /
	-- {Action="Fuse"}) return before the throttle.
	if type(instanceId) == "table" and instanceId.Action ~= nil then
		return
	end
	if rateLimited(player, "upgradeBrainrot") then
		return
	end
	local ok, success, reason = pcall(function()
		return BaseService.UpgradeBrainrot(player, instanceId)
	end)
	if not ok then
		warn("[BaseService] UpgradeBrainrot error for " .. player.Name .. ": " .. tostring(success))
	elseif not success then
		warn("[BaseService] UpgradeBrainrot denied for " .. player.Name .. ": " .. tostring(reason))
	end
end

local function onStoreBrainrot(player: Player, instanceId: any): ()
	if rateLimited(player, "store") then
		return
	end
	local ok, success, reason = pcall(function()
		return BaseService.StoreBrainrot(player, instanceId)
	end)
	if not ok then
		warn("[BaseService] StoreBrainrot error for " .. player.Name .. ": " .. tostring(success))
	elseif not success then
		warn("[BaseService] StoreBrainrot denied for " .. player.Name .. ": " .. tostring(reason))
	end
end

function BaseService.Init(dataService: any, map: Model?): ()
	assert(dataService ~= nil, "[BaseService] Init requires DataService")
	_dataService = dataService

	task.spawn(function()
		local placeRemote: RemoteEvent? = nil
		local collectRemote: RemoteEvent? = nil
		local upgradeRemote: RemoteEvent? = nil
		local upgradeBrainrotRemote: RemoteEvent? = nil
		local storeRemote: RemoteEvent? = nil
		local requestFn: RemoteFunction? = nil
		for _ = 1, 50 do
			placeRemote = placeRemote or getEvent(Remotes.Names.PlaceBrainrot)
			collectRemote = collectRemote or getEvent(Remotes.Names.CollectIncome)
			upgradeRemote = upgradeRemote or getEvent(Remotes.Names.UpgradeBase)
			upgradeBrainrotRemote = upgradeBrainrotRemote or getEvent(Remotes.Names.UpgradeBrainrot)
			storeRemote = storeRemote or getEvent(Remotes.Names.StoreBrainrot)
			requestFn = requestFn or getFunction(Remotes.Names.RequestBase)
			if placeRemote ~= nil and collectRemote ~= nil and upgradeRemote ~= nil
				and upgradeBrainrotRemote ~= nil and storeRemote ~= nil and requestFn ~= nil then
				break
			end
			task.wait(0.2)
		end
		if placeRemote ~= nil then
			placeRemote.OnServerEvent:Connect(onPlaceBrainrot)
		else
			warn("[BaseService] PlaceBrainrot remote not available")
		end
		if collectRemote ~= nil then
			collectRemote.OnServerEvent:Connect(onCollectIncome)
		else
			warn("[BaseService] CollectIncome remote not available")
		end
		if upgradeRemote ~= nil then
			upgradeRemote.OnServerEvent:Connect(onUpgradeBase)
		else
			warn("[BaseService] UpgradeBase remote not available")
		end
		if upgradeBrainrotRemote ~= nil then
			upgradeBrainrotRemote.OnServerEvent:Connect(onUpgradeBrainrot)
		else
			warn("[BaseService] UpgradeBrainrot remote not available")
		end
		if storeRemote ~= nil then
			storeRemote.OnServerEvent:Connect(onStoreBrainrot)
		else
			warn("[BaseService] StoreBrainrot remote not available")
		end
		if requestFn ~= nil then
			requestFn.OnServerInvoke = function(player: Player)
				local snapshot = BaseService.GetBase(player)
				if snapshot == nil then
					return { Success = false, Message = "no data" }
				end
				return snapshot
			end
		else
			warn("[BaseService] RequestBase function not available")
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		BaseService.ReleaseBase(player)
	end)

	if _running then
		return
	end
	_running = true

	-- Passive income tick: bank each base's per-second income.
	task.spawn(function()
		while true do
			local dt = task.wait(tonumber(Config.IncomeTickSeconds) or 1)
			dt = tonumber(dt) or (tonumber(Config.IncomeTickSeconds) or 1)
			-- Clamp lag spikes so a hitch cannot bank a windfall.
			dt = math.clamp(dt, 0, 5)
			for _, player in ipairs(Players:GetPlayers()) do
				pcall(function()
					if _playerPlot[player] == nil then
						return
					end
					local data = _dataService.GetData(player)
					if data == nil then
						return
					end
					ensureBaseData(data)
					local rate = BaseService.GetIncomePerSec(player)
					if rate > 0 then
						local banked = (tonumber(data.BankedIncome) or 0) + rate * dt
						data.BankedIncome = math.min(banked, bankedCapFor(player))
					end
				end)
			end
		end
	end)

	-- Idle bob for placed models (one loop for every base).
	task.spawn(function()
		while true do
			task.wait(0.1)
			local t = os.clock()
			for player, models in pairs(_placedModels) do
				if player.Parent ~= nil then
					for instanceId, model in pairs(models) do
						local baseCF = _placedBaseCF[player] and _placedBaseCF[player][instanceId]
						local phase = _placedPhase[player] and _placedPhase[player][instanceId] or 0
						if baseCF ~= nil and model.Parent ~= nil then
							local bob = math.sin(t * 2 + phase) * 0.15
							pcall(function()
								model:PivotTo(baseCF * CFrame.new(0, bob, 0))
							end)
						end
					end
				end
			end
		end
	end)
end

return BaseService
