--!strict
-- EffectsController.luau
-- Client-side visual effects for GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE:
-- particles, screen shake, hit flashes, floating damage numbers,
-- spawn/despawn poofs, ability AoE rings, and Glitch Tide effects
-- (screen distortion, lighting/color shift, teleport-pad sparkles,
-- glitched-Brainrot aura, steal alarm flash).
-- Listens to the SpawnEffect, DamageNumber and GlitchTideUpdate remotes
-- fired by the server.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer

local EffectsController = {}

local remotes: Folder? = nil
local camera: Camera? = nil

-- Screen shake state. Trauma decays every frame; the camera offset is
-- trauma^2 scaled, so small shakes stay subtle and big hits punch.
--
-- CAMERA-SAFE SHAKE (fix for the stuck / drifting camera): the old code
-- ran on RenderStepped and did `cam.CFrame = cam.CFrame * offset` —
-- compounding a fresh random offset onto whatever CFrame the previous
-- frame left, so offsets accumulated into a random walk and, while
-- trauma was > 0, the camera was being rewritten every frame outside
-- the default camera script. The shake now runs via BindToRenderStep
-- at Enum.RenderPriority.Camera.Value + 1, i.e. AFTER the default
-- camera script (priority 200) has written the frame's CFrame. Each
-- frame it reads that fresh CFrame as its base, applies ONE offset,
-- and never stores it: the next frame the default camera rewrites
-- CFrame from the (correctly bound) subject before the shake reads it
-- again, so nothing accumulates and nothing can freeze. When trauma
-- reaches exactly 0 the step becomes a no-op and writes nothing at all.
local trauma = 0
local shakeBound = false

local function getCamera(): Camera
	local cam = workspace.CurrentCamera
	if cam then
		camera = cam
	end
	return cam :: Camera
end

local function addTrauma(amount: number)
	trauma = math.min(1, trauma + amount)
end

local function shakeStep(deltaTime: number)
	if trauma <= 0.001 then
		trauma = 0
		return
	end
	trauma = math.max(0, trauma - deltaTime * 1.6)
	if trauma <= 0 then
		trauma = 0
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end
	-- No bound subject (camera stuck / between spawns): do not shake a
	-- camera that is not following the player.
	if cam.CameraSubject == nil then
		return
	end
	local magnitude = trauma * trauma * 0.6
	local offset = Vector3.new(
		(math.random() * 2 - 1) * magnitude,
		(math.random() * 2 - 1) * magnitude,
		0
	)
	-- Single-frame offset on top of the default camera's fresh CFrame.
	-- The default camera rewrites CFrame next frame, so this can never
	-- accumulate or leave the camera frozen at an offset position.
	cam.CFrame = cam.CFrame * CFrame.new(offset)
end

local function startShakeLoop()
	if shakeBound then
		return
	end
	shakeBound = true
	RunService:BindToRenderStep(
		"GlitchTideCameraShake",
		Enum.RenderPriority.Camera.Value + 1,
		shakeStep
	)
end

-- ---------------------------------------------------------------------------
-- Hit flash: a full-screen white/red overlay that fades out quickly.
-- ---------------------------------------------------------------------------
local flashGui: ScreenGui? = nil
local flashFrame: Frame? = nil

local function ensureFlashGui()
	if flashGui then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "HitFlashGui"
	gui.DisplayOrder = 50
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	local frame = Instance.new("Frame")
	frame.Name = "Flash"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	flashGui = gui
	flashFrame = frame
end

local function hitFlash(color: Color3, strength: number)
	ensureFlashGui()
	local frame = flashFrame
	if not frame then
		return
	end
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 1 - strength
	local tween = TweenService:Create(
		frame,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()
end

-- ---------------------------------------------------------------------------
-- Floating damage numbers.
-- ---------------------------------------------------------------------------
local function spawnDamageNumber(position: Vector3, amount: number, isCrit: boolean, isHeal: boolean)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Size = UDim2.fromOffset(120, 40)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	if isHeal then
		label.Text = "+" .. tostring(amount)
		label.TextColor3 = Color3.fromRGB(80, 255, 120)
	elseif isCrit then
		label.Text = tostring(amount) .. "!"
		label.TextColor3 = Color3.fromRGB(255, 200, 40)
	else
		label.Text = tostring(amount)
		label.TextColor3 = Color3.fromRGB(255, 90, 70)
	end
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Parent = billboard

	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace
	billboard.Adornee = anchor
	billboard.Parent = anchor

	local riseTween = TweenService:Create(
		anchor,
		TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(position + Vector3.new(math.random(-1, 1), 3, 0)) }
	)
	local fadeTween = TweenService:Create(
		label,
		TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }
	)
	riseTween:Play()
	fadeTween:Play()
	Debris:AddItem(anchor, 1.0)
