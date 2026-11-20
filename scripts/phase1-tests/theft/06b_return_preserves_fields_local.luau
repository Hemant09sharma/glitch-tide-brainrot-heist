-- 06b_return_preserves_fields_local.luau — P1-14 via the LOCAL fallback:
-- same assertions as 06a, but the BaseService stub has NO PlaceBrainrot,
-- so RaidService's own reinsert path runs (slot-freedom check + full
-- field restore + owned-flag sync). If this file passes, the return
-- preserves everything even when BaseService is unlinked.
-- Run: lune run scripts/phase1-tests/theft/06b_return_preserves_fields_local.luau
local H = require("../harness")

local env = H.newEnv({ base = { withPlace = false } })

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
local pairA = H.newPair(env, 161, 261)
H.steal(env, pairA)
env.raid.ReturnStolen(pairA.targetId)
assertFields(1, pairA, "A: free slot", 2)
H.check(3, "A: exactly one placed copy, exactly one owned copy",
	H.countPlaced(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1
		and H.countOwned(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)

-- B: slot 2 occupied mid-theft by a squatter — restore falls back.
local pairB = H.newPair(env, 163, 263, {
	victimExtraPlaced = {
		{
			InstanceId = "t163v263_squatter",
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
assertFields(4, pairB, "B: occupied slot", 3)
H.check(6, "B: squatter untouched on slot 2",
	H.findPlaced(pairB.victimData, "t163v263_squatter") ~= nil
		and H.findPlaced(pairB.victimData, "t163v263_squatter").Slot == 2)
H.check(7, "B: exactly one placed copy of the target",
	H.countPlaced(env, { pairB.thief, pairB.victim }, pairB.targetId) == 1)

H.finish()
