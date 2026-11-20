-- 11_two_transactions_same_instance.luau — R3-4: two recordings for
-- the same instance (100 then 150) must total exactly 250 in the
-- cache AND in the sidecar. The old code passed the already-
-- accumulated total to the sidecar, which accumulated again (350).
-- R3-3 (E): two separate legitimate steal-reward transactions for
-- the same Brainrot must be representable without confusing them
-- with duplicate attempts of the same transaction — exercised
-- end-to-end as a steal-back: the thief is paid pending for the
-- first delivery, the Brainrot is stolen from them and delivered by
-- a third player, then the thief steals it back and is paid pending
-- again. Both transactions pay exactly once in total on recovery.
-- Run: bash scripts/phase1-tests/persistence/run.sh
local P = require("./persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService()
local env = P.newRaidEnv()
local Economy = require("../theft/shared/Economy")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- ---------------------------------------------------------------------------
-- (a) Sidecar level: two recordings, distinct TxIds, same instance.
-- ---------------------------------------------------------------------------
local userA = 9211
local playerA = { UserId = userA, Name = "Player9211" }
local ok1 = DS.RecordPendingRewardSidecar(playerA, P.pendingEntryTx("r34_inst", 100, "tx-r34-1"))
local ok2 = DS.RecordPendingRewardSidecar(playerA, P.pendingEntryTx("r34_inst", 150, "tx-r34-2"))
local listA = store:peek(P.pendingKey(userA))
check("R3-4: both recordings land in the sidecar",
	ok1 == true and ok2 == true)
check("R3-4: two separate entries (one per transaction), not one summed entry",
	P.countInList(listA, "r34_inst") == 2 and #listA == 2,
	"list size=" .. (type(listA) == "table" and #listA or tostring(listA)))
check("R3-4: sidecar total for the instance is exactly 250 (100 + 150)",
	P.sidecarTotal(listA, "r34_inst") == 250,
	"total=" .. tostring(P.sidecarTotal(listA, "r34_inst")))
-- Replay of the first recording: no-op.
local okReplay = DS.RecordPendingRewardSidecar(playerA, P.pendingEntryTx("r34_inst", 100, "tx-r34-1"))
local listA2 = store:peek(P.pendingKey(userA))
check("R3-4: replaying the same TxId reports success but changes nothing",
	okReplay == true and P.countInList(listA2, "r34_inst") == 2
		and P.sidecarTotal(listA2, "r34_inst") == 250)

-- ---------------------------------------------------------------------------
-- (b) Cache + merge level: rejoin merges both, recovery pays 250 once.
-- ---------------------------------------------------------------------------
store:seed(P.mainKey(userA), {
	Coins = 500,
	OwnedInstances = {},
	Base = { Placed = {} },
	LastLogin = os.time(),
})
local realPlayerA = H.newPlayer(userA, "Player9211")
local dataA = DS.LoadData(realPlayerA)
check("R3-4: rejoin merges both transactions into one aggregate (250)",
	P.pendingTotal(dataA, "r34_inst") == 250)
check("R3-4: aggregate records both transaction ids",
	P.pendingTxnCount(dataA, "r34_inst") == 2)
local paidA, totalA = env.raid.RecoverPendingRewards(realPlayerA)
check("R3-4: recovery pays the aggregate exactly once (1 entry, 250 coins)",
	paidA == 1 and totalA == 250, "paid=" .. tostring(paidA) .. " total=" .. tostring(totalA))
check("R3-4: coins arrive (500 + 250)",
	DS.GetData(realPlayerA).Coins == 750)
local paidA2, totalA2 = env.raid.RecoverPendingRewards(realPlayerA)
check("R3-4: second recovery pays nothing more",
	paidA2 == 0 and totalA2 == 0 and DS.GetData(realPlayerA).Coins == 750)

-- ---------------------------------------------------------------------------
-- (c) End-to-end: the same Brainrot stolen and delivered twice to the
-- same thief (steal-back) is two transactions.
-- ---------------------------------------------------------------------------
local pair = P.newLoadedPair(env, 9212, 9213)
local thiefBaseline = DS.GetData(pair.thief).Coins
H.steal(env, pair)
-- First delivery records pending (AddCoins throws, as in theft 11A).
local realAddCoins = DS.AddCoins
DS.AddCoins = function(_player, _amount)
	error("injected AddCoins failure")
end
local okDel1, status1 = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("E: first delivery succeeds and reports reward_pending",
	okDel1 == true and status1 == "reward_pending", "status=" .. tostring(status1))
check("E: first reward is pending in the cache (300, one transaction)",
	P.pendingTotal(DS.GetData(pair.thief), pair.targetId) == 300
		and P.pendingTxnCount(DS.GetData(pair.thief), pair.targetId) == 1)
DS.AddCoins = realAddCoins
-- Place the delivered Brainrot in the thief's base so it can be
-- stolen again; backdate PlacedAt past the 120s protection window and
-- give the thief a second placed Brainrot (a victim must keep >1 placed).
local owned1 = H.findOwned(DS.GetData(pair.thief), pair.targetId)
env.base.PlaceBrainrot(pair.thief, owned1)
-- The stub base's mini-PlaceBrainrot does not clear the carry (the
-- real BaseService.PlaceBrainrot does, BaseService.luau ~1230), so
-- clear it explicitly — otherwise the thief is still "carrying" and
-- the next steal refuses with "already carrying".
env.carry.ClearCarried(pair.thief, true)
local placed1 = H.findPlaced(DS.GetData(pair.thief), pair.targetId)
placed1.PlacedAt = pair.oldTime
table.insert(DS.GetData(pair.thief).Base.Placed, {
	InstanceId = pair.prefix .. "fuse_a",
	CharacterId = "wobble_waffleton",
	Slot = 2,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = pair.oldTime,
})
-- A third player steals it from the thief and delivers (healthy).
local third = H.newPlayer(9214, "Third9214")
store:seed(P.mainKey(9214), {
	Level = 5,
	Coins = 100000,
	Gems = 0,
	MutationCrystals = 0,
	Rebirths = 0,
	Unlocked = { "wobble_waffleton" },
	OwnedInstances = {},
	Base = { Placed = {} },
	LastLogin = os.time(),
})
DS.LoadData(third)
H.steal(env, { thief = third, victim = pair.thief, targetId = pair.targetId })
local thirdBaseline = DS.GetData(third).Coins
local okDelThird, statusThird = env.raid.ConfirmDelivery(third, pair.targetId)
check("E: third player delivers the stolen Brainrot (healthy, 175 coins)",
	okDelThird == true and statusThird == nil
		and DS.GetData(third).Coins == thirdBaseline + 175,
	"status=" .. tostring(statusThird) .. " coins=" .. tostring(DS.GetData(third).Coins))
-- Place it in the third player's base (backdated, plus a filler) so
-- the original thief can steal it back.
local owned2 = H.findOwned(DS.GetData(third), pair.targetId)
env.base.PlaceBrainrot(third, owned2)
env.carry.ClearCarried(third, true)
local placed2 = H.findPlaced(DS.GetData(third), pair.targetId)
placed2.PlacedAt = pair.oldTime
table.insert(DS.GetData(third).Base.Placed, {
	InstanceId = "third_filler",
	CharacterId = "turbo_turnip",
	Slot = 2,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = pair.oldTime,
})
-- The original thief steals it back; the second delivery also records
-- pending (AddCoins throws again). Banked income is now 125, so the
-- second reward is floor(125 * 0.5) + 50 = 112.
H.steal(env, { thief = pair.thief, victim = third, targetId = pair.targetId })
DS.AddCoins = function(_player, _amount)
	error("injected AddCoins failure")
end
local okDel2, status2 = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("E: second delivery succeeds and reports reward_pending",
	okDel2 == true and status2 == "reward_pending", "status=" .. tostring(status2))
DS.AddCoins = realAddCoins
local secondReward = Economy.StealReward("wobble_waffleton", 125)
check("E: second reward follows the shared formula (125 banked -> 112)",
	secondReward == 112, "reward=" .. tostring(secondReward))
check("E: both transactions are pending in the cache (300 + 112 = 412)",
	P.pendingTotal(DS.GetData(pair.thief), pair.targetId) == 300 + secondReward)
check("E: the two transactions are distinct (two TxIds, not one merged replay)",
	P.pendingTxnCount(DS.GetData(pair.thief), pair.targetId) == 2)
local paidC, totalC = env.raid.RecoverPendingRewards(pair.thief)
check("E: recovery pays both transactions exactly once (1 entry, 412 coins)",
	paidC == 1 and totalC == 300 + secondReward,
	"paid=" .. tostring(paidC) .. " total=" .. tostring(totalC))
check("E: coins arrive after recovery (baseline + 412)",
	DS.GetData(pair.thief).Coins == thiefBaseline + 300 + secondReward,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
local paidC2, totalC2 = env.raid.RecoverPendingRewards(pair.thief)
check("E: second recovery pays nothing more",
	paidC2 == 0 and totalC2 == 0
		and DS.GetData(pair.thief).Coins == thiefBaseline + 300 + secondReward)

H.finish()
