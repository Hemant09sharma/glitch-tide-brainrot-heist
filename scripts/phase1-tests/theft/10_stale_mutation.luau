-- 10_stale_mutation.luau — R2-1 (N1): the owned record is authoritative
-- for Mutation at steal time, and MutateBrainrot keeps a placed copy in
-- sync. Fixture: the victim's golden wobble (level 5, glitched) is
-- mutated to electric (40 crystals), then stolen and delivered.
-- Income check: wobble base 5/s, level 5 -> 5*(1+4*0.25)=10/s, glitched
-- x2 -> 20/s, electric x2 -> 40/s. Golden would pay 50/s (10*2*2.5), so
-- 40/s discriminates electric from the stale golden mutation.
-- Loads the REAL BaseService (see H.newBaseEnv) with the real
-- RaidService / CarryService / MutationService from harness.newEnv().
-- The stub base is wired into MutationService so the placed-model
-- rebuild is observable (stub RebuildBase counts calls).
-- Run: lune run scripts/phase1-tests/theft/10_stale_mutation.luau
local H = require("../harness")
local Economy = require("./shared/Economy")

local env = H.newEnv()
local base = H.newBaseEnv(env)
env.mutation.SetBaseService(env.base)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function incomeOf(placed)
	return Economy.IncomePerSecond({
		CharacterId = placed.CharacterId,
		Level = placed.Level,
		Glitched = placed.Glitched,
		Mutation = placed.Mutation,
	})
end

-- ---------------------------------------------------------------------------
-- Pair A: mutate a PLACED Brainrot — the placed copy must sync at once.
-- ---------------------------------------------------------------------------
local pairA = H.newPair(env, 911, 912)
local plotAt = base.AssignBase(pairA.thief)
local plotAv = base.AssignBase(pairA.victim)
assert(plotAt ~= nil and plotAv ~= nil, "pair A plots not assigned")
check("A: fixture starts golden on both copies",
	H.findOwned(pairA.victimData, pairA.targetId).Mutation == "golden"
		and H.findPlaced(pairA.victimData, pairA.targetId).Mutation == "golden")
local crystalsBeforeA = pairA.victimData.MutationCrystals
local rebuildsBeforeA = env.base._rebuilds[pairA.victim] or 0
local okMutA, mutErrA = env.mutation.MutateBrainrot(pairA.victim, pairA.targetId, "electric")
check("A: mutate placed golden wobble to electric succeeds",
	okMutA == true, "err=" .. tostring(mutErrA))
check("A: Mutation Crystals deducted exactly once (100 -> 60)",
	pairA.victimData.MutationCrystals == crystalsBeforeA - 40,
	"crystals=" .. tostring(pairA.victimData.MutationCrystals))
check("A: owned record is electric",
	H.findOwned(pairA.victimData, pairA.targetId).Mutation == "electric")
check("A: placed copy synced to electric at once (no stale golden)",
	H.findPlaced(pairA.victimData, pairA.targetId).Mutation == "electric")
check("A: placed models rebuilt so the display picks up the new look",
	(env.base._rebuilds[pairA.victim] or 0) > rebuildsBeforeA,
	"rebuilds=" .. tostring(env.base._rebuilds[pairA.victim] or 0))
local snapshotA = base.GetBase(pairA.victim)
local snapPlacedA: any = nil
if snapshotA and type(snapshotA.Placed) == "table" then
	for _, placed in ipairs(snapshotA.Placed) do
		if type(placed) == "table" and placed.InstanceId == pairA.targetId then
			snapPlacedA = placed
			break
		end
	end
end
check("A: displayed base snapshot shows electric (not golden)",
	snapPlacedA ~= nil and snapPlacedA.Mutation == "electric")
check("A: income multiplier is electric (40/s, not golden 50/s)",
	incomeOf(H.findPlaced(pairA.victimData, pairA.targetId)) == 40,
	"income=" .. tostring(incomeOf(H.findPlaced(pairA.victimData, pairA.targetId))))
