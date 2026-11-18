--!strict
-- TideService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- The signature world event: every Config.GlitchTideIntervalSeconds the
-- tide runs Warning -> Tide -> Calm. A physical wave wall sweeps the
-- TideChannel; players outside a safe zone / base / shelter take damage
-- + stun and drop whatever they carry. Survivors are paid at the end.
--
-- v1.1 — TEN playable variations, each with REAL behaviour (wave-wall
-- profile, lighting mood, distinct hazard, distinct rewards, distinct
-- announcement). Double / Dark / GiantBoss are promoted out of the
-- v1.0.1 demoted table (Config.TideVariationsDisabled is deleted) and
-- Corrupted + Cosmic are new. No variant is a config entry alone.
--   Standard  — the baseline wave.          Fast     — 1.5x wave sweep.
--   Toxic     — channel DoT + toxic pools.   Frozen   — global + field slows.
--   Meteor    — falling meteors + collectible fallout.
--   Double    — TWO wave walls (anti-phase). Dark     — darkness + ambush spawns.
--   GiantBoss — THE GLITCH COLOSSUS spawns mid-tide.
--   Corrupted — glitch barriers + random teleports.
--   Cosmic    — low gravity + collectible starfall.
--
-- CINEMATIC 10-STAGE ANTICIPATION (Stage 1-5 inside the Warning window,
-- timed from Config.GlitchTideWarningSeconds; 6-10 across Active/Calm):
--   1 EnvironmentFlicker  2 StructureFlicker  3 Sirens  4 SkyChange
--   5 PlayerWarning  6 WaveEmerges  7 WaveTravels  8 Survival
--   9 Climax  10 Rewards. Every stage is broadcast on GlitchTideUpdate
--   (Stage / StageName fields); stage 5 also goes out on EventUpdate and
--   stage 3 fires the TideSiren SpawnEffect for the sound workstream.
--
-- NEW v1.1 MECHANICS: multiple escape routes (safe zones + base plots +
-- temporary shelters, all broadcast in the Warning payload), temporary
-- safe shelters spawned during Active, moving obstacles in the
-- TideChannel, tide surfing (IsTideSurfer/GrantSurfer hooks extended
-- with a surf-time bonus), glitch barriers (Corrupted), risk-and-reward
-- zones inside the wave path, tide-exclusive Brainrots (conveyor
-- ForceSpawn("Secret") during the tide + a rare flawless-survival
-- direct grant), ChaosShards per variant, co-op survival rewards
-- (2+ survivors = +25% coins/XP, +2 tokens), and a secret-encounter
-- roll (hidden merchant visit or secret Brainrot sighting — hook +
-- broadcast for the secrets workstream; see GetSecretEncounter).
--
-- v1.0.2 behaviour preserved: phase machine (Idle -> Warning -> Active
-- -> Calm), callbacks (DropCarried, GetSafeZones, SetGlitchMode,
-- IsTideSurfer/GrantSurfer), survivor payout logic, boss tide every
-- 5th tide, Frozen slow applied every tick (join/respawn-safe), meteor
-- immunity in safe zones / for Tide Surfers.
--
-- OPTIONAL DEPENDENCIES (all degrade gracefully):
--   * `map` (Init arg) may be nil or may lack a TideChannel / SafeZones /
--     Bases folder; waypoints and safe zones fall back to the arena
--     centre and the spawn/lobby area.
--   * callbacks.DropCarried(player) — CarryService hook; skipped when absent.
--   * callbacks.GetSafeZones() -> { {Position, Radius} } or { {Part} }.
--   * callbacks.SetGlitchMode(enabled) — conveyor glitch mode; skipped when absent.
--   * callbacks.IsTideSurfer(player) — AbilityService hook for the
--     Tide Surfer power; without it, TideService.GrantSurfer is the only
--     source of tide immunity.
--   * LightingService (script.Parent.LightingService) — SetMood(mood) when
--     present (another workstream's file; NOT present in v1.1, so the
--     built-in Lighting tween fallback below is what runs today).
--   * ConveyorService (SetConveyorService) — tide-exclusive spawns.
--   * NPCService (SetNPCService) — Dark-tide ambush spawns.
--   * EconomyService — NOT used for tide rewards, deliberately.
--     AUDIT §4f (verified by reading EconomyService): it has NO
--     AddCoins / AddGems / AddCurrency API at all — its whole public
--     API is Init / AwardKO / AwardWin / AwardWave / BuyCharacter /
--     GetBalance / NotifyBalance. So tide/boss rewards use the real
--     paths every other service uses: coins via
--     DataService.AddCoins(player, n); gems / ChaosShards /
--     EventTokens via direct field writes (data.Gems += n, etc.,
--     guarded with tonumber() or 0) + a PlayerStats push. There is no
--     SetEconomyService setter on this file on purpose.
-- No BaseService / CarryService / ConveyorService is required here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local TideService = {}

local _dataService: any = nil
local _map: Instance? = nil
local _callbacks: any = nil
local _questService: any = nil
local _progressionService: any = nil
local _bossService: any = nil
local _conveyorService: any = nil
local _npcService: any = nil
local _tideCount: number = 0

local _phase: string = "Idle" -- "Idle" | "Warning" | "Active" | "Calm"
local _timeLeft: number = 0
local _nextTideIn: number = Config.GlitchTideIntervalSeconds
local _variation: string = "Standard"
local _cycleActive: boolean = false
local _runToken: number = 0
local _incomeMultiplier: number = 1
local _stage: number = 0
local _stageName: string = ""
-- Secret encounter rolled for the current tide (nil when none rolled):
-- { Kind = "HiddenMerchant" | "SecretSighting", Variation = <id> }.
local _secretEncounter: { Kind: string, Variation: string }? = nil

-- player -> os.clock() until which they are immune (Tide Surfer power).
local _surfers: { [Player]: number } = {}
-- Humanoid -> true while a tide stun is active (prevents double-stun).
local _stunned: { [Humanoid]: boolean } = {}
-- Players hit at least once during the current tide.
local _hitThisTide: { [Player]: boolean } = {}
-- WalkSpeed overrides applied by the Frozen variation, for restore.
local _frozenSpeeds: { [Humanoid]: number } = {}
-- Risk-zone earnings banked during the current tide (paid at payout).
local _riskEarnings: { [Player]: number } = {}
-- Seconds each Tide Surfer has spent surfing the wave this tide.
local _surfTime: { [Player]: number } = {}

-- Temp objects spawned for the current tide; all destroyed in cleanup.
local _shelters: { Model } = {}
local _shelterParts: { BasePart } = {}
local _toxicPools: { { Position: Vector3, Radius: number, Part: BasePart } } = {}
local _slowFields: { { Position: Vector3, Radius: number, Part: BasePart } } = {}
local _barriers: { BasePart } = {}
local _obstacles: { { Part: BasePart, BaseX: number, BaseZ: number, Range: number, Speed: number, Phase: number } } = {}
local _riskZones: { { Position: Vector3, Radius: number, Part: BasePart } } = {}
local _pickups: { BasePart } = {}
local _ambushNPCs: { Model } = {}
local _origGravity: number? = nil

type VariationDef = {
	Weight: number,
	WaveSpeed: number,
	RewardMult: number,
	DamageMult: number,
	ChaosShards: number,
	Announcement: string,
}

-- Variation table: built from Config.TideVariations (single source of
-- truth) at load time; the literals below are only the fallback if
-- Config failed to load.
local VARIATIONS: { [string]: VariationDef } = {
	Standard = { Weight = 30, WaveSpeed = 1, RewardMult = 1, DamageMult = 1, ChaosShards = 1, Announcement = "GLITCH TIDE INCOMING!" },
	Fast = { Weight = 15, WaveSpeed = 1.5, RewardMult = 1.25, DamageMult = 1, ChaosShards = 1, Announcement = "FAST TIDE!" },
	Toxic = { Weight = 12, WaveSpeed = 1, RewardMult = 1.5, DamageMult = 1.25, ChaosShards = 2, Announcement = "TOXIC TIDE!" },
	Frozen = { Weight = 12, WaveSpeed = 0.7, RewardMult = 1.5, DamageMult = 1, ChaosShards = 2, Announcement = "FROZEN TIDE!" },
	Meteor = { Weight = 10, WaveSpeed = 1, RewardMult = 1.75, DamageMult = 1.5, ChaosShards = 3, Announcement = "METEOR TIDE!" },
	Double = { Weight = 8, WaveSpeed = 1.25, RewardMult = 2, DamageMult = 1, ChaosShards = 4, Announcement = "DOUBLE TIDE — TWO WALLS!" },
	Dark = { Weight = 6, WaveSpeed = 1.25, RewardMult = 1.75, DamageMult = 1.25, ChaosShards = 3, Announcement = "DARK TIDE!" },
	GiantBoss = { Weight = 4, WaveSpeed = 0.8, RewardMult = 3, DamageMult = 2, ChaosShards = 5, Announcement = "GIANT BOSS TIDE!" },
	Corrupted = { Weight = 2, WaveSpeed = 1.1, RewardMult = 2.25, DamageMult = 1.5, ChaosShards = 4, Announcement = "CORRUPTED TIDE!" },
	Cosmic = { Weight = 1, WaveSpeed = 0.9, RewardMult = 2.5, DamageMult = 1.25, ChaosShards = 5, Announcement = "COSMIC TIDE!" },
}

