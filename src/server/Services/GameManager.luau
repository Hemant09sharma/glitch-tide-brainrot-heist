--!strict
-- GameManager.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Replaces the old arena round loop with a persistent world loop: there
-- is no round / win cycle. Players join a living Memeverse, get a base,
-- buy Brainrots off the conveyor, carry them home and earn passive
-- income while the Glitch Tide comes and goes.
-- Init wires the core services in dependency order and pcall-loads the
-- event / progression services (Tide, Mutation, Ability, Raid, Quest,
-- Event, NPC) if they exist yet, skipping missing ones with a warn —
-- they are built in parallel and may land after this file.
-- CharacterService is only pcall-required for the respawn morph (it is
-- not a hard dependency and must never create a require cycle).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local ConveyorService = require(script.Parent:WaitForChild("ConveyorService"))
local BaseService = require(script.Parent:WaitForChild("BaseService"))
local CarryService = require(script.Parent:WaitForChild("CarryService"))

local GameManager = {}

local _dataService: any = nil
local _economyService: any = nil
local _map: Model? = nil
local _started = false
local _characterService: any = nil
local _characterServiceInit = false

-- Optional services built in parallel; may be absent at load time.
-- Load order matters: QuestService / EventService load before
-- MutationService because its Init takes them; TideService loads first
-- because AbilityService / EventService take it; NPCService loads before
-- EventService / BossService / WaveService; MutationService loads before
-- FusionService and RaidService (both take it via Init / opts).
local _optional: { [string]: any } = {}

local OPTIONAL_SERVICES = {
	"TideService",
	"QuestService",
	"NPCService",
	"EventService",
	"MutationService",
	"FusionService",
	"AbilityService",
	"RaidService",
	"BossService",
	"WaveService",
	"ProgressionService",
	-- v1.1: visual/world services (generic fallback Init(dataService,
	-- economyService, map) matches their signatures), then companions,
	-- then the Wave-2 systems (explicit branches below — their Init
	-- argument orders do NOT match the generic fallback).
	"LightingService",
	"EnvironmentService",
	"DimensionsService",
	"CompanionService",
	"LaboratoryService",
	"ExpeditionService",
	"TerritoryService",
	"SecretService",
	"AchievementService",
}

local function getRemotesFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local ok, found = pcall(function()
		return ReplicatedStorage:WaitForChild("Remotes", 5)
	end)
	if ok and typeof(found) == "Instance" then
		return found :: Folder
	end
	return nil
end

local function getEvent(name: string): RemoteEvent?
	local folder = getRemotesFolder()
	if folder == nil then
		return nil
	end
	local child = folder:FindFirstChild(name)
	if child and child:IsA("RemoteEvent") then
		return child
	end
	return nil
end

local function fireAll(name: string, payload: any): ()
	local remote = getEvent(name)
	if remote ~= nil then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function fireClient(name: string, player: Player, payload: any): ()
	local remote = getEvent(name)
	if remote ~= nil then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

-- Cheapest Common Brainrot in the live roster = the starter grant.
-- Prefers Characters.GetStarterId() when the roster defines one; never
-- hardcodes an id (the roster was replaced by another agent).
local function pickStarter(): any
	if type(Characters.GetStarterId) == "function" then
		local ok, starterId = pcall(Characters.GetStarterId)
		if ok and type(starterId) == "string" and starterId ~= "" then
			local def = Characters.GetById(starterId)
			if def ~= nil then
				return def
			end
		end
	end
	local commons: { any } = {}
	for _, def in ipairs(Characters.GetAll()) do
		if def.Rarity == "Common" then
			table.insert(commons, def)
		end
	end
	table.sort(commons, function(a: any, b: any)
		return (tonumber(a.Cost) or 0) < (tonumber(b.Cost) or 0)
	end)
	if #commons > 0 then
		return commons[1]
	end
	local sorted = Characters.GetSortedByCost()
	if #sorted > 0 then
		return sorted[1]
	end
	return nil
end

