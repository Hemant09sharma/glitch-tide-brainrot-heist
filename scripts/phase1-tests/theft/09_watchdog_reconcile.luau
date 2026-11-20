-- 09_watchdog_reconcile.luau — R2-3 (N6/R8): after a watchdog delivery
-- (PollInTransit sees the stolen instance already placed in the thief's
-- base), ConfirmDelivery must reconcile the pre-existing placed copy
-- FROM the updated owned record, sync owned.Placed / Slot, and clear
-- the thief's carry state — without inserting a duplicate placed copy
-- or paying the reward twice. A second watchdog run must be a no-op.
-- The normal PlaceBrainrot path (no placed copy exists yet at
-- ConfirmDelivery time) must be unaffected.
-- Loads the REAL BaseService (see H.newBaseEnv) with the real
-- RaidService / CarryService from harness.newEnv().
-- Run: lune run scripts/phase1-tests/theft/09_watchdog_reconcile.luau
local H = require("../harness")

local env = H.newEnv()
local base = H.newBaseEnv(env)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- ---------------------------------------------------------------------------
-- Pair A: watchdog reconcile. Steal, then the thief's base already holds
-- a placed copy built from STALE pre-delivery fields (as the old
-- watchdog path left it): level 1, no mutation, not glitched, no banked
-- income, no evolution fields, the victim's old PlacedAt.
-- StealReward for the fixture = half banked (500*0.5=250) +
-- IncomePerSec*10 (wobble 5*10=50) = 300 coins (see theft test 04).
-- ---------------------------------------------------------------------------
local pairA = H.newPair(env, 901, 902)
local plotAt = base.AssignBase(pairA.thief)
local plotAv = base.AssignBase(pairA.victim)
assert(plotAt ~= nil and plotAv ~= nil, "pair A plots not assigned")
H.steal(env, pairA)
table.insert(pairA.thiefData.Base.Placed, {
	InstanceId = pairA.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 1,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = pairA.oldTime,
})
check("A: thief is carrying the stolen instance before the watchdog runs",
	env.carry.GetCarried(pairA.thief) ~= nil
		and env.carry.GetCarried(pairA.thief).InstanceId == pairA.targetId)
local coinsBeforeA = pairA.thiefData.Coins
local deliveryStart = os.time()
env.raid.PollInTransit()
check("A: watchdog delivery pays the steal reward once (300 coins)",
	pairA.thiefData.Coins == coinsBeforeA + 300,
	"coins=" .. tostring(pairA.thiefData.Coins))
