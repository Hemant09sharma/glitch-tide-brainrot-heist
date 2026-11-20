-- 01_mutant_control.luau — R2-5 negative control: the SAME
-- rejoin-ownership assertions as lifecycle/03 scenario A, run against
-- the MUTANT RaidService (old behaviour restored by
-- mutant/make_mutant.sh: no durable owner identity, no pre-save hook,
-- gutted rejoin reconciliation, destroy-on-victim-offline). This file
-- is EXPECTED TO FAIL: after the thief leaves mid-theft, the save
-- lands before the return (the mutant's direct PlayerRemoving handler
-- fires after DataService's save-and-clear), and the rejoin
-- reconciler resolves nothing — so the victim still has no copy and
-- the thief's saved record is still flagged InTransit. That failure
-- proves the lifecycle test detects the missing fix.
-- Never run under lifecycle/run.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")
local L = require("../lifecycle_data")

local DS = L.new()
DS.connectLeaveHandler()
local env = H.newEnv({
	raidPath = "./lifecycle/mutant/RaidServiceLifecycle",
	dataService = DS,
})
local Players = game:GetService("Players")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 1901, 1902)
H.steal(env, pair)
-- The victim's last save is the steal-time one (no record): persist it
-- so the rejoin loads a real victim state without the Brainrot.
DS.SaveData(pair.victim)

-- The thief leaves mid-theft.
pair.thief.Parent = nil
Players.PlayerRemoving:Fire(pair.thief)

-- Crash + rejoin from the saved states (the thief's snapshot is the
-- leave save, taken before the return could run).
DS.simulateCrash()
DS.simulateLoad(pair.thief)
DS.simulateLoad(pair.victim)
local resolved, remaining = env.raid.RecoverStaleTransit(pair.thief)
check("M: rejoin resolves the stale record (1 resolved, 0 remaining)",
	resolved == 1 and remaining == 0,
	"resolved=" .. tostring(resolved) .. " remaining=" .. tostring(remaining))
check("M: exactly one owned copy, back with the victim",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
		and H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
		and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)
local victimOwned = H.findOwned(DS.GetData(pair.victim), pair.targetId)
check("M: victim's placed copy restored, no InTransit flag",
	victimOwned ~= nil and H.findPlaced(DS.GetData(pair.victim), pair.targetId) ~= nil
		and victimOwned.InTransit ~= true)
local thiefOwned = H.findOwned(DS.GetData(pair.thief), pair.targetId)
check("M: thief holds no flagged record after rejoin",
	thiefOwned == nil or thiefOwned.InTransit ~= true)

H.finish()