end

-- ---------------------------------------------------------------------------
-- Particle bursts.
-- ---------------------------------------------------------------------------
local EFFECT_COLORS: { [string]: Color3 } = {
	hit = Color3.fromRGB(255, 220, 120),
	ko = Color3.fromRGB(255, 80, 80),
	heal = Color3.fromRGB(90, 255, 130),
	ability = Color3.fromRGB(120, 180, 255),
	coin = Color3.fromRGB(255, 215, 0),
	poof = Color3.fromRGB(220, 220, 230),
	wave = Color3.fromRGB(255, 150, 60),
}

local function spawnParticles(position: Vector3, effectType: string, count: number)
	local color = EFFECT_COLORS[effectType] or EFFECT_COLORS.hit
	local anchor = Instance.new("Part")
	anchor.Name = "EffectAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = NumberRange.new(6, 14)
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.Rate = 0
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Parent = anchor

	emitter:Emit(count)
	Debris:AddItem(anchor, 1.2)
end

local function spawnPoof(position: Vector3)
	spawnParticles(position, "poof", 18)
	local ring = Instance.new("Part")
	ring.Name = "PoofRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(230, 230, 240)
	ring.Shape = Enum.PartType.Ball
	ring.Size = Vector3.new(1, 1, 1)
	ring.Transparency = 0.4
	ring.CFrame = CFrame.new(position)
	ring.Parent = workspace
	local tween = TweenService:Create(
		ring,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(5, 5, 5), Transparency = 1 }
	)
	tween:Play()
	Debris:AddItem(ring, 0.6)
end

-- Expanding transparent ring on the ground for ability AoE telegraphs/impacts.
local function spawnAoERing(position: Vector3, radius: number, color: Color3)
	local ring = Instance.new("Part")
	ring.Name = "AoERing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.3, 1, 1)
	ring.Transparency = 0.35
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace

	local tween = TweenService:Create(
		ring,
		TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.3, radius * 2, radius * 2), Transparency = 1 }
	)
	tween:Play()
	Debris:AddItem(ring, 0.7)
end

-- ---------------------------------------------------------------------------
-- Glitch Tide effects: screen distortion, lighting/color shift, teleport-pad
-- sparkles, glitched-Brainrot aura and the steal alarm flash.
-- ---------------------------------------------------------------------------
local glitchActive = false
local glitchGui: ScreenGui? = nil
local glitchFrames: { Frame } = {}
local glitchFlicker: RBXScriptConnection? = nil
local glitchCorrection: ColorCorrectionEffect? = nil

local function ensureGlitchGui()
	if glitchGui then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "GlitchDistortionGui"
	gui.DisplayOrder = 45
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Enabled = false
	-- Three translucent RGB-shift panels. While the Tide is active they are
	-- jittered every frame (see the flicker loop), which reads as a
	-- distorted, chromatic-aberration screen without any post-process asset.
	local colors = {
		Color3.fromRGB(255, 0, 80),
		Color3.fromRGB(0, 255, 120),
		Color3.fromRGB(120, 80, 255),
	}
	for i, color in colors do
		local frame = Instance.new("Frame")
		frame.Name = "GlitchShift" .. tostring(i)
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = color
		frame.BackgroundTransparency = 0.93
		frame.BorderSizePixel = 0
		frame.Parent = gui
		table.insert(glitchFrames, frame)
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	glitchGui = gui
end

local function ensureGlitchCorrection()
	if glitchCorrection then
		return
	end
	local correction = Instance.new("ColorCorrectionEffect")
	correction.Name = "GlitchTideColorCorrection"
	correction.Enabled = false
	correction.Saturation = -0.35
	correction.Contrast = 0.25
	correction.TintColor = Color3.fromRGB(200, 120, 255)
	correction.Parent = Lighting
	glitchCorrection = correction
