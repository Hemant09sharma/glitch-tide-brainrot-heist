-- 08_companion_and_mirror.luau — two smaller fixes in the same files.
-- (a) CarryService companion CarrySpeed: with a companion service wired,
-- carrying applies its multiplier (16 * 0.75 = 12); without one, the
-- Config base applies (16 * 0.6 = 9.6). Before the fix the file-scope
-- local was declared after applyCarrySpeed, so the setter fed a local
-- nothing read and the bonus never applied.
-- (b) MutationService.GetInstances mirror: placed state mirrors onto
-- owned records by InstanceId (not CharacterId), and a glitched placed
-- Brainrot sets the Glitched flag instead of clobbering Mutation with
-- "glitched".
-- Run: lune run scripts/phase1-tests/theft/08_companion_and_mirror.luau
local H = require("../harness")

local env = H.newEnv()
local pair = H.newPair(env, 181, 281)
local thief = pair.thief

-- (a) No companion wired yet: Config base 0.6.
local carryRec = H.findOwned(pair.thiefData, pair.prefix .. "carry_1")
local okPick, _id = env.carry.PickupOwned(thief, carryRec)
H.check(1, "companion: pickup succeeds with no companion wired", okPick == true, "ok=" .. tostring(okPick))
H.check(2, "companion: no companion -> base carry speed 16 * 0.6 = 9.6",
	math.abs(thief._Humanoid.WalkSpeed - 9.6) < 1e-9,
	"walkSpeed=" .. tostring(thief._Humanoid.WalkSpeed))
env.carry.ClearCarried(thief, true)

-- Wire a companion service returning the 0.75 cap, pick up again.
env.carry.SetCompanionService({
	GetCarrySpeedMultiplier = function(_player)
		return 0.75
	end,
})
local okPick2, _id2 = env.carry.PickupOwned(thief, carryRec)
H.check(3, "companion: pickup succeeds with companion wired", okPick2 == true, "ok=" .. tostring(okPick2))
H.check(4, "companion: wired bonus applies 16 * 0.75 = 12",
	math.abs(thief._Humanoid.WalkSpeed - 12) < 1e-9,
	"walkSpeed=" .. tostring(thief._Humanoid.WalkSpeed))
env.carry.ClearCarried(thief, true)

-- (b) Mirror: a legacy player whose OwnedInstances was never seeded.
-- Unlocked order seeds wobble as index 1, turbo as index 2.
local legacy = H.newPlayer(183, "Legacy183", 30, Vector3.new(0, 0, 0))
local legacyData = {
	Level = 5,
	Coins = 0,
	Gems = 0,
	MutationCrystals = 0,
	Rebirths = 0,
	Unlocked = { "wobble_waffleton", "turbo_turnip" },
	Base = {
		Placed = {
			{
				InstanceId = "inst_183_turbo_turnip_2",
				CharacterId = "turbo_turnip",
				Slot = 1,
				Level = 3,
				Glitched = true,
				Mutation = nil,
				BankedIncome = 0,
				PlacedAt = os.time() - 1000,
			},
			{
				-- Bogus InstanceId for wobble's character: the old
				-- CharacterId-first-match mirror would flag wobble
				-- placed; the InstanceId mirror must not.
				InstanceId = "bogus_no_match",
				CharacterId = "wobble_waffleton",
				Slot = 2,
				Level = 1,
				Glitched = false,
				Mutation = nil,
				BankedIncome = 0,
				PlacedAt = os.time() - 1000,
			},
		},
	},
	LabDiscoveries = {},
}
env.dataService.Ensure(legacy, legacyData)
local instances = env.mutation.GetInstances(legacy)
local turbo = H.findOwned(legacyData, "inst_183_turbo_turnip_2")
local wobble = H.findOwned(legacyData, "inst_183_wobble_waffleton_1")
H.check(5, "mirror: two instances seeded from Unlocked", #instances == 2 and turbo ~= nil and wobble ~= nil)
H.check(6, "mirror: placed turbo matched by InstanceId (Placed, Slot, Level)",
	turbo ~= nil and turbo.Placed == true and turbo.Slot == 1 and turbo.Level == 3)
H.check(7, "mirror: glitched placed sets Glitched=true, Mutation NOT clobbered to 'glitched'",
	turbo ~= nil and turbo.Glitched == true and turbo.Mutation ~= "glitched",
	"glitched=" .. tostring(turbo and turbo.Glitched) .. " mutation=" .. tostring(turbo and turbo.Mutation))
H.check(8, "mirror: bogus InstanceId does NOT flag wobble placed (no CharacterId match)",
	wobble ~= nil and wobble.Placed ~= true, "placed=" .. tostring(wobble and wobble.Placed))

H.finish()
