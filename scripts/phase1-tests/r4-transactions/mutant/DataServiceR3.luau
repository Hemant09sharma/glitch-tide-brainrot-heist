-- DataService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse — player persistence.
-- DataStoreService with pcall everywhere; safe in-memory defaults when
-- Studio has API access disabled or a DataStore call fails.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Config = require("../shared/Config")

-- Shared daily-bonus math (50 + 10 per streak day, capped day 7).
-- pcall-guarded: DataService must keep working if Economy is absent.
local _economyMod: any = nil
do
	local ok, mod = pcall(function()
		return require("../shared/Economy")
	end)
	if ok then
		_economyMod = mod
	end
end

local DataService = {}

local DATASTORE_NAME = (type(Config.DataStoreName) == "string" and Config.DataStoreName ~= "")
	and Config.DataStoreName
	or "BrainrotBattleArena_v1"
local AUTOSAVE_INTERVAL = tonumber(Config.AutosaveInterval) or 60
local DAY_SECONDS = 24 * 60 * 60
local DAILY_BONUS_COINS = 50
local LOAD_RETRIES = 3
local SAVE_RETRIES = 3

local STARTER_ID = (type(Config.StarterCharacterId) == "string" and Config.StarterCharacterId ~= "")
	and Config.StarterCharacterId
	or "wobble_waffleton"

local DEFAULT_DATA = {
	Coins = tonumber(Config.StartingCoins) or 100,
	XP = 0,
	Level = 1,
	Unlocked = { STARTER_ID },
	Selected = STARTER_ID,
	Wins = 0,
	KOs = 0,
	LastLogin = 0,
	LoginStreak = 1,
	-- Heist-loop fields other services read (they all lazily init
	-- these too, but defaults keep old / partial saves valid).
	Gems = tonumber(Config.StartingGems) or 10,
	ChaosShards = 0,
	MutationCrystals = 0,
	EventTokens = 0,
	Rebirths = 0,
	OwnedInstances = {},
	BankedIncome = 0,
	-- v1.1 Wave 2 (Workstream C) persistence fields. All new fields
	-- only, with safe defaults in applyDefaults below so existing
	-- saves load with them empty / zero.
	Expeditions = { Active = nil, Completed = 0 },
	Achievements = {},
	Titles = {},
	EquippedTitle = "",
	Prestige = 0,
	LabDiscoveries = {},
	SecretDiscoveries = {},
	SecretRunes = {},
	DimensionUnlocks = {},
	Mastery = {},
	ProgressionMilestones = {},
	Challenges = {},
}

local _store = nil
local _cache = {} -- [Player] = data table
local _saving = {} -- [Player] = true while a save is in flight
-- [Player] = true when the store could not be read at join: the
-- session plays on in-memory defaults and saves are REFUSED, so an
-- autosave / leave-save can never overwrite the player's real save
-- with fresh defaults. A rejoin re-attempts the load.
local _loadFailed = {}
local _running = false
-- R2-5: pre-save hooks, run in registration order inside the leave /
-- shutdown handlers BEFORE the save (see RegisterPreSaveHook). This is
-- what makes the leave path ordered: RaidService returns in-transit
-- Brainrots through a hook, so the saved state is already consistent
-- instead of a save racing the recovery.
local _preSaveHooks: { (Player) -> () } = {}
-- [Player] = { Escrow = boolean, Pending = boolean } when a sidecar
-- was read successfully at load and still needs deleting. A key is
-- flagged ONLY if its read SUCCEEDED and it held entries (R3-1), so a
-- failed read never marks its key for deletion — its entries stay
-- parked until a later load merges them. The keys are removed only
-- after a later SaveData succeeds, so a crash between merge and save
-- re-merges the same entries (the merge is idempotent) instead of
-- losing them.
local _sidecarMerged = {}
-- R4-7: one server's identity, for the session lease below. A GUID
-- from HttpService (collision-resistant, server-independent); the
-- fallback is only for an environment where GenerateGUID is
-- unavailable, and is then timestamp + clock + random, i.e. only
-- probabilistic — the same caveat the R3 TxIds carried.
local _serverId: string = "srv-unknown"
do
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and type(guid) == "string" and guid ~= "" then
		_serverId = guid
	else
		_serverId = string.format("srv-%d-%d-%d",
			os.time(), math.floor(os.clock() * 1000), math.random(1, 2147483647))
	end
end
-- R4-7: session lease. [Player] = {ServerId, AcquiredAt, ExpiresAt}
-- (the lease as this server last saw it). The durable lease lives in
-- the DataStore key Brainrot_Session_<UserId> (see leaseKeyFor).
-- Only the server named in a live (unexpired) lease may save that
-- player's main profile; a second server that loads the same player
-- while the lease is live is contested and must not save.
-- TTL 90 s: longer than the 60 s autosave interval, so a healthy
-- server's saves keep refreshing it, and short enough that a crashed
-- server's lease expires on its own — a lease can never permanently
-- lock a player out.
local SESSION_LEASE_TTL = 90
local _lease: { [Player]: any } = {}
-- [Player] = true when this server loaded the player while another
-- live server held the lease (R4-7 contested), or when a later lease
-- check found this server had lost it (R4-7 session lost). Both
-- behave like _loadFailed for saving: SaveData refuses, IsSaveable
-- is false, and the client gets a SaveWarning (see GetSaveWarning).
local _sessionContested = {}
local _sessionLost = {}
-- R5-4: [Player] = true when the most recent lease check could not
-- verify ownership at all — the stored-lease read failed AND the
-- atomic proof (UpdateAsync) failed too — and refused that save
-- attempt. It is NOT sticky like _sessionLost: the next save
-- re-checks from scratch, so a transient outage cannot wedge the
-- session. Queryable via GetSessionLeaseState.
local _leaseCheckUnverified = {}
-- R4-3: coin reservations. [Player] = {[reservationKey] = amount}.
-- A reservation earmarks coins already credited for a pending reward
-- commit so no debit can spend them while the commit's save is in
-- flight (see AddCoins: debits clamp at the reserved total, not at
-- zero). Reservations are in-memory only and are released on commit
-- success, on rollback, and when the player's cache is cleared.
local _reserved: { [Player]: { [string]: number } } = {}
-- R4-8: shutdown-save stats (see SaveAllForShutdown) and a test-only
-- wait hook. _testWaitHook, when set via _TestSetWaitHook, is called
-- once per 0.2 s wait iteration inside SaveData's _saving wait; the
-- r4-transactions suite uses it to release a held _saving flag
-- mid-wait and prove the leave save then lands. It is never set in
-- production.
local _shutdownStats = { attempted = 0, spawned = 0, completed = 0, saved = 0 }
local _testWaitHook: ((Player) -> ())? = nil
local _saveWaitIterations = 0
-- R5-7: shutdown-hook state (see RunShutdownHooks). _hookRunning
-- serialises hooks per player: while one hook run for a player is
-- in flight (PlayerRemoving vs BindToClose for the same player),
-- a second run for that player waits briefly, then skips — the
-- in-flight run already owns the recovery, and two concurrent
-- HandlePlayerLeaving runs could both see the same _inTransit entry
-- and both call ReturnStolen on it. _hookStats counts the last
-- RunShutdownHooks call (attempted / spawned / completed).
local _hookRunning: { [Player]: boolean } = {}
local _hookStats = { attempted = 0, spawned = 0, completed = 0 }
-- R5-7 budgets. The hook phase gets at most 10 s: under Qwen's
-- degraded-store measurement a single player's hooks cost ~7 s
-- (one sidecar op at ~7 s), so 10 s covers the slowest single
-- player with margin; the save phase keeps its R4-8 ~25 s wait.
-- Expected degraded total is ~16 s (7 s hooks + 9 s slowest save),
-- inside the ~30 s shutdown budget; the two caps sum to 35 s, so in
-- the pathological both-phases-saturated case Roblox's 30 s
-- force-close can cut the tail (the lease release — leases
-- self-expire in 90 s). A hook run that is already in flight gets
-- at most 5 s of waiting from a second caller before it is skipped.
local SHUTDOWN_HOOK_BUDGET_SECONDS = 10
local HOOK_WAIT_SECONDS = 5

function DataService.RegisterPreSaveHook(fn: (Player) -> ()): boolean
	if type(fn) ~= "function" then
		return false
	end
	for _, existing in ipairs(_preSaveHooks) do
		if existing == fn then
			return true
		end
	end
	table.insert(_preSaveHooks, fn)
	return true
end

-- runPreSaveHooks(player): run every registered pre-save hook for
-- this player, in registration order. R5-7: per-player
-- serialisation. If a hook run for this player is already in
-- flight, wait (bounded, HOOK_WAIT_SECONDS) for it to finish, then
-- return false WITHOUT re-running: the in-flight run already did
-- the recovery, and re-running it concurrently could double-return
-- the same Brainrot. Returns true iff the hooks ran here. A hook
-- failure (pcall-guarded) never blocks the other hooks or the save.
local function runPreSaveHooks(player: Player): boolean
	if _hookRunning[player] then
		local waited = 0
		while _hookRunning[player] and waited < HOOK_WAIT_SECONDS do
			task.wait(0.2)
			waited += 0.2
		end
		if _hookRunning[player] then
			warn("[DataService] Pre-save hooks for " .. player.Name
				.. " were already running; skipping the duplicate run")
		end
		return false
	end
	_hookRunning[player] = true
	for _, fn in ipairs(_preSaveHooks) do
		pcall(fn, player)
	end
	_hookRunning[player] = nil
	return true
end

-- RunPreSaveHooks(player): the synchronous per-player hook unit
-- (what each spawned task in RunShutdownHooks runs, and what the
-- PlayerRemoving handler runs). Exposed so tests can drive it
-- without the spawn fan-out. Returns true iff the hooks ran.
function DataService.RunPreSaveHooks(player: Player): boolean
	return runPreSaveHooks(player)
end

