-- 03_mutant_control.luau — R2 R13 negative control: the SAME pending-
-- reward assertions as theft/11_pending_reward.luau scenario A, run
-- against the MUTANT RaidService (old pcall + warn-only grant restored
-- by mutant/make_mutant.sh). This file is EXPECTED TO FAIL: the mutant
-- must swallow the AddCoins failure, record nothing pending, and still
-- claim rewarded success, which proves the test detects the missing
-- ledger. Never run under theft/run_all.sh — run via
-- mutant/run_mutant.sh, which inverts the exit code.
local H = require("../../harness")

local env = H.newEnv({ raidPath = "./theft/mutant/RaidServiceR13" })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 955, 956)
H.steal(env, pair)
local realAddCoins = env.dataService.AddCoins
env.dataService.AddCoins = function(_player, _amount)
	error("injected AddCoins failure")
end
local coinsBefore = pair.thiefData.Coins
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("M: delivery succeeds (ownership transfers)", okDel == true)
check("M: delivery reports reward_pending, not rewarded success",
	status == "reward_pending", "status=" .. tostring(status))
check("M: no coins paid on the failed grant",
	pair.thiefData.Coins == coinsBefore,
	"coins=" .. tostring(pair.thiefData.Coins))
local pending = pair.thiefData.PendingRewards
check("M: reward recorded pending (300 coins, keyed by InstanceId)",
	type(pending) == "table" and type(pending[pair.targetId]) == "table"
		and pending[pair.targetId].Amount == 300)
env.dataService.AddCoins = realAddCoins
local paid, total = env.raid.RecoverPendingRewards(pair.thief)
check("M: recovery pays exactly once (1 entry, 300 coins)",
	paid == 1 and total == 300,
	"paid=" .. tostring(paid) .. " total=" .. tostring(total))
check("M: coins arrive after recovery",
	pair.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pair.thiefData.Coins))

H.finish()
