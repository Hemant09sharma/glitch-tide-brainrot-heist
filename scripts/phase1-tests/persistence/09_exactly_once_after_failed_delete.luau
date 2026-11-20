-- 09_exactly_once_after_failed_delete.luau — R3-3 (A/B/C): a pending
-- reward merged from the sidecar, paid, and saved must NOT pay again
-- when the sidecar deletion fails and the same sidecar is merged
-- again on rejoin. The durable ProcessedRewardTxns marker (persisted
-- in the main profile together with the coin change) is what the
-- re-merge recognises. (C) covers the retry: after a subsequent
-- healthy save the stale sidecar key is deleted.
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

local userId = 9101
local player = H.newPlayer(userId, "LedgerPlayer")
local instanceId = "r33_inst"
local txId = "tx-r33-a"

store:seed(P.mainKey(userId), {
	Coins = 500,
	OwnedInstances = {},
	Base = { Placed = {} },
	LastLogin = os.time(),
})
store:seed(P.pendingKey(userId), { P.pendingEntryTx(instanceId, 300, txId) })

local data = DS.LoadData(player)
check("load merges the sidecar reward into PendingRewards (300)",
	P.pendingTotal(data, instanceId) == 300)
check("merged entry records its transaction id",
	P.pendingTxnCount(data, instanceId) == 1
		and type(data.PendingRewards[instanceId].Txns) == "table"
		and data.PendingRewards[instanceId].Txns[txId] == 300)
local baseline = data.Coins
check("baseline coins are the seeded 500 (no daily bonus)",
	baseline == 500, "coins=" .. tostring(baseline))

-- (A) Pay it, then fail the sidecar deletion on the save that follows.
store:failRemoveAsync(1)
local paid, total = env.raid.RecoverPendingRewards(player)
check("recovery pays the merged reward exactly once (1 entry, 300 coins)",
	paid == 1 and total == 300, "paid=" .. tostring(paid) .. " total=" .. tostring(total))
check("coins arrive after recovery",
	DS.GetData(player).Coins == baseline + 300)
check("pending entry is gone from the cache after payment",
	P.pendingTotal(DS.GetData(player), instanceId) == 0)
local stored = store:peek(P.mainKey(userId))
check("main profile persists the payment (800 coins)",
	type(stored) == "table" and stored.Coins == baseline + 300)
check("main profile persists the processed marker with the payment",
	type(stored) == "table" and type(stored.ProcessedRewardTxns) == "table"
		and stored.ProcessedRewardTxns[txId] ~= nil
		and stored.ProcessedRewardTxns[txId].Amount == 300)
check("failed sidecar deletion leaves the entry in place for retry",
	P.findInList(store:peek(P.pendingKey(userId)), instanceId) ~= nil)

-- Rejoin: the same sidecar merges again — the processed transaction
-- must be recognised and must NOT pay again.
local data2 = DS.LoadData(player)
check("rejoin merges nothing new for the processed transaction",
	P.pendingTotal(data2, instanceId) == 0)
local paid2, total2 = env.raid.RecoverPendingRewards(player)
check("recovery after rejoin pays nothing more (still 300 total, not 600)",
	paid2 == 0 and total2 == 0 and DS.GetData(player).Coins == baseline + 300,
	"paid=" .. tostring(paid2) .. " total=" .. tostring(total2)
		.. " coins=" .. tostring(DS.GetData(player).Coins))
check("stored main profile is unchanged by the second recovery",
	store:peek(P.mainKey(userId)).Coins == baseline + 300)

-- (B) Repeat recovery multiple times: still nothing.
for _ = 1, 3 do
	local p, t = env.raid.RecoverPendingRewards(player)
	check("repeated recovery pays nothing more",
		p == 0 and t == 0 and DS.GetData(player).Coins == baseline + 300)
end

-- (C) Retry the deletion after a subsequent healthy save: it succeeds
-- now and the stale sidecar key is gone; a further rejoin stays clean.
store:resetFailures()
local okSave = DS.SaveData(player)
check("healthy save after the outage succeeds",
	okSave == true)
check("stale sidecar key is deleted by the retry save",
	store:peek(P.pendingKey(userId)) == nil)
local data3 = DS.LoadData(player)
check("final rejoin has no pending reward",
	P.pendingTotal(data3, instanceId) == 0)
local paid3, total3 = env.raid.RecoverPendingRewards(player)
check("final recovery pays nothing",
	paid3 == 0 and total3 == 0 and DS.GetData(player).Coins == baseline + 300)

H.finish()
