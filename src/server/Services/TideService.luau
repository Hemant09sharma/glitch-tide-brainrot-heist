--!strict
-- TideService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- The signature world event: every Config.GlitchTideIntervalSeconds the
-- tide runs Warning (30s) -> Tide (60s) -> Calm. A physical wave wall
-- sweeps the TideChannel; players outside a safe zone / base / shelter
-- take damage + stun and drop whatever they carry. Survivors are paid
-- at the end. Five variations (Standard + Fast / Toxic / Frozen /
-- Meteor) are picked randomly with weights and announced.
--
-- v1.0.1 QA: Config used to list three more variations (Double, Dark,
-- GiantBoss) that had NO behaviour anywhere and ForceStart rejected as
-- unknown. They are demoted to Config.TideVariationsDisabled and are
-- NOT in the rotation. Every 5th tide also spawns the world boss via
-- BossService (Config.EventSchedule.BossTideEvery), when linked.
--
-- Optional dependencies (all degrade gracefully):
--   * `map` (Init arg) may be nil or may lack a TideChannel / SafeZones /
--     Bases folder; waypoints and safe zones fall back to the arena
--     centre and the spawn/lobby area.
--   * callbacks.DropCarried(player) — CarryService hook; skipped when absent.
--   * callbacks.GetSafeZones() -> { {Position, Radius} } or { {Part} }.
--   * callbacks.SetGlitchMode(enabled) — conveyor glitch mode; skipped when absent.
--   * callbacks.IsTideSurfer(player) — AbilityService hook for the
--     Tide Surfer power; without it, TideService.GrantSurfer is the only
--     source of tide immunity.
-- No BaseService / CarryService / ConveyorService is required here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local TideService = {}

local _dataService: any = nil
local _map: Instance? = nil
local _callbacks: any = nil
local _questService: any = nil
local _progressionService: any = nil
local _bossService: any = nil
local _tideCount: number = 0

local _phase: string = "Idle" -- "Idle" | "Warning" | "Active" | "Calm"
local _timeLeft: number = 0
local _nextTideIn: number = Config.GlitchTideIntervalSeconds
local _variation: string = "Standard"
local _cycleActive: boolean = false
local _runToken: number = 0
local _incomeMultiplier: number = 1

-- player -> os.clock() until which they are immune (Tide Surfer power).
local _surfers: { [Player]: number } = {}
-- Humanoid -> true while a tide stun is active (prevents double-stun).
local _stunned: { [Humanoid]: boolean } = {}
-- Players hit at least once during the current tide.
local _hitThisTide: { [Player]: boolean } = {}
-- WalkSpeed overrides applied by the Frozen variation, for restore.
local _frozenSpeeds: { [Humanoid]: number } = {}

-- Variation table: weight, wave speed multiplier, reward multiplier,
-- damage multiplier. Built from Config.TideVariations (single source
-- of truth) at load time; the literals below are only the fallback if
-- Config failed to load. v1.0.0 kept a SECOND table here whose reward
-- multipliers disagreed with Config on every non-Standard variation
-- (Fast 1.5 here vs 1.25 in Config, Toxic 1.25 vs 1.5, Meteor 1.5 vs
-- 1.75) and ignored Config's Damage multipliers entirely.
local VARIATIONS: { [string]: { Weight: number, WaveSpeed: number, RewardMult: number, DamageMult: number } } = {
	Standard = { Weight = 40, WaveSpeed = 1, RewardMult = 1, DamageMult = 1 },
	Fast = { Weight = 20, WaveSpeed = 1.5, RewardMult = 1.25, DamageMult = 1 },
	Toxic = { Weight = 15, WaveSpeed = 1, RewardMult = 1.5, DamageMult = 1.25 },
	Frozen = { Weight = 15, WaveSpeed = 1, RewardMult = 1.5, DamageMult = 1 },
	Meteor = { Weight = 10, WaveSpeed = 1, RewardMult = 1.75, DamageMult = 1.5 },
}

