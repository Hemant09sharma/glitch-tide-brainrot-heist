-- 01_store.luau — StoreBrainrot (P0-4): place -> store -> re-place,
-- progression preservation, income stop, and store rejections.
-- Loads the REAL BaseService (see H.newBaseEnv) with the real
-- RaidService / CarryService / MutationService from harness.newEnv().
-- Run: lune run scripts/phase1-tests/store/01_store.luau
local H = require("../harness")

local env = H.newEnv()
local base = H.newBaseEnv(env)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- Rich owned fixture: an evolved, mutated, glitched Level-5 instance.
local function richOwned(pair)
	local owned = H.findOwned(pair.thiefData, pair.prefix .. "evo_1")
	owned.Mutation = "golden"
	owned.Glitched = true
	owned.Evolved = true
	owned.EvolutionId = "evolved_wobble_waffleton"
	owned.EvolvedTrait = "Electric"
	owned.EvolvedFormName = "Wobble Waffleton (Evolved)"
	owned.TraitLevels = { Food = 2 }
	return owned
end

local function placeOwned(pair, plotIndex, owned, slot)
	local okCarry, carryErr = env.carry.PickupOwned(pair.thief, owned)
	assert(okCarry, "PickupOwned failed: " .. tostring(carryErr))
	H.setRootPosition(pair.thief, H.pedestalPosition(plotIndex, slot))
	local ok, placed = base.PlaceBrainrot(pair.thief, owned.InstanceId, slot)
	assert(ok, "PlaceBrainrot failed: " .. tostring(placed))
	return placed
end

-- ---------------------------------------------------------------------------
-- Pair A: place -> store -> re-place, progression + income
-- ---------------------------------------------------------------------------
local pairA = H.newPair(env, 301, 401)
local plotA = base.AssignBase(pairA.thief)
check("A: plot assigned", plotA ~= nil, "plot=" .. tostring(plotA))
local ownedA = richOwned(pairA)
local placedA = placeOwned(pairA, plotA, ownedA, 1)
-- Simulate held banked income + an old placement on the placed copy
-- (the values a delivered / long-placed copy carries).
placedA.BankedIncome = 500
placedA.PlacedAt = pairA.oldTime
local incomeBefore = base.GetIncomePerSec(pairA.thief)
check("A: placed instance earns income", incomeBefore > 0, "income=" .. tostring(incomeBefore))
local coinsBefore = pairA.thiefData.Coins

local okStore, storedA = base.StoreBrainrot(pairA.thief, ownedA.InstanceId)
check("A: store succeeds", okStore == true, "err=" .. tostring(storedA))
check("A: no longer placed", H.findPlaced(pairA.thiefData, ownedA.InstanceId) == nil)
check("A: owned flag cleared (Placed=false, Slot=0)",
	ownedA.Placed == false and ownedA.Slot == 0,
	"Placed=" .. tostring(ownedA.Placed) .. " Slot=" .. tostring(ownedA.Slot))
check("A: level kept", ownedA.Level == 5, "Level=" .. tostring(ownedA.Level))
check("A: mutation kept", ownedA.Mutation == "golden", "Mutation=" .. tostring(ownedA.Mutation))
check("A: glitched kept", ownedA.Glitched == true)
check("A: banked income written back", ownedA.BankedIncome == 500,
	"BankedIncome=" .. tostring(ownedA.BankedIncome))
check("A: PlacedAt written back", ownedA.PlacedAt == pairA.oldTime,
	"PlacedAt=" .. tostring(ownedA.PlacedAt))
check("A: evolution kept", ownedA.Evolved == true
	and ownedA.EvolutionId == "evolved_wobble_waffleton"
	and ownedA.EvolvedTrait == "Electric"
	and ownedA.EvolvedFormName == "Wobble Waffleton (Evolved)",
	"EvolutionId=" .. tostring(ownedA.EvolutionId))
check("A: trait levels kept", type(ownedA.TraitLevels) == "table" and ownedA.TraitLevels.Food == 2)
check("A: income stops after store", base.GetIncomePerSec(pairA.thief) == 0,
	"income=" .. tostring(base.GetIncomePerSec(pairA.thief)))
check("A: no sell-back reward (coins unchanged)", pairA.thiefData.Coins == coinsBefore,
	"coins=" .. tostring(pairA.thiefData.Coins))

-- Re-place in a different free slot: same instance, data intact.
local placedA2 = placeOwned(pairA, plotA, ownedA, 2)
check("A: re-place in a free slot succeeds", placedA2 ~= nil and placedA2.Slot == 2)
check("A: re-placed copy keeps level/mutation/glitched",
	placedA2.Level == 5 and placedA2.Mutation == "golden" and placedA2.Glitched == true)
check("A: income resumes after re-place", base.GetIncomePerSec(pairA.thief) > 0,
	"income=" .. tostring(base.GetIncomePerSec(pairA.thief)))