end

-- Turn the whole Glitch Tide visual treatment on or off. Called from the
-- GlitchTideUpdate remote handler below and from GlitchTideController.
function EffectsController.SetGlitchActive(active: boolean)
	glitchActive = active
	ensureGlitchGui()
	ensureGlitchCorrection()
	local gui = glitchGui
	if gui then
		gui.Enabled = active
	end
	local correction = glitchCorrection
	if correction then
		correction.Enabled = active
	end
	if active then
		if not glitchFlicker then
			glitchFlicker = RunService.RenderStepped:Connect(function()
				-- Jitter the RGB-shift panels and flick the tint between
				-- purple and green so the screen feels unstable.
				for i, frame in glitchFrames do
					frame.Position = UDim2.fromOffset(
						math.random(-8, 8),
						math.random(-6, 6)
					)
					frame.BackgroundTransparency = 0.9 + math.random() * 0.07
					_ = i
				end
				if glitchCorrection then
					if math.random() < 0.5 then
						glitchCorrection.TintColor = Color3.fromRGB(200, 120, 255)
					else
						glitchCorrection.TintColor = Color3.fromRGB(120, 255, 170)
					end
				end
			end)
		end
	else
		if glitchFlicker then
			glitchFlicker:Disconnect()
			glitchFlicker = nil
		end
		for _, frame in glitchFrames do
			frame.Position = UDim2.fromOffset(0, 0)
		end
	end
end

function EffectsController.IsGlitchActive(): boolean
	return glitchActive
end

