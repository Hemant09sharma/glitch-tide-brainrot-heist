-- 02_guards_in_transit.luau — guard contract, every entry point.
--
-- Steal -> mutation, evolution, trait upgrade, alternate-form switch,
-- lab delegates, and carry pickup on the in-transit instance must all be
-- rejected; the instance must be unchanged afterwards. Positive controls
-- run first on the thief's own unplaced instances (each op succeeds once
-- when the instance is NOT in transit).
-- Run: lune run scripts/phase1-tests/theft/02_guards_in_transit.luau
local H = require("../harness")

local env = H.newEnv()
local pair = H.newPair(env, 111, 212)
local thief = pair.thief
local p = pair.prefix

-- Positive controls (each op succeeds on a non-transit instance).
local okEvo, evoInst = env.lab.EvolveBrainrot(thief, p .. "evo_1")
H.check(1, "control: evolve succeeds when not in transit", okEvo == true and evoInst ~= nil and evoInst.Evolved == true,
	"ok=" .. tostring(okEvo))
local okTrait, traitLevel = env.lab.UpgradeTrait(thief, p .. "trait_1", "Food")
H.check(2, "control: trait upgrade succeeds when not in transit", okTrait == true and traitLevel == 1,
	"ok=" .. tostring(okTrait))
local okAlt, altId = env.lab.SwitchAlternateForm(thief, p .. "alt_1")
H.check(3, "control: alternate-form switch succeeds when not in transit",
	okAlt == true and altId == "solar_sloth", "ok=" .. tostring(okAlt) .. " alt=" .. tostring(altId))
local okMut, _mutInst = env.mutation.MutateBrainrot(thief, p .. "fuse_a", "golden")
H.check(4, "control: mutate succeeds when not in transit", okMut == true, "ok=" .. tostring(okMut))
local carryRec = H.findOwned(pair.thiefData, p .. "carry_1")
local okPick, _pickId = env.carry.PickupOwned(thief, carryRec)
H.check(5, "control: pickup succeeds when not in transit", okPick == true, "ok=" .. tostring(okPick))
env.carry.ClearCarried(thief, true)

-- Theft.
H.steal(env, pair)
local targetId = pair.targetId
local function isTransitRejection(ok, reason)
	return ok == false and type(reason) == "string" and string.find(reason, "transit") ~= nil
end

local okFuse, fuseReason = env.fusion.FuseBrainrot(thief, targetId, p .. "fuse_b")
H.check(6, "in-transit: fusion rejected", isTransitRejection(okFuse, fuseReason), "reason=" .. tostring(fuseReason))
local okMut2, mutReason = env.mutation.MutateBrainrot(thief, targetId, "electric")
H.check(7, "in-transit: mutation rejected", isTransitRejection(okMut2, mutReason), "reason=" .. tostring(mutReason))
local okEvo2, evoReason = env.lab.EvolveBrainrot(thief, targetId)
H.check(8, "in-transit: evolution rejected", isTransitRejection(okEvo2, evoReason), "reason=" .. tostring(evoReason))
local okTrait2, traitReason = env.lab.UpgradeTrait(thief, targetId, "Food")
H.check(9, "in-transit: trait upgrade rejected", isTransitRejection(okTrait2, traitReason), "reason=" .. tostring(traitReason))
local okAlt2, altReason = env.lab.SwitchAlternateForm(thief, targetId)
H.check(10, "in-transit: alternate-form switch rejected", isTransitRejection(okAlt2, altReason), "reason=" .. tostring(altReason))
local okLabMut, labMutReason = env.lab.MutateBrainrot(thief, targetId, "electric")
H.check(11, "in-transit: lab mutate delegate rejected (inherits guard)",
	isTransitRejection(okLabMut, labMutReason), "reason=" .. tostring(labMutReason))
local okLabFuse, labFuseReason = env.lab.FuseBrainrot(thief, targetId, p .. "fuse_b")
H.check(12, "in-transit: lab fuse delegate rejected (inherits guard)",
	isTransitRejection(okLabFuse, labFuseReason), "reason=" .. tostring(labFuseReason))

-- Carry: clear the stolen carry first (silently — no DropStolen), so the
-- transit guard itself is what rejects the pickup, not "already carrying".
env.carry.ClearCarried(thief, true)
local stolenRec = H.findOwned(pair.thiefData, targetId)
local okPick2, pickReason = env.carry.PickupOwned(thief, stolenRec)
H.check(13, "in-transit: PickupOwned rejected", isTransitRejection(okPick2, pickReason), "reason=" .. tostring(pickReason))
local okPick3, pickReason3 = env.carry.PickupBrainrot(thief, targetId)
H.check(14, "in-transit: PickupBrainrot rejected", isTransitRejection(okPick3, pickReason3), "reason=" .. tostring(pickReason3))

-- The instance is unchanged by all the rejected operations.
local after = H.findOwned(pair.thiefData, targetId)
H.check(15, "in-transit: instance unchanged after rejections",
	after ~= nil and after.InTransit == true and after.Level == 5
		and after.Mutation == "golden" and after.Evolved == true
		and after.EvolutionId == "evolved_wobble_waffleton"
		and after.EvolvedTrait == "Electric"
		and after.EvolvedFormName == "Wobble Waffleton (Evolved)"
		and type(after.TraitLevels) == "table" and after.TraitLevels.Food == 2,
	"level=" .. tostring(after and after.Level) .. " mut=" .. tostring(after and after.Mutation))

H.finish()
