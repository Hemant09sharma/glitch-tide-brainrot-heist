--!strict
-- LightingService.luau
-- Glitch Tide v1.1 (Workstream A) — professional lighting + mood system.
-- Owns the Lighting service's global properties and the post-effect
-- stack (ColorCorrection, Atmosphere, Bloom, DepthOfField, SunRays),
-- and exposes a named-mood API with smooth tweened transitions.
--
-- HOW OTHER SERVICES CALL IT (nil-safe by design):
--   local ok, LightingService = pcall(require, <LightingService module>)
--   if ok and LightingService.SetMood then
--       LightingService.SetMood("TideWarning") -- returns true/false
--   end
-- TideService (another workstream) is expected to call SetMood on
-- Warning / Active / Calm ("TideWarning" / "TideActive" / "Hub") and
-- on tide variations ("Toxic" / "Frozen" / "Meteor"). SetMood never
-- errors on an unknown mood name: it warns and returns false, leaving
-- the current mood untouched.
--
-- LIGHTING IS GLOBAL: one mood applies to the whole server. A mood is
-- therefore a server-wide state, not a per-player one — Dimensions
-- moods ("Abyssal" / "Skyfall") are applied only by an explicit
-- DimensionsService.ApplyDimensionMood call, never automatically on a
-- single player's teleport (that would re-light the hub for everyone).
--
-- Init signature (matches GameManager's generic optional-service
-- fallback, so no special-casing is strictly required):
--   LightingService.Init(dataService, economyService, map)
-- The first two arguments are accepted and ignored; `map` is optional
-- and only used to find portal PointLights to tint per mood. Init()
-- with no arguments, or Init(map), also works.

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local LightingService = {}

type MoodDef = {
	ClockTime: number,
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogColor: Color3,
	FogStart: number,
	FogEnd: number,
	ColorCorrection: {
		TintColor: Color3,
		Contrast: number,
		Saturation: number,
		Brightness: number,
	},
	Atmosphere: {
		Density: number,
		Offset: number,
		Color: Color3,
		Decay: Color3,
		Glare: number,
		Haze: number,
	},
	Bloom: {
		Intensity: number,
		Size: number,
		Threshold: number,
	},
	DepthOfField: {
		Enabled: boolean,
		FarIntensity: number,
		FocusDistance: number,
		InFocusRadius: number,
		NearIntensity: number,
	},
	SunRays: {
		Enabled: boolean,
		Intensity: number,
		Spread: number,
	},
	AccentColor: Color3, -- tint applied to portal PointLights
}

local TRANSITION_SECONDS = 2.5

