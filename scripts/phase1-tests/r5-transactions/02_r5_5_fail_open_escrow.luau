-- 02_r5_5_fail_open_escrow.luau — R5-5 (P2):
-- Qwen: DataService.InvalidateReturnEscrow() returns SUCCESS when
-- GetDataStore fails to provide a usable store — a fail-open: the
-- delivery commits without ever seeing the victim's escrow sidecar,
-- so a stale return parked there later resurrects a second owner.
-- The fix: a missing store is a failure (not an empty sidecar), the
-- delivery stays blocked while the tombstone cannot be persisted
-- (ConfirmDelivery already fails closed — verified end-to-end
-- here), and the post-yield ownership revalidation is preserved
-- (a return landing during the invalidation yield still wins).
--
-- R5-2 REWRITE (Worker D, 2026-11-20): the thief in §A–§C is now
-- HEALTHY. The old flow stole and delivered with a load-failed
-- thief, which the R5-2 session-health gate now refuses at
-- StealBrainrot and at ConfirmDelivery — and that refusal is the
-- closure of Worker A's decision item: a delivery committed
-- in-memory in a load-failed session can never persist, yet its
-- R4-1 tombstone permanently supersedes the victim's escrow
-- backstop, so if both rejoin first the instance has 0 owners
-- (the old §C asserted 0, not 2). With the gate, the delivery is
-- refused while the thief is unsaveable, the transit stays live,
-- and no tombstone parks — the victim recovers via the escrow.
-- The healthy-thief flow here proves the other side: a delivery
-- committed by a healthy thief persists, the tombstone refuses
-- the stale return, and both rejoining leaves exactly 1 owner.
-- The load-failed-delivery-refusal case lives in test 05 §E.
-- Run: bash scripts/phase1-tests/r5-transactions/run.sh
local R5 = require("./r5_env")
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

local function escrowEntries(userId)
	local list = store:peek(P.escrowKey(userId))
	if type(list) ~= "table" then
		return {}
	end
	return list
end

local function findTombstone(userId, instanceId)
	for _, entry in ipairs(escrowEntries(userId)) do
		if type(entry) == "table" and entry.InstanceId == instanceId and entry.Superseded == true then
			return entry
		end
	end
	return nil
end

local function countEntriesWithTxId(userId, txId)
	local c = 0
	for _, entry in ipairs(escrowEntries(userId)) do
		if type(entry) == "table" and entry.ReturnTxId == txId then
			c += 1
		end
	end
	return c
end

local function tombstoneNames(tombstone, txId)
	if tombstone == nil or type(tombstone.SupersedesReturnTxIds) ~= "table" then
		return false
	end
	for _, tx in ipairs(tombstone.SupersedesReturnTxIds) do
		if tx == txId then
			return true
		end
	end
	return false
end

-- §A — the outage, DataService-level only. R5-2: the steal now
-- needs BOTH sessions healthy, so it happens while the store is
-- UP (below) — but the GetDataStore outage can only be observed
-- BEFORE the first successful getStore(), because DataService
-- CACHES a successful store handle for the life of the server
-- (a failed GetDataStore is not cached, a successful one is).
-- So the outage checks run here, before any load, and the
-- end-to-end delivery-blocked proof moves to §A2 (escrow-key-only
-- write failure, store up).
local staleTxId = "rt-r5-5-stale-001"
local env = R5.newEnv()
local DS = env.dataService

local pair = R5.newPairFixture(9601, 9602)
-- Durable state (seeded directly; seeding bypasses GetDataStore):
-- the victim's stored key does NOT hold the target (the return's
-- victim save failed, so the stored key is the pre-return state),
-- the thief's stored key never held it, and the escrow holds the
-- stale return + one unrelated entry.
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

-- The outage starts before any load or steal has touched the store.
R5.setDataStoreOutage(true)

-- DataService-level: an unavailable store is NOT an empty sidecar.
local okInv, hadStale, invErr = DS.InvalidateReturnEscrow(9602, pair.targetId, "d-r5-5-direct")
check("outage: InvalidateReturnEscrow FAILS (not success) when the store is unavailable",
	okInv == false and invErr == "datastore unavailable",
	"ok=" .. tostring(okInv) .. " err=" .. tostring(invErr))
