-- 03_r5_3_durable_reward_voiding.luau — R5-3 (P1):
-- A reward void must NOT depend on the reward being present in the
-- in-memory PendingRewards table. Qwen's reproduction: a reward
-- exists in the pending sidecar; its read fails during rejoin; the
-- Brainrot is returned to the victim; the void finds no in-memory
-- PendingRewards entry and returns; the sidecar later becomes
-- readable; the reward gets paid even though the delivery was voided.
--
-- The fix (see docs/R5_REPAIRS_REPORT.md, Worker C): the void parks
-- a durable instance-level tombstone ("void-inst-<InstanceId>") in
-- the thief's pending sidecar INDEPENDENTLY of any cache entry or
-- sidecar read, plus per-TxId void entries when TxIds are known
-- (cache or a best-effort sidecar read). mergeSidecars processes the
-- tombstone first and refuses every reward entry for that instance,
-- now or on any later merge. A void whose tombstone AND fallback
-- main-profile save both fail is NOT treated as done: it stays
-- pending for retry (RaidService.RetryPendingVoids) and the
-- recovery reports the instance as remaining, not resolved.
--
-- Sections:
--   (A) Qwen's exact reproduction (pending sidecar read fails at
--       rejoin; void runs with no cache entry; sidecar readable
--       later; reward must NEVER pay).
--   (B) Void UpdateAsync fails (tombstone cannot park) AND the
--       fallback main-profile save fails: the recovery must report
--       remaining, keep the void pending, and pay nothing once the
--       retry lands the tombstone.
--   (C) Main-profile save fails after the void: the tombstone alone
--       must still refuse the reward on the next merge.
--   (D) Repeated recovery / reload / void: idempotent, still 0 paid,
--       exactly one tombstone and one voided TxId.
--   (E) A successful save persists the void ledger and may then
--       delete the sidecar; the ledger alone still refuses payment.
-- Run: bash scripts/phase1-tests/r5-transactions/run.sh
local R5 = require("./r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv()
local DS = env.dataService
local raid = env.raid

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- failSetAsyncForKey(key): fail SetAsync only for one key (same
-- pattern as r4_env.failSetAsyncForKey). Returns a restore function.
local function failSetAsyncForKey(key)
	local orig = store.SetAsync
	store.SetAsync = function(self, k, value)
		if k == key then
			error("injected per-key SetAsync failure for " .. k)
		end
		return orig(self, k, value)
	end
	return function()
		store.SetAsync = orig
	end
end

-- setupPendingPair(thiefId, victimId): steal + deliver with the
-- thief's commit save failing, so the reward is pending (cache +
-- sidecar) and the delivery never persisted. Returns pair, txId.
local function setupPendingPair(thiefId, victimId)
	local pair = P.newLoadedPair(env, thiefId, victimId)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
	assert(DS.SaveData(pair.thief) == true, "setup: thief mid-carry save must land")
	local restoreMain = failSetAsyncForKey(P.mainKey(pair.thief.UserId))
	local okDel, status = raid.ConfirmDelivery(pair.thief, pair.targetId)
	restoreMain()
	assert(okDel == true and status == "reward_pending",
		"setup: delivery must report reward_pending (status=" .. tostring(status) .. ")")
	local entry = DS.GetData(pair.thief).PendingRewards[pair.targetId]
	assert(type(entry) == "table" and type(entry.Txns) == "table",
		"setup: reward must be pending in cache")
	local txId = nil
	for id in pairs(entry.Txns) do
		txId = id
	end
	assert(txId ~= nil, "setup: pending reward must have a TxId")
	assert((tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000,
		"setup: no coins paid yet")
	return pair, txId
end

local function pendingFor(player, instanceId)
	local data = DS.GetData(player)
	if type(data) ~= "table" or type(data.PendingRewards) ~= "table" then
		return nil
	end
	return data.PendingRewards[instanceId]
end

local function countSidecarEntries(userId, pred)
	local list = store:peek(P.pendingKey(userId)) or {}
	local c = 0
	for _, e in ipairs(list) do
		if type(e) == "table" and pred(e) then
			c += 1
		end
	end
	return c
end

local function hasVoidEntry(userId, txId)
	return countSidecarEntries(userId, function(e)
		return e.Voided == true and e.VoidTxId == txId
	end) > 0
end

local function hasInstanceTombstone(userId, instanceId)
	return countSidecarEntries(userId, function(e)
		return e.Voided == true and e.VoidInstance == true and e.InstanceId == instanceId
	end) > 0
end

-- --- (A) Qwen's exact reproduction --------------------------------
local pairA, txIdA = setupPendingPair(9531, 9532)
-- The pending sidecar read fails during the rejoin load (both
-- readSidecar attempts): the reward exists ONLY in the sidecar.
store:failGetAsyncForKey(P.pendingKey(pairA.thief.UserId), 2)
DS.LoadData(pairA.thief)
check("(A) rejoin load with a failed pending read merges NO pending reward into cache",
	pendingFor(pairA.thief, pairA.targetId) == nil)
store:resetFailures()
local resA, remA, paidA, totalA = raid.RecoverOnRejoin(pairA.thief)
check("(A) rejoin resolves the stale transit (rule (d): victim online, Brainrot returns)",
	resA == 1 and remA == 0, "resolved=" .. tostring(resA) .. " remaining=" .. tostring(remA))
check("(A) rejoin pays nothing for the voided delivery", paidA == 0 and totalA == 0)
check("(A) exactly one owner remains: the victim",
	H.countOwned(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1
		and H.findOwned(DS.GetData(pairA.victim), pairA.targetId) ~= nil
		and H.findOwned(DS.GetData(pairA.thief), pairA.targetId) == nil)
check("(A) the void parked a durable instance tombstone even though the cache held no entry",
	hasInstanceTombstone(pairA.thief.UserId, pairA.targetId) == true)
-- The sidecar becomes readable again: a reload merges it. The
-- tombstone must refuse the reward entry now (and forever).
DS.LoadData(pairA.thief)
check("(A) reload after the sidecar becomes readable still merges NO pending reward",
	pendingFor(pairA.thief, pairA.targetId) == nil)
check("(A) the voided transaction is recorded voided after the merge",
	type(DS.GetData(pairA.thief).VoidedRewardTxns) == "table"
		and DS.GetData(pairA.thief).VoidedRewardTxns[txIdA] ~= nil)
local pA, tA = raid.RecoverPendingRewards(pairA.thief)
check("(A) recovery after the sidecar becomes readable pays NOTHING (the voided reward never pays)",
	pA == 0 and tA == 0, "paid=" .. tostring(pA) .. " total=" .. tostring(tA))
check("(A) the thief keeps no coins from the voided delivery",
	(tonumber(DS.GetData(pairA.thief).Coins) or 0) == 100000,
	"coins=" .. tostring(DS.GetData(pairA.thief).Coins))

-- --- (B) Void UpdateAsync fails AND the fallback save fails -------
local pairB, txIdB = setupPendingPair(9533, 9534)
-- Crash + rejoin first: reload the persisted mid-carry key (with the
-- InTransit record) so the recovery has a stale record to resolve.
DS.LoadData(pairB.thief)
check("(B) setup: reload merges the pending reward into cache",
	pendingFor(pairB.thief, pairB.targetId) ~= nil)
store:failUpdateAsyncForKey(P.pendingKey(pairB.thief.UserId), 10)
local restoreB = failSetAsyncForKey(P.mainKey(pairB.thief.UserId))
local resB, remB, paidB, totalB = raid.RecoverOnRejoin(pairB.thief)
check("(B) recovery with an unpersistable void reports the instance as REMAINING, not resolved",
	resB == 0 and remB == 1, "resolved=" .. tostring(resB) .. " remaining=" .. tostring(remB))
check("(B) recovery pays nothing while the void is unpersisted", paidB == 0 and totalB == 0)
check("(B) no void entry reached the sidecar (every void append failed)",
	countSidecarEntries(pairB.thief.UserId, function(e)
		return e.Voided == true
	end) == 0)
check("(B) the void is still recorded in memory (in-session protection)",
	type(DS.GetData(pairB.thief).VoidedRewardTxns) == "table"
		and DS.GetData(pairB.thief).VoidedRewardTxns[txIdB] ~= nil)
check("(B) the pending entry is gone from the cache (voided, not payable in-session)",
	pendingFor(pairB.thief, pairB.targetId) == nil)
check("(B) the Brainrot still went back to the victim (the return itself succeeded)",
	H.countOwned(env, { pairB.thief, pairB.victim }, pairB.targetId) == 1
		and H.findOwned(DS.GetData(pairB.victim), pairB.targetId) ~= nil)
-- The outage clears for the sidecar, but the thief's main-key
-- save stays failing for the retry itself, so the retry's
-- durability comes ONLY from the tombstone park (the save leg is
-- down): the tombstone must then be observable in the sidecar, and
-- the next reload must refuse the reward entry via the tombstone
-- leg — not via a saved ledger.
store:resetFailures()
check("(B) RetryPendingVoids exists", type(raid.RetryPendingVoids) == "function")
local parkedB, stillB = -1, -1
if type(raid.RetryPendingVoids) == "function" then
	parkedB, stillB = raid.RetryPendingVoids(pairB.thief)
end
check("(B) retrying the pending void parks it (nothing still pending)",
	parkedB >= 1 and stillB == 0, "parked=" .. tostring(parkedB) .. " still=" .. tostring(stillB))
check("(B) the retried void parked exactly one instance tombstone",
	countSidecarEntries(pairB.thief.UserId, function(e)
		return e.Voided == true and e.VoidInstance == true and e.InstanceId == pairB.targetId
	end) == 1)
check("(B) the retried void parked the per-TxId void entry too",
	hasVoidEntry(pairB.thief.UserId, txIdB) == true)
DS.LoadData(pairB.thief)
local resB2, remB2, paidB2, totalB2 = raid.RecoverOnRejoin(pairB.thief)
check("(B) rejoin after the retried void resolves the stale copy (rule (b)) and pays nothing",
	resB2 == 1 and remB2 == 0 and paidB2 == 0 and totalB2 == 0,
	"resolved=" .. tostring(resB2) .. " remaining=" .. tostring(remB2)
		.. " paid=" .. tostring(paidB2) .. " total=" .. tostring(totalB2))
check("(B) the thief keeps no coins from the voided delivery",
	(tonumber(DS.GetData(pairB.thief).Coins) or 0) == 100000,
	"coins=" .. tostring(DS.GetData(pairB.thief).Coins))
restoreB()

-- --- (C) Main-profile save fails after the void --------------------
local pairC, txIdC = setupPendingPair(9535, 9536)
-- Crash + rejoin first (same reload as (B)).
DS.LoadData(pairC.thief)
check("(C) setup: reload merges the pending reward into cache",
	pendingFor(pairC.thief, pairC.targetId) ~= nil)
local restoreC = failSetAsyncForKey(P.mainKey(pairC.thief.UserId))
local resC, remC, paidC, totalC = raid.RecoverOnRejoin(pairC.thief)
check("(C) rejoin resolves the stale transit even though the thief's saves fail",
	resC == 1 and remC == 0, "resolved=" .. tostring(resC) .. " remaining=" .. tostring(remC))
check("(C) rejoin pays nothing for the voided delivery", paidC == 0 and totalC == 0)
check("(C) the void tombstone is durable in the sidecar (the only leg that landed)",
	hasInstanceTombstone(pairC.thief.UserId, pairC.targetId) == true)
check("(C) an explicit post-void main-profile save fails (the save leg is down)",
	DS.SaveData(pairC.thief) == false)
restoreC()
DS.LoadData(pairC.thief)
check("(C) reload after the failed save still merges NO pending reward (tombstone leg)",
	pendingFor(pairC.thief, pairC.targetId) == nil)
local resC2, remC2, paidC2, totalC2 = raid.RecoverOnRejoin(pairC.thief)
check("(C) rejoin after the failed save resolves the stale copy and pays nothing",
	resC2 == 1 and remC2 == 0 and paidC2 == 0 and totalC2 == 0)
check("(C) the thief keeps no coins from the voided delivery",
	(tonumber(DS.GetData(pairC.thief).Coins) or 0) == 100000,
	"coins=" .. tostring(DS.GetData(pairC.thief).Coins))

-- --- (D) Repeated recovery / reload / void: idempotent -------------
for i = 1, 3 do
	DS.LoadData(pairA.thief)
	local rD, remD, pD, tD = raid.RecoverOnRejoin(pairA.thief)
	check("(D) repeated recovery #" .. tostring(i) .. " pays nothing",
		pD == 0 and tD == 0 and remD == 0,
		"resolved=" .. tostring(rD) .. " remaining=" .. tostring(remD)
			.. " paid=" .. tostring(pD) .. " total=" .. tostring(tD))
end
check("(D) the thief still keeps no coins after repeated recovery",
	(tonumber(DS.GetData(pairA.thief).Coins) or 0) == 100000,
	"coins=" .. tostring(DS.GetData(pairA.thief).Coins))
check("(D) exactly one instance tombstone exists (re-voids dedupe, never duplicate)",
	countSidecarEntries(pairA.thief.UserId, function(e)
		return e.Voided == true and e.VoidInstance == true and e.InstanceId == pairA.targetId
	end) == 1)
local voidedCountA = 0
for _ in pairs(DS.GetData(pairA.thief).VoidedRewardTxns or {}) do
	voidedCountA += 1
end
check("(D) exactly one transaction is recorded voided (no duplicate ledger entries)",
	voidedCountA == 1, "voidedCount=" .. tostring(voidedCountA))

-- --- (E) A successful save persists the void ledger ----------------
assert(DS.SaveData(pairA.thief) == true, "setup (E): thief save after the void must land")
check("(E) the merged sidecar is deleted after the successful save of the voided state",
	store:peek(P.pendingKey(pairA.thief.UserId)) == nil)
local storedA = store:peek(P.mainKey(pairA.thief.UserId))
check("(E) the stored profile itself records the voided transaction",
	type(storedA) == "table" and type(storedA.VoidedRewardTxns) == "table"
		and storedA.VoidedRewardTxns[txIdA] ~= nil)
DS.LoadData(pairA.thief)
local pE, tE = raid.RecoverPendingRewards(pairA.thief)
check("(E) recovery after the sidecar is gone still pays nothing (ledger leg)",
	pE == 0 and tE == 0)
check("(E) the thief still keeps no coins",
	(tonumber(DS.GetData(pairA.thief).Coins) or 0) == 100000,
	"coins=" .. tostring(DS.GetData(pairA.thief).Coins))

H.finish()
