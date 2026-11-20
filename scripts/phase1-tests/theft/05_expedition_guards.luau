-- 05_expedition_guards.luau — an on-expedition instance cannot be
-- fused / mutated / evolved / trait-upgraded / form-switched / carried,
-- and cannot be stolen. Every guarded op is rejected; the instances are
-- unchanged afterwards.
-- Run: lune run scripts/phase1-tests/theft/05_expedition_guards.luau
local H = require("../harness")

local env = H.newEnv()
local pair = H.newPair(env, 141, 241)
local thief = pair.thief
local p = pair.prefix

local function markExpedition(id)
	local inst = H.findOwned(pair.thiefData, id)
	inst.OnExpedition = true
	return inst
end
local fuseA = markExpedition(p .. "fuse_a")
local evo1 = markExpedition(p .. "evo_1")
local trait1 = markExpedition(p .. "trait_1")
local alt1 = markExpedition(p .. "alt_1")
local carry1 = markExpedition(p .. "carry_1")

local function isExpeditionRejection(ok, reason)
	return ok == false and type(reason) == "string" and string.find(reason, "expedition") ~= nil
end

local okFuse, fuseReason = env.fusion.FuseBrainrot(thief, p .. "fuse_a", p .. "fuse_b")
H.check(1, "on-expedition: fusion rejected", isExpeditionRejection(okFuse, fuseReason), "reason=" .. tostring(fuseReason))
local okMut, mutReason = env.mutation.MutateBrainrot(thief, p .. "evo_1", "golden")
H.check(2, "on-expedition: mutation rejected", isExpeditionRejection(okMut, mutReason), "reason=" .. tostring(mutReason))
local okEvo, evoReason = env.lab.EvolveBrainrot(thief, p .. "evo_1")
H.check(3, "on-expedition: evolution rejected", isExpeditionRejection(okEvo, evoReason), "reason=" .. tostring(evoReason))
local okTrait, traitReason = env.lab.UpgradeTrait(thief, p .. "trait_1", "Food")
H.check(4, "on-expedition: trait upgrade rejected", isExpeditionRejection(okTrait, traitReason), "reason=" .. tostring(traitReason))
local okAlt, altReason = env.lab.SwitchAlternateForm(thief, p .. "alt_1")
H.check(5, "on-expedition: alternate-form switch rejected", isExpeditionRejection(okAlt, altReason), "reason=" .. tostring(altReason))
local okPick, pickReason = env.carry.PickupOwned(thief, carry1)
H.check(6, "on-expedition: PickupOwned rejected", isExpeditionRejection(okPick, pickReason), "reason=" .. tostring(pickReason))
local okPick2, pickReason2 = env.carry.PickupBrainrot(thief, p .. "carry_1")
H.check(7, "on-expedition: PickupBrainrot rejected", isExpeditionRejection(okPick2, pickReason2), "reason=" .. tostring(pickReason2))
local okLabMut, labMutReason = env.lab.MutateBrainrot(thief, p .. "evo_1", "golden")
H.check(8, "on-expedition: lab mutate delegate rejected", isExpeditionRejection(okLabMut, labMutReason), "reason=" .. tostring(labMutReason))
local okLabFuse, labFuseReason = env.lab.FuseBrainrot(thief, p .. "fuse_a", p .. "fuse_b")
H.check(9, "on-expedition: lab fuse delegate rejected", isExpeditionRejection(okLabFuse, labFuseReason), "reason=" .. tostring(labFuseReason))
H.check(10, "on-expedition: instances unchanged after rejections",
	fuseA.OnExpedition == true and fuseA.Mutation == nil
		and evo1.OnExpedition == true and evo1.Evolved ~= true and evo1.Mutation == nil
		and trait1.OnExpedition == true
		and (trait1.TraitLevels == nil or trait1.TraitLevels.Food == nil)
		and alt1.OnExpedition == true and alt1.CharacterId == "glitchy_goose"
		and carry1.OnExpedition == true and env.carry.IsCarrying(thief) == false)

-- An on-expedition instance cannot be stolen either.
local pair2 = H.newPair(env, 143, 243, { targetOverrides = { OnExpedition = true } })
local okSteal, stealReason = env.raid.StealBrainrot(pair2.thief, pair2.victim.UserId, pair2.targetId)
H.check(11, "on-expedition: steal rejected", okSteal == false
	and type(stealReason) == "string" and string.find(stealReason, "expedition") ~= nil,
	"reason=" .. tostring(stealReason))
H.check(12, "on-expedition: failed steal leaves victim untouched",
	H.countOwned(env, { pair2.thief, pair2.victim }, pair2.targetId) == 1
		and H.findOwned(pair2.victimData, pair2.targetId) ~= nil
		and H.findPlaced(pair2.victimData, pair2.targetId) ~= nil
		and env.raid.ReturnStolen(pair2.targetId) == false)

H.finish()