-- Purple/green sparkles on a teleport pad (or any glitch pad position).
local function spawnGlitchPadSparkles(position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "GlitchPadAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace
	for _, color in
		{ Color3.fromRGB(190, 90, 255), Color3.fromRGB(90, 255, 160) }
	do
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Speed = NumberRange.new(4, 10)
		emitter.Lifetime = NumberRange.new(0.5, 1.0)
		emitter.Rate = 0
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Parent = anchor
		emitter:Emit(12)
	end
	Debris:AddItem(anchor, 1.5)
end

-- A lingering purple/green aura around a glitched Brainrot. The emitter
-- lives on a small anchored part at the given position for a few seconds;
-- callers re-fire it to keep an aura alive on a moving Brainrot.
local function spawnGlitchAura(position: Vector3, lifetimeSeconds: number?)
	local anchor = Instance.new("Part")
	anchor.Name = "GlitchAuraAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 90, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 255, 160)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 90, 255)),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = NumberRange.new(1, 3)
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Rate = 18
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Parent = anchor
	Debris:AddItem(anchor, lifetimeSeconds or 3)
end

-- Steal alarm: three hard red flashes plus a shake, so a theft in progress
-- is impossible to miss even with sound muted.
local function stealAlarmFlash()
	ensureFlashGui()
	local frame = flashFrame
	if not frame then
		return
	end
	addTrauma(0.5)
	frame.BackgroundColor3 = Color3.fromRGB(255, 30, 30)
	for _ = 1, 3 do
		frame.BackgroundTransparency = 0.55
		task.wait(0.12)
		frame.BackgroundTransparency = 1
		task.wait(0.12)
	end
end

-- GlitchTideUpdate payload: a table { phase: string, secondsRemaining: number?, ... }
-- or (phase: string, secondsRemaining: number).
-- phase: "warning" | "countdown" | "active" | "ended"
-- WAVE 3 (v1.1 E) FIX: the server (TideService, v1.1 D) sends CAPITAL keys
-- {Phase="Warning"|"Active"|"Calm"|"Idle", TimeLeft=..., Stage=...,
-- StageName=..., Announcement=...} — the old handler only read the
-- lowercase `phase` key and compared case-sensitively, so it matched
-- NOTHING the server actually sends and the tide visuals never ran.
-- This handler now reads Phase or phase, lowercases it, and also reacts
-- to Stage 3 (sirens) via SoundController.
local function onGlitchTideUpdate(phaseOrData: any, secondsRemaining: number?)
	local phase: string? = nil
	local seconds: number? = secondsRemaining
	local stage: number? = nil
	local stageName: string? = nil
	if typeof(phaseOrData) == "table" then
		local rawPhase = phaseOrData.Phase or phaseOrData.phase
		if typeof(rawPhase) == "string" then
			phase = string.lower(rawPhase)
		end
		if typeof(phaseOrData.TimeLeft) == "number" then
			seconds = phaseOrData.TimeLeft
		elseif typeof(phaseOrData.SecondsLeft) == "number" then
			seconds = phaseOrData.SecondsLeft
		elseif typeof(phaseOrData.secondsRemaining) == "number" then
			seconds = phaseOrData.secondsRemaining
		end
		if typeof(phaseOrData.Stage) == "number" then
			stage = phaseOrData.Stage
		end
		if typeof(phaseOrData.StageName) == "string" then
			stageName = phaseOrData.StageName
		end
	elseif typeof(phaseOrData) == "string" then
		phase = string.lower(phaseOrData)
	end
	-- Stage 3 is the siren stage (TideService.broadcastStage): play the
	-- siren cue + a shake even before the "active" phase arrives.
	if stage == 3 then
		pcall(function()
			local mod = script.Parent:FindFirstChild("SoundController")
			if mod then
				local sound = require(mod)
				if sound.PlaySiren then
					sound.PlaySiren()
				end
			end
		end)
		addTrauma(0.3)
	end
	_ = stageName
	if phase == "warning" or phase == "countdown" then
		-- Warning only: light distortion, no full color shift yet.
		EffectsController.SetGlitchActive(false)
		hitFlash(Color3.fromRGB(190, 90, 255), 0.2)
		_ = seconds
	elseif phase == "active" or phase == "tide" then
		EffectsController.SetGlitchActive(true)
		addTrauma(0.4)
	elseif phase == "ended" or phase == "calm" or phase == "idle" then
		EffectsController.SetGlitchActive(false)
		spawnPoof(player.Character and (player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?) and (player.Character:FindFirstChild("HumanoidRootPart") :: BasePart).Position or Vector3.new(0, 5, 0))
	end
end

-- ---------------------------------------------------------------------------
-- Remote handlers.
-- ---------------------------------------------------------------------------
-- SpawnEffect payload — TWO forms, both accepted (Wave 3 v1.1 E fix for
-- audit §3 F1 / QA_V11_B §4: the handler only spoke positional, the
-- servers mostly speak table, so most server FX was a silent no-op):
--   POSITIONAL (B/C new fires): (effectType: string, position: Vector3, extra: any)
--   TABLE (pre-existing fires from AbilityService / CombatService /
--     BossService / ProgressionService / TideService): a single table
--     {type="Power"|"BossShockwave"|"TideSiren"|..., position=Vector3,
--     radius=..., color=..., player=..., bossId=..., ...}
-- Table types are mapped to the same visuals the positional form uses;
-- an unknown table type with a position still gets a particle burst so
-- a new server effect type degrades to *something visible* instead of
-- nothing. Table fires with no position (counts-only payloads such as
-- {type="ToxicPools", count=3}) are intentionally ignored — there is
-- nowhere to draw them.
local function tableEffectColor(typeName: string): Color3
	if string.find(typeName, "Boss") == 1 or string.find(typeName, "Void") == 1 then
		return Color3.fromRGB(170, 60, 255)
	elseif string.find(typeName, "Tide") == 1 then
		return Color3.fromRGB(190, 90, 255)
	elseif string.find(typeName, "Meteor") == 1 or string.find(typeName, "Starfall") == 1 then
		return Color3.fromRGB(255, 150, 60)
	elseif string.find(typeName, "Toxic") == 1 then
		return Color3.fromRGB(90, 255, 90)
	elseif string.find(typeName, "Glitch") == 1 then
		return Color3.fromRGB(90, 255, 160)
	end
	return Color3.fromRGB(120, 180, 255)
end

local function onSpawnEffectTable(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local typeName = payload.type or payload.Type or payload.Effect or ""
	if typeof(typeName) ~= "string" or typeName == "" then
		return
	end
	local position = payload.position or payload.Position
	if typeof(position) ~= "Vector3" then
		-- Count-only / announcement-only table fires (e.g. ToxicPools
		-- {count=3}, TideShelters {count=3}): nothing to draw here.
		return
	end
	local color: Color3 = tableEffectColor(typeName)
	if typeof(payload.color) == "Color3" then
		color = payload.color
	end
	local radius = 8
	if typeof(payload.radius) == "number" then
		radius = payload.radius
	elseif typeof(payload.Radius) == "number" then
		radius = payload.Radius
	end
	if typeName == "TideSiren" then
		-- Siren stage: flash + shake; the siren SOUND is played by
		-- the GlitchTideUpdate stage-3 branch (no double cue).
		hitFlash(Color3.fromRGB(190, 90, 255), 0.3)
		addTrauma(0.4)
		return
	end
	if typeName == "TideClimax" or typeName == "BossGlitchNova" or typeName == "BossVoidNova" then
		spawnAoERing(position, math.max(radius, 14), color)
		hitFlash(color, 0.3)
		addTrauma(0.5)
		return
	end
	if typeName == "BossShockwave" or typeName == "BossVoidZone" or typeName == "BossVoidBolt" then
		spawnAoERing(position, radius, color)
		spawnParticles(position, "ability", 16)
		addTrauma(0.3)
		return
	end
	if typeName == "BossTeleport" or typeName == "BossTeleportArrive" or typeName == "GlitchTeleport" then
		spawnGlitchPadSparkles(position)
		spawnPoof(position)
		return
	end
	if typeName == "SecretEncounter" or typeName == "Starfall" or typeName == "MeteorFallout" then
		spawnAoERing(position, radius, color)
		spawnParticles(position, "coin", 18)
		return
	end
	if typeName == "TideSurf" or typeName == "GlitchTeleport" then
		spawnGlitchPadSparkles(position)
		return
	end
	if typeName == "Power" or typeName == "Ability" then
		-- Character power / ability fire: ring in the power colour +
		-- flash. The payload's `player` field is the caster's name.
		spawnAoERing(position, radius, color)
		hitFlash(color, 0.2)
		return
	end
	-- Generic fallback for any other table type with a position:
	-- a ring + burst in the type's colour, so new server effects are
	-- visible instead of silently dropped.
	spawnAoERing(position, radius, color)
	spawnParticles(position, "ability", 12)
end

-- SpawnEffect payload: (effectType: string, position: Vector3, extra: any)
-- effectType: "hit" | "ko" | "heal" | "ability" | "coin" | "poof" | "wave" |
--   "ring" | "flash" | "shake"
-- A single TABLE argument is the table form (see above) and is routed
-- to onSpawnEffectTable.
local function onSpawnEffect(effectType: string, position: Vector3, extra: any)
	if typeof(effectType) == "table" then
		onSpawnEffectTable(effectType)
		return
	end
	if typeof(effectType) ~= "string" then
		return
	end
	if typeof(position) ~= "Vector3" then
		return
	end
	if effectType == "shake" then
		local amount = 0.35
		if typeof(extra) == "number" then
			amount = extra
		end
		addTrauma(amount)
		return
	end
	if effectType == "flash" then
		local color = Color3.fromRGB(255, 255, 255)
		if typeof(extra) == "Color3" then
			color = extra
		end
		hitFlash(color, 0.35)
		return
	end
	if effectType == "ring" then
		local radius = 8
		local color = Color3.fromRGB(120, 180, 255)
		if typeof(extra) == "table" then
			if typeof(extra.radius) == "number" then
				radius = extra.radius
			end
			if typeof(extra.color) == "Color3" then
				color = extra.color
			end
		end
		spawnAoERing(position, radius, color)
		return
	end
	if effectType == "poof" then
		spawnPoof(position)
		return
	end
	if effectType == "glitchPad" or effectType == "teleport" then
		spawnGlitchPadSparkles(position)
		return
	end
	if effectType == "glitchAura" then
		local lifetime = 3
		if typeof(extra) == "number" then
			lifetime = extra
		elseif typeof(extra) == "table" and typeof(extra.lifetime) == "number" then
			lifetime = extra.lifetime
		end
		spawnGlitchAura(position, lifetime)
		return
	end
	if effectType == "stealAlarm" then
		task.spawn(stealAlarmFlash)
		spawnParticles(position, "ko", 16)
		return
	end
	if effectType == "glitch" then
		spawnGlitchPadSparkles(position)
		addTrauma(0.25)
		return
	end
	if effectType == "hit" then
		spawnParticles(position, "hit", 10)
		addTrauma(0.12)
		return
	end
	if effectType == "ko" then
		spawnParticles(position, "ko", 24)
		addTrauma(0.45)
		hitFlash(Color3.fromRGB(255, 60, 60), 0.25)
		return
	end
	-- heal / ability / coin / wave fall through to a plain particle burst.
	spawnParticles(position, effectType, 14)
end

-- DamageNumber payload — TWO forms (Wave 3 v1.1 E fix; same mismatch as
-- SpawnEffect): the server (CombatService) fires a single TABLE
-- {target=Vector3, amount=number, isCrit=bool, isHeal=bool}, but the old
-- handler only spoke positional (position, amount, isCrit, isHeal) and
-- the HUD listener expected (targetPlayer, amount). The table form
-- crashed spawnDamageNumber (CFrame.new(table)) or silently did
-- nothing. Both forms are now accepted. The server only fires
-- DamageNumber at the attacker / victim, so any received number is
-- for the local player.
-- OPTIMIZATION: at most 40 live damage-number anchors; beyond that a
-- new number is dropped instead of spawning unbounded GUI/parts in a
-- big fight.
local _liveDamageNumbers = 0

local function onDamageNumber(a: any, amount: any, isCrit: any, isHeal: any)
	if _liveDamageNumbers >= 40 then
		return
	end
	if typeof(a) == "table" then
		local position = a.target or a.Position or a.position
		if typeof(position) ~= "Vector3" then
			return
		end
		local n = tonumber(a.amount) or 0
		_liveDamageNumbers += 1
		spawnDamageNumber(position, n, a.isCrit == true, a.isHeal == true)
		task.delay(1.0, function()
			_liveDamageNumbers = math.max(0, _liveDamageNumbers - 1)
		end)
		return
	end
	if typeof(a) == "Vector3" and typeof(amount) == "number" then
		_liveDamageNumbers += 1
		spawnDamageNumber(a, amount, isCrit == true, isHeal == true)
		task.delay(1.0, function()
			_liveDamageNumbers = math.max(0, _liveDamageNumbers - 1)
		end)
	end
end

function EffectsController.Init()
	local rs = ReplicatedStorage:WaitForChild("Remotes")
	remotes = rs :: Folder
	startShakeLoop()

	local spawnEffect = remotes:WaitForChild("SpawnEffect")
	local damageNumber = remotes:WaitForChild("DamageNumber")
	if spawnEffect:IsA("RemoteEvent") then
		(spawnEffect :: RemoteEvent).OnClientEvent:Connect(onSpawnEffect)
	end
	if damageNumber:IsA("RemoteEvent") then
		(damageNumber :: RemoteEvent).OnClientEvent:Connect(onDamageNumber)
	end
	-- GlitchTideUpdate may be added by the server builders; do not block
	-- Init on it — wait in the background and wire up if it appears.
	task.spawn(function()
		local ok, glitchRemote = pcall(function()
			return remotes:WaitForChild("GlitchTideUpdate", 30)
		end)
		if ok and glitchRemote and glitchRemote:IsA("RemoteEvent") then
			(glitchRemote :: RemoteEvent).OnClientEvent:Connect(onGlitchTideUpdate)
		end
	end)
end

-- Public helpers so other client controllers can trigger local-only effects
-- without a server round trip (e.g. the local player's own attack impact).
function EffectsController.Shake(amount: number)
	addTrauma(amount)
end

function EffectsController.Flash(color: Color3, strength: number)
	hitFlash(color, strength)
end

function EffectsController.Burst(position: Vector3, effectType: string, count: number)
	spawnParticles(position, effectType, count)
end

function EffectsController.Ring(position: Vector3, radius: number, color: Color3)
	spawnAoERing(position, radius, color)
end

function EffectsController.Poof(position: Vector3)
	spawnPoof(position)
end

function EffectsController.GlitchPadSparkles(position: Vector3)
	spawnGlitchPadSparkles(position)
end

function EffectsController.GlitchAura(position: Vector3, lifetimeSeconds: number?)
	spawnGlitchAura(position, lifetimeSeconds)
end

function EffectsController.StealAlarm(position: Vector3)
	task.spawn(stealAlarmFlash)
	spawnParticles(position, "ko", 16)
end

return EffectsController