local function loadVariationsFromConfig()
	-- Config is already required at the top of this file; rebuild the
	-- table from it so Config stays the single source of truth.
	if type(Config.TideVariations) ~= "table" then
		return
	end
	local config = Config
	local loaded: { [string]: { Weight: number, WaveSpeed: number, RewardMult: number, DamageMult: number } } = {}
	local count = 0
	for id, def in pairs(config.TideVariations) do
		if type(def) == "table" then
			loaded[id] = {
				Weight = tonumber(def.Weight) or 10,
				WaveSpeed = tonumber(def.SpeedMultiplier) or 1,
				RewardMult = tonumber(def.RewardMultiplier) or 1,
				DamageMult = tonumber(def.Damage) or 1,
			}
			count += 1
		end
	end
	if count > 0 then
		VARIATIONS = loaded
	end
end
loadVariationsFromConfig()

local TIDE_DAMAGE = 12
local TOXIC_DOT = 6
local METEOR_DAMAGE = 25
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

local function awardSurvivor(player: Player, neverHit: boolean, rewardMult: number)
	local data = getData(player)
	if not data then
		return
	end
	local coins = math.floor(SURVIVOR_COINS * rewardMult + 0.5)
	local xp = math.floor(SURVIVOR_XP * rewardMult + 0.5)
	local tokens = SURVIVOR_TOKENS
	if neverHit then
		tokens += SURVIVOR_TOKENS -- flawless-survival bonus
	end
	if _variation == "Meteor" then
		data.ChaosShards = (tonumber(data.ChaosShards) or 0) + 3
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
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		EventTokens = data.EventTokens,
		ChaosShards = data.ChaosShards,
	})
	print(string.format(
		"[TideService] Survivor %s: +%d coins, +%d XP, +%d tokens (%s)",
		player.Name, coins, xp, tokens, _variation
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
	return parts
end

-- ---------------------------------------------------------------------------
-- Public queries
-- ---------------------------------------------------------------------------

function TideService.GetState(): { Phase: string, TimeLeft: number, NextTideIn: number, Variation: string, IncomeMultiplier: number }
	return {
		Phase = _phase,
		TimeLeft = math.max(0, math.floor(_timeLeft)),
		NextTideIn = math.max(0, math.floor(_nextTideIn)),
		Variation = _variation,
		IncomeMultiplier = _incomeMultiplier,
	}
end

function TideService.IsTideActive(): boolean
	return _phase == "Warning" or _phase == "Active"
end

function TideService.GetIncomeMultiplier(): number
	return _incomeMultiplier
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
-- or inside a callback-provided safe zone (position+radius or part).
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

-- ---------------------------------------------------------------------------
-- Wave model + effects
-- ---------------------------------------------------------------------------

local function buildWaveModel(): Model
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
		part.Color = Color3.fromRGB(120, 80, 255)
		part.CFrame = CFrame.new((i - 6) * 7, 9, 0)
		part.Parent = model
	end
	local glow = Instance.new("PointLight")
	glow.Name = "WaveGlow"
	glow.Color = Color3.fromRGB(150, 100, 255)
	glow.Range = 30
	glow.Brightness = 2
	glow.Parent = model:FindFirstChild("WaveSegment6")
	return model
end

-- Position the wave model on the path at `progress` (0..1) facing along it.
local function placeWave(model: Model, waypoints: { Vector3 }, progress: number)
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

local _origLighting: { [string]: any } = {}

local function setStormLighting(on: boolean)
	pcall(function()
		if on then
			_origLighting.Ambient = Lighting.Ambient
			_origLighting.OutdoorAmbient = Lighting.OutdoorAmbient
			_origLighting.Brightness = Lighting.Brightness
			local tween = TweenService:Create(Lighting, TweenInfo.new(2, Enum.EasingStyle.Quad), {
				Ambient = Color3.fromRGB(60, 30, 110),
				OutdoorAmbient = Color3.fromRGB(40, 20, 80),
				Brightness = 1,
			})
			tween:Play()
		else
			local props: { [string]: any } = {}
			if _origLighting.Ambient ~= nil then
				props.Ambient = _origLighting.Ambient
			end
			if _origLighting.OutdoorAmbient ~= nil then
				props.OutdoorAmbient = _origLighting.OutdoorAmbient
			end
			if _origLighting.Brightness ~= nil then
				props.Brightness = _origLighting.Brightness
			end
			if next(props) ~= nil then
				local tween = TweenService:Create(Lighting, TweenInfo.new(3, Enum.EasingStyle.Quad), props)
				tween:Play()
			end
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
		if not humanoid or humanoid.Health <= 0 or touched[humanoid] then
			return
		end
		-- Meteors are tide damage: safe zones and Tide Surfers are immune.
		-- v1.0.0 damaged everyone the meteor touched, including players
		-- standing in a shelter.
		local owner = Players:GetPlayerFromCharacter(model)
		if owner and (TideService.IsInSafeZone(owner) or TideService.IsSurfer(owner)) then
			return
		end
		touched[humanoid] = true
		pcall(function()
			humanoid:TakeDamage(math.floor(METEOR_DAMAGE * (VARIATIONS[_variation] and VARIATIONS[_variation].DamageMult or 1) + 0.5))
		end)
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

local function broadcast(payload: any)
	fireAll(_names.GlitchTideUpdate, payload)
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
	local warningSeconds = Config.GlitchTideWarningSeconds or 30
	local tideSeconds = Config.GlitchTideDurationSeconds or 60

	-- Warning phase -------------------------------------------------------
	_phase = "Warning"
	_timeLeft = warningSeconds
	_incomeMultiplier = 1
	setStormLighting(true)
	if _callbacks and type(_callbacks.SetGlitchMode) == "function" then
		pcall(function()
			_callbacks.SetGlitchMode(true)
		end)
	end
	broadcast({
		Phase = "Warning",
		TimeLeft = warningSeconds,
		NextTideIn = 0,
		Variation = _variation,
		IncomeMultiplier = Config.GlitchTideIncomeMultiplier or 2,
		GlitchChance = Config.GlitchTideGlitchChance or 0.35,
	})
	-- Siren hook for the client (no external asset ids on the server):
	-- EffectsController plays the siren from this SpawnEffect.
	fireAll(_names.SpawnEffect, { type = "TideSiren", variation = _variation })
	print(string.format("[TideService] Glitch Tide warning: %s variation", _variation))
	for t = warningSeconds, 1, -1 do
		if token ~= _runToken then
			_cycleActive = false
			return false
		end
		_timeLeft = t
		if t % 5 == 0 or t <= 5 then
			broadcast({
				Phase = "Warning",
				TimeLeft = t,
				NextTideIn = 0,
				Variation = _variation,
				IncomeMultiplier = Config.GlitchTideIncomeMultiplier or 2,
				GlitchChance = Config.GlitchTideGlitchChance or 0.35,
			})
		end
		task.wait(1)
	end

	-- Tide phase ----------------------------------------------------------
	_phase = "Active"
	_timeLeft = tideSeconds
	_incomeMultiplier = Config.GlitchTideIncomeMultiplier or 2
	_hitThisTide = {}
	_frozenSpeeds = {}
	local waypoints = getWaypoints()
	local wave = buildWaveModel()
	wave.Parent = workspace
	local waveSpeed = variation.WaveSpeed
	-- Fast variation: the wave sweeps the channel 1.5x (ping-pong pass).
	local sweeps = waveSpeed
	local minBound, maxBound = getChannelBounds()
	local meteorTimer = 0

	-- Frozen variation: halve everyone's movement for the whole tide.
	-- Applied inside the tick loop (not just once at tide start):
	-- v1.0.0 only slowed players who were already in-game when the
	-- tide began, so anyone who joined or respawned mid-tide ran at
	-- full speed. Tide Surfers are exempt (their power is tide immunity).
	local function applyFrozenSlow()
		if _variation ~= "Frozen" then
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if not TideService.IsSurfer(player) then
				local character = player.Character
				if character then
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if humanoid and humanoid.Health > 0 and _frozenSpeeds[humanoid] == nil then
						_frozenSpeeds[humanoid] = humanoid.WalkSpeed
						humanoid.WalkSpeed = humanoid.WalkSpeed * 0.5
					end
				end
			end
		end
	end
	applyFrozenSlow()

	local elapsed = 0
	while elapsed < tideSeconds do
		if token ~= _runToken then
			break
		end
		local step = task.wait(1)
		elapsed += step
		_timeLeft = math.max(0, tideSeconds - elapsed)
		-- Wave position: progress 0..1 across `sweeps` ping-pong passes.
		local raw = (elapsed / tideSeconds) * sweeps
		local pass = math.floor(raw)
		local frac = raw - pass
		local progress = (pass % 2 == 0) and frac or (1 - frac)
		local wavePos = placeWave(wave, waypoints, progress)
		broadcast({
			Phase = "Active",
			TimeLeft = math.floor(_timeLeft),
			NextTideIn = 0,
			Variation = _variation,
			IncomeMultiplier = _incomeMultiplier,
			GlitchChance = Config.GlitchTideGlitchChance or 0.35,
			WavePosition = { wavePos.X, wavePos.Y, wavePos.Z },
		})

		if _variation == "Meteor" then
			meteorTimer += step
			if meteorTimer >= 2 then
				meteorTimer = 0
				spawnMeteor()
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
					end
				end
			end
		end
	end

	-- Cleanup + Calm ------------------------------------------------------
	pcall(function()
		wave:Destroy()
	end)
	for humanoid, speed in pairs(_frozenSpeeds) do
		if humanoid.Parent then
			humanoid.WalkSpeed = speed
		end
	end
	_frozenSpeeds = {}
	setStormLighting(false)
	if _callbacks and type(_callbacks.SetGlitchMode) == "function" then
		pcall(function()
			_callbacks.SetGlitchMode(false)
		end)
	end
	_incomeMultiplier = 1
	_phase = "Calm"
	_timeLeft = 0

	-- Survivors: alive at the end of the tide. Flawless survivors
	-- (never hit) earn a token bonus; rewards scale with the variation.
	-- v1.0.0 paid the rewards but never told QuestService: the
	-- "Tide Survivor" and "Meteor Dodger" quests could never complete.
	local survivors: { string } = {}
	local rewardMult = variation.RewardMult
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			table.insert(survivors, player.Name)
			awardSurvivor(player, _hitThisTide[player] == nil, rewardMult)
			if _questService and type(_questService.RecordEvent) == "function" then
				pcall(function()
					_questService.RecordEvent(player, "survive_tide", 1)
				end)
				if _variation == "Meteor" then
					pcall(function()
						_questService.RecordEvent(player, "survive_meteor_tide", 1)
					end)
				end
			end
		end
	end
	-- TideSurvivor remote (exists in Remotes.Names; v1.0.0 never fired it).
	fireAll(_names.TideSurvivor, {
		Survivors = survivors,
		Variation = _variation,
		RewardMultiplier = rewardMult,
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
	})
	print(string.format(
		"[TideService] Tide ended (%s): %d survivors",
		_variation, #survivors
	))
	_nextTideIn = Config.GlitchTideIntervalSeconds
	_phase = "Idle"
	_cycleActive = false
	return true
end

-- ForceStart(variation?): start a tide immediately (EventService /
-- testing hook). Returns false when a cycle is already running or the
-- variation id is unknown.
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
				_incomeMultiplier = 1
				setStormLighting(false)
			end
		end
	end)
end

return TideService
