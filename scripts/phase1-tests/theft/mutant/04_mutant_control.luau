-- 04_mutant_control.luau — R2 M5 negative control: the SAME
-- thief-identity assertions as the M5 rule in ConfirmDelivery, run
-- against the MUTANT RaidService (thief identity check removed by
-- mutant/make_mutant.sh). This file is EXPECTED TO FAIL: the mutant
-- must let a non-thief past the identity guard, which proves the test
-- detects the missing check.
--
-- Two scenarios. A (clean state): the victim and a bystander with no
-- data at all call ConfirmDelivery on a live transit entry. The fixed
-- code rejects both with "not carrying that Brainrot"; the mutant
-- falls through to the owned-record lookup and reports "instance
-- record missing" instead — the only observable difference in a
-- clean state, because the owned-record lookup is a second line of
-- defence (the impostor owns no record with that InstanceId).
-- B (planted duplicate): a bystander is given a planted owned record
-- carrying the same InstanceId, modelling a corrupted/duplicate
-- ledger. The fixed code still rejects the bystander outright; the
-- mutant COMPLETES the delivery for them — pays them the 300-coin
-- reward, writes the snapshot onto their record, and clears the
-- transit entry, stranding the real thief's record in transit.
-- Never run under theft/run_all.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")

local env = H.newEnv({ raidPath = "./theft/mutant/RaidServiceM5" })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- ---------------------------------------------------------------------------
-- Scenario A: non-thieves are rejected with the identity reason, and the
-- theft stays live for the real thief afterwards.
-- ---------------------------------------------------------------------------
local pairA = H.newPair(env, 971, 972)
H.steal(env, pairA)
local bystander = H.newPlayer(979, "Bystander979", 30, Vector3.new(0, 0, 0))

local okV, statusV = env.raid.ConfirmDelivery(pairA.victim, pairA.targetId)
check("A: victim cannot confirm the delivery",
	okV == false and statusV == "not carrying that Brainrot",
	"ok=" .. tostring(okV) .. " status=" .. tostring(statusV))
local okB, statusB = env.raid.ConfirmDelivery(bystander, pairA.targetId)
check("A: bystander cannot confirm the delivery",
	okB == false and statusB == "not carrying that Brainrot",
	"ok=" .. tostring(okB) .. " status=" .. tostring(statusB))
check("A: no reward paid to anyone by the rejected attempts",
	pairA.thiefData.Coins == 100000 and pairA.victimData.Coins == 10000,
	"thiefCoins=" .. tostring(pairA.thiefData.Coins))
local okDelA, statusA = env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
check("A: real thief can still deliver afterwards (transit stayed live)",
	okDelA == true, "status=" .. tostring(statusA))

-- ---------------------------------------------------------------------------
-- Scenario B: planted duplicate owned record — the identity guard is the
-- ONLY thing stopping a non-thief from completing the delivery.
-- ---------------------------------------------------------------------------
local pairB = H.newPair(env, 973, 974)
H.steal(env, pairB)
local impostor = H.newPlayer(980, "Impostor980", 30, Vector3.new(0, 0, 0))
local impostorData = {
	Level = 5,
	Coins = 50000,
	Gems = 0,
	MutationCrystals = 0,
	Rebirths = 0,
	Unlocked = { "wobble_waffleton" },
	OwnedInstances = {
		{
			InstanceId = pairB.targetId,
			CharacterId = "wobble_waffleton",
			Level = 1,
			Mutation = nil,
			Placed = false,
			Slot = 0,
		},
	},
	Base = { Placed = {} },
	LabDiscoveries = {},
}
env.dataService.Ensure(impostor, impostorData)
local planted = H.findOwned(impostorData, pairB.targetId)
local okI, statusI = env.raid.ConfirmDelivery(impostor, pairB.targetId)
check("B: impostor with a duplicate record still cannot confirm",
	okI == false and statusI == "not carrying that Brainrot",
	"ok=" .. tostring(okI) .. " status=" .. tostring(statusI))
check("B: impostor paid nothing",
	impostorData.Coins == 50000, "coins=" .. tostring(impostorData.Coins))
check("B: impostor's planted record untouched (level still 1, no banked)",
	planted ~= nil and planted.Level == 1 and planted.BankedIncome == nil,
	"Level=" .. tostring(planted and planted.Level))
local okDelB, statusB2 = env.raid.ConfirmDelivery(pairB.thief, pairB.targetId)
check("B: real thief can still deliver afterwards (transit stayed live)",
	okDelB == true, "status=" .. tostring(statusB2))

H.finish()
