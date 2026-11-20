-- m01_r5_1_old_logic.luau — NEGATIVE CONTROL for R5-1 (P0):
-- The same Qwen profile-wipe sequence as test 01, run against the
-- PRE-R5 DataService (mutant/DataServiceR4.luau: a missing store
-- counts as a successful load). The control PASSES when the OLD bad
-- outcome is observed: the outage load is saveable, there is no
-- SaveWarning, the post-recovery SaveData lands, and the genuine
-- profile is overwritten with defaults (5000 coins + keepsake ->
-- 150 coins, no keepsake). If this control failed, test 01 would
-- pass even against the broken code.
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh
local R5 = require("../r5_env")
local P = R5.P
local H = R5.H
local store = R5.store

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local userId = 9501
local keepsakeId = "r5-1-keepsake"
local genuine = {
	Level = 12,
	Coins = 5000,
	Gems = 25,
	MutationCrystals = 100,
	Rebirths = 1,
	Unlocked = { "wobble_waffleton", "turbo_turnip" },
	OwnedInstances = {
		{
			InstanceId = keepsakeId,
			CharacterId = "wobble_waffleton",
			Level = 7,
			Mutation = "golden",
			Placed = true,
			Slot = 2,
			PlacedAt = 1000000,
			BankedIncome = 800,
		},
	},
	Base = { Placed = {
		{ InstanceId = keepsakeId, CharacterId = "wobble_waffleton", Slot = 2, Level = 7, Glitched = false, Mutation = "golden", BankedIncome = 800, PlacedAt = 1000000 },
	} },
	LabDiscoveries = {},
	LastLogin = os.time(),
}
store:seed(P.mainKey(userId), genuine)

R5.setDataStoreOutage(true)
local env = R5.newEnv({ dsPath = "./mutant/DataServiceR4" })
local DS = env.dataService

local player = H.newPlayer(userId, "Player9501", 30, Vector3.new(0, 0, 0))
DS.LoadData(player)
check("old: the outage load IS saveable (the defect)",
	DS.IsSaveable(player) == true)
check("old: no SaveWarning is produced for the failed load",
	DS.GetSaveWarning(player) == nil)
check("old: no RetryLoad exists (no safe recovery path)",
	type(DS.RetryLoad) ~= "function")

R5.setDataStoreOutage(false)
check("old: SaveData lands after the store recovers (the wipe)",
	DS.SaveData(player) == true)
local stored = store:peek(P.mainKey(userId))
check("old: the stored profile IS overwritten with defaults (5000 -> 150, keepsake gone)",
	math.floor(tonumber(stored and stored.Coins) or 0) == 150
		and H.findOwned(stored, keepsakeId) == nil,
	"storedCoins=" .. tostring(stored and stored.Coins))

H.finish()