local function grantStarter(player: Player): ()
	local starter = pickStarter()
	if starter == nil then
		warn("[GameManager] No characters in roster; no starter granted to " .. player.Name)
		return
	end
	local data = _dataService.GetOrLoad(player)
	_dataService.UnlockCharacter(player, starter.Id)
	_dataService.SetSelected(player, starter.Id)
	-- Also hand the starter over as a carried Brainrot instance so a brand
	-- new player immediately has something to place in their base. The
	-- registry is data.OwnedInstances (shared with MutationService): when
	-- it is loaded, seed through it first so its Unlocked-derived
	-- instances exist, then create the starter through it; otherwise
	-- insert the same record shape directly.
	local mutationService = _optional["MutationService"]
	local owned: { [string]: any }? = nil
	if mutationService ~= nil and type(mutationService.GetInstances) == "function" then
		local ok, instances = pcall(function()
			return mutationService.GetInstances(player)
		end)
		if ok and type(instances) == "table" then
			for _, record in ipairs(instances) do
				if record.CharacterId == starter.Id then
					owned = record
					break
				end
			end
			if owned == nil and type(mutationService.CreateInstance) == "function" then
				local ok2, record = pcall(function()
					return mutationService.CreateInstance(player, starter.Id, 1, nil)
				end)
				if ok2 and type(record) == "table" then
					owned = record
				end
			end
		end
	end
	if owned == nil then
		if type(data.OwnedInstances) ~= "table" then
			data.OwnedInstances = {}
		end
		for _, record in ipairs(data.OwnedInstances) do
			if record.CharacterId == starter.Id then
				owned = record
				break
			end
		end
		if owned == nil then
			local HttpService = game:GetService("HttpService")
			owned = {
				InstanceId = HttpService:GenerateGUID(false),
				CharacterId = starter.Id,
				Level = 1,
				Glitched = false,
				Mutation = nil,
				Placed = false,
				Slot = 0,
				PurchasedAt = os.time(),
			}
			table.insert(data.OwnedInstances, owned)
		end
	end
	if owned ~= nil then
		-- Pick it up automatically on first join.
		task.spawn(function()
			task.wait(1)
			if player.Parent ~= nil then
				pcall(function()
					CarryService.PickupOwned(player, owned)
				end)
			end
		end)
	end
	print(string.format("[GameManager] Starter %s granted to %s", tostring(starter.Id), player.Name))
end

local function applySelectedCharacter(player: Player): ()
	if _characterService == nil then
		return
	end
	local selected = _dataService.GetSelected(player)
	if type(selected) ~= "string" or selected == "" then
		local starter = pickStarter()
		if starter ~= nil then
			selected = starter.Id
		else
			return
		end
	end
	pcall(function()
		_characterService.ApplyCharacter(player, selected)
	end)
end

local function sendWelcome(player: Player): ()
	-- Initial state push so the client UI can render without waiting for
	-- the next conveyor / income broadcast.
	task.spawn(function()
		task.wait(0.5)
		if player.Parent == nil then
			return
		end
		pcall(function()
			fireClient(Remotes.Names.ConveyorUpdate, player, {
				Items = ConveyorService.GetItems(),
				GlitchMode = ConveyorService.IsGlitchMode(),
			})
		end)
		pcall(function()
			local snapshot = BaseService.GetBase(player)
			if snapshot ~= nil then
				fireClient(Remotes.Names.BaseUpdate, player, snapshot)
			end
		end)
		pcall(function()
			local carried = CarryService.GetCarried(player)
			fireClient(Remotes.Names.CarryUpdate, player, {
				Carrying = carried ~= nil,
				InstanceId = carried and carried.InstanceId or nil,
				CharacterId = carried and carried.CharacterId or nil,
				Glitched = carried and carried.Glitched == true or false,
			})
		end)
		-- Push the equipped power loadout so the client AbilityController
		-- can build its 1/2/3 loadout bar. v1.0.0 never sent it, so the
		-- loadout powers had no client-side presence at all.
		pcall(function()
			local ability = _optional["AbilityService"]
			if ability ~= nil and type(ability.PushLoadout) == "function" then
				ability.PushLoadout(player)
			end
		end)
	end)
