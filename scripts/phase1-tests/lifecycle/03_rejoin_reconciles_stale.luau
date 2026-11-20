-- 03_rejoin_reconciles_stale.luau — R2-5: both players rejoining with
-- stale records present (a crash persisted the in-transit state) must
-- end with exactly ONE owner, correct ownership, no permanent
-- InTransit flag, and no duplicated reward. Four stale shapes:
--   A. thief holds a flagged record with StolenFromUserId, victim
--      holds nothing, victim online -> return to the victim.
--   B. thief holds a flagged record AND a placed copy in their own
--      base (delivery committed in memory, flag-clear never
--      persisted) -> treated as delivered, thief keeps it, flag
--      cleared, no reward re-paid (the reconciler never mints coins
--      on ambiguous evidence; see RaidService.RecoverStaleTransit).
--   C. BOTH hold a copy (old double-save race), thief's flagged ->
--      the stale duplicate is deleted, the victim's clean copy wins.
--   D. legacy flagged record with NO recorded owner -> kept flagged,
--      warned, never deleted and never granted to the thief.
-- A "crash" is simulated by wiping the live caches and reloading
-- from the saved snapshots (lifecycle_data.simulateCrash /
-- simulateLoad), exactly as a server restart would.
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

-- ONE env per file (harness contract: a second H.newEnv in the same
-- process leaves CarryService wired to the first DataService, since
-- its Init early-returns). Scenarios below share it via fresh pairs.
local DS = L.new()
DS.connectLeaveHandler()
local env = H.newEnv({ dataService = DS })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- Crash-persist: snapshot both players' live data as the DataStore
-- state, wipe the caches, reload from the snapshots.
local function crashAndReload(DS, pair)
	DS._saved[pair.thief] = L.deepCopy(pair.thiefData)
	DS._saved[pair.victim] = L.deepCopy(pair.victimData)
	DS.simulateCrash()
	DS.simulateLoad(pair.thief)
	DS.simulateLoad(pair.victim)
end

-- ---------------------------------------------------------------------------
-- A: stale flagged record, victim online -> return on the thief's rejoin.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1301, 1302)
	H.steal(env, pair)
	local coinsBefore = pair.thiefData.Coins
	crashAndReload(DS, pair)
	local thiefData = DS.GetData(pair.thief)
	local victimData = DS.GetData(pair.victim)
	check("A: stale record reloaded flagged with the thief",
		H.findOwned(thiefData, pair.targetId) ~= nil
			and H.findOwned(thiefData, pair.targetId).InTransit == true
			and H.findOwned(thiefData, pair.targetId).StolenFromUserId == pair.victim.UserId)
	check("A: victim reloaded with no copy",
		H.findOwned(victimData, pair.targetId) == nil)
	local resolved, remaining, paid, total = env.raid.RecoverOnRejoin(pair.thief)
	check("A: rejoin resolves the stale record (1 resolved, 0 remaining)",
		resolved == 1 and remaining == 0,
		"resolved=" .. tostring(resolved) .. " remaining=" .. tostring(remaining))
	check("A: no reward paid by the reconciler (theft never delivered)",
		paid == 0 and total == 0 and DS.GetData(pair.thief).Coins == coinsBefore,
		"paid=" .. tostring(paid) .. " coins=" .. tostring(DS.GetData(pair.thief).Coins))
	check("A: exactly one owned copy, back with the victim",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
	check("A: victim's placed copy restored, no InTransit flag",
		H.findPlaced(DS.GetData(pair.victim), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.victim), pair.targetId).InTransit ~= true)
	local resolved2, remaining2 = env.raid.RecoverStaleTransit(pair.thief)
	check("A: second rejoin pass is a no-op (idempotent)",
		resolved2 == 0 and remaining2 == 0)
end