local MOODS: { [string]: MoodDef } = {
	Hub = {
		ClockTime = 14,
		Brightness = 2,
		Ambient = Color3.fromRGB(90, 90, 110),
		OutdoorAmbient = Color3.fromRGB(110, 110, 130),
		FogColor = Color3.fromRGB(150, 120, 220),
		FogStart = 200,
		FogEnd = 900,
		ColorCorrection = { TintColor = Color3.fromRGB(255, 255, 255), Contrast = 0, Saturation = 0, Brightness = 0 },
		Atmosphere = { Density = 0.3, Offset = 0.2, Color = Color3.fromRGB(200, 180, 230), Decay = Color3.fromRGB(120, 100, 160), Glare = 0, Haze = 1 },
		Bloom = { Intensity = 0.3, Size = 12, Threshold = 0.9 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = true, Intensity = 0.08, Spread = 0.7 },
		AccentColor = Color3.fromRGB(180, 80, 255),
	},
	Market = {
		ClockTime = 15.5,
		Brightness = 2.2,
		Ambient = Color3.fromRGB(110, 95, 80),
		OutdoorAmbient = Color3.fromRGB(130, 115, 95),
		FogColor = Color3.fromRGB(220, 190, 140),
		FogStart = 180,
		FogEnd = 800,
		ColorCorrection = { TintColor = Color3.fromRGB(255, 240, 210), Contrast = 0.05, Saturation = 0.1, Brightness = 0 },
		Atmosphere = { Density = 0.25, Offset = 0.2, Color = Color3.fromRGB(230, 200, 150), Decay = Color3.fromRGB(160, 130, 90), Glare = 0, Haze = 1 },
		Bloom = { Intensity = 0.4, Size = 14, Threshold = 0.85 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = true, Intensity = 0.12, Spread = 0.6 },
		AccentColor = Color3.fromRGB(255, 200, 60),
	},
	Abyssal = {
		ClockTime = 0,
		Brightness = 1,
		Ambient = Color3.fromRGB(10, 30, 55),
		OutdoorAmbient = Color3.fromRGB(15, 40, 70),
		FogColor = Color3.fromRGB(10, 40, 80),
		FogStart = 40,
		FogEnd = 220,
		ColorCorrection = { TintColor = Color3.fromRGB(150, 200, 255), Contrast = 0.1, Saturation = 0.15, Brightness = -0.05 },
		Atmosphere = { Density = 0.6, Offset = 0.1, Color = Color3.fromRGB(20, 70, 120), Decay = Color3.fromRGB(10, 40, 80), Glare = 0.3, Haze = 2 },
		Bloom = { Intensity = 0.7, Size = 20, Threshold = 0.6 },
		DepthOfField = { Enabled = true, FarIntensity = 0.6, FocusDistance = 30, InFocusRadius = 15, NearIntensity = 0.2 },
		SunRays = { Enabled = false, Intensity = 0, Spread = 0.7 },
		AccentColor = Color3.fromRGB(40, 140, 255),
	},
	Skyfall = {
		ClockTime = 10,
		Brightness = 2.5,
		Ambient = Color3.fromRGB(130, 150, 190),
		OutdoorAmbient = Color3.fromRGB(150, 175, 220),
		FogColor = Color3.fromRGB(180, 210, 240),
		FogStart = 250,
		FogEnd = 1200,
		ColorCorrection = { TintColor = Color3.fromRGB(255, 255, 255), Contrast = 0, Saturation = 0.05, Brightness = 0.05 },
		Atmosphere = { Density = 0.15, Offset = 0.3, Color = Color3.fromRGB(200, 220, 250), Decay = Color3.fromRGB(150, 180, 220), Glare = 0.2, Haze = 0.5 },
		Bloom = { Intensity = 0.35, Size = 16, Threshold = 0.9 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = true, Intensity = 0.25, Spread = 0.5 },
		AccentColor = Color3.fromRGB(255, 220, 120),
	},
	TideWarning = {
		ClockTime = 17,
		Brightness = 1.6,
		Ambient = Color3.fromRGB(110, 60, 50),
		OutdoorAmbient = Color3.fromRGB(130, 75, 60),
		FogColor = Color3.fromRGB(200, 110, 80),
		FogStart = 150,
		FogEnd = 700,
		ColorCorrection = { TintColor = Color3.fromRGB(255, 200, 170), Contrast = 0.1, Saturation = 0.15, Brightness = 0 },
		Atmosphere = { Density = 0.45, Offset = 0.15, Color = Color3.fromRGB(220, 120, 80), Decay = Color3.fromRGB(150, 80, 60), Glare = 0.2, Haze = 1.5 },
		Bloom = { Intensity = 0.5, Size = 16, Threshold = 0.8 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = true, Intensity = 0.15, Spread = 0.6 },
		AccentColor = Color3.fromRGB(255, 60, 40),
	},
	TideActive = {
		ClockTime = 18.5,
		Brightness = 1.2,
		Ambient = Color3.fromRGB(40, 40, 70),
		OutdoorAmbient = Color3.fromRGB(55, 55, 90),
		FogColor = Color3.fromRGB(60, 60, 120),
		FogStart = 80,
		FogEnd = 500,
		ColorCorrection = { TintColor = Color3.fromRGB(170, 170, 255), Contrast = 0.15, Saturation = 0.1, Brightness = -0.05 },
		Atmosphere = { Density = 0.55, Offset = 0.1, Color = Color3.fromRGB(70, 70, 140), Decay = Color3.fromRGB(40, 40, 90), Glare = 0.4, Haze = 2 },
		Bloom = { Intensity = 0.6, Size = 18, Threshold = 0.7 },
		DepthOfField = { Enabled = true, FarIntensity = 0.5, FocusDistance = 40, InFocusRadius = 20, NearIntensity = 0.2 },
		SunRays = { Enabled = false, Intensity = 0, Spread = 0.7 },
		AccentColor = Color3.fromRGB(80, 120, 255),
	},
	Toxic = {
		ClockTime = 13,
		Brightness = 1.5,
		Ambient = Color3.fromRGB(50, 100, 40),
		OutdoorAmbient = Color3.fromRGB(70, 120, 55),
		FogColor = Color3.fromRGB(90, 160, 70),
		FogStart = 120,
		FogEnd = 600,
		ColorCorrection = { TintColor = Color3.fromRGB(190, 255, 160), Contrast = 0.05, Saturation = 0.25, Brightness = 0 },
		Atmosphere = { Density = 0.5, Offset = 0.15, Color = Color3.fromRGB(110, 190, 80), Decay = Color3.fromRGB(60, 120, 50), Glare = 0.2, Haze = 1.5 },
		Bloom = { Intensity = 0.55, Size = 18, Threshold = 0.75 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = false, Intensity = 0, Spread = 0.7 },
		AccentColor = Color3.fromRGB(120, 255, 80),
	},
	Frozen = {
		ClockTime = 11,
		Brightness = 2.4,
		Ambient = Color3.fromRGB(140, 165, 200),
		OutdoorAmbient = Color3.fromRGB(160, 185, 220),
		FogColor = Color3.fromRGB(200, 220, 245),
		FogStart = 180,
		FogEnd = 800,
		ColorCorrection = { TintColor = Color3.fromRGB(210, 230, 255), Contrast = 0, Saturation = -0.05, Brightness = 0.05 },
		Atmosphere = { Density = 0.35, Offset = 0.25, Color = Color3.fromRGB(210, 230, 250), Decay = Color3.fromRGB(170, 200, 230), Glare = 0.1, Haze = 1 },
		Bloom = { Intensity = 0.45, Size = 16, Threshold = 0.85 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = true, Intensity = 0.18, Spread = 0.6 },
		AccentColor = Color3.fromRGB(160, 220, 255),
	},
	Meteor = {
		ClockTime = 19,
		Brightness = 1.4,
		Ambient = Color3.fromRGB(90, 50, 40),
		OutdoorAmbient = Color3.fromRGB(110, 60, 45),
		FogColor = Color3.fromRGB(160, 80, 50),
		FogStart = 120,
		FogEnd = 600,
		ColorCorrection = { TintColor = Color3.fromRGB(255, 190, 150), Contrast = 0.1, Saturation = 0.2, Brightness = 0 },
		Atmosphere = { Density = 0.5, Offset = 0.1, Color = Color3.fromRGB(200, 100, 60), Decay = Color3.fromRGB(130, 60, 40), Glare = 0.5, Haze = 2 },
		Bloom = { Intensity = 0.7, Size = 22, Threshold = 0.65 },
		DepthOfField = { Enabled = false, FarIntensity = 0, FocusDistance = 50, InFocusRadius = 20, NearIntensity = 0 },
		SunRays = { Enabled = true, Intensity = 0.1, Spread = 0.8 },
		AccentColor = Color3.fromRGB(255, 120, 40),
	},
	Dark = {
		ClockTime = 0,
		Brightness = 0.8,
		Ambient = Color3.fromRGB(20, 20, 35),
		OutdoorAmbient = Color3.fromRGB(30, 30, 50),
		FogColor = Color3.fromRGB(15, 15, 30),
		FogStart = 60,
		FogEnd = 400,
		ColorCorrection = { TintColor = Color3.fromRGB(180, 180, 220), Contrast = 0.1, Saturation = 0, Brightness = -0.05 },
		Atmosphere = { Density = 0.5, Offset = 0.1, Color = Color3.fromRGB(30, 30, 60), Decay = Color3.fromRGB(15, 15, 35), Glare = 0, Haze = 1.5 },
		Bloom = { Intensity = 0.4, Size = 14, Threshold = 0.7 },
		DepthOfField = { Enabled = true, FarIntensity = 0.5, FocusDistance = 30, InFocusRadius = 15, NearIntensity = 0.2 },
		SunRays = { Enabled = false, Intensity = 0, Spread = 0.7 },
		AccentColor = Color3.fromRGB(120, 80, 220),
	},
	Cosmic = {
		ClockTime = 1,
		Brightness = 1.1,
		Ambient = Color3.fromRGB(50, 30, 80),
		OutdoorAmbient = Color3.fromRGB(65, 40, 100),
		FogColor = Color3.fromRGB(80, 50, 140),
		FogStart = 100,
		FogEnd = 700,
		ColorCorrection = { TintColor = Color3.fromRGB(220, 180, 255), Contrast = 0.1, Saturation = 0.2, Brightness = 0 },
		Atmosphere = { Density = 0.45, Offset = 0.15, Color = Color3.fromRGB(100, 60, 170), Decay = Color3.fromRGB(60, 35, 110), Glare = 0.3, Haze = 1.5 },
		Bloom = { Intensity = 0.8, Size = 24, Threshold = 0.55 },
		DepthOfField = { Enabled = true, FarIntensity = 0.4, FocusDistance = 40, InFocusRadius = 20, NearIntensity = 0.1 },
		SunRays = { Enabled = false, Intensity = 0, Spread = 0.7 },
		AccentColor = Color3.fromRGB(200, 80, 255),
	},
	Boss = {
		ClockTime = 18,
		Brightness = 1.3,
		Ambient = Color3.fromRGB(90, 25, 25),
		OutdoorAmbient = Color3.fromRGB(110, 35, 35),
		FogColor = Color3.fromRGB(120, 30, 30),
		FogStart = 100,
		FogEnd = 550,
		ColorCorrection = { TintColor = Color3.fromRGB(255, 170, 170), Contrast = 0.15, Saturation = 0.2, Brightness = 0 },
		Atmosphere = { Density = 0.5, Offset = 0.1, Color = Color3.fromRGB(160, 40, 40), Decay = Color3.fromRGB(100, 20, 20), Glare = 0.4, Haze = 2 },
		Bloom = { Intensity = 0.7, Size = 20, Threshold = 0.65 },
		DepthOfField = { Enabled = true, FarIntensity = 0.5, FocusDistance = 35, InFocusRadius = 15, NearIntensity = 0.2 },
		SunRays = { Enabled = false, Intensity = 0, Spread = 0.7 },
		AccentColor = Color3.fromRGB(255, 40, 40),
	},
}