local function loadVariationsFromConfig()
	-- Config is already required at the top of this file; rebuild the
	-- table from it so Config stays the single source of truth.
	if type(Config.TideVariations) ~= "table" then
		return
	end
	local config = Config
	local loaded: { [string]: VariationDef } = {}
	local count = 0
	for id, def in pairs(config.TideVariations) do
		if type(def) == "table" then
			loaded[id] = {
				Weight = tonumber(def.Weight) or 10,
				WaveSpeed = tonumber(def.SpeedMultiplier) or 1,
				RewardMult = tonumber(def.RewardMultiplier) or 1,
				DamageMult = tonumber(def.Damage) or 1,
				ChaosShards = tonumber(def.ChaosShards) or 0,
				Announcement = type(def.Announcement) == "string" and def.Announcement or "",
			}
			count += 1
		end
	end
	if count > 0 then
		VARIATIONS = loaded
	end
end
loadVariationsFromConfig()

-- Per-variant presentation: lighting mood (see MOODS below) + wave colour.
local VARIATION_STYLE: { [string]: { Mood: string, WaveColor: Color3 } } = {
	Standard = { Mood = "TideActive", WaveColor = Color3.fromRGB(120, 80, 255) },
	Fast = { Mood = "TideActive", WaveColor = Color3.fromRGB(255, 140, 40) },
	Toxic = { Mood = "Toxic", WaveColor = Color3.fromRGB(80, 255, 90) },
	Frozen = { Mood = "Frozen", WaveColor = Color3.fromRGB(140, 220, 255) },
	Meteor = { Mood = "Meteor", WaveColor = Color3.fromRGB(255, 90, 40) },
	Double = { Mood = "TideActive", WaveColor = Color3.fromRGB(120, 80, 255) },
	Dark = { Mood = "Dark", WaveColor = Color3.fromRGB(40, 20, 70) },
	GiantBoss = { Mood = "Boss", WaveColor = Color3.fromRGB(255, 40, 60) },
	Corrupted = { Mood = "TideActive", WaveColor = Color3.fromRGB(255, 40, 220) },
	Cosmic = { Mood = "Cosmic", WaveColor = Color3.fromRGB(140, 240, 255) },
}

-- Lighting moods. "Hub" restores the pre-tide lighting captured on the
-- first mood change. Moods are passed to LightingService.SetMood when
-- that service exists; otherwise the tween fallback below applies the
-- same values directly to game.Lighting.
local MOODS: { [string]: { Ambient: Color3, OutdoorAmbient: Color3, Brightness: number, FogColor: Color3, FogEnd: number } } = {
	Hub = { Ambient = Color3.fromRGB(90, 90, 110), OutdoorAmbient = Color3.fromRGB(110, 110, 130), Brightness = 2, FogColor = Color3.fromRGB(150, 120, 220), FogEnd = 900 },
	TideWarning = { Ambient = Color3.fromRGB(110, 60, 40), OutdoorAmbient = Color3.fromRGB(90, 50, 40), Brightness = 1.4, FogColor = Color3.fromRGB(200, 120, 80), FogEnd = 500 },
	TideActive = { Ambient = Color3.fromRGB(60, 30, 110), OutdoorAmbient = Color3.fromRGB(40, 20, 80), Brightness = 1, FogColor = Color3.fromRGB(90, 60, 160), FogEnd = 400 },
	Toxic = { Ambient = Color3.fromRGB(30, 110, 40), OutdoorAmbient = Color3.fromRGB(20, 80, 30), Brightness = 1, FogColor = Color3.fromRGB(60, 160, 60), FogEnd = 300 },
	Frozen = { Ambient = Color3.fromRGB(120, 170, 220), OutdoorAmbient = Color3.fromRGB(140, 190, 240), Brightness = 1.2, FogColor = Color3.fromRGB(180, 220, 255), FogEnd = 350 },
	Meteor = { Ambient = Color3.fromRGB(110, 40, 20), OutdoorAmbient = Color3.fromRGB(90, 30, 20), Brightness = 1.1, FogColor = Color3.fromRGB(200, 90, 50), FogEnd = 350 },
	Dark = { Ambient = Color3.fromRGB(8, 8, 16), OutdoorAmbient = Color3.fromRGB(5, 5, 12), Brightness = 0.4, FogColor = Color3.fromRGB(10, 10, 20), FogEnd = 120 },
	Cosmic = { Ambient = Color3.fromRGB(40, 30, 110), OutdoorAmbient = Color3.fromRGB(30, 20, 90), Brightness = 1.3, FogColor = Color3.fromRGB(80, 60, 200), FogEnd = 600 },
	Boss = { Ambient = Color3.fromRGB(110, 20, 20), OutdoorAmbient = Color3.fromRGB(80, 15, 15), Brightness = 0.9, FogColor = Color3.fromRGB(160, 40, 40), FogEnd = 300 },
}

local TIDE_DAMAGE = 12
local TOXIC_DOT = 6
local METEOR_DAMAGE = 25
local OBSTACLE_DAMAGE = 5
local SURVIVOR_COINS = 100
local SURVIVOR_XP = 50
local SURVIVOR_TOKENS = 5

-- ---------------------------------------------------------------------------
-- Remote helpers (remotes live in ReplicatedStorage.Remotes; the Remotes
-- module itself only carries names, so look instances up by name).
-- ---------------------------------------------------------------------------

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

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Data helpers (all new fields defaulted defensively; old saves lack them).
-- ---------------------------------------------------------------------------

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

local function pushStats(player: Player, extra: { [string]: any }?)
	local data = getData(player)
	if not data then
		return
	end
	local payload: { [string]: any } = {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		EventTokens = data.EventTokens,
		ChaosShards = data.ChaosShards,
	}
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	fireClient(_names.PlayerStats, player, payload)
end

