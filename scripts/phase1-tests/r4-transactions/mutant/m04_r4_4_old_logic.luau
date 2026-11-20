-- m04_r4_4_old_logic.luau — NEGATIVE CONTROL for R4-4 (Test D):
-- Scenario (B) of test 04, run against the R3 mutant RaidService
-- (RecoverStaleTransit never voids pending rewards). The control
-- PASSES when the OLD bad outcome is observed: the delivery is
-- voided back to the victim, but the pending reward is still paid
-- — the thief keeps the reward AND the victim recovers the
-- Brainrot (reward farming).
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local R = require("../r4_env")
local P = R.P
local H = R.H
local env = R.newEnv({ raidPath = "./mutant/RaidServiceR3" })
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = P.newLoadedPair(env, 9633, 9634)
H.steal(env, pair)
assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
assert(DS.SaveData(pair.thief) == true, "setup: thief mid-carry save must land")
local restoreMain = R.failSetAsyncForKey(P.mainKey(pair.thief.UserId))
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("setup: delivery reports the reward pending", okDel == true and status == "reward_pending", "status=" .. tostring(status))
restoreMain()
DS.LoadData(pair.thief)
local resolved, remaining, paid, total = env.raid.RecoverOnRejoin(pair.thief)
check("setup: rejoin resolves the stale transit (Brainrot returns to the victim)",
	resolved == 1 and remaining == 0, "resolved=" .. tostring(resolved))
check("OLD BUG REPRODUCED: the voided delivery's reward is STILL paid",
	paid == 1 and total == 300, "paid=" .. tostring(paid) .. " total=" .. tostring(total))
check("OLD BUG REPRODUCED: the thief keeps the 300-coin reward",
	(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100300,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
check("OLD BUG REPRODUCED: the victim ALSO recovered the Brainrot (farming)",
	H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
		and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)

H.finish()