local _currentMood = "Hub"
local _initialized = false
local _tweens: { Tween } = {}
local _portalLights: { PointLight } = {}
local _colorCorrection: ColorCorrectionEffect? = nil
local _atmosphere: Atmosphere? = nil
local _bloom: BloomEffect? = nil
local _depthOfField: DepthOfFieldEffect? = nil
local _sunRays: SunRaysEffect? = nil

local function cancelTweens(): ()
	for _, tween in ipairs(_tweens) do
		pcall(function()
			tween:Cancel()
		end)
	end
	_tweens = {}
end

local function tweenInstance(instance: Instance, props: { [string]: any }): ()
	local ok, tween = pcall(function()
		return TweenService:Create(instance,
			TweenInfo.new(TRANSITION_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), props)
	end)
	if ok and tween ~= nil then
		table.insert(_tweens, tween)
		tween:Play()
	end
end

local function ensureEffects(): ()
	if _colorCorrection == nil then
		local existing = Lighting:FindFirstChild("V11ColorCorrection")
		if existing and existing:IsA("ColorCorrectionEffect") then
			_colorCorrection = existing
		else
			local effect = Instance.new("ColorCorrectionEffect")
			effect.Name = "V11ColorCorrection"
			effect.Parent = Lighting
			_colorCorrection = effect
		end
	end
	if _atmosphere == nil then
		local existing = Lighting:FindFirstChild("V11Atmosphere")
		if existing and existing:IsA("Atmosphere") then
			_atmosphere = existing
		else
			local effect = Instance.new("Atmosphere")
			effect.Name = "V11Atmosphere"
			effect.Parent = Lighting
			_atmosphere = effect
		end
	end
	if _bloom == nil then
		local existing = Lighting:FindFirstChild("V11Bloom")
		if existing and existing:IsA("BloomEffect") then
			_bloom = existing
		else
			local effect = Instance.new("BloomEffect")
			effect.Name = "V11Bloom"
			effect.Parent = Lighting
			_bloom = effect
		end
	end
	if _depthOfField == nil then
		local existing = Lighting:FindFirstChild("V11DepthOfField")
		if existing and existing:IsA("DepthOfFieldEffect") then
			_depthOfField = existing
		else
			local effect = Instance.new("DepthOfFieldEffect")
			effect.Name = "V11DepthOfField"
			effect.Parent = Lighting
			_depthOfField = effect
		end
	end
	if _sunRays == nil then
		local existing = Lighting:FindFirstChild("V11SunRays")
		if existing and existing:IsA("SunRaysEffect") then
			_sunRays = existing
		else
			local effect = Instance.new("SunRaysEffect")
			effect.Name = "V11SunRays"
			effect.Parent = Lighting
			_sunRays = effect
		end
	end
