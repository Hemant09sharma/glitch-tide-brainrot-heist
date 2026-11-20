-- 04_delivery_exactly_once.luau — steal -> delivery transfers exactly
-- one instance to the thief and zero remain with the victim.
-- Two delivery triggers: direct ConfirmDelivery (what BaseService's
-- stolen-place path calls) and the watchdog detecting the instance
-- placed in the thief's base. After delivery the InTransit flag is
-- cleared, proven by a mutation succeeding on the delivered instance.
-- Run: lune run scripts/phase1-tests/theft/04_delivery_exactly_once.luau
local H = require("../harness")

local env = H.newEnv()

local function assertDelivered(n, pair, label)
	local thiefData = pair.thiefData
	local victimData = pair.victimData
	H.check(n, label .. ": exactly one owned copy, with the thief",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findOwned(thiefData, pair.targetId) ~= nil
			and H.findOwned(victimData, pair.targetId) == nil)
	H.check(n + 1, label .. ": zero placed copies remain with the victim",
		H.findPlaced(victimData, pair.targetId) == nil)
	local owned = H.findOwned(thiefData, pair.targetId)
	H.check(n + 2, label .. ": InTransit flag cleared on delivery",
		owned ~= nil and owned.InTransit ~= true)
end

-- A: direct ConfirmDelivery. StealReward = half banked (500*0.5=250) +
-- IncomePerSec*10 (wobble 5*10=50) = 300 coins.
-- R1: the delivered owned record keeps the banked remainder (250)
-- and PlacedAt becomes the delivery time (new placement: the 120 s
-- protection window restarts).
local pairA = H.newPair(env, 131, 231)
H.steal(env, pairA)
local coinsBefore = pairA.thiefData.Coins
local deliverStart = os.time()
local okDel, delErr = env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
H.check(1, "A: ConfirmDelivery succeeds", okDel == true, "err=" .. tostring(delErr))
H.check(2, "A: steal reward paid (300 coins)", pairA.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pairA.thiefData.Coins))
assertDelivered(3, pairA, "A: direct delivery")
local ownedA = H.findOwned(pairA.thiefData, pairA.targetId)
H.check(6, "A: delivered owned record retains the banked remainder (250)",
	ownedA ~= nil and ownedA.BankedIncome == 250,
	"BankedIncome=" .. tostring(ownedA and ownedA.BankedIncome))
H.check(7, "A: delivered owned record PlacedAt is the delivery time, not the victim's old time",
	ownedA ~= nil and ownedA.PlacedAt ~= nil and ownedA.PlacedAt ~= pairA.oldTime
		and ownedA.PlacedAt >= deliverStart and ownedA.PlacedAt <= os.time(),
	"PlacedAt=" .. tostring(ownedA and ownedA.PlacedAt) .. " oldTime=" .. tostring(pairA.oldTime))
H.check(8, "A: delivered owned record keeps snapshot fields (level/mutation/glitched/evolution/traits)",
	ownedA ~= nil and ownedA.Level == 5 and ownedA.Mutation == "golden"
		and ownedA.Glitched == true and ownedA.Evolved == true
		and ownedA.EvolutionId == "evolved_wobble_waffleton"
		and type(ownedA.TraitLevels) == "table" and ownedA.TraitLevels.Food == 2)
local okDel2 = env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
H.check(9, "A: second ConfirmDelivery fails (no transit left)", okDel2 == false)
H.check(10, "A: second ConfirmDelivery pays no second reward",
	pairA.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pairA.thiefData.Coins))
H.check(11, "A: second ConfirmDelivery writes nothing (banked remainder stays 250)",
	ownedA ~= nil and ownedA.BankedIncome == 250,
	"BankedIncome=" .. tostring(ownedA and ownedA.BankedIncome))
local okMut = env.mutation.MutateBrainrot(pairA.thief, pairA.targetId, "electric")
H.check(12, "A: delivered instance can be mutated (flag really cleared)",
	okMut == true, "ok=" .. tostring(okMut))

-- B: watchdog delivery detection — the instance is placed in the
-- thief's base while transit is live; PollInTransit confirms it.
local pairB = H.newPair(env, 133, 233)
H.steal(env, pairB)
table.insert(pairB.thiefData.Base.Placed, {
	InstanceId = pairB.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 1,
	Level = 5,
	Glitched = true,
	Mutation = "golden",
	BankedIncome = 0,
	PlacedAt = os.time(),
})
local coinsBeforeB = pairB.thiefData.Coins
env.raid.PollInTransit()
H.check(13, "B: watchdog delivery pays the steal reward",
	pairB.thiefData.Coins == coinsBeforeB + 300,
	"coins=" .. tostring(pairB.thiefData.Coins))
assertDelivered(14, pairB, "B: watchdog delivery")
local ownedB = H.findOwned(pairB.thiefData, pairB.targetId)
H.check(17, "B: watchdog delivery also retains the banked remainder (250)",
	ownedB ~= nil and ownedB.BankedIncome == 250,
	"BankedIncome=" .. tostring(ownedB and ownedB.BankedIncome))

H.finish()
