-- 01_r4_1_stale_escrow_duplication.luau — R4-1 (P1, Test A):
-- Qwen's exact five-condition duplication scenario. Victim owns a
-- Brainrot -> stolen, victim's removal saved -> returned, durable
-- return escrow parked but the victim's profile save fails -> the
-- Brainrot is stolen again (by a second thief) and delivered, the
-- second thief saves -> victim rejoins after the outage. The old R3
-- logic applies the stale escrow entry on the victim's rejoin merge
-- and BOTH players own the same InstanceId. The R4-1 fix parks a
-- durable delivery tombstone at delivery time (and marks the
-- victim's live ledger when online), so the stale entry is refused
-- and exactly one owner remains.
-- Also: repeating recovery changes nothing, and an unrelated escrow
-- entry for another instance survives the tombstone.
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = P.newLoadedPair(env, 9401, 9402)
H.steal(env, pair)
assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")

-- Condition 2: return while the victim's profile save fails.
local restore = R.failSetAsyncForKey(P.mainKey(pair.victim.UserId))
env.raid.DropStolen(pair.thief)
local escrow = store:peek(P.escrowKey(pair.victim.UserId))
check("return parked the durable escrow despite the failed victim save",
	type(escrow) == "table" and #escrow == 1
		and escrow[1].InstanceId == pair.targetId
		and type(escrow[1].ReturnTxId) == "string" and escrow[1].ReturnTxId ~= "",
	"entries=" .. tostring(type(escrow) == "table" and #escrow or 0))
check("victim's stored key does NOT hold the return (save failed)",
	H.findOwned(store:peek(P.mainKey(pair.victim.UserId)), pair.targetId) == nil)
check("in-memory return stands (victim has it, thief does not)",
	H.findOwned(DS.GetData(pair.victim), pair.targetId) ~= nil
		and H.findOwned(DS.GetData(pair.thief), pair.targetId) == nil)

-- Retries exhausted (ReturnStolen keeps transit for 3 retries, then
-- clears it): the watchdog path is now closed, the escrow park is
-- the only backstop — exactly the state Qwen's scenario needs.
for _ = 1, 3 do
	env.raid.ReturnStolen(pair.targetId)
end
escrow = store:peek(P.escrowKey(pair.victim.UserId))
check("escrow still holds exactly one return entry after the retries",
	type(escrow) == "table" and #escrow == 1
		and escrow[1].InstanceId == pair.targetId)
local staleTxId = type(escrow) == "table" and escrow[1] and escrow[1].ReturnTxId or nil

-- An unrelated escrow entry for another instance must survive the
-- tombstone (parked before the second delivery).
local other = P.escrowRecord("other-inst-9402", { CharacterId = "turbo_turnip", Slot = 1 })
assert(DS.EscrowReturnedInstance(pair.victim.UserId, other) == true, "setup: unrelated escrow park must land")
escrow = store:peek(P.escrowKey(pair.victim.UserId))
check("unrelated escrow entry parked alongside the stale return",
	type(escrow) == "table" and #escrow == 2)
restore()

-- Condition 3: a SECOND thief steals the Brainrot again and
-- delivers it; the second thief saves.
local thief2 = R.newLoadedPlayer(env, 9403, 100000)
local okSteal2, errSteal2 = env.raid.StealBrainrot(thief2, pair.victim.UserId, pair.targetId)
check("second thief re-steals the Brainrot", okSteal2 == true, "err=" .. tostring(errSteal2))
local okDel2, status2 = env.raid.ConfirmDelivery(thief2, pair.targetId)
check("second thief delivers it", okDel2 == true and status2 == nil, "status=" .. tostring(status2))
check("delivered thief holds the legitimate instance",
	H.findOwned(DS.GetData(thief2), pair.targetId) ~= nil
		and H.findOwned(DS.GetData(thief2), pair.targetId).InTransit ~= true)
local okSave2 = DS.SaveData(thief2)
check("second thief's delivery save lands", okSave2 == true)
check("delivered copy is durable in the second thief's stored key",
	H.findOwned(store:peek(P.mainKey(thief2.UserId)), pair.targetId) ~= nil)

-- The delivery must have parked a tombstone naming the stale return.
escrow = store:peek(P.escrowKey(pair.victim.UserId))
local tombstone = nil
if type(escrow) == "table" then
	for _, entry in ipairs(escrow) do
		if type(entry) == "table" and entry.Superseded == true then
			tombstone = entry
		end
	end
end
check("delivery parked a tombstone in the victim's escrow",
	tombstone ~= nil and tombstone.InstanceId == pair.targetId,
	"entries=" .. tostring(type(escrow) == "table" and #escrow or 0))
local tombstoneNamesStale = false
if tombstone ~= nil and type(tombstone.SupersedesReturnTxIds) == "table" then
	for _, tx in ipairs(tombstone.SupersedesReturnTxIds) do
		if tx == staleTxId then
			tombstoneNamesStale = true
		end
	end
end
check("tombstone names the stale return transaction", tombstoneNamesStale == true)
check("victim's live ledger marks the stale return superseded (online victim)",
	type(DS.GetData(pair.victim).ReturnedTxns) == "table"
		and staleTxId ~= nil
		and DS.GetData(pair.victim).ReturnedTxns[staleTxId] ~= nil
		and DS.GetData(pair.victim).ReturnedTxns[staleTxId].Superseded == true)

-- Condition 4: the victim leaves / crashes and rejoins after the
-- outage. Crash = discard every in-memory cache, reload from the
-- persisted store (no further saves).
DS.LoadData(thief2)
DS.LoadData(pair.victim)
local rV, remV, _, _ = env.raid.RecoverOnRejoin(pair.victim)
local rT, remT, _, _ = env.raid.RecoverOnRejoin(thief2)
check("victim rejoin finds nothing stale to resolve", rV == 0 and remV == 0)
check("thief rejoin finds nothing stale to resolve", rT == 0 and remT == 0)
check("exactly one owner remains after the victim's rejoin",
	H.countOwned(env, { thief2, pair.victim }, pair.targetId) == 1,
	"count=" .. tostring(H.countOwned(env, { thief2, pair.victim }, pair.targetId)))
check("the delivered thief retains the legitimate instance",
	H.findOwned(DS.GetData(thief2), pair.targetId) ~= nil)
check("the stale escrow did NOT resurrect a duplicate with the victim",
	H.findOwned(DS.GetData(pair.victim), pair.targetId) == nil)
check("victim has no placed copy of the stolen Brainrot",
	H.findPlaced(DS.GetData(pair.victim), pair.targetId) == nil)
check("unrelated escrow entry still merged (victim owns the other instance)",
	H.findOwned(DS.GetData(pair.victim), "other-inst-9402") ~= nil)

-- Repeating recovery changes nothing.
local rV2, remV2, _, _ = env.raid.RecoverOnRejoin(pair.victim)
local rT2, remT2, _, _ = env.raid.RecoverOnRejoin(thief2)
DS.LoadData(pair.victim)
DS.LoadData(thief2)
check("repeating recovery + reload changes nothing",
	rV2 == 0 and remV2 == 0 and rT2 == 0 and remT2 == 0
		and H.countOwned(env, { thief2, pair.victim }, pair.targetId) == 1
		and H.findOwned(DS.GetData(pair.victim), pair.targetId) == nil)

H.finish()
