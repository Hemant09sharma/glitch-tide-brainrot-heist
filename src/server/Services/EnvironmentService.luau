--!strict
-- EnvironmentService.luau
-- Glitch Tide v1.1 (Workstream A) — environmental animation.
-- One Heartbeat loop drives every moving piece of scenery from cached
-- base CFrames with sine math: rotating portal swirls, bobbing fountain
-- water and buoys, pulsing beacons and sirens, spinning lab coils,
-- swaying Abyssal plant bulbs, orbiting Sky Wisps, drifting clouds,
-- and the market sign's colour cycle. No Instance is created per frame
-- (everything is found once in Init and reused); every part is
-- anchored, so there is no physics spam. Missing parts are skipped
-- with one warn at Init — the service degrades gracefully on a
-- partial or older map.
--
-- Event reactions: SetEventMode("TideWarning" | "TideActive" |
-- "Boss" | "Celebration" | "Normal") speeds up the portal spin and
-- siren pulse for the matching event. TideService / EventService /
-- BossService can call it; unknown modes warn and return false.
--
-- Init signature (matches GameManager's generic optional-service
-- fallback): EnvironmentService.Init(dataService, economyService, map).
-- The first two arguments are accepted and ignored; Init(), Init(map)
-- also work. The map is the GlitchTideWorld model built by MapBuilder.

local RunService = game:GetService("RunService")

local EnvironmentService = {}

type SpinEntry = {
	Part: BasePart,
	Base: CFrame,
	Axis: string, -- "X" | "Y" | "Z"
	Speed: number, -- radians per second at Normal speed
	Phase: number,
}
type BobEntry = {
	Part: BasePart,
	Base: CFrame,
	Amplitude: number,
	Speed: number,
	Phase: number,
}
type PulseEntry = {
	Part: BasePart,
	Speed: number,
	Phase: number,
	Min: number, -- transparency at the bottom of the pulse
	Max: number, -- transparency at the top of the pulse
}
type SwayEntry = {
	Part: BasePart,
	Base: CFrame,
	Angle: number, -- max radians of tilt
	Speed: number,
	Phase: number,
}
type OrbitEntry = {
	Body: BasePart,
	Trail: BasePart?,
	Center: Vector3,
	Radius: number,
	Height: number,
	Speed: number,
	Phase: number,
}

local EVENT_MODES: { [string]: boolean } = {
	Normal = true,
	TideWarning = true,
	TideActive = true,
	Boss = true,
	Celebration = true,
}

local _spins: { SpinEntry } = {}
local _bobs: { BobEntry } = {}
local _pulses: { PulseEntry } = {}
local _sways: { SwayEntry } = {}
local _orbits: { OrbitEntry } = {}
local _signLabels: { TextLabel } = {}
local _sirenTops: { BasePart } = {}
local _eventMode = "Normal"
local _spinMultiplier = 1
local _sirenMultiplier = 1
local _running = false
local _startTime = 0
local _map: Instance? = nil
local _connection: RBXScriptConnection? = nil

local SIGN_COLORS: { Color3 } = {
	Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(120, 220, 255),
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(120, 255, 170),
}

local function findFirst(root: Instance, name: string): Instance?
	if root == nil then
		return nil
	end
	local ok, found = pcall(function()
		return root:FindFirstChild(name, true)
	end)
	if ok then
		return found
	end
	return nil
end

