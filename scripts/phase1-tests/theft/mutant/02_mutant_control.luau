-- 02_mutant_control.luau — R2 watchdog negative control: the SAME
-- reconcile assertions as theft/09_watchdog_reconcile.luau scenario A,
-- run against the MUTANT RaidService (reconcile call removed by
-- mutant/make_mutant.sh). This file is EXPECTED TO FAIL: the mutant
-- must leave the stale placed copy untouched after the watchdog
-- delivery, which proves the test detects the missing reconcile.
-- Never run under theft/run_all.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")

local env = H.newEnv({ raidPath = "./theft/mutant/RaidServiceWatchdog" })
local base = H.newBaseEnv(env)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 953, 954)
local plotT = base.AssignBase(pair.thief)
local plotV = base.AssignBase(pair.victim)
assert(plotT ~= nil and plotV ~= nil, "plots not assigned")
H.steal(env, pair)
table.insert(pair.thiefData.Base.Placed, {
	InstanceId = pair.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 1,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = pair.oldTime,
})
local coinsBefore = pair.thiefData.Coins
env.raid.PollInTransit()
check("M: watchdog delivery pays the steal reward once (300 coins)",
	pair.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pair.thiefData.Coins))
local placed = H.findPlaced(pair.thiefData, pair.targetId)
check("M: placed copy reconciled from the owned record (level/mutation/glitched)",
	placed ~= nil and placed.Level == 5 and placed.Mutation == "golden"
		and placed.Glitched == true,
	"Level=" .. tostring(placed and placed.Level)
		.. " Mutation=" .. tostring(placed and placed.Mutation))
check("M: placed copy reconciled (banked remainder 250)",
	placed ~= nil and placed.BankedIncome == 250,
	"BankedIncome=" .. tostring(placed and placed.BankedIncome))
local owned = H.findOwned(pair.thiefData, pair.targetId)
check("M: owned.Placed / Slot synced to the existing placed copy",
	owned ~= nil and owned.Placed == true and owned.Slot == 1,
	"Placed=" .. tostring(owned and owned.Placed) .. " Slot=" .. tostring(owned and owned.Slot))
check("M: thief's carry state cleared by the reconcile",
	env.carry.GetCarried(pair.thief) == nil
		and pair.thief.Character:GetAttribute("CarryingStolen") == "")

H.finish()
