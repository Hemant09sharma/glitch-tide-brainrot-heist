-- m04_r5_4_old_logic.luau — R5-4 negative control.
-- Loads the PRE-R5 DataService snapshot (mutant/DataServiceR4.luau:
-- a failed lease read falls back to the cached lease, the refresh
-- extends the local expiry without checking the UpdateAsync result,
-- SaveData checks the lease only before the _saving wait and never
-- before SetAsync retries, and there is no GetSessionLeaseState)
-- against the CURRENT RaidService. The second server (DataServiceB)
-- is the CURRENT copy: B's acquire/save path is the same in both
-- versions — what is under test is server A's stale-server saves,
-- which must overwrite the newer profile under the OLD code.
-- Each check asserts the OLD bad outcome: if this control passes,
-- the fixed test 04 genuinely detects the bug; if it fails, test 04
-- would pass even against broken code.
-- Sections mirror test 04 §A (lease lost mid-wait), §B (failed read
-- under another owner), §G (lease lost between retries), §D (stale
-- cached-lease extension authorising a later blind write).
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh
local R5 = require("../r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv({ dsPath = "./mutant/DataServiceR4" })
local DSA = env.dataService
local DSB = require("../services/DataServiceB")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function leaseKey(userId)
	return "Brainrot_Session_" .. tostring(userId)
end

check("(0) OLD: GetSessionLeaseState does not exist",
	type(DSA.GetSessionLeaseState) ~= "function")

-- --- (A) Lease lost DURING the _saving wait ------------------------
local playerA = R5.newLoadedPlayer(env, 9641, 5000)
assert(DSA.SaveData(playerA) == true, "setup (A): server A baseline save must land")
DSA.AddCoins(playerA, 1000)
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
check("(A) OLD: B's takeover wrote 10000 mid-wait",
	takeoverStoredCoins == 10000, "takeoverStoredCoins=" .. tostring(takeoverStoredCoins))
check("(A) OLD: the stale server's resumed save LANDS (no post-wait revalidation)",
	okSaveA == true)
check("(A) OLD: the newer profile is OVERWRITTEN (stored key 6000, not B's 10000)",
	(tonumber(store:peek(P.mainKey(playerA.UserId)).Coins) or 0) == 6000,
	"stored=" .. tostring(store:peek(P.mainKey(playerA.UserId)).Coins))

-- --- (B) Lease GetAsync fails while another server owns it --------
local playerB = R5.newLoadedPlayer(env, 9642, 5000)
assert(DSA.SaveData(playerB) == true, "setup (B): server A baseline save must land")
DSA.AddCoins(playerB, 1000)
store:seed(leaseKey(playerB.UserId), {
	ServerId = DSB.GetServerId(),
	AcquiredAt = os.time(),
	ExpiresAt = os.time() + 90,
})
store:failGetAsyncForKey(leaseKey(playerB.UserId), 1)
local okSaveB = DSA.SaveData(playerB)
store:resetFailures()
check("(B) OLD: the stale server's save LANDS on a failed lease read (blind cached fallback)",
	okSaveB == true)
check("(B) OLD: the stored key is overwritten (6000, not 5000)",
	(tonumber(store:peek(P.mainKey(playerB.UserId)).Coins) or 0) == 6000)

-- --- (G) Lease lost between SetAsync retries -----------------------
local playerG = R5.newLoadedPlayer(env, 9643, 5000)
assert(DSA.SaveData(playerG) == true, "setup (G): server A baseline save must land")
DSA.AddCoins(playerG, 1000)
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
check("(G) OLD: the save LANDS on retry with no revalidation",
	okSaveG == true)
check("(G) OLD: the retry wrote A's data (SetAsync reached the store)",
	(store.calls.SetAsync - setCallsBefore) == 1,
	"SetAsync delta=" .. tostring(store.calls.SetAsync - setCallsBefore))
check("(G) OLD: the newer profile is OVERWRITTEN (stored key 6000, not B's 10000)",
	(tonumber(store:peek(P.mainKey(playerG.UserId)).Coins) or 0) == 6000)

-- --- (D) Stale cached-lease extension ------------------------------
local playerD = R5.newLoadedPlayer(env, 9644, 5000)
assert(DSA.SaveData(playerD) == true, "setup (D): server A baseline save must land")
DSA.AddCoins(playerD, 1000)
store:armBeforeCommit(function()
	store:seed(leaseKey(playerD.UserId), {
		ServerId = DSB.GetServerId(),
		AcquiredAt = os.time(),
		ExpiresAt = os.time() + 90,
	})
end)
local okSaveD = DSA.SaveData(playerD)
check("(D) OLD: the in-flight save lands (the lease check passed before the takeover)",
	okSaveD == true)
DSA.AddCoins(playerD, 1000)
store:failGetAsyncForKey(leaseKey(playerD.UserId), 1)
local okSaveD2 = DSA.SaveData(playerD)
store:resetFailures()
check("(D) OLD: the losing server's later save LANDS on a failed read (stale extended cache authorises it)",
	okSaveD2 == true)
check("(D) OLD: the later 7000 overwrites the in-flight 6000",
	(tonumber(store:peek(P.mainKey(playerD.UserId)).Coins) or 0) == 7000)

H.finish()