check("outage: the failed invalidation reports no stale entry seen",
	hadStale == false)
check("outage: the failed invalidation changed nothing in the escrow",
	#escrowEntries(9602) == 2 and findTombstone(9602, pair.targetId) == nil,
	"entries=" .. tostring(#escrowEntries(9602)))

-- The store recovers; the healthy steal happens now.
R5.setDataStoreOutage(false)
R5.loadUnloadedPair(env, pair)
H.steal(env, pair)

-- §A2 — the R5-5 fail-closed, end-to-end, with the store up: the
-- R5-2 session gate passes (both leases probe clean), but ONLY the
-- victim's escrow key fails its UpdateAsync (appendSidecar retries
-- twice — both attempts fail). The delivery must still be refused,
-- by the invalidation, with the transit live, no reward and no
-- tombstone. This is the proof the outage case above can no longer
-- give on its own: the delivery is blocked because the tombstone
-- cannot persist, not merely because the store is down.
store:failUpdateAsyncForKey(P.escrowKey(9602), 2)
local okDelA2, statusDelA2 = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("escrow-write failure: ConfirmDelivery is refused while the tombstone cannot be persisted",
	okDelA2 == false and statusDelA2 == "delivery escrow invalidation unavailable",
	"ok=" .. tostring(okDelA2) .. " status=" .. tostring(statusDelA2))
local thiefOwnedA2 = H.findOwned(DS.GetData(pair.thief), pair.targetId)
check("escrow-write failure: the refused delivery leaves the transit live (thief still carrying)",
	thiefOwnedA2 ~= nil and thiefOwnedA2.InTransit == true)
check("escrow-write failure: the refused delivery pays no reward",
	math.floor(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100000
		and P.pendingTotal(DS.GetData(pair.thief), pair.targetId) == 0,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
check("escrow-write failure: the refused delivery changed nothing in the escrow",
	#escrowEntries(9602) == 2 and findTombstone(9602, pair.targetId) == nil)
store:resetFailures()

-- §B — the store recovers: the same delivery now succeeds and the
-- tombstone lands.
local okDel2, statusDel2 = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("recovery: the delivery succeeds once the store is back",
	okDel2 == true and statusDel2 == nil,
	"ok=" .. tostring(okDel2) .. " status=" .. tostring(statusDel2))
check("recovery: the reward is PAID (healthy thief — not pending, R5-2 rewrite)",
	math.floor(tonumber(DS.GetData(pair.thief).Coins) or 0) == 100300
		and P.pendingTotal(DS.GetData(pair.thief), pair.targetId) == 0,
	"coins=" .. tostring(DS.GetData(pair.thief).Coins))
local tombstone = findTombstone(9602, pair.targetId)
check("recovery: the delivery parked a tombstone in the victim's escrow",
	tombstone ~= nil and tombstone.InstanceId == pair.targetId,
	"entries=" .. tostring(#escrowEntries(9602)))
check("recovery: the tombstone names the stale return transaction",
	tombstoneNames(tombstone, staleTxId))
check("recovery: the stale return entry itself is still parked (superseded, not deleted)",
	countEntriesWithTxId(9602, staleTxId) == 1)
check("recovery: the victim's live ledger marks the stale return superseded (online victim)",
	type(DS.GetData(pair.victim).ReturnedTxns) == "table"
		and DS.GetData(pair.victim).ReturnedTxns[staleTxId] ~= nil
		and DS.GetData(pair.victim).ReturnedTxns[staleTxId].Superseded == true)
local delivered = H.findOwned(DS.GetData(pair.thief), pair.targetId)
check("recovery: the delivered thief holds the instance in memory (no longer in transit)",
	delivered ~= nil and delivered.InTransit ~= true)
check("recovery: exactly one LIVE owner right after the delivery",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1)
check("recovery: the thief's save lands (healthy session — R5-2 rewrite)",
	DS.SaveData(pair.thief) == true)
check("recovery: the thief's stored key holds the delivered copy (delivery persisted)",
	H.findOwned(store:peek(P.mainKey(9601)), pair.targetId) ~= nil)

-- §C — both players rejoin after the outage. The tombstone must
-- refuse the stale return, so the victim gets nothing from the
-- escrow — and the healthy thief's delivery persisted, so the
-- thief keeps the durable copy. Total owners: 1, NOT 2 (and NOT
-- the old 0). R5-2 decision item CLOSED: the old 0-owner outcome
-- came from a delivery committed in-memory in a load-failed
-- session that could never persist, with the tombstone then
-- superseding the victim's escrow backstop. The R5-2 gate refuses
-- that delivery now (test 05 §E); the healthy delivery here
-- persists, so the tombstone correctly refuses the stale return
-- without losing the instance.
DS.LoadData(pair.victim)
check("victim rejoin: the stale return does NOT resurrect a copy (tombstone refused it)",
	H.findOwned(DS.GetData(pair.victim), pair.targetId) == nil)
check("victim rejoin: no placed copy of the stolen Brainrot either",
	H.findPlaced(DS.GetData(pair.victim), pair.targetId) == nil)
check("victim rejoin: the unrelated escrow entry still merged",
	H.findOwned(DS.GetData(pair.victim), "other-inst-9602") ~= nil)
check("victim rejoin: the merge recorded the stale TxId as superseded",
	type(DS.GetData(pair.victim).ReturnedTxns) == "table"
		and DS.GetData(pair.victim).ReturnedTxns[staleTxId] ~= nil
		and DS.GetData(pair.victim).ReturnedTxns[staleTxId].Superseded == true)
DS.LoadData(pair.thief)
check("thief rejoin: the healthy delivery persisted — the thief still owns the Brainrot",
	H.findOwned(DS.GetData(pair.thief), pair.targetId) ~= nil)
check("both rejoin: total owners is 1 (the thief — no duplication, no loss)",
	H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1,
	"count=" .. tostring(H.countOwned(env, { pair.thief, pair.victim }, pair.targetId)))

-- §D — the post-yield ownership revalidation is preserved: a return
-- landing DURING the delivery still wins over it. The store is up
-- here; the stub's one-shot _beforeCommit hook fires on the first
-- UpdateAsync after arming — since R5-2 that is the session gate's
-- lease probe (before the invalidation read), so the return lands
-- before the read rather than inside the tombstone's UpdateAsync.
-- The revalidation still refuses the delivery; the tombstone
-- checks below assert the new interleaving honestly (see note).
local staleTxId2 = "rt-r5-5-stale-002"
local pair2 = R5.newPairFixture(9605, 9606)
local victimStored2 = deepCopy(pair2.victimData)
for i = #victimStored2.OwnedInstances, 1, -1 do
	if victimStored2.OwnedInstances[i].InstanceId == pair2.targetId then
		table.remove(victimStored2.OwnedInstances, i)
	end
end
for i = #victimStored2.Base.Placed, 1, -1 do
	if victimStored2.Base.Placed[i].InstanceId == pair2.targetId then
		table.remove(victimStored2.Base.Placed, i)
	end
end
store:seed(P.mainKey(9606), victimStored2)
store:seed(P.mainKey(9605), deepCopy(pair2.thiefData))
R5.loadUnloadedPair(env, pair2)
store:seed(P.escrowKey(9606), {
	P.escrowRecord(pair2.targetId, { ReturnTxId = staleTxId2 }),
})
H.steal(env, pair2)
store:armBeforeCommit(function()
	env.raid.ReturnStolen(pair2.targetId)
end)
local okDel3, statusDel3 = env.raid.ConfirmDelivery(pair2.thief, pair2.targetId)
check("revalidation: a return landing during the invalidation yield wins",
	okDel3 == false and statusDel3 == "theft resolved during delivery",
	"ok=" .. tostring(okDel3) .. " status=" .. tostring(statusDel3))
check("revalidation: the victim holds the returned Brainrot in memory",
	H.findOwned(DS.GetData(pair2.victim), pair2.targetId) ~= nil)
check("revalidation: the thief no longer holds it",
	H.findOwned(DS.GetData(pair2.thief), pair2.targetId) == nil)
local tombstone2 = findTombstone(9606, pair2.targetId)
-- R5-2 interleaving shift (known limitation, see the R5-2 report
-- section): the _beforeCommit hook fires on the FIRST UpdateAsync
-- after arming — now the R5-2 gate's lease probe, which runs
-- BEFORE the invalidation read, not during the tombstone append.
-- So the return lands before the read, and the fresh return
-- REPLACES the stale entry in the escrow list (both share the
-- legacy sidecar identity "legacy:<instanceId>:0" — the return
-- record carries ReturnTxId but no TxId). The invalidation read
-- therefore sees only the fresh return, and the tombstone
-- supersedes the FRESH transaction, not the stale one. The return
-- still wins the delivery (checks above), and the victim still
-- holds the Brainrot in memory — but the tombstone now also
-- supersedes the victim's fresh-return backstop, so a crash
-- before the victim's save would leave the rejoin without the
-- escrow copy. The normal path below (the victim's leave save
-- lands) preserves the 1-owner outcome; the residual needs a
-- time-ordered invalidation (future work, not this repair).
check("revalidation: the tombstone still parked",
	tombstone2 ~= nil and tombstone2.InstanceId == pair2.targetId)
local newReturnTxId = nil
for _, entry in ipairs(escrowEntries(9606)) do
	if type(entry) == "table" and type(entry.ReturnTxId) == "string"
		and entry.ReturnTxId ~= staleTxId2 and entry.InstanceId == pair2.targetId
	then
		newReturnTxId = entry.ReturnTxId
	end
end
check("revalidation: the interleaved return parked its own fresh transaction",
	newReturnTxId ~= nil,
	"newTxId=" .. tostring(newReturnTxId))
check("revalidation: the stale entry was replaced by the fresh return before the read (shared legacy identity)",
	tombstone2 ~= nil and not tombstoneNames(tombstone2, staleTxId2)
		and countEntriesWithTxId(9606, staleTxId2) == 0)
check("revalidation: the tombstone supersedes the FRESH return (R5-2 interleaving shift — known limitation)",
	newReturnTxId ~= nil and tombstoneNames(tombstone2, newReturnTxId))
check("revalidation: the victim's leave save still lands the returned Brainrot durably",
	DS.SaveData(pair2.victim) == true
		and H.findOwned(store:peek(P.mainKey(9606)), pair2.targetId) ~= nil)

-- §E — DataService-level, store up: a real stale entry gets a
-- tombstone, a repeat re-parks harmlessly, and a genuinely empty
-- sidecar is still (true, false) — empty is not unavailable.
store:seed(P.escrowKey(9603), {
	P.escrowRecord("r5-5-direct", { ReturnTxId = "rt-r5-5-stale-003" }),
})
local okE1, hadE1, _, staleE1 = DS.InvalidateReturnEscrow(9603, "r5-5-direct", "d-r5-5-e1")
check("direct: a stale entry is invalidated with a tombstone",
	okE1 == true and hadE1 == true
		and type(staleE1) == "table" and #staleE1 == 1 and staleE1[1] == "rt-r5-5-stale-003",
	"ok=" .. tostring(okE1) .. " had=" .. tostring(hadE1))
check("direct: the tombstone names the stale transaction",
	tombstoneNames(findTombstone(9603, "r5-5-direct"), "rt-r5-5-stale-003"))
local okE2, hadE2 = DS.InvalidateReturnEscrow(9603, "r5-5-direct", "d-r5-5-e2")
check("direct: repeating the invalidation re-parks harmlessly (still success, still stale)",
	okE2 == true and hadE2 == true)
check("direct: the return entry itself was never duplicated by the repeats",
	countEntriesWithTxId(9603, "rt-r5-5-stale-003") == 1)
local okE3, hadE3, errE3 = DS.InvalidateReturnEscrow(9604, "r5-5-empty", "d-r5-5-e3")
check("direct: a genuinely empty sidecar is (true, false) — empty is not unavailable",
	okE3 == true and hadE3 == false and errE3 == nil,
	"ok=" .. tostring(okE3) .. " had=" .. tostring(hadE3))

H.finish()
