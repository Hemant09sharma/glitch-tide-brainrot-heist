-- 13_return_crash_online.luau — R3-6 (A + B): a thief drops a stolen
-- Brainrot while the victim is online; a crash immediately after the
-- return commit (before the next autosave) must still leave exactly
-- one owner, with the full-fidelity record and placed copy restored.
-- The pre-return stored state is the R3-6 hole itself: the steal-time
-- victim save landed (the removal persisted) while the thief's hold
-- save never landed (neither stored profile holds the instance). The
-- return's own durable legs — the escrow park, the victim's verified
-- save, the ReturnedTxns marker — are what survive the crash.
-- Both rejoin orders are covered (thief first, victim first).
-- A "crash" is a reload from the stub store (DS.LoadData), which
-- discards every in-memory cache exactly as a server restart would.
-- Run: bash scripts/phase1-tests/persistence/run.sh
local P = require("./persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService()
local env = P.newRaidEnv()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- The R3-6 hole state: steal, then persist ONLY the victim's removal.
-- The thief's stored key is still the pre-steal seed (no record).
local function holeSetup(thiefId, victimId)
	local pair = P.newLoadedPair(env, thiefId, victimId)
	H.steal(env, pair)
	local okSave = DS.SaveData(pair.victim)
	assert(okSave == true, "hole setup: victim steal-time save must land")
	return pair
end

-- Crash: discard every in-memory cache, reload both players from the
-- persisted store (no further saves — the autosave never ran).
local function crashReload(pair)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
end

-- Full-fidelity assertions for the returned record + placed copy
-- (fixture: level 5, golden, glitched, evolved, TraitLevels Food=2,
-- BankedIncome 500, original slot 2, original PlacedAt).
local function checkReturned(prefix, pair)
	local victimData = DS.GetData(pair.victim)
	local owned = H.findOwned(victimData, pair.targetId)
	check(prefix .. ": victim holds exactly one owned copy, clean",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and owned ~= nil and owned.InTransit ~= true
			and owned.StolenFromUserId == nil and owned.StolenSlot == nil
			and owned.StolenPlacedAt == nil and owned.StolenBankedIncome == nil)
	check(prefix .. ": returned record keeps level / mutation / glitch",
		owned ~= nil and owned.Level == 5 and owned.Mutation == "golden"
			and owned.Glitched == true,
		"level=" .. tostring(owned and owned.Level)
			.. " mutation=" .. tostring(owned and owned.Mutation))
	check(prefix .. ": returned record keeps evolution / trait fields",
		owned ~= nil and owned.Evolved == true
			and owned.EvolutionId == "evolved_wobble_waffleton"
			and owned.EvolvedTrait == "Electric"
			and owned.EvolvedFormName == "Wobble Waffleton (Evolved)"
			and type(owned.TraitLevels) == "table" and owned.TraitLevels.Food == 2)
	local placed = H.findPlaced(victimData, pair.targetId)
	check(prefix .. ": placed copy restored on the original slot",
		placed ~= nil and placed.Slot == 2, "slot=" .. tostring(placed and placed.Slot))
	check(prefix .. ": placed copy keeps fields + banked income + PlacedAt",
		placed ~= nil and placed.Level == 5 and placed.Mutation == "golden"
			and placed.Glitched == true and placed.BankedIncome == 500
			and placed.PlacedAt == pair.oldTime,
		"banked=" .. tostring(placed and placed.BankedIncome)
			.. " placedAt=" .. tostring(placed and placed.PlacedAt))
	check(prefix .. ": thief holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- ---------------------------------------------------------------------------
-- A1: hole state -> drop -> crash -> thief rejoins first, then victim.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9311, 9312)
	check("A1: hole state set up (neither stored profile holds it)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil
			and H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId) == nil)
	env.raid.DropStolen(pair.thief)
	check("A1: return commits in memory (victim has it, thief does not)",
		H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
	check("A1: return persisted the victim's key (verified save)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) ~= nil)
	check("A1: return persisted the thief's removal",
		H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId) == nil)
	local escrow = store:peek(P.escrowKey(pair.victim.UserId))
	check("A1: return parked its transaction in the victim's escrow sidecar",
		type(escrow) == "table" and #escrow == 1
			and escrow[1].InstanceId == pair.targetId
			and type(escrow[1].ReturnTxId) == "string"
			and string.sub(escrow[1].ReturnTxId, 1, 3) == "rt-")
	local txId = type(escrow) == "table" and escrow[1] and escrow[1].ReturnTxId or nil
	check("A1: victim's stored key carries the return marker for that TxId",
		txId ~= nil
			and type(store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns) == "table"
			and store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns[txId] ~= nil)
	crashReload(pair)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	check("A1: rejoin recovery is a no-op (nothing stale to resolve)",
		rT == 0 and remT == 0 and rV == 0 and remV == 0,
		"thief=" .. tostring(rT) .. "/" .. tostring(remT)
			.. " victim=" .. tostring(rV) .. "/" .. tostring(remV))
	checkReturned("A1", pair)
	local okSave = DS.SaveData(pair.victim)
	check("A1: victim's post-rejoin save succeeds", okSave == true)
	check("A1: stale escrow key is deleted by that save",
		store:peek(P.escrowKey(pair.victim.UserId)) == nil)
end

-- ---------------------------------------------------------------------------
-- A2: same flow, victim rejoins first.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9313, 9314)
	env.raid.DropStolen(pair.thief)
	crashReload(pair)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("A2: rejoin recovery is a no-op in the other order too",
		rV == 0 and remV == 0 and rT == 0 and remT == 0,
		"victim=" .. tostring(rV) .. "/" .. tostring(remV)
			.. " thief=" .. tostring(rT) .. "/" .. tostring(remT))
	checkReturned("A2", pair)
end

H.finish()
