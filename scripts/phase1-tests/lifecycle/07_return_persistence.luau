-- 07_return_persistence.luau — R3-6: the return transaction at the
-- lifecycle level (fake DataService + real RaidService). A: the online
-- return survives a crash immediately after commit (the hole state is
-- the steal-time victim save only — the thief's hold save never
-- landed). B: both saves fail — the escrow park alone recovers the
-- Brainrot on rejoin, and the victim's next save deletes the escrow.
-- C: the watchdog retry — a direct ReturnStolen call fails while the
-- store is down, then succeeds once it recovers (and reports false /
-- true accordingly). D: recovery is idempotent across repeated
-- crash -> rejoin cycles.
-- NOTE: the lifecycle fake's merge dedupes by InstanceId and has no
-- ReturnedTxns marker logic (that is covered by persistence tests
-- 13-16 against the real DataService), and unlike the real
-- mergeSidecars it only flags the escrow for deletion when an entry
-- is actually applied — so case A does not assert escrow deletion
-- after a dedupe-merge (case B does, after an applied merge).
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

local DS = L.new()
DS.connectLeaveHandler()
local env = H.newEnv({ dataService = DS })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function checkReturned(prefix, pair)
	local victimData = DS.GetData(pair.victim)
	local owned = H.findOwned(victimData, pair.targetId)
	check(prefix .. ": exactly one owner, victim holds it clean",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and owned ~= nil and owned.InTransit ~= true
			and owned.StolenFromUserId == nil)
	check(prefix .. ": returned record keeps level / mutation / glitch / evolution",
		owned ~= nil and owned.Level == 5 and owned.Mutation == "golden"
			and owned.Glitched == true and owned.Evolved == true
			and owned.EvolutionId == "evolved_wobble_waffleton"
			and owned.EvolvedTrait == "Electric"
			and type(owned.TraitLevels) == "table" and owned.TraitLevels.Food == 2)
	local placed = H.findPlaced(victimData, pair.targetId)
	check(prefix .. ": placed copy restored on the original slot, full fields",
		placed ~= nil and placed.Slot == 2 and placed.BankedIncome == 500
			and placed.PlacedAt == pair.oldTime and placed.Mutation == "golden")
	check(prefix .. ": thief holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- Steal, then persist only the victim's removal (the R3-6 hole state).
local function holeSetup(thiefId, victimId)
	local pair = H.newPair(env, thiefId, victimId)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
	return pair
end

-- ---------------------------------------------------------------------------
-- A: online return -> crash -> rejoin (thief first, then victim).
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(1371, 1372)
	env.raid.DropStolen(pair.thief)
	check("A: saved victim snapshot holds the returned copy",
		DS._saved[pair.victim] ~= nil
			and H.findOwned(DS._saved[pair.victim], pair.targetId) ~= nil)
	check("A: saved thief snapshot holds no copy",
		DS._saved[pair.thief] ~= nil
			and H.findOwned(DS._saved[pair.thief], pair.targetId) == nil)
	local escrow = DS._escrow[pair.victim.UserId]
	check("A: return parked in the victim's escrow sidecar (fallback park)",
		type(escrow) == "table" and #escrow == 1
			and escrow[1].InstanceId == pair.targetId
			and type(escrow[1].ReturnTxId) == "string"
			and string.sub(escrow[1].ReturnTxId, 1, 3) == "rt-")
	DS.simulateCrash()
	DS.simulateLoad(pair.thief)
	DS.simulateLoad(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	check("A: rejoin recovery is a no-op (nothing stale to resolve)",
		rT == 0 and remT == 0 and rV == 0 and remV == 0,
		"thief=" .. tostring(rT) .. "/" .. tostring(remT)
			.. " victim=" .. tostring(rV) .. "/" .. tostring(remV))
	checkReturned("A", pair)
end

-- ---------------------------------------------------------------------------
-- B: both saves fail — the escrow park recovers it on rejoin.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(1373, 1374)
	DS.setSaveable(false)
	env.raid.DropStolen(pair.thief)
	check("B: victim's saved snapshot lacks the return (save failed)",
		DS._saved[pair.victim] ~= nil
			and H.findOwned(DS._saved[pair.victim], pair.targetId) == nil)
	check("B: escrow park still landed while saves were failing",
		type(DS._escrow[pair.victim.UserId]) == "table"
			and #DS._escrow[pair.victim.UserId] == 1)
	DS.simulateCrash()
	DS.simulateLoad(pair.thief)
	DS.simulateLoad(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("B: rejoins are no-ops (the load-time escrow merge did the recovery)",
		rV == 0 and remV == 0 and rT == 0 and remT == 0)
	checkReturned("B", pair)
	DS.setSaveable(true)
	local okSave = DS.SaveData(pair.victim)
	check("B: victim's post-recovery save succeeds once the store recovers",
		okSave == true)
	check("B: escrow is deleted by that save (the merge applied the entry)",
		DS._escrow[pair.victim.UserId] == nil)
end

-- ---------------------------------------------------------------------------
-- C: watchdog retry — ReturnStolen reports false while the store is
-- down, then true once it recovers (and the transit entry clears).
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(1375, 1376)
	DS.setSaveable(false)
	env.raid.DropStolen(pair.thief)
	local retriedOnce = env.raid.ReturnStolen(pair.targetId)
	check("C: retry fails while the store is down (durability not covered)",
		retriedOnce == false, "ok=" .. tostring(retriedOnce))
	check("C: victim's saved snapshot still lacks the return",
		DS._saved[pair.victim] ~= nil
			and H.findOwned(DS._saved[pair.victim], pair.targetId) == nil)
	DS.setSaveable(true)
	local retriedTwice = env.raid.ReturnStolen(pair.targetId)
	check("C: retry succeeds once the store recovers", retriedTwice == true)
	check("C: victim's saved snapshot now holds the returned copy",
		DS._saved[pair.victim] ~= nil
			and H.findOwned(DS._saved[pair.victim], pair.targetId) ~= nil)
	local retriedThrice = env.raid.ReturnStolen(pair.targetId)
	check("C: transit entry is cleared (a third call finds nothing to return)",
		retriedThrice == false, "ok=" .. tostring(retriedThrice))
	checkReturned("C", pair)
end

-- ---------------------------------------------------------------------------
-- D: idempotent recovery — crash -> rejoin twice in a row.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(1377, 1378)
	env.raid.DropStolen(pair.thief)
	for round = 1, 2 do
		DS.simulateCrash()
		DS.simulateLoad(pair.thief)
		DS.simulateLoad(pair.victim)
		local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
		local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
		check("D round " .. tostring(round) .. ": rejoins are no-ops",
			rV == 0 and remV == 0 and rT == 0 and remT == 0)
		checkReturned("D round " .. tostring(round), pair)
	end
end

H.finish()
