-- DataService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse — player persistence.
-- DataStoreService with pcall everywhere; safe in-memory defaults when
-- Studio has API access disabled or a DataStore call fails.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

-- Shared daily-bonus math (50 + 10 per streak day, capped day 7).
-- pcall-guarded: DataService must keep working if Economy is absent.
local _economyMod: any = nil
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Economy"))
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

	-- Save on leave.
	Players.PlayerRemoving:Connect(function(player)
		DataService.SaveData(player)
		_cache[player] = nil
		_saving[player] = nil
		_loadFailed[player] = nil
	end)

	-- Save everything on shutdown. BindToClose only runs on live servers;
	-- guard it so Studio (where it is a no-op) never errors.
	if not RunService:IsStudio() then
		local ok, err = pcall(function()
			game:BindToClose(function()
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
