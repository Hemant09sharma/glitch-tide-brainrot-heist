-- 08_return_residuals.luau — R3-6 (Worker B residuals, RaidService-owned):
-- (1) the local reinsert fallback (reinsertPlaced, used when
-- BaseService is unlinked or its reinsert fails) mirrors
-- BaseService.reinsertPlacedRecord's ownership guard — a legitimate
-- return must still pass it and restore the placed copy. (1a) is
-- tested here with BaseService unlinked (withPlace = false). The
-- guard's REFUSAL is not reachable via the public API in the return
-- path — the owned record is always back with the victim (markers
-- cleared) before reinserting — and the steal-rollback caller is
-- intentionally exempt (it restores a just-removed copy; theft test
-- 07 scenario D covers that). The refusal predicate is identical to
-- BaseService's, verified by code inspection, not by a test.
-- (2) reconcilePlacedCopy prefers owned.Mutation with placed.Mutation
-- as fallback: a delivery whose owned record has no Mutation must not
-- wipe a placed copy's Mutation to nil.
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

-- ONE env for the whole file: CarryService.Init has a _running guard,
-- so a second H.newEnv in the same process would never re-point it
-- (it would keep reading the first env's data). withPlace = false
-- (BaseService unlinked) serves both blocks: (1a) needs the local
-- fallback, and (2)'s ConfirmDelivery reconciles from the data
-- directly and never calls PlaceBrainrot.
local DS = L.new()
DS.connectLeaveHandler()
local env = H.newEnv({ dataService = DS, base = { withPlace = false } })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- ---------------------------------------------------------------------------
-- (1a) Guard pass: BaseService unlinked (no PlaceBrainrot), so the
-- return's reinsert goes through the local fallback and its guard.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1381, 1382)
	H.steal(env, pair)
	env.raid.DropStolen(pair.thief)
	local victimData = DS.GetData(pair.victim)
	local owned = H.findOwned(victimData, pair.targetId)
	check("1a: return commits with the local fallback (victim holds it clean)",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and owned ~= nil and owned.InTransit ~= true
			and owned.StolenFromUserId == nil)
	local placed = H.findPlaced(victimData, pair.targetId)
	check("1a: placed copy restored through the guarded fallback (guard passes a legitimate return)",
		placed ~= nil and placed.Slot == 2 and placed.Level == 5
			and placed.Mutation == "golden" and placed.Glitched == true
			and placed.BankedIncome == 500 and placed.PlacedAt == pair.oldTime)
	check("1a: thief holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- ---------------------------------------------------------------------------
-- (2) Mutation fallback: owned Mutation is nil, placed Mutation is
-- "golden" — the delivery reconcile must keep "golden", not wipe it.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1383, 1384)
	-- Strip the Mutation from both the owned record and the placed
	-- copy before the steal, so the steal snapshot carries nil.
	local victimData = DS.GetData(pair.victim)
	local ownedBefore = H.findOwned(victimData, pair.targetId)
	ownedBefore.Mutation = nil
	local placedBefore = H.findPlaced(victimData, pair.targetId)
	placedBefore.Mutation = nil
	H.steal(env, pair)
	check("2: setup — stolen record's Mutation is nil in transit",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.thief), pair.targetId).Mutation == nil)
	-- The thief "places" the stolen Brainrot in their own base with a
	-- Mutation of golden (e.g. a mutation applied after the steal).
	local thiefData = DS.GetData(pair.thief)
	table.insert(thiefData.Base.Placed, {
		InstanceId = pair.targetId,
		CharacterId = "wobble_waffleton",
		Slot = 1,
		Level = 5,
		Mutation = "golden",
		Glitched = true,
		BankedIncome = 0,
		PlacedAt = os.time(),
	})
	-- The watchdog sees the placed copy and confirms the delivery.
	env.raid.PollInTransit()
	local owned = H.findOwned(DS.GetData(pair.thief), pair.targetId)
	local placed = H.findPlaced(DS.GetData(pair.thief), pair.targetId)
	check("2: delivery committed (thief owns it, placed in their base)",
		owned ~= nil and owned.InTransit ~= true and placed ~= nil)
	check("2: placed Mutation stays golden (owned-wins-with-placed-fallback)",
		placed ~= nil and placed.Mutation == "golden",
		"mutation=" .. tostring(placed and placed.Mutation))
	check("2: owned Mutation stays nil (the fallback does not invent one)",
		owned ~= nil and owned.Mutation == nil,
		"mutation=" .. tostring(owned and owned.Mutation))
end

H.finish()
