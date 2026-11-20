-- 05_double_save_race.luau — R2-5: both leave handlers firing (the
-- old competing-save race) must end consistent: the coordinated path
-- has ONE save owner, so a second PlayerRemoving fire is a no-op
-- (the cache is already cleared; SaveData finds nothing and persists
-- nothing), and the final saved states hold exactly one copy of the
-- instance with the victim — no duplicate, no loss.
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

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

local pair = H.newPair(env, 1501, 1502)
H.steal(env, pair)

-- Both players leave, each signal fired twice, interleaved — the
-- worst case of the old double-handler race.
pair.thief.Parent = nil
Players.PlayerRemoving:Fire(pair.thief)
pair.victim.Parent = nil
Players.PlayerRemoving:Fire(pair.victim)
Players.PlayerRemoving:Fire(pair.thief)
Players.PlayerRemoving:Fire(pair.victim)

check("thief saved exactly once despite the double fire",
	(DS._saves[pair.thief] or 0) == 1, "saves=" .. tostring(DS._saves[pair.thief]))
check("victim saved exactly once despite the double fire",
	(DS._saves[pair.victim] or 0) == 1, "saves=" .. tostring(DS._saves[pair.victim]))
check("thief's saved data has no copy",
	countInSaved(DS._saved[pair.thief], pair.targetId) == 0)
check("victim's saved data holds exactly one copy",
	countInSaved(DS._saved[pair.victim], pair.targetId) == 1)
check("victim's saved copy has no InTransit flag",
	H.findOwned(DS._saved[pair.victim], pair.targetId).InTransit ~= true)
check("victim's saved placed copy is restored",
	H.findPlaced(DS._saved[pair.victim], pair.targetId) ~= nil)
check("global invariant: exactly one owned copy across both saved states",
	countInSaved(DS._saved[pair.thief], pair.targetId)
		+ countInSaved(DS._saved[pair.victim], pair.targetId) == 1)

-- A restart from those saved states rejouns clean: nothing stale to
-- reconcile, nothing to duplicate.
DS.simulateLoad(pair.thief)
DS.simulateLoad(pair.victim)
local resolvedT, remainingT = env.raid.RecoverStaleTransit(pair.thief)
local resolvedV, remainingV = env.raid.RecoverStaleTransit(pair.victim)
check("rejoin after the race finds nothing stale to resolve",
	resolvedT == 0 and remainingT == 0 and resolvedV == 0 and remainingV == 0)
check("rejoin keeps exactly one owned copy, with the victim",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
		and H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil)

H.finish()
