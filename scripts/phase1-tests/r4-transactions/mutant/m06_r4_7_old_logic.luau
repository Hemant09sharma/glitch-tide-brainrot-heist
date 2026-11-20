-- m06_r4_7_old_logic.luau — NEGATIVE CONTROL for R4-7 (Test G):
-- The same two-server interleaving as test 06, run with the R3
-- mutant DataService as server B (acquireSessionLease always
-- succeeds: no lease contention, last-write-wins) and the FIXED
-- DataService as server A (which holds the lease). The control
-- PASSES when the OLD bad outcome is observed: B loads without
-- seeing the session as contested, B's save lands, and A's newer
-- data is silently overwritten.
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local R = require("../r4_env")
local P = R.P
local H = R.H
local store = R.store
local envM = R.newEnv({ dsPath = "./mutant/DataServiceR3" })
local DSM = envM.dataService
local DSA = require("../services/DataService")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local player = H.newPlayer(9661, "Player9661", 30, Vector3.new(0, 0, 0))
P.store:seed(P.mainKey(9661), {
	Level = 5, Coins = 5000, Gems = 0, MutationCrystals = 1000, Rebirths = 0,
	Unlocked = { "wobble_waffleton", "turbo_turnip", "glitchy_goose" },
	OwnedInstances = {}, Base = { Placed = {} }, LabDiscoveries = {},
	LastLogin = os.time(),
})
DSA.LoadData(player)
check("setup: server A (fixed) loads the player saveably", DSA.IsSaveable(player) == true)
assert(DSA.SaveData(player) == true, "setup: server A baseline save must land")

-- Server B (mutant) loads the same profile while A holds the lease.
DSM.LoadData(player)
check("OLD BUG REPRODUCED: mutant server B does NOT see the session as contested",
	DSM.GetSaveBlockedReason(player) == nil)
check("OLD BUG REPRODUCED: mutant server B is saveable", DSM.IsSaveable(player) == true)
DSM.AddCoins(player, 9999)
check("OLD BUG REPRODUCED: mutant server B's save lands (last-write-wins)",
	DSM.SaveData(player) == true)
check("OLD BUG REPRODUCED: the stored key holds B's overwrite (14999) — A's data is lost",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 14999,
	"coins=" .. tostring(store:peek(P.mainKey(player.UserId)).Coins))

H.finish()
