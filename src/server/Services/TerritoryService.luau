--!strict
-- TerritoryService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse (v1.1, Workstream C).
-- Capturable territories, Part 6C: seven locations (the five hub
-- zones plus the two Wave 1 dimensions). Holding a territory pays a
-- real bonus; taking one requires a channel.
--
-- RULES (server-authoritative): capture is a 10s channel — the
-- channeler must stay alive and inside the territory radius; leaving
-- the radius, dying or leaving the game breaks the channel. If a
-- second player (or the current holder) is inside the radius while
-- someone channels, the territory is CONTESTED and channel progress
-- freezes until only one contender remains. Per-player cooldown: 60s
-- after any capture attempt (success or fail). No captures while a
-- Glitch Tide is Active. A capture breaks the moment its holder
-- leaves the game or dies — the territory goes neutral. Holders keep
-- a territory without standing in it; only another player's completed
-- channel (or the holder's death / departure) takes it away.
--
-- BONUSES: while held, the territory pays CoinsPerSec straight into
-- the holder's Coins (DataService.AddCoins — NOT BankedIncome, so the
-- bonus never hits the bank cap and is never lost) and XPPerMinute
-- (via ProgressionService.AddXP when linked, else DataService.AddXP).
-- A flat per-second tick is used deliberately: the multiplier form
-- would need a GetIncomePerSec edit in BaseService, which is outside
-- this workstream's two-integration scope (see docs/QA_V11_C.md).
-- Territory state is in-memory (holders change hands constantly);
-- nothing about a holder is persisted.
--
-- REMOTES (fired by STRING name; Remotes.luau is frozen for this
-- workstream — see docs/REMOTES_NEEDED_C.md):
--   RequestTerritories (RemoteFunction): returns GetTerritories.
--   CaptureTerritory (RemoteEvent): {TerritoryId}.
--   TerritoryUpdate (RemoteEvent broadcast): state push on
--     channel start / progress / break / capture / release.
-- Existing broadcasts reused: EventUpdate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local TerritoryService = {}

local _dataService: any = nil
local _tideService: any = nil
local _progressionService: any = nil
local _questService: any = nil
local _achievementService: any = nil

local CAPTURE_CHANNEL_SECONDS = 10
local CAPTURE_COOLDOWN_SECONDS = 60

export type TerritoryDef = {
	Id: string,
	Name: string,
	Position: Vector3,
	Radius: number,
	Tier: number,
	CoinsPerSec: number,
	XPPerMinute: number,
}

local TERRITORIES: { TerritoryDef } = {
	{ Id = "plaza", Name = "Memeverse Plaza", Position = Vector3.new(0, 3, 0), Radius = 14, Tier = 1, CoinsPerSec = 5, XPPerMinute = 10 },
	{ Id = "market", Name = "Rift Market", Position = Vector3.new(0, 3, -60), Radius = 12, Tier = 1, CoinsPerSec = 5, XPPerMinute = 10 },
	{ Id = "lab", Name = "Mutation Lab", Position = Vector3.new(-75, 3, 55), Radius = 12, Tier = 2, CoinsPerSec = 10, XPPerMinute = 20 },
	{ Id = "arena", Name = "Chaos Arena", Position = Vector3.new(75, 3, 55), Radius = 14, Tier = 2, CoinsPerSec = 10, XPPerMinute = 20 },
	{ Id = "rift", Name = "Forbidden Rift", Position = Vector3.new(-150, 3, -150), Radius = 12, Tier = 3, CoinsPerSec = 15, XPPerMinute = 30 },
	{ Id = "abyssal", Name = "Abyssal Kingdom", Position = Vector3.new(-150, 3, 136), Radius = 12, Tier = 3, CoinsPerSec = 15, XPPerMinute = 30 },
	{ Id = "skyfall", Name = "Skyfall Kingdom", Position = Vector3.new(150, 48, -140), Radius = 12, Tier = 3, CoinsPerSec = 15, XPPerMinute = 30 },
}

