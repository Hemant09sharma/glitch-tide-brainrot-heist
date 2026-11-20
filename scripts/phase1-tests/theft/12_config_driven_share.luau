-- 12_config_driven_share.luau — R2-7 E1 (positive): the steal-reward
-- share must follow Config.StealRewardMultiplier, not a hard-coded
-- 0.5. Sets the multiplier to 0.25 and 0.75 and asserts both the
-- direct Economy.StealRewardShare computation and a real delivery
-- split follow the config (500 banked at 0.25 -> 125 paid, 375
-- retained; 501 banked at 0.75 -> 375 share). The negative control is
-- theft/mutant/06_mutant_control.luau (mutant Economy hard-codes 0.5).
-- Run: lune run scripts/phase1-tests/theft/12_config_driven_share.luau
local H = require("../harness")
local Config = require("./shared/Config")
local Economy = require("./shared/Economy")

local env = H.newEnv()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

check("config default multiplier is 0.5", Config.StealRewardMultiplier == 0.5,
	"multiplier=" .. tostring(Config.StealRewardMultiplier))

-- Direct computation at 0.25.
Config.StealRewardMultiplier = 0.25
check("share follows config 0.25 (500 banked -> 125)",
	Economy.StealRewardShare("wobble_waffleton", 500) == 125,
	"share=" .. tostring(Economy.StealRewardShare("wobble_waffleton", 500)))
check("reward follows config 0.25 (125 share + 50 bonus = 175)",
	Economy.StealReward("wobble_waffleton", 500) == 175,
	"reward=" .. tostring(Economy.StealReward("wobble_waffleton", 500)))

-- Direct computation at 0.75 (odd banked amount exercises the floor).
Config.StealRewardMultiplier = 0.75
check("share follows config 0.75 (501 banked -> floor(375.75) = 375)",
	Economy.StealRewardShare("wobble_waffleton", 501) == 375,
	"share=" .. tostring(Economy.StealRewardShare("wobble_waffleton", 501)))
check("reward follows config 0.75 (375 share + 50 bonus = 425)",
	Economy.StealReward("wobble_waffleton", 501) == 425,
	"reward=" .. tostring(Economy.StealReward("wobble_waffleton", 501)))

-- Real delivery at 0.25: 500 banked -> 175 coins paid, 375 retained.
Config.StealRewardMultiplier = 0.25
local pair = H.newPair(env, 961, 962)
H.steal(env, pair)
local coinsBefore = pair.thiefData.Coins
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("delivery succeeds at multiplier 0.25", okDel == true,
	"status=" .. tostring(status))
check("delivery pays the configured reward (175 coins, not 300)",
	pair.thiefData.Coins == coinsBefore + 175,
	"coins=" .. tostring(pair.thiefData.Coins))
local owned = H.findOwned(pair.thiefData, pair.targetId)
check("delivered record retains the configured remainder (375)",
	owned ~= nil and owned.BankedIncome == 375,
	"BankedIncome=" .. tostring(owned and owned.BankedIncome))
check("paid share + retained == banked (125 + 375 == 500)",
	owned ~= nil and 125 + owned.BankedIncome == 500)

Config.StealRewardMultiplier = 0.5
H.finish()
