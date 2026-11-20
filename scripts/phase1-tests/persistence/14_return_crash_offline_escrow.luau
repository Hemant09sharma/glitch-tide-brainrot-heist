-- 14_return_crash_offline_escrow.luau — R3-6 (C): a thief drops a
-- stolen Brainrot while the victim is OFFLINE. The return is escrowed
-- (the victim's next load merges it back), and a crash before any
-- further save must still leave exactly one owner. Both rejoin orders
-- are covered, plus the variant where the thief's save lands after the
-- escrow (their stored InTransit copy is gone, so the victim's rejoin
-- merge is the only recovery). A "crash" is a reload from the stub
-- store (DS.LoadData), which discards the in-memory cache exactly as
-- a server restart would.
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

-- Victim-side assertions only (the thief's stale copy is legitimately
-- still present until the thief's own rejoin resolves it).
local function checkVictimClean(prefix, pair)
	local victimData = DS.GetData(pair.victim)
	local owned = H.findOwned(victimData, pair.targetId)
	check(prefix .. ": victim holds a clean owned copy",
		owned ~= nil and owned.InTransit ~= true
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
end

-- Full assertions (victim clean + exactly one owner + thief empty).
-- Only valid AFTER the thief's rejoin has resolved their stale copy.
local function checkReturned(prefix, pair)
	check(prefix .. ": exactly one owner overall",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1)
	checkVictimClean(prefix, pair)
	check(prefix .. ": thief holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- Steal, persist the victim's removal AND the thief's InTransit hold,
-- then take the victim offline. (The thief's save is what puts the
-- stale InTransit copy in their stored key — without it, a crash
-- reload would give the thief nothing at all, and there would be no
-- stale copy for rejoin rule (b) / (d) to resolve.)
local function offlineSetup(thiefId, victimId)
	local pair = P.newLoadedPair(env, thiefId, victimId)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "offline setup: victim save must land")
	assert(DS.SaveData(pair.thief) == true, "offline setup: thief save must land")
	pair.victim.Parent = nil
	return pair
end

-- ---------------------------------------------------------------------------
-- C1: victim rejoins first (their load merges the escrow); the thief's
-- rejoin then deletes their stale copy via rule (b).
-- ---------------------------------------------------------------------------
do
	local pair = offlineSetup(9321, 9322)
	env.raid.DropStolen(pair.thief)
	local escrow = store:peek(P.escrowKey(pair.victim.UserId))
	check("C1: return escrowed for the offline victim",
		type(escrow) == "table" and #escrow == 1
			and escrow[1].InstanceId == pair.targetId
			and type(escrow[1].ReturnTxId) == "string"
			and string.sub(escrow[1].ReturnTxId, 1, 3) == "rt-")
	check("C1: escrow entry carries the full record (level/mutation/banked/slot)",
		type(escrow) == "table" and escrow[1].Level == 5
			and escrow[1].Mutation == "golden" and escrow[1].BankedIncome == 500
			and escrow[1].Slot == 2 and escrow[1].PlacedAt == pair.oldTime
			and escrow[1].Evolved == true
			and type(escrow[1].TraitLevels) == "table" and escrow[1].TraitLevels.Food == 2)
	check("C1: thief's in-memory record is destroyed by the escrow",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
	-- Crash: both reload from the store. The victim's load merges the
	-- escrow; the thief's load brings back their stored InTransit copy.
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	check("C1: victim rejoin needs no stale-transit recovery (merge did it)",
		rV == 0 and remV == 0, "resolved=" .. tostring(rV) .. " remaining=" .. tostring(remV))
	checkVictimClean("C1", pair)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("C1: thief rejoin deletes the stale copy (rule (b), victim holds the clean copy)",
		rT == 1 and remT == 0, "resolved=" .. tostring(rT) .. " remaining=" .. tostring(remT))
	checkReturned("C1", pair)
	local okSave = DS.SaveData(pair.victim)
	check("C1: victim's post-rejoin save succeeds", okSave == true)
	local stored = store:peek(P.mainKey(pair.victim.UserId))
	check("C1: victim's stored key carries the return marker after the merge + save",
		type(stored.ReturnedTxns) == "table"
			and type(escrow[1].ReturnTxId) == "string"
			and stored.ReturnedTxns[escrow[1].ReturnTxId] ~= nil)
	check("C1: escrow key is deleted by that save",
		store:peek(P.escrowKey(pair.victim.UserId)) == nil)
end

-- ---------------------------------------------------------------------------
-- C2: thief rejoins first (victim still offline) — the stale record is
-- re-escrowed (re-park, fresh TxId), then the victim's rejoin merges it.
-- ---------------------------------------------------------------------------
do
	local pair = offlineSetup(9323, 9324)
	env.raid.DropStolen(pair.thief)
	local escrow1 = store:peek(P.escrowKey(pair.victim.UserId))
	local txId1 = type(escrow1) == "table" and escrow1[1] and escrow1[1].ReturnTxId or nil
	check("C2: first escrow parked", txId1 ~= nil)
	-- Crash for the thief only: their reload brings back the stored
	-- InTransit copy; the victim has not reloaded yet.
	DS.LoadData(pair.thief)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("C2: thief rejoin re-escrows for the still-offline victim (rule (d))",
		rT == 1 and remT == 0, "resolved=" .. tostring(rT) .. " remaining=" .. tostring(remT))
	local escrow2 = store:peek(P.escrowKey(pair.victim.UserId))
	check("C2: re-park replaced the entry (still exactly one, fresh TxId)",
		type(escrow2) == "table" and #escrow2 == 1
			and escrow2[1].InstanceId == pair.targetId
			and type(escrow2[1].ReturnTxId) == "string"
			and escrow2[1].ReturnTxId ~= txId1)
	check("C2: thief holds no copy after the re-escrow",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
	-- Now the victim rejoins and merges the (re-parked) escrow.
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	check("C2: victim rejoin needs no stale-transit recovery",
		rV == 0 and remV == 0, "resolved=" .. tostring(rV) .. " remaining=" .. tostring(remV))
	checkReturned("C2", pair)
end

-- ---------------------------------------------------------------------------
-- C3: the thief's save lands after the escrow (their stored copy is
-- gone); the victim's rejoin merge is the only recovery, and it works.
-- ---------------------------------------------------------------------------
do
	local pair = offlineSetup(9325, 9326)
	env.raid.DropStolen(pair.thief)
	assert(DS.SaveData(pair.thief) == true, "C3: thief save must land")
	check("C3: thief's stored key no longer holds the record",
		H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId) == nil)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("C3: both rejoins are no-ops (nothing stale anywhere)",
		rV == 0 and remV == 0 and rT == 0 and remT == 0)
	checkReturned("C3", pair)
end

H.finish()