local _byId: { [string]: TerritoryDef } = {}
for _, def in ipairs(TERRITORIES) do
	_byId[def.Id] = def
end

local _holders: { [string]: Player } = {} -- territoryId -> holder
local _channels: { [Player]: { TerritoryId: string, Progress: number } } = {}
local _lastAttempt: { [Player]: number } = {}
local _xpAccrued: { [Player]: number } = {} -- seconds of holding, per player
local _running = false

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

local function sanitize(id: any): string?
	if Security and Security.SanitizeId then
		local ok, clean = pcall(function()
			return Security.SanitizeId(id)
		end)
		if ok then
			return clean
		end
	end
	if type(id) ~= "string" or #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
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

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function isInRadius(player: Player, def: TerritoryDef): boolean
	local root = getRoot(player)
	if not root then
		return false
	end
	return (root.Position - def.Position).Magnitude <= def.Radius
end

local function isTideActive(): boolean
	if _tideService and type(_tideService.IsTideActive) == "function" then
		local ok, active = pcall(function()
			return _tideService.IsTideActive()
		end)
		if ok then
			return active == true
		end
	end
	return false
end

-- resolveQuestService: lazy sibling require. GameManager cannot be
-- edited by this workstream, so territories wire their own progress
-- funnel (see LaboratoryService for the pattern). Declared BEFORE
-- reportProgress: a local used before its declaration would resolve
-- to a global (nil) at runtime.
local function resolveQuestService(): any
	if _questService and type(_questService.ReportProgress) == "function" then
		return _questService
	end
	_questService = nil
	pcall(function()
		local mod = script.Parent:FindFirstChild("QuestService")
		if mod then
			local candidate = require(mod)
			if type(candidate.ReportProgress) == "function" then
				_questService = candidate
			end
		end
	end)
	return _questService
end

local function reportProgress(player: Player, kind: string, id: string, amount: number)
	-- ReportProgress is the funnel: it advances quests AND forwards
	-- to achievements / challenges exactly once (QuestService
	-- EVENT_KIND_MAP). Do NOT also call CheckProgress here — that
	-- would double-count.
	local qs = _questService or resolveQuestService()
	if qs and type(qs.ReportProgress) == "function" then
		pcall(function()
			qs.ReportProgress(player, kind, id, amount)
		end)
	end
end

local function broadcastTerritories(extra: { [string]: any }?)
	local payload: { [string]: any } = {
		Action = "TerritoryUpdate",
		Territories = TerritoryService.GetTerritories(),
	}
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	fireAll("TerritoryUpdate", payload)
end

-- releaseTerritory(territoryId, reason): holder loses the territory
-- (death / leave / captured by someone else). Never errors.
local function releaseTerritory(territoryId: string, reason: string)
	local holder = _holders[territoryId]
	if holder == nil then
		return
	end
	_holders[territoryId] = nil
	_xpAccrued[holder] = nil
	print(string.format(
		"[TerritoryService] %s lost by %s (%s)",
		territoryId, holder.Name, reason
	))
	broadcastTerritories({ Action = "TerritoryReleased", TerritoryId = territoryId, Reason = reason })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- GetTerritories(): every territory with holder, channel and contest state.
