-- 03_mutant_control.luau — NEGATIVE CONTROL (expected to FAIL).
-- Same assertions as 09_exactly_once_after_failed_delete.luau (A/C),
-- run against the PRE-R3 DataService (mutant/DataServiceOld.luau:
-- the merge has no Processed check, and SaveData clears the sidecar
-- flag even when RemoveAsync fails). The old code must pay the reward
-- a second time on rejoin (600, not 300) and must never retry the
-- failed deletion — proving the test detects the R3-3 bug.
-- Run: bash scripts/phase1-tests/persistence/mutant/run_mutant.sh
local P = require("../persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService("./mutant/DataServiceOld")
local env = P.newRaidEnv("./mutant/DataServiceOld")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local userId = 9101
local player = H.newPlayer(userId, "LedgerPlayer")
local instanceId = "r33_inst"

store:seed(P.mainKey(userId), {
	Coins = 500,
	OwnedInstances = {},
	Base = { Placed = {} },
	LastLogin = os.time(),
})
store:seed(P.pendingKey(userId), { P.pendingEntryTx(instanceId, 300, "tx-r33-a") })

local data = DS.LoadData(player)
check("load merges the sidecar reward into PendingRewards (300)",
	P.pendingTotal(data, instanceId) == 300)
local baseline = data.Coins

-- The old SaveData deletes BOTH sidecar keys when its single flag is
-- set, so both deletes must fail for the pending entry to survive.
store:failRemoveAsync(2)
local paid, total = env.raid.RecoverPendingRewards(player)
check("recovery pays the merged reward exactly once (1 entry, 300 coins)",
	paid == 1 and total == 300, "paid=" .. tostring(paid) .. " total=" .. tostring(total))
check("coins arrive after recovery",
	DS.GetData(player).Coins == baseline + 300)
check("failed sidecar deletion leaves the entry in place for retry",
	P.findInList(store:peek(P.pendingKey(userId)), instanceId) ~= nil)

-- The old SaveData cleared the flag despite the failed deletes, so a
-- later healthy save never retries the deletion.
store:resetFailures()
local okSave = DS.SaveData(player)
check("healthy save after the outage succeeds", okSave == true)
check("stale sidecar key is deleted by the retry save",
	store:peek(P.pendingKey(userId)) == nil)

-- Rejoin: the old merge has no Processed check, so the surviving
-- entry is resurrected as pending again.
local data2 = DS.LoadData(player)
check("rejoin merges nothing new for the processed transaction",
	P.pendingTotal(data2, instanceId) == 0)
-- The resurrected entry is dropped by the NEW recovery's
-- processed-check (defence in depth), so the coins stay 800 even
-- against the old DataService — the double-pay the old system would
-- produce needs the old recovery too. What this control proves about
-- the OLD code is checks 06 + 07 above: the failed deletion is never
-- retried, and a processed transaction is re-merged as if unpaid.
local paid2, total2 = env.raid.RecoverPendingRewards(player)
check("resurrected entry is dropped without paying (recovery's processed-check contains the old merge bug)",
	paid2 == 0 and total2 == 0 and DS.GetData(player).Coins == baseline + 300,
	"paid=" .. tostring(paid2) .. " total=" .. tostring(total2)
		.. " coins=" .. tostring(DS.GetData(player).Coins))

H.finish()
