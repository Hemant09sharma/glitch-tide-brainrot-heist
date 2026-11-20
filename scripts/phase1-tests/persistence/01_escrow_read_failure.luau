-- 01_escrow_read_failure.luau — R3-1 (A): a failed sidecar read must
-- never wipe existing escrow data.
--
-- NOTE on the R3-1 wording: the old code read the list with GetAsync
-- and then overwrote it with SetAsync, so two failed GetAsync calls
-- meant "empty list" and the old entry was destroyed. The R3 fix
-- removes the separate read entirely — the append is a single atomic
-- UpdateAsync, so a GetAsync outage cannot reach the append at all.
-- Phase 1 therefore asserts the invariant the requirement protects
-- (the old entry stays intact AND the new entry lands) under the same
-- injected GetAsync failure; phase 2 covers the failure mode that CAN
-- occur in the new path (UpdateAsync itself failing), where the
-- operation must report false and leave everything untouched.
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

-- Phase 1: GetAsync outage during an escrow append.
local userA = 7001
store:seed(P.escrowKey(userA), { P.escrowRecord("old_1") })
store:failGetAsync(2) -- both attempts a read-then-write append would make
local okA = DS.EscrowReturnedInstance(userA, P.escrowRecord("new_1"))
local listA = store:peek(P.escrowKey(userA))
check("escrow append under a GetAsync outage does not wipe the old entry",
	P.findInList(listA, "old_1") ~= nil,
	"list=" .. (type(listA) == "table" and #listA or tostring(listA)))
check("new entry still lands (atomic append needs no separate read)",
	okA == true and P.findInList(listA, "new_1") ~= nil)
check("exactly two entries, no duplicates",
	type(listA) == "table" and #listA == 2
		and P.countInList(listA, "old_1") == 1 and P.countInList(listA, "new_1") == 1)
store:resetFailures()

-- Phase 2: the append itself fails (UpdateAsync errors twice).
local userB = 7002
local oldRecord = P.escrowRecord("old_2")
store:seed(P.escrowKey(userB), { oldRecord })
local newRecord = P.escrowRecord("new_2")
local newSnapshot = P.escrowRecord("new_2") -- caller still holds this record
store:failUpdateAsync(2) -- both append attempts fail
local okB = DS.EscrowReturnedInstance(userB, newRecord)
local listB = store:peek(P.escrowKey(userB))
check("failed escrow append reports failure (does not claim success)",
	okB == false)
check("failed escrow append leaves the old entry intact",
	P.findInList(listB, "old_2") ~= nil and #listB == 1)
check("failed escrow append leaves the caller's record untouched for retry",
	newRecord.InstanceId == newSnapshot.InstanceId
		and newRecord.CharacterId == newSnapshot.CharacterId
		and newRecord.BankedIncome == newSnapshot.BankedIncome)
check("append path uses no SetAsync (no read-modify-write left)",
	store.calls.SetAsync == 0, "SetAsync calls=" .. store.calls.SetAsync)
store:resetFailures()
local okB2 = DS.EscrowReturnedInstance(userB, newRecord)
local listB2 = store:peek(P.escrowKey(userB))
check("retry after the outage succeeds and lands exactly once",
	okB2 == true and P.countInList(listB2, "new_2") == 1 and #listB2 == 2)

H.finish()
