-- m02_r5_5_old_logic.luau — NEGATIVE CONTROL for R5-5 (P2) + R5-2:
-- The same GetDataStore outage sequence as test 02 (§A–§C), run
-- against the PRE-R5 DataService (mutant/DataServiceR4.luau:
-- InvalidateReturnEscrow returns success when no store is
-- available) AND the PRE-R5-2 RaidService (mutant/RaidServiceR4.luau:
-- no session-health gates — a load-failed thief can steal and
-- deliver). Both old modules are needed: the current RaidService
-- refuses the steal outright (thief load-failed), so the old
-- DataService defect alone can no longer be reached end-to-end.
-- The control PASSES when the OLD bad outcomes are observed: the
-- invalidation claims success during the outage, the delivery
-- commits during the outage, the thief's post-recovery save lands
-- (the old session was saveable), and after the victim's rejoin
-- BOTH players own the same InstanceId. If this control failed,
-- test 02 would pass even against the broken code.
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh
local R5 = require("../r5_env")
local P = R5.P
local H = R5.H
local store = R5.store

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

local staleTxId = "rt-r5-5-stale-001"
R5.setDataStoreOutage(true)
local env = R5.newEnv({ dsPath = "./mutant/DataServiceR4", raidPath = "./mutant/RaidServiceR4" })
local DS = env.dataService

local pair = R5.newPairFixture(9601, 9602)
local victimStored = deepCopy(pair.victimData)
for i = #victimStored.OwnedInstances, 1, -1 do
	if victimStored.OwnedInstances[i].InstanceId == pair.targetId then
		table.remove(victimStored.OwnedInstances, i)
	end
end
for i = #victimStored.Base.Placed, 1, -1 do
	if victimStored.Base.Placed[i].InstanceId == pair.targetId then
		table.remove(victimStored.Base.Placed, i)
	end
end
store:seed(P.mainKey(9602), victimStored)
store:seed(P.mainKey(9601), deepCopy(pair.thiefData))
store:seed(P.escrowKey(9602), {
	P.escrowRecord(pair.targetId, { ReturnTxId = staleTxId }),
	P.escrowRecord("other-inst-9602", { CharacterId = "turbo_turnip", Slot = 1 }),
})
R5.loadUnloadedPair(env, pair)
H.steal(env, pair)

local okInv, hadStale, invErr = DS.InvalidateReturnEscrow(9602, pair.targetId, "d-r5-5-direct")
check("old: InvalidateReturnEscrow claims SUCCESS during the outage (fail-open)",
	okInv == true and hadStale == false and invErr == nil,
	"ok=" .. tostring(okInv) .. " err=" .. tostring(invErr))
local okDel, statusDel = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("old: ConfirmDelivery COMMITS during the outage",
	okDel == true,
	"ok=" .. tostring(okDel) .. " status=" .. tostring(statusDel))

R5.setDataStoreOutage(false)
check("old: the thief's post-recovery save lands (the old session was saveable)",
	DS.SaveData(pair.thief) == true)
check("old: the thief's stored key holds the delivered copy",
	H.findOwned(store:peek(P.mainKey(9601)), pair.targetId) ~= nil)

DS.LoadData(pair.victim)
check("old: the victim's rejoin resurrects the stale escrow copy",
	H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil)
DS.LoadData(pair.thief)
check("old: BOTH players own the same InstanceId after rejoin (duplication)",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 2,
	"count=" .. tostring(H.countOwned(env, { pair.thief, pair.victim }, pair.targetId)))

H.finish()
