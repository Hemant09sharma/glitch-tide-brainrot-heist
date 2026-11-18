--!strict
-- Economy.luau
-- Pure reward / progression functions. No state, no side effects, so
-- server and client can share the exact same math.

local Characters = require("./Characters")
local Config = require("./Config")
local Mutations = require("./Mutations")

local Economy = {}

local BASE_XP_PER_LEVEL = 100
local XP_GROWTH_PER_LEVEL = 25

-- KO reward grows with the killer's current streak, capped so one
-- dominant player cannot farm unlimited coins in a single match.
function Economy.CalculateKOReward(streak: number): number
	local safeStreak = math.max(0, math.floor(streak))
	local bonus = math.min(safeStreak * 5, 50)
	return 25 + bonus
end

-- Win bonus scales mildly with lifetime wins so veterans are rewarded
-- without making early wins worthless.
function Economy.CalculateWinBonus(wins: number): number
	local safeWins = math.max(0, math.floor(wins))
	local bonus = math.min(safeWins * 2, 100)
	return 100 + bonus
end

-- Total XP required to go from `level` to `level + 1`.
function Economy.XPForLevel(level: number): number
	local safeLevel = math.max(1, math.floor(level))
	return BASE_XP_PER_LEVEL + (safeLevel - 1) * XP_GROWTH_PER_LEVEL
end

-- Total cumulative XP required to reach `level` (level 1 needs 0).
function Economy.TotalXPForLevel(level: number): number
	local safeLevel = math.max(1, math.floor(level))
	local total = 0
	for lvl = 1, safeLevel - 1 do
		total += Economy.XPForLevel(lvl)
	end
	return total
end

-- Level implied by a lifetime XP total.
function Economy.LevelFromXP(xp: number): number
	local safeXP = math.max(0, math.floor(xp))
	local level = 1
	local remaining = safeXP
	while remaining >= Economy.XPForLevel(level) do
		remaining -= Economy.XPForLevel(level)
		level += 1
		if level >= 100 then
			break
		end
	end
	return level
end

-- XP progress (0..1) toward the next level from a lifetime XP total.
function Economy.XPProgress(xp: number): number
	local level = Economy.LevelFromXP(xp)
	local intoLevel = math.max(0, math.floor(xp)) - Economy.TotalXPForLevel(level)
	local needed = Economy.XPForLevel(level)
	if needed <= 0 then
		return 1
	end
	return math.clamp(intoLevel / needed, 0, 1)
end

-- Coins awarded for clearing a PvE wave. Boss waves pay double.
function Economy.CoinsForWave(wave: number): number
	local safeWave = math.max(1, math.floor(wave))
	local base = 10 + safeWave * 5
	if safeWave % 5 == 0 then
		base *= 2
	end
	return base
end

function Economy.CanAfford(coins: number, cost: number): boolean
	return coins >= cost
end

-- Daily login bonus: 50 base, +10 per consecutive day, capped at day 7.
function Economy.DailyBonusAmount(dayStreak: number): number
	local streak = math.clamp(math.floor(dayStreak), 1, 7)
	return 50 + (streak - 1) * 10
end

-- Coins left after a purchase, or nil when the player cannot afford it.
function Economy.SpendCoins(coins: number, cost: number): number?
	if not Economy.CanAfford(coins, cost) then
		return nil
	end
	return coins - cost
end

-- -------------------------------------------------------------------------
-- Glitch Tide heist economy
-- -------------------------------------------------------------------------

export type PlacedBrainrotInput = {
	CharacterId: string,
	Level: number?,
	Glitched: boolean?,
	Mutation: string?,
}

-- Passive income per second for one Brainrot placed in a base.
-- Level adds +25% per level; a glitched Brainrot earns double; a
-- mutation multiplies income by its IncomeMultiplier.
--
-- Mutation ids are matched case-insensitively against the shared
-- Mutations table (MutationService stores them lowercase, e.g.
-- "golden", while the shared table keys them "Golden"). A "Glitched"
-- mutation is NOT stacked on top of the Glitched flag: the flag
-- already pays x2 for a glitched Brainrot, and the mutation is the
-- same effect under another name — multiplying both would pay x7.
-- (Mutations the shared table does not know, e.g. MutationService's
-- "Magma" / "Spectral", pay no bonus here; that table drift lives in
-- MutationService, not in this formula.)
local function mutationMultiplier(mutationId: string?, glitched: boolean): number
	if mutationId == nil or mutationId == "" then
		return 1
	end
	local canonical: string? = nil
	for _, def in ipairs(Mutations.GetAll()) do
		if string.lower(def.Id) == string.lower(mutationId) then
			canonical = def.Id
			break
		end
	end
	if canonical == nil then
		return 1
	end
	if canonical == "Glitched" and glitched then
		return 1
	end
	return Mutations.GetMultiplier(canonical)
