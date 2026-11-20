-- m02_r4_2_old_logic.luau — NEGATIVE CONTROL for R4-2 (Test B):
-- The same sequence as test 02, run against the R3 mutant
-- RaidService (park result ignored, RetryPendingParks a no-op).
-- The control PASSES when the OLD bad outcome is observed: the
-- recovery never retries the missing park, so after the crash the
-- reward exists nowhere durable and is LOST (the R3 B/B2 loss).
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local R = require("../r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv({ raidPath = "./mutant/RaidServiceR3" })
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = P.newLoadedPair(env, 9611, 9612)
H.steal(env, pair)
store:failUpdateAsyncForKey(P.pendingKey(pair.thief.UserId), 2)
local restoreMain = R.failSetAsyncForKey(P.mainKey(pair.thief.UserId))
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("setup: delivery reports the reward pending", okDel == true and status == "reward_pending", "status=" .. tostring(status))
local entry = DS.GetData(pair.thief).PendingRewards[pair.targetId]
local txId = nil
if type(entry) == "table" and type(entry.Txns) == "table" then
	for id in pairs(entry.Txns) do
		txId = id
	end
end
check("setup: the reward is pending with one transaction id", txId ~= nil)
store:resetFailures()
restoreMain()
restoreMain = R.failSetAsyncForKey(P.mainKey(pair.thief.UserId))
-- Recovery with the sidecar restored: the old code never retries
-- the park, so the transaction stays unparked.
local paidCount, totalPaid = env.raid.RecoverPendingRewards(pair.thief)
check("old logic: recovery pays nothing while main saves fail", paidCount == 0 and totalPaid == 0)
check("OLD BUG REPRODUCED: the transaction is STILL not parked after recovery",
	R.findTxIdInList(store:peek(P.pendingKey(pair.thief.UserId)), txId) == nil)
restoreMain()
-- Crash + rejoin: the reward exists nowhere durable.
DS.LoadData(pair.thief)
local pendingAfter = DS.GetData(pair.thief).PendingRewards
check("OLD BUG REPRODUCED: after crash + rejoin the pending reward is gone (never parked)",
	type(pendingAfter) ~= "table" or pendingAfter[pair.targetId] == nil)
local paid2, total2 = env.raid.RecoverPendingRewards(pair.thief)
check("OLD BUG REPRODUCED: recovery after rejoin pays nothing — the reward is lost",
	paid2 == 0 and total2 == 0)
check("OLD BUG REPRODUCED: the thief kept no reward (100000, not 100300)",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))

H.finish()
