-- 03_empty_sidecar_accepts.luau — R3-1 (C): a genuinely empty sidecar
-- can still accept a new entry (both sidecars), and a stored non-table
-- value is treated as empty, as the pre-R3 read path did.
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

-- Escrow into a never-written key.
local userA = 7021
check("escrow key starts genuinely empty",
	store:peek(P.escrowKey(userA)) == nil)
local okA = DS.EscrowReturnedInstance(userA, P.escrowRecord("empty_1"))
local listA = store:peek(P.escrowKey(userA))
check("empty escrow sidecar accepts the first entry",
	okA == true and type(listA) == "table" and #listA == 1
		and P.findInList(listA, "empty_1") ~= nil)

-- Pending into a never-written key.
local userB = 7022
check("pending key starts genuinely empty",
	store:peek(P.pendingKey(userB)) == nil)
local okB = DS.RecordPendingRewardSidecar(mockPlayer(userB), P.pendingEntry("empty_p1", 300))
local listB = store:peek(P.pendingKey(userB))
check("empty pending sidecar accepts the first entry",
	okB == true and type(listB) == "table" and #listB == 1
		and P.findInList(listB, "empty_p1") ~= nil
		and P.findInList(listB, "empty_p1").Amount == 300)

-- A second, different entry appends after the first (sequential).
local okA2 = DS.EscrowReturnedInstance(userA, P.escrowRecord("empty_2"))
local listA2 = store:peek(P.escrowKey(userA))
check("second escrow entry appends onto the first",
	okA2 == true and #listA2 == 2
		and P.findInList(listA2, "empty_1") ~= nil
		and P.findInList(listA2, "empty_2") ~= nil)

-- A stored non-table value is treated as empty (pre-R3 read behaviour
-- preserved: no reader could use it, so the append starts a fresh list).
local userC = 7023
store:seed(P.escrowKey(userC), "corrupt-non-table-value")
local okC = DS.EscrowReturnedInstance(userC, P.escrowRecord("after_corrupt"))
local listC = store:peek(P.escrowKey(userC))
check("non-table stored value is treated as an empty list",
	okC == true and type(listC) == "table" and #listC == 1
		and P.findInList(listC, "after_corrupt") ~= nil)

H.finish()
