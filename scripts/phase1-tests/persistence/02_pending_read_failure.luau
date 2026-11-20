-- 02_pending_read_failure.luau — R3-1 (B): a failed sidecar read must
-- never wipe existing pending-reward data. Same shape as
-- 01_escrow_read_failure.luau, for the pending-reward sidecar: phase 1
-- injects the GetAsync outage the old read-then-write append depended
-- on; phase 2 injects UpdateAsync failures, the failure mode that can
-- occur in the new atomic path.
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

-- Phase 1: GetAsync outage during a pending-reward append.
local userA = 7011
store:seed(P.pendingKey(userA), { P.pendingEntry("pend_old", 300) })
store:failGetAsync(2)
local okA = DS.RecordPendingRewardSidecar(mockPlayer(userA), P.pendingEntry("pend_new", 250))
local listA = store:peek(P.pendingKey(userA))
check("pending append under a GetAsync outage does not wipe the old reward",
	P.findInList(listA, "pend_old") ~= nil
		and P.findInList(listA, "pend_old").Amount == 300,
	"list=" .. (type(listA) == "table" and #listA or tostring(listA)))
check("new pending entry still lands with its own amount",
	okA == true and P.findInList(listA, "pend_new") ~= nil
		and P.findInList(listA, "pend_new").Amount == 250)
check("exactly two pending entries",
	type(listA) == "table" and #listA == 2)
store:resetFailures()

-- Phase 2: the append itself fails (UpdateAsync errors twice).
local userB = 7012
store:seed(P.pendingKey(userB), { P.pendingEntry("pend_old2", 300) })
local entry = P.pendingEntry("pend_new2", 100)
store:failUpdateAsync(2)
local okB = DS.RecordPendingRewardSidecar(mockPlayer(userB), entry)
local listB = store:peek(P.pendingKey(userB))
check("failed pending append reports failure (does not claim success)",
	okB == false)
check("failed pending append leaves the original reward intact",
	P.findInList(listB, "pend_old2") ~= nil
		and P.findInList(listB, "pend_old2").Amount == 300 and #listB == 1)
check("failed pending append leaves the caller's entry untouched for retry",
	entry.InstanceId == "pend_new2" and entry.Amount == 100)
check("append path uses no SetAsync (no read-modify-write left)",
	store.calls.SetAsync == 0, "SetAsync calls=" .. store.calls.SetAsync)
store:resetFailures()
local okB2 = DS.RecordPendingRewardSidecar(mockPlayer(userB), entry)
local listB2 = store:peek(P.pendingKey(userB))
check("retry after the outage succeeds and lands exactly once",
	okB2 == true and P.countInList(listB2, "pend_new2") == 1 and #listB2 == 2)

H.finish()
