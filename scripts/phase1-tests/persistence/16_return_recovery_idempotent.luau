-- 16_return_recovery_idempotent.luau — R3-6 (E + marker): recovery
-- must be idempotent (crash -> rejoin, repeated three times, still
-- exactly one owner and no change), and the ReturnedTxns marker must
-- stop a STALE escrow entry from voiding a legitimate re-steal: after
-- a completed return (marker in the victim's key, escrow entry still
-- parked), a second thief steals the Brainrot and delivers it; the
-- victim's rejoin merge must SKIP the stale escrow entry instead of
-- handing them a second copy.
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

-- Steal, then persist only the victim's removal (the R3-6 hole state).
local function holeSetup(thiefId, victimId)
	local pair = P.newLoadedPair(env, thiefId, victimId)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
	return pair
end

local function checkOneOwnerClean(prefix, pair, players)
	check(prefix .. ": exactly one owner overall",
		H.countOwned(env, players, pair.targetId) == 1)
	local owned = H.findOwned(DS.GetData(pair.victim), pair.targetId)
	check(prefix .. ": victim holds it clean",
		owned ~= nil and owned.InTransit ~= true
			and owned.StolenFromUserId == nil)
	local placed = H.findPlaced(DS.GetData(pair.victim), pair.targetId)
	check(prefix .. ": placed copy restored on the original slot, full fields",
		placed ~= nil and placed.Slot == 2 and placed.Level == 5
			and placed.Mutation == "golden" and placed.Glitched == true
			and placed.BankedIncome == 500 and placed.PlacedAt == pair.oldTime)
	check(prefix .. ": thief holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- ---------------------------------------------------------------------------
-- E1: crash -> rejoin, three times in a row (no saves between).
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9351, 9352)
	env.raid.DropStolen(pair.thief)
	for round = 1, 3 do
		DS.LoadData(pair.thief)
		DS.LoadData(pair.victim)
		local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
		local rT, remT, _, _ = env.raid.RecoverOnRejoin(pair.thief)
		check("E1 round " .. tostring(round) .. ": rejoins are no-ops",
			rV == 0 and remV == 0 and rT == 0 and remT == 0,
			"victim=" .. tostring(rV) .. "/" .. tostring(remV)
				.. " thief=" .. tostring(rT) .. "/" .. tostring(remT))
		checkOneOwnerClean("E1 round " .. tostring(round), pair,
			{ pair.thief, pair.victim })
	end
end

-- ---------------------------------------------------------------------------
-- E2: the marker stops a stale escrow entry from voiding a re-steal.
-- ---------------------------------------------------------------------------
do
	local pair = holeSetup(9353, 9354)
	env.raid.DropStolen(pair.thief)
	check("E2: return committed (victim's stored key holds it)",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) ~= nil)
	local escrow = store:peek(P.escrowKey(pair.victim.UserId))
	local txId = type(escrow) == "table" and escrow[1] and escrow[1].ReturnTxId or nil
	check("E2: return marker is in the victim's stored key",
		txId ~= nil
			and type(store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns) == "table"
			and store:peek(P.mainKey(pair.victim.UserId)).ReturnedTxns[txId] ~= nil)
	check("E2: escrow entry is still parked (no rejoin yet to delete it)",
		type(escrow) == "table" and #escrow == 1)
	-- A second thief steals the returned Brainrot and delivers it.
	-- (The victim's restored PlacedAt is ~15 days old, so the 120s
	-- protection is off; both players stand at (0,0,0), so the
	-- channel range passes.)
	local thief2 = H.newPlayer(9355, "Thief9355", 30, Vector3.new(0, 0, 0))
	store:seed(P.mainKey(9355), {
		Level = 5,
		Coins = 100000,
		Gems = 0,
		Unlocked = { "wobble_waffleton" },
		OwnedInstances = {},
		Base = { Placed = {} },
		LastLogin = os.time(),
	})
	DS.LoadData(thief2)
	local okSteal, stealErr = env.raid.StealBrainrot(thief2, pair.victim.UserId, pair.targetId)
	check("E2: second thief steals the returned Brainrot",
		okSteal == true, "err=" .. tostring(stealErr))
	local okDeliver = env.raid.ConfirmDelivery(thief2, pair.targetId)
	check("E2: second thief delivers it", okDeliver == true)
	assert(DS.SaveData(pair.victim) == true, "E2: victim save must land (removal + marker)")
	assert(DS.SaveData(thief2) == true, "E2: thief2 save must land (delivered copy)")
	check("E2: victim's stored key no longer holds the Brainrot",
		H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil)
	check("E2: thief2's stored key holds the delivered copy",
		H.findOwned(store:peek(P.mainKey(9355)), pair.targetId) ~= nil)
	-- The victim leaves and rejoins: their load merges the sidecars,
	-- and the merge must SKIP the stale escrow entry (marker present).
	DS.LoadData(pair.victim)
	local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
	check("E2: victim rejoin is a no-op (no stale transit to resolve)",
		rV == 0 and remV == 0, "resolved=" .. tostring(rV) .. " remaining=" .. tostring(remV))
	check("E2: victim did NOT regain a copy from the stale escrow (marker skipped it)",
		H.findOwned(DS.GetData(pair.victim), pair.targetId) == nil)
	check("E2: victim has no placed copy restored either",
		H.findPlaced(DS.GetData(pair.victim), pair.targetId) == nil)
	check("E2: exactly one owner overall (thief2)",
		H.countOwned(env, { pair.thief, pair.victim, thief2 }, pair.targetId) == 1
			and H.findOwned(DS.GetData(thief2), pair.targetId) ~= nil)
	check("E2: first thief still holds no copy",
		H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
	local okSave = DS.SaveData(pair.victim)
	check("E2: victim's post-rejoin save succeeds", okSave == true)
	check("E2: stale escrow key is deleted by that save",
		store:peek(P.escrowKey(pair.victim.UserId)) == nil)
end

H.finish()
