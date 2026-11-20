-- 15_return_save_failures.luau — R3-6 (D): the return when one of its
-- two saves fails. D1: the victim's save fails (their verified save is
-- the proof the return landed) — the transit entry must be KEPT so the
-- watchdog retries, the thief's save must be SKIPPED so their stored
-- InTransit copy survives as the rejoin backstop, and the escrow park
-- must still recover the Brainrot on crash + rejoin. D1a: the watchdog
-- retry itself (a direct ReturnStolen call, since PollInTransit has a
-- 2s StolenAt guard) first fails again, then succeeds once the store
-- recovers. D2: the victim's save lands and the thief's fails — the
-- thief's stale stored copy must be deleted by rejoin rule (b), and
-- the victim's rejoin merge must SKIP the stale escrow entry (the
-- marker is in their key) instead of applying it a second time. D3:
-- both saves fail — the escrow park alone must recover it.
-- Per-key SetAsync failure is injected by monkey-patching
-- store.SetAsync in this file only (the stub's failSetAsync is global);
-- the wrapper is restored after each case.
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

-- Fail SetAsync only for one key (leave every other key working).
local function failSetAsyncForKey(key)
	local orig = store.SetAsync
	store.SetAsync = function(self, k, value)
		if k == key then
			error("injected per-key SetAsync failure for " .. k)
		end
		return orig(self, k, value)
	end
	return function()
		store.SetAsync = orig
	end
end

-- Steal, then persist only the victim's removal (the R3-6 hole state).
local function holeSetup(thiefId, victimId)
	local pair = P.newLoadedPair(env, thiefId, victimId)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
	return pair
end

local function checkReturned(prefix, pair)
	local victimData = DS.GetData(pair.victim)
	local owned = H.findOwned(victimData, pair.targetId)
	check(prefix .. ": exactly one owner, victim holds it clean",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and owned ~= nil and owned.InTransit ~= true
			and owned.StolenFromUserId == nil)
	check(prefix .. ": returned record keeps level / mutation / banked / slot",
		owned ~= nil and owned.Level == 5 and owned.Mutation == "golden"
			and owned.Glitched == true and owned.Evolved == true
			and type(owned.TraitLevels) == "table" and owned.TraitLevels.Food == 2)
	local placed = H.findPlaced(victimData, pair.targetId)
	check(prefix .. ": placed copy restored on the original slot",
		placed ~= nil and placed.Slot == 2 and placed.BankedIncome == 500
			and placed.PlacedAt == pair.oldTime)
	check(prefix .. ": thief holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- ---------------------------------------------------------------------------
-- D1: victim's save fails; thief's save skipped; escrow recovers it.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9341, 9342)
	local restore = failSetAsyncForKey(P.mainKey(pair.victim.UserId))
	env.raid.DropStolen(pair.thief)
	local escrow = store:peek(P.escrowKey(pair.victim.UserId))
	check("D1: escrow park still landed (park uses UpdateAsync, not SetAsync)",
		type(escrow) == "table" and #escrow == 1
			and escrow[1].InstanceId == pair.targetId)
	check("D1: victim's stored key does NOT hold the return (save failed)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil)
	check("D1: thief's stored key has no copy (their save was skipped, not failed)",
		H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId) == nil)
	check("D1: in-memory return still stands (victim has it, thief does not)",
		H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
	-- D1a: the watchdog retry (direct ReturnStolen — PollInTransit has a
	-- 2s StolenAt guard). With the failure still armed it must fail
	-- again and keep the transit entry; once the store recovers it
	-- must succeed and land the victim's key.
	local retriedOnce = env.raid.ReturnStolen(pair.targetId)
	check("D1a: retry fails again while the victim's key is still failing",
		retriedOnce == false, "ok=" .. tostring(retriedOnce))
	check("D1a: victim's stored key still lacks the return after the failed retry",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil)
	restore()
	local retriedTwice = env.raid.ReturnStolen(pair.targetId)
	check("D1a: retry succeeds once the store recovers", retriedTwice == true)
	check("D1a: victim's stored key now holds the returned copy",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) ~= nil)
	check("D1a: victim's stored key carries the return marker",
		type(store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns) == "table"
			and next(store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns) ~= nil)
	-- Crash now (after the successful retry): the recovery is a no-op.
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("D1: post-crash rejoins are no-ops",
		rV == 0 and remV == 0 and rT == 0 and remT == 0)
	checkReturned("D1", pair)
end

-- ---------------------------------------------------------------------------
-- D1b: the same victim-save failure, but the crash hits BEFORE any
-- retry — the escrow merge alone must recover it on rejoin.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9343, 9344)
	local restore = failSetAsyncForKey(P.mainKey(pair.victim.UserId))
	env.raid.DropStolen(pair.thief)
	restore()
	check("D1b: victim's stored key lacks the return (save failed)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("D1b: rejoins are no-ops (the load-time escrow merge did the recovery)",
		rV == 0 and remV == 0 and rT == 0 and remT == 0)
	checkReturned("D1b", pair)
