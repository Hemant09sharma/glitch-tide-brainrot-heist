-- 13_share_rounding_conservation.luau — R2-7 E2 (positive): the
-- delivered BankedIncome remainder must be computed by the SAME single
-- formula as the paid reward (Economy.StealRewardShare), never by a
-- locally re-derived share. With an odd banked amount (501) the floor
-- matters: share = floor(501 * 0.5) = 250, reward = 250 + 50 = 300,
-- retained = 501 - 250 = 251, and paid + retained == banked exactly.
-- A ceil (or any second formula) would retain 250 and silently destroy
-- 1 coin of banked income. The negative control is
-- theft/mutant/07_mutant_control.luau (ConfirmDelivery re-derives the
-- share with math.ceil).
-- Run: lune run scripts/phase1-tests/theft/13_share_rounding_conservation.luau
local H = require("../harness")
local Economy = require("./shared/Economy")

local env = H.newEnv()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

check("share floors an odd banked amount (501 -> 250)",
	Economy.StealRewardShare("wobble_waffleton", 501) == 250,
	"share=" .. tostring(Economy.StealRewardShare("wobble_waffleton", 501)))
check("reward is share + rarity bonus (250 + 50 = 300)",
	Economy.StealReward("wobble_waffleton", 501) == 300,
	"reward=" .. tostring(Economy.StealReward("wobble_waffleton", 501)))

local pair = H.newPair(env, 963, 964)
-- Odd banked amount: the snapshot takes BankedIncome from the placed
-- copy, so set it before the steal.
H.findPlaced(pair.victimData, pair.targetId).BankedIncome = 501
H.steal(env, pair)
local coinsBefore = pair.thiefData.Coins
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("delivery succeeds with odd banked income", okDel == true,
	"status=" .. tostring(status))
check("delivery pays 300 coins (250 share + 50 bonus)",
	pair.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pair.thiefData.Coins))
local owned = H.findOwned(pair.thiefData, pair.targetId)
check("delivered record retains 251 (501 - 250, not 501 - 251)",
	owned ~= nil and owned.BankedIncome == 251,
	"BankedIncome=" .. tostring(owned and owned.BankedIncome))
check("conservation: paid share + retained == banked (250 + 251 == 501)",
	owned ~= nil and 250 + owned.BankedIncome == 501)
check("no income destroyed or created by the split",
	owned ~= nil and owned.BankedIncome == 501 - Economy.StealRewardShare("wobble_waffleton", 501))

H.finish()
