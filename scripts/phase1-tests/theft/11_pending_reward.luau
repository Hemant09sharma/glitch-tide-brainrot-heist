-- 11_pending_reward.luau — R2-4 (R13): a steal-reward failure must not
-- silently lose the reward. Two injected failures:
--   A. DataService.AddCoins throws at delivery time.
--   B. The session cannot persist (IsSaveable false — the DataStore
--      load failed, so SaveData would refuse): no phantom coins may be
--      minted, and recovery while unsaveable must keep the entry.
-- In both cases ConfirmDelivery must report "reward_pending" (not
-- rewarded success), the reward must sit in data.PendingRewards keyed
-- by InstanceId, and RecoverPendingRewards must pay it exactly once.
-- A healthy delivery (C) still pays directly with no pending entry.
-- Run: lune run scripts/phase1-tests/theft/11_pending_reward.luau
local H = require("../harness")

local env = H.newEnv()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- ---------------------------------------------------------------------------
-- Pair A: AddCoins throws at delivery time.
-- StealReward for the fixture = half banked (500*0.5=250) +
-- IncomePerSec*10 (wobble 5*10=50) = 300 coins (see theft test 04).
-- ---------------------------------------------------------------------------
local pairA = H.newPair(env, 921, 922)
H.steal(env, pairA)
local realAddCoins = env.dataService.AddCoins
env.dataService.AddCoins = function(_player, _amount)
	error("injected AddCoins failure")
end
local coinsBeforeA = pairA.thiefData.Coins
local okDelA, statusA = env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
check("A: delivery still succeeds (ownership transfers)", okDelA == true)
check("A: delivery reports reward_pending, not rewarded success",
	statusA == "reward_pending", "status=" .. tostring(statusA))
check("A: no coins paid on the failed grant",
	pairA.thiefData.Coins == coinsBeforeA,
	"coins=" .. tostring(pairA.thiefData.Coins))
local pendingA = pairA.thiefData.PendingRewards
check("A: reward recorded pending (300 coins, keyed by InstanceId)",
	type(pendingA) == "table" and type(pendingA[pairA.targetId]) == "table"
		and pendingA[pairA.targetId].Amount == 300
		and pendingA[pairA.targetId].CharacterId == "wobble_waffleton")
local ownedA = H.findOwned(pairA.thiefData, pairA.targetId)
check("A: transit cleared and ownership consistent despite the failure",
	ownedA ~= nil and ownedA.InTransit ~= true and ownedA.BankedIncome == 250
		and H.countOwned(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)
check("A: CarryingStolen attribute cleared",
	pairA.thief.Character:GetAttribute("CarryingStolen") == "")
local okDelA2 = env.raid.ConfirmDelivery(pairA.thief, pairA.targetId)
check("A: second ConfirmDelivery fails (no transit left)", okDelA2 == false)
check("A: second ConfirmDelivery records no second pending reward",
	pendingA[pairA.targetId].Amount == 300
		and pairA.thiefData.Coins == coinsBeforeA)
-- Restore AddCoins; recover.
env.dataService.AddCoins = realAddCoins
local paidA, totalA = env.raid.RecoverPendingRewards(pairA.thief)
check("A: recovery pays exactly once (1 entry, 300 coins)",
	paidA == 1 and totalA == 300,
	"paid=" .. tostring(paidA) .. " total=" .. tostring(totalA))
check("A: coins arrive after recovery",
	pairA.thiefData.Coins == coinsBeforeA + 300,
	"coins=" .. tostring(pairA.thiefData.Coins))
check("A: pending entry removed after payment",
	pairA.thiefData.PendingRewards == nil
		or pairA.thiefData.PendingRewards[pairA.targetId] == nil)
local paidA2, totalA2 = env.raid.RecoverPendingRewards(pairA.thief)
check("A: second recovery pays nothing more",
	paidA2 == 0 and totalA2 == 0 and pairA.thiefData.Coins == coinsBeforeA + 300)

-- ---------------------------------------------------------------------------
-- Pair B: unsaveable session (IsSaveable false).
-- ---------------------------------------------------------------------------
local pairB = H.newPair(env, 923, 924)
H.steal(env, pairB)
local addCoinsCalls = 0
local realAddCoinsB = env.dataService.AddCoins
env.dataService.AddCoins = function(player, amount)
	addCoinsCalls += 1
	return realAddCoinsB(player, amount)
end
env.dataService.IsSaveable = function(_player)
	return false
end
local coinsBeforeB = pairB.thiefData.Coins
local okDelB, statusB = env.raid.ConfirmDelivery(pairB.thief, pairB.targetId)
check("B: delivery succeeds with an unsaveable session", okDelB == true)
check("B: delivery reports reward_pending",
	statusB == "reward_pending", "status=" .. tostring(statusB))
check("B: AddCoins never called (no phantom coins minted)",
	addCoinsCalls == 0, "calls=" .. tostring(addCoinsCalls))
check("B: no coins paid",
	pairB.thiefData.Coins == coinsBeforeB,
	"coins=" .. tostring(pairB.thiefData.Coins))
check("B: reward recorded pending",
	type(pairB.thiefData.PendingRewards) == "table"
		and type(pairB.thiefData.PendingRewards[pairB.targetId]) == "table"
		and pairB.thiefData.PendingRewards[pairB.targetId].Amount == 300)
local paidB0, totalB0 = env.raid.RecoverPendingRewards(pairB.thief)
check("B: recovery while unsaveable pays nothing and keeps the entry",
	paidB0 == 0 and totalB0 == 0
		and pairB.thiefData.PendingRewards[pairB.targetId] ~= nil
		and pairB.thiefData.Coins == coinsBeforeB)
-- The session becomes saveable again (rejoin with a good load):
-- recovery must pay exactly once.
env.dataService.IsSaveable = function(_player)
	return true
end
local paidB, totalB = env.raid.RecoverPendingRewards(pairB.thief)
check("B: recovery after the session is saveable pays exactly once",
	paidB == 1 and totalB == 300,
	"paid=" .. tostring(paidB) .. " total=" .. tostring(totalB))
check("B: coins arrive after recovery",
	pairB.thiefData.Coins == coinsBeforeB + 300,
	"coins=" .. tostring(pairB.thiefData.Coins))
check("B: pending entry removed after payment",
	pairB.thiefData.PendingRewards[pairB.targetId] == nil)
local paidB2, totalB2 = env.raid.RecoverPendingRewards(pairB.thief)
check("B: second recovery pays nothing more",
	paidB2 == 0 and totalB2 == 0 and pairB.thiefData.Coins == coinsBeforeB + 300)
-- Restore the stubs.
env.dataService.AddCoins = realAddCoinsB
env.dataService.IsSaveable = nil

-- ---------------------------------------------------------------------------
-- Pair C: healthy delivery still pays directly, with no pending entry.
-- ---------------------------------------------------------------------------
local pairC = H.newPair(env, 925, 926)
H.steal(env, pairC)
local coinsBeforeC = pairC.thiefData.Coins
local okDelC, statusC = env.raid.ConfirmDelivery(pairC.thief, pairC.targetId)
check("C: healthy delivery pays the reward directly (300 coins, status nil)",
	okDelC == true and statusC == nil and pairC.thiefData.Coins == coinsBeforeC + 300,
	"status=" .. tostring(statusC) .. " coins=" .. tostring(pairC.thiefData.Coins))
check("C: healthy delivery records no pending reward",
	pairC.thiefData.PendingRewards == nil
		or pairC.thiefData.PendingRewards[pairC.targetId] == nil)

H.finish()