-- RunShutdownHooks(players): the bounded parallel hook phase. Spawns
-- one task per player (each runs that player's pre-save hooks), then
-- waits at most SHUTDOWN_HOOK_BUDGET_SECONDS for all of them, so
-- the phase costs roughly the slowest single player's hooks instead
-- of the sum (the old BindToClose loop ran them inline, one player
-- after another: ~42 simulated seconds for 6 players under a
-- degraded store, before the save phase even started). Returns
-- {attempted, spawned, completed}. A player whose hooks never
-- complete in the budget is reported, never silently claimed done:
-- their save still runs afterwards (SaveAllForShutdown) and the
-- rejoin reconciler covers an unrecovered InTransit record. The
-- per-player serialisation in runPreSaveHooks keeps a hook from
-- running twice concurrently even if a leave fires mid-shutdown.
function DataService.RunShutdownHooks(players: { Player }?): { [string]: number }
	local list: { Player } = players or Players:GetPlayers()
	_hookStats = { attempted = #list, spawned = 0, completed = 0 }
	local done = 0
	for _, player in ipairs(list) do
		_hookStats.spawned += 1
		task.spawn(function()
			pcall(function()
				runPreSaveHooks(player)
			end)
			done += 1
			_hookStats.completed = done
		end)
	end
	local waited = 0
	while done < #list and waited < SHUTDOWN_HOOK_BUDGET_SECONDS do
		task.wait(0.2)
		waited += 0.2
	end
	if done < #list then
		warn(string.format(
			"[DataService] Shutdown hooks incomplete: %d/%d players finished in the %ds hook budget",
			done, #list, SHUTDOWN_HOOK_BUDGET_SECONDS))
	end
	return { attempted = #list, spawned = _hookStats.spawned, completed = done }
end

function DataService.GetShutdownHookStats(): { [string]: number }
	return {
		attempted = _hookStats.attempted,
		spawned = _hookStats.spawned,
		completed = _hookStats.completed,
	}
end

local function keyFor(player)
	return "Brainrot_Player_" .. tostring(player.UserId)
end

local function deepCopy(t)
	local copy = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			copy[k] = deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

-- Fill any missing fields on loaded data so old / partial saves stay valid.
local function applyDefaults(data)
	if type(data) ~= "table" then
		return deepCopy(DEFAULT_DATA)
	end
	local merged = deepCopy(DEFAULT_DATA)
	for k, v in pairs(data) do
		merged[k] = v
	end
	if type(merged.Unlocked) ~= "table" or #merged.Unlocked == 0 then
		merged.Unlocked = { STARTER_ID }
	end
	if type(merged.Selected) ~= "string" or merged.Selected == "" then
		merged.Selected = STARTER_ID
	end
	if type(merged.OwnedInstances) ~= "table" then
		merged.OwnedInstances = {}
	end
	if type(merged.BankedIncome) ~= "number" then
		merged.BankedIncome = 0
	end
	if type(merged.Rebirths) ~= "number" then
		merged.Rebirths = 0
	end
	-- v1.1 Wave 2 (Workstream C): new fields only — nil-safe loads for
	-- existing saves. Tables are re-created empty when missing or of
	-- the wrong type; numbers default to 0; EquippedTitle to "".
	if type(merged.Expeditions) ~= "table" then
		merged.Expeditions = { Active = nil, Completed = 0 }
	end
	if type(merged.Expeditions.Completed) ~= "number" then
		merged.Expeditions.Completed = 0
	end
	for _, field in ipairs({ "Achievements", "Titles", "LabDiscoveries", "SecretDiscoveries", "SecretRunes", "DimensionUnlocks", "Mastery", "ProgressionMilestones", "Challenges" }) do
		if type(merged[field]) ~= "table" then
			merged[field] = {}
		end
	end
	if type(merged.EquippedTitle) ~= "string" then
		merged.EquippedTitle = ""
	end
	if type(merged.Prestige) ~= "number" then
		merged.Prestige = 0
	end
	-- R2-5: a PendingRewards ledger that survived a load with the wrong
	-- type (e.g. a corrupt value) is reset, never trusted as-is.
	if merged.PendingRewards ~= nil and type(merged.PendingRewards) ~= "table" then
		merged.PendingRewards = {}
	end
	-- R3-3: the same guard for the processed-reward ledger
	-- (data.ProcessedRewardTxns, [TxId] = {TxId, InstanceId, Amount,
	-- PaidAt}): a corrupt value is reset, never trusted as-is. The
	-- ledger is the durable proof a reward transaction was paid; see
	-- mergeSidecars and RaidService.commitPendingPayment.
	if merged.ProcessedRewardTxns ~= nil and type(merged.ProcessedRewardTxns) ~= "table" then
		merged.ProcessedRewardTxns = {}
	end
	-- R3-6: the same guard for the return-transaction ledger
	-- (data.ReturnedTxns, [TxId] = {TxId, InstanceId, ReturnedAt}):
	-- a corrupt value is reset, never trusted as-is. The ledger is
	-- the durable proof a return transaction is reflected in this
	-- profile; see mergeEscrowRecord and RaidService.ReturnStolen.
	if merged.ReturnedTxns ~= nil and type(merged.ReturnedTxns) ~= "table" then
		merged.ReturnedTxns = {}
	end
	-- R4-4: the same guard for the voided-reward ledger
	-- (data.VoidedRewardTxns, [TxId] = {TxId, InstanceId, VoidedAt}):
	-- a corrupt value is reset, never trusted as-is. A voided TxId
	-- is a reward whose delivery was voided on recovery; it must
	-- never be paid, so the ledger is consulted on every merge and
	-- every commit (see mergeSidecars and
	-- RaidService.commitPendingPayment).
	if merged.VoidedRewardTxns ~= nil and type(merged.VoidedRewardTxns) ~= "table" then
		merged.VoidedRewardTxns = {}
	end
	-- R5-3: the same guard for the voided-reward-instance ledger
	-- (data.VoidedRewardInstances, [InstanceId] = {InstanceId,
	-- VoidedAt}): a corrupt value is reset, never trusted as-is.
	-- A voided instance's rewards are never paid, whatever TxIds
	-- they carry (see mergeSidecars and
	-- RaidService.voidPendingRewardsForInstance).
	if merged.VoidedRewardInstances ~= nil and type(merged.VoidedRewardInstances) ~= "table" then
		merged.VoidedRewardInstances = {}
	end
	for _, currency in ipairs({ "Gems", "ChaosShards", "MutationCrystals", "EventTokens" }) do
		if type(merged[currency]) ~= "number" then
			merged[currency] = 0
		end
	end
	return merged
end

local function getStore()
	if _store ~= nil and _store ~= false then
		return _store
	end
	-- A failed GetDataStore is NOT cached: Studio / API outages are
	-- transient, and a sticky `false` would leave every later load
	-- and save dead for the life of the server.
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok and store then
		_store = store
		return store
	else
		warn("[DataService] DataStore unavailable (Studio / API off?): " .. tostring(store))
		_store = false
		return nil
	end
end

-- ---------------------------------------------------------------------------
-- R2-5: recovery sidecars (separate DataStore keys per player).
-- ---------------------------------------------------------------------------
-- Why a sidecar at all: two recovery payloads cannot live in the main
-- player key. (1) An escrowed Brainrot belongs to a player who is
-- OFFLINE — there is no cache to write it into, and writing it into
-- the thief's key would leave it owned by the wrong player. (2) A
-- pending steal reward recorded while the session cannot persist
-- (load failed: SaveData refuses the main key for the whole session)
-- would die with the cache if it lived only there — the R2-4 hole.
-- The sidecar keys hold exactly those payloads, are read on the next
-- successful load, merged idempotently into the cache, and deleted
-- only after a later save of the merged data succeeds (see SaveData).
-- A crash between merge and save re-merges the same entries; the
-- merge dedupes by transaction id (R3-3), so nothing is paid or
-- restored twice.
local function escrowKeyFor(userId: number): string
	return "Brainrot_Escrow_" .. tostring(userId)
end

local function pendingKeyFor(userId: number): string
	return "Brainrot_Pending_" .. tostring(userId)
end

-- ---------------------------------------------------------------------------
-- R4-7: player session lease (cross-server session safety).
-- ---------------------------------------------------------------------------
-- The main profile is a full-table SetAsync, so two servers writing
-- the same player's key last-write-win: the slower server silently
-- overwrites the faster server's newer data. The lease makes that
-- impossible to do silently. One DataStore key per player,
-- Brainrot_Session_<UserId>, holds {ServerId, AcquiredAt,
-- ExpiresAt}; it is written ONLY through UpdateAsync with a pure
-- transform, so two servers acquiring at once cannot both win — the
-- transform keeps a live lease owned by someone else and only takes
-- a free / expired / own lease. A server that cannot acquire (or
-- later finds another live owner) is contested / lost and must stop
-- saving (SaveData refuses; IsSaveable is false). A crashed server's
-- lease expires after SESSION_LEASE_TTL, so no player is ever locked
-- out permanently; a clean leave releases the lease at once.
local function leaseKeyFor(userId: number): string
	return "Brainrot_Session_" .. tostring(userId)
end

local function acquireSessionLease(player: Player): boolean
	-- MUTANT (R3): no session lease; last-write-wins.
	if true then
		return true
	end
	local store = getStore()
	if not store then
		-- Studio / no store: there is nothing to contend over.
		return true, nil
	end
	local lease = {
		ServerId = _serverId,
		AcquiredAt = os.time(),
		ExpiresAt = os.time() + SESSION_LEASE_TTL,
	}
	local ok, result = pcall(function()
		return store:UpdateAsync(leaseKeyFor(player.UserId), function(old: any): any
			if type(old) == "table"
				and type(old.ServerId) == "string"
				and old.ServerId ~= _serverId
				and (tonumber(old.ExpiresAt) or 0) > os.time()
			then
				-- Live lease held by another server: keep it.
				return old
			end
			return lease
		end)
	end)
	if not ok then
		warn("[DataService] Session-lease acquire failed for " .. player.Name .. ": " .. tostring(result))
		return false, nil
	end
	-- The second return is the post-update lease value: the caller
	-- needs it to tell a successful acquire (result names this
	-- server) from a kept foreign lease (result names the other
	-- server) — see checkSessionLease's failed-read proof.
	local acquired = type(result) == "table" and result.ServerId == _serverId
	if acquired then
		_lease[player] = deepCopy(result)
	end
	return acquired, result
end

-- tryAcquireLease(player): (re)acquire the lease, marking the
-- session lost when the acquire's result proves another live server
-- owns it. Returns true iff this server owns the lease afterwards.
-- (A failed acquire with no result — the UpdateAsync itself errored
-- — marks nothing: the next check retries from scratch.)
local function tryAcquireLease(player: Player): boolean
	local acquired, result = acquireSessionLease(player)
	if acquired then
		_sessionLost[player] = nil
		_leaseCheckUnverified[player] = nil
		return true
	end
	if type(result) == "table"
		and type(result.ServerId) == "string"
		and result.ServerId ~= _serverId
		and (tonumber(result.ExpiresAt) or 0) > os.time()
	then
		_lease[player] = deepCopy(result)
		_sessionLost[player] = true
		warn("[DataService] Session lease for " .. player.Name
			.. " is now held by another server; this server stops saving that profile")
	end
	return false
end

-- checkSessionLease(player): true iff this server may save this
-- player's profile right now. R5-4: ownership is verified against
-- the STORED lease on every check — a stale cached lease never
-- authorises a write on its own.
--   * Stored lease names another live server -> the session is lost
--     (sticky: _sessionLost) and the save is refused.
--   * Stored lease names this server (live) -> the save proceeds;
--     the cached lease is synced from the read (the stored value is
--     authoritative).
--   * Stored lease is missing / expired / corrupt, or this server
--     holds no live cached lease -> (re)acquire via UpdateAsync;
--     the transform's result decides (a live lease owned by another
--     server survives the transform, so an acquire that returns
--     another server is a refusal, not a win).
--   * The stored-lease READ FAILS -> resolve it by atomic proof:
--     run the same conditional UpdateAsync. Its result names the
--     owner: this server proves ownership (the save proceeds — the
--     R4 test-06 healthy-owner case, now proven instead of assumed);
--     another live owner proves loss (sticky _sessionLost); an
--     UpdateAsync failure proves nothing and refuses THIS save
--     attempt only (no sticky flag: the next save re-checks, so a
--     transient outage cannot wedge the session; the unverified
--     state is recorded for GetSessionLeaseState).
-- A failed proof is a refusal, never a fallback to the cache: the
-- R4 rule ("a failed lease read does not block") is narrowed to
-- exactly the case above — the read is retried as a write-proof,
-- and only a PROVEN owner may save.
local function checkSessionLease(player: Player): boolean
	local store = getStore()
	if not store then
		return true
	end
	local cached = _lease[player]
	if type(cached) == "table"
		and cached.ServerId == _serverId
		and (tonumber(cached.ExpiresAt) or 0) > os.time()
	then
		local ok, current = pcall(function()
			return store:GetAsync(leaseKeyFor(player.UserId))
		end)
		if ok then
			if type(current) == "table"
				and type(current.ServerId) == "string"
				and current.ServerId ~= _serverId
				and (tonumber(current.ExpiresAt) or 0) > os.time()
			then
				_sessionLost[player] = true
				warn("[DataService] Session lease for " .. player.Name
					.. " is now held by another server; this server stops saving that profile")
				return false
			end
			if type(current) == "table"
				and current.ServerId == _serverId
				and (tonumber(current.ExpiresAt) or 0) > os.time()
			then
				-- Our lease, verified live: sync the cache from
				-- the read (the stored value is authoritative).
				_lease[player] = deepCopy(current)
				_leaseCheckUnverified[player] = nil
				return true
			end
			-- Stored lease is missing, expired, or corrupt: our
			-- cached lease is stale — re-acquire before saving.
			return tryAcquireLease(player)
		end
		-- R5-4: the read failed — prove ownership atomically
		-- instead of trusting the cache.
		local acquired, result = acquireSessionLease(player)
		if acquired then
			_sessionLost[player] = nil
			_leaseCheckUnverified[player] = nil
			return true
		end
		if type(result) == "table"
			and type(result.ServerId) == "string"
			and result.ServerId ~= _serverId
			and (tonumber(result.ExpiresAt) or 0) > os.time()
		then
			-- The proof returned another live owner: a positive
			-- sighting, same as a successful read.
			_lease[player] = deepCopy(result)
			_sessionLost[player] = true
			warn("[DataService] Session lease for " .. player.Name
				.. " is now held by another server (proven by lease write); this server stops saving that profile")
			return false
		end
		-- The proof itself failed (UpdateAsync errored): nothing
		-- is proven. Refuse THIS save attempt only — no sticky
		-- flag, so the next save re-checks once the store
		-- recovers. Record the unverified state for
		-- GetSessionLeaseState.
		_leaseCheckUnverified[player] = true
		warn("[DataService] Session lease for " .. player.Name
			.. " could not be verified (lease read AND lease proof failed); refusing this save")
		return false
	end
	-- No live cached lease (never acquired, expired locally, or
	-- contested at load): try to (re)acquire before saving. A
	-- successful re-acquire clears the lost flag: this server owns
	-- the session again.
	return tryAcquireLease(player)
end

local function refreshSessionLease(player: Player): boolean
	local store = getStore()
	if not store then
		return false
	end
	local ok, result = pcall(function()
		return store:UpdateAsync(leaseKeyFor(player.UserId), function(old: any): any
			if type(old) == "table" and old.ServerId == _serverId then
				local copy = deepCopy(old)
				copy.ExpiresAt = os.time() + SESSION_LEASE_TTL
				return copy
			end
			return old
		end)
	end)
	if not ok then
		-- The refresh itself failed: an unproven refresh extends
		-- nothing (the local cache keeps its old expiry).
		return false
	end
	if type(result) == "table" and result.ServerId == _serverId then
		-- The UpdateAsync result actually confirms this server
		-- owns the lease: only now may the cached expiry move.
		_lease[player] = deepCopy(result)
		return true
	end
	if type(result) == "table"
		and type(result.ServerId) == "string"
		and result.ServerId ~= _serverId
		and (tonumber(result.ExpiresAt) or 0) > os.time()
	then
		-- Another live server owns the lease now (it took over
		-- while this save was in flight): do NOT extend the local
		-- cache — record the observed lease and mark the session
		-- lost, so the next save refuses instead of overwriting
		-- the new owner's data.
		_lease[player] = deepCopy(result)
		_sessionLost[player] = true
		warn("[DataService] Session lease for " .. player.Name
			.. " is now held by another server (found on refresh); this server stops saving that profile")
	end
	return false
end

function DataService.ReleaseSessionLease(player: Player)
	local store = getStore()
	_lease[player] = nil
	if not store then
		return
	end
	-- UpdateAsync (not RemoveAsync): only delete the lease when it
	-- is still ours — a fast rejoin on another server must not lose
	-- its lease to our delayed release.
	pcall(function()
		store:UpdateAsync(leaseKeyFor(player.UserId), function(old: any): any
			if type(old) == "table" and old.ServerId == _serverId then
				return nil
			end
			return old
		end)
	end)
end

function DataService.AcquireSessionLease(player: Player): boolean
	return acquireSessionLease(player)
end

function DataService.GetServerId(): string
	return _serverId
end

function DataService.IsSessionContested(player: Player): boolean
	return _sessionContested[player] == true or _sessionLost[player] == true
end

-- GetSessionLeaseState(player): the session-lease state as this
-- server currently sees it, for ownership gates (R5-2) and
-- diagnostics. Owned is true only when the cached lease names this
-- server and is still live; it is a LOCAL view — a save re-verifies
-- against the stored lease first (see checkSessionLease), so Owned
-- never authorises a write on its own. LastLeaseCheckFailed is true
-- when the most recent lease check could not verify ownership at
-- all (read failed AND proof failed) and refused that save attempt.
function DataService.GetSessionLeaseState(player: Player): { [string]: any }
	local cached = _lease[player]
	local owned = type(cached) == "table"
		and cached.ServerId == _serverId
		and (tonumber(cached.ExpiresAt) or 0) > os.time()
	return {
		Owned = owned == true,
		Contested = _sessionContested[player] == true,
		Lost = _sessionLost[player] == true,
		ServerId = _serverId,
		LeaseExpiresAt = type(cached) == "table" and tonumber(cached.ExpiresAt) or nil,
		LastLeaseCheckFailed = _leaseCheckUnverified[player] == true,
	}
end

-- GetSaveBlockedReason(player): nil when this session may save, else
-- "load_failed" | "session_contested" | "session_lost". GameManager
-- uses this on join to fire the client SaveWarning (R4-8).
function DataService.GetSaveBlockedReason(player: Player): string?
	if _loadFailed[player] then
		return "load_failed"
	end
	if _sessionContested[player] then
		return "session_contested"
	end
	if _sessionLost[player] then
		return "session_lost"
	end
	return nil
end

-- GetSaveWarning(player): the client-facing warning payload for a
-- session that cannot save, or nil when the session is healthy. The
-- message states plainly that progress will NOT be saved this
-- session and that rejoining retries the load / lease.
function DataService.GetSaveWarning(player: Player): { [string]: string }?
	local reason = DataService.GetSaveBlockedReason(player)
	if reason == nil then
		return nil
	end
	local message: string
	if reason == "load_failed" then
		message = "WARNING: Your save data could not be loaded. You are playing on temporary progress that will NOT be saved. Please rejoin to try again."
	elseif reason == "session_contested" then
		message = "WARNING: Another game server is already saving this account. This session cannot save — progress will NOT be kept. Please rejoin."
	else
		message = "WARNING: This server lost ownership of your save session. Progress will NOT be saved — please rejoin."
	end
	return { Reason = reason, Message = message }
end

-- Test-only hook for the r4-transactions suite (see _testWaitHook).
function DataService._TestSetWaitHook(fn: ((Player) -> ())?)
	_testWaitHook = fn
end

function DataService._TestSetSavingFlag(player: Player, held: boolean)
	_saving[player] = held == true and true or nil
end

function DataService.GetSaveWaitIterations(): number
	return _saveWaitIterations
end

function DataService.GetShutdownStats(): { [string]: number }
	return {
		attempted = _shutdownStats.attempted,
		spawned = _shutdownStats.spawned,
		completed = _shutdownStats.completed,
		saved = _shutdownStats.saved,
	}
end

-- ---------------------------------------------------------------------------
-- R4-3: coin reservations (pending-reward commit safety).
-- ---------------------------------------------------------------------------
-- ReserveCoins(player, key, amount): earmark `amount` coins already
-- in the player's balance under `key`. Only the credited amount of a
-- pending reward commit is ever reserved, and only for the duration
-- of that commit's verified save. GetSpendableCoins is the balance
-- every debit must check; AddCoins enforces the floor itself, so a
-- debit route that only calls AddCoins can never spend reserved
-- coins even if it checked the raw balance first.
function DataService.ReserveCoins(player: Player, key: string, amount: number): boolean
	local data = _cache[player]
	if not data or type(key) ~= "string" or key == "" then
		return false
	end
	local wanted = math.floor(tonumber(amount) or 0)
	if wanted <= 0 then
		return false
	end
	if (tonumber(data.Coins) or 0) - DataService.GetReservedCoins(player) < wanted then
		return false
	end
	if type(_reserved[player]) ~= "table" then
		_reserved[player] = {}
	end
	_reserved[player][key] = (_reserved[player][key] or 0) + wanted
	return true
end

function DataService.ReleaseReservation(player: Player, key: string): number
	local perPlayer = _reserved[player]
	if type(perPlayer) ~= "table" or type(key) ~= "string" then
		return 0
	end
	local released = perPlayer[key] or 0
	perPlayer[key] = nil
	return released
end

function DataService.GetReservedCoins(player: Player): number
	local perPlayer = _reserved[player]
	if type(perPlayer) ~= "table" then
		return 0
	end
	local total = 0
	for _, amount in pairs(perPlayer) do
		total += math.floor(tonumber(amount) or 0)
	end
	return total
end

function DataService.GetSpendableCoins(player: Player): number
	local data = _cache[player]
	if not data then
		return 0
	end
	return math.max(0, (tonumber(data.Coins) or 0) - DataService.GetReservedCoins(player))
end

-- R3-1: a sidecar read distinguishes "empty" from "failed".
-- readSidecar returns (ok, value): ok == false means BOTH GetAsync
-- attempts errored and the caller MUST abort — never treat the result
-- as an empty list, or a later write would silently replace whatever
-- was stored. ok == true with value == nil means the key is genuinely
-- empty (a stored non-table value is also reported as empty: no reader
-- can use it, matching the pre-R3 read behaviour). Retry policy: two
-- attempts, 0.5s apart; a caller that needs the data retries the whole
-- operation later — the failed read itself writes nothing.
local function readSidecar(store: any, key: string): (boolean, { any }?)
	local lastErr: any = nil
	for _ = 1, 2 do
		local ok, value = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			if type(value) == "table" then
				return true, value
			end
			return true, nil
		end
		lastErr = value
		task.wait(0.5)
	end
	warn("[DataService] Sidecar read failed for " .. key .. " after 2 attempts: " .. tostring(lastErr))
	return false, nil
end

-- R3-3 / R3-4: the dedupe identity of a sidecar entry. A TxId
-- identifies ONE reward recording (see RaidService.newRewardTxId):
-- two entries with the same TxId are the same recording replayed,
-- two with different TxIds are two separate transactions — even for
-- the same InstanceId. Entries without a TxId (legacy pending entries
-- and escrow records) fall back to the stable InstanceId + CreatedAt
-- pair; escrow records carry no CreatedAt, so their identity is just
-- the InstanceId, which is the pre-R3 rule and is unchanged for them.
local function sidecarIdentity(entry: any): string?
	if type(entry) ~= "table" then
		return nil
	end
	if type(entry.TxId) == "string" and entry.TxId ~= "" then
		return "tx:" .. entry.TxId
	end
	if type(entry.InstanceId) == "string" then
		return "legacy:" .. entry.InstanceId .. ":" .. tostring(entry.CreatedAt or 0)
	end
	return nil
end

-- R3-2: atomic sidecar append via UpdateAsync. The transform callback
-- is a pure function of the old value (no side effects, no DataStore
-- calls, deterministic): it copies the stored list, dedupes by
-- sidecarIdentity, and either keeps the existing entry (combine == nil)
-- or replaces it with combine(existing, entry). A duplicate identity
-- therefore appends exactly once, and if Roblox retries the callback
-- (concurrent writers / contention) the result is the same list. A
-- stored non-table value is treated as an empty list (no reader can
-- use it; see readSidecar).
-- R3-4: the pending-reward path passes NO combine: a replayed TxId is
-- a no-op (the existing entry is kept, its Amount untouched), and a
-- new TxId for the same InstanceId is a SEPARATE entry. The old
-- combine accumulated Amount onto the existing entry, which double-
-- counted whenever the caller passed an already-accumulated total as
-- if it were a delta (100 then +150 landed as 350 in the sidecar).
-- Amounts are now summed only where they belong — in the in-cache
-- aggregate (RaidService.recordPendingReward) and at merge time
-- (mergeSidecars) — never inside this transform.
-- Returns (true) on success, (false, err) on failure. A failure is
-- safe to retry: the append is idempotent per identity, and the
-- caller keeps its in-memory / in-transit record until a retry
-- succeeds. NEVER pay rewards or destroy a thief-side copy inside
-- this callback — it may run more than once.
-- Returns (true) on success, (false, err) on failure. A failure is
-- safe to retry: the append is idempotent per InstanceId, and the
-- caller keeps its in-memory / in-transit record until a retry
-- succeeds. NEVER pay rewards or destroy a thief-side copy inside
-- this callback — it may run more than once.
local function appendSidecar(
	store: any,
	key: string,
	entry: { any },
	combine: ((any, any) -> any)?
): (boolean, string?)
	local lastErr: any = nil
	for _ = 1, 2 do
		local ok, result = pcall(function()
			return store:UpdateAsync(key, function(oldValue: any): { any }
				local list: { any } = {}
				if type(oldValue) == "table" then
					for _, existing in ipairs(oldValue) do
						table.insert(list, existing)
					end
				end
				for index, existing in ipairs(list) do
					if type(existing) == "table"
						and sidecarIdentity(existing) ~= nil
						and sidecarIdentity(existing) == sidecarIdentity(entry)
					then
						if combine ~= nil then
							local updated = combine(existing, entry)
							if updated ~= nil then
								list[index] = updated
							end
						end
						return list
					end
				end
				table.insert(list, deepCopy(entry))
				return list
			end)
		end)
		if ok then
			return true
		end
		lastErr = result
		task.wait(0.5)
	end
	warn("[DataService] Sidecar append failed for " .. key .. " after 2 attempts: " .. tostring(lastErr))
	return false, tostring(lastErr)
end

local function deleteSidecar(store: any, key: string): boolean
	local ok = pcall(function()
		store:RemoveAsync(key)
	end)
	return ok
end

-- Merge one escrowed owned record into `data`: insert the owned record
-- (deduped by InstanceId) and restore its placed copy when the record
-- was placed and no placed copy exists yet. Returns true iff anything
-- was merged. The escrow record is a full owned record plus Placed /
-- Slot / PlacedAt / BankedIncome (written by RaidService when it
-- escrows a return for an offline victim). R3-6: an entry whose
-- ReturnTxId is already in data.ReturnedTxns is skipped (the return
-- is already reflected in this profile), and the TxId is recorded
-- there when an entry is applied or deduped — see the marker notes
-- inside the function.
local function mergeEscrowRecord(data: any, record: any): boolean
	if type(record) ~= "table" or type(record.InstanceId) ~= "string" then
		return false
	end
	-- R3-6: a return transaction already reflected in this profile
	-- is never applied again. The marker (data.ReturnedTxns) is
	-- written by RaidService into the same data table as the
	-- returned record and persisted with it in one SetAsync, so a
	-- marker present in the loaded key proves the return landed —
	-- even when the record itself has since been stolen away again
	-- (a re-steal removes the record but carries the marker forward
	-- in the cache). A stale escrow entry for that transaction is
	-- then skipped instead of resurrecting the record and voiding
	-- the new theft. Legacy entries (no ReturnTxId) merge as before.
	local txId = record.ReturnTxId
	local hasTxId = type(txId) == "string" and txId ~= ""
	if hasTxId then
		if type(data.ReturnedTxns) == "table" and data.ReturnedTxns[txId] ~= nil then
			return false
		end
	end
	if type(data.OwnedInstances) ~= "table" then
		data.OwnedInstances = {}
	end
	local owned: any = nil
	for _, inst in ipairs(data.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == record.InstanceId then
			owned = inst
			break
		end
	end
	local merged = false
	if owned == nil then
		owned = deepCopy(record)
		owned.InTransit = nil
		owned.StolenFromUserId = nil
		owned.StolenSlot = nil
		owned.StolenPlacedAt = nil
		owned.StolenBankedIncome = nil
		table.insert(data.OwnedInstances, owned)
		merged = true
	end
	-- R3-6: record the transaction as applied, whether the record
	-- was just inserted or was already here (dedupe). The marker is
	-- what invalidates this escrow entry on a later load — without
	-- it, a stale entry could resurrect the record after a
	-- legitimate re-steal. Recording it on dedupe matters too: the
	-- record is already in the key (e.g. the return's own save
	-- landed before this load), so the entry's effect is present and
	-- the transaction is applied by definition.
	if hasTxId then
		if type(data.ReturnedTxns) ~= "table" then
			data.ReturnedTxns = {}
		end
		if data.ReturnedTxns[txId] == nil then
			data.ReturnedTxns[txId] = {
				TxId = txId,
				InstanceId = record.InstanceId,
				ReturnedAt = os.time(),
			}
		end
	end
	if record.Placed == true then
		if type(data.Base) ~= "table" then
			data.Base = { Placed = {} }
		end
		if type(data.Base.Placed) ~= "table" then
			data.Base.Placed = {}
		end
		local placed: any = nil
		for _, entry in ipairs(data.Base.Placed) do
			if type(entry) == "table" and entry.InstanceId == record.InstanceId then
				placed = entry
				break
			end
		end
		if placed == nil then
			local occupied: { [number]: boolean } = {}
			for _, entry in ipairs(data.Base.Placed) do
				if type(entry) == "table" then
					occupied[math.floor(tonumber(entry.Slot) or 0)] = true
				end
			end
			local slot = math.floor(tonumber(record.Slot) or 0)
			if slot < 1 or occupied[slot] then
				slot = 0
				for candidate = 1, 24 do
					if not occupied[candidate] then
						slot = candidate
						break
					end
				end
				if slot == 0 then
					slot = math.floor(tonumber(record.Slot) or 1)
				end
			end
			local traitLevels: { [string]: number }? = nil
			if type(record.TraitLevels) == "table" then
				local copied: { [string]: number } = {}
				for traitId, level in pairs(record.TraitLevels) do
					copied[traitId] = level
				end
				traitLevels = copied
			end
			table.insert(data.Base.Placed, {
				InstanceId = record.InstanceId,
				CharacterId = record.CharacterId,
				Slot = slot,
				Level = tonumber(record.Level) or 1,
				Glitched = record.Glitched == true,
				Mutation = record.Mutation,
				BankedIncome = tonumber(record.BankedIncome) or 0,
				PlacedAt = tonumber(record.PlacedAt) or os.time(),
				Evolved = record.Evolved,
				EvolutionId = record.EvolutionId,
				EvolvedTrait = record.EvolvedTrait,
				EvolvedFormName = record.EvolvedFormName,
				TraitLevels = traitLevels,
			})
			owned.Placed = true
			owned.Slot = slot
			merged = true
		end
	end
	return merged
end

-- R3-3: the transaction id of a pending sidecar entry. Entries
-- written by RaidService carry TxId (see newRewardTxId there); a
-- legacy entry without one is identified by "legacy-<InstanceId>-
-- <CreatedAt>" — the same synthesis RaidService uses for a legacy
-- in-cache entry, so a legacy reward merged here and later recovered
-- there is recognised as the same transaction. Two distinct legacy
-- recordings for one instance share an id only if they were recorded
-- in the same second, which cannot happen for new recordings (they
-- always carry a TxId).
local function pendingTxId(entry: any): string
	if type(entry.TxId) == "string" and entry.TxId ~= "" then
		return entry.TxId
	end
	return "legacy-" .. tostring(entry.InstanceId) .. "-" .. tostring(entry.CreatedAt or 0)
end

-- R3-3: the per-transaction sub-ledger of an in-cache pending entry.
-- PendingRewards[InstanceId].Txns maps TxId -> that recording's delta
-- amount. A legacy entry (loaded from a pre-R3 save, no Txns) is
-- normalised to a single implicit transaction — its legacy id, for
-- its full Amount — so merge and recovery treat it exactly like a
-- TxId entry instead of re-adding it on every re-merge.
local function pendingEntryTxns(existing: any, instanceId: string): { [string]: number }
	if type(existing.Txns) == "table" then
		return existing.Txns
	end
	local txns: { [string]: number } = {}
	txns[pendingTxId(existing)] = math.floor(tonumber(existing.Amount) or 0)
	existing.Txns = txns
	return txns
end

-- Read both sidecar keys for `player` and merge them into the loaded
-- cache. Escrow entries restore returned Brainrots; pending entries
-- merge into data.PendingRewards (one aggregate entry per InstanceId,
-- whose Amount is the sum of its not-yet-paid recordings and whose
-- Txns sub-ledger records each recording's TxId and delta).
-- R3-3 exactly-once: a sidecar entry is merged ONLY when its TxId is
-- neither already processed (data.ProcessedRewardTxns — the durable
-- proof the reward was paid, persisted in the main profile together
-- with the coin change) nor already pending in the cache under that
-- TxId. A failed sidecar deletion therefore cannot double-pay: the
-- next load re-merges the same entries and every one of them is
-- recognised as processed or already-pending and skipped. A re-merge
-- after a crash adds nothing new for the same reason.
-- Returns (merged, escrowDone, pendingDone). `merged` is true iff
-- anything was merged. Each `*Done` flag is true iff that sidecar's
-- read SUCCEEDED and the key held entries — only then may SaveData
-- delete that key after a successful save. A FAILED read leaves that
-- key untouched (its entries stay parked for the next load) while the
-- other sidecar still merges normally (R3-1). Note pendingDone stays
-- true even when every entry was skipped as processed / already
-- pending: the key is then stale, and deleting it on the next
-- successful save is safe precisely because the skipped entries are
-- already durable in the main profile (processed markers) or in the
-- cache pending entry the save persists.
local function mergeSidecars(data: any, store: any, player: Player): (boolean, boolean, boolean)
	local merged = false
	local escrowDone = false
	local escrowOk, escrow = readSidecar(store, escrowKeyFor(player.UserId))
	if escrowOk then
		if type(escrow) == "table" then
			escrowDone = #escrow > 0
			-- R4-1: delivery tombstones. A delivery that supersedes
			-- an older return parks a tombstone entry
			-- ({Superseded = true, SupersedesReturnTxIds = {...}})
			-- in this same list. Tombstones are processed FIRST:
			-- every superseded ReturnTxId is recorded in
			-- data.ReturnedTxns, so the existing marker-skip in
			-- mergeEscrowRecord then refuses the stale return
			-- entry — even when the victim's own key never saved
			-- the marker. The tombstone itself is never merged as
			-- a record. A tombstone may also supersede legacy
			-- entries (no ReturnTxId) for its InstanceId.
			local supersededTxns: { [string]: boolean } = {}
			local legacySuperseded: { [string]: boolean } = {}
			for _, record in ipairs(escrow) do
				if type(record) == "table" and record.Superseded == true then
					if type(record.SupersedesReturnTxIds) == "table" then
						for _, txId in ipairs(record.SupersedesReturnTxIds) do
							if type(txId) == "string" and txId ~= "" then
								supersededTxns[txId] = true
							end
						end
					end
					if record.SupersedesLegacy == true and type(record.InstanceId) == "string" then
						legacySuperseded[record.InstanceId] = true
					end
				end
			end
			if next(supersededTxns) ~= nil then
				if type(data.ReturnedTxns) ~= "table" then
					data.ReturnedTxns = {}
				end
				for txId in pairs(supersededTxns) do
					if data.ReturnedTxns[txId] == nil then
						data.ReturnedTxns[txId] = {
							TxId = txId,
							InstanceId = "?",
							ReturnedAt = os.time(),
							Superseded = true,
						}
					end
				end
			end
			for _, record in ipairs(escrow) do
				if type(record) == "table" and record.Superseded == true then
					-- Tombstone: already applied above, never a record.
				elseif type(record) == "table"
					and (type(record.ReturnTxId) ~= "string" or record.ReturnTxId == "")
					and legacySuperseded[record.InstanceId] == true
				then
					-- Legacy return entry superseded by a delivery
					-- tombstone: never resurrect it.
				elseif mergeEscrowRecord(data, record) then
					merged = true
				end
			end
		end
	else
		warn("[DataService] Escrow sidecar read failed for " .. player.Name
			.. "; entries left in place for the next load")
	end
	local pendingDone = false
	local pendingOk, pending = readSidecar(store, pendingKeyFor(player.UserId))
	if pendingOk then
		if type(pending) == "table" then
			pendingDone = #pending > 0
			if type(data.PendingRewards) ~= "table" then
				data.PendingRewards = {}
			end
			if type(data.ProcessedRewardTxns) ~= "table" then
				data.ProcessedRewardTxns = {}
			end
			if type(data.VoidedRewardTxns) ~= "table" then
				data.VoidedRewardTxns = {}
			end
			-- R4-4: reward-void entries. A voided delivery parks
			-- {Voided = true, VoidTxId = <reward TxId>} in this
			-- list; the voided TxId is recorded in
			-- data.VoidedRewardTxns and any reward entry (in this
			-- list or already in the cache) for that TxId is
			-- dropped without paying — a voided delivery's reward
			-- can never be recovered, on any rejoin.
			for _, entry in ipairs(pending) do
				if type(entry) == "table" and entry.Voided == true
					and type(entry.VoidTxId) == "string" and entry.VoidTxId ~= ""
				then
					if data.VoidedRewardTxns[entry.VoidTxId] == nil then
						data.VoidedRewardTxns[entry.VoidTxId] = {
							TxId = entry.VoidTxId,
							InstanceId = entry.InstanceId,
							VoidedAt = os.time(),
						}
					end
				end
				if type(entry) == "table" and entry.Voided == true
					and entry.VoidInstance == true
					and type(entry.InstanceId) == "string" and entry.InstanceId ~= ""
				then
					-- R5-3: instance-level void tombstone (see
					-- RecordRewardVoidForInstance). The whole
					-- instance's rewards are void, whatever TxIds
					-- they carry — including TxIds this server
					-- never saw (the sidecar read failed when the
					-- void was recorded, so no TxId was known).
					-- Record the instance in
					-- VoidedRewardInstances; the drop loop below
					-- voids every TxId of that instance out of the
					-- cache, and the merge loop refuses every
					-- reward entry for it.
					if type(data.VoidedRewardInstances) ~= "table" then
						data.VoidedRewardInstances = {}
					end
					if data.VoidedRewardInstances[entry.InstanceId] == nil then
						data.VoidedRewardInstances[entry.InstanceId] = {
							InstanceId = entry.InstanceId,
							VoidedAt = os.time(),
						}
					end
				end
			end
			-- Drop voided TxIds out of any in-cache pending entry
			-- (they may have merged before the void was parked).
			for instanceId, existing in pairs(data.PendingRewards) do
				if type(existing) == "table" then
					local instanceVoided = type(data.VoidedRewardInstances) == "table"
						and data.VoidedRewardInstances[instanceId] ~= nil
					if type(existing.Txns) == "table" then
						local changed = false
						for txId, delta in pairs(existing.Txns) do
							if data.VoidedRewardTxns[txId] ~= nil or instanceVoided then
								-- A TxId dropped because its whole
								-- instance is voided is recorded in
								-- the per-TxId ledger too, so the
								-- ledger stays precise even for
								-- TxIds the void never named.
								if data.VoidedRewardTxns[txId] == nil then
									data.VoidedRewardTxns[txId] = {
										TxId = txId,
										InstanceId = instanceId,
										VoidedAt = os.time(),
									}
								end
								existing.Amount = (tonumber(existing.Amount) or 0)
									- math.floor(tonumber(delta) or 0)
								existing.Txns[txId] = nil
								changed = true
							end
						end
						if changed then
							if (tonumber(existing.Amount) or 0) <= 0 or next(existing.Txns) == nil then
								data.PendingRewards[instanceId] = nil
							end
							merged = true
						end
					elseif instanceVoided then
						-- Legacy entry (no Txns sub-ledger) for a
						-- voided instance: drop it whole.
						data.VoidedRewardTxns[pendingTxId(existing)] = {
							TxId = pendingTxId(existing),
							InstanceId = instanceId,
							VoidedAt = os.time(),
						}
						data.PendingRewards[instanceId] = nil
						merged = true
					end
				end
			end
			for _, entry in ipairs(pending) do
				if type(entry) == "table" and type(entry.InstanceId) == "string" then
					local amount = math.floor(tonumber(entry.Amount) or 0)
					if amount > 0 then
						local txId = pendingTxId(entry)
						if data.ProcessedRewardTxns[txId] == nil
							and data.VoidedRewardTxns[txId] == nil
							and (type(data.VoidedRewardInstances) ~= "table"
								or data.VoidedRewardInstances[entry.InstanceId] == nil)
						then
							local existing = data.PendingRewards[entry.InstanceId]
							if type(existing) == "table" then
								local txns = pendingEntryTxns(existing, entry.InstanceId)
								if txns[txId] == nil then
									txns[txId] = amount
									existing.Amount = (tonumber(existing.Amount) or 0) + amount
									merged = true
								end
								-- Same TxId already pending: a re-merge
								-- of the same recording — no-op.
							else
								data.PendingRewards[entry.InstanceId] = {
									InstanceId = entry.InstanceId,
									CharacterId = entry.CharacterId,
									Amount = amount,
									Reason = entry.Reason,
									CreatedAt = entry.CreatedAt,
									Txns = { [txId] = amount },
								}
								merged = true
							end
						elseif type(data.VoidedRewardInstances) == "table"
							and data.VoidedRewardInstances[entry.InstanceId] ~= nil
						then
							-- R5-3: reward entry for a voided
							-- instance (its TxId was never named by
							-- the void — the sidecar read failed when
							-- the void was recorded): record the TxId
							-- voided and skip it — never pay it.
							if data.VoidedRewardTxns[txId] == nil then
								data.VoidedRewardTxns[txId] = {
									TxId = txId,
									InstanceId = entry.InstanceId,
									VoidedAt = os.time(),
								}
							end
						end
						-- Processed TxId: already paid (its coin change
						-- and marker were persisted together in the
						-- main profile) — skip, never pay again.
					end
				end
			end
		end
	else
		warn("[DataService] Pending sidecar read failed for " .. player.Name
			.. "; entries left in place for the next load")
	end
	return merged, escrowDone, pendingDone
end

-- EscrowReturnedInstance(victimUserId, record): durably park a Brainrot
-- being returned to an OFFLINE victim (RaidService calls this when the
-- victim left mid-theft). The victim's next successful load merges it
-- back into OwnedInstances (+ its placed copy). Idempotent per
-- InstanceId: an already-escrowed instance is not written twice.
-- R3-2: the append is atomic (UpdateAsync, deduped by InstanceId), so
-- two servers escrowing for the same victim cannot lose each other's
-- entry, and a failed read can no longer wipe the stored list (R3-1).
-- Returns false with no store (Studio) or when the write fails — the
-- caller must then keep the record in transit instead of dropping it.
function DataService.EscrowReturnedInstance(victimUserId: any, record: any): boolean
	local userId = tonumber(victimUserId)
	if not userId or type(record) ~= "table" or type(record.InstanceId) ~= "string" then
		return false
	end
	local store = getStore()
	if not store then
		return false
	end
	local ok, err = appendSidecar(store, escrowKeyFor(userId), deepCopy(record))
	if not ok then
		warn("[DataService] Escrow append failed for user " .. tostring(userId) .. ": " .. tostring(err))
	end
	return ok
end

-- ParkReturnEscrow(victimUserId, record): durably park one return
-- transaction for a victim (R3-6 — RaidService calls this for EVERY
-- return, online or offline, before the in-memory commit). The record
-- carries ReturnTxId, the id of the return event it belongs to.
-- Unlike EscrowReturnedInstance (keep-first per InstanceId), a
-- re-park for the same InstanceId REPLACES the existing entry: the
-- sidecar always holds the LATEST return for that instance, so a
-- stale entry from an earlier return can never backstop — or
-- resurrect — a later one. The replace is a pure transform (see
-- appendSidecar): it copies the new entry in and touches nothing
-- else, so a retried callback returns the same list. Returns false
-- with no store (Studio) or when the write fails — the caller keeps
-- its in-memory / in-transit record until a retry succeeds, never
-- drops it.
function DataService.ParkReturnEscrow(victimUserId: any, record: any): boolean
	local userId = tonumber(victimUserId)
	if not userId or type(record) ~= "table" or type(record.InstanceId) ~= "string" then
		return false
	end
	local store = getStore()
	if not store then
		return false
	end
	local ok, err = appendSidecar(store, escrowKeyFor(userId), deepCopy(record),
		function(_existing: any, entry: any): any
			return deepCopy(entry)
		end)
	if not ok then
		warn("[DataService] Return-escrow park failed for user " .. tostring(userId) .. ": " .. tostring(err))
	end
	return ok
end

-- InvalidateReturnEscrow(victimUserId, instanceId, deliveryTxId):
-- R4-1 durable delivery tombstone. Reads the victim's escrow
-- sidecar; when it holds return entries for `instanceId` (returns
-- parked before this delivery, whose victim-key marker never
-- landed), parks a tombstone entry naming their ReturnTxIds (plus
-- SupersedesLegacy when a legacy entry with no ReturnTxId is
-- present). The victim's next load records the superseded TxIds in
-- ReturnedTxns (see mergeSidecars) and refuses to apply those
-- entries, so a stale escrow can never resurrect a Brainrot a second
-- thief legitimately delivered. Returns (ok, hadStale, err,
-- staleTxIds):
--   * (true, false) — no stale entry; nothing to invalidate.
--   * (true, true) — tombstone parked.
--   * (false, hadStale, err) — the invalidation could NOT be proven:
--     the escrow read failed, or the tombstone append failed. The
--     caller (RaidService.ConfirmDelivery) MUST fail the delivery
--     closed on (false, ...) — it must not silently create a second
--     owner. R5-5: a missing store is also (false, ...) — an
--     unavailable DataStore handle is NOT an empty sidecar, and
--     claiming "nothing stale" when the escrow cannot even be read
--     is the fail-open that duplicated Brainrots during an outage.
--     (Studio with API access off hits this too: deliveries are
--     refused there rather than risking a duplicate — the thief
--     keeps carrying and can retry when the store is available.)
-- The tombstone's own TxId ("sup-<deliveryTxId>") keeps its
-- appendSidecar identity distinct from return entries (which carry
-- no TxId) and from other tombstones, so re-parking the same
-- delivery is idempotent and a later return for the same instance
-- (a NEW ReturnTxId, parked after this delivery) is NOT superseded
-- by it — only returns parked BEFORE the delivery are named.
function DataService.InvalidateReturnEscrow(victimUserId: any, instanceId: string, deliveryTxId: string?): (boolean, boolean, string?, { string }?)
	local userId = tonumber(victimUserId)
	if not userId or type(instanceId) ~= "string" or instanceId == "" then
		return false, false, "invalid args", nil
	end
	local store = getStore()
	if not store then
		-- R5-5: FAIL CLOSED. A missing store is not an empty escrow:
		-- the victim's sidecar may hold a stale return this server
		-- cannot see, and claiming "nothing stale" would let
		-- ConfirmDelivery commit a second owner of the instance.
		warn("[DataService] InvalidateReturnEscrow unavailable for user " .. tostring(userId) .. ": DataStore unavailable")
		return false, false, "datastore unavailable", nil
	end
	local okRead, list = readSidecar(store, escrowKeyFor(userId))
	if not okRead then
		return false, false, "escrow read failed", nil
	end
	local staleTxIds: { string } = {}
	local hasLegacy = false
	if type(list) == "table" then
		for _, entry in ipairs(list) do
			if type(entry) == "table" and entry.InstanceId == instanceId and entry.Superseded ~= true then
				if type(entry.ReturnTxId) == "string" and entry.ReturnTxId ~= "" then
					table.insert(staleTxIds, entry.ReturnTxId)
				else
					hasLegacy = true
				end
			end
		end
	end
	if #staleTxIds == 0 and not hasLegacy then
		return true, false, nil, nil
	end
	local tombstone = {
		InstanceId = instanceId,
		Superseded = true,
		SupersedesReturnTxIds = staleTxIds,
		SupersedesLegacy = hasLegacy,
		DeliveryTxId = deliveryTxId,
		SupersededAt = os.time(),
		TxId = "sup-" .. tostring(deliveryTxId or ""),
	}
	local okAppend, err = appendSidecar(store, escrowKeyFor(userId), deepCopy(tombstone))
	if not okAppend then
		return false, true, tostring(err), staleTxIds
	end
	return true, true, nil, staleTxIds
end

-- RecordRewardVoidSidecar(player, txId, instanceId): R4-4 durable
-- reward void. Parks {Voided = true, VoidTxId = txId} in the
-- player's pending-reward sidecar so a later load records the TxId
-- in data.VoidedRewardTxns and never pays it (see mergeSidecars).
-- The void entry's TxId is "void-<txId>" so its appendSidecar
-- identity never collides with the reward entry it voids (same
-- TxId, different identity) — the two entries coexist in the list.
-- Returns false with no store or when the write fails; the
-- in-cache VoidedRewardTxns entry is the first line of defence and
-- the caller's next main-profile save persists it.
function DataService.RecordRewardVoidSidecar(player: Player, txId: string, instanceId: string): boolean
	if not player or type(txId) ~= "string" or txId == ""
		or type(instanceId) ~= "string" or instanceId == ""
	then
		return false
	end
	local store = getStore()
	if not store then
		return false
	end
	local ok, err = appendSidecar(store, pendingKeyFor(player.UserId), {
		TxId = "void-" .. txId,
		VoidTxId = txId,
		InstanceId = instanceId,
		Voided = true,
		CreatedAt = os.time(),
	})
	if not ok then
		warn("[DataService] Reward-void append failed for " .. player.Name .. ": " .. tostring(err))
	end
	return ok
end

-- RecordRewardVoidForInstance(player, instanceId, txIds?): R5-3
-- durable reward void, INDEPENDENT of the in-memory PendingRewards
-- table and of a successful pending-sidecar read. Parks an
-- instance-level void tombstone {Voided = true, VoidInstance = true,
-- InstanceId, TxId = "void-inst-<instanceId>"} in the player's
-- pending-reward sidecar, plus one per-TxId void entry for every
-- TxId supplied (or found by a best-effort read of the sidecar).
-- mergeSidecars processes the tombstone first and refuses EVERY
-- reward entry for the instance — including entries whose TxId the
-- voiding server never knew, because the sidecar read failed when
-- the void was recorded. That is the R5-3 fix: the old void could
-- only name TxIds present in the cache, so a void recorded while
-- the sidecar was unreadable left the reward payable once the
-- sidecar became readable again.
-- The tombstone's TxId is stable ("void-inst-<instanceId>"), so
-- re-parking it is idempotent (appendSidecar dedupes by identity)
-- and a retry uses the same identifier. The best-effort sidecar
-- read only ADDS known TxIds; a failed read never fails the void —
-- the tombstone does not need it.
-- Returns (true, voidedTxIds) iff the tombstone landed (the void is
-- durable); (false, knownTxIds, err) otherwise — no store, or the
-- tombstone append failed. A per-TxId void that fails to park does
-- NOT fail the void: the tombstone already voids the whole
-- instance, so the per-TxId entries are ledger precision only
-- (mergeSidecars records the TxId as voided when it refuses the
-- entry for the instance). Callers MUST check the first return:
-- a false result means the void is not durable (see
-- RaidService.voidPendingRewardsForInstance, which keeps it pending
-- for retry and refuses to finish the recovery silently).
function DataService.RecordRewardVoidForInstance(player: Player, instanceId: string, txIds: { string }?): (boolean, { string }?, string?)
	if not player or type(instanceId) ~= "string" or instanceId == "" then
		return false, {}, "invalid args"
	end
	local store = getStore()
	if not store then
		return false, {}, "datastore unavailable"
	end
	-- Known TxIds: the caller's list, plus whatever a best-effort
	-- read of the sidecar finds for this instance (the caller may
	-- not know them — its cache entry may never have merged).
	local known: { [string]: boolean } = {}
	if type(txIds) == "table" then
		for _, txId in ipairs(txIds) do
			if type(txId) == "string" and txId ~= "" then
				known[txId] = true
			end
		end
	end
	local okRead, list = readSidecar(store, pendingKeyFor(player.UserId))
	if okRead and type(list) == "table" then
		for _, entry in ipairs(list) do
			if type(entry) == "table" and entry.InstanceId == instanceId
				and type(entry.TxId) == "string" and entry.TxId ~= ""
				and entry.Voided ~= true
			then
				known[entry.TxId] = true
			end
		end
	end
	-- The tombstone FIRST: it is the durability criterion. If it
	-- cannot be parked, the void is not durable — report false and
	-- let the caller keep it pending for retry.
	local okTomb, errTomb = appendSidecar(store, pendingKeyFor(player.UserId), {
		TxId = "void-inst-" .. instanceId,
		Voided = true,
		VoidInstance = true,
		InstanceId = instanceId,
		VoidedAt = os.time(),
	})
	if not okTomb then
		warn("[DataService] Reward-void tombstone append failed for " .. player.Name
			.. " (" .. instanceId .. "): " .. tostring(errTomb))
		local knownList: { string } = {}
		for txId in pairs(known) do
			table.insert(knownList, txId)
		end
		return false, knownList, tostring(errTomb)
	end
	-- Per-TxId voids for every known TxId (best effort: the
	-- tombstone already covers the instance).
	local voided: { string } = {}
	for txId in pairs(known) do
		table.insert(voided, txId)
		if not DataService.RecordRewardVoidSidecar(player, txId, instanceId) then
			warn("[DataService] Per-TxId reward-void append failed for " .. player.Name
				.. " (" .. instanceId .. ", " .. txId .. "); the instance tombstone still voids it")
		end
	end
	return true, voided, nil
end

-- RecordPendingRewardSidecar(player, entry): durably park a steal
-- reward that cannot be persisted in the main key because this
-- session cannot save (load failed). RaidService calls this only in
-- that case; the entry is merged into data.PendingRewards on the next
-- successful load. R3-2: the append is atomic (UpdateAsync); a second
-- entry with the SAME TxId is a replayed recording and is a no-op
-- (the existing entry is kept, its Amount untouched — NO combine, see
-- R3-4 below), while a different TxId for the same InstanceId is a
-- separate transaction and lands as its own entry. R3-4: `entry`
-- carries ONE recording's delta Amount under its own TxId — the
-- caller must never pass an already-accumulated total here. R3-5:
-- RaidService also parks through this function BEFORE paying a
-- saveable session's reward, so the sidecar is the durable backstop
-- if the main-profile save then fails. Returns false with no store
-- or when the write fails — the in-cache ledger entry is still the
-- first line of defence for a session that later becomes saveable,
-- and the caller may retry the append later (idempotent per TxId).
function DataService.RecordPendingRewardSidecar(player: Player, entry: any): boolean
	if not player or type(entry) ~= "table" or type(entry.InstanceId) ~= "string" then
		return false
	end
	local store = getStore()
	if not store then
		return false
	end
	local ok, err = appendSidecar(store, pendingKeyFor(player.UserId), deepCopy(entry))
	if not ok then
		warn("[DataService] Pending-reward append failed for " .. player.Name .. ": " .. tostring(err))
	end
	return ok
end

-- Daily login bonus, scaled by streak via the shared helper
-- (50 base, +10 per consecutive day, capped at day 7).
-- Streak increments on consecutive-day logins, resets after a missed day.
local function applyDailyBonus(data)
	local now = os.time()
	local last = tonumber(data.LastLogin) or 0
	local newStreak = 1
	if last <= 0 then
		newStreak = 1
	elseif now - last >= DAY_SECONDS then
		if now - last < DAY_SECONDS * 2 then
			newStreak = (tonumber(data.LoginStreak) or 1) + 1
		else
			newStreak = 1
		end
	else
		return false, 0
	end
	local bonus = DAILY_BONUS_COINS
	if _economyMod ~= nil and type(_economyMod.DailyBonusAmount) == "function" then
		local ok, amount = pcall(_economyMod.DailyBonusAmount, newStreak)
		if ok and type(amount) == "number" and amount > 0 then
			bonus = amount
		end
	end
	data.LoginStreak = newStreak
	data.LastLogin = now
	data.Coins = (tonumber(data.Coins) or 0) + bonus
	return true, bonus
end

function DataService.Init()
	if _running then
		return
	end
	_running = true
	getStore()

	-- Autosave loop: save every connected player's cached data.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				if _cache[player] then
					task.spawn(function()
						DataService.SaveData(player)
					end)
				end
			end
		end
	end)

	-- Save on leave — the SINGLE save owner on the leave path.
	-- R2-5 lifecycle ordering (verified against Main.server.luau:
	-- DataService.Init runs BEFORE GameManager.Init, so this handler
	-- is connected FIRST and used to run first): the old handler saved
	-- and cleared the cache before RaidService's later PlayerRemoving
	-- handler could return a stolen Brainrot, so GameManager's later
	-- SaveData found no cache and the pre-return state was what
	-- persisted — a frozen InTransit record with the thief, nothing
	-- with the victim. Now the registered pre-save hooks run FIRST
	-- (RaidService.HandlePlayerLeaving returns in-transit Brainrots),
	-- then the one save, then the cache is cleared. No other handler
	-- saves on leave: GameManager's old onPlayerRemoving save, and
	-- Base / Carry / Conveyor leave handlers, are cleanup-only and
	-- never touch persisted data, so nothing can save a half-cleaned
	-- state after this handler. A hook failure (pcall-guarded) never
	-- blocks the save.
	Players.PlayerRemoving:Connect(function(player)
		runPreSaveHooks(player)
		-- R4-8: a leave save must not be dropped because a slow
		-- autosave is still in flight: wait up to 10 s, then wait
		-- once more (RetryOnce) before giving up. The _saving guard
		-- itself is NOT removed — that would reintroduce the R2
		-- concurrent-save race.
		DataService.SaveData(player, { WaitSeconds = 10, RetryOnce = true })
		DataService.ReleaseSessionLease(player)
		_cache[player] = nil
		_saving[player] = nil
		_loadFailed[player] = nil
		_sidecarMerged[player] = nil
		_sessionContested[player] = nil
		_sessionLost[player] = nil
		_leaseCheckUnverified[player] = nil
		_reserved[player] = nil
		_lease[player] = nil
	end)

	-- Save everything on shutdown. BindToClose only runs on live servers;
	-- guard it so Studio (where it is a no-op) never errors.
	-- R2-5: the shutdown sequence is the same coordinated one as
	-- leave — recovery hooks for every player FIRST (no permanently
	-- frozen in-transit record), then the saves. GameManager's old
	-- second BindToClose (save-only, no recovery) is removed; this is
	-- the only shutdown saver.
	if not RunService:IsStudio() then
		local ok, err = pcall(function()
			game:BindToClose(function()
				-- R5-7: the hook phase runs IN PARALLEL (one spawned
				-- task per player, bounded 10 s wait — see
				-- RunShutdownHooks), not sequentially. The old loop
				-- ran every player's hooks inline, one after another:
				-- ~42 simulated seconds for 6 players under a
				-- degraded store, before the save phase even started,
				-- blowing the ~30 s shutdown budget. Parallel hooks
				-- cost roughly the slowest single player's hooks
				-- instead of the sum; the per-player serialisation
				-- in runPreSaveHooks keeps a hook from running twice
				-- concurrently if a leave fires mid-shutdown.
				local hookResults = DataService.RunShutdownHooks(Players:GetPlayers())
				if hookResults.completed < hookResults.attempted then
					warn(string.format(
						"[DataService] Shutdown hooks incomplete: %d/%d players finished in the hook budget",
						hookResults.completed, hookResults.attempted))
				end
				-- R4-8: shutdown saves run IN PARALLEL (one spawned
				-- task per player, bounded ~25 s wait for all of
				-- them), not sequentially. Sequential saves burn
				-- ~9 s per player under a degraded store (3 retries
				-- x 1 s sleeps + waits) and blow the ~30 s shutdown
				-- budget after ~3 players; parallel saves cost
				-- roughly the slowest single save instead of the
				-- sum. See SaveAllForShutdown.
				local results = DataService.SaveAllForShutdown(Players:GetPlayers())
				if results.completed < results.attempted then
					warn(string.format(
						"[DataService] Shutdown save incomplete: %d/%d players saved in the shutdown budget",
						results.saved, results.attempted))
				end
				for _, player in ipairs(Players:GetPlayers()) do
					DataService.ReleaseSessionLease(player)
				end
			end)
		end)
		if not ok then
			warn("[DataService] BindToClose failed: " .. tostring(err))
		end
	end
end

-- SaveAllForShutdown(players): the shutdown saver. Spawns one
-- task per player (each runs SaveData with shutdown opts) and waits
-- at most ~25 s for all of them, so the total cost is the slowest
-- single save, not the sum. Returns {attempted, completed, saved}.
-- A player whose save never completes in the budget is reported,
-- never silently claimed saved. In-flight saves are waited out
-- (WaitSeconds = 5) rather than dropped; see SaveData.
function DataService.SaveAllForShutdown(players: { Player }?): { [string]: number }
	local list: { Player } = players or Players:GetPlayers()
	_shutdownStats = { attempted = #list, spawned = 0, completed = 0, saved = 0 }
	local done = 0
	local saved = 0
	for _, player in ipairs(list) do
		-- MUTANT (R3): sequential saves, no spawned fan-out.
		(function()
			local ok = false
			pcall(function()
				ok = DataService.SaveData(player, { WaitSeconds = 5, RetryOnce = false }) == true
			end)
			done += 1
			if ok then
				saved += 1
			end
			_shutdownStats.completed = done
			_shutdownStats.saved = saved
		end)()
	end
	local waited = 0
	while done < #list and waited < 25 do
		task.wait(0.2)
		waited += 0.2
	end
	return { attempted = #list, completed = done, saved = saved }
end

-- SaveForShutdown(player): the single-player shutdown save, run
-- synchronously (what each spawned task in SaveAllForShutdown
-- does). Exposed so tests can drive the per-player unit without
-- the spawn fan-out.
function DataService.SaveForShutdown(player: Player): boolean
	return DataService.SaveData(player, { WaitSeconds = 5, RetryOnce = false }) == true
end

-- attemptLoad(player, store): try the main-profile GetAsync
-- LOAD_RETRIES times. Returns (true, data) on a genuine successful
-- read, (false, nil) otherwise. A corrupt (non-table) value counts
-- as a successful read of unusable data: the caller keeps defaults
-- in memory and lets the next save rewrite the key (pre-existing
-- recovery behaviour — the corrupt value itself is unusable).
-- Shared by LoadData and RetryLoad so both attempt the load the
-- same way.
local function attemptLoad(player: Player, store: any): (boolean, any)
	local data: any = nil
	local lastErr: any = nil
	for attempt = 1, LOAD_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(player))
		end)
		if ok then
			data = result
			if type(data) ~= "table" and data ~= nil then
				-- Corrupt value: readable, but not a data table. Keep
				-- defaults in memory and let the next save rewrite the
				-- key (recovery); the corrupt value itself is unusable.
				warn(string.format(
					"[DataService] Corrupt save for %s (type %s, not a table); starting from defaults",
					player.Name, typeof(data)))
				data = nil
			end
			return true, data
		end
		lastErr = result
		if attempt < LOAD_RETRIES then
			task.wait(1)
		end
	end
	warn(string.format(
		"[DataService] Load failed for %s after %d attempts: %s",
		player.Name, LOAD_RETRIES, tostring(lastErr)))
	return false, nil
end

-- finishSuccessfulLoad(player, data, store): the post-read half of
-- a load whose GetAsync genuinely succeeded — session lease, sidecar
-- merge, daily bonus. Shared by LoadData and RetryLoad so a
-- recovered session goes through exactly the same path as a fresh
-- join. Returns true iff the session is healthy and saveable
-- afterwards (false when the lease is contested elsewhere).
local function finishSuccessfulLoad(player: Player, data: any, store: any): boolean
	-- R4-7: claim this player's session lease on a successful load
	-- only. When another live server holds it, this session is
	-- contested: it plays read-only (saves refused, no daily bonus,
	-- no sidecar merge — the owning server's merge is the
	-- authoritative one), and GetSaveWarning explains it to the
	-- player. A failed lease acquire (store error) is also contested
	-- rather than silently overwriting the other server's data.
	local leaseOk = true
	if not _loadFailed[player] and store ~= nil then
		leaseOk = acquireSessionLease(player)
		if not leaseOk then
			_sessionContested[player] = true
			warn(string.format(
				"[DataService] %s is playing read-only: another server holds an active session lease; saves are disabled this session",
				player.Name))
		else
			-- R4-7 (found by the r4-transactions suite): a later
			-- load that acquires the lease — teleport / rejoin
			-- after the previous owner released, or after its
			-- lease expired — clears the contested/lost flags.
			-- The session owns the profile again; without this
			-- the handover stayed read-only forever.
			_sessionContested[player] = nil
			_sessionLost[player] = nil
		end
	end

	-- R2-5: on a successful load only, merge the recovery sidecars
	-- (escrowed returns for this player + pending rewards parked while
	-- a session could not persist). A failed load leaves the sidecars
	-- untouched for the next attempt. The merged entries are deleted
	-- from their sidecar keys only after a later save of the merged
	-- data succeeds (see SaveData). R3-1: each key is flagged for
	-- deletion only if its own read succeeded — a failed sidecar read
	-- leaves that key parked for the next load instead of deleting
	-- unmerged entries.
	-- R4-7: a contested session does not merge either — its cache
	-- never saves, so a merge here could only confuse the owning
	-- server's recovery; the sidecars stay parked for the owner.
	if not _loadFailed[player] and not _sessionContested[player] and store ~= nil then
		local okMerge, merged, escrowDone, pendingDone = pcall(function()
			return mergeSidecars(data, store, player)
		end)
		if okMerge then
			if escrowDone or pendingDone then
				_sidecarMerged[player] = { Escrow = escrowDone == true, Pending = pendingDone == true }
			end
		else
			warn("[DataService] Sidecar merge failed for " .. player.Name .. ": " .. tostring(merged))
		end
	end

	if _sessionContested[player] then
		return false
	end

	local gotBonus, bonus = applyDailyBonus(data)
	if gotBonus then
		print(string.format(
			"[DataService] Daily bonus for %s: +%d coins (streak %d)",
			player.Name, bonus, data.LoginStreak
		))
		-- Persist the bonus immediately so a crash cannot lose it.
		task.spawn(function()
			DataService.SaveData(player)
		end)
	end
	return true
end

function DataService.LoadData(player)
	local store = getStore()
	local data: any = nil
	-- R5-1: a missing store is a FAILED load, never a "nothing to
	-- fail" Studio no-op. GetDataStore failing (outage, or Studio
	-- with API access off) means the real profile was never read;
	-- the old code treated that as a successful load on defaults,
	-- which made the session saveable — and a later SaveData after
	-- the store recovered overwrote the genuine profile with
	-- defaults (Qwen R5-1, reproduced by r5-transactions test 01).
	-- loadOk is true only when a store was obtained AND its GetAsync
	-- genuinely succeeded.
	local loadOk = false
	if store then
		loadOk, data = attemptLoad(player, store)
	end
	-- A failed load NEVER becomes a saveable "fresh" profile: flag
	-- the session so SaveData refuses to overwrite the real save.
	_loadFailed[player] = (not loadOk) or nil
	data = applyDefaults(data)
	_cache[player] = data

	if _loadFailed[player] then
		warn(string.format(
			"[DataService] %s is playing on in-memory defaults (load failed); saves are disabled this session",
			player.Name))
		return data
	end

	finishSuccessfulLoad(player, data, store)
	return data
end

-- RetryLoad(player): R5-1 explicit reload / retry path for a session
-- whose load failed (GetDataStore outage or GetAsync failure).
-- Re-attempts the load from scratch; ONLY a genuine successful load
-- replaces the cache, clears _loadFailed, acquires the session
-- lease, merges sidecars and applies the daily bonus — the same
-- finishSuccessfulLoad a fresh join runs. On ANY failure the
-- existing in-memory cache is left untouched and the session stays
-- unsaveable: a failed retry must never clear the genuine stored
-- profile or silently mint a replacement profile. A healthy session
-- (no failed load) is a no-op returning (true, cached data):
-- re-reading the stored profile would discard in-session progress.
-- A player with no cache at all (never loaded) is not a retry
-- candidate — fresh loads go through LoadData / GetOrLoad.
-- Returns (true, data) iff the session is now healthy and saveable,
-- else (false, reason) where reason is "no_cache" |
-- "datastore_unavailable" | "load_failed" | "session_contested".
-- (The SaveWarning banner is owned by GameManager/HUDController,
-- which fire it on join from GetSaveWarning; a successful RetryLoad
-- clears the reason, but nothing re-fires to clear the banner
-- mid-session — see the R5 report §5 follow-up.)
function DataService.RetryLoad(player: Player): (boolean, any)
	if not _loadFailed[player] then
		local cached = _cache[player]
		if cached then
			return true, cached
		end
		return false, "no_cache"
	end
	local store = getStore()
	if not store then
		warn("[DataService] RetryLoad failed for " .. player.Name .. ": DataStore unavailable")
		return false, "datastore_unavailable"
	end
	local loadOk, data = attemptLoad(player, store)
	if not loadOk then
		return false, "load_failed"
	end
	-- Genuine successful load: ONLY now replace the cache and clear
	-- the failed flag. Anything earned in the failed session's
	-- in-memory defaults is discarded — it was never saveable, and
	-- keeping it would mix unsaved progress into the genuine profile.
	_loadFailed[player] = nil
	data = applyDefaults(data)
	_cache[player] = data
	if not finishSuccessfulLoad(player, data, store) then
		return false, "session_contested"
	end
	return true, data
end

-- SaveData(player, opts?): persist the player's cached data. opts
-- is an optional table: {WaitSeconds (default 5), RetryOnce
-- (default false)}. Returns true iff the write landed.
-- R4-8: a save already in flight does not mean "drop this one": wait
-- for it (up to WaitSeconds), and with RetryOnce wait once more —
-- the leave path passes {WaitSeconds = 10, RetryOnce = true} so a
-- slow autosave overlapping a leave no longer silently drops up to
-- ~60 s of progress. The _saving guard itself is NOT removed: it is
-- what prevents two concurrent SetAsync writes racing each other
-- (the R2 double-save race). A save that is still blocked after the
-- wait(s) returns false and warns — a dropped save is always loud.
function DataService.SaveData(player, opts)
	local data = _cache[player]
	if not data then
		return false
	end
	if _loadFailed[player] then
		-- The store was never read successfully this session: this
		-- cache started from defaults, and writing it would wipe
		-- the player's real save. Refuse; a rejoin re-attempts load.
		warn("[DataService] Save refused for " .. player.Name .. ": load failed this session (real save protected)")
		return false
	end
	if _sessionContested[player] or _sessionLost[player] then
		-- R4-7: another server owns this player's session (or this
		-- server lost it). Saving would overwrite newer data.
		warn("[DataService] Save refused for " .. player.Name .. ": session owned by another server (lease contested/lost)")
		return false
	end
	if not checkSessionLease(player) then
		warn("[DataService] Save refused for " .. player.Name .. ": session lease check failed (another server holds it)")
		return false
	end
	local waitSeconds = 5
	local retryOnce = false
	if type(opts) == "table" then
		if type(opts.WaitSeconds) == "number" and opts.WaitSeconds > 0 then
			waitSeconds = opts.WaitSeconds
		end
		retryOnce = opts.RetryOnce == true
	end
	local function waitForSaving(seconds: number): boolean
		local iterations = math.max(1, math.floor(seconds / 0.2))
		for _ = 1, iterations do
			if not _saving[player] then
				return true
			end
			_saveWaitIterations += 1
			if _testWaitHook ~= nil then
				pcall(_testWaitHook, player)
			end
			task.wait(0.2)
		end
		return not _saving[player]
	end
	if not waitForSaving(waitSeconds) then
		warn("[DataService] Save dropped for " .. player.Name
			.. ": another save stayed in flight for " .. tostring(waitSeconds) .. "s")
		return false
	end
	-- R5-4: revalidate AFTER the wait. The pre-wait check above can
	-- be stale by the time the wait ends: another server may have
	-- taken the lease (expiry / release) and written newer data
	-- while this save was queued behind an in-flight save. Saving
	-- on the pre-wait verdict alone overwrote that newer profile
	-- (r5-transactions test 04 §A reproduces it).
	if not checkSessionLease(player) then
		warn("[DataService] Save refused for " .. player.Name .. ": session lease lost while waiting for an in-flight save")
		return false
	end
	_saving[player] = true
	local store = getStore()
	local ok = true
	if store then
		ok = false
		for attempt = 1, SAVE_RETRIES do
			-- R5-4: revalidate immediately before EVERY SetAsync
			-- attempt, not just before the first. A lease lost
			-- between attempts (attempt 1 failed on the store
			-- while another server took over) must abort the save
			-- before the retry writes over the new owner's data
			-- (r5-transactions test 04 §G reproduces it).
			if not checkSessionLease(player) then
				warn("[DataService] Save refused for " .. player.Name
					.. ": session lease lost before save attempt " .. tostring(attempt))
				_saving[player] = nil
				return false
			end
			local success, err = pcall(function()
				store:SetAsync(keyFor(player), data)
			end)
			if success then
				ok = true
				break
			end
			warn(string.format("[DataService] Save failed for %s (attempt %d/%d): %s",
				player.Name, attempt, SAVE_RETRIES, tostring(err)))
			if attempt < SAVE_RETRIES then
				task.wait(1)
			end
		end
	else
		-- No store (Studio): data stays in the in-memory cache only.
		ok = false
	end
	-- R2-5 / R3-1: the merged data (with sidecar entries) is now
	-- durable, so the sidecar keys can be deleted — best effort, only
	-- on a successful save, and only the keys whose load-time read
	-- SUCCEEDED (a key whose read failed was never merged, so deleting
	-- it would destroy unmerged entries). If a delete fails that key
	-- stays flagged and the next successful save retries; a crash
	-- before the delete simply re-merges the same entries (idempotent
	-- by InstanceId).
	if ok and type(_sidecarMerged[player]) == "table" then
		local flags = _sidecarMerged[player]
		local remaining = false
		if flags.Escrow then
			if deleteSidecar(store, escrowKeyFor(player.UserId)) then
				flags.Escrow = false
			else
				remaining = true
			end
		end
		if flags.Pending then
			if deleteSidecar(store, pendingKeyFor(player.UserId)) then
				flags.Pending = false
			else
				remaining = true
			end
		end
		if not remaining then
			_sidecarMerged[player] = nil
		end
	end
	if ok then
		-- R4-7: a successful save is the heartbeat that keeps this
		-- server's session lease alive past its TTL.
		refreshSessionLease(player)
	end
	_saving[player] = nil
	return ok
end

function DataService.GetData(player)
	return _cache[player]
end

function DataService.GetOrLoad(player)
	if _cache[player] then
		return _cache[player]
	end
	return DataService.LoadData(player)
end

-- R13 (R2-4): IsSaveable(player) — false iff this session's DataStore
-- load failed (_loadFailed), or another server owns this player's
-- session (R4-7 contested / lost), in which case SaveData refuses
-- to persist for the whole session and any coins granted into the
-- in-memory cache would vanish on leave. RaidService checks this
-- before paying a steal reward and records the reward pending
-- instead of minting phantom coins. True when the session loaded
-- normally or has no cache yet (the load is attempted by GetOrLoad).
function DataService.IsSaveable(player)
	return _loadFailed[player] ~= true
		and _sessionContested[player] ~= true
		and _sessionLost[player] ~= true
end

-- R4-3: the coin reservation floor. A debit (negative amount) may
-- spend only the SPENDABLE balance — the balance above the reserved
-- total. It clamps at the reserved total, never at zero, so a
-- reserved reward credit cannot be spent out from under a pending
-- commit's rollback: after a rollback releases the reservation, the
-- exact subtraction lands on a balance that provably still holds
-- those coins. Credits are unaffected. Callers that need a clean
-- affordability answer use GetSpendableCoins; the floor here is the
-- backstop for any route that only calls AddCoins.
function DataService.AddCoins(player, amount)
	local data = DataService.GetOrLoad(player)
	amount = tonumber(amount) or 0
	local balance = tonumber(data.Coins) or 0
	if amount < 0 then
		local floor = DataService.GetReservedCoins(player)
		data.Coins = math.max(floor, balance + amount)
	else
		data.Coins = math.max(0, balance + amount)
	end
	return data.Coins
end

function DataService.AddXP(player, amount)
	local data = DataService.GetOrLoad(player)
	data.XP = (tonumber(data.XP) or 0) + (tonumber(amount) or 0)
	return data.XP
end

function DataService.SetLevel(player, level)
	local data = DataService.GetOrLoad(player)
	data.Level = math.max(1, tonumber(level) or 1)
	return data.Level
end

function DataService.AddWin(player)
	local data = DataService.GetOrLoad(player)
	data.Wins = (tonumber(data.Wins) or 0) + 1
	return data.Wins
end

function DataService.AddKO(player)
	local data = DataService.GetOrLoad(player)
	data.KOs = (tonumber(data.KOs) or 0) + 1
	return data.KOs
end

function DataService.HasCharacter(player, characterId)
	local data = DataService.GetOrLoad(player)
	for _, id in ipairs(data.Unlocked) do
		if id == characterId then
			return true
		end
	end
	return false
end

function DataService.UnlockCharacter(player, characterId)
	local data = DataService.GetOrLoad(player)
	if DataService.HasCharacter(player, characterId) then
		return false
	end
	table.insert(data.Unlocked, characterId)
	return true
end

function DataService.SetSelected(player, characterId)
	local data = DataService.GetOrLoad(player)
	if not DataService.HasCharacter(player, characterId) then
		return false
	end
	data.Selected = characterId
	return true
end

function DataService.GetSelected(player)
	local data = DataService.GetOrLoad(player)
	return data.Selected
end

return DataService
