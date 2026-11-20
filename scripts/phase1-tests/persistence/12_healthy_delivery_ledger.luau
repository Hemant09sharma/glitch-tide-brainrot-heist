-- 12_healthy_delivery_ledger.luau — R3-3: a HEALTHY delivery parks
-- its reward in the sidecar first (R3-5 park-first) and pays
-- directly; the parked entry must NOT pay again when the next load
-- re-merges it — the Processed marker persisted with the payment is
-- recognised — and the stale sidecar key is deleted on the next save.
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

local pair = P.newLoadedPair(env, 9221, 9222)
local baseline = DS.GetData(pair.thief).Coins
H.steal(env, pair)
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("healthy delivery pays directly (status nil, +300 coins)",
	okDel == true and status == nil and DS.GetData(pair.thief).Coins == baseline + 300,
	"status=" .. tostring(status) .. " coins=" .. tostring(DS.GetData(pair.thief).Coins))
check("healthy delivery records no pending reward",
	P.pendingTotal(DS.GetData(pair.thief), pair.targetId) == 0)
local sidecar = store:peek(P.pendingKey(pair.thief.UserId))
check("healthy delivery parked its transaction in the sidecar first",
	type(sidecar) == "table" and #sidecar == 1
		and sidecar[1].InstanceId == pair.targetId and sidecar[1].Amount == 300
		and type(sidecar[1].TxId) == "string" and sidecar[1].TxId ~= "")
local txId = type(sidecar) == "table" and sidecar[1] and sidecar[1].TxId or nil
check("healthy delivery persisted the processed marker with the payment",
	type(store:peek(P.mainKey(pair.thief.UserId)).ProcessedRewardTxns) == "table"
		and txId ~= nil
		and store:peek(P.mainKey(pair.thief.UserId)).ProcessedRewardTxns[txId] ~= nil
		and store:peek(P.mainKey(pair.thief.UserId)).ProcessedRewardTxns[txId].Amount == 300)

-- Rejoin: the stale sidecar entry re-merges and must be skipped.
local data2 = DS.LoadData(pair.thief)
check("rejoin does not resurrect the paid reward as pending",
	P.pendingTotal(data2, pair.targetId) == 0)
local paid, total = env.raid.RecoverPendingRewards(pair.thief)
check("recovery after rejoin pays nothing (still +300 total, not +600)",
	paid == 0 and total == 0 and DS.GetData(pair.thief).Coins == baseline + 300,
	"paid=" .. tostring(paid) .. " total=" .. tostring(total))
local okSave = DS.SaveData(pair.thief)
check("save after rejoin succeeds", okSave == true)
check("stale sidecar key is deleted by that save",
	store:peek(P.pendingKey(pair.thief.UserId)) == nil)
local data3 = DS.LoadData(pair.thief)
check("final rejoin has no pending reward",
	P.pendingTotal(data3, pair.targetId) == 0)
local paid2, total2 = env.raid.RecoverPendingRewards(pair.thief)
check("final recovery pays nothing",
	paid2 == 0 and total2 == 0 and DS.GetData(pair.thief).Coins == baseline + 300)

H.finish()
