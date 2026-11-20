-- 01_fuse_in_transit.luau — Duplication vector 1 (fuse-then-return).
--
-- Steal -> attempt fusion of the in-transit instance -> must be rejected
-- with no instance consumed and no output created. Positive control first:
-- the same fusion on unplaced, non-transit instances succeeds.
-- Run: lune run scripts/phase1-tests/theft/01_fuse_in_transit.luau
local H = require("../harness")

local env = H.newEnv()

-- Positive control: normal fusion still works.
local pair1 = H.newPair(env, 101, 201)
local coinsBefore = pair1.thiefData.Coins
local crystalsBefore = pair1.thiefData.MutationCrystals
local ok, output, outcome = env.fusion.FuseBrainrot(
	pair1.thief, pair1.prefix .. "fuse_a", pair1.prefix .. "fuse_b"
)
H.check(1, "control: unplaced wobble+turbo fuse succeeds", ok == true and output ~= nil
	and output.CharacterId == "bloop_bloomington" and outcome == "Recipe",
	"ok=" .. tostring(ok) .. " out=" .. tostring(output and output.CharacterId))
H.check(2, "control: fusion consumes both inputs", H.countOwned(env, { pair1.thief }, pair1.prefix .. "fuse_a") == 0
	and H.countOwned(env, { pair1.thief }, pair1.prefix .. "fuse_b") == 0)
H.check(3, "control: fusion charges 1000 coins + 25 crystals",
	pair1.thiefData.Coins == coinsBefore - 1000
		and pair1.thiefData.MutationCrystals == crystalsBefore - 25)

-- Theft: steal pair2's target, then try to fuse it.
local pair2 = H.newPair(env, 103, 204)
H.steal(env, pair2)
local thiefOwnedBefore = #pair2.thiefData.OwnedInstances
local stolen = H.findOwned(pair2.thiefData, pair2.targetId)
H.check(4, "setup: stolen record carries InTransit=true", stolen ~= nil and stolen.InTransit == true)

local okFuse, reason = env.fusion.FuseBrainrot(pair2.thief, pair2.targetId, pair2.prefix .. "fuse_b")
H.check(5, "in-transit instance cannot be fused", okFuse == false
	and type(reason) == "string" and string.find(reason, "transit") ~= nil,
	"reason=" .. tostring(reason))
local okFuse2, reason2 = env.fusion.FuseBrainrot(pair2.thief, pair2.prefix .. "fuse_b", pair2.targetId)
H.check(6, "in-transit instance cannot be fused (swapped order)", okFuse2 == false
	and type(reason2) == "string" and string.find(reason2, "transit") ~= nil,
	"reason=" .. tostring(reason2))
H.check(7, "rejected fusion consumes nothing", H.countOwned(env, { pair2.thief }, pair2.targetId) == 1
	and H.countOwned(env, { pair2.thief }, pair2.prefix .. "fuse_b") == 1
	and #pair2.thiefData.OwnedInstances == thiefOwnedBefore)
H.check(8, "rejected fusion creates no output and charges nothing",
	#pair2.thiefData.OwnedInstances == thiefOwnedBefore
		and pair2.thiefData.Coins == 100000
		and pair2.thiefData.MutationCrystals == 1000)
local stillThere = H.findOwned(pair2.thiefData, pair2.targetId)
H.check(9, "stolen record still in transit after rejected fusion",
	stillThere ~= nil and stillThere.InTransit == true)

H.finish()