-- ---------------------------------------------------------------------------
-- Pair B: a mutation applied AFTER placing must survive the store.
-- (MutationService writes the owned record only; the placed copy is
-- stale afterwards, so a blind placed->owned write-back would revert
-- it. StoreBrainrot must NOT do that.)
-- ---------------------------------------------------------------------------
local pairB = H.newPair(env, 302, 402)
local plotB = base.AssignBase(pairB.thief)
local ownedB = richOwned(pairB)
placeOwned(pairB, plotB, ownedB, 1)
ownedB.Mutation = "electric" -- post-placement mutation (owned-only)
local okStoreB = base.StoreBrainrot(pairB.thief, ownedB.InstanceId)
check("B: store succeeds after post-placement mutation", okStoreB == true)
check("B: post-placement mutation NOT reverted by store", ownedB.Mutation == "electric",
	"Mutation=" .. tostring(ownedB.Mutation))
check("B: other progression still kept (level/glitched/evolved)",
	ownedB.Level == 5 and ownedB.Glitched == true and ownedB.Evolved == true)
local okStoreB2, errB2 = base.StoreBrainrot(pairB.thief, ownedB.InstanceId)
check("B: storing an already-stored instance is rejected",
	okStoreB2 == false and errB2 == "brainrot not placed", "err=" .. tostring(errB2))
local okStoreB3, errB3 = base.StoreBrainrot(pairB.thief, pairB.prefix .. "alt_1")
check("B: storing a never-placed instance is rejected",
	okStoreB3 == false and errB3 == "brainrot not placed", "err=" .. tostring(errB3))

-- ---------------------------------------------------------------------------
-- Pair C: non-owner, owner-mismatch, in-transit, on-expedition
-- ---------------------------------------------------------------------------
local pairC = H.newPair(env, 303, 403)
local plotC = base.AssignBase(pairC.thief)
local plotCv = base.AssignBase(pairC.victim)
check("C: victim has their own plot", plotCv ~= nil and plotCv ~= plotC)
local ownedC = richOwned(pairC)
placeOwned(pairC, plotC, ownedC, 1)
local okNonOwner, errNonOwner = base.StoreBrainrot(pairC.victim, ownedC.InstanceId)
check("C: non-owner store is rejected", okNonOwner == false,
	"err=" .. tostring(errNonOwner) .. " (victim data has no such placed record)")
check("C: instance still placed after non-owner attempt",
	H.findPlaced(pairC.thiefData, ownedC.InstanceId) ~= nil)
pairC.thiefData.Base.OwnerUserId = 999999
local okMismatch, errMismatch = base.StoreBrainrot(pairC.thief, ownedC.InstanceId)
check("C: owner-mismatch data is rejected", okMismatch == false and errMismatch == "not your base",
	"err=" .. tostring(errMismatch))
pairC.thiefData.Base.OwnerUserId = pairC.thief.UserId
ownedC.InTransit = true
local okTransit, errTransit = base.StoreBrainrot(pairC.thief, ownedC.InstanceId)
check("C: in-transit store is rejected", okTransit == false and errTransit == "brainrot in transit",
	"err=" .. tostring(errTransit))
ownedC.InTransit = nil
ownedC.OnExpedition = true
local okExped, errExped = base.StoreBrainrot(pairC.thief, ownedC.InstanceId)
check("C: on-expedition store is rejected", okExped == false and errExped == "brainrot on expedition",
	"err=" .. tostring(errExped))
ownedC.OnExpedition = nil
check("C: store succeeds once flags clear", base.StoreBrainrot(pairC.thief, ownedC.InstanceId) == true)

-- ---------------------------------------------------------------------------
-- Pair D: REAL steal, then store the in-transit instance (rejected),
-- then ReturnStolen restores it to the victim.
-- ---------------------------------------------------------------------------
local pairD = H.newPair(env, 304, 404)
local plotD = base.AssignBase(pairD.thief)
local plotDv = base.AssignBase(pairD.victim)
-- Both players stay at the harness default (0,0,0): under Lune the
-- steal's pedestal lookups degrade to "near the victim" (CarryService
-- keeps the stub base, whose GetPlacedPosition returns (0,0,0), and
-- RaidService's typeof(Vector3) checks fail — see the harness
-- header), so (0,0,0) is where the steal validates.
H.steal(env, pairD)
local movedD = H.findOwned(pairD.thiefData, pairD.targetId)
check("D: steal moved the record with InTransit set",
	movedD ~= nil and movedD.InTransit == true)
local okStoreD, errStoreD = base.StoreBrainrot(pairD.thief, pairD.targetId)
check("D: storing an in-transit (stolen) instance is rejected", okStoreD == false,
	"err=" .. tostring(errStoreD))
check("D: transit flag still set after rejected store", movedD.InTransit == true)
check("D: stolen instance not duplicated by the attempt",
	H.countOwned(env, { pairD.thief, pairD.victim }, pairD.targetId) == 1)
local okReturn = env.raid.ReturnStolen(pairD.targetId)
check("D: ReturnStolen restores the victim afterwards", okReturn == true)
check("D: victim has the placed copy back",
	H.findPlaced(pairD.victimData, pairD.targetId) ~= nil)
check("D: thief no longer owns it",
	H.findOwned(pairD.thiefData, pairD.targetId) == nil)

H.finish()
