--!strict
-- ProgressionService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- XP / levels, rebirth, the collection book and cosmetics.
--
-- XP CURVE: reuses shared Economy.XPForLevel (the same curve
-- EconomyService uses), so a level means the same thing everywhere.
-- Level-up rewards: coins (50 + 25/level), +5 gems every 5 levels,
-- +1 base slot every 10 levels (capped at Config.BaseSlotsMax).
--
-- REBIRTH (Rebirth remote): requires Level >= 25 AND 100,000 coins AND
-- 10 DISTINCT owned Brainrots — all three checked server-side, all read
-- from Config.RebirthRequirements (the single source of truth). It
-- resets Coins (to Config.StartingCoins), Level/XP (to 1/0) and placed
-- Brainrots (they return to the inventory), BUT KEEPS owned characters
-- and the rebirth count (data.Rebirths), wins/KOs, quests and
-- cosmetics. Each rebirth grants a permanent +10% income (Config),
-- +2 base slots, +25 gems, and unlocks the rebirth-only mutation tier
-- (MutationService reads data.Rebirths). Max 10 rebirths.
-- v1.0.1 QA: v1.0.0 enforced 8 PLACED (not 10 distinct), paid 0 gems
-- (Config promises 25), granted +25% income (Config says +10%), had no
-- rebirth cap, and WIPED the whole collection to the starter — directly
-- contradicting Config's "keeps owned characters". All fixed here.
--
-- PRESTIGE (v1.1, Workstream C): after 10 rebirths, Prestige() resets
-- Rebirths to 0 and grants Prestige rank +1 (keeps the collection and
-- dimension unlocks), +50 gems, a title, and a permanent +5% income
-- per prestige rank (PRESTIGE_INCOME_PER_RANK below — Config has no
-- prestige rate and is frozen for this workstream, so the rate lives
-- here and is mirrored in BaseService's unwired fallback).
--
-- LEVEL / COLLECTION MILESTONES (v1.1): one-time rewards at level
-- 15/20/30/40/50/75/100 and at 10/15/20/27 distinct Brainrots,
-- tracked in data.ProgressionMilestones (claimed flags).
--
-- WORLD UNLOCKS (v1.1): dimensions unlock by level (Abyssal 5,
-- Skyfall 15) and stay unlocked across rebirths (data.DimensionUnlocks
-- is never reset). CanAccessDimension is the check DimensionsService's
-- teleport hook reads; unlocking sets the player attribute
-- "DimensionUnlocked_<id>" so the teleport check can read it without
-- a service call.
--
-- RARE-CHARACTER MASTERY (v1.1): mastery XP per owned Rare+ Brainrot
-- (AwardMastery — called by expeditions / evolutions). At 100 / 500 /
-- 1000 mastery XP a Brainrot grants +1% income each (max +3% per
-- Brainrot, +15% total), folded into GetIncomeMultiplier.
--
-- CHALLENGES (v1.1): cumulative cross-system goals (tides, bosses,
-- expeditions, fusions, evolutions, secrets, territories), tracked in
-- data.Challenges and advanced by CheckChallenge — called from
-- QuestService.ReportProgress forwarding.
--
-- COLLECTION BOOK: GetCollection(player) merges data.Unlocked,
-- data.Placed and data.CollectionDiscovered (other services call
-- RecordDiscovery when a character is found). Wired to the
-- RequestCollection RemoteFunction in Init (v1.0.1 integration QA:
-- the getter existed but no handler did, so InvokeServer errored).
--
-- COSMETICS: titles / auras / trails, unlocked by level, rebirth count
-- or collection size. Purely visual — no gameplay advantage. The
-- equipped cosmetic is stored in data.Cosmetics.Equipped; applying the
-- visual is the client's job.
--
-- REMOTE: Rebirth does not exist in Remotes.Names yet, so the existing
-- UpgradeBase remote is reused with an Action envelope
-- ({Action="Rebirth"}); EquipCosmetic likewise reuses SelectCharacter
-- with ({Action="EquipCosmetic", CosmeticId=...}). Both handlers ignore
-- any payload without their Action.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Economy = require(ReplicatedStorage:WaitForChild("Economy"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local ProgressionService = {}

local _dataService: any = nil
local _achievementService: any = nil

-- v1.1 (Workstream C) tuning. Prestige income lives here because
-- Config is frozen for this workstream (see header); BaseService's
-- unwired fallback mirrors the 0.05.
ProgressionService.PRESTIGE_INCOME_PER_RANK = 0.05
local MASTERY_MILESTONES: { number } = { 100, 500, 1000 }
local MASTERY_BONUS_PER_MILESTONE = 0.01
local MASTERY_BONUS_CAP = 0.15
local MASTERY_MIN_RANK = 3 -- Rare+ Brainrots earn mastery XP

-- Level milestones: one-time rewards, claimed in AddXP.
local LEVEL_MILESTONES: { { Level: number, Coins: number, Gems: number, Crystals: number, XP: number } } = {
	{ Level = 15, Coins = 200, Gems = 10, Crystals = 10, XP = 100 },
	{ Level = 20, Coins = 500, Gems = 10, Crystals = 25, XP = 150 },
	{ Level = 30, Coins = 1000, Gems = 15, Crystals = 25, XP = 250 },
	{ Level = 40, Coins = 2000, Gems = 20, Crystals = 50, XP = 400 },
	{ Level = 50, Coins = 5000, Gems = 50, Crystals = 100, XP = 500 },
	{ Level = 75, Coins = 10000, Gems = 75, Crystals = 100, XP = 750 },
	{ Level = 100, Coins = 25000, Gems = 100, Crystals = 250, XP = 1000 },
}

-- Collection milestones: one-time rewards by distinct Brainrots owned.
local COLLECTION_MILESTONES: { { Distinct: number, Coins: number, Gems: number, Crystals: number, XP: number } } = {
	{ Distinct = 10, Coins = 500, Gems = 10, Crystals = 10, XP = 100 },
	{ Distinct = 15, Coins = 1000, Gems = 15, Crystals = 25, XP = 200 },
	{ Distinct = 20, Coins = 2500, Gems = 25, Crystals = 50, XP = 300 },
	{ Distinct = 27, Coins = 10000, Gems = 100, Crystals = 100, XP = 1000 },
}

-- World unlocks: dimension id -> minimum level. Once unlocked, the
-- unlock persists in data.DimensionUnlocks (never reset by rebirth
-- or prestige).
local DIMENSION_UNLOCKS: { [string]: { Level: number } } = {
	abyssal = { Level = 5 },
	skyfall = { Level = 15 },
}

-- Challenges: cumulative cross-system goals. Reward XP is paid via
-- AddXP (which never calls CheckChallenge, so there is no cycle).
local CHALLENGES: { { Id: string, Name: string, Kind: string, Goal: number, Reward: { Coins: number, Gems: number, XP: number, Crystals: number } } } = {
	{ Id = "ch_tides_10", Name = "Tide Veteran", Kind = "tide_survived", Goal = 10, Reward = { Coins = 2000, Gems = 25, XP = 100, Crystals = 50 } },
	{ Id = "ch_tides_25", Name = "Tide Legend", Kind = "tide_survived", Goal = 25, Reward = { Coins = 5000, Gems = 50, XP = 250, Crystals = 100 } },
	{ Id = "ch_bosses_5", Name = "Boss Hunter", Kind = "boss_defeated", Goal = 5, Reward = { Coins = 5000, Gems = 50, XP = 500, Crystals = 50 } },
	{ Id = "ch_expeditions_10", Name = "Expedition Leader", Kind = "expedition", Goal = 10, Reward = { Coins = 3000, Gems = 25, XP = 250, Crystals = 50 } },
	{ Id = "ch_fusions_10", Name = "Fusion Master", Kind = "fusion", Goal = 10, Reward = { Coins = 3000, Gems = 25, XP = 250, Crystals = 50 } },
	{ Id = "ch_evolutions_5", Name = "Evolution Master", Kind = "evolution", Goal = 5, Reward = { Coins = 3000, Gems = 25, XP = 250, Crystals = 50 } },
	{ Id = "ch_secrets_3", Name = "Secret Hunter", Kind = "secret", Goal = 3, Reward = { Coins = 3000, Gems = 50, XP = 500, Crystals = 25 } },
	{ Id = "ch_territories_5", Name = "Territory Lord", Kind = "territory", Goal = 5, Reward = { Coins = 2000, Gems = 25, XP = 250, Crystals = 25 } },
}

-- Rebirth tuning is read from Config.RebirthRequirements at call time
-- (see rebirthConfig()); the locals below are only the fallback if
-- Config is ever missing a field.
local function rebirthConfig()
	local req = Config.RebirthRequirements or {}
	return {
		MinLevel = tonumber(req.Level) or 25,
		MinCoins = tonumber(req.Coins) or 100000,
		MinDistinct = tonumber(req.Brainrots) or 10,
		RewardGems = tonumber(req.RewardGems) or 25,
		IncomePer = tonumber(req.IncomeBonusPerRebirth) or 0.10,
		SlotsPer = tonumber(req.SlotsPerRebirth) or 2,
		MaxRebirths = tonumber(req.MaxRebirths) or 10,
	}
end
export type CosmeticDef = {
	Id: string,
	Name: string,
	Kind: string, -- "Title" | "Aura" | "Trail"
	Requirement: { Level: number?, Rebirths: number?, Distinct: number? },
}

local COSMETICS: { CosmeticDef } = {
	{ Id = "title_rookie", Name = "Rookie", Kind = "Title", Requirement = { Level = 1 } },
	{ Id = "title_collector", Name = "Collector", Kind = "Title", Requirement = { Distinct = 10 } },
	{ Id = "title_tideborn", Name = "Tideborn", Kind = "Title", Requirement = { Level = 10 } },
	{ Id = "title_glitch_lord", Name = "Glitch Lord", Kind = "Title", Requirement = { Rebirths = 1 } },
	{ Id = "title_meme_king", Name = "Meme King", Kind = "Title", Requirement = { Level = 50 } },
	{ Id = "aura_gold", Name = "Golden Aura", Kind = "Aura", Requirement = { Level = 25 } },
	{ Id = "aura_void", Name = "Void Aura", Kind = "Aura", Requirement = { Rebirths = 2 } },
	{ Id = "aura_glitch", Name = "Glitch Aura", Kind = "Aura", Requirement = { Level = 40 } },
	{ Id = "trail_fire", Name = "Fire Trail", Kind = "Trail", Requirement = { Level = 15 } },
	{ Id = "trail_rainbow", Name = "Rainbow Trail", Kind = "Trail", Requirement = { Level = 30 } },
	{ Id = "trail_void", Name = "Void Trail", Kind = "Trail", Requirement = { Rebirths = 1 } },
}

local _cosmeticById: { [string]: CosmeticDef } = {}
for _, def in ipairs(COSMETICS) do
	_cosmeticById[def.Id] = def
end

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

local function getFunction(name: string): RemoteFunction?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetFunction(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteFunction") then
		return remote :: RemoteFunction
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

local function ensureProgressionData(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.Rebirths) ~= "number" then
		data.Rebirths = 0
	end
	if type(data.BaseSlots) ~= "number" then
		data.BaseSlots = Config.BaseSlotsStart or 4
	end
	if type(data.Gems) ~= "number" then
		data.Gems = 0
	end
	if type(data.EventTokens) ~= "number" then
		data.EventTokens = 0
	end
	if type(data.CollectionDiscovered) ~= "table" then
		data.CollectionDiscovered = {}
	end
	if type(data.Prestige) ~= "number" then
		data.Prestige = 0
	end
	if type(data.DimensionUnlocks) ~= "table" then
		data.DimensionUnlocks = {}
	end
	if type(data.Mastery) ~= "table" then
		data.Mastery = {}
	end
	if type(data.ProgressionMilestones) ~= "table" then
		data.ProgressionMilestones = {}
	end
	if type(data.Challenges) ~= "table" then
		data.Challenges = {}
	end
	if type(data.Titles) ~= "table" then
		data.Titles = {}
	end
	if type(data.Cosmetics) ~= "table" then
		data.Cosmetics = { Unlocked = {}, Equipped = {} }
	end
	if type(data.Cosmetics.Unlocked) ~= "table" then
		data.Cosmetics.Unlocked = {}
	end
	if type(data.Cosmetics.Equipped) ~= "table" then
		data.Cosmetics.Equipped = {}
	end
	return data
end

-- ---------------------------------------------------------------------------
-- R5-6: reservation-aware coin helpers.
-- ---------------------------------------------------------------------------
-- A pending steal-reward commit (RaidService.commitPendingPayment,
-- R4-3) credits the reward and reserves it (DataService.ReserveCoins)
-- for the duration of its verified save. A Rebirth/Prestige that
-- fires inside that save window must not wipe the reserved coins:
-- the reset keeps StartingCoins PLUS every reserved coin, so a later
-- commit success keeps the reward and a later rollback subtracts
-- exactly. The coin requirement is likewise judged on SPENDABLE
-- coins — reserved coins are already-credited reward money awaiting
-- a verified save, not the player's to spend yet — so a player
-- cannot buy a rebirth/prestige with coins earmarked for a pending
-- commit. Every other R4-3 spending route judges affordability the
-- same way.
-- Both helpers fall back to the raw balance when DataService has no
-- reservation API (stub DataServices in other suites), preserving
-- the old behaviour there.
local function reservedCoins(player: Player): number
	if _dataService and type(_dataService.GetReservedCoins) == "function" then
		local ok, reserved = pcall(function()
			return _dataService.GetReservedCoins(player)
		end)
		if ok and type(reserved) == "number" then
			return math.max(0, math.floor(reserved))
		end
	end
	return 0
end

local function spendableCoins(player: Player, data: any): number
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, spendable = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(spendable) == "number" then
			return math.max(0, math.floor(spendable))
		end
	end
	return tonumber(data.Coins) or 0
end

-- resetCoins(player): the coin balance a Rebirth/Prestige reset lands
-- on — StartingCoins plus every reserved coin (R5-6). Wiping the
-- reserved coins would lose the reward on commit success and corrupt
-- the rollback on commit failure (the exact subtraction would clamp
-- at zero and eat the reset's StartingCoins instead).
local function resetCoins(player: Player): number
	return (Config.StartingCoins or 100) + reservedCoins(player)
end

local function distinctCount(data: any): number
	local seen: { [string]: boolean } = {}
	local count = 0
	local function add(id: any)
		if type(id) == "string" and not seen[id] and Characters.GetById(id) then
			seen[id] = true
			count += 1
		end
	end
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			add(id)
		end
	end
	if type(data.CollectionDiscovered) == "table" then
		for _, id in ipairs(data.CollectionDiscovered) do
			add(id)
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- XP / levels
-- ---------------------------------------------------------------------------

-- checkMilestones(player, data, level): claim any newly-reached level /
-- collection milestones. Pays coins / gems / crystals immediately and
-- RETURNS the XP the milestones grant (the caller feeds it back into
-- the level-up loop — milestone XP can itself level the player up,
-- which can claim further milestones; each milestone claims once, so
-- the loop terminates).
local function checkMilestones(player: Player, data: any, level: number): number
	local grantedXP = 0
	local distinct = distinctCount(data)
	for _, milestone in ipairs(LEVEL_MILESTONES) do
		local key = "level_" .. tostring(milestone.Level)
		if level >= milestone.Level and data.ProgressionMilestones[key] ~= true then
			data.ProgressionMilestones[key] = true
			data.Coins = (tonumber(data.Coins) or 0) + milestone.Coins
			data.Gems = (tonumber(data.Gems) or 0) + milestone.Gems
			data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + milestone.Crystals
			grantedXP += milestone.XP
			print(string.format(
				"[ProgressionService] %s claimed level milestone %d: +%d coins, +%d gems, +%d XP",
				player.Name, milestone.Level, milestone.Coins, milestone.Gems, milestone.XP
			))
		end
	end
	for _, milestone in ipairs(COLLECTION_MILESTONES) do
		local key = "collection_" .. tostring(milestone.Distinct)
		if distinct >= milestone.Distinct and data.ProgressionMilestones[key] ~= true then
			data.ProgressionMilestones[key] = true
			data.Coins = (tonumber(data.Coins) or 0) + milestone.Coins
			data.Gems = (tonumber(data.Gems) or 0) + milestone.Gems
			data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + milestone.Crystals
			grantedXP += milestone.XP
			print(string.format(
				"[ProgressionService] %s claimed collection milestone %d distinct: +%d coins, +%d gems, +%d XP",
				player.Name, milestone.Distinct, milestone.Coins, milestone.Gems, milestone.XP
			))
		end
	end
	return grantedXP
end

-- checkDimensionUnlocks(player, data, level): grant any dimension
-- whose level requirement the player just met.
local function checkDimensionUnlocks(player: Player, data: any, level: number)
	for dimensionId, req in pairs(DIMENSION_UNLOCKS) do
		if level >= req.Level and data.DimensionUnlocks[dimensionId] ~= true then
			ProgressionService.UnlockDimension(player, dimensionId)
		end
	end
end

-- AddXP(player, amount): applies XP, handles level-ups (possibly
-- several), grants level-up rewards, and notifies the client. Other
-- services should call this instead of DataService.AddXP directly.
function ProgressionService.AddXP(player: Player, amount: number): (number, boolean)
	local data = ensureProgressionData(player)
	if not data then
		return 1, false
	end
	local gain = math.max(0, math.floor(tonumber(amount) or 0))
	if gain == 0 then
		return tonumber(data.Level) or 1, false
	end
	local newXP = tonumber(data.XP) or 0
	local level = tonumber(data.Level) or 1
	local leveledUp = false
	local pendingXP = gain
	-- Outer loop: milestone XP can itself level the player up, which
	-- can claim further milestones. Each milestone claims once, so
	-- this terminates.
	while pendingXP > 0 do
		newXP += pendingXP
		pendingXP = 0
		while newXP >= Economy.XPForLevel(level) do
			newXP -= Economy.XPForLevel(level)
			level += 1
			leveledUp = true
			-- Level-up reward: coins scale with the new level.
			data.Coins = (tonumber(data.Coins) or 0) + 50 + 25 * level
			if level % 5 == 0 then
				data.Gems = (tonumber(data.Gems) or 0) + 5
			end
			if level % 10 == 0 then
				-- +1 base slot: BaseService reads data.Base.Slots, so bump
				-- that (and the legacy data.BaseSlots) together.
				local newSlots = math.min(Config.BaseSlotsMax or 10, (tonumber(data.BaseSlots) or 4) + 1)
				data.BaseSlots = newSlots
				if type(data.Base) == "table" then
					data.Base.Slots = newSlots
				end
			end
		end
		pendingXP = checkMilestones(player, data, level)
	end
	data.XP = newXP
	if leveledUp then
		_dataService.SetLevel(player, level)
		fireClient(_names.SpawnEffect, player, {
			type = "LevelUp",
			player = player.Name,
			level = level,
		})
		print(string.format("[ProgressionService] %s levelled up to %d", player.Name, level))
	end
	-- Absolute achievement progress for level (SetProgress, not an
	-- increment — level resets on rebirth).
	if _achievementService and type(_achievementService.SetProgress) == "function" then
		pcall(function()
			_achievementService.SetProgress(player, "level", level)
		end)
	end
	checkDimensionUnlocks(player, data, level)
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Gems = data.Gems,
	})
	return level, leveledUp
end

function ProgressionService.GetLevel(player: Player): number
	local data = getData(player)
	return data and (tonumber(data.Level) or 1) or 1
end

function ProgressionService.GetRebirths(player: Player): number
	local data = getData(player)
	return data and (tonumber(data.Rebirths) or 0) or 0
end

-- GetPrestige(player): prestige rank (0 = never prestiged).
function ProgressionService.GetPrestige(player: Player): number
	local data = getData(player)
	return data and (tonumber(data.Prestige) or 0) or 0
end

-- GetMastery(player, characterId): mastery XP on one Brainrot.
function ProgressionService.GetMastery(player: Player, characterId: string): number
	local data = getData(player)
	if not data or type(data.Mastery) ~= "table" then
		return 0
	end
	return tonumber(data.Mastery[characterId]) or 0
end

-- AwardMastery(player, characterId, amount): add mastery XP to one
-- owned Rare+ Brainrot. Returns (true) or (false, reason). Mastery
-- milestones (100 / 500 / 1000 XP) each grant +1% income for that
-- Brainrot (see GetMasteryBonus).
function ProgressionService.AwardMastery(player: Player, characterId: any, amount: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(characterId)
	if not clean then
		return false, "invalid character id"
	end
	local def = Characters.GetById(clean)
	if not def then
		return false, "unknown character"
	end
	if Characters.GetRarityRank(def.Rarity) < MASTERY_MIN_RANK then
		return false, "only Rare+ Brainrots earn mastery"
	end
	local gain = math.max(0, math.floor(tonumber(amount) or 0))
	if gain == 0 then
		return false, "no mastery gained"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	data.Mastery[clean] = (tonumber(data.Mastery[clean]) or 0) + gain
	return true, nil
end

-- GetMasteryBonus(player): total income bonus from mastery
-- milestones (+1% per milestone hit per Rare+ Brainrot, max +3% each,
-- +15% total). Folded into GetIncomeMultiplier, so it flows through
-- BaseService.GetIncomePerSec with no other edit.
function ProgressionService.GetMasteryBonus(player: Player): number
	local data = getData(player)
	if not data or type(data.Mastery) ~= "table" then
		return 0
	end
	local total = 0
	for characterId, xp in pairs(data.Mastery) do
		local def = Characters.GetById(tostring(characterId))
		if def and Characters.GetRarityRank(def.Rarity) >= MASTERY_MIN_RANK then
			local value = tonumber(xp) or 0
			for _, threshold in ipairs(MASTERY_MILESTONES) do
				if value >= threshold then
					total += MASTERY_BONUS_PER_MILESTONE
				end
			end
		end
	end
	return math.min(total, MASTERY_BONUS_CAP)
end

-- GetIncomeMultiplier(player): 1 + 10%/rebirth (Config, the single
-- source of truth) + 5%/prestige rank + mastery bonus. v1.0.0
-- hardcoded +25% here while Config says +10%.
function ProgressionService.GetIncomeMultiplier(player: Player): number
	return 1
		+ ProgressionService.GetRebirths(player) * rebirthConfig().IncomePer
		+ ProgressionService.GetPrestige(player) * ProgressionService.PRESTIGE_INCOME_PER_RANK
		+ ProgressionService.GetMasteryBonus(player)
end

-- ---------------------------------------------------------------------------
-- World unlocks (dimensions)
-- ---------------------------------------------------------------------------

-- CanAccessDimension(player, dimensionId): hub is always open; a
-- dimension is open once unlocked, or once the player's level meets
-- its requirement (unlocking it as a side effect). Unknown ids are
-- never accessible.
function ProgressionService.CanAccessDimension(player: Player, dimensionId: any): boolean
	if type(dimensionId) ~= "string" then
		return false
	end
	if dimensionId == "hub" then
		return true
	end
	local req = DIMENSION_UNLOCKS[dimensionId]
	if req == nil then
		return false
	end
	local data = ensureProgressionData(player)
	if not data then
		return false
	end
	if data.DimensionUnlocks[dimensionId] == true then
		-- Re-apply the attribute on rejoin (attributes do not persist
		-- across sessions; the save does).
		pcall(function()
			player:SetAttribute("DimensionUnlocked_" .. dimensionId, true)
		end)
		return true
	end
	if (tonumber(data.Level) or 1) >= req.Level then
		ProgressionService.UnlockDimension(player, dimensionId)
		return true
	end
	return false
end

-- UnlockDimension(player, dimensionId): record the unlock, set the
-- player attribute DimensionsService's teleport check reads, and
-- broadcast. Returns (true) or (false, reason). Idempotent.
function ProgressionService.UnlockDimension(player: Player, dimensionId: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	if type(dimensionId) ~= "string" or DIMENSION_UNLOCKS[dimensionId] == nil then
		return false, "unknown dimension"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	if data.DimensionUnlocks[dimensionId] == true then
		return true, nil
	end
	data.DimensionUnlocks[dimensionId] = true
	pcall(function()
		player:SetAttribute("DimensionUnlocked_" .. dimensionId, true)
	end)
	fireClient("EventUpdate", player, {
		EventId = "DimensionUnlocked",
		Name = "New world unlocked: " .. dimensionId .. "!",
		Phase = "Started",
		Duration = 6,
	})
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	print(string.format("[ProgressionService] %s unlocked dimension %s", player.Name, dimensionId))
	return true, nil
end

-- GetUnlockedDimensions(player): ids of unlocked dimensions (hub excluded).
function ProgressionService.GetUnlockedDimensions(player: Player): { string }
	local data = getData(player)
	local out: { string } = {}
	if data and type(data.DimensionUnlocks) == "table" then
		for id, unlocked in pairs(data.DimensionUnlocks) do
			if unlocked == true then
				table.insert(out, id)
			end
		end
	end
	table.sort(out)
	return out
end

-- ---------------------------------------------------------------------------
-- Challenges
-- ---------------------------------------------------------------------------

-- CheckChallenge(player, kind, amount): advance every challenge
-- listening to `kind` by `amount` (cumulative). Rewards are paid
-- exactly once, on completion. Called from QuestService forwarding
-- (ReportProgress / RecordEvent funnel). Safe for unknown kinds.
function ProgressionService.CheckChallenge(player: Player, kind: any, amount: any): { string }
	local completed: { string } = {}
	if not player or not player:IsA("Player") then
		return completed
	end
	if type(kind) ~= "string" or kind == "" then
		return completed
	end
	local data = ensureProgressionData(player)
	if not data then
		return completed
	end
	local delta = math.max(0, math.floor(tonumber(amount) or 1))
	if delta == 0 then
		return completed
	end
	for _, challenge in ipairs(CHALLENGES) do
		if challenge.Kind == kind then
			local state = data.Challenges[challenge.Id]
			if type(state) ~= "table" then
				state = { Progress = 0, Claimed = false }
				data.Challenges[challenge.Id] = state
			end
			if state.Claimed ~= true then
				local after = math.min(challenge.Goal, (tonumber(state.Progress) or 0) + delta)
				state.Progress = after
				if after >= challenge.Goal then
					state.Claimed = true
					table.insert(completed, challenge.Id)
					local reward = challenge.Reward
					pcall(function()
						_dataService.AddCoins(player, reward.Coins)
					end)
					data.Gems = (tonumber(data.Gems) or 0) + reward.Gems
					data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + reward.Crystals
					task.spawn(function()
						pcall(function()
							_dataService.SaveData(player)
						end)
					end)
					fireClient("EventUpdate", player, {
						EventId = "ChallengeComplete",
						Name = player.Name .. " completed challenge: " .. challenge.Name .. "!",
						Phase = "Started",
						Duration = 6,
					})
					print(string.format(
						"[ProgressionService] %s completed challenge %s (%s)",
						player.Name, challenge.Id, challenge.Name
					))
					-- Reward XP (AddXP never calls CheckChallenge, so
					-- this cannot cycle). Paid after the coins/gems so
					-- a level-up here cannot re-trigger this challenge.
					if reward.XP > 0 then
						ProgressionService.AddXP(player, reward.XP)
					end
				end
			end
		end
	end
	return completed
end

-- GetChallenges(player): every challenge with live Progress / Claimed.
function ProgressionService.GetChallenges(player: Player): { any }
	local data = ensureProgressionData(player)
	if not data then
		return {}
	end
	local out: { any } = {}
	for _, challenge in ipairs(CHALLENGES) do
		local state = data.Challenges[challenge.Id]
		local progress = 0
		local claimed = false
		if type(state) == "table" then
			progress = tonumber(state.Progress) or 0
			claimed = state.Claimed == true
		end
		table.insert(out, {
			Id = challenge.Id,
			Name = challenge.Name,
			Kind = challenge.Kind,
			Goal = challenge.Goal,
			Progress = math.min(progress, challenge.Goal),
			Claimed = claimed,
			Reward = challenge.Reward,
		})
	end
	return out
end

function ProgressionService.GetBaseSlots(player: Player): number
	local data = getData(player)
	if not data then
		return Config.BaseSlotsStart or 4
	end
	-- BaseService reads data.Base.Slots; data.BaseSlots is the legacy
	-- field. Prefer the live one.
	local base = Config.BaseSlotsStart or 4
	if type(data.Base) == "table" and tonumber(data.Base.Slots) then
		base = tonumber(data.Base.Slots) :: number
	elseif tonumber(data.BaseSlots) then
		base = tonumber(data.BaseSlots) :: number
	end
	-- v1.0.0 never clamped: rebirth slots could push the total past
	-- every cap. Clamp to MaxBasePlots (12 = MaxPlayers).
	return math.min(
		Config.MaxBasePlots or 12,
		base + ProgressionService.GetRebirths(player) * rebirthConfig().SlotsPer
	)
end

-- ---------------------------------------------------------------------------
-- Rebirth
-- ---------------------------------------------------------------------------

-- Rebirth(player): validates all requirements from
-- Config.RebirthRequirements, then resets coins / level / XP / placed
-- slots while KEEPING owned characters (Unlocked + OwnedInstances),
-- wins/KOs, quests and cosmetics. Returns (true, rebirths) or
-- (false, reason).
function ProgressionService.Rebirth(player: Player): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	local cfg = rebirthConfig()
	local level = tonumber(data.Level) or 1
	-- R5-6: judge the coin requirement on SPENDABLE coins — a
	-- pending reward's reserved coins are not the player's to spend.
	local coins = spendableCoins(player, data)
	local distinct = distinctCount(data)
	local rebirths = tonumber(data.Rebirths) or 0
	if rebirths >= cfg.MaxRebirths then
		return false, "max rebirths reached (" .. tostring(cfg.MaxRebirths) .. ")"
	end
	if level < cfg.MinLevel then
		return false, "requires level " .. tostring(cfg.MinLevel)
	end
	if coins < cfg.MinCoins then
		return false, "requires " .. tostring(cfg.MinCoins) .. " coins"
	end
	if distinct < cfg.MinDistinct then
		return false, "requires " .. tostring(cfg.MinDistinct) .. " distinct Brainrots owned"
	end
	rebirths += 1
	-- Reset economy + placed state only. Owned characters stay owned:
	-- Unlocked is untouched, and OwnedInstances keeps every instance
	-- with Placed cleared (placed Brainrots return to the inventory).
	-- v1.0.0 wiped Unlocked to the starter and nilled OwnedInstances,
	-- destroying the whole collection on every rebirth.
	-- R5-6: resetCoins keeps every reserved coin on top of
	-- StartingCoins, so a reward commit open in the save window
	-- survives the reset (success keeps it, rollback subtracts it
	-- exactly).
	data.Coins = resetCoins(player)
	data.XP = 0
	data.Level = 1
	data.Gems = (tonumber(data.Gems) or 0) + cfg.RewardGems
	data.Selected = "wobble_waffleton"
	data.Placed = {}
	if type(data.Base) == "table" then
		-- Placed Brainrots live in data.Base.Placed (BaseService) —
		-- clear that too or the rebirth would keep the old base.
		data.Base.Placed = {}
	end
	if type(data.OwnedInstances) == "table" then
		for _, inst in ipairs(data.OwnedInstances) do
			if type(inst) == "table" then
				inst.Placed = false
				inst.Slot = 0
			end
		end
	end
	local newSlots = math.min(
		Config.MaxBasePlots or 12,
		(Config.BaseSlotsStart or 4) + rebirths * cfg.SlotsPer
	)
	if type(data.Base) == "table" then
		data.Base.Slots = newSlots
	end
	data.BaseSlots = newSlots
	data.Rebirths = rebirths
	-- v1.1: dimension unlocks survive rebirth (data.DimensionUnlocks
	-- is never touched here), and the rebirth counts toward
	-- achievements.
	if _achievementService and type(_achievementService.CheckProgress) == "function" then
		pcall(function()
			_achievementService.CheckProgress(player, "rebirth", 1)
		end)
	end
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient(_names.SpawnEffect, player, {
		type = "Rebirth",
		player = player.Name,
		rebirths = rebirths,
	})
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Rebirths = rebirths,
		Gems = data.Gems,
		BaseSlots = data.BaseSlots,
	})
	print(string.format(
		"[ProgressionService] %s rebirthed (count %d): +%.0f%% income, +%d base slots, +%d gems",
		player.Name, rebirths, cfg.IncomePer * 100, cfg.SlotsPer, cfg.RewardGems
	))
	return true, rebirths
end

-- ---------------------------------------------------------------------------
-- Prestige (v1.1)
-- ---------------------------------------------------------------------------

-- Prestige requirements (this workstream's tuning — Config is frozen
-- and has no prestige rate): 10 rebirths (the max), Level >= 25,
-- 250,000 coins, 15 distinct Brainrots owned.
local PRESTIGE_MIN_REBIRTHS = 10
local PRESTIGE_MIN_LEVEL = 25
local PRESTIGE_MIN_COINS = 250000
local PRESTIGE_MIN_DISTINCT = 15
local PRESTIGE_REWARD_GEMS = 50

-- Prestige(player): consume 10 rebirths for Prestige rank +1. Resets
-- coins / level / XP / rebirths / placed slots (like a rebirth) but
-- KEEPS the collection, dimension unlocks and mastery. Grants +50
-- gems, the "title_prestiged" title, and a permanent +5% income per
-- prestige rank (see GetIncomeMultiplier). Returns (true, prestige)
-- or (false, reason).
function ProgressionService.Prestige(player: Player): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	local cfg = rebirthConfig()
	local level = tonumber(data.Level) or 1
	-- R5-6: judge the coin requirement on SPENDABLE coins (see
	-- Rebirth — a pending reward's reserved coins are not spendable).
	local coins = spendableCoins(player, data)
	local distinct = distinctCount(data)
	local rebirths = tonumber(data.Rebirths) or 0
	local prestige = tonumber(data.Prestige) or 0
	if rebirths < math.min(PRESTIGE_MIN_REBIRTHS, cfg.MaxRebirths) then
		return false, "requires " .. tostring(PRESTIGE_MIN_REBIRTHS) .. " rebirths (currently " .. tostring(rebirths) .. ")"
	end
	if level < PRESTIGE_MIN_LEVEL then
		return false, "requires level " .. tostring(PRESTIGE_MIN_LEVEL)
	end
	if coins < PRESTIGE_MIN_COINS then
		return false, "requires " .. tostring(PRESTIGE_MIN_COINS) .. " coins"
	end
	if distinct < PRESTIGE_MIN_DISTINCT then
		return false, "requires " .. tostring(PRESTIGE_MIN_DISTINCT) .. " distinct Brainrots owned"
	end
	prestige += 1
	-- Reset economy + placed state only — same shape as Rebirth.
	-- Collection (Unlocked / OwnedInstances), dimension unlocks and
	-- mastery are all kept.
	-- R5-6: resetCoins keeps every reserved coin on top of
	-- StartingCoins (see Rebirth).
	data.Coins = resetCoins(player)
	data.XP = 0
	data.Level = 1
	data.Gems = (tonumber(data.Gems) or 0) + PRESTIGE_REWARD_GEMS
	data.Selected = "wobble_waffleton"
	data.Placed = {}
	if type(data.Base) == "table" then
		data.Base.Placed = {}
	end
	if type(data.OwnedInstances) == "table" then
		for _, inst in ipairs(data.OwnedInstances) do
			if type(inst) == "table" then
				inst.Placed = false
				inst.Slot = 0
			end
		end
	end
	local newSlots = Config.BaseSlotsStart or 4
	if type(data.Base) == "table" then
		data.Base.Slots = newSlots
	end
	data.BaseSlots = newSlots
	data.Rebirths = 0
	data.Prestige = prestige
	-- Prestige title (defined in shared/AchievementDefs.luau).
	local titleOwned = false
	for _, ownedId in ipairs(data.Titles) do
		if ownedId == "title_prestiged" then
			titleOwned = true
			break
		end
	end
	if not titleOwned then
		table.insert(data.Titles, "title_prestiged")
	end
	if _achievementService and type(_achievementService.CheckProgress) == "function" then
		pcall(function()
			_achievementService.CheckProgress(player, "prestige", 1)
		end)
	end
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient(_names.SpawnEffect, player, {
		type = "Prestige",
		player = player.Name,
		prestige = prestige,
	})
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Rebirths = 0,
		Prestige = prestige,
		Gems = data.Gems,
		BaseSlots = data.BaseSlots,
	})
	print(string.format(
		"[ProgressionService] %s prestiged (rank %d): +%.0f%% income, +%d gems",
		player.Name, prestige, ProgressionService.PRESTIGE_INCOME_PER_RANK * 100, PRESTIGE_REWARD_GEMS
	))
	return true, prestige
end

-- ---------------------------------------------------------------------------
-- Collection book
-- ---------------------------------------------------------------------------

-- RecordDiscovery(player, characterId): remember a character was found
-- (called by ConveyorService / EconomyService / BossService on grant).
function ProgressionService.RecordDiscovery(player: Player, characterId: any): boolean
	local clean = sanitize(characterId)
	if not clean or not Characters.GetById(clean) then
		return false
	end
	local data = ensureProgressionData(player)
	if not data then
		return false
	end
	for _, id in ipairs(data.CollectionDiscovered) do
		if id == clean then
			return false
		end
	end
	table.insert(data.CollectionDiscovered, clean)
	-- v1.1: collection milestones + absolute achievement progress.
	-- Milestone XP is fed through AddXP (which re-checks milestones;
	-- nothing new claims the second time, so this terminates).
	local milestoneXP = checkMilestones(player, data, tonumber(data.Level) or 1)
	if milestoneXP > 0 then
		ProgressionService.AddXP(player, milestoneXP)
	end
	if _achievementService and type(_achievementService.SetProgress) == "function" then
		pcall(function()
			_achievementService.SetProgress(player, "collection", distinctCount(data))
		end)
	end
	return true
end

-- GetCollection(player): discovered ids + totals, for the client
-- Collection UI. Discovered = Unlocked ∪ Placed ∪ CollectionDiscovered.
function ProgressionService.GetCollection(player: Player): { Discovered: { string }, Total: number, Owned: number, ByRarity: { [string]: number } }
	local data = ensureProgressionData(player)
	local discovered: { [string]: boolean } = {}
	if data then
		local function add(id: any)
			if type(id) == "string" and Characters.GetById(id) then
				discovered[id] = true
			end
		end
		if type(data.Unlocked) == "table" then
			for _, id in ipairs(data.Unlocked) do
				add(id)
			end
		end
		if type(data.Placed) == "table" then
			for _, placed in ipairs(data.Placed) do
				if type(placed) == "table" then
					add(placed.CharacterId)
				end
			end
		end
		-- Placed Brainrots live in data.Base.Placed (BaseService's
		-- shape); v1.0.0 only read the legacy data.Placed, so placed
		-- Brainrots never counted as discovered in the collection book.
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			for _, placed in ipairs(data.Base.Placed) do
				if type(placed) == "table" then
					add(placed.CharacterId)
				end
			end
		end
		if type(data.CollectionDiscovered) == "table" then
			for _, id in ipairs(data.CollectionDiscovered) do
				add(id)
			end
		end
	end
	local ids: { string } = {}
	local byRarity: { [string]: number } = {}
	for id in pairs(discovered) do
		table.insert(ids, id)
		local def = Characters.GetById(id)
		if def then
			byRarity[def.Rarity] = (byRarity[def.Rarity] or 0) + 1
		end
	end
	table.sort(ids)
	return {
		Discovered = ids,
		Total = Characters.GetCount(),
		Owned = #ids,
		ByRarity = byRarity,
	}
end

-- ---------------------------------------------------------------------------
-- Cosmetics (visual only — no gameplay advantage).
-- ---------------------------------------------------------------------------

function ProgressionService.IsCosmeticUnlocked(player: Player, cosmeticId: string): boolean
	local def = _cosmeticById[cosmeticId]
	if not def then
		return false
	end
	local data = ensureProgressionData(player)
	if not data then
		return false
	end
	local req = def.Requirement
	if req.Level and (tonumber(data.Level) or 1) < req.Level then
		return false
	end
	if req.Rebirths and (tonumber(data.Rebirths) or 0) < req.Rebirths then
		return false
	end
	if req.Distinct and distinctCount(data) < req.Distinct then
		return false
	end
	return true
end

function ProgressionService.GetCosmetics(player: Player): { any }
	local data = ensureProgressionData(player)
	if not data then
		return {}
	end
	local out: { any } = {}
	for _, def in ipairs(COSMETICS) do
		table.insert(out, {
			Id = def.Id,
			Name = def.Name,
			Kind = def.Kind,
			Unlocked = ProgressionService.IsCosmeticUnlocked(player, def.Id),
			Equipped = data.Cosmetics.Equipped[def.Kind] == def.Id,
		})
	end
	return out
end

-- EquipCosmetic(player, id): validated against unlocks; stores the
-- equipped cosmetic per Kind. Returns (true) or (false, reason).
function ProgressionService.EquipCosmetic(player: Player, cosmeticId: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(cosmeticId)
	if not clean or not _cosmeticById[clean] then
		return false, "unknown cosmetic"
	end
	if not ProgressionService.IsCosmeticUnlocked(player, clean) then
		return false, "cosmetic not unlocked"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	local def = _cosmeticById[clean]
	data.Cosmetics.Equipped[def.Kind] = clean
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient(_names.PlayerStats, player, {
		Action = "CosmeticEquipped",
		CosmeticId = clean,
		Kind = def.Kind,
	})
	return true, nil
end

local function onRebirthRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	-- v1.1: the Rebirth remote carries both actions — Rebirth and
	-- Prestige — distinguished by the Action envelope (same pattern
	-- as the existing Rebirth / EquipCosmetic envelopes).
	if payload.Action == "Rebirth" then
		if not rateOk(player, "Rebirth", 5) then
			return
		end
		local ok, err = ProgressionService.Rebirth(player)
		if not ok then
			warn("[ProgressionService] Rebirth failed for " .. player.Name .. ": " .. tostring(err))
		end
	elseif payload.Action == "Prestige" then
		if not rateOk(player, "Prestige", 5) then
			return
		end
		local ok, err = ProgressionService.Prestige(player)
		if not ok then
			warn("[ProgressionService] Prestige failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
end

local function onSelectRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" or payload.Action ~= "EquipCosmetic" then
		return
	end
	if not rateOk(player, "EquipCosmetic", 1) then
		return
	end
	local ok, err = ProgressionService.EquipCosmetic(player, payload.CosmeticId)
	if not ok then
		warn("[ProgressionService] EquipCosmetic failed for " .. player.Name .. ": " .. tostring(err))
	end
end

-- SetAchievementService: lets AddXP / Rebirth / Prestige /
-- RecordDiscovery report absolute achievement progress (level /
-- collection) and rebirth / prestige counts. Wired by
-- AchievementService.Init (it calls this when it loads) or by
-- GameManager.wireCrossLinks when the setter name is added to its
-- shared table. Until then, achievement reporting from this service
-- is skipped (quests / challenges still work).
function ProgressionService.SetAchievementService(achievementService: any)
	if achievementService and type(achievementService.CheckProgress) == "function" then
		_achievementService = achievementService
	end
end

function ProgressionService.Init(dataService: any)
	assert(dataService ~= nil, "[ProgressionService] Init requires DataService")
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	local rebirthRemote = _names.Rebirth or _names.UpgradeBase
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(rebirthRemote)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onRebirthRemote)
		else
			warn("[ProgressionService] Remote not found, rebirth handler not wired: " .. tostring(rebirthRemote))
		end
	end)

	local cosmeticRemote = _names.EquipCosmetic or _names.SelectCharacter
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(cosmeticRemote)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onSelectRemote)
		else
			warn("[ProgressionService] Remote not found, cosmetic handler not wired: " .. tostring(cosmeticRemote))
		end
	end)

	-- RequestCollection (RemoteFunction): the collection book's pull
	-- path. v1.0.1 integration QA — GetCollection existed but no
	-- handler did, so InvokeServer errored. Returns the same shape
	-- CollectionController reads from RequestShop (Discovered ids,
	-- totals, ByRarity).
	local collectionFnName = _names.RequestCollection or "RequestCollection"
	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction(collectionFnName)
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(player: Player)
				return ProgressionService.GetCollection(player)
			end
		else
			warn("[ProgressionService] RemoteFunction not found, RequestCollection not wired: " .. tostring(collectionFnName))
		end
	end)
end

return ProgressionService
