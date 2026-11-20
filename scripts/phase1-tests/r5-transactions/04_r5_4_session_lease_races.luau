-- 04_r5_4_session_lease_races.luau — R5-4 (P1):
-- Fix the session-lease races left open by R4-7:
--   (1) refreshSessionLease extended the LOCAL cached expiry even
--       when the stored lease belonged to another server (the
--       UpdateAsync result was never checked);
--   (2) SaveData checked the lease only BEFORE the _saving wait, so
--       a lease lost DURING the wait still let the save land;
--   (3) SaveData never revalidated before SetAsync retries, so a
--       server that lost its lease mid-save overwrote newer data;
--   (4) a failed lease read fell back to the cached lease and
--       authorised the write blindly (the R4 partition limit).
--
-- The R5-4 rule (see docs/R5_REPAIRS_REPORT.md, Worker C): a lease
-- check verifies ownership against the STORED lease on every check.
-- A failed read is resolved by an atomic proof: a conditional
-- UpdateAsync whose RESULT names the owner. The proof returning this
-- server proves ownership (the save proceeds); the proof returning
-- another live owner, or failing outright, refuses THIS save attempt
-- (a failed proof alone never poisons the session — the next save
-- re-checks). The local cached expiry is extended ONLY when an
-- UpdateAsync result actually confirms this server owns the lease.
-- The contested/lost state stays queryable (IsSessionContested,
-- GetSaveBlockedReason, GetSessionLeaseState) for the R5-2 gates.
--
-- Two module instances (DataService and DataServiceB) stand in for
-- two servers sharing one stub store (the r4 test 06 pattern).
-- Sections:
--   (A) Lease expires during a SaveData wait; server B acquires and
--       writes newer data; server A resumes its save -> REFUSED and
--       the newer profile survives.
--   (B) Lease GetAsync fails while server B owns the lease -> the
--       stale server's save is REFUSED (proof UpdateAsync names B).
--   (C) Legitimate handover: A releases, B acquires and saves, B
--       releases, A re-acquires and saves; the server that lost the
--       lease cannot keep saving afterwards.
--   (D) Cached-lease extension: a lease taken over mid-save must NOT
--       extend A's local expiry, must mark A lost, and must not let
--       a later save through on a failed read.
--   (E) Crash and expiry recovery: an expired lease lets a new
--       server take over (no permanent lockout).
--   (F) The owner's save is PRESERVED when the lease is verifiably
--       ours and healthy: a failed read with a live own lease is
--       proven by UpdateAsync and the save lands.
--   (G) Per-retry revalidation: a lease lost between SetAsync
--       attempt 1 (failed) and attempt 2 aborts the save before the
--       retry writes.
-- Run: bash scripts/phase1-tests/r5-transactions/run.sh
local R5 = require("./r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv()
local DSA = env.dataService
local DSB = require("./services/DataServiceB")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function leaseKey(userId)
	return "Brainrot_Session_" .. tostring(userId)
end

local function leaseState(DS, player)
	if type(DS.GetSessionLeaseState) ~= "function" then
		return nil
	end
	return DS.GetSessionLeaseState(player)
end

-- --- (A) Lease lost DURING the _saving wait ------------------------
local playerA = R5.newLoadedPlayer(env, 9541, 5000)
assert(DSA.SaveData(playerA) == true, "setup (A): server A baseline save must land")
DSA.AddCoins(playerA, 1000)
check("(A) setup: server A cache holds 6000, stored key holds 5000",
	(tonumber(DSA.GetData(playerA).Coins) or 0) == 6000
		and (tonumber(store:peek(P.mainKey(playerA.UserId)).Coins) or 0) == 5000)
-- Hold A's _saving flag; the wait hook runs server B's REAL
-- takeover mid-wait (A's stored lease expires, B loads + acquires,
-- B writes newer data), then releases the wait. The stored value
-- right after B's write is captured inside the hook: by the time
-- SaveData returns, A's resumed save may already have overwritten
-- it (that overwrite is exactly the bug).
local takeoverStoredCoins = nil
DSA._TestSetWaitHook(function(_player)
	store:seed(leaseKey(playerA.UserId), {
		ServerId = DSA.GetServerId(),
		AcquiredAt = os.time() - 200,
		ExpiresAt = os.time() - 10,
	})
	DSB.LoadData(playerA)
	DSB.AddCoins(playerA, 5000)
	assert(DSB.SaveData(playerA) == true, "setup (A): server B takeover save must land")
	takeoverStoredCoins = tonumber(store:peek(P.mainKey(playerA.UserId)).Coins)
	DSA._TestSetSavingFlag(playerA, false)
	DSA._TestSetWaitHook(nil)
end)
DSA._TestSetSavingFlag(playerA, true)
local okSaveA = DSA.SaveData(playerA)
DSA._TestSetWaitHook(nil)
DSA._TestSetSavingFlag(playerA, false)
check("(A) server B took over mid-wait and wrote newer data (stored key was 10000 at takeover)",
	takeoverStoredCoins == 10000, "takeoverStoredCoins=" .. tostring(takeoverStoredCoins))
check("(A) the stale server's resumed save is REFUSED after the wait",
	okSaveA == false)
check("(A) the newer profile survives: stored key still holds B's 10000, not A's 6000",
	(tonumber(store:peek(P.mainKey(playerA.UserId)).Coins) or 0) == 10000)
check("(A) the stale server is marked as having lost the session",
	DSA.IsSessionContested(playerA) == true
		and DSA.GetSaveBlockedReason(playerA) == "session_lost")

-- --- (B) Lease GetAsync fails while another server owns it --------
local playerB = R5.newLoadedPlayer(env, 9542, 5000)
assert(DSA.SaveData(playerB) == true, "setup (B): server A baseline save must land")
DSA.AddCoins(playerB, 1000)
-- Server B owns the stored lease now; A's cache still looks live
-- (stale: A never re-read the lease).
store:seed(leaseKey(playerB.UserId), {
	ServerId = DSB.GetServerId(),
	AcquiredAt = os.time(),
	ExpiresAt = os.time() + 90,
})
store:failGetAsyncForKey(leaseKey(playerB.UserId), 1)
local okSaveB = DSA.SaveData(playerB)
store:resetFailures()
check("(B) the stale server's save is REFUSED when the lease read fails under another owner",
	okSaveB == false)
check("(B) the stored key is untouched (5000, not A's 6000)",
	(tonumber(store:peek(P.mainKey(playerB.UserId)).Coins) or 0) == 5000)
check("(B) the stale server is marked as having lost the session",
	DSA.IsSessionContested(playerB) == true
		and DSA.GetSaveBlockedReason(playerB) == "session_lost")
local stateB = leaseState(DSA, playerB)
check("(B) the lease state is queryable and reports Lost",
	stateB ~= nil and stateB.Lost == true and stateB.Owned == false)

-- --- (C) Legitimate handover ---------------------------------------
local playerC = R5.newLoadedPlayer(env, 9543, 5000)
assert(DSA.SaveData(playerC) == true, "setup (C): server A baseline save must land")
DSA.ReleaseSessionLease(playerC)
DSB.LoadData(playerC)
check("(C) after A releases, B acquires the lease and is saveable",
	DSB.IsSaveable(playerC) == true and DSB.GetSaveBlockedReason(playerC) == nil)
DSB.AddCoins(playerC, 5000)
check("(C) B's save lands (stored key 10000)",
	DSB.SaveData(playerC) == true
		and (tonumber(store:peek(P.mainKey(playerC.UserId)).Coins) or 0) == 10000)
local stateC1 = leaseState(DSB, playerC)
check("(C) B's lease state reports Owned while B holds it",
	stateC1 ~= nil and stateC1.Owned == true and stateC1.Lost == false)
DSB.ReleaseSessionLease(playerC)
DSA.LoadData(playerC)
check("(C) after B releases, A re-acquires and is saveable again",
	DSA.IsSaveable(playerC) == true and DSA.GetSaveBlockedReason(playerC) == nil)
DSA.AddCoins(playerC, 100)
check("(C) A's save lands after re-acquiring (stored key 10100)",
	DSA.SaveData(playerC) == true
		and (tonumber(store:peek(P.mainKey(playerC.UserId)).Coins) or 0) == 10100)
DSB.AddCoins(playerC, 9999)
check("(C) the server that lost the lease cannot keep saving afterwards",
	DSB.SaveData(playerC) == false
		and (tonumber(store:peek(P.mainKey(playerC.UserId)).Coins) or 0) == 10100)
local stateC2 = leaseState(DSB, playerC)
check("(C) the losing server's lease state reports Lost after its refused save",
	stateC2 ~= nil and stateC2.Lost == true and stateC2.Owned == false)

-- --- (D) Cached-lease extension on a mid-save takeover ------------
local playerD = R5.newLoadedPlayer(env, 9544, 5000)
assert(DSA.SaveData(playerD) == true, "setup (D): server A baseline save must land")
DSA.AddCoins(playerD, 1000)
local stateD0 = leaseState(DSA, playerD)
local expiryBefore = nil
if stateD0 ~= nil then
	expiryBefore = stateD0.LeaseExpiresAt
end
-- Server B takes the lease over DURING A's SetAsync commit window.
store:armBeforeCommit(function()
	store:seed(leaseKey(playerD.UserId), {
		ServerId = DSB.GetServerId(),
		AcquiredAt = os.time(),
		ExpiresAt = os.time() + 90,
	})
end)
local okSaveD = DSA.SaveData(playerD)
check("(D) the in-flight save itself lands (the lease check passed before the takeover)",
	okSaveD == true, "SaveData=" .. tostring(okSaveD))
local stateD1 = leaseState(DSA, playerD)
check("(D) the post-save refresh did NOT extend A's local expiry past the takeover",
	stateD1 ~= nil and expiryBefore ~= nil
		and (tonumber(stateD1.LeaseExpiresAt) or 0) <= (tonumber(expiryBefore) or 0),
	"before=" .. tostring(expiryBefore) .. " after=" .. tostring(stateD1 and stateD1.LeaseExpiresAt))
check("(D) the post-save refresh marked A as having lost the session",
	stateD1 ~= nil and stateD1.Lost == true and stateD1.Owned == false)
-- And the stale extension must not authorise a later blind write:
-- with the lease read failing, the lost server stays refused.
DSA.AddCoins(playerD, 1000)
store:failGetAsyncForKey(leaseKey(playerD.UserId), 1)
local okSaveD2 = DSA.SaveData(playerD)
store:resetFailures()
check("(D) the losing server's later save stays REFUSED even when the lease read fails",
	okSaveD2 == false)
check("(D) the stored key keeps A's in-flight 6000 (the later 7000 never lands)",
	(tonumber(store:peek(P.mainKey(playerD.UserId)).Coins) or 0) == 6000)

-- --- (E) Crash and expiry recovery ---------------------------------
local playerE = R5.newLoadedPlayer(env, 9545, 5000)
assert(DSA.SaveData(playerE) == true, "setup (E): server A baseline save must land")
-- Server A "crashes": its lease is left expired, never released.
store:seed(leaseKey(playerE.UserId), {
	ServerId = DSA.GetServerId(),
	AcquiredAt = os.time() - 200,
	ExpiresAt = os.time() - 10,
})
DSB.LoadData(playerE)
check("(E) after the lease expires, server B takes over and is saveable (no permanent lockout)",
	DSB.IsSaveable(playerE) == true and DSB.GetSaveBlockedReason(playerE) == nil)
check("(E) B's save lands after taking over the expired lease",
	DSB.SaveData(playerE) == true)
local stateE = leaseState(DSB, playerE)
check("(E) B's lease state reports Owned after the crash takeover",
	stateE ~= nil and stateE.Owned == true)

-- --- (F) Healthy owner's save preserved under a failed read -------
local playerF = R5.newLoadedPlayer(env, 9546, 5000)
assert(DSA.SaveData(playerF) == true, "setup (F): server A baseline save must land")
DSA.AddCoins(playerF, 1000)
local updateBefore = store.calls.UpdateAsync
store:failGetAsyncForKey(leaseKey(playerF.UserId), 1)
local okSaveF = DSA.SaveData(playerF)
store:resetFailures()
check("(F) the owning server's save still lands when its lease read fails (ownership proven, not assumed)",
	okSaveF == true)
check("(F) the stored key holds A's newer data (6000)",
	(tonumber(store:peek(P.mainKey(playerF.UserId)).Coins) or 0) == 6000)
check("(F) the failed read was resolved by an ownership proof (an UpdateAsync ran)",
	(store.calls.UpdateAsync - updateBefore) >= 1,
	"UpdateAsync delta=" .. tostring(store.calls.UpdateAsync - updateBefore))
local stateF = leaseState(DSA, playerF)
check("(F) the owner's lease state still reports Owned, not Lost",
	stateF ~= nil and stateF.Owned == true and stateF.Lost == false)

-- --- (G) Per-retry revalidation ------------------------------------
local playerG = R5.newLoadedPlayer(env, 9547, 5000)
assert(DSA.SaveData(playerG) == true, "setup (G): server A baseline save must land")
DSA.AddCoins(playerG, 1000)
-- Wrap SetAsync: the FIRST attempt for A's main key fails AFTER
-- server B takes the lease and writes newer data (10000).
local setCallsBefore = store.calls.SetAsync
local origSetAsync = store.SetAsync
local swappedG = false
store.SetAsync = function(self, k, value)
	if k == P.mainKey(playerG.UserId) and not swappedG then
		swappedG = true
		store:seed(leaseKey(playerG.UserId), {
			ServerId = DSB.GetServerId(),
			AcquiredAt = os.time(),
			ExpiresAt = os.time() + 90,
		})
		store:seed(P.mainKey(playerG.UserId), {
			Level = 5,
			Coins = 10000,
			Gems = 0,
			MutationCrystals = 1000,
			Rebirths = 0,
			Unlocked = { "wobble_waffleton", "turbo_turnip", "glitchy_goose" },
			OwnedInstances = {},
			Base = { Placed = {} },
			LabDiscoveries = {},
			LastLogin = os.time(),
		})
		error("injected SetAsync failure for " .. k)
	end
	return origSetAsync(self, k, value)
end
local okSaveG = DSA.SaveData(playerG)
store.SetAsync = origSetAsync
check("(G) the save is REFUSED after the lease is lost between retries (no retry writes)",
	okSaveG == false)
check("(G) no SetAsync retry wrote A's data (the wrapper's failed attempt never reached the store)",
	(store.calls.SetAsync - setCallsBefore) == 0,
	"SetAsync delta=" .. tostring(store.calls.SetAsync - setCallsBefore))
check("(G) the newer profile survives: stored key still holds B's 10000, not A's 6000",
	(tonumber(store:peek(P.mainKey(playerG.UserId)).Coins) or 0) == 10000)

-- --- (H) Lease state is queryable on a never-loaded player --------
local playerH = H.newPlayer(9548, "Player9548", 30, Vector3.new(0, 0, 0))
local stateH = leaseState(DSA, playerH)
check("(H) a never-loaded player reports not-owned, not-contested, not-lost",
	stateH ~= nil and stateH.Owned == false
		and stateH.Contested == false and stateH.Lost == false)

H.finish()