function TerritoryService.GetTerritories(): { { [string]: any } }
	local out: { { [string]: any } } = {}
	for _, def in ipairs(TERRITORIES) do
		local holder = _holders[def.Id]
		local channeler: Player? = nil
		local progress = 0
		for player, channel in pairs(_channels) do
			if channel.TerritoryId == def.Id then
				channeler = player
				progress = channel.Progress
				break
			end
		end
		-- Contested: someone channels while anyone else (holder or
		-- another player) stands in the radius.
		local contested = false
		if channeler ~= nil then
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= channeler and isAlive(player) and isInRadius(player, def) then
					contested = true
					break
				end
			end
		end
		-- Annotated as {[string]: any}: strict-mode table inference
		-- rejects a sealed literal inserted into the {[string]: any}
		-- list.
		local entry: { [string]: any } = {
			Id = def.Id,
			Name = def.Name,
			Position = { X = def.Position.X, Y = def.Position.Y, Z = def.Position.Z },
			Radius = def.Radius,
			Tier = def.Tier,
			CoinsPerSec = def.CoinsPerSec,
			XPPerMinute = def.XPPerMinute,
			Holder = holder and holder.Name or nil,
			HolderUserId = holder and holder.UserId or nil,
			Channeler = channeler and channeler.Name or nil,
			ChannelProgress = progress,
			ChannelSeconds = CAPTURE_CHANNEL_SECONDS,
			Contested = contested,
		}
		table.insert(out, entry)
	end
	return out
end

-- GetHeldTerritories(player): ids of the territories this player holds.
function TerritoryService.GetHeldTerritories(player: Player): { string }
	local held: { string } = {}
	for id, holder in pairs(_holders) do
		if holder == player then
			table.insert(held, id)
		end
	end
	return held
end

-- CaptureTerritory(player, territoryId): start a capture channel.
-- Returns (true, "channel started") or (false, reason). The channel
-- itself resolves in the 1s tick loop.
function TerritoryService.CaptureTerritory(player: Player, territoryId: any): (boolean, string)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(territoryId)
	if not clean then
		return false, "invalid territory id"
	end
	local def = _byId[clean]
	if not def then
		return false, "unknown territory"
	end
	if isTideActive() then
		return false, "cannot capture during an Active tide"
	end
	local now = os.clock()
	local last = _lastAttempt[player] or -math.huge
	if now - last < CAPTURE_COOLDOWN_SECONDS then
		return false, "capture on cooldown (" .. tostring(math.ceil(CAPTURE_COOLDOWN_SECONDS - (now - last))) .. "s)"
	end
	if _holders[clean] == player then
		return false, "you already hold this territory"
	end
	if _channels[player] ~= nil then
		return false, "already channeling a capture"
	end
	if not isAlive(player) then
		return false, "you must be alive to capture"
	end
	if not isInRadius(player, def) then
		return false, "stand inside the territory to capture it"
	end
	_lastAttempt[player] = now
	_channels[player] = { TerritoryId = clean, Progress = 0 }
	broadcastTerritories({ Action = "ChannelStarted", TerritoryId = clean, Player = player.Name })
	print(string.format("[TerritoryService] %s started capturing %s", player.Name, clean))
	return true, "channel started"
end

-- ---------------------------------------------------------------------------
-- Setters
-- ---------------------------------------------------------------------------

function TerritoryService.SetTideService(tideService: any)
	if tideService and type(tideService.IsTideActive) == "function" then
		_tideService = tideService
	end
end

function TerritoryService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function TerritoryService.SetQuestService(questService: any)
	if questService and type(questService.ReportProgress) == "function" then
		_questService = questService
	end
end

function TerritoryService.SetAchievementService(achievementService: any)
	if achievementService and type(achievementService.CheckProgress) == "function" then
		_achievementService = achievementService
	end
end

