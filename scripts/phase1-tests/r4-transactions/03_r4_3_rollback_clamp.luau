-- 03_r4_3_rollback_clamp.luau — R4-3 (P2, Test C):
-- The R3 rollback (AddCoins(-payable) after a failed save) clamped
-- at zero: a purchase that spent the provisionally credited reward
-- left the rollback short, and recovery then paid the reward a
-- second time — the player kept the spent value AND the reward.
-- The R4-3 fix reserves the credited amount (ReserveCoins) before
-- the verifying save, so no debit — direct or through any spending
-- route — can touch the reserved coins while the commit is open;
-- the rollback releases the reservation first, so the exact
-- subtraction cannot clamp.
--
-- Leg 1 (the over-spend window): thief starts at 100000 coins, a
-- 300-coin reward is credited (balance 100300, 300 reserved), a
-- 100200-coin debit is injected between the credit and the failing
-- save. The debit is affordable against the provisional balance
-- but NOT against the 100000 spendable coins. The reserved 300 must
-- survive: balance after the debit is 300, rollback restores exactly
-- 100000, recovery pays the 300 exactly once.
-- Leg 2 (legitimate spending is not blocked): the same commit with
-- a real 60000-coin EconomyService.BuyCharacter injected instead —
-- affordable against spendable coins, so it succeeds, and the final
-- accounting is exact (40300 coins + the character = 100000 + 300).
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService
local EconomyService = require("./services/EconomyService")
EconomyService.Init(DS)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- One-shot spend, every-attempt failure for one key: on the first
-- write, run `spendFn` FIRST (the concurrent spend, between the
-- reward credit and the failing save), then fail the write; fail
-- every later write for the key too, because DataService.SaveData
-- retries up to 3 attempts and a single failed attempt would let
-- the commit's save land on retry. Returns a restore function;
-- call it right after the delivery so later saves succeed.
local function failFirstSaveWithSpend(key, spendFn)
	local orig = store.SetAsync
	local spent = false
	store.SetAsync = function(self, k, value)
		if k == key then
			if not spent then
				spent = true
				spendFn()
			end
			error("injected SetAsync failure for " .. k)
		end
		return orig(self, k, value)
	end
	return function()
		store.SetAsync = orig
	end
end

-- --- Leg 1: the over-spend window -----------------------------------
local pair = P.newLoadedPair(env, 9421, 9422)
H.steal(env, pair)
local thiefKey = P.mainKey(pair.thief.UserId)
local balanceAfterSpend = nil
local reservedDuringSpend = nil
local restore1 = failFirstSaveWithSpend(thiefKey, function()
	reservedDuringSpend = DS.GetReservedCoins(pair.thief)
	-- A 100200 debit: affordable against the provisional 100300,
	-- NOT against the 100000 spendable coins.
	DS.AddCoins(pair.thief, -100200)
	balanceAfterSpend = tonumber(DS.GetData(pair.thief).Coins) or 0
end)
local okDel1, status1 = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
restore1()
check("leg 1: delivery reports the reward pending", okDel1 == true and status1 == "reward_pending", "status=" .. tostring(status1))
check("leg 1: the reservation held 300 coins while the commit was open",
	reservedDuringSpend == 300, "reserved=" .. tostring(reservedDuringSpend))
check("leg 1: the over-spend could not touch the reserved coins (balance 300, not 100)",
	balanceAfterSpend == 300, "balanceAfterSpend=" .. tostring(balanceAfterSpend))
check("leg 1: rollback removed exactly the reward (balance 0: the 100000 spendable was spent, the 300 reserved was not)",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 0,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
check("leg 1: the reservation was released by the rollback",
	DS.GetReservedCoins(pair.thief) == 0)
check("leg 1: the reward stayed pending for recovery",
	DS.GetData(pair.thief).PendingRewards[pair.targetId] ~= nil)
check("leg 1: no processed marker survived the failed commit",
	DS.GetData(pair.thief).ProcessedRewardTxns ~= nil
		and next(DS.GetData(pair.thief).ProcessedRewardTxns) == nil)
local paid1, total1 = env.raid.RecoverPendingRewards(pair.thief)
check("leg 1: recovery pays the reward exactly once", paid1 == 1 and total1 == 300)
check("leg 1: final balance is original minus spendable spent, plus one reward (300)",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 300,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
local paid1b, total1b = env.raid.RecoverPendingRewards(pair.thief)
check("leg 1: repeated recovery pays nothing more", paid1b == 0 and total1b == 0)

-- --- Leg 2: a legitimate purchase during the commit ------------------
local pair2 = P.newLoadedPair(env, 9423, 9424)
H.steal(env, pair2)
local thiefKey2 = P.mainKey(pair2.thief.UserId)
local buyOk, buyErr = nil, nil
local balanceAfterBuy = nil
local restore2 = failFirstSaveWithSpend(thiefKey2, function()
	-- A REAL spending route: 60000 coins, affordable against the
	-- 100000 spendable coins, so it must succeed even while the
	-- 300-coin reward commit is open.
	buyOk, buyErr = EconomyService.BuyCharacter(pair2.thief, "zap_zucchini")
	balanceAfterBuy = tonumber(DS.GetData(pair2.thief).Coins) or 0
end)
local okDel2, status2 = env.raid.ConfirmDelivery(pair2.thief, pair2.targetId)
restore2()
check("leg 2: delivery reports the reward pending", okDel2 == true and status2 == "reward_pending", "status=" .. tostring(status2))
check("leg 2: the affordable purchase succeeded during the open commit",
	buyOk == true, "err=" .. tostring(buyErr))
check("leg 2: balance after the purchase is 40300 (100300 - 60000)",
	balanceAfterBuy == 40300, "balanceAfterBuy=" .. tostring(balanceAfterBuy))
check("leg 2: rollback restored the pre-reward balance minus the purchase (40000)",
	(tonumber(DS.GetData(pair2.thief).Coins) or 0) == 40000,
	"coins=" .. tostring(DS.GetData(pair2.thief).Coins))
check("leg 2: the purchased character was kept (not rolled back)",
	DS.HasCharacter(pair2.thief, "zap_zucchini") == true)
check("leg 2: the reward stayed pending for recovery",
	DS.GetData(pair2.thief).PendingRewards[pair2.targetId] ~= nil)
local paid2, total2 = env.raid.RecoverPendingRewards(pair2.thief)
check("leg 2: recovery pays the reward exactly once", paid2 == 1 and total2 == 300)
check("leg 2: final accounting is exact (40300 coins + 60000 character = 100000 + 300)",
	(tonumber(DS.GetData(pair2.thief).Coins) or 0) == 40300
		and DS.HasCharacter(pair2.thief, "zap_zucchini") == true,
	"coins=" .. tostring(DS.GetData(pair2.thief).Coins))
local paid2b, total2b = env.raid.RecoverPendingRewards(pair2.thief)
check("leg 2: repeated recovery pays nothing more", paid2b == 0 and total2b == 0)

H.finish()
