-- 02_delivery.luau — P1-2 + P0-3-vector-2: stolen delivery through the
-- REAL BaseService.PlaceBrainrot: all validation BEFORE ConfirmDelivery,
-- exact-InstanceId resolution, never mint.
-- Loads the REAL BaseService (see H.newBaseEnv) with the real
-- RaidService / CarryService from harness.newEnv().
-- Run: lune run scripts/phase1-tests/store/02_delivery.luau
local H = require("../harness")

local env = H.newEnv()
local base = H.newBaseEnv(env)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- Steal pair.targetId; thief ends up carrying it stolen. Both players
-- stay at the harness default (0,0,0) for the steal: under Lune the
-- steal's pedestal lookups degrade to "near the victim" (CarryService
-- keeps the stub base, whose GetPlacedPosition returns (0,0,0), and
-- RaidService's typeof(Vector3) checks fail), so (0,0,0) is where the
-- steal validates. The delivery-distance checks below use the real
-- pedestal geometry instead: the thief starts ~100 studs from their
-- own pedestal (far) and is then moved onto it (near).
local function stealPair(thiefId, victimId)
	local pair = H.newPair(env, thiefId, victimId)
	local plotT = base.AssignBase(pair.thief)
	local plotV = base.AssignBase(pair.victim)
	H.steal(env, pair)
	return pair, plotT, plotV
end

-- ---------------------------------------------------------------------------
-- Pair A: delivery from OUTSIDE pedestal distance fails cleanly, then
-- the SAME theft delivers fine once the thief is in range.
-- StealReward for the fixture = half banked (500*0.5=250) +
-- IncomePerSec*10 (wobble 5*10=50) = 300 coins (see theft test 04).
-- ---------------------------------------------------------------------------
local pairA, plotA = stealPair(311, 411)
local coinsBeforeA = pairA.thiefData.Coins
-- Thief is still at the origin (0,0,0): ~104 studs from their own
-- pedestal slot 1 (plot 311, slot 1 at (104,0,0)) — far beyond
-- PLACE_DISTANCE (12).
local okFar, errFar = base.PlaceBrainrot(pairA.thief, pairA.targetId, 1)
check("A: far delivery is rejected", okFar == false and errFar == "too far from the pedestal",
	"err=" .. tostring(errFar))
check("A: no reward paid on failed delivery", pairA.thiefData.Coins == coinsBeforeA,
	"coins=" .. tostring(pairA.thiefData.Coins))
local movedA = H.findOwned(pairA.thiefData, pairA.targetId)
check("A: transit still active after failed delivery", movedA ~= nil and movedA.InTransit == true)
check("A: instance NOT placed after failed delivery",
	H.findPlaced(pairA.thiefData, pairA.targetId) == nil)
