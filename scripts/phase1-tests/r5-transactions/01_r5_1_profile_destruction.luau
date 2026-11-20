-- 01_r5_1_profile_destruction.luau — R5-1 (P0):
-- Qwen reproduced: GetDataStore fails → LoadData treats the missing
-- store as a successful load → a default profile becomes saveable →
-- DataStore recovers → SaveData overwrites the player's real profile
-- with defaults. The fix: a GetDataStore failure is a failed load
-- (the session is unsaveable, SaveWarning reports load_failed), a
-- plain SaveData still refuses after the store recovers, and recovery
-- happens ONLY through the explicit RetryLoad path, which replaces
-- the cache solely on a genuine successful load — it never clears
-- the genuine stored profile or silently creates a replacement.
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

local function storedCoins(userId)
	local key = store:peek(P.mainKey(userId))
	return math.floor(tonumber(key and key.Coins) or 0)
end

local function storedHasKeepsake(userId, keepsakeId)
	local key = store:peek(P.mainKey(userId))
	return H.findOwned(key, keepsakeId) ~= nil
end

-- The genuine profile: seeded BEFORE the outage, so the store holds
-- real progress the failed load must never overwrite.
local userId = 9501
local keepsakeId = "r5-1-keepsake"
local genuine = {
	Level = 12,
	Coins = 5000,
	Gems = 25,
	MutationCrystals = 100,
	Rebirths = 1,
	Unlocked = { "wobble_waffleton", "turbo_turnip" },
	OwnedInstances = {
		{
			InstanceId = keepsakeId,
			CharacterId = "wobble_waffleton",
			Level = 7,
			Mutation = "golden",
			Placed = true,
			Slot = 2,
			PlacedAt = 1000000,
			BankedIncome = 800,
		},
	},
	Base = { Placed = {
		{ InstanceId = keepsakeId, CharacterId = "wobble_waffleton", Slot = 2, Level = 7, Glitched = false, Mutation = "golden", BankedIncome = 800, PlacedAt = 1000000 },
	} },
	LabDiscoveries = {},
	LastLogin = os.time(),
}
store:seed(P.mainKey(userId), genuine)

R5.setDataStoreOutage(true)
local env = R5.newEnv()
local DS = env.dataService

local player = H.newPlayer(userId, "Player9501", 30, Vector3.new(0, 0, 0))
local data = DS.LoadData(player)
-- The outage load plays on in-memory defaults (100 starting coins,
-- or 150 if the old code's daily bonus fires on the unread profile)
-- and never sees the genuine profile.
check("outage load plays on in-memory defaults, not the genuine profile",
	math.floor(tonumber(data.Coins) or 0) <= 150
		and H.findOwned(data, keepsakeId) == nil,
	"coins=" .. tostring(data.Coins))
check("outage load is NOT saveable",
	DS.IsSaveable(player) == false)
check("outage load reports the load_failed block reason",
	DS.GetSaveBlockedReason(player) == "load_failed",
	"reason=" .. tostring(DS.GetSaveBlockedReason(player)))
local warning = DS.GetSaveWarning(player)
check("outage load produces a SaveWarning for the client",
	type(warning) == "table" and warning.Reason == "load_failed"
		and type(warning.Message) == "string"
		and string.find(warning.Message, "will NOT be saved") ~= nil,
	"warning=" .. tostring(type(warning) == "table" and warning.Reason or nil))
check("SaveData refuses while the store is down",
	DS.SaveData(player) == false)
check("stored profile untouched while the store is down",
	storedCoins(userId) == 5000 and storedHasKeepsake(userId, keepsakeId),
	"storedCoins=" .. tostring(storedCoins(userId)))

-- The explicit reload path exists and fails closed while the outage
-- lasts: no silent replacement profile, cache untouched.
check("RetryLoad exists as the explicit reload path",
	type(DS.RetryLoad) == "function")
if type(DS.RetryLoad) == "function" then
	local okRetry, reason = DS.RetryLoad(player)
	check("RetryLoad fails while the outage lasts (no silent replacement)",
		okRetry == false and reason == "datastore_unavailable",
		"ok=" .. tostring(okRetry) .. " reason=" .. tostring(reason))
	check("failed RetryLoad leaves the in-memory cache untouched (still defaults)",
		math.floor(tonumber(DS.GetData(player).Coins) or 0) == 100
			and H.findOwned(DS.GetData(player), keepsakeId) == nil,
		"coins=" .. tostring(DS.GetData(player).Coins))
	check("session still unsaveable after the failed RetryLoad",
		DS.IsSaveable(player) == false)
	check("stored profile still genuine after the failed RetryLoad",
		storedCoins(userId) == 5000 and storedHasKeepsake(userId, keepsakeId))
end

-- The DataStore recovers. A plain SaveData must STILL refuse: this
-- session never read the genuine profile, and saving now would
-- overwrite it with defaults — the Qwen wipe.
R5.setDataStoreOutage(false)
check("SaveData STILL refuses after the store recovers (no silent wipe)",
	DS.SaveData(player) == false)
check("stored profile still genuine after recovery + refused save",
	storedCoins(userId) == 5000 and storedHasKeepsake(userId, keepsakeId),
	"storedCoins=" .. tostring(storedCoins(userId)))

if type(DS.RetryLoad) == "function" then
	local okRetry, loaded = DS.RetryLoad(player)
	check("RetryLoad succeeds once the store is back",
		okRetry == true and type(loaded) == "table",
		"ok=" .. tostring(okRetry))
	check("RetryLoad loads the GENUINE profile (not defaults, not a replacement)",
		math.floor(tonumber(DS.GetData(player).Coins) or 0) == 5000
			and H.findOwned(DS.GetData(player), keepsakeId) ~= nil
			and (H.findOwned(DS.GetData(player), keepsakeId).Level or 0) == 7
			and (H.findOwned(DS.GetData(player), keepsakeId).BankedIncome or 0) == 800,
		"coins=" .. tostring(DS.GetData(player).Coins))
	check("session is saveable after a genuine RetryLoad",
		DS.IsSaveable(player) == true)
	check("SaveWarning clears after a genuine RetryLoad",
		DS.GetSaveWarning(player) == nil)
	check("SaveData now persists the genuine profile",
		DS.SaveData(player) == true)
	check("stored profile still genuine after the post-recovery save",
		storedCoins(userId) == 5000 and storedHasKeepsake(userId, keepsakeId),
		"storedCoins=" .. tostring(storedCoins(userId)))
	-- RetryLoad on a healthy session is a no-op: it must NOT
	-- re-read the stored profile and discard in-session progress.
	DS.AddCoins(player, 250)
	check("in-session progress exists before the no-op RetryLoad",
		math.floor(tonumber(DS.GetData(player).Coins) or 0) == 5250,
		"coins=" .. tostring(DS.GetData(player).Coins))
	local okAgain = DS.RetryLoad(player)
	check("RetryLoad on a healthy session is a no-op success",
		okAgain == true)
	check("no-op RetryLoad keeps in-session progress (no re-read)",
		math.floor(tonumber(DS.GetData(player).Coins) or 0) == 5250,
		"coins=" .. tostring(DS.GetData(player).Coins))
	check("SaveData persists the in-session progress too",
		DS.SaveData(player) == true)
	check("stored profile now holds the progress (5250)",
		storedCoins(userId) == 5250,
		"storedCoins=" .. tostring(storedCoins(userId)))
end

H.finish()
