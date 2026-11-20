-- 04_victim_leaves_mid_theft.luau — R2-5 (N3/N4): the victim leaving
-- mid-theft must NOT delete the stolen Brainrot (the old behaviour
-- destroyed it) and must NOT let the thief keep it for free.
--   A. Victim leaves first, thief leaves after with the victim
--      offline -> the record is escrowed durably for the victim; the
--      thief's saved state has no copy; when the victim rejoins, the
--      escrow merges back into their data (exactly one copy, placed
--      copy restored, no InTransit flag).
--   B. Same flow with a DataService that has NO escrow API (older
--      version) -> the record stays flagged in-transit with the thief
--      (recoverable on the thief's later rejoin with the victim
--      online), never destroyed and never granted clean.
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

-- ONE env per file (harness contract: a second H.newEnv in the same
-- process leaves CarryService wired to the first DataService, since
-- its Init early-returns). Scenarios below share it via fresh pairs.
local DS = L.new()
DS.connectLeaveHandler()
local env = H.newEnv({ dataService = DS })
local Players = game:GetService("Players")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function countInSaved(saved, instanceId)
	local total = 0
	if saved and type(saved.OwnedInstances) == "table" then
		for _, inst in ipairs(saved.OwnedInstances) do
			if type(inst) == "table" and inst.InstanceId == instanceId then
				total += 1
			end
		end
	end
	return total
end

-- ---------------------------------------------------------------------------
-- A: escrow path.
-- ---------------------------------------------------------------------------
do
	local pair = H.newPair(env, 1401, 1402)
	H.steal(env, pair)

	-- The victim leaves mid-theft. Their save must not contain the
	-- instance (it was moved away at steal time) and nothing is lost.
	pair.victim.Parent = nil
	Players.PlayerRemoving:Fire(pair.victim)
	check("A: victim's saved data has no copy (it was stolen, not lost)",
		DS._saved[pair.victim] ~= nil
			and countInSaved(DS._saved[pair.victim], pair.targetId) == 0)
	check("A: victim's cache cleared after leave",
		env.dataService.GetData(pair.victim) == nil)

	-- The thief leaves with the victim offline: escrow, not destroy.
	pair.thief.Parent = nil
	Players.PlayerRemoving:Fire(pair.thief)
	check("A: thief's saved data has no copy (escrowed away, not kept)",
		DS._saved[pair.thief] ~= nil
			and countInSaved(DS._saved[pair.thief], pair.targetId) == 0)
	check("A: exactly one escrow entry parked for the victim",
		type(DS._escrow[pair.victim.UserId]) == "table"
			and #DS._escrow[pair.victim.UserId] == 1
			and DS._escrow[pair.victim.UserId][1].InstanceId == pair.targetId)
	check("A: escrow entry carries the return-restore fields",
		DS._escrow[pair.victim.UserId][1].Placed == true
			and DS._escrow[pair.victim.UserId][1].Slot == 2
			and DS._escrow[pair.victim.UserId][1].BankedIncome == 500)
	check("A: global invariant — the instance exists exactly once (in escrow)",
		countInSaved(DS._saved[pair.thief], pair.targetId)
			+ countInSaved(DS._saved[pair.victim], pair.targetId)
			+ (DS._escrow[pair.victim.UserId] and #DS._escrow[pair.victim.UserId] or 0) == 1)

	-- The victim rejoins (same player object re-parented: the harness
	-- cannot mint a second Player with the same UserId, and the escrow
	-- key is the UserId, so the merge behaves identically for a fresh
	-- Player object in production). Load merges the escrow.
	pair.victim.Parent = Players
	DS.simulateLoad(pair.victim)
	local victimData = DS.GetData(pair.victim)
	check("A: rejoin restores exactly one owned copy to the victim",
		H.findOwned(victimData, pair.targetId) ~= nil
			and H.countOwned(env, { pair.victim }, pair.targetId) == 1)
	local restored = H.findOwned(victimData, pair.targetId)
	check("A: restored record has no InTransit flag or theft markers",
		restored ~= nil and restored.InTransit ~= true
			and restored.StolenFromUserId == nil)
	check("A: restored placed copy is back on the original slot",
		H.findPlaced(victimData, pair.targetId) ~= nil
			and H.findPlaced(victimData, pair.targetId).Slot == 2
			and H.findPlaced(victimData, pair.targetId).BankedIncome == 500)
	check("A: restored record keeps its paid fields (level/mutation/glitched)",
		restored ~= nil and restored.Level == 5 and restored.Mutation == "golden"
			and restored.Glitched == true)
	-- A later save of the merged data deletes the sidecar entry.
	DS.SaveData(pair.victim)
	check("A: sidecar entry deleted after the merged data is saved",
		DS._escrow[pair.victim.UserId] == nil)
	-- A second rejoin re-merges nothing (no duplication from the merge).
	DS.simulateLoad(pair.victim)
	check("A: second load does not duplicate the restored Brainrot",
		H.countOwned(env, { pair.victim }, pair.targetId) == 1
			and H.countPlaced(env, { pair.victim }, pair.targetId) == 1)
end

-- ---------------------------------------------------------------------------
-- B: no-escrow fallback — keep flagged, never destroy, never grant.
-- ---------------------------------------------------------------------------
do
	-- No-escrow variant on the SHARED fake: removing the API field
	-- makes RaidService see "no escrow API" (older DataService).
	DS.EscrowReturnedInstance = nil
	local pair = H.newPair(env, 1403, 1404)
	H.steal(env, pair)
	pair.victim.Parent = nil
	Players.PlayerRemoving:Fire(pair.victim)
	pair.thief.Parent = nil
	Players.PlayerRemoving:Fire(pair.thief)
	check("B: without an escrow API the thief's saved data still holds the flagged record",
		DS._saved[pair.thief] ~= nil
			and countInSaved(DS._saved[pair.thief], pair.targetId) == 1
			and H.findOwned(DS._saved[pair.thief], pair.targetId).InTransit == true)
	check("B: the saved record still names its victim (recoverable later)",
		H.findOwned(DS._saved[pair.thief], pair.targetId).StolenFromUserId == pair.victim.UserId)
	check("B: victim's saved data has no copy (no duplication)",
		countInSaved(DS._saved[pair.victim], pair.targetId) == 0)
	-- The thief rejoins with the victim back online: the rejoin
	-- reconciler returns it now.
	pair.victim.Parent = Players
	pair.thief.Parent = Players
	DS.simulateLoad(pair.thief)
	DS.simulateLoad(pair.victim)
	local resolved, remaining = env.raid.RecoverStaleTransit(pair.thief)
	check("B: thief rejoin with victim online resolves the kept record",
		resolved == 1 and remaining == 0,
		"resolved=" .. tostring(resolved) .. " remaining=" .. tostring(remaining))
	check("B: exactly one owned copy, back with the victim",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
			and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
end

H.finish()
