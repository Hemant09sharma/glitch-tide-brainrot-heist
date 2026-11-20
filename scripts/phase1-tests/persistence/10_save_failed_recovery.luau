-- 10_save_failed_recovery.luau — R3-5: a saveable profile whose
-- saves ALL fail must not lose the steal reward, and must not pay it
-- twice; plus R3-3 (D): a main-profile save failure DURING recovery
-- must neither lose nor duplicate the reward on retry.
-- NOTE on Part 1: the delivery itself is NOT durable here — every
-- save fails, so the stored profile never sees the ownership
-- transfer and the rejoin voids the delivery (the R2 rule: ownership
-- is never granted without durable proof). The REWARD is a separate
-- ledger entry: it was parked in the sidecar before the failed save,
-- so it is still recovered exactly once. Paying a reward for a
-- voided delivery is the specified R3-5 outcome (reward recovered
-- exactly once); whether that policy is desirable is a product call,
-- not a ledger bug.
-- Run: bash scripts/phase1-tests/persistence/run.sh
local P = require("./persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService()
local env = P.newRaidEnv()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- ---------------------------------------------------------------------------
-- Part 1 (R3-5): load a saveable profile; commit a steal delivery;
-- allow AddCoins() to succeed in memory; force all main-profile saves
-- to fail; player leaves and rejoins; the reward is eventually
-- persisted and paid exactly once.
-- ---------------------------------------------------------------------------
local pair = P.newLoadedPair(env, 9201, 9202)
local baseline = DS.GetData(pair.thief).Coins
check("R3-5: thief starts with the seeded coins",
	baseline == 100000, "coins=" .. tostring(baseline))
H.steal(env, pair)
store:failSetAsync(100)
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("R3-5: delivery still succeeds while every save fails",
	okDel == true, "status=" .. tostring(status))
check("R3-5: delivery reports reward_pending, not rewarded success",
	status == "reward_pending", "status=" .. tostring(status))
check("R3-5: no coins are kept in memory (payment rolled back to pending)",
	DS.GetData(pair.thief).Coins == baseline,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
check("R3-5: reward is pending in the cache (300)",
	P.pendingTotal(DS.GetData(pair.thief), pair.targetId) == 300)
check("R3-5: reward is parked in the sidecar before the failed save",
	P.sidecarTotal(store:peek(P.pendingKey(pair.thief.UserId)), pair.targetId) == 300)
check("R3-5: failed saves persist nothing (stored main is still the seeded profile)",
	store:peek(P.mainKey(pair.thief.UserId)).Coins == baseline)
-- The player leaves (leave save also fails) and rejoins after the outage.
local okLeaveSave = DS.SaveData(pair.thief)
check("R3-5: leave save fails too (outage still on)",
	okLeaveSave == false)
store:resetFailures()
local data2 = DS.LoadData(pair.thief)
check("R3-5: unpersisted delivery is voided on rejoin (thief no longer owns the Brainrot)",
	H.findOwned(data2, pair.targetId) == nil)
check("R3-5: rejoin merges the parked reward back into PendingRewards",
	P.pendingTotal(data2, pair.targetId) == 300)
local paid, total = env.raid.RecoverPendingRewards(pair.thief)
check("R3-5: recovery after rejoin pays exactly once (1 entry, 300 coins)",
	paid == 1 and total == 300, "paid=" .. tostring(paid) .. " total=" .. tostring(total))
check("R3-5: coins arrive after recovery",
	DS.GetData(pair.thief).Coins == baseline + 300)
check("R3-5: reward is persisted in the main profile after recovery",
	store:peek(P.mainKey(pair.thief.UserId)).Coins == baseline + 300)
check("R3-5: processed marker is persisted with the recovered payment",
	type(store:peek(P.mainKey(pair.thief.UserId)).ProcessedRewardTxns) == "table"
		and next(store:peek(P.mainKey(pair.thief.UserId)).ProcessedRewardTxns) ~= nil)
local paid2, total2 = env.raid.RecoverPendingRewards(pair.thief)
check("R3-5: second recovery pays nothing more",
	paid2 == 0 and total2 == 0 and DS.GetData(pair.thief).Coins == baseline + 300)

-- ---------------------------------------------------------------------------
-- Part 2 (R3-3 D): main-profile save failure DURING recovery — retry
-- neither loses nor duplicates the reward.
-- ---------------------------------------------------------------------------
local userId = 9203
local player = H.newPlayer(userId, "SaveFailPlayer")
store:seed(P.mainKey(userId), {
	Coins = 500,
	OwnedInstances = {},
	Base = { Placed = {} },
	LastLogin = os.time(),
})
store:seed(P.pendingKey(userId), { P.pendingEntryTx("r33d_inst", 300, "tx-r33-d") })
local data3 = DS.LoadData(player)
check("D: load merges the sidecar reward (300)",
	P.pendingTotal(data3, "r33d_inst") == 300)
store:failSetAsync(100)
local paid3, total3 = env.raid.RecoverPendingRewards(player)
check("D: recovery during the outage pays nothing yet (save failed, entry kept)",
	paid3 == 0 and total3 == 0, "paid=" .. tostring(paid3) .. " total=" .. tostring(total3))
check("D: coins are unchanged during the outage",
	DS.GetData(player).Coins == 500)
check("D: pending entry is kept for retry (not lost, not paid)",
	P.pendingTotal(DS.GetData(player), "r33d_inst") == 300)
check("D: no processed marker is persisted during the outage",
	(store:peek(P.mainKey(userId)).ProcessedRewardTxns or {})["tx-r33-d"] == nil)
check("D: failed sidecar deletion leaves the entry in place for retry",
	P.findInList(store:peek(P.pendingKey(userId)), "r33d_inst") ~= nil)
store:resetFailures()
local paid4, total4 = env.raid.RecoverPendingRewards(player)
check("D: retry after the outage pays exactly once (1 entry, 300 coins)",
	paid4 == 1 and total4 == 300, "paid=" .. tostring(paid4) .. " total=" .. tostring(total4))
check("D: coins arrive after the retry",
	DS.GetData(player).Coins == 800)
check("D: reward is persisted in the main profile after the retry",
	store:peek(P.mainKey(userId)).Coins == 800)
local paid5, total5 = env.raid.RecoverPendingRewards(player)
check("D: further recovery pays nothing more",
	paid5 == 0 and total5 == 0 and DS.GetData(player).Coins == 800)

H.finish()
