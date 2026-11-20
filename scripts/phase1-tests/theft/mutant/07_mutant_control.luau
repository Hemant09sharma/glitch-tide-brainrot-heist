-- 07_mutant_control.luau — R2 E2 negative control: the SAME
-- rounding/conservation assertions as
-- theft/13_share_rounding_conservation.luau, run against the MUTANT
-- RaidService (ConfirmDelivery re-derives the share locally with
-- math.ceil instead of the single Economy.StealRewardShare floor
-- computation, built by mutant/make_mutant.sh). This file is EXPECTED
-- TO FAIL: with an odd banked amount (501) the mutant must retain
-- 250 instead of 251, silently destroying 1 coin of banked income,
-- which proves the test detects a duplicated share formula.
-- Never run under theft/run_all.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")
local Economy = require("../shared/Economy")

local env = H.newEnv({ raidPath = "./theft/mutant/RaidServiceE2" })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 983, 984)
H.findPlaced(pair.victimData, pair.targetId).BankedIncome = 501
H.steal(env, pair)
local coinsBefore = pair.thiefData.Coins
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("M: delivery succeeds with odd banked income", okDel == true,
	"status=" .. tostring(status))
check("M: delivery pays 300 coins (250 share + 50 bonus)",
	pair.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pair.thiefData.Coins))
local owned = H.findOwned(pair.thiefData, pair.targetId)
check("M: delivered record retains 251 (501 - 250, not 501 - 251)",
	owned ~= nil and owned.BankedIncome == 251,
	"BankedIncome=" .. tostring(owned and owned.BankedIncome))
check("M: conservation: paid share + retained == banked (250 + 251 == 501)",
	owned ~= nil and 250 + owned.BankedIncome == 501)
check("M: remainder matches the single shared computation",
	owned ~= nil and owned.BankedIncome == 501 - Economy.StealRewardShare("wobble_waffleton", 501))

H.finish()
