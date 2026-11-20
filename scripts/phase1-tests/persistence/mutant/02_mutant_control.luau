-- 02_mutant_control.luau — NEGATIVE CONTROL (expected to FAIL).
-- Same assertions as 05_concurrent_escrow.luau direction 1, run against
-- the PRE-R3 DataService (mutant/DataServiceOld.luau: read-modify-write
-- + SetAsync). The old code has no retry: server B's entry, committed
-- inside server A's SetAsync window, is overwritten by A's whole-key
-- write — a lost update. The "both entries survive" assertion must
-- FAIL, proving the test detects the R3-2 race.
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

local userA = 7051
store:resetCounts()
store:armBeforeCommit(function()
	local okB = DS.EscrowReturnedInstance(userA, P.escrowRecord("race_b1"))
	assert(okB == true, "server B escrow must succeed inside the race window")
end)
local okA = DS.EscrowReturnedInstance(userA, P.escrowRecord("race_a1"))
local listA = store:peek(P.escrowKey(userA))
check("direction 1: server A append reports success",
	okA == true)
check("direction 1: both escrow entries survive the interleave",
	P.findInList(listA, "race_a1") ~= nil and P.findInList(listA, "race_b1") ~= nil
		and #listA == 2,
	"list size=" .. (type(listA) == "table" and #listA or tostring(listA)))

H.finish()
