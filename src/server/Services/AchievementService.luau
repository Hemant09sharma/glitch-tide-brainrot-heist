--!strict
-- AchievementService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse (v1.1, Workstream C).
-- Achievement milestones + collection-completion rewards + player
-- titles. All milestone tables live in shared/AchievementDefs.luau.
--
-- HOW IT WORKS: other services call CheckProgress(player, kind,
-- amount) when something countable happens (a tide survived, a boss
-- defeated, a fusion done, ...). QuestService.ReportProgress also
-- forwards matching kinds here. Progress is cumulative per
-- achievement; on reaching Goal the achievement unlocks EXACTLY ONCE
-- and its reward is paid server-side (coins via DataService.AddCoins,
-- gems / crystals / shards / tokens via direct field writes — the same
-- stack every other service uses, audit §4f — XP via
-- ProgressionService.AddXP when linked, else DataService.AddXP).
-- Titles granted on unlock go into data.Titles; the equipped title is
-- stored in data.EquippedTitle (title equip UI is Wave 3 client work;
-- SetEquippedTitle is the server-side store for it).
--
-- REMOTES (fired by STRING name; Remotes.luau is frozen for this
-- workstream — see docs/REMOTES_NEEDED_C.md):
--   RequestAchievements (RemoteFunction): returns GetAchievements.
--   AchievementUnlocked (RemoteEvent broadcast): unlock payload.
-- Existing broadcasts reused: SpawnEffect (positional), EventUpdate.
-- Secrets are NEVER listed here: GetAchievements returns achievements
-- only; secret discovery lives in SecretService.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AchievementDefs = require(ReplicatedStorage:WaitForChild("AchievementDefs"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local AchievementService = {}

local _dataService: any = nil
local _progressionService: any = nil
local _questService: any = nil

local _rate: { [Player]: number } = {}

local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function rateOk(player: Player, key: string, interval: number): boolean
	if Security and Security.RateLimit then
		local ok, allowed = pcall(function()
			return Security.RateLimit(player, key, interval)
		end)
		if ok then
			return allowed
		end
	end
	local now = os.clock()
	local last = _rate[player] or -math.huge
	if now - last < interval then
		return false
	end
	_rate[player] = now
	return true
end

local function getRemote(name: string): RemoteEvent?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

local function getFunction(name: string): RemoteFunction?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetFunction(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteFunction") then
		return remote :: RemoteFunction
	end
	return nil
end

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function getData(player: Player): any
	if not _dataService then
		return nil
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

local function ensureAchievements(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.Achievements) ~= "table" then
		data.Achievements = {}
	end
	if type(data.Titles) ~= "table" then
		data.Titles = {}
	end
	if type(data.EquippedTitle) ~= "string" then
		data.EquippedTitle = ""
	end
	for _, def in ipairs(AchievementDefs.GetAll()) do
		if type(data.Achievements[def.Id]) ~= "table" then
			data.Achievements[def.Id] = { Progress = 0, Unlocked = false }
		end
	end
	return data
end

local function grantXP(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	if _progressionService and type(_progressionService.AddXP) == "function" then
		pcall(function()
			_progressionService.AddXP(player, amount)
		end)
	else
		pcall(function()
			_dataService.AddXP(player, amount)
		end)
	end
end

local function grantTitle(data: any, titleId: string): boolean
	if type(titleId) ~= "string" or titleId == "" then
		return false
	end
	if AchievementDefs.GetTitle(titleId) == nil then
		return false
	end
	for _, owned in ipairs(data.Titles) do
		if owned == titleId then
			return false
		end
	end
	table.insert(data.Titles, titleId)
	return true
end

-- unlockAchievement(player, data, def, state): pay the reward exactly
-- once and broadcast. Shared by CheckProgress (incremental) and
-- SetProgress (absolute).
local function unlockAchievement(player: Player, data: any, def: any, state: any)
	state.Unlocked = true
	local reward = def.Reward
	pcall(function()
		_dataService.AddCoins(player, reward.Coins)
	end)
	data.Gems = (tonumber(data.Gems) or 0) + reward.Gems
	data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + reward.Crystals
	data.ChaosShards = (tonumber(data.ChaosShards) or 0) + reward.Shards
	data.EventTokens = (tonumber(data.EventTokens) or 0) + reward.Tokens
	grantXP(player, reward.XP)
	if def.Title then
		grantTitle(data, def.Title)
	end
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient("AchievementUnlocked", player, {
		Action = "AchievementUnlocked",
		Id = def.Id,
		Name = def.Name,
		Reward = reward,
		Title = def.Title,
	})
	fireAll("EventUpdate", {
		EventId = "AchievementUnlocked",
		Name = player.Name .. " unlocked: " .. def.Name .. "!",
		Phase = "Started",
		Duration = 6,
	})
	print(string.format(
		"[AchievementService] %s unlocked %s (%s)",
		player.Name, def.Id, def.Name
	))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- GetAchievements(player): every achievement with live Progress /
-- Unlocked flags, plus the player's owned titles and equipped title.
function AchievementService.GetAchievements(player: Player): { any }
	local data = ensureAchievements(player)
	if not data then
		return {}
	end
	local out: { any } = {}
	for _, def in ipairs(AchievementDefs.GetAll()) do
		local state = data.Achievements[def.Id]
		table.insert(out, {
			Id = def.Id,
			Name = def.Name,
			Description = def.Description,
			Kind = def.Kind,
			Goal = def.Goal,
			Progress = math.min(tonumber(state.Progress) or 0, def.Goal),
			Unlocked = state.Unlocked == true,
			Reward = def.Reward,
			Title = def.Title,
		})
	end
	return {
		Achievements = out,
		Titles = data.Titles,
		EquippedTitle = data.EquippedTitle,
	}
end

-- CheckProgress(player, kind, amount): advance every achievement
-- listening to `kind` by `amount` (cumulative). Unlocks pay their
-- reward exactly once. Returns the list of newly unlocked ids.
-- Safe to call for kinds no achievement listens to (no-op).
function AchievementService.CheckProgress(player: Player, kind: any, amount: any): { string }
	local unlocked: { string } = {}
	if not player or not player:IsA("Player") then
		return unlocked
	end
	if type(kind) ~= "string" or kind == "" then
		return unlocked
	end
	local data = ensureAchievements(player)
	if not data then
		return unlocked
	end
	local delta = math.max(0, math.floor(tonumber(amount) or 1))
	if delta == 0 then
		return unlocked
	end
	for _, def in ipairs(AchievementDefs.GetAll()) do
		if def.Kind == kind then
			local state = data.Achievements[def.Id]
			if state.Unlocked ~= true then
				local before = tonumber(state.Progress) or 0
				local after = math.min(def.Goal, before + delta)
				state.Progress = after
				if after >= def.Goal then
					table.insert(unlocked, def.Id)
					unlockAchievement(player, data, def, state)
				end
			end
		end
	end
	return unlocked
end

-- SetProgress(player, kind, value): set ABSOLUTE progress for every
-- achievement listening to `kind` — for values that are totals, not
-- increments ("level", "collection"). Progress only ever moves up
-- (a rebirth resetting level to 1 never un-earns progress). Returns
-- the list of newly unlocked ids.
function AchievementService.SetProgress(player: Player, kind: any, value: any): { string }
	local unlocked: { string } = {}
	if not player or not player:IsA("Player") then
		return unlocked
	end
	if type(kind) ~= "string" or kind == "" then
		return unlocked
	end
	local data = ensureAchievements(player)
	if not data then
		return unlocked
	end
	local absolute = math.max(0, math.floor(tonumber(value) or 0))
	for _, def in ipairs(AchievementDefs.GetAll()) do
		if def.Kind == kind then
			local state = data.Achievements[def.Id]
			if state.Unlocked ~= true then
				local before = tonumber(state.Progress) or 0
				local after = math.min(def.Goal, math.max(before, absolute))
				state.Progress = after
				if after >= def.Goal then
					table.insert(unlocked, def.Id)
					unlockAchievement(player, data, def, state)
				end
			end
		end
	end
	return unlocked
end

-- IsUnlocked(player, achievementId): true when the achievement is unlocked.
function AchievementService.IsUnlocked(player: Player, achievementId: string): boolean
	local data = ensureAchievements(player)
	if not data then
		return false
	end
	local state = data.Achievements[achievementId]
	return type(state) == "table" and state.Unlocked == true
end

-- GetTitles(player): owned title ids.
function AchievementService.GetTitles(player: Player): { string }
	local data = ensureAchievements(player)
	if not data then
		return {}
	end
	local copy: { string } = {}
	for _, titleId in ipairs(data.Titles) do
		table.insert(copy, titleId)
	end
	return copy
end

-- SetEquippedTitle(player, titleId): store the equipped title
-- server-side (the equip UI is Wave 3 client work). Returns
-- (true) or (false, reason). The title must be owned.
function AchievementService.SetEquippedTitle(player: Player, titleId: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	if type(titleId) ~= "string" or titleId == "" then
		return false, "invalid title"
	end
	local data = ensureAchievements(player)
	if not data then
		return false, "no data"
	end
	local owned = false
	for _, ownedId in ipairs(data.Titles) do
		if ownedId == titleId then
			owned = true
			break
		end
	end
	if not owned then
		return false, "title not owned"
	end
	data.EquippedTitle = titleId
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	return true, nil
end

-- ---------------------------------------------------------------------------
-- Setters (called by GameManager wireCrossLinks when the setter name is
-- in its shared table, or by the integrator's loadOptional branch).
-- ---------------------------------------------------------------------------

function AchievementService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function AchievementService.SetQuestService(questService: any)
	if questService and type(questService.ReportProgress) == "function" then
		_questService = questService
	end
end

function AchievementService.Init(dataService: any?, questService: any?)
	assert(dataService ~= nil, "[AchievementService] Init requires DataService")
	_dataService = dataService
	if questService and type(questService.SetAchievementService) == "function" then
		-- Let QuestService forward ReportProgress kinds to us.
		pcall(function()
			questService.SetAchievementService(AchievementService)
		end)
		_questService = questService
	end
	-- Self-wire to ProgressionService (AddXP / Rebirth / Prestige /
	-- RecordDiscovery report absolute achievement progress). The
	-- sibling require returns the same module table GameManager
	-- loads, so no GameManager edit is needed.
	pcall(function()
		local mod = script.Parent:FindFirstChild("ProgressionService")
		if mod then
			local candidate = require(mod)
			if type(candidate.SetAchievementService) == "function" then
				candidate.SetAchievementService(AchievementService)
				_progressionService = candidate
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	-- RequestAchievements (RemoteFunction): the client's pull path.
	local fnName = "RequestAchievements"
	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction(fnName)
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(player: Player)
				return AchievementService.GetAchievements(player)
			end
		else
			warn("[AchievementService] RemoteFunction not found, RequestAchievements not wired: " .. fnName)
		end
	end)

	-- EquipTitle (RemoteEvent): the client's equip path (integration
	-- fix — Wave 3 left this unwired). The client fires {TitleId = id};
	-- accept a bare string too. Ownership is validated server-side by
	-- SetEquippedTitle; unowned/invalid titles are rejected there.
	local equipName = "EquipTitle"
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(equipName)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(function(player: Player, payload: any)
				local titleId: any = payload
				if type(payload) == "table" then
					titleId = payload.TitleId
				end
				local ok, err = pcall(function()
					return AchievementService.SetEquippedTitle(player, titleId)
				end)
				if not ok then
					warn("[AchievementService] EquipTitle failed for " .. player.Name .. ": " .. tostring(err))
				end
			end)
		else
			warn("[AchievementService] Remote not found, EquipTitle handler not wired: " .. equipName)
		end
	end)
end

return AchievementService