local placedA = H.findPlaced(pairA.thiefData, pairA.targetId)
check("A: placed copy still exists exactly once (no duplicate inserted)",
	H.countPlaced(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1
		and placedA ~= nil)
check("A: placed copy reconciled from the owned record (level/mutation/glitched)",
	placedA ~= nil and placedA.Level == 5 and placedA.Mutation == "golden"
		and placedA.Glitched == true,
	"Level=" .. tostring(placedA and placedA.Level)
		.. " Mutation=" .. tostring(placedA and placedA.Mutation))
check("A: placed copy reconciled (evolution / trait fields)",
	placedA ~= nil and placedA.Evolved == true
		and placedA.EvolutionId == "evolved_wobble_waffleton"
		and placedA.EvolvedTrait == "Electric"
		and placedA.EvolvedFormName == "Wobble Waffleton (Evolved)"
		and type(placedA.TraitLevels) == "table" and placedA.TraitLevels.Food == 2)
check("A: placed copy reconciled (banked remainder 250, delivery PlacedAt)",
	placedA ~= nil and placedA.BankedIncome == 250
		and placedA.PlacedAt ~= nil and placedA.PlacedAt ~= pairA.oldTime
		and placedA.PlacedAt >= deliveryStart and placedA.PlacedAt <= os.time(),
	"BankedIncome=" .. tostring(placedA and placedA.BankedIncome)
		.. " PlacedAt=" .. tostring(placedA and placedA.PlacedAt))
local ownedA = H.findOwned(pairA.thiefData, pairA.targetId)
check("A: owned.Placed / Slot synced to the existing placed copy",
	ownedA ~= nil and ownedA.Placed == true and ownedA.Slot == 1,
	"Placed=" .. tostring(ownedA and ownedA.Placed) .. " Slot=" .. tostring(ownedA and ownedA.Slot))
check("A: owned record itself keeps the delivered fields",
	ownedA ~= nil and ownedA.Level == 5 and ownedA.Mutation == "golden"
		and ownedA.Glitched == true and ownedA.BankedIncome == 250
		and ownedA.InTransit ~= true)
check("A: thief's carry state cleared by the reconcile",
	env.carry.GetCarried(pairA.thief) == nil
		and pairA.thief.Character:GetAttribute("CarryingStolen") == "")
-- Second watchdog run: transit is gone, so nothing may change.
env.raid.PollInTransit()
check("A: second watchdog run pays no second reward",
	pairA.thiefData.Coins == coinsBeforeA + 300,
	"coins=" .. tostring(pairA.thiefData.Coins))
check("A: second watchdog run inserts no duplicate placed copy",
	H.countPlaced(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)
local placedA2 = H.findPlaced(pairA.thiefData, pairA.targetId)
check("A: second watchdog run leaves the reconciled fields untouched",
	placedA2 ~= nil and placedA2.Level == 5 and placedA2.Mutation == "golden"
		and placedA2.BankedIncome == 250)
-- Store the reconciled Brainrot: values must survive intact.
local okStoreA, storeErrA = base.StoreBrainrot(pairA.thief, pairA.targetId)
check("A: reconciled Brainrot can be stored", okStoreA == true, "err=" .. tostring(storeErrA))
check("A: stored owned record keeps the reconciled values",
	ownedA ~= nil and ownedA.Level == 5 and ownedA.Mutation == "golden"
		and ownedA.Glitched == true and ownedA.BankedIncome == 250
		and ownedA.Evolved == true and ownedA.EvolutionId == "evolved_wobble_waffleton",
	"BankedIncome=" .. tostring(ownedA and ownedA.BankedIncome))
check("A: no placed copy remains after storing",
	H.findPlaced(pairA.thiefData, pairA.targetId) == nil)

-- ---------------------------------------------------------------------------
-- Pair B: normal-path delivery through the REAL BaseService.PlaceBrainrot.
-- No placed copy exists at ConfirmDelivery time, so the reconcile must
-- be a no-op: exactly one placed copy, built afterwards from the owned
-- record, reward paid once, carry cleared by the place itself.
-- ---------------------------------------------------------------------------
local pairB = H.newPair(env, 903, 904)
local plotBt = base.AssignBase(pairB.thief)
local plotBv = base.AssignBase(pairB.victim)
assert(plotBt ~= nil and plotBv ~= nil, "pair B plots not assigned")
H.steal(env, pairB)
local coinsBeforeB = pairB.thiefData.Coins
H.setRootPosition(pairB.thief, H.pedestalPosition(plotBt, 1))
local deliveryStartB = os.time()
local okPlaceB, placedB = base.PlaceBrainrot(pairB.thief, pairB.targetId, 1)
check("B: normal-path delivery succeeds", okPlaceB == true, "err=" .. tostring(placedB))
check("B: reward paid exactly once (300 coins)",
	pairB.thiefData.Coins == coinsBeforeB + 300,
	"coins=" .. tostring(pairB.thiefData.Coins))
check("B: exactly one placed copy in the thief base",
	H.countPlaced(env, { pairB.thief, pairB.victim }, pairB.targetId) == 1
		and H.findPlaced(pairB.thiefData, pairB.targetId) ~= nil)
check("B: placed copy built from the delivered owned record",
	placedB ~= nil and placedB.InstanceId == pairB.targetId
		and placedB.Level == 5 and placedB.Mutation == "golden"
		and placedB.Glitched == true and placedB.BankedIncome == 250
		and placedB.PlacedAt ~= nil and placedB.PlacedAt ~= pairB.oldTime
		and placedB.PlacedAt >= deliveryStartB and placedB.PlacedAt <= os.time(),
	"BankedIncome=" .. tostring(placedB and placedB.BankedIncome))
local ownedB = H.findOwned(pairB.thiefData, pairB.targetId)
check("B: owned.Placed / Slot synced by the place",
	ownedB ~= nil and ownedB.Placed == true and ownedB.Slot == 1)
check("B: carry cleared after the place",
	env.carry.GetCarried(pairB.thief) == nil
		and pairB.thief.Character:GetAttribute("CarryingStolen") == "")

H.finish()
