-- 04_failed_write_reports.luau — R3-1 (D): a failed write leaves the
-- authoritative in-memory / in-transit record available for retry.
-- The append function must report failure (return false) and must not
-- claim success; the caller's record/entry must be unchanged; and a
-- retry after the outage must land exactly once. Also covers the
-- retry policy: a single transient UpdateAsync failure is absorbed by
-- the append's own second attempt.
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

-- Escrow: both attempts fail -> false, nothing stored, record intact.
local userA = 7031
local record = P.escrowRecord("retry_1")
store:failUpdateAsync(2)
local okA = DS.EscrowReturnedInstance(userA, record)
check("escrow append failing twice reports false",
	okA == false)
check("nothing is stored after the failed escrow append",
	store:peek(P.escrowKey(userA)) == nil)
check("caller's in-transit record is unchanged after the failure",
	record.InstanceId == "retry_1" and record.Level == 5
		and record.BankedIncome == 500 and record.Placed == true)
local okA2 = DS.EscrowReturnedInstance(userA, record)
local listA = store:peek(P.escrowKey(userA))
check("retry succeeds and stores the record exactly once",
	okA2 == true and P.countInList(listA, "retry_1") == 1 and #listA == 1)

-- Pending: both attempts fail -> false, nothing stored, entry intact.
local userB = 7032
local entry = P.pendingEntry("retry_p1", 300)
store:failUpdateAsync(2)
local okB = DS.RecordPendingRewardSidecar(mockPlayer(userB), entry)
check("pending append failing twice reports false",
	okB == false)
check("nothing is stored after the failed pending append",
	store:peek(P.pendingKey(userB)) == nil)
check("caller's pending entry is unchanged after the failure",
	entry.InstanceId == "retry_p1" and entry.Amount == 300)
local okB2 = DS.RecordPendingRewardSidecar(mockPlayer(userB), entry)
local listB = store:peek(P.pendingKey(userB))
check("retry succeeds and stores the entry exactly once",
	okB2 == true and P.countInList(listB, "retry_p1") == 1 and #listB == 1)

-- Transient failure: one failed UpdateAsync is absorbed by the
-- append's own retry, so the caller still sees success.
local userC = 7033
store:failUpdateAsync(1)
local okC = DS.EscrowReturnedInstance(userC, P.escrowRecord("transient_1"))
local listC = store:peek(P.escrowKey(userC))
check("a single transient UpdateAsync failure is retried internally",
	okC == true and P.countInList(listC, "transient_1") == 1)

H.finish()