local function collect(map: Instance): ()
	_spins = {}
	_bobs = {}
	_pulses = {}
	_sways = {}
	_orbits = {}
	_signLabels = {}
	_sirenTops = {}

	-- Portal swirls (hub main portal, hub dimension portals, rift,
	-- return portals — all named "PortalSwirl" by MapBuilder):
	-- spin around their facing axis (local Z).
	local swirlNames: { string } = { "PortalSwirl", "RiftPortal" }
	for _, descendant in ipairs(map:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local part = descendant :: BasePart
			if table.find(swirlNames, part.Name) ~= nil then
				table.insert(_spins, {
					Part = part,
					Base = part.CFrame,
					Axis = "Z",
					Speed = 0.6,
					Phase = math.random() * math.pi * 2,
				})
			end
		end
	end
	-- Rift portal also pulses (it is the wildest portal in the world).
	local rift = findFirst(map, "RiftPortal")
	if rift and rift:IsA("BasePart") then
		table.insert(_pulses, {
			Part = rift :: BasePart,
			Speed = 1.2,
			Phase = 0,
			Min = 0.25,
			Max = 0.55,
		})
	end

	-- Fountain water bobs; tower beacon pulses.
	local fountain = findFirst(map, "FountainWater")
	if fountain and fountain:IsA("BasePart") then
		table.insert(_bobs, {
			Part = fountain :: BasePart,
			Base = (fountain :: BasePart).CFrame,
			Amplitude = 0.25,
			Speed = 1.5,
			Phase = 0,
		})
	end
	local beacon = findFirst(map, "TowerBeacon")
	if beacon and beacon:IsA("BasePart") then
		table.insert(_pulses, {
			Part = beacon :: BasePart,
			Speed = 1.0,
			Phase = 0,
			Min = 0,
			Max = 0.6,
		})
	end

	-- Lab coils spin on Y; arena reward chest spins on Y and bobs.
	for _, coilName in ipairs({ "LabCoil1", "LabCoil2" }) do
		local coil = findFirst(map, coilName)
		if coil and coil:IsA("BasePart") then
			table.insert(_spins, {
				Part = coil :: BasePart,
				Base = (coil :: BasePart).CFrame,
				Axis = "Y",
				Speed = 1.4,
				Phase = 0,
			})
		end
	end
	local chest = findFirst(map, "RewardChest")
	if chest and chest:IsA("BasePart") then
		table.insert(_spins, {
			Part = chest :: BasePart,
			Base = (chest :: BasePart).CFrame,
			Axis = "Y",
			Speed = 0.8,
			Phase = 0,
		})
		table.insert(_bobs, {
			Part = chest :: BasePart,
			Base = (chest :: BasePart).CFrame,
			Amplitude = 0.3,
			Speed = 1.2,
			Phase = 0,
		})
	end

	-- Channel buoys bob on the water.
	for i = 1, 3 do
		local buoy = findFirst(map, "Buoy" .. tostring(i))
		if buoy and buoy:IsA("BasePart") then
			table.insert(_bobs, {
				Part = buoy :: BasePart,
				Base = (buoy :: BasePart).CFrame,
				Amplitude = 0.35,
				Speed = 1.1 + i * 0.2,
				Phase = i * 1.3,
			})
		end
	end

	-- Siren tops pulse (fast only in warning/active/boss modes).
	for i = 1, 4 do
		local siren = findFirst(map, "SirenTop" .. tostring(i))
		if siren and siren:IsA("BasePart") then
			table.insert(_sirenTops, siren :: BasePart)
			table.insert(_pulses, {
				Part = siren :: BasePart,
				Speed = 0.5,
				Phase = i * 0.7,
				Min = 0,
				Max = 0.7,
			})
		end
	end

	-- Abyssal plant glow bulbs sway.
	for i = 1, 6 do
		local bulb = findFirst(map, "PlantGlow" .. tostring(i))
		if bulb and bulb:IsA("BasePart") then
			table.insert(_sways, {
				Part = bulb :: BasePart,
				Base = (bulb :: BasePart).CFrame,
				Angle = math.rad(6),
				Speed = 0.7 + i * 0.08,
				Phase = i * 1.1,
			})
		end
	end

	-- Sky Wisps orbit their island centres; clouds drift up and down.
	-- Wisp orbit centres/radii mirror MapBuilder's layout.
	local wispDefs = {
		{ Center = Vector3.new(150, 52, -155), Radius = 12, Speed = 0.35 },
		{ Center = Vector3.new(160, 55, -165), Radius = 9, Speed = 0.5 },
		{ Center = Vector3.new(140, 58, -150), Radius = 10, Speed = 0.42 },
	}
	for i, wispDef in ipairs(wispDefs) do
		local body = findFirst(map, "SkyWisp" .. tostring(i))
		if body and body:IsA("BasePart") then
			local trail = findFirst(map, "SkyWispTrail" .. tostring(i))
			local trailPart: BasePart? = nil
			if trail and trail:IsA("BasePart") then
				trailPart = trail :: BasePart
			end
			table.insert(_orbits, {
				Body = body :: BasePart,
				Trail = trailPart,
				Center = wispDef.Center,
				Radius = wispDef.Radius,
				Height = wispDef.Center.Y,
				Speed = wispDef.Speed,
				Phase = i * 2.1,
			})
		end
	end
	for i = 1, 3 do
		local cloud = findFirst(map, "Cloud" .. tostring(i))
		if cloud and cloud:IsA("BasePart") then
			table.insert(_bobs, {
				Part = cloud :: BasePart,
				Base = (cloud :: BasePart).CFrame,
				Amplitude = 1.2,
				Speed = 0.25 + i * 0.05,
				Phase = i * 1.7,
			})
		end
	end

	-- Market sign cycles its text colour (the one animated sign).
	local marketSign = findFirst(map, "MarketSign")
	if marketSign ~= nil then
		local gui = marketSign:FindFirstChild("LabelGui")
		if gui ~= nil then
			local title = gui:FindFirstChild("Title")
			if title and title:IsA("TextLabel") then
				table.insert(_signLabels, title :: TextLabel)
			end
		end
	end

	local total = #_spins + #_bobs + #_pulses + #_sways + #_orbits + #_signLabels
	if total == 0 then
		warn("[EnvironmentService] No animated parts found on the map — running idle")
	else
		print(string.format(
			"[EnvironmentService] Collected %d animated elements (%d spin, %d bob, %d pulse, %d sway, %d orbit, %d signs)",
			total, #_spins, #_bobs, #_pulses, #_sways, #_orbits, #_signLabels))
	end
end

local function onHeartbeat(_dt: number): ()
	if not _running then
		return
	end
	local t = os.clock() - _startTime
	local spinSpeed = _spinMultiplier
	for _, entry in ipairs(_spins) do
		local angle = (t * entry.Speed * spinSpeed) + entry.Phase
		local rot: CFrame
		if entry.Axis == "X" then
			rot = CFrame.Angles(angle, 0, 0)
		elseif entry.Axis == "Y" then
			rot = CFrame.Angles(0, angle, 0)
		else
			rot = CFrame.Angles(0, 0, angle)
		end
		pcall(function()
			entry.Part.CFrame = entry.Base * rot
		end)
	end
	for _, entry in ipairs(_bobs) do
		local offset = math.sin(t * entry.Speed + entry.Phase) * entry.Amplitude
		pcall(function()
			entry.Part.CFrame = entry.Base * CFrame.new(0, offset, 0)
		end)
	end
	for _, entry in ipairs(_pulses) do
		local speed = entry.Speed
		-- Siren tops share the event multiplier; everything else pulses
		-- at its own calm rate.
		if table.find(_sirenTops, entry.Part) ~= nil then
			speed = entry.Speed * _sirenMultiplier
		end
		local wave = (math.sin(t * speed + entry.Phase) + 1) * 0.5
		pcall(function()
			entry.Part.Transparency = entry.Min + (entry.Max - entry.Min) * wave
		end)
	end
	for _, entry in ipairs(_sways) do
		local tilt = math.sin(t * entry.Speed + entry.Phase) * entry.Angle
		pcall(function()
			entry.Part.CFrame = entry.Base * CFrame.Angles(tilt, 0, tilt * 0.5)
		end)
	end
	for _, entry in ipairs(_orbits) do
		local angle = (t * entry.Speed) + entry.Phase
		local x = entry.Center.X + math.cos(angle) * entry.Radius
		local z = entry.Center.Z + math.sin(angle) * entry.Radius
		local y = entry.Height + math.sin(t * 0.9 + entry.Phase) * 1.5
		local pos = Vector3.new(x, y, z)
		-- Face along the direction of travel.
		local look = Vector3.new(
			entry.Center.X + math.cos(angle + 0.2) * entry.Radius,
			y,
			entry.Center.Z + math.sin(angle + 0.2) * entry.Radius)
		pcall(function()
			entry.Body.CFrame = CFrame.lookAt(pos, look)
			if entry.Trail ~= nil then
				local trail = entry.Trail :: BasePart
				local back = Vector3.new(
					entry.Center.X + math.cos(angle - 0.25) * entry.Radius,
					y,
					entry.Center.Z + math.sin(angle - 0.25) * entry.Radius)
				trail.CFrame = CFrame.lookAt(back, pos)
			end
		end)
	end
	-- Market sign colour cycle, one colour every ~2 seconds.
	if #_signLabels > 0 then
		local index = (math.floor(t / 2) % #SIGN_COLORS) + 1
		local color = SIGN_COLORS[index]
		for _, label in ipairs(_signLabels) do
			pcall(function()
				label.TextColor3 = color
			end)
		end
	end
end

local function applyEventMode(): ()
	if _eventMode == "TideWarning" then
		_spinMultiplier = 1.4
		_sirenMultiplier = 4
	elseif _eventMode == "TideActive" then
		_spinMultiplier = 1.8
		_sirenMultiplier = 6
	elseif _eventMode == "Boss" then
		_spinMultiplier = 2
		_sirenMultiplier = 6
	elseif _eventMode == "Celebration" then
		_spinMultiplier = 1.6
		_sirenMultiplier = 2
	else
		_spinMultiplier = 1
		_sirenMultiplier = 1
	end
end

-- Init(dataService, economyService, map) — generic optional-service
-- shape; the first two arguments are accepted and ignored. Init() or
-- Init(map) also work.
function EnvironmentService.Init(a: any, _b: any, c: any): ()
	local map: Instance? = nil
	if typeof(a) == "Instance" then
		map = a
	elseif typeof(c) == "Instance" then
		map = c
	end
	if map == nil then
		warn("[EnvironmentService] Init called without a map — animations disabled")
		_running = false
		return
	end
	_map = map
	collect(map)
	_startTime = os.clock()
	_running = true
	applyEventMode()
	if _connection ~= nil then
		pcall(function()
			(_connection :: RBXScriptConnection):Disconnect()
		end)
	end
	_connection = RunService.Heartbeat:Connect(onHeartbeat)
	print("[EnvironmentService] Initialised (mode: " .. _eventMode .. ")")
end

function EnvironmentService.SetEventMode(mode: string): boolean
	if type(mode) ~= "string" or EVENT_MODES[mode] ~= true then
		warn("[EnvironmentService] Unknown event mode: " .. tostring(mode))
		return false
	end
	_eventMode = mode
	applyEventMode()
	return true
end

function EnvironmentService.GetEventMode(): string
	return _eventMode
end

function EnvironmentService.IsRunning(): boolean
	return _running
end

function EnvironmentService.GetAnimatedCount(): number
	return #_spins + #_bobs + #_pulses + #_sways + #_orbits + #_signLabels
end

function EnvironmentService.Stop(): ()
	_running = false
	if _connection ~= nil then
		pcall(function()
			(_connection :: RBXScriptConnection):Disconnect()
		end)
		_connection = nil
	end
end

return EnvironmentService