end

function Economy.IncomePerSecond(placed: PlacedBrainrotInput): number
	local def = Characters.GetById(placed.CharacterId)
	if def == nil then
		return 0
	end
	local maxLevel = tonumber(Config.MaxBrainrotLevel) or 5
	local levelBonus = tonumber(Config.BrainrotLevelIncomeBonus) or 0.25
	local level = math.clamp(math.floor(placed.Level or 1), 1, maxLevel)
	local income = def.IncomePerSec * (1 + (level - 1) * levelBonus)
	if placed.Glitched then
		income *= 2
	end
	income *= mutationMultiplier(placed.Mutation, placed.Glitched == true)
	return income
end

-- Total passive income per second across a whole base.
function Economy.BaseIncomePerSecond(placedList: { PlacedBrainrotInput }, incomeMultiplier: number?): number
	local total = 0
	for _, placed in placedList do
		total += Economy.IncomePerSecond(placed)
	end
	return total * (incomeMultiplier or 1)
end

-- Cost of the next level of an upgrade kind, given the current level.
-- kind: "BaseSlot" | "IncomeMultiplier" | "Lock" | "Turret" |
--       "ConveyorLuck" | "BrainrotLevel". Returns nil when maxed out.
-- Indexing follows the Config comment ("level 1 -> cost to reach 2"):
-- Brainrot levels are 1-based, so the cost out of level N is table[N];
-- the base-upgrade kinds count upgrades already bought (0-based), so
-- the cost of the next one is table[level + 1].
function Economy.UpgradeCost(kind: string, level: number): number?
	local table: { number }? = nil
	if kind == "BaseSlot" then
		table = Config.BaseSlotCost
	elseif kind == "IncomeMultiplier" then
		table = Config.IncomeMultiplierCost
	elseif kind == "Lock" then
		table = Config.LockCost
	elseif kind == "Turret" then
		table = Config.TurretCost
	elseif kind == "ConveyorLuck" then
		table = Config.ConveyorLuckCost
	elseif kind == "BrainrotLevel" then
		table = Config.BrainrotLevelCost
	else
		return nil
	end
	local index = math.floor(level) + 1
	if kind == "BrainrotLevel" then
		index = math.floor(level)
	end
	if index < 1 or index > #table then
		return nil
	end
	return table[index]
end

-- Price of a Brainrot on the conveyor. Glitched ones cost 1.5x.
function Economy.ConveyorPrice(characterId: string, glitched: boolean?): number
	local def = Characters.GetById(characterId)
	if def == nil then
		return 0
	end
	if glitched then
		return math.floor(def.Cost * 1.5 + 0.5)
	end
	return def.Cost
end

-- What a thief walks away with after stealing a Brainrot: half of the
-- income that Brainrot had banked in the victim's base, plus a flat
-- bonus scaled to the Brainrot's rarity income.
function Economy.StealReward(characterId: string, bankedIncome: number): number
	local def = Characters.GetById(characterId)
	if def == nil then
		return 0
	end
	local banked = math.max(0, math.floor(bankedIncome))
	local share = math.floor(banked * Config.StealRewardMultiplier)
	return share + def.IncomePerSec * 10
end

-- Cost of fusing two Brainrots (coins + Mutation Crystals), or nil
-- when the pair has no fusion recipe.
function Economy.FusionCost(characterIdA: string, characterIdB: string): { Coins: number, MutationCrystals: number }?
	if Mutations.GetFusionRecipe(characterIdA, characterIdB) == nil then
		return nil
	end
	return {
		Coins = Config.FusionCosts.Coins,
		MutationCrystals = Config.FusionCosts.MutationCrystals,
	}
end

return Economy