local okMutA2, mutErrA2 = env.mutation.MutateBrainrot(pairA.victim, pairA.targetId, "electric")
check("A: re-mutating to the same mutation is rejected (no double charge)",
	okMutA2 == false and type(mutErrA2) == "string",
	"err=" .. tostring(mutErrA2))
check("A: crystals unchanged by the rejected re-mutation",
	pairA.victimData.MutationCrystals == crystalsBeforeA - 40)
local ownedA = H.findOwned(pairA.victimData, pairA.targetId)
check("A: mutation progress intact (level/glitched/evolution untouched)",
	ownedA ~= nil and ownedA.Level == 5 and ownedA.Glitched == true
		and ownedA.Evolved == true and ownedA.EvolutionId == "evolved_wobble_waffleton"
		and type(ownedA.TraitLevels) == "table" and ownedA.TraitLevels.Food == 2)

-- ---------------------------------------------------------------------------
-- Pair B: the snapshot must take the OWNED mutation even when the placed
-- copy is stale. The placed copy is reverted to golden by hand here to
-- simulate the pre-fix lag (a placed copy that never saw the paid
-- mutation); the steal snapshot must still be electric.
-- ---------------------------------------------------------------------------
local pairB = H.newPair(env, 913, 914)
local plotBt = base.AssignBase(pairB.thief)
local plotBv = base.AssignBase(pairB.victim)
assert(plotBt ~= nil and plotBv ~= nil, "pair B plots not assigned")
local okMutB, mutErrB = env.mutation.MutateBrainrot(pairB.victim, pairB.targetId, "electric")
check("B: mutate to electric succeeds", okMutB == true, "err=" .. tostring(mutErrB))
-- Simulate the stale placed copy: owned is electric, placed lags golden.
H.findPlaced(pairB.victimData, pairB.targetId).Mutation = "golden"
check("B: stale fixture set up (owned electric, placed golden)",
	H.findOwned(pairB.victimData, pairB.targetId).Mutation == "electric"
		and H.findPlaced(pairB.victimData, pairB.targetId).Mutation == "golden")
H.steal(env, pairB)
local movedB = H.findOwned(pairB.thiefData, pairB.targetId)
check("B: in-transit record carries the owned (electric) mutation",
	movedB ~= nil and movedB.Mutation == "electric",
	"Mutation=" .. tostring(movedB and movedB.Mutation))
H.setRootPosition(pairB.thief, H.pedestalPosition(plotBt, 1))
local okPlaceB, placedB = base.PlaceBrainrot(pairB.thief, pairB.targetId, 1)
check("B: delivery through the real BaseService succeeds",
	okPlaceB == true, "err=" .. tostring(placedB))
check("B: delivered owned record is electric (not the stale golden)",
	movedB ~= nil and movedB.Mutation == "electric")
check("B: delivered placed copy is electric (not the stale golden)",
	placedB ~= nil and placedB.Mutation == "electric",
	"Mutation=" .. tostring(placedB and placedB.Mutation))
check("B: delivered income is electric (40/s, not golden 50/s)",
	placedB ~= nil and incomeOf(placedB) == 40,
	"income=" .. tostring(placedB and incomeOf(placedB)))
check("B: crystals deducted exactly once (100 -> 60)",
	pairB.victimData.MutationCrystals == 60,
	"crystals=" .. tostring(pairB.victimData.MutationCrystals))
check("B: delivered instance keeps level/glitched/evolution",
	movedB ~= nil and movedB.Level == 5 and movedB.Glitched == true
		and movedB.Evolved == true and movedB.EvolutionId == "evolved_wobble_waffleton")
check("B: exactly one owned copy, with the thief",
	H.countOwned(env, { pairB.thief, pairB.victim }, pairB.targetId) == 1
		and H.findOwned(pairB.victimData, pairB.targetId) == nil)

H.finish()
