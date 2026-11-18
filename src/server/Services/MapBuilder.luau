--!strict
-- MapBuilder.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Builds the whole persistent world as one anchored Model in Workspace.
-- Zones: MemeversePlaza, RiftMarket (conveyor), BaseDistrict (12 plots),
-- TideChannel, MutationLab, ChaosArena, ForbiddenRift.
-- No external asset ids, no client-trusted values, part count kept sane
-- (roughly 300 parts). Lighting is set here, guarded by pcall.
-- Accessors live on this module (MapBuilder.GetBasePlot etc.): Luau
-- functions cannot carry extra fields, so Build.GetBasePlot is not a
-- real thing — call the module functions instead.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local MapBuilder = {}

local MAX_LIGHTS = 16 -- 12 plot lights + portal + tower + siren + 1 spare
local _lightCount = 0
local _built = false
local _model: Model? = nil
local _plots: { [number]: { [string]: any } } = {}
local _waypoints: { Vector3 } = {}
local _safeZones: { { Position: Vector3, Center: Vector3, Radius: number } } = {}
local _spawnPosition = Vector3.new(0, 3, 0)
local _beltParts: { BasePart } = {}
local _beltMinX = -30
local _beltMaxX = 30
local _beltY = 2.1

local function newPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = true
	part.Parent = parent
	return part
end

local function addPointLight(parent: Instance, color: Color3, range: number, brightness: number): PointLight?
	if _lightCount >= MAX_LIGHTS then
		return nil
	end
	_lightCount += 1
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Parent = parent
	return light
end

local function addLabel(part: BasePart, text: string, textSize: number, textColor: Color3): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "LabelGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = textSize
	label.TextColor3 = textColor
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = gui
	return gui
end