-- ---------------------------------------------------------------------------
-- B: flagged record + placed copy in the thief's own base -> delivered.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1303, 1304)
	H.steal(env, pair)
	-- The placed copy exists (delivery path built it) but the
	-- flag-clear never persisted.
	table.insert(pair.thiefData.Base.Placed, {
		InstanceId = pair.targetId,
		CharacterId = "wobble_waffleton",
		Slot = 1,
		Level = 5,
		Glitched = true,
		Mutation = "golden",
		BankedIncome = 250,
		PlacedAt = pair.oldTime,
	})
	local coinsBefore = pair.thiefData.Coins
	crashAndReload(DS, pair)
	local resolved, remaining, paid = env.raid.RecoverOnRejoin(pair.thief)
	check("B: rejoin resolves the delivered stale record",
		resolved == 1 and remaining == 0,
		"resolved=" .. tostring(resolved) .. " remaining=" .. tostring(remaining))
	check("B: thief keeps the delivered Brainrot (exactly one copy)",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findOwned(DS.GetData(pair.thief), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.victim), pair.targetId) == nil)
	local ownedB = H.findOwned(DS.GetData(pair.thief), pair.targetId)
	check("B: InTransit flag and theft markers cleared on the kept record",
		ownedB ~= nil and ownedB.InTransit ~= true and ownedB.StolenFromUserId == nil)
	check("B: placed copy stays in the thief's base",
		H.findPlaced(DS.GetData(pair.thief), pair.targetId) ~= nil)
	check("B: no reward re-paid by the reconciler",
		paid == 0 and DS.GetData(pair.thief).Coins == coinsBefore,
		"paid=" .. tostring(paid) .. " coins=" .. tostring(DS.GetData(pair.thief).Coins))
end

-- ---------------------------------------------------------------------------
-- C: both hold a copy (old double-save race) -> stale duplicate deleted.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1305, 1306)
	H.steal(env, pair)
	-- The victim ALSO holds a clean copy (the double-save race wrote
	-- the record into both accounts).
	local cleanCopy = L.deepCopy(H.findOwned(pair.thiefData, pair.targetId))
	cleanCopy.InTransit = nil
	cleanCopy.StolenFromUserId = nil
	cleanCopy.StolenSlot = nil
	cleanCopy.StolenPlacedAt = nil
	cleanCopy.StolenBankedIncome = nil
	table.insert(pair.victimData.OwnedInstances, cleanCopy)
	crashAndReload(DS, pair)
	check("C: stale duplicate present before rejoin (2 owned copies)",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 2)
	local resolved, remaining = env.raid.RecoverStaleTransit(pair.thief)
	check("C: rejoin deletes the stale duplicate (1 resolved)",
		resolved == 1 and remaining == 0,
		"resolved=" .. tostring(resolved) .. " remaining=" .. tostring(remaining))
	check("C: exactly one owned copy left, with the victim (clean copy wins)",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

-- ---------------------------------------------------------------------------
-- D: legacy flagged record, no recorded owner -> kept, never granted.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1307, 1308)
	H.steal(env, pair)
	local stale = H.findOwned(pair.thiefData, pair.targetId)
	stale.StolenFromUserId = nil
	stale.StolenSlot = nil
	stale.StolenPlacedAt = nil
	stale.StolenBankedIncome = nil
	pair.victim.Parent = nil -- victim offline too: no owner to return to
	crashAndReload(DS, pair)
	local resolved, remaining = env.raid.RecoverStaleTransit(pair.thief)
	check("D: legacy record with no owner is NOT resolved (0 resolved, 1 remaining)",
		resolved == 0 and remaining == 1,
		"resolved=" .. tostring(resolved) .. " remaining=" .. tostring(remaining))
	local kept = H.findOwned(DS.GetData(pair.thief), pair.targetId)
	check("D: record is kept flagged with the thief — not deleted, not granted clean",
		kept ~= nil and kept.InTransit == true)
	check("D: victim still has no copy (no duplication)",
		H.findOwned(DS.GetData(pair.victim), pair.targetId) == nil
			and H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1)
end

H.finish()
