-- 01_thief_leaves_mid_theft.luau — R2-5 (N3): a thief who leaves
-- while carrying a stolen Brainrot must NOT persist an orphaned
-- in-transit record. The coordinated leave path (DataService
-- PlayerRemoving: pre-save hook -> save -> clear cache) returns the
-- Brainrot to the victim BEFORE the thief's data is saved, so the
-- saved thief state contains no in-transit record and the victim's
-- data regains exactly one copy.
-- The fake DataService (lifecycle_data) mirrors the real
-- DataService.luau contract: hooks run before the save. If the save
-- ran first (the old ordering), the thief's snapshot would still hold
-- the InTransit record — see the mutant control.
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

local DS = L.new()
-- Production order: DataService.Init (leave handler) connects BEFORE
-- GameManager.Init / RaidService.Init.
DS.connectLeaveHandler()
local env = H.newEnv({ dataService = DS })
local Players = game:GetService("Players")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 1101, 1102)
H.steal(env, pair)
local ownedBefore = H.findOwned(pair.thiefData, pair.targetId)
check("pre-leave: stolen record is with the thief, flagged InTransit",
	ownedBefore ~= nil and ownedBefore.InTransit == true
		and ownedBefore.StolenFromUserId == pair.victim.UserId,
	"StolenFromUserId=" .. tostring(ownedBefore and ownedBefore.StolenFromUserId))
check("pre-leave: victim has no owned copy",
	H.findOwned(pair.victimData, pair.targetId) == nil)

-- The thief leaves: Parent=nil first (offline), then the signal.
pair.thief.Parent = nil
Players.PlayerRemoving:Fire(pair.thief)

check("thief's cache cleared after leave (save-then-clear)",
	env.dataService.GetData(pair.thief) == nil)
check("thief saved exactly once on leave",
	(DS._saves[pair.thief] or 0) == 1, "saves=" .. tostring(DS._saves[pair.thief]))
local thiefSaved = DS._saved[pair.thief]
check("SAVED thief data contains no orphaned in-transit record",
	thiefSaved ~= nil and H.findOwned(thiefSaved, pair.targetId) == nil)
check("SAVED thief data has no InTransit-flagged record at all",
	thiefSaved ~= nil and (function()
		for _, inst in ipairs(thiefSaved.OwnedInstances or {}) do
			if type(inst) == "table" and inst.InTransit == true then
				return false
			end
		end
		return true
	end)())
check("victim's live data regains exactly one owned copy",
	H.countOwned(env, { pair.victim }, pair.targetId) == 1
		and H.findOwned(pair.victimData, pair.targetId) ~= nil)
local victimOwned = H.findOwned(pair.victimData, pair.targetId)
check("returned record has no InTransit flag and no theft markers",
	victimOwned ~= nil and victimOwned.InTransit ~= true
		and victimOwned.StolenFromUserId == nil)
check("victim's live data regains exactly one placed copy",
	H.countPlaced(env, { pair.victim }, pair.targetId) == 1
		and H.findPlaced(pair.victimData, pair.targetId) ~= nil)
check("global invariant: exactly one owned copy across both players",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1)
check("thief is no longer carrying, attribute cleared",
	env.carry.IsCarrying(pair.thief) == false
		and pair.thief:GetAttribute("CarryingStolen") == "")

-- The victim leaves too: their save must now carry the returned copy.
pair.victim.Parent = nil
Players.PlayerRemoving:Fire(pair.victim)
local victimSaved = DS._saved[pair.victim]
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
check("SAVED victim data holds exactly one owned copy",
	victimSaved ~= nil and countInSaved(victimSaved, pair.targetId) == 1)
check("SAVED victim data holds exactly one placed copy, no InTransit flag",
	victimSaved ~= nil and H.findPlaced(victimSaved, pair.targetId) ~= nil
		and H.findOwned(victimSaved, pair.targetId).InTransit ~= true)
check("SAVED states together hold exactly one copy (no duplication)",
	countInSaved(DS._saved[pair.thief], pair.targetId)
		+ countInSaved(DS._saved[pair.victim], pair.targetId) == 1)

H.finish()