end

-- Collect the portal PointLights (parents named "PortalSwirl") so a
-- mood can tint them. Plot lights and the tower/siren lights are left
-- alone — they belong to their zones, not to the mood.
local function collectPortalLights(map: Instance?): ()
	_portalLights = {}
	if map == nil then
		return
	end
	pcall(function()
		for _, descendant in ipairs(map:GetDescendants()) do
			if descendant:IsA("PointLight") then
				local parent = descendant.Parent
				if parent ~= nil and parent.Name == "PortalSwirl" then
					table.insert(_portalLights, descendant)
				end
			end
		end
	end)
end

local function applyMood(mood: MoodDef, instant: boolean): ()
	ensureEffects()
	if instant then
		cancelTweens()
		pcall(function()
			Lighting.ClockTime = mood.ClockTime
			Lighting.Brightness = mood.Brightness
			Lighting.Ambient = mood.Ambient
			Lighting.OutdoorAmbient = mood.OutdoorAmbient
			Lighting.FogColor = mood.FogColor
			Lighting.FogStart = mood.FogStart
			Lighting.FogEnd = mood.FogEnd
		end)
	else
		tweenInstance(Lighting, {
			ClockTime = mood.ClockTime,
			Brightness = mood.Brightness,
			Ambient = mood.Ambient,
			OutdoorAmbient = mood.OutdoorAmbient,
			FogColor = mood.FogColor,
			FogStart = mood.FogStart,
			FogEnd = mood.FogEnd,
		})
	end
	if _colorCorrection ~= nil then
		local cc = mood.ColorCorrection
		if instant then
			local ccEffect = _colorCorrection :: ColorCorrectionEffect
			pcall(function()
				ccEffect.TintColor = cc.TintColor
				ccEffect.Contrast = cc.Contrast
				ccEffect.Saturation = cc.Saturation
				ccEffect.Brightness = cc.Brightness
			end)
		else
			tweenInstance(_colorCorrection, {
				TintColor = cc.TintColor,
				Contrast = cc.Contrast,
				Saturation = cc.Saturation,
				Brightness = cc.Brightness,
			})
		end
	end
	if _atmosphere ~= nil then
		local at = mood.Atmosphere
		if instant then
			local atEffect = _atmosphere :: Atmosphere
			pcall(function()
				atEffect.Density = at.Density
				atEffect.Offset = at.Offset
				atEffect.Color = at.Color
				atEffect.Decay = at.Decay
				atEffect.Glare = at.Glare
				atEffect.Haze = at.Haze
			end)
		else
			tweenInstance(_atmosphere, {
				Density = at.Density,
				Offset = at.Offset,
				Color = at.Color,
				Decay = at.Decay,
				Glare = at.Glare,
				Haze = at.Haze,
			})
		end
	end
	if _bloom ~= nil then
		local bl = mood.Bloom
		if instant then
			local blEffect = _bloom :: BloomEffect
			pcall(function()
				blEffect.Intensity = bl.Intensity
				blEffect.Size = bl.Size
				blEffect.Threshold = bl.Threshold
			end)
		else
			tweenInstance(_bloom, {
				Intensity = bl.Intensity,
				Size = bl.Size,
				Threshold = bl.Threshold,
			})
		end
	end
	if _depthOfField ~= nil then
		local dof = mood.DepthOfField
		pcall(function()
			(_depthOfField :: DepthOfFieldEffect).Enabled = dof.Enabled
		end)
		if instant then
			local dofEffect = _depthOfField :: DepthOfFieldEffect
			pcall(function()
				dofEffect.FarIntensity = dof.FarIntensity
				dofEffect.FocusDistance = dof.FocusDistance
				dofEffect.InFocusRadius = dof.InFocusRadius
				dofEffect.NearIntensity = dof.NearIntensity
			end)
		else
			tweenInstance(_depthOfField, {
				FarIntensity = dof.FarIntensity,
				FocusDistance = dof.FocusDistance,
				InFocusRadius = dof.InFocusRadius,
				NearIntensity = dof.NearIntensity,
			})
		end
	end
	if _sunRays ~= nil then
		local sr = mood.SunRays
		pcall(function()
			(_sunRays :: SunRaysEffect).Enabled = sr.Enabled
		end)
		if instant then
			local srEffect = _sunRays :: SunRaysEffect
			pcall(function()
				srEffect.Intensity = sr.Intensity
				srEffect.Spread = sr.Spread
			end)
		else
			tweenInstance(_sunRays, {
				Intensity = sr.Intensity,
				Spread = sr.Spread,
			})
		end
	end
	-- Tint portal lights to the mood accent (no new lights created).
	for _, light in ipairs(_portalLights) do
		if instant then
			pcall(function()
				light.Color = mood.AccentColor
			end)
		else
			tweenInstance(light, { Color = mood.AccentColor })
		end
	end
