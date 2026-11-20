-- 06a_return_preserves_fields_base.luau — P1-14 via the PREFERRED path:
-- return routes through BaseService.PlaceBrainrot (whole-record shape),
-- which builds a fixed-field placed table; RaidService tops up the
-- evolution / trait fields it drops. The returned placed copy must keep
-- mutation, level, glitched state, banked income, original PlacedAt,
-- slot, and ALL evolution / trait fields. Second pair: the original
-- slot is occupied mid-theft, so the restore must fall back to a free
-- slot instead of stacking two copies on one slot.
-- Run: lune run scripts/phase1-tests/theft/06a_return_preserves_fields_base.luau
local H = require("../harness")

local env = H.newEnv()

local function assertFields(n, pair, label, expectedSlot)
	local placed = H.findPlaced(pair.victimData, pair.targetId)
	local ok = placed ~= nil
		and placed.CharacterId == "wobble_waffleton"
		and placed.Slot == expectedSlot
		and placed.Level == 5
		and placed.Glitched == true
		and placed.Mutation == "golden"
		and placed.BankedIncome == 500
		and placed.PlacedAt == pair.oldTime
		and placed.Evolved == true
		and placed.EvolutionId == "evolved_wobble_waffleton"
		and placed.EvolvedTrait == "Electric"
		and placed.EvolvedFormName == "Wobble Waffleton (Evolved)"
		and type(placed.TraitLevels) == "table"
		and placed.TraitLevels.Food == 2
	H.check(n, label .. ": placed copy keeps every field", ok,
		placed == nil and "no placed copy" or ("slot=" .. tostring(placed.Slot)
			.. " banked=" .. tostring(placed.BankedIncome)
			.. " placedAt=" .. tostring(placed.PlacedAt)
			.. " evolved=" .. tostring(placed.Evolved)
			.. " trait=" .. tostring(placed.EvolvedTrait)))
	local owned = H.findOwned(pair.victimData, pair.targetId)
	H.check(n + 1, label .. ": owned record back in sync (Placed, Slot)",
		owned ~= nil and owned.Placed == true and owned.Slot == expectedSlot)
end

-- A: original slot free — restored to slot 2.
local pairA = H.newPair(env, 151, 251)
H.steal(env, pairA)
env.raid.ReturnStolen(pairA.targetId)
assertFields(1, pairA, "A: free slot", 2)
H.check(3, "A: exactly one placed copy, exactly one owned copy",
	H.countPlaced(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1
		and H.countOwned(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)

-- B: slot 2 occupied mid-theft by a squatter — restore falls back.
local pairB = H.newPair(env, 153, 253, {
	victimExtraPlaced = {
		{
			InstanceId = "t153v253_squatter",
			CharacterId = "turbo_turnip",
			Slot = 2,
			Level = 1,
			Glitched = false,
			Mutation = nil,
			BankedIncome = 0,
			PlacedAt = os.time() - 1000,
		},
	},
})
H.steal(env, pairB)
env.raid.ReturnStolen(pairB.targetId)
-- Slot 1 = filler, slot 2 = squatter, so the first free slot is 3.
assertFields(4, pairB, "B: occupied slot", 3)
H.check(6, "B: squatter untouched on slot 2",
	H.findPlaced(pairB.victimData, "t153v253_squatter") ~= nil
		and H.findPlaced(pairB.victimData, "t153v253_squatter").Slot == 2)
H.check(7, "B: exactly one placed copy of the target",
	H.countPlaced(env, { pairB.thief, pairB.victim }, pairB.targetId) == 1)

H.finish()
