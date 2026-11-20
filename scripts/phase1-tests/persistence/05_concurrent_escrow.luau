-- 05_concurrent_escrow.luau — R3-2: two concurrent server processes
-- appending different escrow entries to the same user's sidecar must
-- BOTH survive, regardless of interleaving. The interleaving is real:
-- the stub fires a one-shot hook inside server A's UpdateAsync commit
-- window that runs server B's whole append first, so B commits while
-- A is mid-flight; A's transform must then retry against B's value.
-- store.updateRetries >= 1 proves the retry actually happened (a
-- sequential run would show 0). Both directions are covered.
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

-- Direction 1: A starts, B commits inside A's commit window.
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
check("direction 1: the transform genuinely retried (not sequential)",
	store.updateRetries >= 1, "updateRetries=" .. store.updateRetries)

-- Direction 2: B starts, A commits inside B's commit window.
local userB = 7052
store:resetCounts()
store:armBeforeCommit(function()
	local okA2 = DS.EscrowReturnedInstance(userB, P.escrowRecord("race_a2"))
	assert(okA2 == true, "server A escrow must succeed inside the race window")
end)
local okB = DS.EscrowReturnedInstance(userB, P.escrowRecord("race_b2"))
local listB = store:peek(P.escrowKey(userB))
check("direction 2: server B append reports success",
	okB == true)
check("direction 2: both escrow entries survive the interleave",
	P.findInList(listB, "race_a2") ~= nil and P.findInList(listB, "race_b2") ~= nil
		and #listB == 2,
	"list size=" .. (type(listB) == "table" and #listB or tostring(listB)))
check("direction 2: the transform genuinely retried (not sequential)",
	store.updateRetries >= 1, "updateRetries=" .. store.updateRetries)

check("concurrent escrow appends use no GetAsync / SetAsync at all",
	store.calls.GetAsync == 0 and store.calls.SetAsync == 0,
	"GetAsync=" .. store.calls.GetAsync .. " SetAsync=" .. store.calls.SetAsync
		.. " UpdateAsync=" .. store.calls.UpdateAsync)

H.finish()
