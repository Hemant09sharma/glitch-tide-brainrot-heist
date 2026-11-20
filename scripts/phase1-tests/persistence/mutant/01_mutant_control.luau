-- 01_mutant_control.luau — NEGATIVE CONTROL (expected to FAIL).
-- Same assertions as 01_escrow_read_failure.luau phase 1, run against
-- the PRE-R3 DataService (mutant/DataServiceOld.luau: readSidecar
-- returning nil on failure + `or {}` + SetAsync writeSidecar). The old
-- code must WIPE the seeded entry, failing the "old entry intact"
-- assertion — proving the test detects the R3-1 bug.
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

local userA = 7001
store:seed(P.escrowKey(userA), { P.escrowRecord("old_1") })
store:failGetAsync(2) -- both attempts the old readSidecar makes
local okA = DS.EscrowReturnedInstance(userA, P.escrowRecord("new_1"))
local listA = store:peek(P.escrowKey(userA))
check("escrow append under a GetAsync outage does not wipe the old entry",
	P.findInList(listA, "old_1") ~= nil,
	"list=" .. (type(listA) == "table" and #listA or tostring(listA)))
check("new entry still lands",
	okA == true and P.findInList(listA, "new_1") ~= nil)
check("exactly two entries, no duplicates",
	type(listA) == "table" and #listA == 2)

H.finish()