end

local function onPlayerAdded(player: Player): ()
	local ok, err = pcall(function()
		_dataService.GetOrLoad(player)
		grantStarter(player)
		BaseService.AssignBase(player)
		BaseService.RebuildBase(player)
		sendWelcome(player)
	end)
	if not ok then
		warn("[GameManager] Join setup failed for " .. player.Name .. ": " .. tostring(err))
	end
	player.CharacterAdded:Connect(function()
		-- Carry state was cleared on death / removal by CarryService; the
		-- respawn just needs the selected character re-applied.
		task.wait(0.3)
		if player.Parent ~= nil then
			applySelectedCharacter(player)
		end
	end)
end

local function onPlayerRemoving(player: Player): ()
	pcall(function()
		CarryService.ClearCarried(player, true)
	end)
	pcall(function()
		BaseService.ReleaseBase(player)
	end)
	pcall(function()
		ConveyorService.OnPlayerLeaving(player)
	end)
	pcall(function()
		_dataService.SaveData(player)
	end)
end

-- pcall-load one optional service and Init it. Each service has its own
-- Init signature, so they are special-cased here; a generic
-- (dataService, economyService, map) call is only the fallback for
-- services whose signature is still unknown. Missing modules are
-- skipped with a warn, never a crash.
local function loadOptional(name: string): ()
	local module = script.Parent:FindFirstChild(name)
	if module == nil then
		warn("[GameManager] Optional service not present yet, skipping: " .. name)
		return
	end
	local ok, service = pcall(require, module)
	if not ok or type(service) ~= "table" then
		warn("[GameManager] Could not require " .. name .. ": " .. tostring(service))
		return
	end
	_optional[name] = service
	local tideService = _optional["TideService"]
	local questService = _optional["QuestService"]
	local npcService = _optional["NPCService"]
	local eventService = _optional["EventService"]
	local mutationService = _optional["MutationService"]
	local initOk: boolean, initErr: any = false, nil
	if type(service.Init) == "function" then
		if name == "TideService" then
			-- Init(dataService, map, callbacks): the tide needs the core
			-- loop's hooks to drop carried Brainrots, find safe zones
			-- (shelters + platforms + base plots) and flip glitch mode.
			-- IsTideSurfer resolves lazily: AbilityService loads later.
			local MapBuilder = require(script.Parent:WaitForChild("MapBuilder"))
			initOk, initErr = pcall(function()
				service.Init(_dataService, _map, {
					DropCarried = function(player: Player)
						CarryService.DropCarried(player, "tide")
					end,
					GetSafeZones = function()
						local zones: { { [string]: any } } = {}
						for _, zone in ipairs(MapBuilder.GetSafeZones()) do
							table.insert(zones, { Position = zone.Position, Radius = zone.Radius })
						end
						-- Base plots count as safe zones too.
						for _, plot in pairs(MapBuilder.GetBasePlots()) do
							table.insert(zones, { Position = plot.Center, Radius = 12 })
						end
						return zones
					end,
					SetGlitchMode = function(enabled: boolean)
						ConveyorService.SetGlitchMode(enabled)
						BaseService.SetTideMultiplier(enabled
							and (tonumber(Config.GlitchTideIncomeMultiplier) or 2) or 1)
					end,
					IsTideSurfer = function(player: Player)
						local ability = _optional["AbilityService"]
						if ability ~= nil and type(ability.IsTideSurfer) == "function" then
							local ok2, result = pcall(ability.IsTideSurfer, player)
							if ok2 and type(result) == "boolean" then
								return result
							end
						end
						-- v1.1: companion TideProtection (per-hit roll).
						-- CompanionService loads later; resolve lazily.
						local companion = _optional["CompanionService"]
						if companion ~= nil and type(companion.IsTideProtected) == "function" then
							local ok3, protected = pcall(companion.IsTideProtected, player)
							if ok3 and protected == true then
								return true
							end
						end
						return false
					end,
				})
			end)
		elseif name == "QuestService" or name == "ProgressionService" then
			-- Init(dataService).
			initOk, initErr = pcall(function()
				service.Init(_dataService)
			end)
		elseif name == "NPCService" then
			-- Init(map, combatService, questService, raidService).
			-- CombatService is never initialised (see header note), so
			-- nil; raidService is wired later via SetRaidService.
			initOk, initErr = pcall(function()
				service.Init(_map, nil, questService, nil)
			end)
		elseif name == "EventService" then
			-- Init(dataService, tideService, npcService, questService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, tideService, npcService, questService)
			end)
		elseif name == "MutationService" then
			-- Init(dataService, questService, eventService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, questService, eventService)
			end)
		elseif name == "FusionService" then
			-- Init(dataService, mutationService, questService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, mutationService, questService)
			end)
		elseif name == "AbilityService" then
			-- Init(dataService, tideService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, tideService)
			end)
		elseif name == "RaidService" then
			-- Init(dataService, baseService, carryService, opts).
			initOk, initErr = pcall(function()
				service.Init(_dataService, BaseService, CarryService, {
					MutationService = mutationService,
					QuestService = questService,
				})
			end)
		elseif name == "BossService" then
			-- Init(map, dataService, npcService, questService).
			initOk, initErr = pcall(function()
				service.Init(_map, _dataService, npcService, questService)
			end)
		elseif name == "WaveService" then
			-- Init(dataService, map, npcService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, _map, npcService)
			end)
		elseif name == "LaboratoryService" then
			-- Init(dataService, mutationService, fusionService).
			-- Generic fallback would pass economyService/map instead.
			initOk, initErr = pcall(function()
				service.Init(_dataService, mutationService, _optional["FusionService"])
			end)
		elseif name == "TerritoryService" then
			-- Init(dataService, map).
			initOk, initErr = pcall(function()
				service.Init(_dataService, _map)
			end)
		elseif name == "SecretService" then
			-- Init(dataService, npcService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, npcService)
			end)
		elseif name == "AchievementService" then
			-- Init(dataService, questService).
			initOk, initErr = pcall(function()
				service.Init(_dataService, questService)
			end)
		else
			initOk, initErr = pcall(function()
				service.Init(_dataService, _economyService, _map)
			end)
		end
	end
	if not initOk and type(service.Init) == "function" then
		-- Some services may Init with no arguments instead.
		local retryOk, retryErr = pcall(function()
			service.Init()
		end)
		if not retryOk then
			warn("[GameManager] " .. name .. ".Init failed: " .. tostring(initErr)
				.. " / retry: " .. tostring(retryErr))
		end
	end
	-- Cross-wire the services this core loop owns, when the optional
	-- service exposes a setter for them. All services here use dot
	-- notation (no self), so setters are called with just the value;
	-- nil values are skipped (the service keeps its own default).
	local function tryWire(method: string, value: any): ()
		if value ~= nil and type(service[method]) == "function" then
			pcall(service[method], value)
		end
	end
	tryWire("SetConveyorService", ConveyorService)
	tryWire("SetBaseService", BaseService)
	tryWire("SetCarryService", CarryService)
	tryWire("SetDataService", _dataService)
	tryWire("SetEconomyService", _economyService)
	tryWire("SetQuestService", questService)
	tryWire("SetNPCService", npcService)
	tryWire("SetMutationService", mutationService)
	tryWire("SetTideService", tideService)
	-- The core loop's instance registry is shared with MutationService.
	if name == "MutationService" then
		ConveyorService.SetMutationService(service)
		BaseService.SetMutationService(service)
	end
	-- RaidService owns the steal lifecycle; the core loop must route
	-- stolen carries and stolen placements through it.
	if name == "RaidService" then
		CarryService.SetRaidService(service)
		BaseService.SetRaidService(service)
	end
	print("[GameManager] Optional service loaded: " .. name)