-- Tide-exclusive Brainrot grant: a random Secret / Divine character the
-- player does not own yet (falls back to any Secret/Divine when they
-- own them all). Returns the granted Id or nil.
local function grantTideExclusive(player: Player): string?
	local data = getData(player)
	if not data then
		return nil
	end
	local owned: { [string]: boolean } = {}
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			owned[id] = true
		end
	end
	local pool: { string } = {}
	for _, rarity in ipairs({ "Secret", "Divine" }) do
		local ok, defs = pcall(function()
			return Characters.GetByRarity(rarity)
		end)
		if ok and type(defs) == "table" then
			for _, def in ipairs(defs) do
				if not owned[def.Id] then
					table.insert(pool, def.Id)
				end
			end
		end
	end
	if #pool == 0 then
		for _, rarity in ipairs({ "Secret", "Divine" }) do
			local ok, defs = pcall(function()
				return Characters.GetByRarity(rarity)
			end)
			if ok and type(defs) == "table" then
				for _, def in ipairs(defs) do
					table.insert(pool, def.Id)
				end
			end
		end
	end
	if #pool == 0 then
		return nil
	end
	local granted = pool[math.random(1, #pool)]
	local ok = pcall(function()
		return _dataService.UnlockCharacter(player, granted)
	end)
	if not ok then
		return nil
	end
	return granted
end

type SurvivorOpts = {
	Coop: boolean,
	MerchantBonus: boolean,
}

local function awardSurvivor(player: Player, neverHit: boolean, rewardMult: number, opts: SurvivorOpts?)
	local data = getData(player)
	if not data then
		return
	end
	local variation = VARIATIONS[_variation] or VARIATIONS.Standard
	local riskCoins = math.floor(_riskEarnings[player] or 0)
	local surfSeconds = _surfTime[player] or 0
	local surfBlocks = math.floor(surfSeconds / 5)
	local surfCoins = math.floor(surfBlocks * 10 * rewardMult + 0.5)
	local surfShards = math.floor(surfSeconds / 15)
	local coins = math.floor(SURVIVOR_COINS * rewardMult + 0.5) + riskCoins + surfCoins
	local xp = math.floor(SURVIVOR_XP * rewardMult + 0.5)
	local tokens = SURVIVOR_TOKENS
	if neverHit then
		tokens += SURVIVOR_TOKENS -- flawless-survival bonus
	end
	if opts and opts.Coop then
		-- Co-op survival: 2+ survivors share the tide.
		coins = math.floor(coins * 1.25 + 0.5)
		xp = math.floor(xp * 1.25 + 0.5)
		tokens += 2
	end
	if opts and opts.MerchantBonus then
		tokens += 5 -- hidden merchant visited this tide
	end
	-- Event materials: per-variant ChaosShards + surfing shards.
	-- (No EconomyService shard API exists — direct field write, the
	-- same path v1.0.2 used; see the header note / audit §4f.)
	data.ChaosShards = (tonumber(data.ChaosShards) or 0) + (variation.ChaosShards or 0) + surfShards
	-- Rare tide-exclusive grant: flawless survivors get a 10% roll at
	-- a Secret / Divine Brainrot they do not own yet.
	local exclusiveGranted: string? = nil
	if neverHit and math.random() < 0.10 then
		exclusiveGranted = grantTideExclusive(player)
	end
	pcall(function()
		_dataService.AddCoins(player, coins)
	end)
	-- XP goes through ProgressionService when linked so level-ups pay
	-- their rewards (DataService.AddXP alone never levels anyone up);
	-- otherwise fall back to the raw add.
	if _progressionService and type(_progressionService.AddXP) == "function" then
		pcall(function()
			_progressionService.AddXP(player, xp)
		end)
	else
		pcall(function()
			_dataService.AddXP(player, xp)
		end)
	end
	data.EventTokens = (tonumber(data.EventTokens) or 0) + tokens
	pushStats(player, { TideExclusive = exclusiveGranted })
	print(string.format(
		"[TideService] Survivor %s: +%d coins, +%d XP, +%d tokens, +%d shards (%s%s%s)",
		player.Name, coins, xp, tokens,
		(variation.ChaosShards or 0) + surfShards, _variation,
		riskCoins > 0 and (", risk +" .. tostring(riskCoins)) or "",
		exclusiveGranted and (", EXCLUSIVE: " .. exclusiveGranted) or ""
	))
end

-- ---------------------------------------------------------------------------
-- World queries (map-agnostic: every lookup has a fallback).
-- ---------------------------------------------------------------------------

local function pointInPart(part: BasePart, point: Vector3): boolean
	local localPos = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Y) <= half.Y
		and math.abs(localPos.Z) <= half.Z
end

-- Waypoints for the wave path: a "TideChannel" folder in the map (or in
-- Workspace) whose parts are ordered by name, else a straight sweep
-- across the arena centre (z = -60 -> +60).
local function getWaypoints(): { Vector3 }
	local channel: Instance? = nil
	if _map then
		channel = _map:FindFirstChild("TideChannel")
	end
	if not channel then
		channel = workspace:FindFirstChild("TideChannel")
	end
	if channel then
		local points: { BasePart } = {}
		for _, child in ipairs(channel:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(points, child)
			end
		end
		table.sort(points, function(a, b)
			return a.Name < b.Name
		end)
		if #points >= 2 then
			local out: { Vector3 } = {}
			for _, part in ipairs(points) do
				table.insert(out, part.Position)
			end
			return out
		end
	end
	return { Vector3.new(0, 3, -60), Vector3.new(0, 3, 60) }
end

-- Channel bounds (for the Toxic DoT): min/max of the waypoint path,
-- padded, or the default arena rect.
local function getChannelBounds(): (Vector3, Vector3)
	local points = getWaypoints()
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(points) do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z)
		maxZ = math.max(maxZ, p.Z)
	end
	local pad = 35
	return Vector3.new(minX - pad, 0, minZ - pad), Vector3.new(maxX + pad, 0, maxZ + pad)
end

local function getSafeZoneParts(): { BasePart }
	local parts: { BasePart } = {}
	local folder: Instance? = nil
	if _map then
		folder = _map:FindFirstChild("SafeZones")
	end
	if not folder then
		folder = workspace:FindFirstChild("SafeZones")
	end
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(parts, child)
			end
		end
	end
	-- Base plots are safe zones too: a "Bases" folder whose children are
	-- per-player plots (named by UserId or player Name) containing parts.
	local bases: Instance? = nil
	if _map then
		bases = _map:FindFirstChild("Bases")
	end
	if not bases then
		bases = workspace:FindFirstChild("Bases")
	end
	if bases then
		for _, plot in ipairs(bases:GetChildren()) do
			for _, descendant in ipairs(plot:GetDescendants()) do
				if descendant:IsA("BasePart") and descendant.Name == "Plot" then
					table.insert(parts, descendant)
				end
			end
		end
	end
	-- Temporary tide shelters count as safe zones while they stand.
	for _, part in ipairs(_shelterParts) do
		table.insert(parts, part)
	end
	return parts
end

local function getRootPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

-- ---------------------------------------------------------------------------
-- Public queries
-- ---------------------------------------------------------------------------

function TideService.GetState(): { Phase: string, TimeLeft: number, NextTideIn: number, Variation: string, IncomeMultiplier: number, Stage: number, StageName: string }
	return {
		Phase = _phase,
		TimeLeft = math.max(0, math.floor(_timeLeft)),
		NextTideIn = math.max(0, math.floor(_nextTideIn)),
		Variation = _variation,
		IncomeMultiplier = _incomeMultiplier,
		Stage = _stage,
		StageName = _stageName,
	}
end

function TideService.GetVariation(): string
	return _variation
end

function TideService.GetStage(): (number, string)
	return _stage, _stageName
end

function TideService.IsTideActive(): boolean
	return _phase == "Warning" or _phase == "Active"
end

function TideService.GetIncomeMultiplier(): number
	return _incomeMultiplier
end

-- GetSecretEncounter(): the secret encounter rolled for the current (or
-- most recent) tide, or nil. Hook for the secrets workstream: the
-- encounter is also broadcast on EventUpdate + SpawnEffect when it
-- rolls (Stage 5). Kind is "HiddenMerchant" or "SecretSighting".
function TideService.GetSecretEncounter(): { Kind: string, Variation: string }?
	return _secretEncounter
end

-- GetEscapeRoutes(): every escape route for the current tide — MapBuilder
-- safe zones (shelters / escape platforms), base plots, callback safe
-- zones, and any temporary tide shelters standing right now. Clients
-- render these from the Warning payload; players pick a route.
function TideService.GetEscapeRoutes(): { { Position: Vector3, Radius: number, Kind: string } }
	local routes: { { Position: Vector3, Radius: number, Kind: string } } = {}
	-- MapBuilder safe zones (escape platforms + built shelters).
	pcall(function()
		local ok, mod = pcall(function()
			return script.Parent:FindFirstChild("MapBuilder")
		end)
		if ok and mod then
			local builder: any = require(mod)
			if builder and type(builder.GetSafeZones) == "function" then
				for _, zone in ipairs(builder.GetSafeZones()) do
					table.insert(routes, {
						Position = zone.Position,
						Radius = tonumber(zone.Radius) or 7,
						Kind = "SafeZone",
					})
				end
			end
			if builder and type(builder.GetBasePlots) == "function" then
				for _, plot in pairs(builder.GetBasePlots()) do
					if type(plot) == "table" and typeof(plot.Center) == "Vector3" then
						table.insert(routes, {
							Position = plot.Center,
							Radius = 12,
							Kind = "BasePlot",
						})
					end
				end
			end
		end
	end)
	-- Callback safe zones (GameManager wires MapBuilder zones + plots
	-- here too; kept so a custom provider still shows up).
	if _callbacks and type(_callbacks.GetSafeZones) == "function" then
		local ok, zones = pcall(function()
			return _callbacks.GetSafeZones()
		end)
		if ok and type(zones) == "table" then
			for _, zone in ipairs(zones) do
				if type(zone) == "table" and typeof(zone.Position) == "Vector3" then
					table.insert(routes, {
						Position = zone.Position,
						Radius = tonumber(zone.Radius) or 7,
						Kind = "SafeZone",
					})
				end
			end
		end
	end
	-- Temporary tide shelters standing right now.
	for _, part in ipairs(_shelterParts) do
		table.insert(routes, {
			Position = part.Position,
			Radius = 8,
			Kind = "TideShelter",
		})
	end
	return routes
end

-- GrantSurfer(player, durationSeconds): Tide Surfer power immunity.
function TideService.GrantSurfer(player: Player, durationSeconds: number)
	if not player or not player:IsA("Player") then
		return
	end
	_surfers[player] = os.clock() + math.max(1, tonumber(durationSeconds) or 60)
end

function TideService.IsSurfer(player: Player): boolean
	local untilTime = _surfers[player]
	if untilTime ~= nil and os.clock() < untilTime then
		return true
	end
	-- AbilityService also stamps a TideSurferUntil attribute on the
	-- character (its local immunity works even when the two services
	-- were never wired together by GameManager).
	local character = player.Character
	if character then
		local attrUntil = character:GetAttribute("TideSurferUntil")
		if type(attrUntil) == "number" and os.clock() < attrUntil then
			return true
		end
	end
	-- AbilityService hook (when the Init callbacks carry it).
	if _callbacks and type(_callbacks.IsTideSurfer) == "function" then
		local ok, result = pcall(function()
			return _callbacks.IsTideSurfer(player)
		end)
		if ok and result == true then
			return true
		end
	end
	return false
end

-- IsInSafeZone(player): inside a SafeZones part, inside any base plot,
-- inside a temporary tide shelter, or inside a callback-provided safe
-- zone (position+radius or part).
function TideService.IsInSafeZone(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local pos = root.Position
	for _, part in ipairs(getSafeZoneParts()) do
		if pointInPart(part, pos) then
			return true
		end
	end
	if _callbacks and type(_callbacks.GetSafeZones) == "function" then
		local ok, zones = pcall(function()
			return _callbacks.GetSafeZones()
		end)
		if ok and type(zones) == "table" then
			for _, zone in ipairs(zones) do
				if type(zone) == "table" then
					if zone.Part and typeof(zone.Part) == "Instance" and zone.Part:IsA("BasePart") then
						if pointInPart(zone.Part, pos) then
							return true
						end
					elseif typeof(zone.Position) == "Vector3" and tonumber(zone.Radius) then
						if (pos - zone.Position).Magnitude <= (zone.Radius :: number) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local function isInZoneList(zones: { { Position: Vector3, Radius: number, Part: BasePart } }, pos: Vector3): boolean
	for _, zone in ipairs(zones) do
		if (pos - zone.Position).Magnitude <= zone.Radius then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Wave model + lighting moods + stage broadcasts
-- ---------------------------------------------------------------------------

local _origLighting: { [string]: any } = {}

-- setMood(mood): LightingService.SetMood when that service exists
-- (another workstream's file — absent in v1.1), else tween
-- game.Lighting directly from the MOODS table. "Hub" restores the
-- pre-tide lighting captured on the first mood change. Never errors.
local function setMood(mood: string)
	-- Try the dedicated service first.
	local tried = false
	local handled = false
	pcall(function()
		local mod = script.Parent:FindFirstChild("LightingService")
		if mod then
			tried = true
			local service: any = require(mod)
			if service and type(service.SetMood) == "function" then
				local ok = pcall(service.SetMood, mood)
				handled = ok == true
			end
		end
	end)
	if tried and handled then
		return
	end
	-- Fallback: direct Lighting tween.
	pcall(function()
		if next(_origLighting) == nil then
			_origLighting.Ambient = Lighting.Ambient
			_origLighting.OutdoorAmbient = Lighting.OutdoorAmbient
			_origLighting.Brightness = Lighting.Brightness
			_origLighting.FogColor = Lighting.FogColor
			_origLighting.FogEnd = Lighting.FogEnd
		end
		local props: { [string]: any } = {}
		if mood == "Hub" then
			props = _origLighting
		else
			local def = MOODS[mood]
			if not def then
				return
			end
			props = {
				Ambient = def.Ambient,
				OutdoorAmbient = def.OutdoorAmbient,
				Brightness = def.Brightness,
				FogColor = def.FogColor,
				FogEnd = def.FogEnd,
			}
		end
		if next(props) ~= nil then
			local tween = TweenService:Create(Lighting, TweenInfo.new(2, Enum.EasingStyle.Quad), props)
			tween:Play()
		end
	end)
end

local function buildWaveModel(waveColor: Color3): Model
	local model = Instance.new("Model")
	model.Name = "GlitchTideWave"
	-- A wall of semi-transparent segments spanning the channel.
	for i = 1, 11 do
		local part = Instance.new("Part")
		part.Name = "WaveSegment" .. tostring(i)
		part.Size = Vector3.new(7, 18, 4)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.Transparency = 0.45
		part.Material = Enum.Material.Neon
		part.Color = waveColor
		part.CFrame = CFrame.new((i - 6) * 7, 9, 0)
		part.Parent = model
	end
	local glow = Instance.new("PointLight")
	glow.Name = "WaveGlow"
	glow.Color = waveColor
	glow.Range = 30
	glow.Brightness = 2
	glow.Parent = model:FindFirstChild("WaveSegment6")
	return model
end

-- Position the wave model on the path at `progress` (0..1) facing along it.
local function placeWave(model: Model, waypoints: { Vector3 }, progress: number): Vector3
	local clamped = math.clamp(progress, 0, 1)
	local segments = #waypoints - 1
	if segments < 1 then
		return Vector3.new(0, 3, 0)
	end
	local scaled = clamped * segments
	local index = math.min(math.floor(scaled) + 1, segments)
	local t = scaled - (index - 1)
	local a = waypoints[index]
	local b = waypoints[index + 1]
	local pos = a:Lerp(b, t)
	local dir = b - a
	if dir.Magnitude < 0.01 then
		dir = Vector3.new(0, 0, 1)
	end
	model:PivotTo(CFrame.lookAt(pos, pos + Vector3.new(dir.X, 0, dir.Z)))
	return pos
end

local function broadcast(payload: any)
	fireAll(_names.GlitchTideUpdate, payload)
end

-- broadcastStage(stage, name, extra): every cinematic stage goes out on
-- GlitchTideUpdate (Stage / StageName); stage 5 also goes out on
-- EventUpdate so the HUD banner shows the warning.
local function broadcastStage(stage: number, name: string, extra: { [string]: any }?)
	_stage = stage
	_stageName = name
	local payload: { [string]: any } = {
		Phase = _phase,
		TimeLeft = math.max(0, math.floor(_timeLeft)),
		NextTideIn = 0,
		Variation = _variation,
		IncomeMultiplier = _incomeMultiplier,
		Stage = stage,
		StageName = name,
	}
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	broadcast(payload)
	if stage == 5 then
		fireAll(_names.EventUpdate, {
			EventId = "glitch_tide",
			Name = "Glitch Tide: " .. _variation,
			Phase = "Started",
			Duration = math.max(0, math.floor(_timeLeft)),
			IncomeMultiplier = Config.GlitchTideIncomeMultiplier or 2,
			Announcement = (VARIATIONS[_variation] or VARIATIONS.Standard).Announcement,
		})
	end
end

-- Stage 1 — environment flicker: the whole world's light stutters.
local function flickerEnvironment()
	task.spawn(function()
		local base = Lighting.Brightness
		for _ = 1, 3 do
			pcall(function()
				Lighting.Brightness = 0.4
			end)
			task.wait(0.15)
			pcall(function()
				Lighting.Brightness = base
			end)
			task.wait(0.15)
		end
	end)
end

-- Stage 2 — distant structure flicker: Neon parts of the built world
-- (via the map model / Workspace, read-only) blink. Capped so a huge
-- world cannot stall the warning.
local function flickerStructures()
	task.spawn(function()
		local root: Instance? = _map
		if not root then
			root = workspace:FindFirstChild("GlitchTideWorld")
		end
		if not root then
			return
		end
		local parts: { BasePart } = {}
		pcall(function()
			for _, descendant in ipairs(root:GetDescendants()) do
				if descendant:IsA("BasePart") and descendant.Material == Enum.Material.Neon then
					table.insert(parts, descendant)
					if #parts >= 40 then
						break
					end
				end
			end
		end)
		if #parts == 0 then
			return
		end
		local originals: { [BasePart]: number } = {}
		for _, part in ipairs(parts) do
			originals[part] = part.Transparency
		end
		for _ = 1, 2 do
			for _, part in ipairs(parts) do
				pcall(function()
					part.Transparency = 0.9
				end)
			end
			task.wait(0.2)
			for _, part in ipairs(parts) do
				pcall(function()
					part.Transparency = originals[part] or 0
				end)
			end
			task.wait(0.2)
		end
	end)
end

local function applyStun(player: Player, duration: number)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or _stunned[humanoid] then
		return
	end
	_stunned[humanoid] = true
	local originalSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = 0
	character:SetAttribute("TideStunned", true)
	task.delay(duration, function()
		_stunned[humanoid] = nil
		if humanoid.Parent then
			character:SetAttribute("TideStunned", false)
			humanoid.WalkSpeed = originalSpeed
		end
	end)
end

-- Collectible pickup (Meteor fallout / Cosmic starfall). Touching it
-- pays the collector immediately; each part pays once, then vanishes.
local function spawnPickup(kind: string, position: Vector3)
	local part = Instance.new("Part")
	part.Name = kind == "Starfall" and "CosmicStarfall" or "MeteorFallout"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(3, 3, 3)
	part.Material = Enum.Material.Neon
	part.Color = kind == "Starfall" and Color3.fromRGB(180, 240, 255) or Color3.fromRGB(255, 180, 60)
	part.Anchored = true
	part.CanCollide = false
	part.Position = position + Vector3.new(0, 2, 0)
	part.Parent = workspace
	local glow = Instance.new("PointLight")
	glow.Color = part.Color
	glow.Range = 10
	glow.Brightness = 2
	glow.Parent = part
	table.insert(_pickups, part)
	Debris:AddItem(part, 25)
	local claimed = false
	part.Touched:Connect(function(hit)
		if claimed then
			return
		end
		local model = hit:FindFirstAncestorOfClass("Model")
		if not model then
			return
		end
		local player = Players:GetPlayerFromCharacter(model)
		if not player then
			return
		end
		claimed = true
		local data = getData(player)
		if data then
			data.ChaosShards = (tonumber(data.ChaosShards) or 0) + 1
			if kind == "Starfall" then
				pcall(function()
					_dataService.AddCoins(player, 25)
				end)
			end
			pushStats(player, { Pickup = kind })
			print(string.format("[TideService] %s collected %s (+1 Chaos Shard)", player.Name, kind))
		end
		pcall(function()
			part:Destroy()
		end)
	end)
	fireAll(_names.SpawnEffect, { type = kind, position = position })
end

local function spawnMeteor()
	local x = math.random(-50, 50)
	local z = math.random(-50, 50)
	local meteor = Instance.new("Part")
	meteor.Name = "TideMeteor"
	meteor.Shape = Enum.PartType.Ball
	meteor.Size = Vector3.new(math.random(2, 4), math.random(2, 4), math.random(2, 4))
	meteor.Material = Enum.Material.Neon
	meteor.Color = Color3.fromRGB(255, 90, 40)
	meteor.Anchored = false
	meteor.CanCollide = true
	meteor.Position = Vector3.new(x, 70, z)
	meteor.Parent = workspace
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 120, 40)
	glow.Range = 12
	glow.Brightness = 2
	glow.Parent = meteor
	Debris:AddItem(meteor, 10)
	local touched: { [Humanoid]: boolean } = {}
	meteor.Touched:Connect(function(hit)
		local model = hit:FindFirstAncestorOfClass("Model")
		if not model then
			return
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and not touched[humanoid] then
			touched[humanoid] = true
			-- Meteors are tide damage: safe zones and Tide Surfers are immune.
			local owner = Players:GetPlayerFromCharacter(model)
			if owner and (TideService.IsInSafeZone(owner) or TideService.IsSurfer(owner)) then
				return
			end
			pcall(function()
				humanoid:TakeDamage(math.floor(METEOR_DAMAGE * (VARIATIONS[_variation] and VARIATIONS[_variation].DamageMult or 1) + 0.5))
			end)
			return
		end
		-- No Humanoid hit: the meteor struck the world — leave
		-- collectible fallout where it landed (Meteor tide only).
		if _variation == "Meteor" and meteor.Parent then
			local pos = meteor.Position
			task.spawn(function()
				spawnPickup("MeteorFallout", Vector3.new(pos.X, 1, pos.Z))
			end)
		end
	end)
	fireAll(_names.SpawnEffect, {
		type = "Meteor",
		position = Vector3.new(x, 60, z),
	})
end

local function pickVariation(): string
	local total = 0
	for _, def in pairs(VARIATIONS) do
		total += def.Weight
	end
	local roll = math.random(1, total)
	local acc = 0
	for id, def in pairs(VARIATIONS) do
		acc += def.Weight
		if roll <= acc then
			return id
		end
	end
	return "Standard"
end

-- ---------------------------------------------------------------------------
-- v1.1 hazard / structure spawners (all cleaned up when the tide ends).
-- ---------------------------------------------------------------------------

local function makeZonePart(name: string, position: Vector3, size: Vector3, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = 0.5
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Position = position
	part.Parent = workspace
	return part
end

-- Toxic: damage-over-time pools scattered across the channel.
local function spawnToxicPools()
	local minBound, maxBound = getChannelBounds()
	for _ = 1, 3 do
		local pos = Vector3.new(
			math.random(math.floor(minBound.X), math.floor(maxBound.X)),
			1,
			math.random(math.floor(minBound.Z), math.floor(maxBound.Z))
		)
		local part = makeZonePart("ToxicPool", pos, Vector3.new(14, 1, 14), Color3.fromRGB(60, 255, 80))
		table.insert(_toxicPools, { Position = pos, Radius = 8, Part = part })
	end
	fireAll(_names.SpawnEffect, { type = "ToxicPools", count = #_toxicPools })
end

-- Frozen: slow fields — standing in one nearly stops you.
local function spawnSlowFields()
	local minBound, maxBound = getChannelBounds()
	for _ = 1, 3 do
		local pos = Vector3.new(
			math.random(math.floor(minBound.X), math.floor(maxBound.X)),
			1,
			math.random(math.floor(minBound.Z), math.floor(maxBound.Z))
		)
		local part = makeZonePart("SlowField", pos, Vector3.new(14, 1, 14), Color3.fromRGB(140, 220, 255))
		table.insert(_slowFields, { Position = pos, Radius = 8, Part = part })
	end
	fireAll(_names.SpawnEffect, { type = "SlowFields", count = #_slowFields })
end

-- Corrupted: glitch barriers across the channel. Touching one throws
-- the player to a random escape route (see barrier Touched below).
local function spawnBarriers()
	local waypoints = getWaypoints()
	local mid = waypoints[math.floor(#waypoints / 2) + 1] or Vector3.new(0, 3, 75)
	for _, x in ipairs({ -60, 0, 60 }) do
		local part = Instance.new("Part")
		part.Name = "GlitchBarrier"
		part.Size = Vector3.new(4, 12, 2)
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 0.3
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 40, 220)
		part.Position = Vector3.new(mid.X + x, 6, mid.Z)
		part.Parent = workspace
		table.insert(_barriers, part)
		local lastTeleport: { [Humanoid]: number } = {}
		part.Touched:Connect(function(hit)
			local model = hit:FindFirstAncestorOfClass("Model")
			if not model then
				return
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
				return
			end
			local now = os.clock()
			if now - (lastTeleport[humanoid] or -math.huge) < 3 then
				return
			end
			lastTeleport[humanoid] = now
			local routes = TideService.GetEscapeRoutes()
			local dest: Vector3? = nil
			if #routes > 0 then
				dest = routes[math.random(1, #routes)].Position
			end
			if dest then
				pcall(function()
					root.CFrame = CFrame.new(dest + Vector3.new(0, 3, 0))
				end)
				local player = Players:GetPlayerFromCharacter(model)
				if player then
					fireClient(_names.SpawnEffect, player, { type = "GlitchTeleport", position = dest })
					print(string.format("[TideService] Glitch barrier threw %s to a safe zone", player.Name))
				end
			end
		end)
	end
	fireAll(_names.SpawnEffect, { type = "GlitchBarriers", count = #_barriers })
end

-- Moving obstacles in the TideChannel: heavy glitch blocks sliding
-- along the channel that knock players they touch (5 damage + shove).
local function spawnObstacles()
	local waypoints = getWaypoints()
	local mid = waypoints[math.floor(#waypoints / 2) + 1] or Vector3.new(0, 3, 75)
	for i, x in ipairs({ -90, -30, 30, 90 }) do
		local part = Instance.new("Part")
		part.Name = "TideObstacle" .. tostring(i)
		part.Size = Vector3.new(6, 6, 6)
		part.Anchored = true
		part.CanCollide = false
		part.Material = Enum.Material.Metal
		part.Color = Color3.fromRGB(60, 60, 80)
		part.Position = Vector3.new(mid.X + x, 3, mid.Z)
		part.Parent = workspace
		table.insert(_obstacles, {
			Part = part,
			BaseX = mid.X + x,
			BaseZ = mid.Z,
			Range = 25,
			Speed = 0.6 + i * 0.15,
			Phase = i * 1.7,
		})
		local lastHit: { [Humanoid]: number } = {}
		part.Touched:Connect(function(hit)
			local model = hit:FindFirstAncestorOfClass("Model")
			if not model then
				return
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
				return
			end
			local now = os.clock()
			if now - (lastHit[humanoid] or -math.huge) < 1 then
				return
			end
			lastHit[humanoid] = now
			pcall(function()
				humanoid:TakeDamage(math.floor(OBSTACLE_DAMAGE * (VARIATIONS[_variation] and VARIATIONS[_variation].DamageMult or 1) + 0.5))
			end)
			local away = root.Position - part.Position
			away = Vector3.new(away.X, 0, away.Z)
			if away.Magnitude < 0.01 then
				away = Vector3.new(0, 0, 1)
			end
			local bv = Instance.new("BodyVelocity")
			bv.MaxForce = Vector3.new(math.huge, 0, math.huge)
			bv.Velocity = away.Unit * 25 + Vector3.new(0, 4, 0)
			bv.Parent = root
			Debris:AddItem(bv, 0.3)
		end)
	end
end

-- Risk-and-reward zones: gold pads INSIDE the wave path. Standing in
-- one during the tide banks +5 coins per second — paid only if you
-- survive the tide.
local function spawnRiskZones()
	local waypoints = getWaypoints()
	local mid = waypoints[math.floor(#waypoints / 2) + 1] or Vector3.new(0, 3, 75)
	for _, x in ipairs({ -40, 40 }) do
		local pos = Vector3.new(mid.X + x, 1, mid.Z)
		local part = makeZonePart("RiskZone", pos, Vector3.new(12, 1, 12), Color3.fromRGB(255, 200, 60))
		table.insert(_riskZones, { Position = pos, Radius = 7, Part = part })
	end
	fireAll(_names.SpawnEffect, { type = "RiskZones", count = #_riskZones })
end

-- Temporary safe shelters: a floor + roof + posts, standing only for
-- the Active phase. Their floors are safe-zone parts (IsInSafeZone).
local function spawnShelters()
	local count = tonumber(Config.TideShelterCount) or 3
	local waypoints = getWaypoints()
	local mid = waypoints[math.floor(#waypoints / 2) + 1] or Vector3.new(0, 3, 75)
	for i = 1, count do
		local x = mid.X + (i - 2) * 100
		local z = mid.Z + 35
		local shelter = Instance.new("Model")
		shelter.Name = "TideShelter" .. tostring(i)
		local floorPart = Instance.new("Part")
		floorPart.Name = "ShelterFloor"
		floorPart.Size = Vector3.new(12, 1, 12)
		floorPart.Anchored = true
		floorPart.Material = Enum.Material.Concrete
		floorPart.Color = Color3.fromRGB(90, 90, 110)
		floorPart.Position = Vector3.new(x, 0.5, z)
		floorPart.Parent = shelter
		local roof = Instance.new("Part")
		roof.Name = "ShelterRoof"
		roof.Size = Vector3.new(14, 1, 14)
		roof.Anchored = true
		roof.Material = Enum.Material.SmoothPlastic
		roof.Color = Color3.fromRGB(120, 255, 170)
		roof.Position = Vector3.new(x, 6, z)
		roof.Parent = shelter
		for _, dx in ipairs({ -5.5, 5.5 }) do
			for _, dz in ipairs({ -5.5, 5.5 }) do
				local post = Instance.new("Part")
				post.Name = "ShelterPost"
				post.Size = Vector3.new(1, 5, 1)
				post.Anchored = true
				post.Material = Enum.Material.Concrete
				post.Color = Color3.fromRGB(70, 70, 85)
				post.Position = Vector3.new(x + dx, 3, z + dz)
				post.Parent = shelter
			end
		end
		shelter.Parent = workspace
		table.insert(_shelters, shelter)
		table.insert(_shelterParts, floorPart)
	end
	fireAll(_names.SpawnEffect, { type = "TideShelters", count = #_shelters })
end

-- Dark: ambush spawns. NPCService when linked, else a minimal fallback
-- enemy (block body + Humanoid, wanders, touch damage 10, 60s life).
local function spawnAmbushEnemy(position: Vector3)
	if _npcService and type(_npcService.SpawnEnemy) == "function" then
		local model: Model? = nil
		pcall(function()
			model = _npcService.SpawnEnemy(nil, position, { Health = 80, Damage = 10 })
		end)
		if model then
			table.insert(_ambushNPCs, model)
			return
		end
	end
	local all = Characters.GetAll()
	local def = all[math.random(1, #all)]
	local model = Instance.new("Model")
	model.Name = "Ambush_" .. def.DisplayName
	model:SetAttribute("NPCType", "Enemy")
	model:SetAttribute("Damage", 10)
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Position = position
	root.Parent = model
	model.PrimaryPart = root
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(3, 3, 2)
	body.Color = Color3.fromRGB(20, 20, 30)
	body.Material = Enum.Material.Neon
	body.Parent = model
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = body
	weld.Parent = root
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = 80
	humanoid.MaxHealth = 80
	humanoid.WalkSpeed = 16
	humanoid.Parent = model
	local tag = Instance.new("BoolValue")
	tag.Name = "IsNPC"
	tag.Parent = model
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "NPCs"
		folder.Parent = workspace
	end
	model.Parent = folder
	table.insert(_ambushNPCs, model)
	Debris:AddItem(model, 60)
	local damage = 10
	local lastHit: { [Humanoid]: number } = {}
	body.Touched:Connect(function(hit)
		local hitModel = hit:FindFirstAncestorOfClass("Model")
		if not hitModel then
			return
		end
		local target = hitModel:FindFirstChildOfClass("Humanoid")
		if not target or target.Health <= 0 then
			return
		end
		local now = os.clock()
		if now - (lastHit[target] or -math.huge) >= 1 then
			lastHit[target] = now
			pcall(function()
				target:TakeDamage(damage)
			end)
		end
	end)
	task.spawn(function()
		while model.Parent and humanoid.Health > 0 do
			pcall(function()
				humanoid:MoveTo(position + Vector3.new(math.random(-15, 15), 0, math.random(-15, 15)))
			end)
			task.wait(3)
		end
	end)
end

-- Secret encounter roll (10% by default, Config.TideSecretEncounterChance).
-- Either a hidden merchant visits (every survivor gets +5 Event Tokens
-- at payout) or a secret Brainrot is sighted (everyone online gets
-- +1 Chaos Shard now). Broadcast on EventUpdate + SpawnEffect; the
-- record is kept for GetSecretEncounter() (secrets workstream hook).
local function rollSecretEncounter()
	local chance = tonumber(Config.TideSecretEncounterChance) or 0.10
	if math.random() >= chance then
		_secretEncounter = nil
		return
	end
	local kind = if math.random() < 0.5 then "HiddenMerchant" else "SecretSighting"
	_secretEncounter = { Kind = kind, Variation = _variation }
	if kind == "SecretSighting" then
		for _, player in ipairs(Players:GetPlayers()) do
			local data = getData(player)
			if data then
				data.ChaosShards = (tonumber(data.ChaosShards) or 0) + 1
				pushStats(player)
			end
		end
	end
	fireAll(_names.EventUpdate, {
		EventId = "tide_secret",
		Name = kind == "HiddenMerchant" and "Hidden Merchant" or "Secret Brainrot Sighting",
		Phase = "Started",
		Duration = 0,
		SecretEncounter = kind,
		Variation = _variation,
	})
	fireAll(_names.SpawnEffect, {
		type = "SecretEncounter",
		kind = kind,
		variation = _variation,
	})
	print(string.format("[TideService] Secret encounter rolled: %s (%s tide)", kind, _variation))
end

-- Tide-exclusive Brainrot spawn on the conveyor: a Secret-rarity
-- Brainrot appears while the tide runs (glitch mode is on). Uses the
-- linked ConveyorService; silently skipped when it is absent or full.
local function spawnTideExclusive()
	if not _conveyorService or type(_conveyorService.ForceSpawn) ~= "function" then
		return
	end
	pcall(function()
		local item = _conveyorService.ForceSpawn("Secret")
		if item then
			print("[TideService] Tide-exclusive Secret Brainrot on the conveyor")
		end
	end)
end

local function cleanupTideObjects(wave: Model?, secondWave: Model?)
	pcall(function()
		if wave then
			wave:Destroy()
		end
		if secondWave then
			secondWave:Destroy()
		end
	end)
	for _, shelter in ipairs(_shelters) do
		pcall(function()
			shelter:Destroy()
		end)
	end
	_shelters = {}
	_shelterParts = {}
	for _, zone in ipairs(_toxicPools) do
		pcall(function()
			zone.Part:Destroy()
		end)
	end
	_toxicPools = {}
	for _, zone in ipairs(_slowFields) do
		pcall(function()
			zone.Part:Destroy()
		end)
	end
	_slowFields = {}
	for _, part in ipairs(_barriers) do
		pcall(function()
			part:Destroy()
		end)
	end
	_barriers = {}
	for _, obstacle in ipairs(_obstacles) do
		pcall(function()
			obstacle.Part:Destroy()
		end)
	end
	_obstacles = {}
	for _, zone in ipairs(_riskZones) do
		pcall(function()
			zone.Part:Destroy()
		end)
	end
	_riskZones = {}
	for _, part in ipairs(_pickups) do
		pcall(function()
			part:Destroy()
		end)
	end
	_pickups = {}
	for _, model in ipairs(_ambushNPCs) do
		pcall(function()
			model:Destroy()
		end)
	end
	_ambushNPCs = {}
	-- Cosmic low gravity ends with the tide.
	if _origGravity ~= nil then
		local restore = _origGravity
		_origGravity = nil
		pcall(function()
			workspace.Gravity = restore
		end)
	end
end

-- ---------------------------------------------------------------------------
-- One full tide cycle (Warning -> Tide -> Calm). Guarded by _cycleActive
-- so ForceStart and the scheduler can never run two cycles at once.
-- ---------------------------------------------------------------------------

local function runCycle(variationId: string?)
	if _cycleActive then
		return false
	end
	_cycleActive = true
	_runToken += 1
	local token = _runToken
	_variation = variationId or pickVariation()
	local variation = VARIATIONS[_variation] or VARIATIONS.Standard
	local style = VARIATION_STYLE[_variation] or VARIATION_STYLE.Standard
	local warningSeconds = Config.GlitchTideWarningSeconds or 30
	local tideSeconds = Config.GlitchTideDurationSeconds or 60
	local climaxSeconds = tonumber(Config.TideClimaxSeconds) or 5
	_hitThisTide = {}
	_riskEarnings = {}
	_surfTime = {}
	_frozenSpeeds = {}
	rollSecretEncounter()

	-- Waits `seconds` in 1s steps (token-checked); each step refreshes
	-- the countdown and re-broadcasts it every 5s / in the last 5s.
	local function waitStage(seconds: number): boolean
		local remaining = seconds
		while remaining > 0 do
			if token ~= _runToken then
				return false
			end
			local step = math.min(1, remaining)
			task.wait(step)
			remaining -= step
			_timeLeft = math.max(0, _timeLeft - step)
			local t = math.floor(_timeLeft)
			if t % 5 == 0 or t <= 5 then
				broadcast({
					Phase = _phase,
					TimeLeft = t,
					NextTideIn = 0,
					Variation = _variation,
					IncomeMultiplier = Config.GlitchTideIncomeMultiplier or 2,
					GlitchChance = Config.GlitchTideGlitchChance or 0.35,
					Stage = _stage,
					StageName = _stageName,
				})
			end
		end
		return token == _runToken
	end

	-- Warning phase: cinematic stages 1-5 -------------------------------
	_phase = "Warning"
	_timeLeft = warningSeconds
	_incomeMultiplier = 1
	_stage = 0
	_stageName = ""

	-- Stage 1: the environment flickers (15% of the warning window).
	broadcastStage(1, "EnvironmentFlicker")
	flickerEnvironment()
	if not waitStage(warningSeconds * 0.15) then
		_cycleActive = false
		return false
	end
	-- Stage 2: distant structures flicker (15%).
	broadcastStage(2, "StructureFlicker")
	flickerStructures()
	if not waitStage(warningSeconds * 0.15) then
		_cycleActive = false
		return false
	end
	-- Stage 3: sirens (20%) — SpawnEffect for the sound workstream.
	broadcastStage(3, "Sirens")
	fireAll(_names.SpawnEffect, { type = "TideSiren", variation = _variation })
	if not waitStage(warningSeconds * 0.20) then
		_cycleActive = false
		return false
	end
	-- Stage 4: the sky changes (20%).
	broadcastStage(4, "SkyChange")
	setMood("TideWarning")
	if not waitStage(warningSeconds * 0.20) then
		_cycleActive = false
		return false
	end
	-- Stage 5: the player warning (30%) — full payload: announcement,
	-- escape routes, variation, income multiplier, glitch chance.
	broadcastStage(5, "PlayerWarning", {
		Announcement = variation.Announcement,
		EscapeRoutes = (function()
			local routes = TideService.GetEscapeRoutes()
			local out: { { Position: { number }, Radius: number, Kind: string } } = {}
			for _, route in ipairs(routes) do
				table.insert(out, {
					Position = { route.Position.X, route.Position.Y, route.Position.Z },
					Radius = route.Radius,
					Kind = route.Kind,
				})
			end
			return out
		end)(),
		GlitchChance = Config.GlitchTideGlitchChance or 0.35,
	})
	if _callbacks and type(_callbacks.SetGlitchMode) == "function" then
		pcall(function()
			_callbacks.SetGlitchMode(true)
		end)
	end
	print(string.format("[TideService] Glitch Tide warning: %s variation", _variation))
	if not waitStage(warningSeconds * 0.30) then
		_cycleActive = false
		return false
	end

	-- Tide phase: stages 6-9 --------------------------------------------
	_phase = "Active"
	_timeLeft = tideSeconds
	_incomeMultiplier = Config.GlitchTideIncomeMultiplier or 2
	setMood(style.Mood)
	local waypoints = getWaypoints()
	local wave = buildWaveModel(style.WaveColor)
	wave.Parent = workspace
	-- Double: a second wall, cyan, travelling in anti-phase.
	local secondWave: Model? = nil
	local isDouble = _variation == "Double"
	if isDouble then
		secondWave = buildWaveModel(Color3.fromRGB(40, 220, 255))
		secondWave.Parent = workspace
	end
	-- Stage 6: the wave emerges.
	broadcastStage(6, "WaveEmerges", {
		IncomeMultiplier = _incomeMultiplier,
		GlitchChance = Config.GlitchTideGlitchChance or 0.35,
	})
	-- Structures every tide gets: shelters, moving obstacles, risk zones.
	spawnShelters()
	spawnObstacles()
	spawnRiskZones()
	-- Per-variant hazards.
	if _variation == "Toxic" then
		spawnToxicPools()
	elseif _variation == "Frozen" then
		spawnSlowFields()
	elseif _variation == "Corrupted" then
		spawnBarriers()
	end
	-- Cosmic: low gravity for the whole tide.
	if _variation == "Cosmic" then
		_origGravity = workspace.Gravity
		pcall(function()
			workspace.Gravity = 60
		end)
	end
	-- GiantBoss: THE GLITCH COLOSSUS storms the arena mid-tide.
	if _variation == "GiantBoss" and _bossService and type(_bossService.SpawnBoss) == "function" then
		local spawned = false
		pcall(function()
			spawned = _bossService.SpawnBoss("GlitchColossus") == true
		end)
		if not spawned then
			pcall(function()
				_bossService.SpawnBoss()
			end)
		end
		print("[TideService] GiantBoss tide: boss summoned mid-tide")
	end
	-- First tide-exclusive conveyor spawn right away.
	spawnTideExclusive()

	local waveSpeed = variation.WaveSpeed
	local minBound, maxBound = getChannelBounds()
	local meteorTimer = 0
	local starfallTimer = 0
	local exclusiveTimer = 0
	local ambushTimer = 0
	local teleportTimer = 0

	-- Frozen variation: halve everyone's movement for the whole tide.
	-- Applied inside the tick loop (not just once at tide start):
	-- v1.0.0 only slowed players who were already in-game when the
	-- tide began, so anyone who joined or respawned mid-tide ran at
	-- full speed. Tide Surfers are exempt (their power is tide immunity).
	-- v1.1: standing in a slow field slows further (x0.35 total).
	local function applyFrozenSlow()
		if _variation ~= "Frozen" then
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if not TideService.IsSurfer(player) then
				local character = player.Character
				if character then
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if humanoid and humanoid.Health > 0 then
						if _frozenSpeeds[humanoid] == nil then
							_frozenSpeeds[humanoid] = humanoid.WalkSpeed
						end
						local pos = getRootPosition(player)
						local inField = pos ~= nil and isInZoneList(_slowFields, pos)
						humanoid.WalkSpeed = _frozenSpeeds[humanoid] * (inField and 0.35 or 0.5)
					end
				end
			end
		end
	end
	applyFrozenSlow()

	-- Stage 7: the wave travels across the world.
	broadcastStage(7, "WaveTravels")
	local stage8Done = false
	local stage9Done = false
	local elapsed = 0
	while elapsed < tideSeconds do
		if token ~= _runToken then
			break
		end
		local step = task.wait(1)
		elapsed += step
		_timeLeft = math.max(0, tideSeconds - elapsed)
		-- Stage 8: survival phase (second half of the tide).
		if not stage8Done and elapsed >= tideSeconds * 0.5 then
			stage8Done = true
			broadcastStage(8, "Survival")
		end
		-- Stage 9: climax — the final surge (last TideClimaxSeconds):
		-- the wave sweeps 1.5x faster and Meteor rain doubles.
		local inClimax = elapsed >= tideSeconds - climaxSeconds
		if not stage9Done and inClimax then
			stage9Done = true
			broadcastStage(9, "Climax")
			fireAll(_names.SpawnEffect, { type = "TideClimax", variation = _variation })
		end
		local effectiveSpeed = waveSpeed * (inClimax and 1.5 or 1)
		-- Wave position: progress 0..1 across `effectiveSpeed` ping-pong passes.
		local raw = (elapsed / tideSeconds) * effectiveSpeed
		local pass = math.floor(raw)
		local frac = raw - pass
		local progress = (pass % 2 == 0) and frac or (1 - frac)
		local wavePos = placeWave(wave, waypoints, progress)
		local wavePos2: Vector3? = nil
		if secondWave then
			wavePos2 = placeWave(secondWave, waypoints, 1 - progress)
		end
		-- Moving obstacles slide along the channel.
		for _, obstacle in ipairs(_obstacles) do
			pcall(function()
				local x = obstacle.BaseX + math.sin(elapsed * obstacle.Speed + obstacle.Phase) * obstacle.Range
				obstacle.Part.Position = Vector3.new(x, 3, obstacle.BaseZ)
			end)
		end
		broadcast({
			Phase = "Active",
			TimeLeft = math.floor(_timeLeft),
			NextTideIn = 0,
			Variation = _variation,
			IncomeMultiplier = _incomeMultiplier,
			GlitchChance = Config.GlitchTideGlitchChance or 0.35,
			WavePosition = { wavePos.X, wavePos.Y, wavePos.Z },
			Stage = _stage,
			StageName = _stageName,
		})

		if _variation == "Meteor" then
			meteorTimer += step
			if meteorTimer >= (inClimax and 1 or 2) then
				meteorTimer = 0
				spawnMeteor()
			end
		end
		if _variation == "Cosmic" then
			starfallTimer += step
			if starfallTimer >= 8 then
				starfallTimer = 0
				spawnPickup("Starfall", Vector3.new(
					math.random(math.floor(minBound.X), math.floor(maxBound.X)),
					1,
					math.random(math.floor(minBound.Z), math.floor(maxBound.Z))
				))
			end
		end
		-- Tide-exclusive conveyor spawns keep coming during the tide.
		exclusiveTimer += step
		if exclusiveTimer >= 25 then
			exclusiveTimer = 0
			if math.random() < 0.5 then
				spawnTideExclusive()
			end
		end
		-- Dark: ambush spawns in the dark (cap 4 alive at once).
		if _variation == "Dark" then
			ambushTimer += step
			if ambushTimer >= 10 then
				ambushTimer = 0
				local alive = 0
				for _, model in ipairs(_ambushNPCs) do
					local h = model:FindFirstChildOfClass("Humanoid")
					if model.Parent and h and h.Health > 0 then
						alive += 1
					end
				end
				if alive < 4 then
					spawnAmbushEnemy(Vector3.new(
						math.random(math.floor(minBound.X), math.floor(maxBound.X)),
						3,
						math.random(math.floor(minBound.Z), math.floor(maxBound.Z))
					))
				end
			end
		end
		-- Corrupted: random teleports strike the exposed.
		if _variation == "Corrupted" then
			teleportTimer += step
			if teleportTimer >= 15 then
				teleportTimer = 0
				local exposed: { Player } = {}
				for _, player in ipairs(Players:GetPlayers()) do
					if not TideService.IsInSafeZone(player) and not TideService.IsSurfer(player) then
						table.insert(exposed, player)
					end
				end
				if #exposed > 0 then
					local victim = exposed[math.random(1, #exposed)]
					local character = victim.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if root and root:IsA("BasePart") then
						pcall(function()
							root.CFrame = root.CFrame + Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
						end)
						fireClient(_names.SpawnEffect, victim, { type = "GlitchTeleport", position = root.Position })
					end
				end
			end
		end

		-- Frozen slow for anyone who joined / respawned since the last tick.
		applyFrozenSlow()

		-- Damage tick: everyone not safe, not a Tide Surfer, and alive.
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			if character then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				local root = character:FindFirstChild("HumanoidRootPart")
				if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
					if not TideService.IsInSafeZone(player) and not TideService.IsSurfer(player) then
						local pos = root.Position
						local nearWave = math.abs(pos.X - wavePos.X) < 38
							and math.abs(pos.Z - wavePos.Z) < 9
						if wavePos2 then
							nearWave = nearWave or (math.abs(pos.X - wavePos2.X) < 38
								and math.abs(pos.Z - wavePos2.Z) < 9)
						end
						-- Wave + Toxic damage, scaled by the variation's
						-- Damage multiplier from Config (v1.0.0 used flat
						-- 12 / 6 and ignored the multiplier entirely).
						local damageMult = variation.DamageMult or 1
						local damage = 0
						if nearWave then
							damage += math.floor(TIDE_DAMAGE * damageMult + 0.5)
						end
						-- Toxic: damage over time anywhere inside the channel.
						if _variation == "Toxic"
							and pos.X >= minBound.X and pos.X <= maxBound.X
							and pos.Z >= minBound.Z and pos.Z <= maxBound.Z
						then
							damage += math.floor(TOXIC_DOT * damageMult + 0.5)
						end
						-- Toxic pools: extra DoT inside a pool.
						if _variation == "Toxic" and isInZoneList(_toxicPools, pos) then
							damage += math.floor(TOXIC_DOT * damageMult + 0.5)
						end
						-- Dark: the dark itself bites the exposed.
						if _variation == "Dark" then
							damage += math.floor(4 * damageMult + 0.5)
						end
						if damage > 0 then
							_hitThisTide[player] = true
							pcall(function()
								humanoid:TakeDamage(damage)
							end)
							applyStun(player, 1)
							if _callbacks and type(_callbacks.DropCarried) == "function" then
								pcall(function()
									_callbacks.DropCarried(player)
								end)
							end
						end
						-- Risk-and-reward: bank coins for standing in a
						-- risk zone inside the wave path (paid on survival).
						if isInZoneList(_riskZones, pos) then
							_riskEarnings[player] = (_riskEarnings[player] or 0) + 5
						end
					elseif TideService.IsSurfer(player) then
						-- Tide surfing: a Surfer riding near the wave
						-- banks surf time — +10 coins per 5s, +1 Chaos
						-- Shard per 15s, paid at the end of the tide.
						local nearWave = math.abs(root.Position.X - wavePos.X) < 20
							and math.abs(root.Position.Z - wavePos.Z) < 12
						if wavePos2 then
							nearWave = nearWave or (math.abs(root.Position.X - wavePos2.X) < 20
								and math.abs(root.Position.Z - wavePos2.Z) < 12)
						end
						if nearWave then
							local before = math.floor((_surfTime[player] or 0) / 5)
							_surfTime[player] = (_surfTime[player] or 0) + step
							local after = math.floor((_surfTime[player] or 0) / 5)
							if after > before then
								fireClient(_names.SpawnEffect, player, {
									type = "TideSurf",
									surfSeconds = _surfTime[player],
								})
							end
						end
					end
				end
			end
		end
	end

	-- Cleanup + Calm ------------------------------------------------------
	cleanupTideObjects(wave, secondWave)
	for humanoid, speed in pairs(_frozenSpeeds) do
		if humanoid.Parent then
			humanoid.WalkSpeed = speed
		end
	end
	_frozenSpeeds = {}
	setMood("Hub")
	if _callbacks and type(_callbacks.SetGlitchMode) == "function" then
		pcall(function()
			_callbacks.SetGlitchMode(false)
		end)
	end
	_incomeMultiplier = 1
	_phase = "Calm"
	_timeLeft = 0

	-- Stage 10: rewards distributed.
	-- Survivors: alive at the end of the tide. Flawless survivors
	-- (never hit) earn a token bonus; rewards scale with the variation.
	-- v1.0.0 paid the rewards but never told QuestService: the
	-- "Tide Survivor" and "Meteor Dodger" quests could never complete.
	local survivors: { string } = {}
	local survivorPlayers: { Player } = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			table.insert(survivors, player.Name)
			table.insert(survivorPlayers, player)
		end
	end
	local coop = #survivorPlayers >= 2
	local merchantBonus = _secretEncounter ~= nil and _secretEncounter.Kind == "HiddenMerchant"
	local rewardMult = variation.RewardMult
	broadcastStage(10, "Rewards", {
		Survivors = survivors,
		RewardMultiplier = rewardMult,
		CoopBonus = coop,
	})
	for _, player in ipairs(survivorPlayers) do
		awardSurvivor(player, _hitThisTide[player] == nil, rewardMult, {
			Coop = coop,
			MerchantBonus = merchantBonus,
		})
		if _questService and type(_questService.RecordEvent) == "function" then
			pcall(function()
				_questService.RecordEvent(player, "survive_tide", 1)
			end)
			if _variation == "Meteor" then
				pcall(function()
					_questService.RecordEvent(player, "survive_meteor_tide", 1)
				end)
			end
			if _variation == "GiantBoss" then
				pcall(function()
					_questService.RecordEvent(player, "survive_boss_tide", 1)
				end)
			end
		end
		-- v1.1 (Workstream C): quest-progress hook — flawless survival
		-- (never hit this tide) has no RecordEvent coverage yet.
		if _questService and type(_questService.ReportProgress) == "function" then
			if _hitThisTide[player] == nil then
				pcall(function()
					_questService.ReportProgress(player, "tide_flawless", "flawless", 1)
				end)
			end
		end
	end
	-- TideSurvivor remote (exists in Remotes.Names; v1.0.0 never fired it).
	fireAll(_names.TideSurvivor, {
		Survivors = survivors,
		Variation = _variation,
		RewardMultiplier = rewardMult,
		CoopBonus = coop,
		SecretEncounter = _secretEncounter and _secretEncounter.Kind or nil,
	})
	-- Boss tide: every Nth tide spawns the world boss
	-- (Config.EventSchedule.BossTideEvery = 5). v1.0.0 scheduled this
	-- nowhere — the boss only ever spawned on its own 30-minute timer.
	_tideCount += 1
	local bossEvery = 5
	if Config.EventSchedule and tonumber(Config.EventSchedule.BossTideEvery) then
		bossEvery = tonumber(Config.EventSchedule.BossTideEvery) :: number
	end
	if _bossService and type(_bossService.SpawnBoss) == "function" and bossEvery > 0
		and _tideCount % bossEvery == 0 then
		pcall(function()
			_bossService.SpawnBoss()
		end)
		print(string.format("[TideService] Boss tide (tide #%d): THE ALGORITHM summoned", _tideCount))
	end
	broadcast({
		Phase = "Calm",
		TimeLeft = 0,
		NextTideIn = Config.GlitchTideIntervalSeconds,
		Variation = _variation,
		IncomeMultiplier = 1,
		GlitchChance = 0,
		Survivors = survivors,
		Stage = _stage,
		StageName = _stageName,
	})
	-- Also broadcast the Survivor phase named in the spec.
	broadcast({
		Phase = "Survivor",
		TimeLeft = 0,
		NextTideIn = Config.GlitchTideIntervalSeconds,
		Variation = _variation,
		IncomeMultiplier = 1,
		GlitchChance = 0,
		Survivors = survivors,
		Stage = _stage,
		StageName = _stageName,
	})
	print(string.format(
		"[TideService] Tide ended (%s): %d survivors",
		_variation, #survivors
	))
	_nextTideIn = Config.GlitchTideIntervalSeconds
	_phase = "Idle"
	_stage = 0
	_stageName = ""
	_cycleActive = false
	return true
end

-- ForceStart(variation?): start a tide immediately (EventService /
-- testing hook). Returns false when a cycle is already running or the
-- variation id is unknown. Accepts every variation in
-- Config.TideVariations (all ten in v1.1).
function TideService.ForceStart(variationId: string?): boolean
	if _cycleActive then
		warn("[TideService] ForceStart ignored: a tide cycle is already running")
		return false
	end
	if variationId ~= nil and VARIATIONS[variationId] == nil then
		warn("[TideService] ForceStart ignored: unknown variation " .. tostring(variationId))
		return false
	end
	task.spawn(function()
		runCycle(variationId)
	end)
	return true
end

-- SetQuestService / SetProgressionService / SetBossService: setter
-- injection (GameManager's wireCrossLinks calls these with the final
-- loaded services; each validates the interface before accepting).
function TideService.SetQuestService(questService: any)
	if questService and type(questService.RecordEvent) == "function" then
		_questService = questService
	end
end

function TideService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function TideService.SetBossService(bossService: any)
	if bossService and type(bossService.SpawnBoss) == "function" then
		_bossService = bossService
	end
end

-- SetConveyorService / SetNPCService: same setter injection
-- (GameManager's shared cross-link table calls both).
-- ConveyorService drives tide-exclusive spawns; NPCService drives
-- Dark-tide ambushes.
function TideService.SetConveyorService(conveyorService: any)
	if conveyorService and type(conveyorService.ForceSpawn) == "function" then
		_conveyorService = conveyorService
	end
end

function TideService.SetNPCService(npcService: any)
	if npcService and type(npcService.SpawnEnemy) == "function" then
		_npcService = npcService
	end
end

function TideService.GetTideCount(): number
	return _tideCount
end

function TideService.Init(dataService: any, map: Instance?, callbacks: any?)
	assert(dataService ~= nil, "[TideService] Init requires DataService")
	_dataService = dataService
	_map = map
	_callbacks = callbacks

	Players.PlayerRemoving:Connect(function(player)
		_surfers[player] = nil
		_hitThisTide[player] = nil
		_riskEarnings[player] = nil
		_surfTime[player] = nil
	end)

	-- Scheduler: idle countdown, then run a cycle, then repeat.
	task.spawn(function()
		while true do
			_nextTideIn = Config.GlitchTideIntervalSeconds
			for t = Config.GlitchTideIntervalSeconds, 1, -1 do
				_nextTideIn = t
				task.wait(1)
			end
			local ok, err = pcall(function()
				runCycle(nil)
			end)
			if not ok then
				warn("[TideService] Tide cycle failed: " .. tostring(err))
				_cycleActive = false
				_phase = "Idle"
				_stage = 0
				_stageName = ""
				_incomeMultiplier = 1
				setMood("Hub")
			end
		end
	end)
end

return TideService
