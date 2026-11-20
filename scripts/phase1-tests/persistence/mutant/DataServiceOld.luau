-- DataService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse — player persistence.
-- DataStoreService with pcall everywhere; safe in-memory defaults when
-- Studio has API access disabled or a DataStore call fails.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
-- [Player] = true when a sidecar (escrow / pending reward) was merged
-- into this session's cache at load and still needs deleting: the
-- sidecar keys are removed only after a later SaveData succeeds, so a
-- crash between merge and save re-merges the same entries (the merge
-- is idempotent) instead of losing them.
local _sidecarMerged = {}

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

local function runPreSaveHooks(player: Player)
	for _, fn in ipairs(_preSaveHooks) do
		pcall(fn, player)
	end
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
-- merge dedupes by InstanceId, so nothing is paid or restored twice.
local function escrowKeyFor(userId: number): string
	return "Brainrot_Escrow_" .. tostring(userId)
end

local function pendingKeyFor(userId: number): string
	return "Brainrot_Pending_" .. tostring(userId)
end

local function readSidecar(store: any, key: string): { any }?
	for _ = 1, 2 do
		local ok, value = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			if type(value) == "table" then
				return value
			end
			return nil
		end
		task.wait(0.5)
	end
	return nil
end

local function writeSidecar(store: any, key: string, value: { any }): boolean
	for _ = 1, 2 do
		local ok = pcall(function()
			store:SetAsync(key, value)
		end)
		if ok then
			return true
		end
		task.wait(0.5)
	end
	return false
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
-- escrows a return for an offline victim).
local function mergeEscrowRecord(data: any, record: any): boolean
	if type(record) ~= "table" or type(record.InstanceId) ~= "string" then
		return false
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

-- Read both sidecar keys for `player` and merge them into the loaded
-- cache. Escrow entries restore returned Brainrots; pending entries
-- accumulate onto data.PendingRewards (a sidecar entry is written only
-- when the main key cannot persist, so an in-cache entry for the same
-- InstanceId can only be an older, separate reward — accumulating is
-- correct and a re-merge after a crash adds nothing new because the
-- sidecar is deleted once a save of the merged data succeeds).
-- Returns true iff anything was merged. Only called on a successful
-- load: a failed load must leave the sidecars untouched for the next
-- attempt.
local function mergeSidecars(data: any, store: any, player: Player): boolean
	local merged = false
	local escrow = readSidecar(store, escrowKeyFor(player.UserId))
	if type(escrow) == "table" then
		for _, record in ipairs(escrow) do
			if mergeEscrowRecord(data, record) then
				merged = true
			end
		end
	end
	local pending = readSidecar(store, pendingKeyFor(player.UserId))
	if type(pending) == "table" then
		if type(data.PendingRewards) ~= "table" then
			data.PendingRewards = {}
		end
		for _, entry in ipairs(pending) do
			if type(entry) == "table" and type(entry.InstanceId) == "string" then
				local amount = math.floor(tonumber(entry.Amount) or 0)
				if amount > 0 then
					local existing = data.PendingRewards[entry.InstanceId]
					if type(existing) == "table" then
						existing.Amount = (tonumber(existing.Amount) or 0) + amount
					else
						data.PendingRewards[entry.InstanceId] = {
							InstanceId = entry.InstanceId,
							CharacterId = entry.CharacterId,
							Amount = amount,
							Reason = entry.Reason,
							CreatedAt = entry.CreatedAt,
						}
					end
					merged = true
				end
			end
		end
	end
	return merged
end

-- EscrowReturnedInstance(victimUserId, record): durably park a Brainrot
-- being returned to an OFFLINE victim (RaidService calls this when the
-- victim left mid-theft). The victim's next successful load merges it
-- back into OwnedInstances (+ its placed copy). Idempotent per
-- InstanceId: an already-escrowed instance is not written twice.
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
	local key = escrowKeyFor(userId)
	local list = readSidecar(store, key) or {}
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.InstanceId == record.InstanceId then
			return true
		end
	end
	table.insert(list, deepCopy(record))
	return writeSidecar(store, key, list)
end

