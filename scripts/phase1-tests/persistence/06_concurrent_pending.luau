-- 06_concurrent_pending.luau — R3-2: two concurrent server processes
-- appending different pending rewards to the same user's sidecar must
-- BOTH survive, regardless of interleaving (same real-interleave
-- mechanism as 05_concurrent_escrow.luau). Also covers the same-
-- InstanceId race: two servers recording a reward for the SAME
-- instance under DIFFERENT TxIds must leave two entries (one per
-- transaction), amounts un-summed in the sidecar — dedupe by TxId,
-- not by InstanceId, with no lost update (R3-4: the sidecar never
-- accumulates; amounts are summed only by the reader).
-- Run: bash scripts/phase1-tests/persistence/run.sh
local P = require("./persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function mockPlayer(userId)
	return { UserId = userId, Name = "Player" .. tostring(userId) }
end

-- Different InstanceIds, interleaved: both survive.
local userA = 7061
store:resetCounts()
store:armBeforeCommit(function()
	local okB = DS.RecordPendingRewardSidecar(mockPlayer(userA), P.pendingEntry("race_pb1", 250))
	assert(okB == true, "server B pending append must succeed inside the race window")
end)
local okA = DS.RecordPendingRewardSidecar(mockPlayer(userA), P.pendingEntry("race_pa1", 100))
local listA = store:peek(P.pendingKey(userA))
check("different ids: server A append reports success",
	okA == true)
check("different ids: both pending rewards survive the interleave",
	P.findInList(listA, "race_pa1") ~= nil
		and P.findInList(listA, "race_pa1").Amount == 100
		and P.findInList(listA, "race_pb1") ~= nil
		and P.findInList(listA, "race_pb1").Amount == 250
		and #listA == 2,
	"list size=" .. (type(listA) == "table" and #listA or tostring(listA)))
check("different ids: the transform genuinely retried (not sequential)",
	store.updateRetries >= 1, "updateRetries=" .. store.updateRetries)

-- Same InstanceId, interleaved, DISTINCT TxIds: two entries, nothing lost.
local userB = 7062
store:resetCounts()
store:armBeforeCommit(function()
	local okB = DS.RecordPendingRewardSidecar(mockPlayer(userB),
		P.pendingEntry("race_same", 250, { TxId = "tx-race-same-b" }))
	assert(okB == true, "server B pending append must succeed inside the race window")
end)
local okB2 = DS.RecordPendingRewardSidecar(mockPlayer(userB),
	P.pendingEntry("race_same", 100, { TxId = "tx-race-same-a" }))
local listB = store:peek(P.pendingKey(userB))
check("same id: server A append reports success",
	okB2 == true)
check("same id: both transactions survive as separate entries (dedupe by TxId, not InstanceId)",
	P.countInList(listB, "race_same") == 2 and #listB == 2,
	"list size=" .. (type(listB) == "table" and #listB or tostring(listB)))
local totalB = 0
if type(listB) == "table" then
	for _, entry in ipairs(listB) do
		totalB += (tonumber(entry.Amount) or 0)
	end
end
check("same id: neither reward is lost (100 + 250 = 350 across the two entries)",
	totalB == 350, "total=" .. tostring(totalB))
check("same id: each entry keeps its own delta (no in-sidecar accumulation)",
	type(listB) == "table" and #listB == 2
		and ((listB[1].Amount == 100 and listB[2].Amount == 250)
			or (listB[1].Amount == 250 and listB[2].Amount == 100)))
check("same id: the transform genuinely retried (not sequential)",
	store.updateRetries >= 1, "updateRetries=" .. store.updateRetries)

check("concurrent pending appends use no GetAsync / SetAsync at all",
	store.calls.GetAsync == 0 and store.calls.SetAsync == 0,
	"GetAsync=" .. store.calls.GetAsync .. " SetAsync=" .. store.calls.SetAsync
		.. " UpdateAsync=" .. store.calls.UpdateAsync)

H.finish()
