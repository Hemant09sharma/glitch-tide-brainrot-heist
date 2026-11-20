-- m03_r4_3_old_logic.luau — NEGATIVE CONTROL for R4-3 (Test C):
-- Leg 1 of test 03, run against the R3 mutant RaidService (no coin
-- reservation). The control PASSES when the OLD bad outcome is
-- observed: the injected 100200-coin debit spends the provisionally
-- credited reward (balance 100, not the reserved 300), the rollback
-- clamps at zero, and recovery then pays the reward again — the
-- player keeps 100200 of spent value plus the 300 reward, i.e.
-- 200 coins overpaid against the correct single-payment outcome.
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local R = require("../r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv({ raidPath = "./mutant/RaidServiceR3" })
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = P.newLoadedPair(env, 9621, 9622)
H.steal(env, pair)
local thiefKey = P.mainKey(pair.thief.UserId)
local balanceAfterSpend = nil
local orig = store.SetAsync
local spent = false
store.SetAsync = function(self, k, value)
	if k == thiefKey then
		if not spent then
			spent = true
			DS.AddCoins(pair.thief, -100200)
			balanceAfterSpend = tonumber(DS.GetData(pair.thief).Coins) or 0
		end
		error("injected SetAsync failure for " .. k)
	end
	return orig(self, k, value)
end
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
store.SetAsync = orig
check("setup: delivery reports the reward pending", okDel == true and status == "reward_pending", "status=" .. tostring(status))
check("OLD BUG REPRODUCED: the over-spend ate into the reward (balance 100, not the reserved 300)",
	balanceAfterSpend == 100, "balanceAfterSpend=" .. tostring(balanceAfterSpend))
check("old logic: rollback clamps at zero (balance 0 after removing a 300 reward from 100)",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 0,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
local paid, total = env.raid.RecoverPendingRewards(pair.thief)
check("old logic: recovery pays the reward again", paid == 1 and total == 300)
check("OLD BUG REPRODUCED: the player ends with 300 coins AND 100200 of spent value (200 overpaid)",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 300,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))

H.finish()
