-- m05_r5_2_old_logic.luau — NEGATIVE CONTROL for R5-2 (P0):
-- The decisive test-05 scenarios run against the PRE-R5-2
-- RaidService (mutant/RaidServiceR5Pre2.luau: no session-health
-- gates) and the PRE-R5-2 BaseService (mutant/BaseServiceR5Pre2.luau:
-- no place/store gates), with the CURRENT DataService (the R5-4
-- lease machinery is shared — the old services never call it at
-- the steal/delivery commit points, which is exactly the defect).
-- The control PASSES when the OLD bad outcomes are observed: a
-- contested thief's steal succeeds and the instance is LOST after
-- both rejoin (0 owners); a load-failed thief's steal and delivery
-- succeed and the instance is LOST after both rejoin (0 owners);
-- a delivery committed in-memory in a load-failed session parks a
-- tombstone that supersedes the victim's escrow backstop, so both
-- rejoining leaves 0 owners (the Worker-A decision item as it
-- stood); a load-failed place succeeds. If this control failed,
-- test 05 would pass even against the broken code.
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_2_7.sh
local R5 = require("../r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv({ raidPath = "./mutant/RaidServiceR5Pre2" })
local DS = env.dataService
local DSB = require("../services/DataServiceB")
local raid = env.raid

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function leaseKey(userId)
	return "Brainrot_Session_" .. tostring(userId)
end

local function findTombstone(userId, instanceId)
	local list = store:peek(P.escrowKey(userId))
	if type(list) ~= "table" then
		return nil
	end
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.InstanceId == instanceId and entry.Superseded == true then
			return entry
		end
	end
	return nil
end

-- takeLeaseWithB(player): server B takes this player's session
-- lease (test 04 §A pattern: expire A's stored lease, B loads).
local function takeLeaseWithB(player)
	store:seed(leaseKey(player.UserId), {
		ServerId = DS.GetServerId(),
		AcquiredAt = os.time() - 200,
		ExpiresAt = os.time() - 10,
	})
	DSB.LoadData(player)
end

-- loadSplitPair(pair, failThief): seed both main keys, then load one
-- party healthy and the other with a failed load (3 GetAsync
-- failures = LOAD_RETRIES), then merge the fixture tables into the
-- live caches (mirrors R5.loadUnloadedPair).
local function loadSplitPair(pair, failThief)
	store:seed(P.mainKey(pair.thief.UserId), deepCopy(pair.thiefData))
	store:seed(P.mainKey(pair.victim.UserId), deepCopy(pair.victimData))
	local failPlayer = failThief and pair.thief or pair.victim
	store:failGetAsyncForKey(P.mainKey(failPlayer.UserId), 3)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	store:resetFailures()
	local liveThief = DS.GetData(pair.thief)
	local liveVictim = DS.GetData(pair.victim)
	assert(liveThief ~= nil and liveVictim ~= nil, "loadSplitPair: no cache after load")
	for k, v in pairs(pair.thiefData) do
		liveThief[k] = v
	end
	for k, v in pairs(pair.victimData) do
		liveVictim[k] = v
	end
	return pair
end

local function countLive(players, instanceId)
	return H.countOwned(env, players, instanceId)
end

-- --- (A) Contested thief steals from a healthy victim -----------
local pairA = P.newLoadedPair(env, 9701, 9702)
takeLeaseWithB(pairA.thief)
local okA, reasonA = raid.StealBrainrot(pairA.thief, pairA.victim.UserId, pairA.targetId)
check("old (A): contested thief's steal SUCCEEDS (no gate)",
	okA == true, "ok=" .. tostring(okA) .. " reason=" .. tostring(reasonA))
check("old (A): the victim's removal save lands",
	DS.SaveData(pairA.victim) == true)
check("old (A): the thief's save refuses (contested lease)",
	DS.SaveData(pairA.thief) == false)
DS.LoadData(pairA.victim)
DS.LoadData(pairA.thief)
check("old (A): both rejoin — the instance is LOST (0 owners)",
	countLive({ pairA.thief, pairA.victim }, pairA.targetId) == 0,
	"count=" .. tostring(countLive({ pairA.thief, pairA.victim }, pairA.targetId)))

-- --- (C) Load-failed thief steals and delivers --------------------
local pairC = loadSplitPair(R5.newPairFixture(9711, 9712), true)
check("old (C) setup: thief is load-failed",
	DS.IsSaveable(pairC.thief) == false)
local okC, reasonC = raid.StealBrainrot(pairC.thief, pairC.victim.UserId, pairC.targetId)
check("old (C): load-failed thief's steal SUCCEEDS (no gate)",
	okC == true, "ok=" .. tostring(okC) .. " reason=" .. tostring(reasonC))
local okDelC, statusDelC = raid.ConfirmDelivery(pairC.thief, pairC.targetId)
check("old (C): load-failed thief's delivery SUCCEEDS in-memory (no gate)",
	okDelC == true, "ok=" .. tostring(okDelC) .. " status=" .. tostring(statusDelC))
check("old (C): the thief's save refuses (load-failed)",
	DS.SaveData(pairC.thief) == false)
-- The victim is healthy, so their removal save lands (the Qwen
-- loss: the victim's removal persists, the thief's delivery never
-- does). Without this save the victim's stale stored key would
-- resurrect the Brainrot on rejoin and hide the loss.
check("old (C): the victim's removal save lands",
	DS.SaveData(pairC.victim) == true)
DS.LoadData(pairC.victim)
DS.LoadData(pairC.thief)
check("old (C): both rejoin — the instance is LOST (0 owners)",
	countLive({ pairC.thief, pairC.victim }, pairC.targetId) == 0,
	"count=" .. tostring(countLive({ pairC.thief, pairC.victim }, pairC.targetId)))

-- --- (E) Decision item: healthy steal, load-failed delivery -------
local pairE = P.newLoadedPair(env, 9741, 9742)
H.steal(env, pairE)
store:seed(P.escrowKey(pairE.victim.UserId), {
	P.escrowRecord(pairE.targetId, { ReturnTxId = "rt-m05-stale-001" }),
	P.escrowRecord("other-inst-9742", { CharacterId = "turbo_turnip", Slot = 1 }),
})
local thiefLiveBefore = deepCopy(DS.GetData(pairE.thief))
store:failGetAsyncForKey(P.mainKey(pairE.thief.UserId), 3)
DS.LoadData(pairE.thief)
store:resetFailures()
local liveThiefE = DS.GetData(pairE.thief)
for k, v in pairs(thiefLiveBefore) do
	liveThiefE[k] = v
end
check("old (E) setup: the thief is load-failed AND still carrying",
	DS.IsSaveable(pairE.thief) == false
		and H.findOwned(DS.GetData(pairE.thief), pairE.targetId) ~= nil
		and H.findOwned(DS.GetData(pairE.thief), pairE.targetId).InTransit == true)
local okE, reasonE = raid.ConfirmDelivery(pairE.thief, pairE.targetId)
check("old (E): load-failed thief's delivery SUCCEEDS (no gate)",
	okE == true, "ok=" .. tostring(okE) .. " reason=" .. tostring(reasonE))
check("old (E): the delivery parked a tombstone over the stale escrow",
	findTombstone(pairE.victim.UserId, pairE.targetId) ~= nil)
check("old (E): the thief's save refuses (load-failed)",
	DS.SaveData(pairE.thief) == false)
-- The victim is healthy, so their removal save lands (see the
-- note in §C): without it the stale stored key resurrects the
-- Brainrot and hides the loss.
check("old (E): the victim's removal save lands",
	DS.SaveData(pairE.victim) == true)
DS.LoadData(pairE.victim)
DS.LoadData(pairE.thief)
check("old (E): both rejoin — the instance is LOST (0 owners: delivery never persisted, tombstone killed the escrow)",
	countLive({ pairE.thief, pairE.victim }, pairE.targetId) == 0,
	"count=" .. tostring(countLive({ pairE.thief, pairE.victim }, pairE.targetId)))

-- --- (H-b) Load-failed place via the old BaseService --------------
-- Wire the PRE-R5-2 BaseService snapshot directly (H.newBaseEnv
-- hardcodes the current store/services copy): same wiring as
-- H.newBaseEnv, pointed at mutant/BaseServiceR5Pre2.
local BaseServiceOld = require("./BaseServiceR5Pre2")
BaseServiceOld.Init(env.dataService)
BaseServiceOld.SetCarryService(env.carry)
BaseServiceOld.SetRaidService(env.raid)
env.raid.SetBaseService(BaseServiceOld)
local base = BaseServiceOld

local pairHb = loadSplitPair(R5.newPairFixture(9773, 9774), true)
local plotHbT = base.AssignBase(pairHb.thief)
base.AssignBase(pairHb.victim)
check("old (H-b) setup: thief is load-failed",
	DS.IsSaveable(pairHb.thief) == false
		and DS.GetSaveBlockedReason(pairHb.thief) == "load_failed")
local ownedEvoB = H.findOwned(DS.GetData(pairHb.thief), pairHb.prefix .. "evo_1")
assert(env.carry.PickupOwned(pairHb.thief, ownedEvoB), "H-b setup: PickupOwned must succeed")
H.setRootPosition(pairHb.thief, H.pedestalPosition(plotHbT, 1))
local okPlaceHb, errPlaceHb = base.PlaceBrainrot(pairHb.thief, pairHb.prefix .. "evo_1", 1)
check("old (H-b): place in a load-failed session SUCCEEDS (no gate)",
	okPlaceHb == true, "ok=" .. tostring(okPlaceHb) .. " err=" .. tostring(errPlaceHb))

H.finish()
