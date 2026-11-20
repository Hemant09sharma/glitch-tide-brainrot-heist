-- 04_r4_4_voided_delivery_farming.luau — R4-4 (P2, Test D):
-- POLICY (R4-4, reversing R3): reward eligibility follows the
-- delivery transaction's durable fate. A delivery that is voided
-- during recovery (the Brainrot goes back to the victim) must not
-- leave a payable reward; a durably committed delivery preserves
-- exactly-once reward recovery.
--
-- (A) Successful delivery + successful save: the reward is paid
-- exactly once, and a rejoin does not void the delivery or pay
-- again. (B) Delivery commit + failed profile save + recovery
-- voids the delivery (rule (d): the victim is online, the Brainrot
-- goes back): the pending reward must be cancelled, not payable.
-- (C) Repeated recovery calls must not grant the cancelled reward
-- — including after a reload re-merges the parked sidecar entries.
-- (D) Three steal/deliver cycles during an injected outage must
-- not farm coins: each cycle ends with the victim holding the
-- Brainrot and the thief at exactly their starting balance.
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

-- --- (A) Durably committed delivery: paid exactly once -------------
local pairA = P.newLoadedPair(env, 9431, 9432)
H.steal(env, pairA)
local okDelA, statusA = env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
check("(A) delivery succeeds and the reward pays", okDelA == true and statusA == nil, "status=" .. tostring(statusA))
check("(A) balance is exactly original + one reward",
	(tonumber(DS.GetData(pairA.thief).Coins) or 0) == 100300)
local txIdA = nil
for id in pairs(DS.GetData(pairA.thief).ProcessedRewardTxns or {}) do
	txIdA = id
end
check("(A) the reward transaction is marked processed", txIdA ~= nil)
DS.LoadData(pairA.thief)
local rA, remA, paidA, totalA = env.raid.RecoverOnRejoin(pairA.thief)
check("(A) rejoin voids nothing and pays nothing more",
	rA == 0 and remA == 0 and paidA == 0 and totalA == 0)
check("(A) balance unchanged after rejoin",
	(tonumber(DS.GetData(pairA.thief).Coins) or 0) == 100300)
check("(A) the delivered Brainrot is kept (rule (a): placed copy proves delivery)",
	H.findOwned(DS.GetData(pairA.thief), pairA.targetId) ~= nil
		and H.findOwned(DS.GetData(pairA.thief), pairA.targetId).InTransit ~= true)

-- --- (B) Delivery commit + failed save + recovery voids it --------
local pair = P.newLoadedPair(env, 9433, 9434)
H.steal(env, pair)
assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
-- The thief's key is saved mid-carry: the InTransit record is
-- durable, so a crash-reload can still see the unresolved theft.
assert(DS.SaveData(pair.thief) == true, "setup: thief mid-carry save must land")
local restoreMain = R.failSetAsyncForKey(P.mainKey(pair.thief.UserId))
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("(B) delivery reports the reward pending (commit save failed)",
	okDel == true and status == "reward_pending", "status=" .. tostring(status))
local entryB = DS.GetData(pair.thief).PendingRewards[pair.targetId]
local txIdB = nil
if type(entryB) == "table" and type(entryB.Txns) == "table" then
	for id in pairs(entryB.Txns) do
		txIdB = id
	end
