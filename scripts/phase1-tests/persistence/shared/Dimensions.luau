--!strict
-- Dimensions.luau
-- Glitch Tide v1.1 (Workstream A) — shared dimension definitions.
-- Pure data + tiny helpers: safe to require from server and client.
-- Single source of truth for the two v1.1 regions (Abyssal Kingdom and
-- Skyfall Kingdom). MapBuilder builds the geometry FROM these defs and
-- DimensionsService runs the gameplay FROM these defs, so a position
-- can never drift between the map and the service.
--
-- NOTE on lighting moods: Lighting is a global service — one mood
-- applies to the whole server. A dimension's LightingMood is therefore
-- descriptive data (which mood best fits the region, for the shot list
-- and for explicit ApplyDimensionMood calls), NOT something applied
-- automatically per player on teleport. See DimensionsService.

local Dimensions = {}

export type HazardZone = {
	Name: string,
	Kind: string, -- "Current" (push + damage) | "Wind" (push only)
	Center: Vector3,
	Radius: number,
	Push: Vector3, -- studs/sec added to the root part velocity
	DamagePerSecond: number,
}

export type ChestDef = {
	Name: string,
	Title: string,
	Position: Vector3,
	Coins: number,
	XP: number,
	CooldownSeconds: number,
}

export type CheckpointDef = {
	Name: string,
	Position: Vector3,
}

export type DimensionDef = {
	Id: string,
	DisplayName: string,
	Description: string,
	HubPortalPosition: Vector3, -- portal ring in MemeversePlaza
	HubPortalYaw: number, -- radians; ring faces the plaza centre
	SpawnPosition: Vector3, -- where teleports land inside the region
	ReturnPortalPosition: Vector3, -- return portal inside the region
	LightingMood: string, -- LightingService mood name for this region
	ExclusiveCharacterId: string?, -- granted once, on the region's big feat
	Chests: { ChestDef },
	Hazards: { HazardZone },
	Checkpoints: { CheckpointDef },
	CheckpointTimeLimit: number, -- seconds to run all checkpoints
	CheckpointRewardCoins: number,
	CheckpointRewardXP: number,
	BossTriggerCooldownSeconds: number,
	FallReturnY: number?, -- below this Y the player is returned to hub
}

local HUB_ID = "hub"

-- Abyssal Kingdom: sunken basin in the south-west corner, centre
-- (-150, 0, 150). Underwater architecture, bioluminescent plants,
-- three treasure chests, three dangerous currents, a boss altar.
local ABYSSAL: DimensionDef = {
	Id = "abyssal",
	DisplayName = "Abyssal Kingdom",
	Description = "A sunken kingdom beneath a glass sea. Bioluminescent plants light drowned ruins; currents drag the unwary into the dark, and something old sleeps at the altar.",
	HubPortalPosition = Vector3.new(-26, 0, -6),
	HubPortalYaw = math.atan2(26, 6),
	SpawnPosition = Vector3.new(-150, 3, 136),
	ReturnPortalPosition = Vector3.new(-150, 0, 134),
	LightingMood = "Abyssal",
	ExclusiveCharacterId = "puddle_professor",
	Chests = {
		{
			Name = "TreasureChest1",
			Title = "Sunken Chest",
			Position = Vector3.new(-168, 1, 142),
			Coins = 150,
			XP = 25,
			CooldownSeconds = 300,
		},
		{
			Name = "TreasureChest2",
			Title = "Coral Chest",
			Position = Vector3.new(-132, 1, 162),
			Coins = 300,
			XP = 40,
			CooldownSeconds = 300,
		},
		{
			Name = "TreasureChest3",
			Title = "Drowned King's Chest",
			Position = Vector3.new(-166, 1, 170),
			Coins = 600,
			XP = 75,
			CooldownSeconds = 600,
		},
	},
	Hazards = {
		{
			Name = "CurrentZone1",
			Kind = "Current",
			Center = Vector3.new(-162, 2, 150),
			Radius = 8,
			Push = Vector3.new(-18, 0, 0),
			DamagePerSecond = 5,
		},
		{
			Name = "CurrentZone2",
			Kind = "Current",
			Center = Vector3.new(-138, 2, 150),
			Radius = 8,
			Push = Vector3.new(18, 0, 0),
			DamagePerSecond = 5,
		},
		{
			Name = "CurrentZone3",
			Kind = "Current",
			Center = Vector3.new(-150, 2, 164),
			Radius = 7,
			Push = Vector3.new(0, 0, 14),
			DamagePerSecond = 5,
		},
	},
	Checkpoints = {},
	CheckpointTimeLimit = 0,
	CheckpointRewardCoins = 0,
	CheckpointRewardXP = 0,
	BossTriggerCooldownSeconds = 600,
	FallReturnY = nil,
}

