-- 05_r5_2_unhealthy_session_ownership.luau — R5-2 (P0):
-- Block ownership operations in unhealthy sessions.
--
-- Qwen reproduced: a contested thief steals from a healthy victim;
-- the victim's removal saves; the thief cannot save; the instance
-- disappears when the thief leaves. Also contested-victim duplication
-- and load-failed thief loss. The fix gates every ownership-changing
-- operation on BOTH parties' session health, using the R5-4 machinery
-- (IsSaveable / GetSaveBlockedReason for the local state, plus a
-- stored-lease proof via AcquireSessionLease at the steal/delivery
-- commit points, where a lease lost since the last check can still
-- lose or duplicate an instance). Recovery paths (ReturnStolen,
-- RecoverStaleTransit, RecoverOnRejoin, the PlaceBrainrot whole-record
-- reinsert shape) are EXEMPT: blocking them would create the loss
-- the gate exists to prevent.
--
-- Sections:
--   (A) Contested thief steals from a healthy victim -> refused.
--       (The local view still looks healthy; only the stored-lease
--       probe catches it.)
--   (B) Contested victim stolen from by a healthy thief -> refused.
--   (C) Load-failed thief / load-failed victim attempt a steal ->
--       refused with load_failed.
--   (D) Session becomes contested DURING an active theft (mid-channel
--       takeover via the steal-channel test hook) -> refused after
--       the channel; the victim is untouched.
--   (E) DECISION ITEM (Worker-A §C): a delivery committed in-memory
--       in a load-failed session can never persist, yet its R4-1
--       tombstone permanently supersedes the victim's escrow backstop
--       (old test 02 §C: 0 owners). Gated: a load-failed thief's
--       delivery is refused while a stale return escrow exists for
--       the instance — transit stays live, no reward, NO tombstone —
--       so the victim recovers via the escrow: exactly 1 owner.
--   (F) Player leaves during rejection/recovery: the leave hook still
--       returns the Brainrot (recovery-exempt) and both rejoin to
--       exactly 1 owner.
--   (G) Healthy end-to-end positive control: steal -> deliver ->
--       rejoin, exactly 1 owner (the gates must not break the
--       healthy path).
--   (H) PlaceBrainrot / StoreBrainrot gates (real BaseService):
--       normal place/store refused in an unhealthy session; the
--       whole-record reinsert shape stays exempt (recovery); a stolen
--       delivery through PlaceBrainrot is refused for a contested
--       thief and succeeds once the lease is released.
-- Run: bash scripts/phase1-tests/r5-transactions/run.sh
local R5 = require("./r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv()
local DS = env.dataService
local DSB = require("./services/DataServiceB")
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

local function releaseLeaseB(player)
	DSB.ReleaseSessionLease(player)
end

-- loadSplitPair(env, pair, failThief): seed both main keys, then load
-- one party healthy and the other with a failed load (3 GetAsync
-- failures = LOAD_RETRIES), then merge the fixture tables into the
-- live caches (mirrors R5.loadUnloadedPair). failThief=true fails the
-- thief's load; false fails the victim's.
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

local function countLive(envArg, players, instanceId)
	return H.countOwned(envArg, players, instanceId)
end

-- --- (A) Contested thief steals from a healthy victim ------------
local pairA = P.newLoadedPair(env, 9701, 9702)
takeLeaseWithB(pairA.thief)
check("(A) server B holds the thief's lease now",
	DSB.GetSessionLeaseState(pairA.thief).Owned == true)
check("(A) server A's LOCAL view still looks healthy (no flag set yet)",
	DS.IsSaveable(pairA.thief) == true and DS.GetSaveBlockedReason(pairA.thief) == nil)
local okA, reasonA = raid.StealBrainrot(pairA.thief, pairA.victim.UserId, pairA.targetId)
check("(A) contested thief's steal is REFUSED",
	okA == false, "ok=" .. tostring(okA) .. " reason=" .. tostring(reasonA))
check("(A) refusal names the session/lease (not a gameplay reason)",
	type(reasonA) == "string" and (string.find(reasonA, "session") ~= nil or string.find(reasonA, "lease") ~= nil),
	"reason=" .. tostring(reasonA))
check("(A) victim still owns the placed Brainrot",
	H.findOwned(DS.GetData(pairA.victim), pairA.targetId) ~= nil
		and H.findPlaced(DS.GetData(pairA.victim), pairA.targetId) ~= nil)
check("(A) thief holds nothing; exactly one owner",
	H.findOwned(DS.GetData(pairA.thief), pairA.targetId) == nil
		and countLive(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)
check("(A) the refused steal burned no cooldown state (no transit, no carry)",
	pairA.thief:GetAttribute("CarryingStolen") == nil
		or pairA.thief:GetAttribute("CarryingStolen") == "")
-- Release B: the same steal now succeeds (the refusal was session-only).
releaseLeaseB(pairA.thief)
DS.LoadData(pairA.thief)
check("(A) after B releases, the thief is saveable again",
	DS.IsSaveable(pairA.thief) == true and DS.GetSaveBlockedReason(pairA.thief) == nil)
local okReA = raid.StealBrainrot(pairA.thief, pairA.victim.UserId, pairA.targetId)
check("(A) after B releases, the same steal SUCCEEDS",
	okReA == true
		and H.findOwned(DS.GetData(pairA.thief), pairA.targetId) ~= nil)
raid.ReturnStolen(pairA.targetId)

-- --- (B) Contested victim stolen from by a healthy thief ---------
local pairB = P.newLoadedPair(env, 9711, 9712)
takeLeaseWithB(pairB.victim)
check("(B) server B holds the victim's lease now",
	DSB.GetSessionLeaseState(pairB.victim).Owned == true)
local okB, reasonB = raid.StealBrainrot(pairB.thief, pairB.victim.UserId, pairB.targetId)
check("(B) steal from a contested victim is REFUSED",
	okB == false, "ok=" .. tostring(okB) .. " reason=" .. tostring(reasonB))
check("(B) refusal names the victim's session",
	type(reasonB) == "string" and string.find(reasonB, "victim") ~= nil,
	"reason=" .. tostring(reasonB))
check("(B) victim still owns the placed Brainrot",
	H.findOwned(DS.GetData(pairB.victim), pairB.targetId) ~= nil
		and H.findPlaced(DS.GetData(pairB.victim), pairB.targetId) ~= nil)
check("(B) exactly one owner after the refused steal",
	countLive(env, { pairB.thief, pairB.victim }, pairB.targetId) == 1)
releaseLeaseB(pairB.victim)
DS.LoadData(pairB.victim)
local okReB = raid.StealBrainrot(pairB.thief, pairB.victim.UserId, pairB.targetId)
check("(B) after B releases, the same steal SUCCEEDS",
	okReB == true
		and H.findOwned(DS.GetData(pairB.thief), pairB.targetId) ~= nil)
raid.ReturnStolen(pairB.targetId)

-- --- (C) Load-failed thief / victim attempt a steal --------------
local pairC = loadSplitPair(R5.newPairFixture(9721, 9722), true)
check("(C) thief's session is load-failed / unsaveable",
	DS.IsSaveable(pairC.thief) == false
		and DS.GetSaveBlockedReason(pairC.thief) == "load_failed")
local okC, reasonC = raid.StealBrainrot(pairC.thief, pairC.victim.UserId, pairC.targetId)
check("(C) load-failed thief's steal is REFUSED",
	okC == false, "ok=" .. tostring(okC) .. " reason=" .. tostring(reasonC))
check("(C) refusal names load_failed",
	type(reasonC) == "string" and string.find(reasonC, "load_failed") ~= nil,
	"reason=" .. tostring(reasonC))
check("(C) victim still owns the placed Brainrot",
	H.findOwned(DS.GetData(pairC.victim), pairC.targetId) ~= nil
		and H.findPlaced(DS.GetData(pairC.victim), pairC.targetId) ~= nil)
check("(C) victim's stored key is untouched (still holds the target)",
	H.findOwned(store:peek(P.mainKey(pairC.victim.UserId)), pairC.targetId) ~= nil)

local pairC2 = loadSplitPair(R5.newPairFixture(9723, 9724), false)
check("(C2) victim's session is load-failed / unsaveable",
	DS.IsSaveable(pairC2.victim) == false
		and DS.GetSaveBlockedReason(pairC2.victim) == "load_failed")
local okC2, reasonC2 = raid.StealBrainrot(pairC2.thief, pairC2.victim.UserId, pairC2.targetId)
check("(C2) steal from a load-failed victim is REFUSED",
	okC2 == false, "ok=" .. tostring(okC2) .. " reason=" .. tostring(reasonC2))
check("(C2) refusal names the victim's load failure",
	type(reasonC2) == "string"
		and string.find(reasonC2, "victim") ~= nil
		and string.find(reasonC2, "load_failed") ~= nil,
	"reason=" .. tostring(reasonC2))
check("(C2) exactly one owner after the refused steal",
	countLive(env, { pairC2.thief, pairC2.victim }, pairC2.targetId) == 1)

-- --- (D) Session becomes contested DURING an active theft --------
local pairD = P.newLoadedPair(env, 9731, 9732)
local hookFired = false
check("(D) the steal-channel test hook exists (R5-2 test API)",
	type(raid._TestSetStealChannelHook) == "function")
if type(raid._TestSetStealChannelHook) == "function" then
	raid._TestSetStealChannelHook(function(_thief, _instanceId)
		if hookFired then
			return
		end
		hookFired = true
		takeLeaseWithB(pairD.thief)
	end)
end
local okD, reasonD = raid.StealBrainrot(pairD.thief, pairD.victim.UserId, pairD.targetId)
if type(raid._TestSetStealChannelHook) == "function" then
	raid._TestSetStealChannelHook(nil)
end
check("(D) the mid-channel takeover hook fired",
	hookFired == true)
check("(D) steal is REFUSED when the lease is lost mid-channel",
	okD == false, "ok=" .. tostring(okD) .. " reason=" .. tostring(reasonD))
check("(D) refusal names the session/lease",
	type(reasonD) == "string" and (string.find(reasonD, "session") ~= nil or string.find(reasonD, "lease") ~= nil),
	"reason=" .. tostring(reasonD))
check("(D) victim is untouched: still owns the placed Brainrot",
	H.findOwned(DS.GetData(pairD.victim), pairD.targetId) ~= nil
		and H.findPlaced(DS.GetData(pairD.victim), pairD.targetId) ~= nil)
check("(D) no transit was created (thief holds nothing)",
	H.findOwned(DS.GetData(pairD.thief), pairD.targetId) == nil)
check("(D) only the stored-lease probe caught it: A's local flags are still clear",
	DS.IsSaveable(pairD.thief) == true and DS.GetSaveBlockedReason(pairD.thief) == nil)
check("(D) the stored lease names server B",
	DSB.GetSessionLeaseState(pairD.thief).Owned == true)
releaseLeaseB(pairD.thief)
DS.LoadData(pairD.thief)
-- The re-steal is on cooldown: the post-channel refusal stands
-- exactly like a failed channel (the 60 s cooldown was burned when
-- the channel started, before the takeover). The pre-channel
-- refusals in §A/§B burn nothing — the cooldown is only set once
-- the channel starts.
local okReD, reasonReD = raid.StealBrainrot(pairD.thief, pairD.victim.UserId, pairD.targetId)
check("(D) after B releases, the re-steal is on cooldown (the interrupted attempt burned it)",
	okReD == false and reasonReD == "steal on cooldown",
	"ok=" .. tostring(okReD) .. " reason=" .. tostring(reasonReD))
check("(D) the victim still owns the Brainrot (no theft happened)",
	H.findOwned(DS.GetData(pairD.victim), pairD.targetId) ~= nil)

-- --- (E) DECISION ITEM: load-failed thief delivery + stale escrow -
-- Setup: a healthy steal (transit live), a stale return parked in the
-- victim's escrow, the victim's stored key holding the pre-return
-- state (no target). The thief's session then degrades to load-failed
-- AFTER the steal (a failed reload replaces the cache with defaults;
-- the pre-steal live data is merged back, so the thief is load-failed
-- AND still carrying — the _inTransit snapshot itself survives the
-- reload, exactly as it survives a server-side session change).
local staleTxIdE = "rt-r5-2-stale-001"
local pairE = P.newLoadedPair(env, 9741, 9742)
H.steal(env, pairE)
local victimStoredE = deepCopy(DS.GetData(pairE.victim))
-- The victim's live data lost the target at steal time; mirror that
-- in the stored key (the steal-time removal persisted) so a rejoin
-- does not resurrect it from the main key.
for i = #victimStoredE.OwnedInstances, 1, -1 do
	if victimStoredE.OwnedInstances[i].InstanceId == pairE.targetId then
		table.remove(victimStoredE.OwnedInstances, i)
	end
end
for i = #victimStoredE.Base.Placed, 1, -1 do
	if victimStoredE.Base.Placed[i].InstanceId == pairE.targetId then
		table.remove(victimStoredE.Base.Placed, i)
	end
end
store:seed(P.mainKey(pairE.victim.UserId), victimStoredE)
store:seed(P.escrowKey(pairE.victim.UserId), {
	P.escrowRecord(pairE.targetId, { ReturnTxId = staleTxIdE }),
	P.escrowRecord("other-inst-9742", { CharacterId = "turbo_turnip", Slot = 1 }),
})
local thiefLiveBefore = deepCopy(DS.GetData(pairE.thief))
store:failGetAsyncForKey(P.mainKey(pairE.thief.UserId), 3)
DS.LoadData(pairE.thief)
store:resetFailures()
check("(E) setup: the thief's reload failed, session is load-failed",
	DS.IsSaveable(pairE.thief) == false
		and DS.GetSaveBlockedReason(pairE.thief) == "load_failed")
local liveThiefE = DS.GetData(pairE.thief)
for k, v in pairs(thiefLiveBefore) do
	liveThiefE[k] = v
end
check("(E) setup: the thief is load-failed AND still carrying the Brainrot",
	H.findOwned(DS.GetData(pairE.thief), pairE.targetId) ~= nil
		and H.findOwned(DS.GetData(pairE.thief), pairE.targetId).InTransit == true
		and env.carry.GetCarried(pairE.thief) ~= nil)
local coinsBeforeE = math.floor(tonumber(DS.GetData(pairE.thief).Coins) or 0)
local okE, reasonE = raid.ConfirmDelivery(pairE.thief, pairE.targetId)
check("(E) load-failed thief's delivery is REFUSED while a stale escrow exists",
	okE == false, "ok=" .. tostring(okE) .. " reason=" .. tostring(reasonE))
check("(E) refusal names the thief's load failure",
	type(reasonE) == "string" and string.find(reasonE, "load_failed") ~= nil,
	"reason=" .. tostring(reasonE))
check("(E) transit stays live (thief still carrying, no state change)",
	H.findOwned(DS.GetData(pairE.thief), pairE.targetId) ~= nil
		and H.findOwned(DS.GetData(pairE.thief), pairE.targetId).InTransit == true)
check("(E) no reward was paid or parked",
	math.floor(tonumber(DS.GetData(pairE.thief).Coins) or 0) == coinsBeforeE
		and P.pendingTotal(DS.GetData(pairE.thief), pairE.targetId) == 0,
	"coins=" .. tostring(DS.GetData(pairE.thief).Coins))
check("(E) NO tombstone was parked (the refusal happened before invalidation)",
	findTombstone(pairE.victim.UserId, pairE.targetId) == nil
		and #escrowEntries(pairE.victim.UserId) == 2,
	"entries=" .. tostring(#escrowEntries(pairE.victim.UserId)))
-- Recovery is NOT blocked: the return still restores the victim.
local okRetE = raid.ReturnStolen(pairE.targetId)
check("(E) the return still works (recovery is exempt from the gate)",
	okRetE == true)
check("(E) victim holds the Brainrot after the return",
	H.findOwned(DS.GetData(pairE.victim), pairE.targetId) ~= nil)
check("(E) exactly one owner after the return",
	countLive(env, { pairE.thief, pairE.victim }, pairE.targetId) == 1)
DS.LoadData(pairE.victim)
DS.LoadData(pairE.thief)
raid.RecoverOnRejoin(pairE.victim)
raid.RecoverOnRejoin(pairE.thief)
check("(E) both rejoin: exactly ONE owner (the victim, via the escrow backstop — not 0)",
	countLive(env, { pairE.thief, pairE.victim }, pairE.targetId) == 1,
	"count=" .. tostring(countLive(env, { pairE.thief, pairE.victim }, pairE.targetId)))
check("(E) the victim owns it after rejoin (the stale escrow was NOT superseded)",
	H.findOwned(DS.GetData(pairE.victim), pairE.targetId) ~= nil)

-- --- (F) Player leaves during rejection / recovery ---------------
local pairF = P.newLoadedPair(env, 9751, 9752)
H.steal(env, pairF)
takeLeaseWithB(pairF.thief)
local okF, reasonF = raid.ConfirmDelivery(pairF.thief, pairF.targetId)
check("(F) contested thief's delivery is REFUSED",
	okF == false, "ok=" .. tostring(okF) .. " reason=" .. tostring(reasonF))
check("(F) transit stays live after the refused delivery",
	H.findOwned(DS.GetData(pairF.thief), pairF.targetId) ~= nil
		and H.findOwned(DS.GetData(pairF.thief), pairF.targetId).InTransit == true)
local returnedF = raid.HandlePlayerLeaving(pairF.thief)
check("(F) the leave hook still returns the Brainrot (recovery-exempt, contested or not)",
	returnedF == 1, "returned=" .. tostring(returnedF))
check("(F) victim holds the Brainrot after the leave",
	H.findOwned(DS.GetData(pairF.victim), pairF.targetId) ~= nil
		and H.findPlaced(DS.GetData(pairF.victim), pairF.targetId) ~= nil)
check("(F) exactly one owner after the leave",
	countLive(env, { pairF.thief, pairF.victim }, pairF.targetId) == 1)
check("(F) the contested thief's leave save still refuses (no phantom persist)",
	DS.SaveData(pairF.thief) == false)
releaseLeaseB(pairF.thief)
DS.LoadData(pairF.victim)
DS.LoadData(pairF.thief)
raid.RecoverOnRejoin(pairF.victim)
raid.RecoverOnRejoin(pairF.thief)
check("(F) both rejoin: exactly one owner (the victim)",
	countLive(env, { pairF.thief, pairF.victim }, pairF.targetId) == 1,
	"count=" .. tostring(countLive(env, { pairF.thief, pairF.victim }, pairF.targetId)))

-- --- (G) Healthy end-to-end positive control ----------------------
local pairG = P.newLoadedPair(env, 9761, 9762)
H.steal(env, pairG)
local okG, statusG = raid.ConfirmDelivery(pairG.thief, pairG.targetId)
check("(G) healthy delivery succeeds",
	okG == true, "ok=" .. tostring(okG) .. " status=" .. tostring(statusG))
check("(G) exactly one owner after delivery (the thief)",
	countLive(env, { pairG.thief, pairG.victim }, pairG.targetId) == 1
		and H.findOwned(DS.GetData(pairG.thief), pairG.targetId) ~= nil)
check("(G) both saves land",
	DS.SaveData(pairG.victim) == true and DS.SaveData(pairG.thief) == true)
DS.LoadData(pairG.victim)
DS.LoadData(pairG.thief)
raid.RecoverOnRejoin(pairG.victim)
raid.RecoverOnRejoin(pairG.thief)
check("(G) both rejoin: exactly one owner (the thief)",
	countLive(env, { pairG.thief, pairG.victim }, pairG.targetId) == 1
		and H.findOwned(DS.GetData(pairG.thief), pairG.targetId) ~= nil,
	"count=" .. tostring(countLive(env, { pairG.thief, pairG.victim }, pairG.targetId)))

-- --- (H) PlaceBrainrot / StoreBrainrot gates (real BaseService) ----
local base = H.newBaseEnv(env)

-- H-a: healthy place + store work (positive controls).
local pairH = P.newLoadedPair(env, 9771, 9772)
local plotHT = base.AssignBase(pairH.thief)
base.AssignBase(pairH.victim)
local ownedEvo = H.findOwned(DS.GetData(pairH.thief), pairH.prefix .. "evo_1")
assert(env.carry.PickupOwned(pairH.thief, ownedEvo), "H setup: PickupOwned evo_1 must succeed")
H.setRootPosition(pairH.thief, H.pedestalPosition(plotHT, 1))
local okPlaceH, placedH = base.PlaceBrainrot(pairH.thief, pairH.prefix .. "evo_1", 1)
check("(H-a) healthy place succeeds",
	okPlaceH == true, "err=" .. tostring(placedH))
local okStoreH = base.StoreBrainrot(pairH.thief, pairH.prefix .. "evo_1")
check("(H-a) healthy store succeeds",
	okStoreH == true)
check("(H-a) instance is unplaced again after the store",
	H.findPlaced(DS.GetData(pairH.thief), pairH.prefix .. "evo_1") == nil
		and H.findOwned(DS.GetData(pairH.thief), pairH.prefix .. "evo_1") ~= nil)

-- H-b: load-failed player — place and store are both refused.
local pairHb = loadSplitPair(R5.newPairFixture(9773, 9774), true)
local plotHbT = base.AssignBase(pairHb.thief)
base.AssignBase(pairHb.victim)
check("(H-b) setup: thief is load-failed",
	DS.IsSaveable(pairHb.thief) == false
		and DS.GetSaveBlockedReason(pairHb.thief) == "load_failed")
local ownedEvoB = H.findOwned(DS.GetData(pairHb.thief), pairHb.prefix .. "evo_1")
assert(env.carry.PickupOwned(pairHb.thief, ownedEvoB), "H-b setup: PickupOwned must succeed")
H.setRootPosition(pairHb.thief, H.pedestalPosition(plotHbT, 1))
local okPlaceHb, errPlaceHb = base.PlaceBrainrot(pairHb.thief, pairHb.prefix .. "evo_1", 1)
check("(H-b) place in a load-failed session is REFUSED",
	okPlaceHb == false, "ok=" .. tostring(okPlaceHb) .. " err=" .. tostring(errPlaceHb))
check("(H-b) refusal names load_failed",
	type(errPlaceHb) == "string" and string.find(errPlaceHb, "load_failed") ~= nil,
	"err=" .. tostring(errPlaceHb))
check("(H-b) instance stays unplaced and owned (nothing stranded)",
	H.findPlaced(DS.GetData(pairHb.thief), pairHb.prefix .. "evo_1") == nil
		and H.findOwned(DS.GetData(pairHb.thief), pairHb.prefix .. "evo_1") ~= nil)
local pairHb2 = loadSplitPair(R5.newPairFixture(9775, 9776), false)
base.AssignBase(pairHb2.thief)
base.AssignBase(pairHb2.victim)
local okStoreHb, errStoreHb = base.StoreBrainrot(pairHb2.victim, pairHb2.targetId)
check("(H-b) store in a load-failed session is REFUSED",
	okStoreHb == false, "ok=" .. tostring(okStoreHb) .. " err=" .. tostring(errStoreHb))
check("(H-b) placed copy survives the refused store",
	H.findPlaced(DS.GetData(pairHb2.victim), pairHb2.targetId) ~= nil
		and H.findOwned(DS.GetData(pairHb2.victim), pairHb2.targetId) ~= nil)

-- H-c: contested-then-flagged player — store refused, placed intact.
local pairHc = P.newLoadedPair(env, 9777, 9778)
local plotHcT = base.AssignBase(pairHc.thief)
base.AssignBase(pairHc.victim)
local ownedTrait = H.findOwned(DS.GetData(pairHc.thief), pairHc.prefix .. "trait_1")
assert(env.carry.PickupOwned(pairHc.thief, ownedTrait), "H-c setup: PickupOwned must succeed")
H.setRootPosition(pairHc.thief, H.pedestalPosition(plotHcT, 1))
assert(base.PlaceBrainrot(pairHc.thief, pairHc.prefix .. "trait_1", 1), "H-c setup: healthy place must succeed")
takeLeaseWithB(pairHc.thief)
check("(H-c) setup: a save attempt after the takeover flags the session lost",
	DS.SaveData(pairHc.thief) == false
		and DS.GetSaveBlockedReason(pairHc.thief) == "session_lost")
local okStoreHc, errStoreHc = base.StoreBrainrot(pairHc.thief, pairHc.prefix .. "trait_1")
check("(H-c) store in a session-lost session is REFUSED",
	okStoreHc == false, "ok=" .. tostring(okStoreHc) .. " err=" .. tostring(errStoreHc))
check("(H-c) placed copy survives the refused store",
	H.findPlaced(DS.GetData(pairHc.thief), pairHc.prefix .. "trait_1") ~= nil)
releaseLeaseB(pairHc.thief)

-- H-d: the whole-record reinsert shape stays EXEMPT (recovery).
local pairHd = P.newLoadedPair(env, 9779, 9780)
base.AssignBase(pairHd.thief)
base.AssignBase(pairHd.victim)
takeLeaseWithB(pairHd.thief)
check("(H-d) setup: a save attempt after the takeover flags the session lost",
	DS.SaveData(pairHd.thief) == false
		and DS.GetSaveBlockedReason(pairHd.thief) == "session_lost")
local reinsertRecord = {
	InstanceId = pairHd.prefix .. "carry_1",
	CharacterId = "wobble_waffleton",
	Slot = 1,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = os.time(),
}
local okReinsert, errReinsert = base.PlaceBrainrot(pairHd.thief, reinsertRecord)
check("(H-d) recovery reinsert (table shape) still works in an unhealthy session",
	okReinsert == true, "err=" .. tostring(errReinsert))
check("(H-d) the reinserted placed copy exists",
	H.findPlaced(DS.GetData(pairHd.thief), pairHd.prefix .. "carry_1") ~= nil)
releaseLeaseB(pairHd.thief)

-- H-e: stolen delivery through PlaceBrainrot with a contested thief.
local pairHe = P.newLoadedPair(env, 9781, 9782)
local plotHeT = base.AssignBase(pairHe.thief)
base.AssignBase(pairHe.victim)
H.steal(env, pairHe)
takeLeaseWithB(pairHe.thief)
H.setRootPosition(pairHe.thief, H.pedestalPosition(plotHeT, 1))
local okPlaceHe, errPlaceHe = base.PlaceBrainrot(pairHe.thief, pairHe.targetId, 1)
check("(H-e) stolen delivery via Place is REFUSED for a contested thief",
	okPlaceHe == false, "ok=" .. tostring(okPlaceHe) .. " err=" .. tostring(errPlaceHe))
check("(H-e) transit stays live after the refused delivery",
	H.findOwned(DS.GetData(pairHe.thief), pairHe.targetId) ~= nil
		and H.findOwned(DS.GetData(pairHe.thief), pairHe.targetId).InTransit == true)
check("(H-e) no placed copy was built by the refused delivery",
	H.findPlaced(DS.GetData(pairHe.thief), pairHe.targetId) == nil)
releaseLeaseB(pairHe.thief)
H.setRootPosition(pairHe.thief, H.pedestalPosition(plotHeT, 1))
local okPlaceHe2, errPlaceHe2 = base.PlaceBrainrot(pairHe.thief, pairHe.targetId, 1)
check("(H-e) after B releases, the same delivery SUCCEEDS",
	okPlaceHe2 == true, "err=" .. tostring(errPlaceHe2))
check("(H-e) exactly one owner after the recovered delivery",
	countLive(env, { pairHe.thief, pairHe.victim }, pairHe.targetId) == 1
		and H.findOwned(DS.GetData(pairHe.thief), pairHe.targetId) ~= nil)

H.finish()