end

-- After every optional service has loaded, run a second cross-link pass:
-- setters that take a service which loaded later (e.g. NPCService's
-- SetRaidService, EventService's SetNPCService) are wired here with the
-- final set of loaded services.
local function wireCrossLinks(): ()
	local function wireAll(target: any, setters: { [string]: any }): ()
		if type(target) ~= "table" then
			return
		end
		for method, value in pairs(setters) do
			if value ~= nil and type(target[method]) == "function" then
				pcall(target[method], value)
			end
		end
	end
	local shared = {
		SetConveyorService = ConveyorService,
		SetBaseService = BaseService,
		SetCarryService = CarryService,
		SetDataService = _dataService,
		SetEconomyService = _economyService,
		SetQuestService = _optional["QuestService"],
		SetNPCService = _optional["NPCService"],
		SetMutationService = _optional["MutationService"],
		SetTideService = _optional["TideService"],
		SetRaidService = _optional["RaidService"],
		-- v1.0.1 QA: these two setters existed on the services but were
		-- never called by the cross-link pass, so QuestService never
		-- delegated XP to ProgressionService and TideService never knew
		-- about BossService (no boss tides, no survivor quest events).
		SetProgressionService = _optional["ProgressionService"],
		SetBossService = _optional["BossService"],
		SetEventService = _optional["EventService"],
		-- v1.1: DimensionsService takes SetLightingService so its
		-- teleports can tint the portal light; TideService uses a
		-- pcall-require fallback for LightingService instead.
		SetLightingService = _optional["LightingService"],
		SetCompanionService = _optional["CompanionService"],
		SetDimensionsService = _optional["DimensionsService"],
		SetLaboratoryService = _optional["LaboratoryService"],
		SetExpeditionService = _optional["ExpeditionService"],
		SetTerritoryService = _optional["TerritoryService"],
		SetSecretService = _optional["SecretService"],
		SetAchievementService = _optional["AchievementService"],
	}
	for _, service in pairs(_optional) do
		wireAll(service, shared)
	end
	-- Core-loop services take the raid/mutation/event services too.
	if _optional["RaidService"] ~= nil then
		CarryService.SetRaidService(_optional["RaidService"])
		BaseService.SetRaidService(_optional["RaidService"])
	end
	if _optional["MutationService"] ~= nil then
		ConveyorService.SetMutationService(_optional["MutationService"])
		BaseService.SetMutationService(_optional["MutationService"])
	end
	if _optional["EventService"] ~= nil then
		-- v1.0.1 integration QA: Golden Hour's 2x income multiplier
		-- existed on EventService but BaseService never read it, so
		-- Golden Hour paid nothing. Wired here (SetEventService).
		BaseService.SetEventService(_optional["EventService"])
	end
end

-- RegisterKO(killer, victim): called by CombatService on every
-- player-vs-player KO. Forwards to EventService so the Chaos Arena
-- challenge can be scored (it tracks KOs per player while active).
-- v1.0.0: this method did not exist — CombatService's pcall-guarded
-- call silently did nothing, and the challenge never recorded a KO.
function GameManager.RegisterKO(killerPlayer: Player, victimPlayer: Player?)
	local eventService = _optional["EventService"]
	if eventService ~= nil and type(eventService.RecordKO) == "function" then
		pcall(function()
			eventService.RecordKO(killerPlayer)
		end)
	end
end

function GameManager.GetService(name: string): any
	if name == "ConveyorService" then
		return ConveyorService
	elseif name == "BaseService" then
		return BaseService
	elseif name == "CarryService" then
		return CarryService
	end
	return _optional[name]
end

function GameManager.GetOptionalServices(): { [string]: any }
	return _optional
end

function GameManager.Init(dataService: any, economyService: any, map: Model?): ()
	assert(dataService ~= nil, "[GameManager] Init requires DataService")
	assert(economyService ~= nil, "[GameManager] Init requires EconomyService")
	_dataService = dataService
	_economyService = economyService
	_map = map

	-- Core services, dependency order: Base -> Carry -> Conveyor.
	BaseService.Init(dataService, map)
	CarryService.Init(dataService, BaseService)
	ConveyorService.Init(dataService, economyService, map)

	-- Setter injection (avoids require cycles between the core services).
	ConveyorService.SetCarryService(CarryService)
	BaseService.SetCarryService(CarryService)
	ConveyorService.SetLuckProvider(function(): number
		return BaseService.GetMaxConveyorLuck()
	end)

	-- Respawn morph only: pcall-require CharacterService and Init it so
	-- ApplyCharacter can check ownership. If CharacterModels (its own
	-- dependency) has not landed yet, this warns and morphs stay off
	-- until the next server start.
	local charModule = script.Parent:FindFirstChild("CharacterService")
	if charModule ~= nil then
		local ok, service = pcall(require, charModule)
		if ok and type(service) == "table" then
			_characterService = service
			if not _characterServiceInit and type(service.Init) == "function" then
				-- Dot notation: Init takes just the DataService, no self.
				local initOk, initErr = pcall(service.Init, dataService)
				if initOk then
					_characterServiceInit = true
				else
					warn("[GameManager] CharacterService.Init failed: " .. tostring(initErr))
				end
			end
		else
			warn("[GameManager] CharacterService unavailable (CharacterModels may be missing): "
				.. tostring(service))
		end
	else
		warn("[GameManager] CharacterService module not found; respawn morph disabled")
	end

	-- Optional event / progression services (built in parallel).
	for _, name in ipairs(OPTIONAL_SERVICES) do
		loadOptional(name)
	end
	wireCrossLinks()

	-- Join / leave hooks (including players already in-game on reload).
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	-- Save everything on shutdown.
	if not RunService:IsStudio() then
		pcall(function()
			game:BindToClose(function()
				for _, player in ipairs(Players:GetPlayers()) do
					pcall(function()
						_dataService.SaveData(player)
					end)
				end
				task.wait(2)
			end)
		end)
	end

	print("[GameManager] Initialised (persistent world loop, no rounds)")
end

-- Persistent world loop: autosave + periodic leaderboard / status push.
-- No round timer, no win condition — the world just keeps running.
function GameManager.Start(): ()
	if _started then
		warn("[GameManager] Start called twice; ignoring")
		return
	end
	_started = true
	print("[GameManager] Persistent world loop started")

	local tick = 0
	while true do
		task.wait(10)
		tick += 10

		-- Leaderboard push every 30s: top coins, broadcast as a generic
		-- status update on RoundUpdate (the old round payload shape is
		-- reused as a status channel; Phase is always "Persistent").
		if tick % 30 == 0 then
			pcall(function()
				local rows: { { Name: string, Coins: number } } = {}
				for _, player in ipairs(Players:GetPlayers()) do
					local data = _dataService.GetData(player)
					if data ~= nil then
						table.insert(rows, {
							Name = player.Name,
							Coins = tonumber(data.Coins) or 0,
						})
					end
				end
				table.sort(rows, function(a, b)
					return a.Coins > b.Coins
				end)
				local top: { { Name: string, Coins: number } } = {}
				for i = 1, math.min(5, #rows) do
					table.insert(top, rows[i])
				end
				fireAll(Remotes.Names.RoundUpdate, {
					Phase = "Persistent",
					RoundNumber = 0,
					TimeLeft = 0,
					TopPlayers = top,
					PlayerCount = #Players:GetPlayers(),
				})
			end)
		end

		-- Autosave every Config.AutosaveInterval.
		local autosave = tonumber(Config.AutosaveInterval) or 120
		if tick % autosave == 0 then
			for _, player in ipairs(Players:GetPlayers()) do
				task.spawn(function()
					pcall(function()
						_dataService.SaveData(player)
					end)
				end)
			end
		end
	end
end

return GameManager
