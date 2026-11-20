-- 06_pending_sidecar.luau — R2-5 (R2-4 hole): a pending steal reward
-- recorded while the session cannot persist (DataStore load failed,
-- so SaveData refuses the main key) must NOT die with the cache when
-- the player leaves before a successful load. The entry is ALSO
-- parked in the DataStore sidecar, which the next successful load
-- merges back into PendingRewards; recovery then pays it exactly
-- once. (StealReward for the fixture = half banked 500*0.5=250 +
-- IncomePerSec*10 = 300 coins.)
-- Run: bash scripts/phase1-tests/lifecycle/run.sh
local H = require("../harness")
local L = require("./lifecycle_data")

local DS = L.new()
DS.connectLeaveHandler()
local env = H.newEnv({ dataService = DS })
local Players = game:GetService("Players")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 1601, 1602)
H.steal(env, pair)

-- The session cannot persist from here on (load failed at join).
DS.setSaveable(false)
local coinsBefore = pair.thiefData.Coins
local okDel, status = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("delivery succeeds with an unsaveable session", okDel == true)
check("delivery reports reward_pending",
	status == "reward_pending", "status=" .. tostring(status))
check("no coins paid (no phantom coins minted)",
	pair.thiefData.Coins == coinsBefore)
check("reward recorded in the in-cache ledger",
	type(pair.thiefData.PendingRewards) == "table"
		and pair.thiefData.PendingRewards[pair.targetId] ~= nil
		and pair.thiefData.PendingRewards[pair.targetId].Amount == 300)
check("reward ALSO parked in the sidecar (survives the cache)",
	type(DS._pendingSidecar[pair.thief.UserId]) == "table"
		and #DS._pendingSidecar[pair.thief.UserId] == 1
		and DS._pendingSidecar[pair.thief.UserId][1].InstanceId == pair.targetId
		and DS._pendingSidecar[pair.thief.UserId][1].Amount == 300)

-- The player leaves WITHOUT a successful save (SaveData refuses):
-- the in-cache ledger dies with the cache, the sidecar survives.
pair.thief.Parent = nil
Players.PlayerRemoving:Fire(pair.thief)
check("leave save refused while unsaveable (nothing persisted)",
	(DS._saves[pair.thief] or 0) == 0 and DS._saved[pair.thief] == nil)
check("sidecar entry survives the leave",
	type(DS._pendingSidecar[pair.thief.UserId]) == "table"
		and #DS._pendingSidecar[pair.thief.UserId] == 1)

-- Crash + rejoin with a good load: the sidecar merges back, the
-- reward is paid exactly once, and a second recovery pays nothing.
-- (The thief's DataStore key holds no save from the unsaveable
-- session, so the rejoin snapshot below stands in for the last good
-- save — with the pending ledger stripped out, as a save from before
-- the ledger existed would have it. The delivered Brainrot itself is
-- already in the data; only the ledger entry is what was lost.)
local deliveredOwned = L.deepCopy(H.findOwned(pair.thiefData, pair.targetId))
local thiefSnapshot = L.deepCopy(pair.thiefData)
thiefSnapshot.PendingRewards = nil
DS._saved[pair.thief] = thiefSnapshot
DS.setSaveable(true)
DS.simulateCrash()
DS.simulateLoad(pair.thief)
local reloaded = DS.GetData(pair.thief)
check("rejoin merges the sidecar entry back into PendingRewards",
	type(reloaded.PendingRewards) == "table"
		and reloaded.PendingRewards[pair.targetId] ~= nil
		and reloaded.PendingRewards[pair.targetId].Amount == 300)
local paid, total = env.raid.RecoverPendingRewards(pair.thief)
check("recovery after rejoin pays exactly once (1 entry, 300 coins)",
	paid == 1 and total == 300, "paid=" .. tostring(paid) .. " total=" .. tostring(total))
check("coins arrive after recovery",
	reloaded.Coins == coinsBefore + 300, "coins=" .. tostring(reloaded.Coins))
check("pending entry removed after payment",
	reloaded.PendingRewards[pair.targetId] == nil)
local paid2, total2 = env.raid.RecoverPendingRewards(pair.thief)
check("second recovery pays nothing more",
	paid2 == 0 and total2 == 0 and reloaded.Coins == coinsBefore + 300)
check("delivered Brainrot still owned exactly once after the whole flow",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
		and H.findOwned(reloaded, pair.targetId) ~= nil)
check("delivered record is the same instance (not a restored duplicate)",
	H.findOwned(reloaded, pair.targetId).InstanceId == deliveredOwned.InstanceId
		and H.findOwned(reloaded, pair.targetId).InTransit ~= true)

H.finish()
