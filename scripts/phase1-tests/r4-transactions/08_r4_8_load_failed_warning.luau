-- 08_r4_8_load_failed_warning.luau — R4-8 (P2, Test J):
-- A load-failed (or contested / session-lost) session used to
-- play on defaults with only a server-side warn: the player could
-- lose a whole session's earnings without ever knowing. The R4-8
-- fix gives the player a clear client-visible warning:
-- DataService.GetSaveWarning returns {Reason, Message} (nil when
-- the session can save), GameManager fires it to the client on
-- join via the SaveWarning remote, and HUDController shows a
-- persistent red banner (never auto-hides). The client banner
-- itself is not Lune-testable (no client harness) — its presence
-- is asserted by static anchors in run.sh; this file proves the
-- server-side payload for every reason, and that a load-failed
-- session still never overwrites the genuine profile.
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService
local DSB = require("./services/DataServiceB")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- A saveable session gets no warning.
local playerOk = R.newLoadedPlayer(env, 9481, 5000)
check("a saveable session has no save warning", DS.GetSaveWarning(playerOk) == nil)

-- Load-failed: the genuine profile is never overwritten, and the
-- player is warned.
local playerFail = H.newPlayer(9482, "Player9482", 30, Vector3.new(0, 0, 0))
P.store:seed(P.mainKey(9482), {
	Level = 5, Coins = 7777, Gems = 0, MutationCrystals = 0, Rebirths = 0,
	Unlocked = {}, OwnedInstances = {}, Base = { Placed = {} }, LabDiscoveries = {},
	LastLogin = os.time(),
})
store:failGetAsyncForKey(P.mainKey(9482), 3) -- LOAD_RETRIES attempts
DS.LoadData(playerFail)
check("load-failed session is flagged unsaveable", DS.IsSaveable(playerFail) == false)
check("load-failed session plays on defaults in memory (100 starting coins)",
	(tonumber(DS.GetData(playerFail).Coins) or 0) == 100)
local warnFail = DS.GetSaveWarning(playerFail)
check("load-failed session gets a load_failed warning",
	type(warnFail) == "table" and warnFail.Reason == "load_failed",
	"reason=" .. tostring(type(warnFail) == "table" and warnFail.Reason or nil))
check("the warning says plainly the progress will NOT be saved",
	type(warnFail) == "table" and string.find(warnFail.Message, "will NOT be saved", 1, true) ~= nil,
	"message=" .. tostring(type(warnFail) == "table" and warnFail.Message or nil))
DS.AddCoins(playerFail, 500) -- session "earnings" on the phantom cache
local okSaveFail = DS.SaveData(playerFail)
check("the load-failed session's save is refused", okSaveFail == false)
check("the genuine profile is NOT overwritten (stored key still 7777)",
	(tonumber(store:peek(P.mainKey(9482)).Coins) or 0) == 7777)

-- Contested: another live server owns the session.
local playerC = R.newLoadedPlayer(env, 9483, 5000)
DSB.LoadData(playerC)
local warnC = DSB.GetSaveWarning(playerC)
check("contested session gets a session_contested warning",
	type(warnC) == "table" and warnC.Reason == "session_contested",
	"reason=" .. tostring(type(warnC) == "table" and warnC.Reason or nil))
check("the contested warning says progress will NOT be kept",
	type(warnC) == "table" and string.find(warnC.Message, "will NOT be kept", 1, true) ~= nil)
check("the owning server reports no warning for the same player",
	DS.GetSaveWarning(playerC) == nil)

-- Session lost: this server held the lease, then the stored lease
-- record shows another live server owning it (the positive
-- sighting in checkSessionLease). Seeding that state drives the
-- exact branch.
local playerL = R.newLoadedPlayer(env, 9484, 5000)
assert(DS.SaveData(playerL) == true, "setup: owning-server save must land (refreshes the lease)")
store:seed("Brainrot_Session_" .. tostring(playerL.UserId), {
	ServerId = DSB.GetServerId(),
	AcquiredAt = os.time(),
	ExpiresAt = os.time() + 90,
})
local okSaveLost = DS.SaveData(playerL)
check("a save after losing the lease is refused", okSaveLost == false)
check("the session is flagged session_lost",
	DS.GetSaveBlockedReason(playerL) == "session_lost")
local warnL = DS.GetSaveWarning(playerL)
check("session-lost gets a session_lost warning",
	type(warnL) == "table" and warnL.Reason == "session_lost",
	"reason=" .. tostring(type(warnL) == "table" and warnL.Reason or nil))
check("the session-lost warning says progress will NOT be saved",
	type(warnL) == "table" and string.find(warnL.Message, "will NOT be saved", 1, true) ~= nil)
check("the lost session's stored key is untouched (still 5000)",
	(tonumber(store:peek(P.mainKey(playerL.UserId)).Coins) or 0) == 5000)

H.finish()