-- RecordPendingRewardSidecar(player, entry): durably park a steal
-- reward that cannot be persisted in the main key because this
-- session cannot save (load failed). RaidService calls this only in
-- that case; the entry is merged into data.PendingRewards on the next
-- successful load. Returns false with no store or when the write
-- fails — the in-cache ledger entry is still the first line of
-- defence for a session that later becomes saveable.
function DataService.RecordPendingRewardSidecar(player: Player, entry: any): boolean
	if not player or type(entry) ~= "table" or type(entry.InstanceId) ~= "string" then
		return false
	end
	local store = getStore()
	if not store then
		return false
	end
	local key = pendingKeyFor(player.UserId)
	local list = readSidecar(store, key) or {}
	for _, existing in ipairs(list) do
		if type(existing) == "table" and existing.InstanceId == entry.InstanceId then
			existing.Amount = (tonumber(existing.Amount) or 0) + (tonumber(entry.Amount) or 0)
			return writeSidecar(store, key, list)
		end
	end
	table.insert(list, deepCopy(entry))
	return writeSidecar(store, key, list)
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
		DataService.SaveData(player)
		_cache[player] = nil
		_saving[player] = nil
		_loadFailed[player] = nil
		_sidecarMerged[player] = nil
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
				for _, player in ipairs(Players:GetPlayers()) do
					runPreSaveHooks(player)
				end
				for _, player in ipairs(Players:GetPlayers()) do
					-- Let an in-flight save finish first instead of
					-- dropping this shutdown save on the _saving guard.
					for _ = 1, 10 do
						if not _saving[player] then
							break
						end
						task.wait(0.2)
					end
					DataService.SaveData(player)
				end
				-- Give in-flight saves a moment to finish.
				task.wait(2)
			end)
		end)
		if not ok then
			warn("[DataService] BindToClose failed: " .. tostring(err))
		end
	end
end

function DataService.LoadData(player)
	local store = getStore()
	local data: any = nil
	local loadOk = store == nil -- no store (Studio): nothing to fail
	if store then
		loadOk = false
		local lastErr: any = nil
		for attempt = 1, LOAD_RETRIES do
			local ok, result = pcall(function()
				return store:GetAsync(keyFor(player))
			end)
			if ok then
				loadOk = true
				data = result
				break
			end
			lastErr = result
			if attempt < LOAD_RETRIES then
				task.wait(1)
			end
		end
		if not loadOk then
			warn(string.format(
				"[DataService] Load failed for %s after %d attempts: %s",
				player.Name, LOAD_RETRIES, tostring(lastErr)))
		elseif type(data) ~= "table" and data ~= nil then
			-- Corrupt value: readable, but not a data table. Keep
			-- defaults in memory and let the next save rewrite the
			-- key (recovery); the corrupt value itself is unusable.
			warn(string.format(
				"[DataService] Corrupt save for %s (type %s, not a table); starting from defaults",
				player.Name, typeof(data)))
			data = nil
		end
	end
	-- A failed load NEVER becomes a saveable "fresh" profile: flag
	-- the session so SaveData refuses to overwrite the real save.
	_loadFailed[player] = (store ~= nil and not loadOk) or nil
	data = applyDefaults(data)
	_cache[player] = data

	-- R2-5: on a successful load only, merge the recovery sidecars
	-- (escrowed returns for this player + pending rewards parked while
	-- a session could not persist). A failed load leaves the sidecars
	-- untouched for the next attempt. The merged entries are deleted
	-- from their sidecar keys only after a later save of the merged
	-- data succeeds (see SaveData).
	if not _loadFailed[player] and store ~= nil then
		local okMerge, merged = pcall(function()
			return mergeSidecars(data, store, player)
		end)
		if okMerge and merged then
			_sidecarMerged[player] = true
		elseif not okMerge then
			warn("[DataService] Sidecar merge failed for " .. player.Name .. ": " .. tostring(merged))
		end
	end

	if _loadFailed[player] then
		warn(string.format(
			"[DataService] %s is playing on in-memory defaults (load failed); saves are disabled this session",
			player.Name))
		return data
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
	return data
end

function DataService.SaveData(player)
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
	-- A save already in flight does not mean "drop this one": wait
	-- for it briefly instead of losing the write (matters on leave,
	-- where there is no later autosave to pick it up).
	for _ = 1, 25 do
		if not _saving[player] then
			break
		end
		task.wait(0.2)
	end
	if _saving[player] then
		return false
	end
	_saving[player] = true
	local store = getStore()
	local ok = true
	if store then
		ok = false
		for attempt = 1, SAVE_RETRIES do
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
	-- R2-5: the merged data (with sidecar entries) is now durable, so
	-- the sidecar keys can be deleted — best effort, only on a
	-- successful save. If a delete fails the flag stays set and the
	-- next successful save retries; a crash before the delete simply
	-- re-merges the same entries (idempotent by InstanceId).
	if ok and _sidecarMerged[player] then
		local delOk = pcall(function()
			deleteSidecar(store, escrowKeyFor(player.UserId))
			deleteSidecar(store, pendingKeyFor(player.UserId))
		end)
		if delOk then
			_sidecarMerged[player] = nil
		end
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
-- load failed (_loadFailed), in which case SaveData refuses to persist
-- for the whole session and any coins granted into the in-memory cache
-- would vanish on leave. RaidService checks this before paying a steal
-- reward and records the reward pending instead of minting phantom
-- coins. True when the session loaded normally or has no cache yet
-- (the load is attempted by GetOrLoad).
function DataService.IsSaveable(player)
	return _loadFailed[player] ~= true
end

function DataService.AddCoins(player, amount)
	local data = DataService.GetOrLoad(player)
	amount = tonumber(amount) or 0
	data.Coins = math.max(0, (tonumber(data.Coins) or 0) + amount)
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
