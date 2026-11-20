-- 06_mutant_control.luau — R2 E1 negative control: the SAME
-- config-driven-share assertions as theft/12_config_driven_share.luau,
-- run against the MUTANT Economy (StealRewardShare hard-codes 0.5
-- instead of Config.StealRewardMultiplier, built by
-- mutant/make_mutant.sh into mutant/economy/). This file is EXPECTED
-- TO FAIL: the mutant must ignore the configured multiplier, which
-- proves the test detects a hard-coded share.
--
-- The mutant RaidService is loaded from mutant/economy/services/ so
-- its `require("../shared/Economy")` resolves to the mutant Economy
-- in mutant/economy/shared/; the multiplier is set on that same
-- module's Config (require "./economy/shared/Config"), which Lune
-- resolves to the same file the mutant Economy loaded.
-- Never run under theft/run_all.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")
local Config = require("./economy/shared/Config")
local Economy = require("./economy/shared/Economy")

local env = H.newEnv({ raidPath = "./theft/mutant/economy/services/RaidService" })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

Config.StealRewardMultiplier = 0.25
check("M: share follows config 0.25 (500 banked -> 125)",
	Economy.StealRewardShare("wobble_waffleton", 500) == 125,
	"share=" .. tostring(Economy.StealRewardShare("wobble_waffleton", 500)))
check("M: reward follows config 0.25 (125 share + 50 bonus = 175)",
	Economy.StealReward("wobble_waffleton", 500) == 175,
	"reward=" .. tostring(Economy.StealReward("wobble_waffleton", 500)))
Config.StealRewardMultiplier = 0.75
check("M: share follows config 0.75 (501 banked -> 375)",
	Economy.StealRewardShare("wobble_waffleton", 501) == 375,
	"share=" .. tostring(Economy.StealRewardShare("wobble_waffleton", 501)))

Config.StealRewardMultiplier = 0.25
local pair = H.newPair(env, 981, 982)
H.steal(env, pair)
local coinsBefore = pair.thiefData.Coins
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("M: delivery succeeds at multiplier 0.25", okDel == true,
	"status=" .. tostring(status))
check("M: delivery pays the configured reward (175 coins, not 300)",
	pair.thiefData.Coins == coinsBefore + 175,
	"coins=" .. tostring(pair.thiefData.Coins))
local owned = H.findOwned(pair.thiefData, pair.targetId)
check("M: delivered record retains the configured remainder (375)",
	owned ~= nil and owned.BankedIncome == 375,
	"BankedIncome=" .. tostring(owned and owned.BankedIncome))

Config.StealRewardMultiplier = 0.5
H.finish()