end

-- Init(dataService, economyService, map) — the generic optional-service
-- shape. dataService / economyService are accepted and ignored; map is
-- optional (portal-light tinting only). Init(), Init(map) also work.
function LightingService.Init(a: any, _b: any, c: any): ()
	local map: Instance? = nil
	if typeof(a) == "Instance" then
		map = a
	elseif typeof(c) == "Instance" then
		map = c
	end
	ensureEffects()
	collectPortalLights(map)
	local hub = MOODS["Hub"]
	if hub ~= nil then
		applyMood(hub, true)
		_currentMood = "Hub"
	end
	_initialized = true
	print("[LightingService] Initialised (mood: Hub)")
end

-- SetMood(moodName) -> boolean. Unknown names warn and return false;
-- the current mood is left untouched. Transitions tween over ~2.5s.
function LightingService.SetMood(moodName: string): boolean
	if type(moodName) ~= "string" or moodName == "" then
		warn("[LightingService] SetMood called with an invalid mood name")
		return false
	end
	local mood = MOODS[moodName]
	if mood == nil then
		warn("[LightingService] Unknown mood: " .. moodName)
		return false
	end
	if moodName == _currentMood and _initialized then
		return true
	end
	cancelTweens()
	applyMood(mood, false)
	_currentMood = moodName
	return true
end

function LightingService.GetMood(): string
	return _currentMood
end

function LightingService.GetMoods(): { string }
	local names: { string } = {}
	for name, _ in pairs(MOODS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function LightingService.IsInitialized(): boolean
	return _initialized
end

return LightingService
