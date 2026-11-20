-- m01_rebirth_prestige_old.luau — R5-6 NEGATIVE CONTROL.
--
-- Loads the PRE-FIX ProgressionService (mutant/ProgressionServiceOld,
-- built from git HEAD by make_mutant.sh: the old direct reset
-- `data.Coins = Config.StartingCoins or 100` and the raw-balance
-- requirement check) and asserts the OLD bad outcomes. Every check
-- here must PASS against the old code: a control passing proves the
-- fixed test (06_rebirth_prestige.luau) discriminates — the same
-- scenarios fail on the old code and pass on the fixed code.
-- The old code's failures, leg by leg:
--   L1/L3 (failing save): the rollback subtracts 300 from a balance
--     of 100 and clamps at 0 — the reset's StartingCoins are eaten,
--     and the retry pays the reward on top of a zeroed balance
--     (final 300, not 400). At hook time the reservation (300) is
--     larger than the balance (100): the R4-3 invariant
--     balance >= reserved is violated.
--   L2 (succeeding save): the 300-coin reward is wiped outright
--     (balance 100, stored 100, recovery pays 0).
--   L4: the old raw-balance check ACCEPTS a rebirth with only 99800
--     spendable coins (100100 raw), then the rollback zeroes it.
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant.sh
local R = require("../../r4-transactions/r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService
local Prog = require("./ProgressionServiceOld")
Prog.Init(DS)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local REWARD = 300
local STARTING = 100

local IDS10 = {
	"wobble_waffleton", "turbo_turnip", "bloop_bloomington",
	"crumb_comet", "noodle_nebula", "toast_ghost", "disco_dumpling",
	"captain_picklebyte", "moon_mochi", "giga_gumball",
}
local IDS15 = {
	"wobble_waffleton", "turbo_turnip", "bloop_bloomington",
	"crumb_comet", "noodle_nebula", "toast_ghost", "disco_dumpling",
	"captain_picklebyte", "moon_mochi", "giga_gumball",
	"miso_mothership", "puddle_professor", "springy_spaghetti",
	"zap_zucchini", "cosmic_cupcake",
}

local function coinsOf(player)
	return tonumber(DS.GetData(player).Coins) or 0
end

local function makeThief(thiefId, victimId, opts)
	opts = opts or {}
	local pair = P.newLoadedPair(env, thiefId, victimId)
	local data = DS.GetData(pair.thief)
	data.Level = opts.level or 25
	data.Coins = opts.coins or 100000
	data.Rebirths = opts.rebirths or 0
	data.Unlocked = opts.unlocked or IDS10
	H.steal(env, pair)
	return pair
end

local function failSaveWithHook(key, hookFn)
	local orig = store.SetAsync
	local ran = false
	store.SetAsync = function(self, k, value)
		if k == key then
			if not ran then
				ran = true
				hookFn()
			end
			error("injected SetAsync failure for " .. k)
		end
		return orig(self, k, value)
	end
	return function()
		store.SetAsync = orig
	end
end

local function passSaveWithHook(key, hookFn)
	local orig = store.SetAsync
	local ran = false
	store.SetAsync = function(self, k, value)
		if k == key and not ran then
			ran = true
			hookFn()
		end
		return orig(self, k, value)
	end
	return function()
		store.SetAsync = orig
	end
end

-- --- L1 (old): Rebirth during a FAILING reward save -----------------
local pair1 = makeThief(9511, 9512, { coins = 100000 })
local thiefKey1 = P.mainKey(9511)
local hookReserved1, hookBalance1 = nil, nil
local postResetReserved1, postResetBalance1 = nil, nil
local rebirthOk1 = nil
local restore1 = failSaveWithHook(thiefKey1, function()
	hookReserved1 = DS.GetReservedCoins(pair1.thief)
	hookBalance1 = coinsOf(pair1.thief)
	rebirthOk1 = Prog.Rebirth(pair1.thief)
	postResetReserved1 = DS.GetReservedCoins(pair1.thief)
	postResetBalance1 = coinsOf(pair1.thief)
end)
local okDel1, status1 = env.raid.ConfirmDelivery(pair1.thief, pair1.targetId)
restore1()
check("OLD L1: delivery reports the reward pending", okDel1 == true and status1 == "reward_pending")
check("OLD L1: hook ran inside the commit window (300 reserved, 100300)",
	hookReserved1 == REWARD and hookBalance1 == 100300)
check("OLD L1: old rebirth succeeded", rebirthOk1 == true)
check("OLD L1: after the old reset the reservation (300) EXCEEDS the balance (100)",
	postResetReserved1 == REWARD and postResetBalance1 == STARTING,
	"reserved=" .. tostring(postResetReserved1) .. " balance=" .. tostring(postResetBalance1))
check("OLD L1: rollback ate the StartingCoins (balance 0, not 100)",
	coinsOf(pair1.thief) == 0, "coins=" .. tostring(coinsOf(pair1.thief)))
local paid1, total1 = env.raid.RecoverPendingRewards(pair1.thief)
check("OLD L1: recovery still pays the reward once", paid1 == 1 and total1 == REWARD)
check("OLD L1: final balance is 300, not 400 — the StartingCoins were lost",
	coinsOf(pair1.thief) == REWARD, "coins=" .. tostring(coinsOf(pair1.thief)))
DS.SaveData(pair1.thief)
local stored1 = store:peek(thiefKey1)
check("OLD L1: stored balance after recovery is 300, not 400",
	stored1 ~= nil and tonumber(stored1.Coins) == REWARD,
	"stored=" .. tostring(stored1 and stored1.Coins))

-- --- L2 (old): Rebirth during a SUCCEEDING reward save (the wipe) ---
local pair2 = makeThief(9521, 9522, { coins = 100000 })
local thiefKey2 = P.mainKey(9521)
local rebirthOk2 = nil
local restore2 = passSaveWithHook(thiefKey2, function()
	rebirthOk2 = Prog.Rebirth(pair2.thief)
end)
local okDel2, status2 = env.raid.ConfirmDelivery(pair2.thief, pair2.targetId)
restore2()
check("OLD L2: delivery reports paid (status nil)", okDel2 == true and status2 == nil)
check("OLD L2: old rebirth succeeded", rebirthOk2 == true)
check("OLD L2: the reward was WIPED by the reset (balance 100, not 400)",
	coinsOf(pair2.thief) == STARTING, "coins=" .. tostring(coinsOf(pair2.thief)))
local paid2, total2 = env.raid.RecoverPendingRewards(pair2.thief)
check("OLD L2: recovery pays nothing — the reward is gone for good",
	paid2 == 0 and total2 == 0)
DS.SaveData(pair2.thief)
local stored2 = store:peek(thiefKey2)
check("OLD L2: stored balance is 100 — the wipe is durable",
	stored2 ~= nil and tonumber(stored2.Coins) == STARTING,
	"stored=" .. tostring(stored2 and stored2.Coins))

-- --- L3 (old): Prestige during a FAILING reward save ----------------
local pair3 = makeThief(9531, 9532, { coins = 250000, rebirths = 10, unlocked = IDS15 })
local prestigeOk3 = nil
local restore3 = failSaveWithHook(P.mainKey(9531), function()
	prestigeOk3 = Prog.Prestige(pair3.thief)
end)
local okDel3, status3 = env.raid.ConfirmDelivery(pair3.thief, pair3.targetId)
restore3()
check("OLD L3: delivery reports the reward pending", okDel3 == true and status3 == "reward_pending")
check("OLD L3: old prestige succeeded", prestigeOk3 == true)
check("OLD L3: rollback ate the StartingCoins (balance 0, not 100)",
	coinsOf(pair3.thief) == 0, "coins=" .. tostring(coinsOf(pair3.thief)))
local paid3, total3 = env.raid.RecoverPendingRewards(pair3.thief)
check("OLD L3: recovery still pays the reward once", paid3 == 1 and total3 == REWARD)
check("OLD L3: final balance is 300, not 400 — the StartingCoins were lost",
	coinsOf(pair3.thief) == REWARD, "coins=" .. tostring(coinsOf(pair3.thief)))

-- --- L4 (old): Rebirth ACCEPTED on unspendable coins ---------------
local pair4 = makeThief(9541, 9542, { coins = 99800 })
local rebirthOk4 = nil
local restore4 = failSaveWithHook(P.mainKey(9541), function()
	rebirthOk4 = Prog.Rebirth(pair4.thief)
end)
local okDel4, status4 = env.raid.ConfirmDelivery(pair4.thief, pair4.targetId)
restore4()
check("OLD L4: delivery reports the reward pending", okDel4 == true and status4 == "reward_pending")
check("OLD L4: old rebirth was ACCEPTED on 99800 spendable (raw 100100 >= 100000)",
	rebirthOk4 == true)
check("OLD L4: a rebirth happened", (tonumber(DS.GetData(pair4.thief).Rebirths) or 0) == 1)
check("OLD L4: rollback zeroed the balance (0, not 99800)",
	coinsOf(pair4.thief) == 0, "coins=" .. tostring(coinsOf(pair4.thief)))
local paid4, total4 = env.raid.RecoverPendingRewards(pair4.thief)
check("OLD L4: recovery pays the reward once", paid4 == 1 and total4 == REWARD)
check("OLD L4: final balance is 300, not 100100 — the player lost 99800",
	coinsOf(pair4.thief) == REWARD, "coins=" .. tostring(coinsOf(pair4.thief)))

-- --- L5 (old): the legitimate economy was already right ------------
local p5 = R.newLoadedPlayer(env, 9551, 100000)
local d5 = DS.GetData(p5)
d5.Level = 25
d5.Unlocked = IDS10
local ok5, r5 = Prog.Rebirth(p5)
check("OLD L5: plain rebirth succeeds with the old code too", ok5 == true and r5 == 1)
check("OLD L5: plain rebirth resets coins to 100", coinsOf(p5) == STARTING)

H.finish()
