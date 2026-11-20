-- 02_r4_2_park_retry.luau — R4-2 (P2, Test B / B2):
-- The R3 recordPendingReward ignored the sidecar append's result:
-- when the initial UpdateAsync failed, the reward lived only in
-- memory and RecoverPendingRewards never retried the missing park.
-- The R4-2 fix records per-TxId park state (ParkedTxns) and
-- RetryPendingParks re-parks the same TxId with the same delta;
-- RecoverPendingRewards retries the park BEFORE attempting payment
-- (and before the saveable check, so an unsaveable session's
-- sidecar — its only durable leg — still gets the park).
--
-- Sequence: (1) pending-sidecar UpdateAsync fails; (2) main-profile
-- SetAsync fails; (3) confirm the reward stays pending, unparked;
-- (4) restore sidecar UpdateAsync while keeping main saves failing;
-- (5) RecoverPendingRewards retries the park (same TxId), payment
-- still cannot land; (6) crash + rejoin; (7) restore storage;
-- (8) the reward is recovered exactly once. Plus the unsaveable /
-- load-failed session variant: the park is still retried, no coins
-- are paid, the entry stays pending.
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = P.newLoadedPair(env, 9411, 9412)
H.steal(env, pair)

-- (1) The pending-sidecar UpdateAsync fails (appendSidecar retries
-- twice, so both attempts must fail), and (2) the thief's main
-- profile SetAsync fails.
store:failUpdateAsyncForKey(P.pendingKey(pair.thief.UserId), 2)
local restoreMain = R.failSetAsyncForKey(P.mainKey(pair.thief.UserId))

local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("delivery reports the reward pending, not paid", okDel == true and status == "reward_pending", "ok=" .. tostring(okDel) .. " status=" .. tostring(status))
local data = DS.GetData(pair.thief)
local entry = data.PendingRewards[pair.targetId]
check("reward remains pending in cache", type(entry) == "table" and (tonumber(entry.Amount) or 0) == 300)
local txId = nil
if type(entry) == "table" and type(entry.Txns) == "table" then
	for id in pairs(entry.Txns) do
		txId = id
	end
end
check("pending entry carries one transaction id", type(txId) == "string" and txId ~= "")
check("failed park is recorded explicitly (ParkedTxns false, not silently dropped)",
	type(entry) == "table" and type(entry.ParkedTxns) == "table" and entry.ParkedTxns[txId] == false)
check("no parked copy of the transaction exists in the sidecar",
	R.findTxIdInList(store:peek(P.pendingKey(pair.thief.UserId)), txId) == nil)
check("no coins were paid (rollback exact)", (tonumber(data.Coins) or 0) == 100000)

-- (4) Restore the sidecar while main-profile saves keep failing.
store:resetFailures()
restoreMain() -- remove the first per-key patch before installing the second
restoreMain = R.failSetAsyncForKey(P.mainKey(pair.thief.UserId))

-- (5) Recovery retries the park FIRST, with the same TxId, even
-- though payment still cannot land.
local paidCount, totalPaid = env.raid.RecoverPendingRewards(pair.thief)
check("recovery pays nothing while main saves fail", paidCount == 0 and totalPaid == 0)
check("recovery retried the park: the same TxId is now parked",
	R.findTxIdInList(store:peek(P.pendingKey(pair.thief.UserId)), txId) ~= nil)
local entry2 = DS.GetData(pair.thief).PendingRewards[pair.targetId]
check("park state is now recorded (ParkedTxns true)",
	type(entry2) == "table" and entry2.ParkedTxns[txId] == true)
check("reward still pending after the failed payment attempt",
	type(entry2) == "table" and (tonumber(entry2.Amount) or 0) == 300)