check("A: instance NOT duplicated by failed delivery",
	H.countOwned(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)
check("A: thief still carrying the stolen instance",
	env.carry.GetCarried(pairA.thief) ~= nil
		and env.carry.GetCarried(pairA.thief).InstanceId == pairA.targetId)
check("A: failed delivery writes nothing to the owned record (snapshot intact)",
	movedA ~= nil and movedA.BankedIncome == nil and movedA.PlacedAt == nil
		and movedA.Level == 5 and movedA.Mutation == "golden",
	"BankedIncome=" .. tostring(movedA and movedA.BankedIncome)
		.. " PlacedAt=" .. tostring(movedA and movedA.PlacedAt))

-- Same theft, now in range: delivery must succeed exactly once.
-- Discriminator for the old CharacterId scan: a second unplaced
-- wobble acquired AFTER the steal sorts after the moved record, so
-- the old backwards scan would have placed THIS one instead of the
-- stolen instance. The fix must still place targetId exactly.
table.insert(pairA.thiefData.OwnedInstances, {
	InstanceId = pairA.prefix .. "late_wobble",
	CharacterId = "wobble_waffleton",
	Level = 1,
	Mutation = nil,
	Placed = false,
	Slot = 0,
})
H.setRootPosition(pairA.thief, H.pedestalPosition(plotA, 1))
local deliveryStart = os.time()
local okNear, placedA = base.PlaceBrainrot(pairA.thief, pairA.targetId, 1)
check("A: in-range delivery succeeds", okNear == true, "err=" .. tostring(placedA))
check("A: reward paid exactly once (300 coins)", pairA.thiefData.Coins == coinsBeforeA + 300,
	"coins=" .. tostring(pairA.thiefData.Coins))
check("A: instance placed exactly once in the thief base",
	H.countPlaced(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1
		and H.findPlaced(pairA.thiefData, pairA.targetId) ~= nil)
check("A: placed copy is the STOLEN instance id (not another wobble)",
	placedA ~= nil and placedA.InstanceId == pairA.targetId)
check("A: the thief's other unplaced wobbles were NOT placed instead",
	H.findOwned(pairA.thiefData, pairA.prefix .. "evo_1").Placed ~= true
		and H.findOwned(pairA.thiefData, pairA.prefix .. "carry_1").Placed ~= true
		and H.findOwned(pairA.thiefData, pairA.prefix .. "late_wobble").Placed ~= true)
check("A: transit cleared on delivery", movedA.InTransit ~= true)
check("A: delivered instance keeps level/mutation/glitched/evolution",
	placedA ~= nil and placedA.Level == 5 and placedA.Mutation == "golden"
		and placedA.Glitched == true
		and movedA.Evolved == true and movedA.EvolutionId == "evolved_wobble_waffleton")
-- R1 (fixed): ConfirmDelivery writes the snapshot remainder onto the
-- owned record before PlaceBrainrot builds the placed copy: 500
-- banked -> 250 paid immediately (reward), 250 retained here.
-- PlacedAt is the delivery time, NOT the victim's old time: this is
-- a new placement in the thief's base, so the 120-second protection
-- window restarts. TraitLevels survive from the snapshot (copied,
-- not aliased).
check("A: delivered owned record retains the banked remainder (250)",
	movedA.BankedIncome == 250, "BankedIncome=" .. tostring(movedA.BankedIncome))
check("A: delivered placed copy retains the banked remainder (250)",
	placedA ~= nil and placedA.BankedIncome == 250,
	"BankedIncome=" .. tostring(placedA and placedA.BankedIncome))
check("A: delivered owned record PlacedAt is the delivery time, not the victim's old time",
	movedA.PlacedAt ~= nil and movedA.PlacedAt ~= pairA.oldTime
		and movedA.PlacedAt >= deliveryStart and movedA.PlacedAt <= os.time(),
	"PlacedAt=" .. tostring(movedA.PlacedAt) .. " oldTime=" .. tostring(pairA.oldTime))
check("A: delivered placed copy PlacedAt is the delivery time",
	placedA ~= nil and placedA.PlacedAt ~= pairA.oldTime
		and placedA.PlacedAt >= deliveryStart and placedA.PlacedAt <= os.time(),
	"PlacedAt=" .. tostring(placedA and placedA.PlacedAt) .. " oldTime=" .. tostring(pairA.oldTime))
check("A: delivered instance keeps trait levels from the snapshot",
	type(movedA.TraitLevels) == "table" and movedA.TraitLevels.Food == 2)

-- ---------------------------------------------------------------------------
-- Pair B: owned record missing at place time -> NO mint, NO confirm.
-- (Proves the old GUID-mint fallback is gone and the failed place did
-- not consume the transit: restoring the record lets ConfirmDelivery
-- succeed afterwards.)
-- ---------------------------------------------------------------------------
local pairB, plotB = stealPair(312, 412)
local coinsBeforeB = pairB.thiefData.Coins
local movedB = H.findOwned(pairB.thiefData, pairB.targetId)
-- Simulate the moved record being consumed mid-transit.
local thiefOwnedB = pairB.thiefData.OwnedInstances
for i, inst in ipairs(thiefOwnedB) do
	if inst.InstanceId == pairB.targetId then
		table.remove(thiefOwnedB, i)
		break
	end
end
H.setRootPosition(pairB.thief, H.pedestalPosition(plotB, 1))
local okMissing, errMissing = base.PlaceBrainrot(pairB.thief, pairB.targetId, 1)
check("B: place with the owned record missing fails (no mint)",
	okMissing == false and errMissing == "brainrot not owned", "err=" .. tostring(errMissing))
check("B: no minted copy appeared", H.countOwned(env, { pairB.thief, pairB.victim }, pairB.targetId) == 0
	and H.findPlaced(pairB.thiefData, pairB.targetId) == nil)
-- Restore the record: the transit must still be live (the failed
-- place must NOT have confirmed it).
table.insert(thiefOwnedB, movedB)
local deliveryStartB = os.time()
local okConfirm = env.raid.ConfirmDelivery(pairB.thief, pairB.targetId)
check("B: transit still live after the failed place (ConfirmDelivery succeeds)",
	okConfirm == true)
check("B: reward paid exactly once by that confirmation",
	pairB.thiefData.Coins == coinsBeforeB + 300,
	"coins=" .. tostring(pairB.thiefData.Coins))
check("B: delivered owned record retains the banked remainder (250)",
	movedB.BankedIncome == 250, "BankedIncome=" .. tostring(movedB.BankedIncome))
check("B: delivered owned record PlacedAt is the delivery time",
	movedB.PlacedAt ~= nil and movedB.PlacedAt ~= pairB.oldTime
		and movedB.PlacedAt >= deliveryStartB and movedB.PlacedAt <= os.time(),
	"PlacedAt=" .. tostring(movedB.PlacedAt) .. " oldTime=" .. tostring(pairB.oldTime))
local coinsAfterB = pairB.thiefData.Coins
local okConfirm2 = env.raid.ConfirmDelivery(pairB.thief, pairB.targetId)
check("B: second ConfirmDelivery fails (no transit left)", okConfirm2 == false)
check("B: second ConfirmDelivery pays no second reward",
	pairB.thiefData.Coins == coinsAfterB,
	"coins=" .. tostring(pairB.thiefData.Coins))
check("B: second ConfirmDelivery writes nothing (banked remainder stays 250)",
	movedB.BankedIncome == 250, "BankedIncome=" .. tostring(movedB.BankedIncome))

-- ---------------------------------------------------------------------------
-- Pair C: normal-path place of an in-transit instance is rejected.
-- (Flag set after PickupOwned — the mid-carry race the guard exists
-- for. PickupOwned itself would also reject a pre-flagged record.)
-- ---------------------------------------------------------------------------
local pairC = H.newPair(env, 313, 413)
local plotC = base.AssignBase(pairC.thief)
local ownedC = H.findOwned(pairC.thiefData, pairC.prefix .. "evo_1")
local okCarryC = env.carry.PickupOwned(pairC.thief, ownedC)
check("C: normal carry starts", okCarryC == true)
ownedC.InTransit = true
H.setRootPosition(pairC.thief, H.pedestalPosition(plotC, 1))
local okPlaceC, errPlaceC = base.PlaceBrainrot(pairC.thief, ownedC.InstanceId, 1)
check("C: normal place of an in-transit instance is rejected",
	okPlaceC == false and errPlaceC == "brainrot in transit", "err=" .. tostring(errPlaceC))
check("C: instance not placed by the rejected attempt",
	H.findPlaced(pairC.thiefData, ownedC.InstanceId) == nil)
ownedC.InTransit = nil
local okPlaceC2 = base.PlaceBrainrot(pairC.thief, ownedC.InstanceId, 1)
check("C: place succeeds once the flag clears", okPlaceC2 == true)

-- ---------------------------------------------------------------------------
-- Pair D: normal-path place of an on-expedition instance is rejected.
-- ---------------------------------------------------------------------------
local pairD = H.newPair(env, 314, 414)
local plotD = base.AssignBase(pairD.thief)
local ownedD = H.findOwned(pairD.thiefData, pairD.prefix .. "carry_1")
local okCarryD = env.carry.PickupOwned(pairD.thief, ownedD)
check("D: normal carry starts", okCarryD == true)
ownedD.OnExpedition = true
H.setRootPosition(pairD.thief, H.pedestalPosition(plotD, 1))
local okPlaceD, errPlaceD = base.PlaceBrainrot(pairD.thief, ownedD.InstanceId, 1)
check("D: normal place of an on-expedition instance is rejected",
	okPlaceD == false and errPlaceD == "brainrot on expedition", "err=" .. tostring(errPlaceD))
check("D: instance not placed by the rejected attempt",
	H.findPlaced(pairD.thiefData, ownedD.InstanceId) == nil)
ownedD.OnExpedition = nil
local okPlaceD2 = base.PlaceBrainrot(pairD.thief, ownedD.InstanceId, 1)
check("D: place succeeds once the flag clears", okPlaceD2 == true)

H.finish()
