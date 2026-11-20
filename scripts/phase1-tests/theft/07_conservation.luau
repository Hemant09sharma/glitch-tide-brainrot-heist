-- 07_conservation.luau — instance conservation across the whole theft
-- lifecycle. The ownership ledger is OwnedInstances (Base.Placed copies
-- are views, not second instances): the owned count for the InstanceId
-- across both players must be exactly 1 at every step of steal ->
-- delivery and steal -> return. Plus two failure-mode proofs: a record
-- consumed mid-transit is NEVER resurrected by the return path, and a
-- failed ownership transfer rolls the steal back instead of stranding
-- the instance in transit limbo.
-- Run: lune run scripts/phase1-tests/theft/07_conservation.luau
local H = require("../harness")

local env = H.newEnv()

-- A: steal -> delivery.
local pairA = H.newPair(env, 171, 271)
local bothA = { pairA.thief, pairA.victim }
H.check(1, "A: owned count is 1 before the steal", H.countOwned(env, bothA, pairA.targetId) == 1)
H.steal(env, pairA)
H.check(2, "A: owned count is 1 while in transit", H.countOwned(env, bothA, pairA.targetId) == 1)
H.check(3, "A: in transit the record sits with the thief",
	H.findOwned(pairA.thiefData, pairA.targetId) ~= nil
		and H.findOwned(pairA.victimData, pairA.targetId) == nil)
env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
H.check(4, "A: owned count is 1 after delivery", H.countOwned(env, bothA, pairA.targetId) == 1)
H.check(5, "A: after delivery the record sits with the thief",
	H.findOwned(pairA.thiefData, pairA.targetId) ~= nil
		and H.findOwned(pairA.victimData, pairA.targetId) == nil)

-- B: steal -> return.
local pairB = H.newPair(env, 173, 273)
local bothB = { pairB.thief, pairB.victim }
H.check(6, "B: owned count is 1 before the steal", H.countOwned(env, bothB, pairB.targetId) == 1)
H.steal(env, pairB)
H.check(7, "B: owned count is 1 while in transit", H.countOwned(env, bothB, pairB.targetId) == 1)
env.raid.ReturnStolen(pairB.targetId)
H.check(8, "B: owned count is 1 after the return", H.countOwned(env, bothB, pairB.targetId) == 1)
H.check(9, "B: after the return the record sits with the victim",
	H.findOwned(pairB.victimData, pairB.targetId) ~= nil
		and H.findOwned(pairB.thiefData, pairB.targetId) == nil)
H.check(10, "B: placed count is 1 after the return (no duplication)",
	H.countPlaced(env, bothB, pairB.targetId) == 1)

-- C: fuse-then-return, pre-fix duplication scenario. The fusion itself
-- is blocked by the guard (file 01); here the record is removed by
-- hand to simulate consumption by a path outside the guards, and the
-- return must NOT resurrect a victim copy.
local pairC = H.newPair(env, 175, 275)
local bothC = { pairC.thief, pairC.victim }
H.steal(env, pairC)
for index, inst in ipairs(pairC.thiefData.OwnedInstances) do
	if inst.InstanceId == pairC.targetId then
		table.remove(pairC.thiefData.OwnedInstances, index)
		break
	end
end
H.check(11, "C: setup — record consumed while in transit", H.countOwned(env, bothC, pairC.targetId) == 0)
local okRet = env.raid.ReturnStolen(pairC.targetId)
H.check(12, "C: return of a consumed instance fails (does not recreate)",
	okRet == false, "ok=" .. tostring(okRet))
H.check(13, "C: no placed copy recreated for the victim",
	H.countPlaced(env, bothC, pairC.targetId) == 0
		and H.findPlaced(pairC.victimData, pairC.targetId) == nil)
H.check(14, "C: no copy remains with the thief either",
	H.countOwned(env, bothC, pairC.targetId) == 0)

-- D: failed ownership transfer rolls the steal back. A sabotaged
-- MutationService whose MoveInstance deletes the record without
-- inserting it (a transfer that loses the record) makes the move fail;
-- the steal must fail, the placed copy must be restored, and no transit
-- entry may survive.
local pairD = H.newPair(env, 177, 277)
local realMutation = env.mutation
local sabotage = {
	MoveInstance = function(fromPlayer, _toPlayer, instanceId)
		local data = env.dataService.GetData(fromPlayer)
		if data and type(data.OwnedInstances) == "table" then
			for index, inst in ipairs(data.OwnedInstances) do
				if inst.InstanceId == instanceId then
					table.remove(data.OwnedInstances, index)
					break
				end
			end
		end
		return nil
	end,
	RemoveInstance = realMutation.RemoveInstance,
}
env.raid.SetMutationService(sabotage)
local okSteal, stealErr = env.raid.StealBrainrot(pairD.thief, pairD.victim.UserId, pairD.targetId)
H.check(15, "D: steal fails when the ownership transfer fails", okSteal == false
	and type(stealErr) == "string" and string.find(stealErr, "transfer") ~= nil,
	"err=" .. tostring(stealErr))
H.check(16, "D: placed copy rolled back (victim still has it placed)",
	H.findPlaced(pairD.victimData, pairD.targetId) ~= nil)
H.check(17, "D: no transit entry survives the failed steal",
	env.raid.ReturnStolen(pairD.targetId) == false)
H.check(18, "D: thief owns nothing of the target",
	H.countOwned(env, { pairD.thief }, pairD.targetId) == 0)
env.raid.SetMutationService(realMutation)

H.finish()
