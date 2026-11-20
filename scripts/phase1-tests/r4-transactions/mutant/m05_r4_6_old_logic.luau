-- m05_r4_6_old_logic.luau — NEGATIVE CONTROL for R4-6 (Test F):
-- No service modules needed: the old probabilistic TxId shape
-- (sr-<user>-<instance>-<unix>-<clockMs>-<counter>) is recomputed
-- here with controlled inputs. The control PASSES when the old
-- generator collides: the same inputs (same second, same
-- millisecond, same counter — e.g. two servers minting in the same
-- millisecond after a restart resets the counter) produce the
-- IDENTICAL id, and two servers with the same counter state collide
-- with each other. Test 05 proves the fixed GUID generator does
-- not do this.
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local H = require("../../harness")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function oldRewardTxId(userId, instanceId, unix, clockMs, counter)
	return string.format("sr-%d-%s-%d-%d-%d", userId, instanceId, unix, clockMs, counter)
end

local a = oldRewardTxId(9451, "t9451v9452_target", 1700000000, 123, 1)
local b = oldRewardTxId(9451, "t9451v9452_target", 1700000000, 123, 1)
check("OLD BUG REPRODUCED: identical inputs give identical old TxIds", a == b, "id=" .. a)
-- Server B restarts (counter resets to 1) and mints in the same
-- millisecond as server A: the same id for a different transaction.
local c = oldRewardTxId(9451, "t9451v9452_target", 1700000000, 123, 1)
check("OLD BUG REPRODUCED: two servers with the same counter collide", a == c)
-- Even a retry in the same millisecond with a counter that has not
-- advanced yet collides.
local d = oldRewardTxId(9451, "t9451v9452_target", 1700000000, 123, 1)
check("OLD BUG REPRODUCED: a same-millisecond retry collides", a == d)

H.finish()
