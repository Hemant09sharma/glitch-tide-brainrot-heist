-- 02_shutdown_in_transit.luau — R2-5 (N4): server shutdown while a
-- theft is in transit must not leave a permanently frozen in-transit
-- record. The coordinated shutdown path (DataService BindToClose:
-- recovery hooks for every player FIRST, then the saves) returns the
-- Brainrot before either player's state is saved, so neither saved
-- state holds InTransit=true and the victim regains exactly one copy.
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

local function anyInTransit(saved)
	if not saved or type(saved.OwnedInstances) ~= "table" then
		return false
	end
	for _, inst in ipairs(saved.OwnedInstances) do
		if type(inst) == "table" and inst.InTransit == true then
			return true
		end
	end
	return false
end

-- A: coordinated shutdown via the RaidService entry point, then saves.
local pairA = H.newPair(env, 1201, 1202)
H.steal(env, pairA)
local returnedA = env.raid.HandleShutdown({ pairA.thief, pairA.victim })
check("A: shutdown recovery returns the in-transit Brainrot",
	returnedA == 1, "returned=" .. tostring(returnedA))
check("A: no InTransit flag left in live data after recovery",
	H.findOwned(pairA.thiefData, pairA.targetId) == nil
		and H.findOwned(pairA.victimData, pairA.targetId).InTransit ~= true)
DS.SaveData(pairA.thief)
DS.SaveData(pairA.victim)
check("A: SAVED thief data has no copy and no InTransit flag",
	countInSaved(DS._saved[pairA.thief], pairA.targetId) == 0
		and not anyInTransit(DS._saved[pairA.thief]))
check("A: SAVED victim data holds exactly one copy, no InTransit flag",
	countInSaved(DS._saved[pairA.victim], pairA.targetId) == 1
		and not anyInTransit(DS._saved[pairA.victim]))
check("A: global invariant — exactly one owned copy across both saved states",
	countInSaved(DS._saved[pairA.thief], pairA.targetId)
		+ countInSaved(DS._saved[pairA.victim], pairA.targetId) == 1)
local againA = env.raid.HandleShutdown({ pairA.thief, pairA.victim })
check("A: second shutdown pass is a no-op (idempotent)",
	againA == 0, "returned=" .. tostring(againA))

-- B: the full DataService shutdown sequence (hooks, then saves) —
-- the path BindToClose actually runs in production.
local pairB = H.newPair(env, 1203, 1204)
H.steal(env, pairB)
DS.shutdownAll({ pairB.thief, pairB.victim })
check("B: shutdown sequence saves both players",
	(DS._saves[pairB.thief] or 0) == 1 and (DS._saves[pairB.victim] or 0) == 1)
check("B: SAVED thief data has no copy and no InTransit flag",
	countInSaved(DS._saved[pairB.thief], pairB.targetId) == 0
		and not anyInTransit(DS._saved[pairB.thief]))
check("B: SAVED victim data holds exactly one copy, no InTransit flag",
	countInSaved(DS._saved[pairB.victim], pairB.targetId) == 1
		and not anyInTransit(DS._saved[pairB.victim]))
check("B: victim's saved placed copy is restored on the original slot",
	H.findPlaced(DS._saved[pairB.victim], pairB.targetId) ~= nil
		and H.findPlaced(DS._saved[pairB.victim], pairB.targetId).Slot == 2)
check("B: global invariant — exactly one owned copy across both saved states",
	countInSaved(DS._saved[pairB.thief], pairB.targetId)
		+ countInSaved(DS._saved[pairB.victim], pairB.targetId) == 1)

H.finish()
