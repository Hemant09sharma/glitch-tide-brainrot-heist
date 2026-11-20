-- 06_r4_7_session_lease.luau — R4-7 (P2, Test G):
-- The main profile was last-write-wins SetAsync with no session
-- ownership: a second server could silently load and overwrite the
-- first server's newer data. The R4-7 fix is a session lease in
-- DataService: the DataStore key Brainrot_Session_<UserId> holds
-- {ServerId, AcquiredAt, ExpiresAt} (TTL 90 s); LoadData claims it
-- on a successful load, SaveData refuses when another live server
-- holds it, and a crashed server's lease expires on its own (never
-- a permanent lockout). Two module instances (DataService and
-- DataServiceB) stand in for two servers sharing one stub store.
-- Teleport/rejoin (clean release + re-acquire), crash expiry, the
-- contested session's save refusal, and the contested session
-- skipping the sidecar merge (the owning server's recovery is
-- authoritative) are all asserted. The lease read failing (a
-- partition) falls back to the cached lease and does NOT block a
-- save — a documented limit, asserted here so it stays deliberate.
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DSA = env.dataService
local DSB = require("./services/DataServiceB")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

check("the two server instances have distinct server ids",
	DSA.GetServerId() ~= DSB.GetServerId(),
	"A=" .. tostring(DSA.GetServerId()) .. " B=" .. tostring(DSB.GetServerId()))

local player = R.newLoadedPlayer(env, 9461, 5000)
check("server A loads the player saveably", DSA.IsSaveable(player) == true
	and DSA.GetSaveBlockedReason(player) == nil)
assert(DSA.SaveData(player) == true, "setup: server A baseline save must land")

-- A second server loads the same profile while A holds the lease.
DSB.LoadData(player)
check("server B sees the session as contested (another live server owns it)",
	DSB.GetSaveBlockedReason(player) == "session_contested")
check("the contested session is not saveable", DSB.IsSaveable(player) == false)

-- The contested server mutates its cache and tries to save: refused,
-- and the stored key keeps server A's data.
DSB.AddCoins(player, 9999)
check("contested cache can mutate in memory (coins 14999 in B's cache)",
	(tonumber(DSB.GetData(player).Coins) or 0) == 14999)
local okSaveB = DSB.SaveData(player)
check("the contested server's save is refused", okSaveB == false)
check("the stored key still holds server A's data (5000, not 14999)",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 5000)
check("server A's cache is untouched by B's mutation",
	(tonumber(DSA.GetData(player).Coins) or 0) == 5000)
assert(DSA.SaveData(player) == true, "setup: server A save after the refused B save must land")
check("server A's newer save lands (stored key still 5000)",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 5000)

-- A contested session must not merge sidecars: the owning server's
-- merge is authoritative, and a contested merge could only confuse
-- its recovery. Park a pending reward, reload on B (contested), and
-- confirm B's cache does NOT pick it up — then A merges it.
local parked = DSA.RecordPendingRewardSidecar(player, {
	TxId = "sr-lease-test",
	InstanceId = "lease-inst",
	CharacterId = "wobble_waffleton",
	Amount = 300,
	Reason = "lease test",
	CreatedAt = os.time(),
})
check("setup: the pending reward parks in the sidecar", parked == true)
DSB.LoadData(player)
local bPending = DSB.GetData(player).PendingRewards
check("contested server B does not merge the parked pending reward",
	type(bPending) ~= "table" or bPending["lease-inst"] == nil)
DSA.LoadData(player)
local aPending = DSA.GetData(player).PendingRewards
check("owning server A merges the parked pending reward on reload",
	type(aPending) == "table" and aPending["lease-inst"] ~= nil
		and (tonumber(aPending["lease-inst"].Amount) or 0) == 300)

-- Clean handover (teleport/rejoin): A releases, B acquires.
DSA.ReleaseSessionLease(player)
DSB.LoadData(player)
check("after A releases, B acquires the lease and is saveable",
	DSB.IsSaveable(player) == true and DSB.GetSaveBlockedReason(player) == nil)
DSB.AddCoins(player, 100)
check("B's save now lands", DSB.SaveData(player) == true)
check("stored key reflects B's save (5100)",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 5100)

-- Crash expiry: B holds the lease and never releases (simulated
-- crash). Expire the lease by writing an already-expired lease
-- record (the TTL mechanism itself), and A must be able to take
-- over — no permanent lockout.
store:seed("Brainrot_Session_" .. tostring(player.UserId), {
	ServerId = DSB.GetServerId(),
	AcquiredAt = os.time() - 200,
	ExpiresAt = os.time() - 10,
})
DSA.LoadData(player)
check("after the lease expires, A takes over and is saveable",
	DSA.IsSaveable(player) == true and DSA.GetSaveBlockedReason(player) == nil)
check("A's save lands after taking over the expired lease",
	DSA.SaveData(player) == true)

-- Partition limit (deliberate): a failed lease read falls back to
-- the cached lease and does NOT block the save.
store:failGetAsyncForKey("Brainrot_Session_" .. tostring(player.UserId), 1)
check("a failed lease read does not block the owning server's save",
	DSA.SaveData(player) == true)
store:resetFailures()

H.finish()
