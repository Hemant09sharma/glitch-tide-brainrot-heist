-- 06_rebirth_prestige.luau — R5-6 (P2): reservation-aware Rebirth
-- and Prestige.
--
-- THE DEFECT (pre-fix ProgressionService): Rebirth and Prestige reset
-- coins with a direct assignment, `data.Coins = Config.StartingCoins
-- or 100`, with no regard for the R4-3 coin reservation. A pending
-- steal-reward commit (RaidService.commitPendingPayment) credits the
-- reward and reserves it (DataService.ReserveCoins) for the duration
-- of its verified save. If Rebirth/Prestige fires inside that save
-- window, the reset wipes the reserved reward coins out of the
-- balance while the reservation record still holds them:
--   * save SUCCEEDS -> the reservation is released, the commit
--     reports paid, and the 300-coin reward is simply gone (wiped);
--   * save FAILS -> the rollback releases the reservation and then
--     subtracts exactly 300 from a balance of 100, which clamps at
--     0: the rollback eats the reset's StartingCoins, the entry is
--     restored, and the retry pays the reward on top of a zeroed
--     balance (final 300 instead of StartingCoins + 300 = 400).
-- The same direct reset also lets a player buy a rebirth with coins
-- that are not spendable yet: a 100100 balance with 300 reserved
-- passes the raw 100000-coin requirement even though only 99800 is
-- spendable.
--
-- THE FIX: the reset lands on StartingCoins PLUS every reserved coin
-- (so a later commit success keeps the reward and a later rollback
-- subtracts exactly), and the coin requirement is judged on
-- spendable coins, like every other R4-3 spending route. Costs,
-- rewards and multipliers are unchanged.
--
-- Leg 1: Rebirth during a FAILING reward save -> rollback exact,
--   recovery pays once, final = 100 + 300.
-- Leg 2: Rebirth during a SUCCEEDING reward save -> the reward
--   survives the reset (400, not 100), recovery pays nothing more.
-- Leg 3: Prestige during a FAILING reward save -> same accounting
--   as leg 1, prestige economy intact.
-- Leg 4: Rebirth REFUSED while only reserved coins push the balance
--   over the 100000 requirement (spendable 99800 < 100000).
-- Leg 5: legitimate economy unchanged with no reservation open:
--   plain Rebirth / Prestige costs, rewards, slots, multipliers,
--   and the requirement gates.
--
-- The test loads the REAL DataService + RaidService (via the R4 env)
-- and the REAL ProgressionService (services/ copy, refreshed from
-- src/ by refresh_06.sh), with a stubbed DataStore API. The reward
-- save window is entered exactly as in production: the Rebirth /
-- Prestige call runs inside a SetAsync hook on the thief's main key,
-- i.e. after the reward credit + reservation and before the save
-- lands — the same injection point the R4-3 test 03 uses.
-- Run: bash scripts/phase1-tests/r5-transactions/run_06.sh
local R = require("../r4-transactions/r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService
local Prog = require("./services/ProgressionService")
Prog.Init(DS)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local REWARD = 300 -- steal reward for the fixture (500 banked income)
local STARTING = 100 -- Config.StartingCoins

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

local function reservedOf(player)
	return DS.GetReservedCoins(player)
end

local function noProcessedMarkers(player)
	local markers = DS.GetData(player).ProcessedRewardTxns
	return markers ~= nil and next(markers) == nil
end

local function approx(a, b)
	return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 0.000001
end

-- makeThief(thiefId, victimId, opts): a steal-fixture pair whose
-- thief is rebirth/prestige-ready (level 25, the given coins /
-- rebirths / distinct Brainrots), with the theft already staged
-- (H.steal). The LIVE data is mutated after LoadData, before the
-- steal, so the fixture data is exactly what the services see.
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

-- failSaveWithHook(key, hookFn): fail EVERY SetAsync for `key`
-- (SaveData retries 3 attempts, so a single failure would let the
-- commit land on retry); run `hookFn` once, on the first attempt —
-- i.e. inside the reward-save window, after the credit + reservation.
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

-- passSaveWithHook(key, hookFn): run `hookFn` once, on the first
-- SetAsync for `key`, then let the write land — the commit's save
-- succeeds after the Rebirth/Prestige ran inside its window.
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

-- --- Leg 1: Rebirth during a FAILING reward save --------------------
local pair1 = makeThief(9511, 9512, { coins = 100000 })
local thiefKey1 = P.mainKey(9511)
local hookReserved1, hookBalance1, rebirthOk1, rebirthErr1 = nil, nil, nil, nil
local restore1 = failSaveWithHook(thiefKey1, function()
	hookReserved1 = reservedOf(pair1.thief)
	hookBalance1 = coinsOf(pair1.thief)
	rebirthOk1, rebirthErr1 = Prog.Rebirth(pair1.thief)
end)
local okDel1, status1 = env.raid.ConfirmDelivery(pair1.thief, pair1.targetId)
restore1()
check("L1: delivery reports the reward pending", okDel1 == true and status1 == "reward_pending",
	"status=" .. tostring(status1))
check("L1: hook ran inside the commit window (300 reserved, balance 100300)",
	hookReserved1 == REWARD and hookBalance1 == 100300,
	"reserved=" .. tostring(hookReserved1) .. " balance=" .. tostring(hookBalance1))
check("L1: rebirth succeeded on exactly-100000 spendable coins", rebirthOk1 == true,
	"err=" .. tostring(rebirthErr1))
check("L1: rollback left exactly StartingCoins (100), not 0",
	coinsOf(pair1.thief) == STARTING, "coins=" .. tostring(coinsOf(pair1.thief)))
check("L1: the reservation was released by the rollback", reservedOf(pair1.thief) == 0)
check("L1: the reward stayed pending for recovery",
	DS.GetData(pair1.thief).PendingRewards[pair1.targetId] ~= nil)
check("L1: no processed marker survived the failed commit", noProcessedMarkers(pair1.thief))
check("L1: rebirth economy — count 1, +25 gems, level 1, +2 slots",
	(tonumber(DS.GetData(pair1.thief).Rebirths) or 0) == 1
		and (tonumber(DS.GetData(pair1.thief).Gems) or 0) == 25
		and (tonumber(DS.GetData(pair1.thief).Level) or 0) == 1
		and (tonumber(DS.GetData(pair1.thief).BaseSlots) or 0) == 6,
	"rebirths=" .. tostring(DS.GetData(pair1.thief).Rebirths)
		.. " gems=" .. tostring(DS.GetData(pair1.thief).Gems)
		.. " slots=" .. tostring(DS.GetData(pair1.thief).BaseSlots))
check("L1: rebirth kept the collection (10 distinct owned)",
	#(DS.GetData(pair1.thief).Unlocked or {}) == 10)
DS.SaveData(pair1.thief)
local stored1 = store:peek(thiefKey1)
check("L1: stored balance is 100 after the rollback save",
	stored1 ~= nil and tonumber(stored1.Coins) == STARTING,
	"stored=" .. tostring(stored1 and stored1.Coins))
check("L1: stored entry still pending",
	stored1 ~= nil and stored1.PendingRewards ~= nil
		and stored1.PendingRewards[pair1.targetId] ~= nil)
local paid1, total1 = env.raid.RecoverPendingRewards(pair1.thief)
check("L1: recovery pays the reward exactly once", paid1 == 1 and total1 == REWARD,
	"paid=" .. tostring(paid1) .. " total=" .. tostring(total1))
check("L1: final balance is StartingCoins + one reward (400)",
	coinsOf(pair1.thief) == STARTING + REWARD, "coins=" .. tostring(coinsOf(pair1.thief)))
local paid1b, total1b = env.raid.RecoverPendingRewards(pair1.thief)
check("L1: repeated recovery pays nothing more", paid1b == 0 and total1b == 0)
check("L1: final balance still 400 after repeated recovery",
	coinsOf(pair1.thief) == STARTING + REWARD)
check("L1: income multiplier is 1.10 after one rebirth",
	approx(Prog.GetIncomeMultiplier(pair1.thief), 1.10),
	"mult=" .. tostring(Prog.GetIncomeMultiplier(pair1.thief)))

-- --- Leg 2: Rebirth during a SUCCEEDING reward save (the wipe) -----
local pair2 = makeThief(9521, 9522, { coins = 100000 })
local thiefKey2 = P.mainKey(9521)
local hookReserved2, hookBalance2, rebirthOk2, rebirthErr2 = nil, nil, nil, nil
local restore2 = passSaveWithHook(thiefKey2, function()
	hookReserved2 = reservedOf(pair2.thief)
	hookBalance2 = coinsOf(pair2.thief)
	rebirthOk2, rebirthErr2 = Prog.Rebirth(pair2.thief)
end)
local okDel2, status2 = env.raid.ConfirmDelivery(pair2.thief, pair2.targetId)
restore2()
check("L2: delivery reports paid (status nil)", okDel2 == true and status2 == nil,
	"status=" .. tostring(status2))
check("L2: hook ran inside the commit window (300 reserved, balance 100300)",
	hookReserved2 == REWARD and hookBalance2 == 100300,
	"reserved=" .. tostring(hookReserved2) .. " balance=" .. tostring(hookBalance2))
check("L2: rebirth succeeded", rebirthOk2 == true, "err=" .. tostring(rebirthErr2))
check("L2: the reserved reward SURVIVED the reset (400, not 100)",
	coinsOf(pair2.thief) == STARTING + REWARD, "coins=" .. tostring(coinsOf(pair2.thief)))
check("L2: the reservation was released on commit success", reservedOf(pair2.thief) == 0)
check("L2: the pending entry is gone",
	DS.GetData(pair2.thief).PendingRewards[pair2.targetId] == nil)
check("L2: the processed marker was kept", not noProcessedMarkers(pair2.thief))
local paid2, total2 = env.raid.RecoverPendingRewards(pair2.thief)
check("L2: recovery pays nothing more (no overpay)", paid2 == 0 and total2 == 0)
check("L2: balance still 400 after recovery", coinsOf(pair2.thief) == STARTING + REWARD)
DS.SaveData(pair2.thief)
local stored2 = store:peek(thiefKey2)
check("L2: stored balance is 400",
	stored2 ~= nil and tonumber(stored2.Coins) == STARTING + REWARD,
	"stored=" .. tostring(stored2 and stored2.Coins))
check("L2: stored entry gone",
	stored2 ~= nil
		and (stored2.PendingRewards == nil or stored2.PendingRewards[pair2.targetId] == nil))

-- --- Leg 3: Prestige during a FAILING reward save -------------------
local pair3 = makeThief(9531, 9532, { coins = 250000, rebirths = 10, unlocked = IDS15 })
local thiefKey3 = P.mainKey(9531)
local hookReserved3, hookBalance3, prestigeOk3, prestigeErr3 = nil, nil, nil, nil
local restore3 = failSaveWithHook(thiefKey3, function()
	hookReserved3 = reservedOf(pair3.thief)
	hookBalance3 = coinsOf(pair3.thief)
	prestigeOk3, prestigeErr3 = Prog.Prestige(pair3.thief)
end)
local okDel3, status3 = env.raid.ConfirmDelivery(pair3.thief, pair3.targetId)
restore3()
check("L3: delivery reports the reward pending", okDel3 == true and status3 == "reward_pending",
	"status=" .. tostring(status3))
check("L3: hook ran inside the commit window (300 reserved, balance 250300)",
	hookReserved3 == REWARD and hookBalance3 == 250300,
	"reserved=" .. tostring(hookReserved3) .. " balance=" .. tostring(hookBalance3))
check("L3: prestige succeeded on exactly-250000 spendable coins", prestigeOk3 == true,
	"err=" .. tostring(prestigeErr3))
check("L3: rollback left exactly StartingCoins (100), not 0",
	coinsOf(pair3.thief) == STARTING, "coins=" .. tostring(coinsOf(pair3.thief)))
check("L3: the reservation was released by the rollback", reservedOf(pair3.thief) == 0)
check("L3: the reward stayed pending for recovery",
	DS.GetData(pair3.thief).PendingRewards[pair3.targetId] ~= nil)
check("L3: no processed marker survived the failed commit", noProcessedMarkers(pair3.thief))
check("L3: prestige economy — rank 1, rebirths 0, +50 gems, level 1, slots 4",
	(tonumber(DS.GetData(pair3.thief).Prestige) or 0) == 1
		and (tonumber(DS.GetData(pair3.thief).Rebirths) or 0) == 0
		and (tonumber(DS.GetData(pair3.thief).Gems) or 0) == 50
		and (tonumber(DS.GetData(pair3.thief).Level) or 0) == 1
		and (tonumber(DS.GetData(pair3.thief).BaseSlots) or 0) == 4,
	"prestige=" .. tostring(DS.GetData(pair3.thief).Prestige)
		.. " rebirths=" .. tostring(DS.GetData(pair3.thief).Rebirths)
		.. " gems=" .. tostring(DS.GetData(pair3.thief).Gems)
		.. " slots=" .. tostring(DS.GetData(pair3.thief).BaseSlots))
check("L3: prestige kept the collection (15 distinct owned)",
	#(DS.GetData(pair3.thief).Unlocked or {}) == 15)
DS.SaveData(pair3.thief)
local stored3 = store:peek(thiefKey3)
check("L3: stored balance is 100 after the rollback save",
	stored3 ~= nil and tonumber(stored3.Coins) == STARTING,
	"stored=" .. tostring(stored3 and stored3.Coins))
local paid3, total3 = env.raid.RecoverPendingRewards(pair3.thief)
check("L3: recovery pays the reward exactly once", paid3 == 1 and total3 == REWARD,
	"paid=" .. tostring(paid3) .. " total=" .. tostring(total3))
check("L3: final balance is StartingCoins + one reward (400)",
	coinsOf(pair3.thief) == STARTING + REWARD, "coins=" .. tostring(coinsOf(pair3.thief)))
local paid3b, total3b = env.raid.RecoverPendingRewards(pair3.thief)
check("L3: repeated recovery pays nothing more", paid3b == 0 and total3b == 0)
check("L3: income multiplier is 1.05 after one prestige rank",
	approx(Prog.GetIncomeMultiplier(pair3.thief), 1.05),
	"mult=" .. tostring(Prog.GetIncomeMultiplier(pair3.thief)))

-- --- Leg 4: Rebirth refused when only reserved coins push it over --
local pair4 = makeThief(9541, 9542, { coins = 99800 })
local thiefKey4 = P.mainKey(9541)
local hookReserved4, hookBalance4, rebirthOk4, rebirthErr4 = nil, nil, nil, nil
local restore4 = failSaveWithHook(thiefKey4, function()
	hookReserved4 = reservedOf(pair4.thief)
	hookBalance4 = coinsOf(pair4.thief)
	rebirthOk4, rebirthErr4 = Prog.Rebirth(pair4.thief)
end)
local okDel4, status4 = env.raid.ConfirmDelivery(pair4.thief, pair4.targetId)
restore4()
check("L4: delivery reports the reward pending", okDel4 == true and status4 == "reward_pending",
	"status=" .. tostring(status4))
check("L4: hook ran inside the commit window (300 reserved, balance 100100)",
	hookReserved4 == REWARD and hookBalance4 == 100100,
	"reserved=" .. tostring(hookReserved4) .. " balance=" .. tostring(hookBalance4))
check("L4: rebirth REFUSED — spendable 99800 < 100000 (reserved coins are not spendable)",
	rebirthOk4 == false, "err=" .. tostring(rebirthErr4))
check("L4: no rebirth happened", (tonumber(DS.GetData(pair4.thief).Rebirths) or 0) == 0)
check("L4: rollback restored the pre-reward balance (99800)",
	coinsOf(pair4.thief) == 99800, "coins=" .. tostring(coinsOf(pair4.thief)))
check("L4: the reservation was released by the rollback", reservedOf(pair4.thief) == 0)
check("L4: the reward stayed pending for recovery",
	DS.GetData(pair4.thief).PendingRewards[pair4.targetId] ~= nil)
local paid4, total4 = env.raid.RecoverPendingRewards(pair4.thief)
check("L4: recovery pays the reward exactly once", paid4 == 1 and total4 == REWARD)
check("L4: final balance is 99800 + one reward (100100)",
	coinsOf(pair4.thief) == 99800 + REWARD, "coins=" .. tostring(coinsOf(pair4.thief)))
local paid4b, total4b = env.raid.RecoverPendingRewards(pair4.thief)
check("L4: repeated recovery pays nothing more", paid4b == 0 and total4b == 0)

-- --- Leg 5: legitimate economy unchanged (no reservation open) -----
local function readyPlayer(userId, coins, level, rebirths, unlocked)
	local player = R.newLoadedPlayer(env, userId, coins)
	local data = DS.GetData(player)
	data.Level = level
	data.Rebirths = rebirths
	data.Unlocked = unlocked
	return player
end

local p5 = readyPlayer(9551, 100000, 25, 0, IDS10)
local ok5, r5 = Prog.Rebirth(p5)
check("L5: plain rebirth succeeds", ok5 == true and r5 == 1, "err=" .. tostring(r5))
check("L5: plain rebirth resets coins to StartingCoins (100)", coinsOf(p5) == STARTING,
	"coins=" .. tostring(coinsOf(p5)))
check("L5: plain rebirth grants +25 gems", (tonumber(DS.GetData(p5).Gems) or 0) == 25)
check("L5: plain rebirth resets level 1 / XP 0",
	(tonumber(DS.GetData(p5).Level) or 0) == 1 and (tonumber(DS.GetData(p5).XP) or 0) == 0)
check("L5: plain rebirth grants +2 base slots (6)",
	(tonumber(DS.GetData(p5).BaseSlots) or 0) == 6)
check("L5: plain rebirth keeps the collection (10 distinct)",
	#(DS.GetData(p5).Unlocked or {}) == 10)
check("L5: plain rebirth income multiplier is 1.10",
	approx(Prog.GetIncomeMultiplier(p5), 1.10))

local p5b = readyPlayer(9552, 99999, 25, 0, IDS10)
local ok5b, err5b = Prog.Rebirth(p5b)
check("L5: rebirth still refused below 100000 coins", ok5b == false,
	"err=" .. tostring(err5b))
check("L5: refused rebirth changed nothing (coins still 99999)",
	coinsOf(p5b) == 99999 and (tonumber(DS.GetData(p5b).Rebirths) or 0) == 0)

local p5c = readyPlayer(9553, 100000, 24, 0, IDS10)
local ok5c, _ = Prog.Rebirth(p5c)
check("L5: rebirth still refused below level 25", ok5c == false)

local p5d = readyPlayer(9554, 100000, 25, 0, { "wobble_waffleton", "turbo_turnip", "bloop_bloomington", "crumb_comet", "noodle_nebula", "toast_ghost", "disco_dumpling", "captain_picklebyte", "moon_mochi" })
local ok5d, _ = Prog.Rebirth(p5d)
check("L5: rebirth still refused below 10 distinct Brainrots", ok5d == false)

local p6 = readyPlayer(9555, 250000, 25, 10, IDS15)
local ok6, pr6 = Prog.Prestige(p6)
check("L5: plain prestige succeeds", ok6 == true and pr6 == 1, "err=" .. tostring(pr6))
check("L5: plain prestige resets coins to StartingCoins (100)", coinsOf(p6) == STARTING,
	"coins=" .. tostring(coinsOf(p6)))
check("L5: plain prestige grants +50 gems", (tonumber(DS.GetData(p6).Gems) or 0) == 50)
check("L5: plain prestige consumes the 10 rebirths (0 left)",
	(tonumber(DS.GetData(p6).Rebirths) or 0) == 0)
check("L5: plain prestige resets base slots to 4",
	(tonumber(DS.GetData(p6).BaseSlots) or 0) == 4)
check("L5: plain prestige keeps the collection (15 distinct)",
	#(DS.GetData(p6).Unlocked or {}) == 15)
check("L5: plain prestige income multiplier is 1.05",
	approx(Prog.GetIncomeMultiplier(p6), 1.05))

local p6b = readyPlayer(9556, 250000, 25, 9, IDS15)
local ok6b, _ = Prog.Prestige(p6b)
check("L5: prestige still refused below 10 rebirths", ok6b == false)

H.finish()