-- Skyfall Kingdom: floating islands above the north-east corner.
-- Island tops: main (150,46,-140), east (172,51,-156),
-- west (128,51,-160), summit (150,57,-176). Bridges link them; every
-- bridge climbs at most ~25 degrees so it stays walkable.
local SKYFALL: DimensionDef = {
	Id = "skyfall",
	DisplayName = "Skyfall Kingdom",
	Description = "Islands adrift in the open sky, chained by rope bridges. Crosswinds shove the careless off the edge, and a timed checkpoint run across all four islands pays in gold.",
	HubPortalPosition = Vector3.new(26, 0, 6),
	HubPortalYaw = math.atan2(-26, -6),
	SpawnPosition = Vector3.new(150, 48, -140),
	ReturnPortalPosition = Vector3.new(150, 46, -136),
	LightingMood = "Skyfall",
	ExclusiveCharacterId = "moon_mochi",
	Chests = {
		{
			Name = "SkyCache",
			Title = "Cloud Cache",
			Position = Vector3.new(128, 51, -156),
			Coins = 250,
			XP = 35,
			CooldownSeconds = 300,
		},
	},
	Hazards = {
		{
			Name = "WindZone1",
			Kind = "Wind",
			Center = Vector3.new(162, 49, -150),
			Radius = 6,
			Push = Vector3.new(0, 0, 20),
			DamagePerSecond = 0,
		},
		{
			Name = "WindZone2",
			Kind = "Wind",
			Center = Vector3.new(138, 54, -168),
			Radius = 6,
			Push = Vector3.new(20, 0, 0),
			DamagePerSecond = 0,
		},
	},
	Checkpoints = {
		{ Name = "Checkpoint1", Position = Vector3.new(150, 46.3, -146) },
		{ Name = "Checkpoint2", Position = Vector3.new(172, 51.3, -156) },
		{ Name = "Checkpoint3", Position = Vector3.new(128, 51.3, -160) },
		{ Name = "Checkpoint4", Position = Vector3.new(150, 57.3, -176) },
	},
	CheckpointTimeLimit = 90,
	CheckpointRewardCoins = 250,
	CheckpointRewardXP = 40,
	BossTriggerCooldownSeconds = 0,
	FallReturnY = 20,
}

local ALL: { DimensionDef } = { ABYSSAL, SKYFALL }

function Dimensions.GetHubId(): string
	return HUB_ID
end

function Dimensions.GetAll(): { DimensionDef }
	local copy: { DimensionDef } = {}
	for _, def in ipairs(ALL) do
		table.insert(copy, def)
	end
	return copy
end

function Dimensions.GetById(id: string): DimensionDef?
	for _, def in ipairs(ALL) do
		if def.Id == id then
			return def
		end
	end
	return nil
end

function Dimensions.GetChest(def: DimensionDef, chestName: string): ChestDef?
	for _, chest in ipairs(def.Chests) do
		if chest.Name == chestName then
			return chest
		end
	end
	return nil
end

return Dimensions
