-- 04_mutant_control.luau — NEGATIVE CONTROL (expected to FAIL).
-- Same assertions as 11_two_transactions_same_instance.luau (a),
-- run against the PRE-R3 DataService (mutant/DataServiceOld.luau:
-- the pending append COMBINES by InstanceId, accumulating Amount).
-- The old code must merge two distinct transactions into one summed
-- entry and must accumulate a replayed TxId — proving the test
-- detects the R3-4 double-count.
-- Run: bash scripts/phase1-tests/persistence/mutant/run_mutant.sh
local P = require("../persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService("./mutant/DataServiceOld")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local userA = 9211
local playerA = { UserId = userA, Name = "Player9211" }
local ok1 = DS.RecordPendingRewardSidecar(playerA, P.pendingEntryTx("r34_inst", 100, "tx-r34-1"))
local ok2 = DS.RecordPendingRewardSidecar(playerA, P.pendingEntryTx("r34_inst", 150, "tx-r34-2"))
local listA = store:peek(P.pendingKey(userA))
check("both recordings land in the sidecar",
	ok1 == true and ok2 == true)
check("two separate entries (one per transaction), not one summed entry",
	P.countInList(listA, "r34_inst") == 2 and #listA == 2,
	"list size=" .. (type(listA) == "table" and #listA or tostring(listA)))
check("sidecar total for the instance is exactly 250 (100 + 150)",
	P.sidecarTotal(listA, "r34_inst") == 250,
	"total=" .. tostring(P.sidecarTotal(listA, "r34_inst")))
local okReplay = DS.RecordPendingRewardSidecar(playerA, P.pendingEntryTx("r34_inst", 100, "tx-r34-1"))
local listA2 = store:peek(P.pendingKey(userA))
check("replaying the same TxId reports success but changes nothing",
	okReplay == true and P.countInList(listA2, "r34_inst") == 2
		and P.sidecarTotal(listA2, "r34_inst") == 250,
	"total=" .. tostring(P.sidecarTotal(listA2, "r34_inst")))

H.finish()