local function onCaptureRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	if not rateOk(player, "CaptureTerritory", 1) then
		return
	end
	local ok, err = TerritoryService.CaptureTerritory(player, payload.TerritoryId)
	if not ok then
		warn("[TerritoryService] Capture failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function TerritoryService.Init(dataService: any?, map: any?)
	assert(dataService ~= nil, "[TerritoryService] Init requires DataService")
	_dataService = dataService
	resolveQuestService()
	-- `map` is accepted for signature parity with the other world
	-- services; territory positions are fixed constants in this file
	-- (they match MapBuilder / Dimensions.luau coordinates), so the
	-- map is not needed at runtime.

	if _running then
		return
	end
	_running = true

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
		_channels[player] = nil
		_lastAttempt[player] = nil
		_xpAccrued[player] = nil
		for id, holder in pairs(_holders) do
			if holder == player then
				releaseTerritory(id, "holder left")
			end
		end
	end)

	-- 1s tick: advance channels, pay holder bonuses, watch for death.
	task.spawn(function()
		while true do
			task.wait(1)
			-- Channels.
			for player, channel in pairs(_channels) do
				local def = _byId[channel.TerritoryId]
				local broken: string? = nil
				if player.Parent == nil then
					broken = "left"
				elseif not isAlive(player) then
					broken = "died"
				elseif def == nil or not isInRadius(player, def) then
					broken = "left the territory"
				elseif isTideActive() then
					broken = "tide started"
				end
				if broken ~= nil then
					_channels[player] = nil
					broadcastTerritories({ Action = "ChannelBroken", TerritoryId = channel.TerritoryId, Player = player.Name, Reason = broken })
					print(string.format("[TerritoryService] %s's capture of %s broke (%s)", player.Name, channel.TerritoryId, broken))
				else
					-- Contested: anyone else alive in the radius
					-- freezes progress (holder included — standing in
					-- your own territory defends it).
					local contested = false
					for _, other in ipairs(Players:GetPlayers()) do
						if other ~= player and isAlive(other) and isInRadius(other, def) then
							contested = true
							break
						end
					end
					if not contested then
						channel.Progress += 1
						if channel.Progress >= CAPTURE_CHANNEL_SECONDS then
							_channels[player] = nil
							local previous = _holders[channel.TerritoryId]
							_holders[channel.TerritoryId] = player
							_xpAccrued[player] = 0
							fireAll("EventUpdate", {
								EventId = "TerritoryCaptured",
								Name = player.Name .. " captured " .. def.Name .. "!",
								Phase = "Started",
								Duration = 6,
							})
							reportProgress(player, "territory", "capture", 1)
							broadcastTerritories({ Action = "TerritoryCaptured", TerritoryId = channel.TerritoryId, Player = player.Name, PreviousHolder = previous and previous.Name or nil })
							print(string.format("[TerritoryService] %s captured %s", player.Name, channel.TerritoryId))
						else
							broadcastTerritories({ Action = "ChannelProgress", TerritoryId = channel.TerritoryId, Player = player.Name, Progress = channel.Progress })
						end
					else
						broadcastTerritories({ Action = "ChannelContested", TerritoryId = channel.TerritoryId, Player = player.Name, Progress = channel.Progress })
					end
				end
			end
			-- Holder bonuses + death watch.
			for territoryId, holder in pairs(_holders) do
				if holder.Parent == nil then
					releaseTerritory(territoryId, "holder left")
				elseif not isAlive(holder) then
					releaseTerritory(territoryId, "holder died")
				else
					local def = _byId[territoryId]
					if def then
						pcall(function()
							_dataService.AddCoins(holder, def.CoinsPerSec)
						end)
						local accrued = (_xpAccrued[holder] or 0) + 1
						if accrued >= 60 then
							_xpAccrued[holder] = 0
							if _progressionService then
								pcall(function()
									_progressionService.AddXP(holder, def.XPPerMinute)
								end)
							else
								pcall(function()
									_dataService.AddXP(holder, def.XPPerMinute)
								end)
							end
						else
							_xpAccrued[holder] = accrued
						end
					end
				end
			end
		end
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote("CaptureTerritory")
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onCaptureRemote)
		else
			warn("[TerritoryService] Remote not found, capture handler not wired: CaptureTerritory")
		end
	end)

	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction("RequestTerritories")
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(_player: Player)
				return TerritoryService.GetTerritories()
			end
		else
			warn("[TerritoryService] RemoteFunction not found, RequestTerritories not wired")
		end
	end)
end

return TerritoryService