end

-- ---------------------------------------------------------------------------
-- D2: victim's save lands, thief's save fails — the thief's stale stored
-- copy is deleted by rejoin rule (b); the merge skips the stale escrow.
-- ---------------------------------------------------------------------------
do
	local pair = P.newLoadedPair(env, 9345, 9346)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "D2 setup: victim save must land")
	assert(DS.SaveData(pair.thief) == true, "D2 setup: thief save must land (their stored key now holds the InTransit copy)")
	local restore = failSetAsyncForKey(P.mainKey(pair.thief.UserId))
	env.raid.DropStolen(pair.thief)
	restore()
	check("D2: victim's stored key holds the returned copy (their save landed)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) ~= nil)
	check("D2: victim's stored key carries the return marker",
		type(store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns) == "table"
			and next(store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns) ~= nil)
	check("D2: thief's stored key still holds the stale InTransit copy (their save failed)",
		H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId) ~= nil
			and H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId).InTransit == true)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	check("D2: victim rejoin is a no-op (their key is clean; the merge skipped the stale escrow)",
		rV == 0 and remV == 0, "resolved=" .. tostring(rV) .. " remaining=" .. tostring(remV))
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("D2: thief rejoin deletes the stale copy (rule (b), victim holds the clean copy)",
		rT == 1 and remT == 0, "resolved=" .. tostring(rT) .. " remaining=" .. tostring(remT))
	checkReturned("D2", pair)
	local okSave = DS.SaveData(pair.victim)
	check("D2: victim's post-rejoin save succeeds", okSave == true)
	check("D2: stale escrow key is deleted by that save",
		store:peek(P.escrowKey(pair.victim.UserId)) == nil)
end

-- ---------------------------------------------------------------------------
-- D3: both saves fail — the escrow park alone must recover it.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9347, 9348)
	store:failSetAsync(100)
	env.raid.DropStolen(pair.thief)
	check("D3: escrow park still landed (park uses UpdateAsync)",
		type(store:peek(P.escrowKey(pair.victim.UserId))) == "table"
			and #store:peek(P.escrowKey(pair.victim.UserId)) == 1)
	check("D3: victim's stored key lacks the return (save failed)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil)
	check("D3: thief's stored key has no copy (their save was skipped)",
		H.findOwned(store:peek(P.mainKey(pair.thief.UserId)), pair.targetId) == nil)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
	check("D3: rejoins are no-ops (the load-time escrow merge did the recovery)",
		rV == 0 and remV == 0 and rT == 0 and remT == 0)
	checkReturned("D3", pair)
	store:resetFailures()
	local okSave = DS.SaveData(pair.victim)
	check("D3: victim's post-recovery save succeeds once the store recovers",
		okSave == true)
	check("D3: escrow key is deleted by that save",
		store:peek(P.escrowKey(pair.victim.UserId)) == nil)
end

H.finish()
