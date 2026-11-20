-- 07_dedupe_and_callback_purity.luau — R3-2: appending the same entry
-- twice (same stable InstanceId) results in one entry; and the
-- UpdateAsync callback is provably side-effect-free and deterministic
-- under retry.
--
-- The stub enforces callback purity itself: it errors if the transform
-- mutates its input or returns different outputs for the same input.
-- This file forces a retry (a hook re-seeds the key with the same value
-- inside the commit window, bumping its version) and then asserts the
-- retried transform produced the same, correct result. Reaching
-- H.finish() at all proves no purity/determinism error fired.
--
-- NOTE on pending amounts (R3-4): a second append of the same pending
-- entry — the SAME TxId — is a replayed recording and is a no-op: one
-- entry, its Amount unchanged (300, not 600). That is the R3-4 fix:
-- the old accumulate-on-duplicate behaviour double-counted whenever
-- the caller passed an already-accumulated total as a delta. Two
-- DIFFERENT transactions for the same instance carry different TxIds
-- and land as separate entries (checked below). Escrow, by contrast,
-- is a pure no-op on duplicate (the record is unchanged).
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

-- Escrow: same record twice -> one entry, unchanged.
local userA = 7071
local okA1 = DS.EscrowReturnedInstance(userA, P.escrowRecord("dupe_1"))
local okA2 = DS.EscrowReturnedInstance(userA, P.escrowRecord("dupe_1"))
local listA = store:peek(P.escrowKey(userA))
check("escrow duplicate append reports success both times",
	okA1 == true and okA2 == true)
check("escrow duplicate append results in exactly one entry",
	P.countInList(listA, "dupe_1") == 1 and #listA == 1)
check("escrow duplicate entry is unchanged (no-op, not a rewrite)",
	P.findInList(listA, "dupe_1") ~= nil
		and P.findInList(listA, "dupe_1").Level == 5
		and P.findInList(listA, "dupe_1").BankedIncome == 500)

-- Pending: same entry (same TxId) twice -> one entry, amount UNCHANGED.
local userB = 7072
local okB1 = DS.RecordPendingRewardSidecar(mockPlayer(userB),
	P.pendingEntry("dupe_p1", 300, { TxId = "tx-dupe-p1" }))
local okB2 = DS.RecordPendingRewardSidecar(mockPlayer(userB),
	P.pendingEntry("dupe_p1", 300, { TxId = "tx-dupe-p1" }))
local listB = store:peek(P.pendingKey(userB))
check("pending duplicate append reports success both times",
	okB1 == true and okB2 == true)
check("pending duplicate append results in exactly one entry",
	P.countInList(listB, "dupe_p1") == 1 and #listB == 1)
check("pending duplicate replay is a no-op (Amount stays 300, not 600)",
	P.findInList(listB, "dupe_p1") ~= nil
		and P.findInList(listB, "dupe_p1").Amount == 300,
	"amount=" .. tostring(P.findInList(listB, "dupe_p1") and P.findInList(listB, "dupe_p1").Amount))

-- Pending: same InstanceId, DIFFERENT TxIds -> two separate entries.
local userB2 = 7074
local okB3 = DS.RecordPendingRewardSidecar(mockPlayer(userB2),
	P.pendingEntry("dupe_p2", 300, { TxId = "tx-dupe-p2-a" }))
local okB4 = DS.RecordPendingRewardSidecar(mockPlayer(userB2),
	P.pendingEntry("dupe_p2", 300, { TxId = "tx-dupe-p2-b" }))
local listB2 = store:peek(P.pendingKey(userB2))
check("pending distinct transactions report success both times",
	okB3 == true and okB4 == true)
check("pending distinct transactions land as two entries, not one summed entry",
	P.countInList(listB2, "dupe_p2") == 2 and #listB2 == 2,
	"list size=" .. (type(listB2) == "table" and #listB2 or tostring(listB2)))
local totalB2 = 0
if type(listB2) == "table" then
	for _, entry in ipairs(listB2) do
		totalB2 += (tonumber(entry.Amount) or 0)
	end
end
check("pending distinct transactions keep their own deltas (300 + 300 = 600 across entries)",
	totalB2 == 600, "total=" .. tostring(totalB2))

-- Forced retry: the hook re-seeds the key with its current value
-- inside the commit window. The value is unchanged, but the version
-- bumps, so the transform MUST run again on the same input — and the
-- stub errors if the second run differs from the first.
local userC = 7073
store:resetCounts()
store:armBeforeCommit(function()
	store:seed(P.escrowKey(userC), store:peek(P.escrowKey(userC)))
end)
local okC = DS.EscrowReturnedInstance(userC, P.escrowRecord("retry_pure"))
local listC = store:peek(P.escrowKey(userC))
check("forced-retry append reports success",
	okC == true)
check("forced-retry append lands exactly once",
	P.countInList(listC, "retry_pure") == 1 and #listC == 1)
check("the transform ran more than once (retry exercised)",
	store.transformCalls >= 2, "transformCalls=" .. store.transformCalls)
check("the transform retried on the version bump",
	store.updateRetries >= 1, "updateRetries=" .. store.updateRetries)
check("no purity / determinism error fired inside any callback",
	true, "reaching this check proves the stub's purity assertions held")

check("dedupe appends use no GetAsync / SetAsync at all",
	store.calls.GetAsync == 0 and store.calls.SetAsync == 0,
	"GetAsync=" .. store.calls.GetAsync .. " SetAsync=" .. store.calls.SetAsync)

H.finish()