end
check("(B) the reward is pending with one transaction id", txIdB ~= nil)
check("(B) no coins paid yet", (tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000)
restoreMain()
-- Crash + rejoin: reload from the persisted store (mid-carry key +
-- parked pending sidecar). The delivery never persisted, so the
-- recovery must void it back to the victim — and void the reward.
DS.LoadData(pair.thief)
local resolved, remaining, paid, total = env.raid.RecoverOnRejoin(pair.thief)
check("(B) rejoin resolves the stale transit (rule (d): victim online, Brainrot returns)",
	resolved == 1 and remaining == 0, "resolved=" .. tostring(resolved))
check("(B) rejoin pays nothing for the voided delivery", paid == 0 and total == 0)
check("(B) exactly one owner remains: the victim",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
		and H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
		and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
check("(B) the thief keeps no coins from the voided delivery",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000)
check("(B) the pending entry is gone (voided, not payable)",
	DS.GetData(pair.thief).PendingRewards[pair.targetId] == nil)
check("(B) the transaction is recorded voided",
	type(DS.GetData(pair.thief).VoidedRewardTxns) == "table"
		and DS.GetData(pair.thief).VoidedRewardTxns[txIdB] ~= nil)
local voidParked = false
for _, e in ipairs(store:peek(P.pendingKey(pair.thief.UserId)) or {}) do
	if type(e) == "table" and e.Voided == true and e.VoidTxId == txIdB then
		voidParked = true
	end
end
check("(B) the void is parked durably in the pending sidecar", voidParked == true)

-- --- (C) Repeated recovery never grants the cancelled reward ------
for i = 1, 3 do
	local p, t = env.raid.RecoverPendingRewards(pair.thief)
	check("(C) repeated recovery #" .. tostring(i) .. " pays nothing", p == 0 and t == 0)
end
check("(C) balance still exactly the starting balance after repeated recovery",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000)
DS.LoadData(pair.thief)
local pC, tC = env.raid.RecoverPendingRewards(pair.thief)
check("(C) recovery after a reload (sidecar re-merge) pays nothing", pC == 0 and tC == 0)
check("(C) the voided transaction is still recorded voided after reload",
	type(DS.GetData(pair.thief).VoidedRewardTxns) == "table"
		and DS.GetData(pair.thief).VoidedRewardTxns[txIdB] ~= nil)
check("(C) balance still exactly the starting balance after reload",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000)

-- --- (D) Three outage cycles must not farm coins ------------------
local victim = pair.victim
local farmed = 0
for cycle = 1, 3 do
	local thiefN = R.newLoadedPlayer(env, 9440 + cycle, 100000)
	local okS, errS = env.raid.StealBrainrot(thiefN, victim.UserId, pair.targetId)
	assert(okS == true, "cycle " .. tostring(cycle) .. ": steal must succeed (err=" .. tostring(errS) .. ")")
	assert(DS.SaveData(victim) == true, "cycle " .. tostring(cycle) .. ": victim steal-time save must land")
	assert(DS.SaveData(thiefN) == true, "cycle " .. tostring(cycle) .. ": thief mid-carry save must land")
	local restoreN = R.failSetAsyncForKey(P.mainKey(thiefN.UserId))
	local okD, statusD = env.raid.ConfirmDelivery(thiefN, pair.targetId)
	assert(okD == true and statusD == "reward_pending",
		"cycle " .. tostring(cycle) .. ": delivery must report reward_pending (status=" .. tostring(statusD) .. ")")
	restoreN()
	DS.LoadData(thiefN)
	local resN, remN, paidN, totalN = env.raid.RecoverOnRejoin(thiefN)
	check("(D) cycle " .. tostring(cycle) .. ": rejoin voids the delivery and pays nothing",
		resN == 1 and remN == 0 and paidN == 0 and totalN == 0)
	check("(D) cycle " .. tostring(cycle) .. ": thief kept no coins",
		(tonumber(DS.GetData(thiefN).Coins) or 0) == 100000,
		"coins=" .. tostring(DS.GetData(thiefN).Coins))
	check("(D) cycle " .. tostring(cycle) .. ": the victim holds the Brainrot (exactly one owner)",
		H.countOwned(env, { thiefN, victim }, pair.targetId) == 1
			and H.findOwned(DS.GetData(victim), pair.targetId) ~= nil)
	farmed += (tonumber(DS.GetData(thiefN).Coins) or 0) - 100000
end
check("(D) three cycles farmed zero coins in total", farmed == 0, "farmed=" .. tostring(farmed))

H.finish()