local function addEmitter(parent: Instance, color: Color3, rate: number, size: number): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(0.6, 1.4)
	emitter.Size = NumberSequence.new(size)
	emitter.Speed = NumberRange.new(2, 5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Parent = parent
	return emitter
end

local function buildGround(parent: Model): ()
	-- One big baseplate plus a subtle plaza disc. Everything else sits on it.
	newPart(parent, "Ground", Vector3.new(420, 2, 420), CFrame.new(0, -1, 0),
		Color3.fromRGB(46, 160, 90), Enum.Material.Grass)
	local plazaDisc = newPart(parent, "PlazaDisc", Vector3.new(46, 1, 46), CFrame.new(0, 0.1, 0),
		Color3.fromRGB(120, 90, 200), Enum.Material.Neon)
	plazaDisc.CanCollide = false
	plazaDisc.Transparency = 0.75

	-- Perimeter boundary walls: the ground ends at +/-210 with no
	-- fence, players could walk off the edge into the void. Four low
	-- walls close the map (gaps are intentional at the corners).
	local wallColor = Color3.fromRGB(70, 70, 90)
	newPart(parent, "BoundaryWallNorth", Vector3.new(420, 8, 2), CFrame.new(0, 4, -210),
		wallColor, Enum.Material.Concrete)
	newPart(parent, "BoundaryWallSouth", Vector3.new(420, 8, 2), CFrame.new(0, 4, 210),
		wallColor, Enum.Material.Concrete)
	newPart(parent, "BoundaryWallWest", Vector3.new(2, 8, 420), CFrame.new(-210, 4, 0),
		wallColor, Enum.Material.Concrete)
	newPart(parent, "BoundaryWallEast", Vector3.new(2, 8, 420), CFrame.new(210, 4, 0),
		wallColor, Enum.Material.Concrete)
end

local function buildPlaza(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "MemeversePlaza"
	folder.Parent = parent

	-- SpawnLocation: the one true respawn point.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(0, 0.5, 0)
	spawn.Color = Color3.fromRGB(90, 200, 255)
	spawn.Material = Enum.Material.Neon
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.AllowTeamChangeOnTouch = false
	spawn.Parent = folder
	_spawnPosition = Vector3.new(0, 3, 0)

	-- 12 spawn pads in a ring around the spawn point.
	for i = 1, 12 do
		local angle = (i - 1) * (math.pi * 2 / 12)
		local x = math.cos(angle) * 13
		local z = math.sin(angle) * 13
		local pad = newPart(folder, "SpawnPad" .. tostring(i), Vector3.new(3, 0.5, 3),
			CFrame.new(x, 0.25, z), Color3.fromRGB(60, 200, 255), Enum.Material.Neon)
		pad.Transparency = 0.35
		pad.CanCollide = false
	end

	-- Giant portal ring + swirling centre, north edge of the plaza.
	local portalFolder = Instance.new("Folder")
	portalFolder.Name = "PortalRing"
	portalFolder.Parent = folder
	for i = 1, 10 do
		local angle = (i - 1) * (math.pi * 2 / 10)
		local x = math.cos(angle) * 7
		local y = 10 + math.sin(angle) * 7
		newPart(portalFolder, "RingSegment" .. tostring(i), Vector3.new(2.5, 2.5, 2),
			CFrame.new(x, y, -30), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
	end
	local swirl = newPart(portalFolder, "PortalSwirl", Vector3.new(11, 11, 0.6),
		CFrame.new(0, 10, -30), Color3.fromRGB(120, 40, 220), Enum.Material.Neon)
	swirl.Transparency = 0.45
	swirl.CanCollide = false
	addEmitter(swirl, Color3.fromRGB(200, 120, 255), 24, 1.2)
	addPointLight(swirl, Color3.fromRGB(180, 80, 255), 30, 2)

	-- Landmark tower, east side of the plaza.
	local tower = Instance.new("Folder")
	tower.Name = "LandmarkTower"
	tower.Parent = folder
	newPart(tower, "TowerBase", Vector3.new(8, 6, 8), CFrame.new(22, 3, -18),
		Color3.fromRGB(70, 70, 90), Enum.Material.Concrete)
	newPart(tower, "TowerMid", Vector3.new(6, 14, 6), CFrame.new(22, 13, -18),
		Color3.fromRGB(120, 90, 200), Enum.Material.SmoothPlastic)
	local towerTop = newPart(tower, "TowerTop", Vector3.new(7, 4, 7), CFrame.new(22, 22, -18),
		Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	addPointLight(towerTop, Color3.fromRGB(255, 200, 60), 36, 2)
	newPart(tower, "TowerBeacon", Vector3.new(1.5, 8, 1.5), CFrame.new(22, 28, -18),
		Color3.fromRGB(255, 220, 100), Enum.Material.Neon)

	-- Leaderboard boards (SurfaceGui text parts).
	local board1 = newPart(folder, "LeaderboardBoard", Vector3.new(10, 6, 0.5),
		CFrame.new(-16, 3, -22), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
	addLabel(board1, "LEADERBOARD\nTop Coins", 28, Color3.fromRGB(255, 220, 90))
	local board2 = newPart(folder, "EventBoard", Vector3.new(8, 5, 0.5),
		CFrame.new(-10, 2.5, 12), Color3.fromRGB(25, 35, 25), Enum.Material.SmoothPlastic)
	addLabel(board2, "GLITCH TIDE\nWatch the sky!", 24, Color3.fromRGB(120, 255, 170))

	-- Tutorial sign near spawn.
	local sign = newPart(folder, "TutorialSign", Vector3.new(5, 3, 0.5),
		CFrame.new(8, 1.5, 10), Color3.fromRGB(40, 40, 55), Enum.Material.Wood)
	addLabel(sign, "BUY on the conveyor\nCARRY it home\nPLACE it in your base", 18, Color3.fromRGB(255, 255, 255))

	-- Little fountain for flavour (one of the few emitters outside portal/conveyor).
	newPart(folder, "FountainBase", Vector3.new(6, 1, 6),
		CFrame.new(-20, 0.5, 8), Color3.fromRGB(150, 150, 170), Enum.Material.Concrete)
	local fountainWater = newPart(folder, "FountainWater", Vector3.new(4.5, 0.5, 4.5),
		CFrame.new(-20, 1, 8), Color3.fromRGB(60, 170, 255), Enum.Material.Neon)
	fountainWater.Transparency = 0.3
	fountainWater.CanCollide = false
	addEmitter(fountainWater, Color3.fromRGB(120, 200, 255), 10, 0.8)
end

local function buildConveyor(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "RiftMarket"
	folder.Parent = parent

	-- 60-stud belt, centred at z = -60, running west -> east.
	local belt = newPart(folder, "ConveyorBelt", Vector3.new(62, 1, 6),
		CFrame.new(0, 1.5, -60), Color3.fromRGB(35, 35, 45), Enum.Material.SmoothPlastic)
	belt.CanCollide = true
	newPart(folder, "ConveyorRailLeft", Vector3.new(62, 1, 0.6),
		CFrame.new(0, 2.3, -63.2), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	newPart(folder, "ConveyorRailRight", Vector3.new(62, 1, 0.6),
		CFrame.new(0, 2.3, -56.8), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)

	-- Moving chevron strips: ConveyorService slides these along +X and wraps them.
	_beltParts = {}
	for i = 1, 12 do
		local x = -30 + (i - 1) * 5
		local chevron = newPart(folder, "BeltChevron" .. tostring(i), Vector3.new(1.2, 0.2, 4.5),
			CFrame.new(x, _beltY, -60), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
		chevron.CanCollide = false
		table.insert(_beltParts, chevron)
	end

	-- Spawn gate (west end) and end gate (east end).
	for _, gateX in ipairs({ -33, 33 }) do
		local gate = Instance.new("Folder")
		gate.Name = (gateX < 0) and "SpawnGate" or "EndGate"
		gate.Parent = folder
		newPart(gate, "GatePostA", Vector3.new(0.8, 7, 0.8),
			CFrame.new(gateX, 3.5, -63.5), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
		newPart(gate, "GatePostB", Vector3.new(0.8, 7, 0.8),
			CFrame.new(gateX, 3.5, -56.5), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
		newPart(gate, "GateTop", Vector3.new(0.8, 1, 7.8),
			CFrame.new(gateX, 7.2, -60), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
	end
	local spawnSwirl = newPart(folder, "SpawnGateSwirl", Vector3.new(0.6, 5.5, 5.5),
		CFrame.new(-33, 3.5, -60), Color3.fromRGB(140, 60, 240), Enum.Material.Neon)
	spawnSwirl.Transparency = 0.5
	spawnSwirl.CanCollide = false
	addEmitter(spawnSwirl, Color3.fromRGB(190, 110, 255), 16, 1)

	local marketSign = newPart(folder, "MarketSign", Vector3.new(12, 3, 0.5),
		CFrame.new(0, 4, -52), Color3.fromRGB(30, 30, 45), Enum.Material.SmoothPlastic)
	addLabel(marketSign, "RIFT MARKET — BUY BRAINROTS", 22, Color3.fromRGB(255, 200, 60))

	-- Waypoints west -> east, at ride height (belt top is y=2, so the
	-- platform centre rides just above it).
	_waypoints = {}
	for i = 0, 6 do
		table.insert(_waypoints, Vector3.new(-30 + i * 10, 2.6, -60))
	end
end

local function buildBasePlot(parent: Model, index: number, center: Vector3): ()
	local folder = Instance.new("Folder")
	folder.Name = "BasePlot" .. tostring(index)
	folder.Parent = parent

	local floor = newPart(folder, "Floor", Vector3.new(24, 1, 24),
		CFrame.new(center.X, 0, center.Z), Color3.fromRGB(55, 55, 75), Enum.Material.Concrete)

	-- 3 walls + an open gate side facing the map centre.
	local gateDir = (Vector3.new(0, 0, 0) - center).Unit
	local wallColor = Color3.fromRGB(90, 80, 160)
	-- North / south / east / west walls in plot-local space; the wall whose
	-- outward normal points away from the centre becomes the gate instead.
	local wallSpecs = {
		{ Offset = Vector3.new(0, 0, -12), Size = Vector3.new(24, 4, 1), Gate = false },
		{ Offset = Vector3.new(0, 0, 12), Size = Vector3.new(24, 4, 1), Gate = false },
		{ Offset = Vector3.new(-12, 0, 0), Size = Vector3.new(1, 4, 24), Gate = false },
		{ Offset = Vector3.new(12, 0, 0), Size = Vector3.new(1, 4, 24), Gate = false },
	}
	-- Pick the wall closest to the centre direction as the gate opening.
	local bestWall = 1
	local bestDot = -2
	for i, spec in ipairs(wallSpecs) do
		local worldOffset = spec.Offset
		local dot = worldOffset.Unit:Dot(gateDir)
		if dot > bestDot then
			bestDot = dot
			bestWall = i
		end
	end
	for i, spec in ipairs(wallSpecs) do
		if i == bestWall then
			local gatePos = center + spec.Offset
			-- The gate slab must span the opening: wide in X for a
			-- north/south wall, wide in Z for an east/west wall. The
			-- old code always used (6, 4, 0.6), so side gates jutted
			-- out perpendicular to their opening and left gaps.
			local gateSize = Vector3.new(6, 4, 0.6)
			if spec.Offset.X ~= 0 then
				gateSize = Vector3.new(0.6, 4, 6)
			end
			local gate = newPart(folder, "Gate", gateSize,
				CFrame.new(gatePos.X, 2, gatePos.Z), Color3.fromRGB(120, 220, 255), Enum.Material.Neon)
			gate.Transparency = 0.55
			gate.CanCollide = false
			-- Gate posts flanking the opening.
			local perp = Vector3.new(-spec.Offset.Z, 0, spec.Offset.X).Unit * 3.5
			newPart(folder, "GatePostA", Vector3.new(1, 5, 1),
				CFrame.new(gatePos.X + perp.X, 2.5, gatePos.Z + perp.Z), wallColor, Enum.Material.Concrete)
			newPart(folder, "GatePostB", Vector3.new(1, 5, 1),
				CFrame.new(gatePos.X - perp.X, 2.5, gatePos.Z - perp.Z), wallColor, Enum.Material.Concrete)
		else
			newPart(folder, "Wall" .. tostring(i), spec.Size,
				CFrame.new(center.X + spec.Offset.X, 2, center.Z + spec.Offset.Z), wallColor, Enum.Material.Concrete)
		end
	end

	-- Owner sign (text set by BaseService when a player claims the plot).
	local signPos = center + Vector3.new(0, 0, -13.5)
	local sign = newPart(folder, "OwnerSign", Vector3.new(10, 3, 0.5),
		CFrame.new(signPos.X, 3.5, signPos.Z), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
	addLabel(sign, "BASE " .. tostring(index) .. "\n(unclaimed)", 20, Color3.fromRGB(255, 255, 255))

	-- 10 pedestal slots: 2 rows x 5.
	local pedestals: { [number]: CFrame } = {}
	local pedestalParts: { [number]: Part } = {}
	for slot = 1, 10 do
		local row = math.ceil(slot / 5)
		local col = ((slot - 1) % 5) + 1
		local ox = (col - 3) * 4.5
		local oz = (row == 1) and -5 or 5
		local ped = newPart(folder, "Pedestal" .. tostring(slot), Vector3.new(3, 1, 3),
			CFrame.new(center.X + ox, 1, center.Z + oz), Color3.fromRGB(140, 120, 220), Enum.Material.Neon)
		ped.Transparency = 0.25
		pedestals[slot] = CFrame.new(center.X + ox, 1.5, center.Z + oz)
		pedestalParts[slot] = ped
	end

	-- Upgrade station pad.
	local station = newPart(folder, "UpgradeStation", Vector3.new(4, 0.5, 4),
		CFrame.new(center.X + 9, 0.75, center.Z - 9), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	station.CanCollide = false

	-- Decorations + one light per plot (12 of the 16-light budget).
	newPart(folder, "DecorPillarA", Vector3.new(1, 5, 1),
		CFrame.new(center.X - 10, 2.5, center.Z - 10), Color3.fromRGB(255, 120, 200), Enum.Material.Neon)
	newPart(folder, "DecorPillarB", Vector3.new(1, 5, 1),
		CFrame.new(center.X + 10, 2.5, center.Z + 10), Color3.fromRGB(120, 220, 255), Enum.Material.Neon)
	addPointLight(floor, Color3.fromRGB(160, 140, 255), 26, 1.5)

	_plots[index] = {
		Index = index,
		Center = center,
		Folder = folder,
		Floor = floor,
		Gate = folder:FindFirstChild("Gate"),
		Sign = sign,
		Station = station,
		Pedestals = pedestals,
		PedestalParts = pedestalParts,
	}
end

local function buildBaseDistrict(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "BaseDistrict"
	folder.Parent = parent
	-- 12 plots, one per player (Config.MaxPlayers = 12), on a ring of
	-- radius 120. Clearances at this radius: the 30°/150° plots clear
	-- the Chaos Arena platform (x <= 90) by ~2 studs, the tide sirens
	-- at x = +/-120 by ~4 studs, and the tide channel (z >= 70) clips
	-- only a 2-stud strip of the 30°/150° plot floors (different Y,
	-- no collision); neighbouring plots sit ~62 studs apart
	-- centre-to-centre. A smaller radius crowds the arena; a larger
	-- one pushes the 30°/150° plots into the sirens.
	local radius = 120
	local plotCount = 12
	for i = 1, plotCount do
		local angle = (i - 1) * (math.pi * 2 / plotCount)
		local center = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		buildBasePlot(folder, i, center)
	end
end

local function buildTideChannel(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "TideChannel"
	folder.Parent = parent

	-- TideService reads the DIRECT BasePart children of this folder,
	-- sorted by name, as the wave path — so the folder itself holds ONLY
	-- the five glowing channel markers in a straight line. Everything
	-- else in the zone lives in the Props subfolder (its children are
	-- not direct children of TideChannel, so they never become waypoints).
	for i, x in ipairs({ -150, -75, 0, 75, 150 }) do
		local marker = newPart(folder, "TidePoint0" .. tostring(i), Vector3.new(6, 0.4, 8),
			CFrame.new(x, 0.2, 75), Color3.fromRGB(40, 120, 255), Enum.Material.Neon)
		marker.Transparency = 0.4
		marker.CanCollide = false
	end

	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = folder

	-- Long channel across the map at z = 75.
	newPart(props, "ChannelFloor", Vector3.new(300, 1, 10),
		CFrame.new(0, -0.4, 75), Color3.fromRGB(20, 60, 140), Enum.Material.SmoothPlastic)
	local water = newPart(props, "ChannelWater", Vector3.new(300, 0.5, 9),
		CFrame.new(0, 0.1, 75), Color3.fromRGB(40, 120, 255), Enum.Material.Neon)
	water.Transparency = 0.4
	water.CanCollide = false

	-- Warning sirens along the channel.
	for i, x in ipairs({ -120, -40, 40, 120 }) do
		newPart(props, "SirenPole" .. tostring(i), Vector3.new(1, 7, 1),
			CFrame.new(x, 3.5, 68), Color3.fromRGB(80, 80, 90), Enum.Material.Metal)
		local sirenTop = newPart(props, "SirenTop" .. tostring(i), Vector3.new(1.6, 1.6, 1.6),
			CFrame.new(x, 7.5, 68), Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
		if i == 1 then
			addPointLight(sirenTop, Color3.fromRGB(255, 40, 40), 24, 1.5)
		end
	end

	-- Elevated escape platforms + ramps.
	for i, x in ipairs({ -90, 0, 90 }) do
		newPart(props, "EscapePlatform" .. tostring(i), Vector3.new(10, 1, 10),
			CFrame.new(x, 6, 75), Color3.fromRGB(200, 170, 60), Enum.Material.WoodPlanks)
		local ramp = newPart(props, "EscapeRamp" .. tostring(i), Vector3.new(4, 0.6, 10),
			CFrame.new(x, 3, 66) * CFrame.Angles(math.rad(-32), 0, 0),
			Color3.fromRGB(160, 130, 50), Enum.Material.WoodPlanks)
		ramp.CanCollide = true
		table.insert(_safeZones, { Position = Vector3.new(x, 6, 75), Center = Vector3.new(x, 6, 75), Radius = 7 })
	end

	-- 3 safe shelters with roofs, just south of the channel.
	for i, x in ipairs({ -100, 0, 100 }) do
		local shelter = Instance.new("Folder")
		shelter.Name = "SafeShelter" .. tostring(i)
		shelter.Parent = props
		newPart(shelter, "ShelterFloor", Vector3.new(12, 1, 12),
			CFrame.new(x, 0.5, 92), Color3.fromRGB(90, 90, 110), Enum.Material.Concrete)
		for _, dx in ipairs({ -5.5, 5.5 }) do
			for _, dz in ipairs({ -5.5, 5.5 }) do
				newPart(shelter, "ShelterPost", Vector3.new(1, 5, 1),
					CFrame.new(x + dx, 3, 92 + dz), Color3.fromRGB(70, 70, 85), Enum.Material.Concrete)
			end
		end
		newPart(shelter, "ShelterRoof", Vector3.new(14, 1, 14),
			CFrame.new(x, 6, 92), Color3.fromRGB(255, 90, 90), Enum.Material.SmoothPlastic)
		local shelterSign = newPart(shelter, "ShelterSign", Vector3.new(6, 2, 0.5),
			CFrame.new(x, 4, 86.2), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
		addLabel(shelterSign, "SAFE SHELTER", 20, Color3.fromRGB(120, 255, 170))
		table.insert(_safeZones, { Position = Vector3.new(x, 1, 92), Center = Vector3.new(x, 1, 92), Radius = 8 })
	end
end

local function buildMutationLab(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "MutationLab"
	folder.Parent = parent
	local c = Vector3.new(-75, 0, 55)
	newPart(folder, "LabMachine", Vector3.new(9, 6, 6),
		CFrame.new(c.X, 3, c.Z), Color3.fromRGB(60, 200, 160), Enum.Material.Metal)
	local chamber = newPart(folder, "FusionChamber", Vector3.new(5, 6, 5),
		CFrame.new(c.X + 8, 3, c.Z), Color3.fromRGB(120, 220, 255), Enum.Material.Glass)
	chamber.Transparency = 0.4
	addEmitter(chamber, Color3.fromRGB(120, 255, 200), 12, 0.9)
	local preview = newPart(folder, "PreviewPad", Vector3.new(6, 0.5, 6),
		CFrame.new(c.X + 8, 0.25, c.Z + 8), Color3.fromRGB(120, 255, 200), Enum.Material.Neon)
	preview.CanCollide = false
	local sign = newPart(folder, "LabSign", Vector3.new(9, 3, 0.5),
		CFrame.new(c.X, 5, c.Z - 4), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
	addLabel(sign, "MUTATION LAB", 24, Color3.fromRGB(120, 255, 200))
end

local function buildChaosArena(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "ChaosArena"
	folder.Parent = parent
	local c = Vector3.new(75, 0, 55)
	newPart(folder, "ArenaPlatform", Vector3.new(30, 2, 30),
		CFrame.new(c.X, 1, c.Z), Color3.fromRGB(120, 60, 60), Enum.Material.Concrete)
	for i = 1, 4 do
		local angle = (i - 1) * (math.pi / 2) + math.pi / 4
		local x = c.X + math.cos(angle) * 11
		local z = c.Z + math.sin(angle) * 11
		local pad = newPart(folder, "EnemySpawnPad" .. tostring(i), Vector3.new(4, 0.5, 4),
			CFrame.new(x, 2.25, z), Color3.fromRGB(255, 60, 60), Enum.Material.Neon)
		pad.CanCollide = false
	end
	newPart(folder, "RewardChest", Vector3.new(3, 2, 3),
		CFrame.new(c.X, 3, c.Z - 10), Color3.fromRGB(255, 200, 60), Enum.Material.Metal)
	local sign = newPart(folder, "ArenaSign", Vector3.new(10, 3, 0.5),
		CFrame.new(c.X, 4, c.Z + 16), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
	addLabel(sign, "CHAOS ARENA", 24, Color3.fromRGB(255, 120, 120))
end

local function buildForbiddenRift(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "ForbiddenRift"
	folder.Parent = parent
	local c = Vector3.new(-150, 0, -150)
	-- Secret path: stepping stones from the plaza corner out to the rift.
	for i = 1, 5 do
		local t = i / 6
		local x = -110 - t * 40
		local z = -110 - t * 40
		local stone = newPart(folder, "PathStone" .. tostring(i), Vector3.new(4, 0.6, 4),
			CFrame.new(x, 0.3, z), Color3.fromRGB(90, 70, 130), Enum.Material.Slate)
		stone.CanCollide = true
	end
	newPart(folder, "RiftPostA", Vector3.new(1, 8, 1),
		CFrame.new(c.X - 5, 4, c.Z), Color3.fromRGB(40, 40, 60), Enum.Material.Concrete)
	newPart(folder, "RiftPostB", Vector3.new(1, 8, 1),
		CFrame.new(c.X + 5, 4, c.Z), Color3.fromRGB(40, 40, 60), Enum.Material.Concrete)
	newPart(folder, "RiftTop", Vector3.new(11, 1, 1),
		CFrame.new(c.X, 8.2, c.Z), Color3.fromRGB(40, 40, 60), Enum.Material.Concrete)
	local riftSwirl = newPart(folder, "RiftPortal", Vector3.new(8, 8, 0.6),
		CFrame.new(c.X, 4, c.Z), Color3.fromRGB(255, 60, 200), Enum.Material.Neon)
	riftSwirl.Transparency = 0.4
	riftSwirl.CanCollide = false
	addEmitter(riftSwirl, Color3.fromRGB(255, 80, 220), 14, 1)
	-- Rare-material nodes.
	for i, offset in ipairs({ Vector3.new(-4, 0, 4), Vector3.new(4, 0, 5), Vector3.new(0, 0, -5) }) do
		newPart(folder, "RareNode" .. tostring(i), Vector3.new(1.5, 2.5, 1.5),
			CFrame.new(c.X + offset.X, 1.25, c.Z + offset.Z),
			Color3.fromRGB(120, 255, 230), Enum.Material.Neon)
	end
	local sign = newPart(folder, "RiftSign", Vector3.new(9, 3, 0.5),
		CFrame.new(c.X, 3, c.Z + 10), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
	addLabel(sign, "FORBIDDEN RIFT", 22, Color3.fromRGB(255, 80, 220))
end

-- Build the world. Idempotent: a second call returns the same Model.
function MapBuilder.Build(): Model
	if _built and _model ~= nil then
		return _model
	end
	_lightCount = 0
	_plots = {}
	_safeZones = {}

	local model = Instance.new("Model")
	model.Name = "GlitchTideWorld"

	pcall(function()
		Lighting.ClockTime = 14
		Lighting.Brightness = 2
		Lighting.Ambient = Color3.fromRGB(90, 90, 110)
		Lighting.OutdoorAmbient = Color3.fromRGB(110, 110, 130)
		Lighting.FogColor = Color3.fromRGB(150, 120, 220)
		Lighting.FogStart = 200
		Lighting.FogEnd = 900
	end)

	buildGround(model)
	buildPlaza(model)
	buildConveyor(model)
	buildBaseDistrict(model)
	buildTideChannel(model)
	buildMutationLab(model)
	buildChaosArena(model)
	buildForbiddenRift(model)

	model.Parent = Workspace
	_model = model
	_built = true
	print(string.format("[MapBuilder] World built (%d PointLights, %d base plots)",
		_lightCount, #_plots))
	return model
end

function MapBuilder.GetBasePlot(index: number): { [string]: any }?
	return _plots[index]
end

function MapBuilder.GetBasePlots(): { [number]: { [string]: any } }
	return _plots
end

function MapBuilder.GetConveyorPath(): { Vector3 }
	local copy: { Vector3 } = {}
	for _, wp in ipairs(_waypoints) do
		table.insert(copy, wp)
	end
	return copy
end

function MapBuilder.GetSafeZones(): { { Position: Vector3, Center: Vector3, Radius: number } }
	local copy: { { Position: Vector3, Center: Vector3, Radius: number } } = {}
	for _, zone in ipairs(_safeZones) do
		table.insert(copy, zone)
	end
	return copy
end

function MapBuilder.GetSpawnPosition(): Vector3
	return _spawnPosition
end

-- Moving belt chevrons, so ConveyorService can animate the belt.
function MapBuilder.GetBeltParts(): { BasePart }
	local copy: { BasePart } = {}
	for _, part in ipairs(_beltParts) do
		table.insert(copy, part)
	end
	return copy
end

function MapBuilder.GetBeltBounds(): (number, number, number)
	return _beltMinX, _beltMaxX, _beltY
end

return MapBuilder
