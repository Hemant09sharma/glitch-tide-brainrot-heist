-- m01_r4_1_old_logic.luau — NEGATIVE CONTROL for R4-1 (Test A):
-- The same Qwen five-condition scenario as test 01, run against
-- the R3 mutant RaidService (ConfirmDelivery without the delivery
-- tombstone). The control PASSES when the OLD bad outcome is
-- observed: after the victim's rejoin, BOTH players own the same
-- InstanceId. If this control failed, test 01 would pass even
-- against the broken code.
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local R = require("../r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv({ raidPath = "./mutant/RaidServiceR3" })
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = P.newLoadedPair(env, 9601, 9602)
H.steal(env, pair)
assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
local restore = R.failSetAsyncForKey(P.mainKey(pair.victim.UserId))
env.raid.DropStolen(pair.thief)
for _ = 1, 3 do
	env.raid.ReturnStolen(pair.targetId)
end
restore()
local thief2 = R.newLoadedPlayer(env, 9603, 100000)
local okSteal2, errSteal2 = env.raid.StealBrainrot(thief2, pair.victim.UserId, pair.targetId)
check("setup: second thief re-steals", okSteal2 == true, "err=" .. tostring(errSteal2))
local okDel2, status2 = env.raid.ConfirmDelivery(thief2, pair.targetId)
check("setup: second thief delivers", okDel2 == true and status2 == nil, "status=" .. tostring(status2))
assert(DS.SaveData(thief2) == true, "setup: second thief save must land")
-- No tombstone was parked by the old delivery.
local escrow = store:peek(P.escrowKey(pair.victim.UserId))
local hasTombstone = false
if type(escrow) == "table" then
	for _, entry in ipairs(escrow) do
		if type(entry) == "table" and entry.Superseded == true then
			hasTombstone = true
		end
	end
end
check("old logic: no delivery tombstone is parked", hasTombstone == false)
-- Crash + victim rejoin: the stale escrow resurrects the duplicate.
DS.LoadData(thief2)
DS.LoadData(pair.victim)
env.raid.RecoverOnRejoin(pair.victim)
check("OLD BUG REPRODUCED: both players own the same InstanceId after rejoin",
	H.countOwned(env, { thief2, pair.victim }, pair.targetId) == 2,
	"count=" .. tostring(H.countOwned(env, { thief2, pair.victim }, pair.targetId)))
check("OLD BUG REPRODUCED: the victim got a duplicate copy back",
	H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil)
check("OLD BUG REPRODUCED: the delivered thief still holds it too",
	H.findOwned(DS.GetData(thief2), pair.targetId) ~= nil)

H.finish()
