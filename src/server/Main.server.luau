-- Main.server.luau
-- Glitch Tide — Brainrot Heist: The Memeverse — server entry point.
-- Creates remotes, builds the map, and wires every server service in order.
-- Services live in script.Parent.Services and are required by name.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

-- Create all RemoteEvents / RemoteFunctions before any service touches them.
Remotes.CreateRemotes(ReplicatedStorage)

local ServicesFolder = script.Parent:WaitForChild("Services")

local DataService = require(ServicesFolder:WaitForChild("DataService"))
local EconomyService = require(ServicesFolder:WaitForChild("EconomyService"))
local MapBuilder = require(ServicesFolder:WaitForChild("MapBuilder"))
local GameManager = require(ServicesFolder:WaitForChild("GameManager"))
local CombatService = require(ServicesFolder:WaitForChild("CombatService"))

-- 1. World first: the arena must exist before players spawn into it.
local arena = MapBuilder.Build()
print("[GlitchTide] MapBuilder built arena:", arena:GetFullName())

-- 2. Data layer.
DataService.Init()
print("[GlitchTide] DataService initialised")

-- 3. Economy layer (depends on DataService).
EconomyService.Init(DataService)
print("[GlitchTide] EconomyService initialised")

-- 4. Game loop (depends on DataService + EconomyService).
-- GameManager wires its own PlayerAdded / CharacterAdded handlers and
-- initialises the core loop (Base/Conveyor/Carry) plus all optional
-- services (Tide, Quests, Events, Mutation, Fusion, Abilities, Raids,
-- NPCs, Boss, Waves, Progression).
GameManager.Init(DataService, EconomyService, arena)
print("[GlitchTide] GameManager initialised")

-- 4b. Arena combat (melee + character primary abilities). Wired here
-- because it needs the GameManager instance; AbilityService (loaded by
-- GameManager) owns the 3-slot loadout powers and CombatService ignores
-- non-primary ability ids, so there is no double-apply.
local combatOk, combatErr = pcall(CombatService.Init, DataService, EconomyService, GameManager)
if combatOk then
	print("[GlitchTide] CombatService initialised")
else
	warn("[GlitchTide] CombatService.Init failed: " .. tostring(combatErr))
end

-- 5. Start the loop last, in its own thread so a loop error cannot kill startup.
task.spawn(function()
	local ok, err = pcall(function()
		GameManager.Start()
	end)
	if not ok then
		warn("[GlitchTide] GameManager.Start failed: " .. tostring(err))
	end
end)

print(string.format(
	"[GlitchTide] %s server started | MaxPlayers=%d | Persistent world (no rounds)",
	tostring(Config.GameName),
	Config.MaxPlayers
))

-- Keep the server script alive and surface late-joiner errors cleanly.
Players.PlayerAdded:Connect(function(player)
	-- DataService / GameManager already hook PlayerAdded themselves;
	-- this handler exists only so a failure in one hook is visible here.
	task.spawn(function()
		local ok, err = pcall(function()
			if DataService.GetData(player) == nil then
				DataService.LoadData(player)
			end
		end)
		if not ok then
			warn("[GlitchTide] Late data load failed for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end)
