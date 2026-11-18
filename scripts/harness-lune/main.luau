-- GLITCH TIDE pure-logic harness — 40 checks over the 14 shared modules.
--
-- Recreated 2026-11-19 for the make.fun package re-verification pass
-- (Task C), faithfully from the v1.0.2 QA report (QA_TEST_REPORT.md §3,
-- T5/T10). The original /tmp/lune_harness/ was lost when /tmp was wiped;
-- this copy lives in the package (scripts/harness-lune/) so it survives,
-- and is the harness of record from here on.
--
-- v1.1 update (2026-11-19, integration): expectations moved to v1.1
-- (GameVersion 1.1.0, roster 27, 10 tide variants, 19 fusion recipes,
-- full-roster synergy 2.8, GetSortedByCost 27) + 7 new checks (34-40)
-- over the new shared def modules (Companions, Dimensions, LabDefs,
-- ExpeditionDefs, AchievementDefs) and the 17 v1.1 remotes.
--
-- Run:  bash scripts/harness-lune/refresh.sh && lune run scripts/harness-lune/main.luau
-- refresh.sh copies src/shared/*.luau into scripts/harness-lune/shared/
-- and applies the harness-only require patch (require(script.Parent.X)
-- -> require("./X")); the project files are never touched.
-- The shared modules are loaded with stubbed Roblox globals (game,
-- Color3, Enum, Vector3, BrickColor, CFrame, Instance). Only pure logic
-- is exercised: QuestService / TideService / ProgressionService need
-- live Roblox services and are NOT executed here (see QA report §6).
-- Exit 0 iff all 40 checks pass (any failure raises, so Lune exits non-zero).

-- --- Stubbed Roblox globals (load-time only; no function under test calls them) ---
local function stubService(name)
	return {
		Name = name,
		IsServer = function()
			return false
		end,
		IsClient = function()
			return true
		end,
		FindFirstChild = function()
			return nil
		end,
		WaitForChild = function()
			error("stub: WaitForChild must not run in the pure-logic harness")
		end,
	}
end

game = {
	GetService = function(_, name)
		return stubService(name)
	end,
}

Color3 = {
	fromRGB = function(r, g, b)
		return { R = r / 255, G = g / 255, B = b / 255 }
	end,
	new = function(r, g, b)
		return { R = r or 0, G = g or 0, B = b or 0 }
	end,
}

local Vector3MT = {}
Vector3MT.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	end
	return nil
end
Vector3MT.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3MT.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3 = {
	new = function(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3MT)
	end,
}

local function anyEnum()
	-- Any member access returns its own name: enough for the Enum values
	-- the shared modules touch (PartType, Material, KeyCode).
	return setmetatable({}, {
		__index = function(_, k)
			return k
		end,
	})
end
Enum = {
	PartType = anyEnum(),
	Material = anyEnum(),
	KeyCode = anyEnum(),
}

BrickColor = {
	new = function(name)
		return { Name = name }
	end,
}

CFrame = {
	new = function(...)
		return {}
	end,
	Angles = function(...)
		return {}
	end,
}

Instance = {
	new = function(_className)
		return {}
	end,
}

-- --- Load the shared modules (fresh copies under ./shared/) ---
local Config = require("./shared/Config")
local Characters = require("./shared/Characters")
local Mutations = require("./shared/Mutations")
local Powers = require("./shared/Powers")
local Economy = require("./shared/Economy")
local Synergies = require("./shared/Synergies")
local Remotes = require("./shared/Remotes")
local Utils = require("./shared/Utils")
local Companions = require("./shared/Companions")
local Dimensions = require("./shared/Dimensions")
local LabDefs = require("./shared/LabDefs")
local ExpeditionDefs = require("./shared/ExpeditionDefs")
local AchievementDefs = require("./shared/AchievementDefs")

local passed = 0
local failed = {}

local function check(n, name, ok, detail)
	if ok then
		passed += 1
		print(`PASS {string.format("%02d", n)}  {name}` .. (detail and ` -- {detail}` or ""))
	else
		table.insert(failed, n)
		print(`FAIL {string.format("%02d", n)}  {name}` .. (detail and ` -- {detail}` or ""))
	end
end

local function close(a, b)
	return math.abs(a - b) < 1e-9
end

-- 01. GameVersion
check(1, "GameVersion is 1.1.0", Config.GameVersion == "1.1.0", Config.GameVersion)

-- 02. Rarity weights sum to 1.0
local wsum = 0
local wtier = 0
for _, v in Config.RarityWeights do
	wsum += v
	wtier += 1
end
check(2, "RarityWeights sum to 1.0 over 10 tiers", wtier == 10 and close(wsum, 1), `sum={wsum} tiers={wtier}`)

-- 03. Plots / players
check(3, "MaxBasePlots == MaxPlayers == 12", Config.MaxBasePlots == 12 and Config.MaxPlayers == 12)

-- 04. Fusion costs
check(4, "FusionCosts 1000 coins + 25 crystals",
	Config.FusionCosts.Coins == 1000 and Config.FusionCosts.MutationCrystals == 25)

-- 05-06. Rebirth requirements and rewards
local rr = Config.RebirthRequirements
check(5, "Rebirth requires Level 25, 100,000 coins, 10 distinct Brainrots",
	rr.Level == 25 and rr.Coins == 100000 and rr.Brainrots == 10)
check(6, "Rebirth grants +10% income, +2 slots, 25 gems, max 10 rebirths",
	close(rr.IncomeBonusPerRebirth, 0.10) and rr.SlotsPerRebirth == 2
		and rr.RewardGems == 25 and rr.MaxRebirths == 10)

-- 07. Playable tide variations + weights
local tvar = 0
local tw = 0
for _, v in Config.TideVariations do
	tvar += 1
	tw += v.Weight
end
check(7, "10 playable tide variations, weights sum to 100",
	tvar == 10 and tw == 100
		and Config.TideVariations.Standard ~= nil
		and Config.TideVariations.Fast ~= nil
		and Config.TideVariations.Toxic ~= nil
		and Config.TideVariations.Frozen ~= nil
		and Config.TideVariations.Meteor ~= nil
		and Config.TideVariations.Double ~= nil
		and Config.TideVariations.Dark ~= nil
		and Config.TideVariations.GiantBoss ~= nil
		and Config.TideVariations.Corrupted ~= nil
		and Config.TideVariations.Cosmic ~= nil,
	`variations={tvar} weight={tw}`)

-- 08-10. Roster
local all = Characters.GetAll()
check(8, "27-character roster", #all == 27 and Characters.GetCount() == 27, `count={#all}`)
local raritySet = {}
for _, def in all do
	raritySet[def.Rarity] = true
end
local nrar = 0
for _ in raritySet do
	nrar += 1
end
check(9, "10 rarities on the roster", nrar == 10, `rarities={nrar}`)
local incomeOk = true
for _, def in all do
	if def.IncomePerSec <= 0 or def.Cost < 0 then
		incomeOk = false
	end
end
check(10, "every character has positive income and non-negative cost", incomeOk)

-- 11. AbilityIds resolve
local abilityOk = true
for _, def in all do
	if Powers.GetById(def.AbilityId) == nil then
		abilityOk = false
	end
end
check(11, "every roster AbilityId resolves to a Power", abilityOk)

-- 12. Epic rank
check(12, 'GetRarityRank("Epic") >= 4', Characters.GetRarityRank("Epic") >= 4,
	`rank={Characters.GetRarityRank("Epic")}`)

-- 13. Mutations
local muts = Mutations.GetAll()
check(13, "12 mutations, no Magma/Spectral",
	#muts == 12 and Mutations.GetCount() == 12
		and Mutations.GetById("Magma") == nil
		and Mutations.GetById("Spectral") == nil,
	`count={#muts}`)

-- 14-17. Fusion recipes
local recipe = Mutations.GetFusionRecipe("wobble_waffleton", "turbo_turnip")
check(14, "fusion recipe lookup (wobble_waffleton + turbo_turnip)",
	recipe ~= nil and recipe.ResultId == "bloop_bloomington")
local swapped = Mutations.GetFusionRecipe("turbo_turnip", "wobble_waffleton")
check(15, "fusion recipe lookup is order-independent",
	swapped ~= nil and swapped.ResultId == (recipe and recipe.ResultId or nil))
check(16, "unknown pair has no recipe",
	Mutations.GetFusionRecipe("wobble_waffleton", "wobble_waffleton") == nil)
local resultsOk = true
for _, r in Mutations.FusionRecipes do
	if Characters.GetById(r.ResultId) == nil then
		resultsOk = false
	end
end
check(17, "all 19 fusion recipe results are real characters",
	#Mutations.FusionRecipes == 19 and resultsOk)

-- 18-19. FusionCost
local fc = Economy.FusionCost("wobble_waffleton", "turbo_turnip")
check(18, "FusionCost present case: 1000 coins + 25 crystals",
	fc ~= nil and fc.Coins == 1000 and fc.MutationCrystals == 25)
check(19, "FusionCost nil case: unknown pair",
	Economy.FusionCost("wobble_waffleton", "wobble_waffleton") == nil)

-- 20-22. XP / wave / KO scaling
check(20, "XPForLevel increasing",
	Economy.XPForLevel(2) > Economy.XPForLevel(1)
		and Economy.XPForLevel(10) > Economy.XPForLevel(2))
check(21, "CoinsForWave increasing",
	Economy.CoinsForWave(2) > Economy.CoinsForWave(1)
		and Economy.CoinsForWave(10) > Economy.CoinsForWave(2))
check(22, "KO reward scales with streak",
	Economy.CalculateKOReward(5) > Economy.CalculateKOReward(0))

-- 23-24. Synergy bonuses
check(23, "synergy bonus 0 for an empty list", close(Synergies.GetSynergyBonus({}), 0))
local ids = {}
for _, def in all do
	table.insert(ids, def.Id)
end
local fullBonus = Synergies.GetSynergyBonusForCharacters(ids)
check(24, "synergy bonus 2.8 for the full roster", close(fullBonus, 2.8), `bonus={fullBonus}`)

-- 25-27. Income formula
local starter = { CharacterId = "wobble_waffleton", Level = 1 }
local base = Economy.IncomePerSecond(starter)
local lvl5 = Economy.IncomePerSecond({ CharacterId = "wobble_waffleton", Level = 5 })
check(25, "income: level 5 is 2x level 1", close(lvl5, 2 * base), `L1={base} L5={lvl5}`)
local golden = Economy.IncomePerSecond({ CharacterId = "wobble_waffleton", Level = 1, Mutation = "Golden" })
check(26, "income: Golden mutation is 2.5x", close(golden, 2.5 * base), `golden={golden}`)
local list = { starter }
local tide2 = Economy.BaseIncomePerSecond(list, 2)
local both = Economy.BaseIncomePerSecond(list, 4)
check(27, "income: Tide 2x x Golden Hour 2x = 4x",
	close(tide2, 2 * base) and close(both, 4 * base), `tide2={tide2} both={both}`)

-- 28. Remotes
check(28, "Remotes.Names holds the core heist remotes",
	Remotes.Names.RequestQuests ~= nil
		and Remotes.Names.RequestShop ~= nil
		and Remotes.Names.RequestBase ~= nil
		and Remotes.Names.BuyCharacter ~= nil
		and Remotes.Names.FuseBrainrot ~= nil)

-- 29. Keybinds
local kb = Config.Keybinds
check(29, "keybinds Q/F/R/E/G + loadout 1/2/3",
	kb.Primary == "Q" and kb.Slam == "F" and kb.Heal == "R"
		and kb.Interact == "E" and kb.Drop == "G"
		and kb.Loadout1 == "1" and kb.Loadout2 == "2" and kb.Loadout3 == "3")

-- 30. Rarity lookup
check(30, "GetByRarity('Epic') non-empty",
	#Characters.GetByRarity("Epic") > 0 and #Characters.GetByRarity("Common") > 0)

-- 31. Mutation multipliers and rebirth gating
check(31, "Golden 2.5x; rebirth gating Void 1, Celestial 1, Rainbow 2",
	close(Mutations.GetMultiplier("Golden"), 2.5)
		and Mutations.GetMinRebirths("Void") == 1
		and Mutations.GetMinRebirths("Celestial") == 1
		and Mutations.GetMinRebirths("Rainbow") == 2)

-- 32. Sorted-by-cost ordering
local byCost = Characters.GetSortedByCost()
check(32, "GetSortedByCost is ascending by cost",
	#byCost == 27 and byCost[1].Cost <= byCost[#byCost].Cost)

-- 33. Utils helpers (Config is absent under the stub, so defaults apply)
local binds = Utils.GetKeybinds()
check(33, "Utils: GetKeybinds Interact E / Drop G; FormatNumber 1,000; GetDistance 5 for 3-4-5",
	binds.Interact == "E" and binds.Drop == "G"
		and Utils.FormatNumber(1000) == "1,000"
		and close(Utils.GetDistance(Vector3.new(0, 0, 0), Vector3.new(3, 4, 0)), 5))

-- 34. The 9 new v1.1 characters (one per tier Common..Secret)
local newIds = {
	"phantom_pancake",
	"prism_penguin",
	"neon_narwhal",
	"reactor_raccoon",
	"gravity_goblin",
	"thunder_tortoise",
	"quantum_quokka",
	"solar_sloth",
	"void_vulture",
}
local newOk = true
for _, id in newIds do
	if Characters.GetById(id) == nil then
		newOk = false
	end
end
check(34, "9 new v1.1 characters resolve", newOk)

-- 35. Playable powers: 17, all cooldowns >= 3s
local playable = Powers.GetPlayablePowers()
local coolOk = true
for _, def in playable do
	if (def.Cooldown or 0) < 3 then
		coolOk = false
	end
end
check(35, "17 playable powers, every cooldown >= 3s", #playable == 17 and coolOk, `count={#playable}`)

-- 36. Companion abilities on 15 characters
local compCount = 0
for _, def in all do
	if def.CompanionAbility ~= nil then
		compCount += 1
	end
end
check(36, "15 characters carry a CompanionAbility", compCount == 15, `count={compCount}`)

-- 37. Disabled tide table is gone
check(37, "TideVariationsDisabled deleted", Config.TideVariationsDisabled == nil)

-- 38. Dimensions: Abyssal + Skyfall
local dims = Dimensions.GetAll()
check(38, "Dimensions has Abyssal + Skyfall",
	#dims == 2 and Dimensions.GetById("abyssal") ~= nil and Dimensions.GetById("skyfall") ~= nil,
	`count={#dims}`)

-- 39. Expeditions / achievements / titles
check(39, "6 expeditions, 24 achievements, 13 titles",
	#ExpeditionDefs.GetAll() == 6
		and #AchievementDefs.GetAll() == 24
		and #AchievementDefs.GetTitles() == 13)

-- 40. v1.1 remotes present
check(40, "Remotes.Names holds the v1.1 remotes",
	Remotes.Names.TeleportDimension ~= nil
		and Remotes.Names.RequestLab ~= nil
		and Remotes.Names.EvolveBrainrot ~= nil
		and Remotes.Names.RequestExpeditions ~= nil
		and Remotes.Names.StartExpedition ~= nil
		and Remotes.Names.RequestTerritories ~= nil
		and Remotes.Names.CaptureTerritory ~= nil
		and Remotes.Names.SecretDiscovered ~= nil
		and Remotes.Names.RequestAchievements ~= nil
		and Remotes.Names.EquipTitle ~= nil)

print(`\n{passed} passed, {#failed} failed (of 40)`)
if #failed > 0 then
	error(`FAILED checks: {table.concat(failed, ", ")}`)
end