check("still no coins paid", (tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000)
-- A second retry is a no-op (appendSidecar dedupes by TxId).
local parkedNow, stillUnparked = env.raid.RetryPendingParks(pair.thief)
check("re-parking an already-parked TxId is a no-op", parkedNow == 0 and stillUnparked == 0)
local parkedList = store:peek(P.pendingKey(pair.thief.UserId))
local parkedCopies = 0
if type(parkedList) == "table" then
	for _, e in ipairs(parkedList) do
		if type(e) == "table" and e.TxId == txId then
			parkedCopies += 1
		end
	end
end
check("exactly one parked copy of the transaction", parkedCopies == 1)

-- (6) Crash + rejoin: discard the cache, reload from the persisted
-- store (the thief's stored key is pre-steal; the pending sidecar
-- is the only record of the reward).
DS.LoadData(pair.thief)
local dataAfter = DS.GetData(pair.thief)
local entryAfter = dataAfter.PendingRewards[pair.targetId]
check("after crash + rejoin the pending reward is restored from the sidecar",
	type(entryAfter) == "table" and (tonumber(entryAfter.Amount) or 0) == 300)
local txIdAfter = nil
if type(entryAfter) == "table" and type(entryAfter.Txns) == "table" then
	for id in pairs(entryAfter.Txns) do
		txIdAfter = id
	end
end
check("the restored entry keeps the SAME transaction id (no new TxId minted)", txIdAfter == txId)
check("no coins paid yet after rejoin", (tonumber(dataAfter.Coins) or 0) == 100000)

-- (7) Restore normal storage, (8) recover — exactly once.
restoreMain()
local paid2, total2 = env.raid.RecoverPendingRewards(pair.thief)
check("recovery pays the reward once storage returns", paid2 == 1 and total2 == 300, "paid=" .. tostring(total2))
check("balance is exactly the original plus one reward",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100300,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
check("transaction is marked processed", DS.GetData(pair.thief).ProcessedRewardTxns[txId] ~= nil)
check("pending entry is gone after payment", DS.GetData(pair.thief).PendingRewards[pair.targetId] == nil)
local paid3, total3 = env.raid.RecoverPendingRewards(pair.thief)
check("repeated recovery pays nothing more", paid3 == 0 and total3 == 0)
check("balance unchanged after repeated recovery",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100300)
-- A reload must not resurrect the payment either (the sidecar copy
-- is dropped on merge because the TxId is already processed).
DS.LoadData(pair.thief)
local paid4, total4 = env.raid.RecoverPendingRewards(pair.thief)
check("recovery after a reload still pays nothing", paid4 == 0 and total4 == 0)
check("balance still exactly one reward after reload",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100300)

-- Unsaveable / load-failed session variant: the park is still
-- retried (the sidecar is the session's only durable leg), but no
-- coins are paid and the entry stays pending.
local thief2 = H.newPlayer(9413, "Player9413", 30, Vector3.new(0, 0, 0))
store:failGetAsyncForKey(P.mainKey(9413), 3) -- LOAD_RETRIES attempts
DS.LoadData(thief2)
check("load-failed session is flagged unsaveable", DS.IsSaveable(thief2) == false)
local data2 = DS.GetData(thief2)
if type(data2.PendingRewards) ~= "table" then
	data2.PendingRewards = {}
end
data2.PendingRewards[pair.targetId] = {
	InstanceId = pair.targetId,
	CharacterId = "wobble_waffleton",
	Amount = 300,
	Reason = "steal reward",
	CreatedAt = os.time(),
	Txns = { ["sr-loadfailed-test"] = 300 },
	ParkedTxns = {},
}
local paid5, total5 = env.raid.RecoverPendingRewards(thief2)
check("unsaveable recovery pays nothing", paid5 == 0 and total5 == 0)
check("unsaveable recovery still retried the park",
	R.findTxIdInList(store:peek(P.pendingKey(9413)), "sr-loadfailed-test") ~= nil)
check("unsaveable session paid no coins (still the 100-coin starting default)",
	(tonumber(DS.GetData(thief2).Coins) or 0) == 100,
	"coins=" .. tostring(DS.GetData(thief2).Coins))
check("unsaveable entry stays pending",
	DS.GetData(thief2).PendingRewards[pair.targetId] ~= nil)

restoreMain()

H.finish()
