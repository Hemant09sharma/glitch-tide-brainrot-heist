--!strict
-- DimensionsService.luau
-- Glitch Tide v1.1 (Workstream A) — gameplay for the two v1.1 regions
-- (Abyssal Kingdom + Skyfall Kingdom, defined in shared Dimensions).
--
-- What it does, per region:
--   Abyssal: 3 treasure chests (ProximityPrompt -> real coin/XP rewards),
--     3 dangerous currents (push + damage while inside), a boss altar
--     (prompt -> BossService.SpawnBoss + one-time exclusive Brainrot).
--   Skyfall: 4-checkpoint timed run (Touched, in order, 90s -> coin/XP
--     reward + one-time exclusive Brainrot), 2 wind hazards (push only),
--     a hidden SkyCache chest, falling below y=20 returns you to the hub.
-- Teleports are server-validated: only from a hub portal (within 14
-- studs), only from hub -> dimension, only back via a return portal
-- (or by falling), 3s cooldown, denied while carrying a Brainrot.
--
-- REWARDS — exact APIs used (audit §4f: EconomyService has NO
-- AddCoins/AddGems; its public API is AwardKO/AwardWin/AwardWave/
-- BuyCharacter/GetBalance/NotifyBalance):
--   * Coins: DataService.AddCoins(player, n) — the same primitive
--     EconomyService itself uses internally.
--   * XP: ProgressionService.AddXP(player, n) when linked (handles
--     level-ups), else DataService.AddXP(player, n).
--   * Balance push after every reward: EconomyService.NotifyBalance.
--   * Exclusive Brainrots: DataService.UnlockCharacter(player, id)
--     (there is no EconomyService grant-character method).
--   * Boss: BossService.SpawnBoss() when linked via SetBossService.
--     NOTE: SpawnBoss spawns THE ALGORITHM in the Chaos Arena — there
--     is no Abyssal-local boss in BossService. The altar is therefore
--     a trigger for the shared world boss plus the Abyssal-local
--     exclusive reward, not a separate boss fight. A true Abyssal boss
--     needs a BossService change (future work, not this workstream).
--
-- REMOTES (not wired here — Remotes.luau is owned by another
-- workstream; see docs/REMOTES_NEEDED_A.md): this service polls for
-- a "TeleportDimension" RemoteEvent and a "RequestDimensions"
-- RemoteFunction and wires them IF they exist. Until then the
-- ProximityPrompts are the only path in/out, and "DimensionUpdate"
-- fires are silent no-ops (Remotes.FireClient with a string name).
-- Nothing here depends on Attack / StealBrainrot (both are dead client
-- paths per the audit) or on NPCService spawns (the Sky Wisps are
-- animated parts, not NPCs).
--
-- Init signature (matches GameManager's generic optional-service
-- fallback): DimensionsService.Init(dataService, economyService, map).
-- Init(map, dataService, economyService) and Init(map) are also
-- accepted (arguments are duck-typed). Setters (all wired by
-- GameManager.wireCrossLinks where the name exists in its shared
-- table): SetDataService, SetEconomyService, SetBossService,
-- SetCarryService, SetProgressionService. SetLightingService exists
-- too but needs a one-line addition to wireCrossLinks (see report).
--
-- Persistence: GetStateForSave / LoadState are in-memory only and
-- wire into DataService later. DataService is NOT edited here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Dimensions = require(ReplicatedStorage:WaitForChild("Dimensions"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local DimensionsService = {}

local TELEPORT_COOLDOWN = 3
local PORTAL_RADIUS = 14
local CHEST_RADIUS = 10
local ALTAR_RADIUS = 10
local TOUCH_DEBOUNCE = 1

local _map: Instance? = nil
local _dataService: any = nil
local _economyService: any = nil
local _bossService: any = nil
local _carryService: any = nil
local _progressionService: any = nil
local _lightingService: any = nil
local _questService: any = nil
local _started = false

local _playerDimension: { [Player]: string } = {}
local _teleportAt: { [Player]: number } = {}
local _chestAvailableAt: { [Player]: { [string]: number } } = {}
local _chestsOpened: { [Player]: { [string]: boolean } } = {}
local _checkpointRuns: { [Player]: { StartTime: number, NextIndex: number } } = {}
local _touchAt: { [Player]: number } = {}
local _exclusiveGranted: { [Player]: { [string]: boolean } } = {}
local _firstCheckpointDone: { [Player]: boolean } = {}
local _bossAltarAvailableAt: number = 0

-- SecurityService is optional (lazy require, like EconomyService).
local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function sanitizeId(id: any): string?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	if Security ~= nil and type(Security.SanitizeId) == "function" then
		local ok, clean = pcall(Security.SanitizeId, id)
		if ok and type(clean) == "string" then
			return clean
		end
		return nil
	end
	if string.match(id, "^[%w%-_]+$") ~= nil then
		return id
	end
	return nil
end

local function getRoot(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if character == nil then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root == nil or not root:IsA("BasePart") then
		return nil, nil
	end
	if humanoid == nil or humanoid.Health <= 0 then
		return nil, nil
	end
	return root :: BasePart, humanoid
end

local function getDimension(player: Player): string
	return _playerDimension[player] or Dimensions.GetHubId()
end

local function fireUpdate(player: Player, payload: { [string]: any }): ()
	pcall(function()
		Remotes.FireClient("DimensionUpdate", player, payload)
	end)
end

local function notifyBalance(player: Player): ()
	if _economyService ~= nil and type(_economyService.NotifyBalance) == "function" then
		pcall(_economyService.NotifyBalance, player)
	end
end

local function grantCoins(player: Player, coins: number): ()
	if _dataService == nil or type(_dataService.AddCoins) ~= "function" then
		warn("[DimensionsService] No DataService — cannot pay " .. tostring(coins) .. " coins to " .. player.Name)
		return
	end
	pcall(_dataService.AddCoins, player, coins)
end

local function grantXP(player: Player, xp: number): ()
	if _progressionService ~= nil and type(_progressionService.AddXP) == "function" then
		pcall(_progressionService.AddXP, player, xp)
		return
	end
	if _dataService ~= nil and type(_dataService.AddXP) == "function" then
		pcall(_dataService.AddXP, player, xp)
	end
end

local function grantExclusive(player: Player, characterId: string): boolean
	if _dataService == nil or type(_dataService.UnlockCharacter) ~= "function" then
		return false
	end
	local granted = _exclusiveGranted[player]
	if granted ~= nil and granted[characterId] == true then
		return false
	end
	local ok, unlocked = pcall(_dataService.UnlockCharacter, player, characterId)
	if ok and unlocked == true then
		if granted == nil then
			granted = {}
			_exclusiveGranted[player] = granted
		end
		granted[characterId] = true
		return true
	end
	return false
end

local function findInMap(path: { string }): Instance?
	local current: Instance? = _map
	for _, name in ipairs(path) do
		if current == nil then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function addPrompt(parent: Instance, actionText: string, objectText: string, holdDuration: number, maxDistance: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = holdDuration
	prompt.MaxActivationDistance = maxDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

-- TeleportToDimension(player, dimensionId) -> (ok, message).
-- Server-validated: hub -> dimension only, from that dimension's hub
-- portal, 3s cooldown, not while carrying.
function DimensionsService.TeleportToDimension(player: Player, dimensionId: any): (boolean, string)
	local id = sanitizeId(dimensionId)
	if id == nil then
		return false, "unknown dimension"
	end
	local def = Dimensions.GetById(id)
	if def == nil then
		return false, "unknown dimension"
	end
	-- v1.1 (Workstream C): world unlock gate. The unlock attribute
	-- ("DimensionUnlocked_<id>", set by ProgressionService on unlock)
	-- is the fast path; otherwise CanAccessDimension decides (and
	-- unlocks + sets the attribute when the level requirement is
	-- met). A locked teleport is denied with a TeleportDenied
	-- broadcast — never a silent fail. When no ProgressionService is
	-- linked at all, the gate fails OPEN (Wave 1 free travel) rather
	-- than locking everyone out over a wiring problem.
	if _progressionService ~= nil then
		local unlocked = player:GetAttribute("DimensionUnlocked_" .. id) == true
		if not unlocked and type(_progressionService.CanAccessDimension) == "function" then
			local ok, allowed = pcall(_progressionService.CanAccessDimension, player, id)
			if ok then
				unlocked = allowed == true
			end
		end
		if not unlocked then
			fireUpdate(player, { Action = "TeleportDenied", Reason = "locked" })
			return false, "dimension locked"
		end
	end
	local root, _humanoid = getRoot(player)
	if root == nil then
		return false, "no character"
	end
	local now = os.clock()
	if (now - (_teleportAt[player] or 0)) < TELEPORT_COOLDOWN then
		return false, "teleporting too fast"
	end
	local current = getDimension(player)
	if current ~= Dimensions.GetHubId() then
		return false, "return to the hub first"
	end
	if current == id then
		return false, "already there"
	end
	-- Must be standing at this dimension's hub portal.
	local portal = Vector3.new(def.HubPortalPosition.X, root.Position.Y, def.HubPortalPosition.Z)
	if (root.Position - portal).Magnitude > PORTAL_RADIUS then
		return false, "step into the portal first"
	end
	if _carryService ~= nil and type(_carryService.IsCarrying) == "function" then
		local ok, carrying = pcall(_carryService.IsCarrying, player)
		if ok and carrying == true then
			return false, "put your Brainrot down first"
		end
	end
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(def.SpawnPosition)
	end)
	_playerDimension[player] = id
	_teleportAt[player] = now
	_checkpointRuns[player] = nil
	-- v1.1 (Workstream C): quest-progress hook — dimension visit.
	if _questService and type(_questService.ReportProgress) == "function" then
		pcall(function()
			_questService.ReportProgress(player, "dimension", "visit_" .. id, 1)
		end)
	end
	fireUpdate(player, {
		Action = "Teleported",
		Dimension = id,
		DisplayName = def.DisplayName,
	})
	print(string.format("[DimensionsService] %s entered %s", player.Name, def.DisplayName))
	return true, def.DisplayName
end

-- ReturnToHub(player, reason?) -> (ok, message). `reason == "fell"`
-- skips the return-portal proximity check (the player is out of the
-- world, not standing at a portal).
function DimensionsService.ReturnToHub(player: Player, reason: any): (boolean, string)
	local current = getDimension(player)
	if current == Dimensions.GetHubId() then
		return false, "already in the hub"
	end
	local def = Dimensions.GetById(current)
	local root, _humanoid = getRoot(player)
	if root == nil then
		-- Dead / no character: just clear the record; the respawn
		-- puts them at the hub SpawnLocation anyway.
		_playerDimension[player] = Dimensions.GetHubId()
		return true, "hub"
	end
	local now = os.clock()
	if (now - (_teleportAt[player] or 0)) < TELEPORT_COOLDOWN and reason ~= "fell" then
		return false, "teleporting too fast"
	end
	if reason ~= "fell" and def ~= nil then
		local portal = Vector3.new(def.ReturnPortalPosition.X, root.Position.Y, def.ReturnPortalPosition.Z)
		if (root.Position - portal).Magnitude > PORTAL_RADIUS then
			return false, "step into the return portal first"
		end
	end
	local spawn = Vector3.new(0, 3, 0)
	if _map ~= nil then
		local ok, mapBuilder = pcall(function()
			return require(script.Parent:WaitForChild("MapBuilder"))
		end)
		if ok and mapBuilder ~= nil and type(mapBuilder.GetSpawnPosition) == "function" then
			local ok2, pos = pcall(mapBuilder.GetSpawnPosition)
			if ok2 and typeof(pos) == "Vector3" then
				spawn = pos
			end
		end
	end
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(spawn)
	end)
	_playerDimension[player] = Dimensions.GetHubId()
	_teleportAt[player] = now
	_checkpointRuns[player] = nil
	fireUpdate(player, { Action = "Returned", Dimension = Dimensions.GetHubId() })
	print(string.format("[DimensionsService] %s returned to the hub (%s)", player.Name, tostring(reason or "portal")))
	return true, "hub"
end

-- OpenChest(player, chestName) -> (ok, message). Works for Abyssal
-- chests and the Skyfall SkyCache (both live in def.Chests).
function DimensionsService.OpenChest(player: Player, chestName: any): (boolean, string)
	local name = sanitizeId(chestName)
	if name == nil then
		return false, "unknown chest"
	end
	local current = getDimension(player)
	local def = Dimensions.GetById(current)
	if def == nil then
		return false, "open chests inside a dimension"
	end
	local chest = Dimensions.GetChest(def, name)
	if chest == nil then
		return false, "unknown chest"
	end
	local root, _humanoid = getRoot(player)
	if root == nil then
		return false, "no character"
	end
	local chestPos = Vector3.new(chest.Position.X, root.Position.Y, chest.Position.Z)
	if (root.Position - chestPos).Magnitude > CHEST_RADIUS then
		return false, "get closer to the chest"
	end
	local now = os.clock()
	local perPlayer = _chestAvailableAt[player]
	if perPlayer ~= nil and (perPlayer[name] or 0) > now then
		local remaining = math.ceil((perPlayer[name] or 0) - now)
		return false, "this chest is empty — come back in " .. tostring(remaining) .. "s"
	end
	grantCoins(player, chest.Coins)
	grantXP(player, chest.XP)
	notifyBalance(player)
	-- v1.1 (Workstream C): quest-progress hook — dimension chest.
	if _questService and type(_questService.ReportProgress) == "function" then
		pcall(function()
			_questService.ReportProgress(player, "dimension", "chest", 1)
		end)
	end
	if perPlayer == nil then
		perPlayer = {}
		_chestAvailableAt[player] = perPlayer
	end
	perPlayer[name] = now + chest.CooldownSeconds
	local opened = _chestsOpened[player]
	if opened == nil then
		opened = {}
		_chestsOpened[player] = opened
	end
	opened[name] = true
	fireUpdate(player, {
		Action = "ChestOpened",
		Chest = name,
		Title = chest.Title,
		Coins = chest.Coins,
		XP = chest.XP,
	})
	print(string.format("[DimensionsService] %s opened %s (+%d coins, +%d XP)",
		player.Name, chest.Title, chest.Coins, chest.XP))
	return true, chest.Title
end

-- TriggerBossAltar(player) -> (ok, message). Server-wide cooldown;
-- requires BossService. See the header note: this awakens the shared
-- world boss (Chaos Arena), it is not an Abyssal-local boss fight.
function DimensionsService.TriggerBossAltar(player: Player): (boolean, string)
	if getDimension(player) ~= "abyssal" then
		return false, "the altar is in the Abyssal Kingdom"
	end
	local root, _humanoid = getRoot(player)
	if root == nil then
		return false, "no character"
	end
	local altar = Vector3.new(-150, root.Position.Y, 156)
	if (root.Position - altar).Magnitude > ALTAR_RADIUS then
		return false, "step up to the altar first"
	end
	local now = os.clock()
	if now < _bossAltarAvailableAt then
		return false, "the altar is dormant — come back later"
	end
	if _bossService == nil or type(_bossService.SpawnBoss) ~= "function" then
		return false, "the horror does not answer (no BossService)"
	end
	local ok, spawned = pcall(_bossService.SpawnBoss)
	if not ok or spawned ~= true then
		return false, "the horror is already awake"
	end
	_bossAltarAvailableAt = now + 600
	local def = Dimensions.GetById("abyssal")
	if def ~= nil and def.ExclusiveCharacterId ~= nil then
		if grantExclusive(player, def.ExclusiveCharacterId :: string) then
			grantCoins(player, 100)
			notifyBalance(player)
		end
	end
	fireUpdate(player, {
		Action = "BossTriggered",
		Dimension = "abyssal",
	})
	print(string.format("[DimensionsService] %s awakened the boss at the Abyssal altar", player.Name))
	return true, "the deep answers"
end

-- ApplyDimensionMood(dimensionId) -> boolean. Explicit opt-in only:
-- lighting is global, so a mood must never flip automatically on one
-- player's teleport. A server-wide event (or a future client-side
-- mood) calls this deliberately.
function DimensionsService.ApplyDimensionMood(dimensionId: any): boolean
	local id = sanitizeId(dimensionId)
	if id == nil then
		return false
	end
	local def = Dimensions.GetById(id)
	if def == nil then
		return false
	end
	if _lightingService == nil or type(_lightingService.SetMood) ~= "function" then
		return false
	end
	local ok, result = pcall(_lightingService.SetMood, def.LightingMood)
	return ok and result == true
end

function DimensionsService.GetDimensions(): { { [string]: any } }
	local out: { { [string]: any } } = {}
	for _, def in ipairs(Dimensions.GetAll()) do
		local chests: { { [string]: any } } = {}
		for _, chest in ipairs(def.Chests) do
			local chestEntry: { [string]: any } = {
				Name = chest.Name,
				Title = chest.Title,
				Coins = chest.Coins,
				XP = chest.XP,
			}
			table.insert(chests, chestEntry)
		end
		local entry: { [string]: any } = {
			Id = def.Id,
			DisplayName = def.DisplayName,
			Description = def.Description,
			LightingMood = def.LightingMood,
			ExclusiveCharacterId = def.ExclusiveCharacterId,
			HubPortalPosition = def.HubPortalPosition,
			SpawnPosition = def.SpawnPosition,
			CheckpointTimeLimit = def.CheckpointTimeLimit,
			CheckpointRewardCoins = def.CheckpointRewardCoins,
			CheckpointRewardXP = def.CheckpointRewardXP,
			Chests = chests,
		}
		table.insert(out, entry)
	end
	return out
end

function DimensionsService.GetPlayerDimension(player: Player): string
	return getDimension(player)
end

function DimensionsService.IsInDimension(player: Player, dimensionId: string): boolean
	return getDimension(player) == dimensionId
end

-- In-memory only (wiring into DataService comes later; DataService
-- is not edited here). Save shape is plain data.
function DimensionsService.GetStateForSave(player: Player): { [string]: any }
	local opened: { string } = {}
	local openedSet = _chestsOpened[player]
	if openedSet ~= nil then
		for name, _ in pairs(openedSet) do
			table.insert(opened, name)
		end
	end
	local granted: { string } = {}
	local grantedSet = _exclusiveGranted[player]
	if grantedSet ~= nil then
		for id, _ in pairs(grantedSet) do
			table.insert(granted, id)
		end
	end
	return {
		CurrentDimension = getDimension(player),
		ChestsOpened = opened,
		ExclusiveGranted = granted,
	}
end

function DimensionsService.LoadState(player: Player, data: any): ()
	if type(data) ~= "table" then
		return
	end
	if type(data.CurrentDimension) == "string" and Dimensions.GetById(data.CurrentDimension) ~= nil then
		_playerDimension[player] = data.CurrentDimension
	end
	if type(data.ChestsOpened) == "table" then
		local opened: { [string]: boolean } = {}
		for _, name in ipairs(data.ChestsOpened) do
			if type(name) == "string" then
				opened[name] = true
			end
		end
		_chestsOpened[player] = opened
	end
	if type(data.ExclusiveGranted) == "table" then
		local granted: { [string]: boolean } = {}
		for _, id in ipairs(data.ExclusiveGranted) do
			if type(id) == "string" then
				granted[id] = true
			end
		end
		_exclusiveGranted[player] = granted
	end
end

local function onCheckpointTouched(player: Player, checkpointIndex: number): ()
	local now = os.clock()
	if (now - (_touchAt[player] or 0)) < TOUCH_DEBOUNCE then
		return
	end
	_touchAt[player] = now
	if getDimension(player) ~= "skyfall" then
		return
	end
	local root, _humanoid = getRoot(player)
	if root == nil then
		return
	end
	local def = Dimensions.GetById("skyfall")
	if def == nil then
		return
	end
	local run = _checkpointRuns[player]
	if checkpointIndex == 1 then
		-- (Re)start the run.
		_checkpointRuns[player] = { StartTime = now, NextIndex = 2 }
		fireUpdate(player, { Action = "Checkpoint", Index = 1, Total = #def.Checkpoints })
		return
	end
	if run == nil then
		return
	end
	if checkpointIndex ~= run.NextIndex then
		return
	end
	if checkpointIndex < #def.Checkpoints then
		run.NextIndex = checkpointIndex + 1
		fireUpdate(player, { Action = "Checkpoint", Index = checkpointIndex, Total = #def.Checkpoints })
		return
	end
	-- Final checkpoint.
	local elapsed = now - run.StartTime
	_checkpointRuns[player] = nil
	if elapsed > def.CheckpointTimeLimit then
		fireUpdate(player, {
			Action = "CheckpointFailed",
			Reason = "time",
			ElapsedSeconds = math.floor(elapsed),
			TimeLimit = def.CheckpointTimeLimit,
		})
		return
	end
	grantCoins(player, def.CheckpointRewardCoins)
	grantXP(player, def.CheckpointRewardXP)
	local first = _firstCheckpointDone[player] ~= true
	if first then
		_firstCheckpointDone[player] = true
		if def.ExclusiveCharacterId ~= nil then
			grantExclusive(player, def.ExclusiveCharacterId :: string)
		end
	end
	notifyBalance(player)
	-- v1.1 (Workstream C): quest-progress hook — checkpoint run done.
	if _questService and type(_questService.ReportProgress) == "function" then
		pcall(function()
			_questService.ReportProgress(player, "dimension", "checkpoint", 1)
		end)
	end
	fireUpdate(player, {
		Action = "CheckpointComplete",
		ElapsedSeconds = math.floor(elapsed),
		Coins = def.CheckpointRewardCoins,
		XP = def.CheckpointRewardXP,
		FirstCompletion = first,
	})
	print(string.format("[DimensionsService] %s finished the Skyfall run in %ds",
		player.Name, math.floor(elapsed)))
end

local function wirePrompts(): ()
	if _map == nil then
		return
	end
	-- Hub portals (MemeversePlaza -> AbyssalPortal / SkyfallPortal).
	for _, def in ipairs(Dimensions.GetAll()) do
		local folderName = (def.Id == "abyssal") and "AbyssalPortal" or "SkyfallPortal"
		local swirl = findInMap({ "MemeversePlaza", folderName, "PortalSwirl" })
		if swirl ~= nil and swirl:IsA("BasePart") then
			local prompt = addPrompt(swirl, "Enter " .. def.DisplayName, def.DisplayName, 0, 10)
			prompt.Triggered:Connect(function(player)
				local ok, message = DimensionsService.TeleportToDimension(player, def.Id)
				if not ok then
					fireUpdate(player, { Action = "TeleportDenied", Reason = message })
				end
			end)
		else
			warn("[DimensionsService] Hub portal missing for " .. def.Id)
		end
	end
	-- Return portals inside each dimension.
	for _, def in ipairs(Dimensions.GetAll()) do
		local folderName = (def.Id == "abyssal") and "AbyssalKingdom" or "SkyfallKingdom"
		local swirl = findInMap({ folderName, "ReturnPortal", "PortalSwirl" })
		if swirl ~= nil and swirl:IsA("BasePart") then
			local prompt = addPrompt(swirl, "Return to the hub", "Return Portal", 0, 10)
			prompt.Triggered:Connect(function(player)
				local ok, message = DimensionsService.ReturnToHub(player, "portal")
				if not ok then
					fireUpdate(player, { Action = "TeleportDenied", Reason = message })
				end
			end)
		else
			warn("[DimensionsService] Return portal missing for " .. def.Id)
		end
	end
	-- Treasure chests + SkyCache.
	for _, def in ipairs(Dimensions.GetAll()) do
		local folderName = (def.Id == "abyssal") and "AbyssalKingdom" or "SkyfallKingdom"
		for _, chest in ipairs(def.Chests) do
			local part = findInMap({ folderName, chest.Name })
			if part ~= nil and part:IsA("BasePart") then
				local prompt = addPrompt(part, "Open " .. chest.Title, chest.Title, 1, 8)
				prompt.Triggered:Connect(function(player)
					local ok, message = DimensionsService.OpenChest(player, chest.Name)
					if not ok then
						fireUpdate(player, { Action = "ChestDenied", Reason = message })
					end
				end)
			else
				warn("[DimensionsService] Chest part missing: " .. chest.Name)
			end
		end
	end
	-- Boss altar (Abyssal).
	local altar = findInMap({ "AbyssalKingdom", "BossAltar" })
	if altar ~= nil and altar:IsA("BasePart") then
		local prompt = addPrompt(altar, "Awaken the deep horror", "Boss Altar", 2, 8)
		prompt.Triggered:Connect(function(player)
			local ok, message = DimensionsService.TriggerBossAltar(player)
			if not ok then
				fireUpdate(player, { Action = "BossDenied", Reason = message })
			end
		end)
	else
		warn("[DimensionsService] Boss altar missing")
	end
	-- Skyfall checkpoint pads.
	for _, cp in ipairs((Dimensions.GetById("skyfall") :: any).Checkpoints) do
		local pad = findInMap({ "SkyfallKingdom", cp.Name })
		if pad ~= nil and pad:IsA("BasePart") then
			local index = tonumber(string.match(cp.Name, "%d+")) or 0
			(pad :: BasePart).Touched:Connect(function(hit)
				local character = hit.Parent
				if character == nil then
					return
				end
				local player = Players:GetPlayerFromCharacter(character)
				if player ~= nil then
					onCheckpointTouched(player, index)
				end
			end)
		else
			warn("[DimensionsService] Checkpoint pad missing: " .. tostring(cp.Name))
		end
	end
end

-- Optional remotes (see docs/REMOTES_NEEDED_A.md): wire them IF they
-- exist. Until Remotes.luau gains the names, the prompts above are the
-- only path in/out and DimensionUpdate fires are silent no-ops.
local function wireOptionalRemotes(): ()
	task.spawn(function()
		local teleportRemote: RemoteEvent? = nil
		local dimsFn: RemoteFunction? = nil
		for _ = 1, 50 do
			if teleportRemote == nil then
				local ok, remote = pcall(Remotes.GetRemote, "TeleportDimension")
				if ok and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
					teleportRemote = remote
				end
			end
			if dimsFn == nil then
				local ok, fn = pcall(Remotes.GetFunction, "RequestDimensions")
				if ok and typeof(fn) == "Instance" and fn:IsA("RemoteFunction") then
					dimsFn = fn
				end
			end
			if teleportRemote ~= nil and dimsFn ~= nil then
				break
			end
			task.wait(0.2)
		end
		if teleportRemote ~= nil then
			(teleportRemote :: RemoteEvent).OnServerEvent:Connect(function(player, payload)
				if type(payload) ~= "table" then
					return
				end
				if Security ~= nil and type(Security.BurstLimit) == "function" then
					local allowed = false
					pcall(function()
						allowed = Security.BurstLimit(player, "TeleportDimension", 5, 5)
					end)
					if not allowed then
						return
					end
				end
				if payload.Action == "Teleport" then
					DimensionsService.TeleportToDimension(player, payload.DimensionId)
				elseif payload.Action == "Return" then
					DimensionsService.ReturnToHub(player, "remote")
				end
			end)
		else
			warn("[DimensionsService] TeleportDimension remote not available (see docs/REMOTES_NEEDED_A.md)")
		end
		if dimsFn ~= nil then
			(dimsFn :: RemoteFunction).OnServerInvoke = function(_player)
				return DimensionsService.GetDimensions()
			end
		else
			warn("[DimensionsService] RequestDimensions function not available (see docs/REMOTES_NEEDED_A.md)")
		end
	end)
end

-- Hazard poll: currents push + damage, wind pushes, falling out of
-- Skyfall returns the player to the hub. 0.5s tick, server-side only.
local function startHazardLoop(): ()
	task.spawn(function()
		while _started do
			task.wait(0.5)
			for _, player in ipairs(Players:GetPlayers()) do
				pcall(function()
					local current = getDimension(player)
					if current == Dimensions.GetHubId() then
						return
					end
					local def = Dimensions.GetById(current)
					if def == nil then
						return
					end
					local root, humanoid = getRoot(player)
					if root == nil or humanoid == nil then
						return
					end
					if def.FallReturnY ~= nil and root.Position.Y < (def.FallReturnY :: number) then
						DimensionsService.ReturnToHub(player, "fell")
						return
					end
					for _, hazard in ipairs(def.Hazards) do
						local offset = root.Position - hazard.Center
						if offset.Magnitude <= hazard.Radius then
							local vel = root.AssemblyLinearVelocity
							root.AssemblyLinearVelocity = Vector3.new(
								vel.X * 0.5 + hazard.Push.X,
								vel.Y,
								vel.Z * 0.5 + hazard.Push.Z)
							if hazard.DamagePerSecond > 0 then
								humanoid:TakeDamage(hazard.DamagePerSecond * 0.5)
							end
						end
					end
				end)
			end
		end
	end)
end

local function normalizeArgs(a: any, b: any, c: any): (any, any, Instance?)
	local dataService: any = nil
	local economyService: any = nil
	local map: Instance? = nil
	if typeof(a) == "Instance" then
		-- Init(map, dataService?, economyService?)
		map = a
		dataService = b
		economyService = c
	elseif typeof(c) == "Instance" then
		-- Init(dataService, economyService, map) — the generic fallback
		map = c
		dataService = a
		economyService = b
	else
		dataService = a
		economyService = b
	end
	return dataService, economyService, map
end

-- Init(dataService, economyService, map) — generic optional-service
-- shape. Also accepts Init(map, dataService, economyService) and
-- Init(map). dataService / economyService may be nil (rewards then
-- warn instead of paying); the service still runs teleports.
function DimensionsService.Init(a: any, b: any, c: any): ()
	local dataService, economyService, map = normalizeArgs(a, b, c)
	_dataService = dataService
	_economyService = economyService
	_map = map
	_started = true

	Players.PlayerRemoving:Connect(function(player)
		_playerDimension[player] = nil
		_teleportAt[player] = nil
		_chestAvailableAt[player] = nil
		_chestsOpened[player] = nil
		_checkpointRuns[player] = nil
		_touchAt[player] = nil
		_exclusiveGranted[player] = nil
		_firstCheckpointDone[player] = nil
	end)

	if _map ~= nil then
		wirePrompts()
	else
		warn("[DimensionsService] Init called without a map — prompts not wired")
	end
	wireOptionalRemotes()
	startHazardLoop()
	print("[DimensionsService] Initialised (2 dimensions: abyssal, skyfall)")
end

function DimensionsService.SetDataService(dataService: any): ()
	_dataService = dataService
end

function DimensionsService.SetEconomyService(economyService: any): ()
	_economyService = economyService
end

function DimensionsService.SetBossService(bossService: any): ()
	_bossService = bossService
end

function DimensionsService.SetCarryService(carryService: any): ()
	_carryService = carryService
end

function DimensionsService.SetProgressionService(progressionService: any): ()
	_progressionService = progressionService
end

function DimensionsService.SetQuestService(questService: any): ()
	if questService and type(questService.ReportProgress) == "function" then
		_questService = questService
	end
end

function DimensionsService.SetLightingService(lightingService: any): ()
	_lightingService = lightingService
end

return DimensionsService
