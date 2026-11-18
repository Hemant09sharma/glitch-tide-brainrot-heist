--!strict
-- MapBuilder.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Builds the whole persistent world as one anchored Model in Workspace.
-- Zones: MemeversePlaza, RiftMarket (conveyor), BaseDistrict (12 plots),
-- TideChannel, MutationLab, ChaosArena, ForbiddenRift, plus the v1.1
-- dimensions AbyssalKingdom and SkyfallKingdom (geometry from shared
-- Dimensions.luau; gameplay lives in DimensionsService).
-- No external asset ids, no client-trusted values, part count kept sane
-- (target < 600 total parts; counted at build time and printed).
-- Lighting is set here, guarded by pcall (baseline only — LightingService
-- owns moods once it is registered).
-- Accessors live on this module (MapBuilder.GetBasePlot etc.): Luau
-- functions cannot carry extra fields, so Build.GetBasePlot is not a
-- real thing — call the module functions instead.
--
-- PRESERVED CONTRACTS (other services depend on these; do not change):
--   * Zone folder names under GlitchTideWorld (see §4d of AUDIT_V1_1).
--   * TideChannel direct BasePart children are ONLY TidePoint01..05 —
--     TideService reads them sorted by name as the wave path. Everything
--     else in that zone lives under TideChannel/Props.
--   * GetBasePlot record fields (Index, Center, Folder, Floor, Gate,
--     Sign, Station, Pedestals, PedestalParts).
--   * GetConveyorPath waypoints, GetBeltParts, GetBeltBounds, GetSafeZones,
--     GetSpawnPosition.
--   * QuestService uses the FIRST BasePart descendant of ForbiddenRift /
--     MutationLab as the zone centre (20-stud radius), so the first part
--     built in each of those folders sits at the zone's heart.
--   * Light budget: 16 PointLights max (12 plots + hub portal + tower +
--     siren + Abyssal hub portal). New regions use Neon / particles only.
-- KNOWN MAP CONTACTS (v1.0.2, unchanged — nothing here moves the ramp,
-- the plots, or the channel, so neither contact can get worse):
--   * escape-ramp edge grazes a plot gate post;
--   * channel floor clips a 2-stud strip of the 30°/150° plot floors
--     (different Y, no collision).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Dimensions = require(ReplicatedStorage:WaitForChild("Dimensions"))

local MapBuilder = {}

local MAX_LIGHTS = 16 -- 12 plot lights + hub portal + tower + siren + Abyssal portal
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
local _partCount = 0
local _dimensionFolders: { [string]: Folder } = {}
local _dimensionPortals: { [string]: BasePart } = {}

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
	_partCount += 1
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

-- Vertical portal ring (segments in a circle in local XY, facing +Z
-- after the yaw) with a swirling centre. Returns the swirl part.
-- DimensionsService attaches the ProximityPrompt to the swirl.
local function buildPortalRing(
	parent: Instance,
	name: string,
	center: Vector3,
	yaw: number,
	radius: number,
	color: Color3,
	withLight: boolean
): Part
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	local base = CFrame.new(center) * CFrame.Angles(0, yaw, 0)
	local segments = 8
	local segSize = math.max(1.2, radius * 0.45)
	for i = 1, segments do
		local angle = (i - 1) * (math.pi * 2 / segments)
		local offset = Vector3.new(math.cos(angle) * radius, math.sin(angle) * radius, 0)
		newPart(folder, "RingSegment" .. tostring(i), Vector3.new(segSize, segSize, 1.5),
			base * CFrame.new(offset), color, Enum.Material.Neon)
	end
	local swirl = newPart(folder, "PortalSwirl", Vector3.new(radius * 1.6, radius * 1.6, 0.6),
		base * CFrame.new(0, 0, 0), color, Enum.Material.Neon)
	swirl.Transparency = 0.45
	swirl.CanCollide = false
	addEmitter(swirl, color, 16, 1)
	if withLight then
		addPointLight(swirl, color, 26, 2)
	end
	return swirl
end

-- A walkable bridge deck between two points, with visual side rails
-- (rails are non-colliding so a shoved player can fall — the hazard
-- is the point on the Skyfall bridges).
local function buildBridge(parent: Instance, name: string, a: Vector3, b: Vector3, width: number): ()
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	local delta = b - a
	local length = delta.Magnitude
	local mid = (a + b) * 0.5
	local yaw = math.atan2(delta.X, delta.Z)
	local pitch = -math.asin(delta.Y / length)
	local cf = CFrame.new(mid) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	newPart(folder, "Deck", Vector3.new(width, 0.6, length), cf,
		Color3.fromRGB(160, 120, 60), Enum.Material.WoodPlanks)
	for _, side in ipairs({ -1, 1 }) do
		local railCf = cf * CFrame.new(side * (width / 2 - 0.15), 0.9, 0)
		local rail = newPart(folder, "Rail" .. ((side < 0) and "Left" or "Right"),
			Vector3.new(0.3, 1.2, length), railCf, Color3.fromRGB(200, 160, 80), Enum.Material.Wood)
		rail.CanCollide = false
	end
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

	-- v1.1 background scenery: distant mountain spires in the four
	-- corners (outside the plot ring, inside the walls) so the horizon
	-- is a skyline, not a flat wall.
	for i, corner in ipairs({
		Vector3.new(188, 0, 188),
		Vector3.new(-188, 0, 188),
		Vector3.new(188, 0, -188),
		Vector3.new(-188, 0, -188),
	}) do
		local height = 34 + (i % 2) * 12
		newPart(parent, "MountainSpire" .. tostring(i), Vector3.new(14, height, 14),
			CFrame.new(corner.X, height / 2, corner.Z) * CFrame.Angles(0, math.rad(20 * i), 0),
			Color3.fromRGB(90, 80, 120), Enum.Material.Slate)
	end

	-- Terrain variation: three low, walkable hills (1-stud risers are
	-- climbable) breaking up the flat grass between zones.
	for i, hill in ipairs({
		{ Pos = Vector3.new(170, 0, 120), Size = Vector3.new(30, 3, 26) },
		{ Pos = Vector3.new(-170, 0, -60), Size = Vector3.new(26, 3, 30) },
		{ Pos = Vector3.new(60, 0, 170), Size = Vector3.new(28, 2.5, 24) },
	}) do
		newPart(parent, "Hill" .. tostring(i), hill.Size,
			CFrame.new(hill.Pos.X, hill.Size.Y / 2 - 0.5, hill.Pos.Z),
			Color3.fromRGB(60, 170, 100), Enum.Material.Grass)
	end

	-- Glitch-crystal clusters: environmental storytelling — the
	-- Memeverse is leaking raw glitch energy at the edges.
	for i, spot in ipairs({ Vector3.new(-120, 0, -180) }) do
		newPart(parent, "GlitchCrystalA" .. tostring(i), Vector3.new(2, 5, 2),
			CFrame.new(spot.X, 2.5, spot.Z) * CFrame.Angles(0, 0, math.rad(12)),
			Color3.fromRGB(255, 80, 220), Enum.Material.Neon)
		newPart(parent, "GlitchCrystalB" .. tostring(i), Vector3.new(1.5, 3.5, 1.5),
			CFrame.new(spot.X + 3, 1.75, spot.Z + 2),
			Color3.fromRGB(120, 220, 255), Enum.Material.Neon)
	end
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

	-- v1.1: stone arch framing the main portal — the plaza's silhouette
	-- from the spawn point.
	newPart(folder, "PortalArchPostA", Vector3.new(1.5, 8, 1.5),
		CFrame.new(-9, 4, -30), Color3.fromRGB(80, 70, 110), Enum.Material.Concrete)
	newPart(folder, "PortalArchPostB", Vector3.new(1.5, 8, 1.5),
		CFrame.new(9, 4, -30), Color3.fromRGB(80, 70, 110), Enum.Material.Concrete)
	newPart(folder, "PortalArchTop", Vector3.new(19.5, 1.5, 2),
		CFrame.new(0, 8.5, -30), Color3.fromRGB(120, 90, 200), Enum.Material.SmoothPlastic)

	-- v1.1: dimension portals (hub side). Positions / yaw come from
	-- Dimensions.luau; DimensionsService attaches the prompts.
	-- The Abyssal portal takes the last spare PointLight (16/16);
	-- the Skyfall portal is Neon + particles only.
	for _, def in ipairs(Dimensions.GetAll()) do
		local folderName = (def.Id == "abyssal") and "AbyssalPortal" or "SkyfallPortal"
		local color = (def.Id == "abyssal")
			and Color3.fromRGB(40, 140, 255)
			or Color3.fromRGB(255, 220, 120)
		local portalSwirl = buildPortalRing(folder, folderName,
			Vector3.new(def.HubPortalPosition.X, 5, def.HubPortalPosition.Z),
			def.HubPortalYaw, 4, color, def.Id == "abyssal")
		_dimensionPortals[def.Id] = portalSwirl
		local signPos = Vector3.new(def.HubPortalPosition.X, 2, def.HubPortalPosition.Z)
			+ Vector3.new(0, 0, (def.Id == "abyssal") and 5.5 or -5.5)
		local sign = newPart(folder, folderName .. "Sign", Vector3.new(9, 2.5, 0.5),
			CFrame.new(signPos.X, 2, signPos.Z) * CFrame.Angles(0, def.HubPortalYaw, 0),
			Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
		addLabel(sign, string.upper(def.DisplayName), 22, Color3.fromRGB(255, 255, 255))
	end

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

	-- v1.1: speaker's dais (walkable 1-stud step) and two plaza banners
	-- so the hub reads as a gathering place, not an empty disc.
	newPart(folder, "SpeakerDais", Vector3.new(8, 1, 8),
		CFrame.new(-4, 0.5, 18), Color3.fromRGB(90, 70, 140), Enum.Material.Concrete)
	for i, bx in ipairs({ -6, 6 }) do
		newPart(folder, "BannerPole" .. tostring(i), Vector3.new(0.5, 5, 0.5),
			CFrame.new(bx, 2.5, -8), Color3.fromRGB(60, 60, 75), Enum.Material.Metal)
		newPart(folder, "BannerCloth" .. tostring(i), Vector3.new(2.5, 3, 0.2),
			CFrame.new(bx, 3.5, -8), Color3.fromRGB(180, 80, 255), Enum.Material.Fabric)
	end

	-- v1.1: two trader stalls at the plaza's south edge — the market
	-- spills into the hub.
	for i, sx in ipairs({ -18 }) do
		newPart(folder, "PlazaStallCounter" .. tostring(i), Vector3.new(3, 1.5, 2),
			CFrame.new(sx, 0.75, 16), Color3.fromRGB(120, 80, 40), Enum.Material.Wood)
		newPart(folder, "PlazaStallRoof" .. tostring(i), Vector3.new(4, 0.3, 3),
			CFrame.new(sx, 3, 16), Color3.fromRGB(255, 120, 120), Enum.Material.Fabric)
	end

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

	-- v1.1: market architecture — four stalls with striped awnings
	-- along the belt's south side, crates stacked by the gates, and a
	-- grand arch over the market entrance. Stalls sit at z = -50 /
	-- z = -70, clear of the belt (z -63.2..-56.8) and the waypoints.
	for i, sx in ipairs({ -24, -8, 8 }) do
		local sz = (i % 2 == 1) and -50 or -70
		newPart(folder, "MarketStallCounter" .. tostring(i), Vector3.new(4, 1.5, 2.5),
			CFrame.new(sx, 0.75, sz), Color3.fromRGB(110, 75, 40), Enum.Material.Wood)
		newPart(folder, "MarketStallRoof" .. tostring(i), Vector3.new(5, 0.3, 3.5),
			CFrame.new(sx, 3.2, sz), Color3.fromRGB(255, 200, 60), Enum.Material.Fabric)
		local awning = newPart(folder, "MarketStallAwning" .. tostring(i), Vector3.new(5, 0.2, 1.5),
			CFrame.new(sx, 2.6, sz + ((sz < -60) and 2 or -2)),
			Color3.fromRGB(255, 120, 120), Enum.Material.Fabric)
		awning.CanCollide = false
	end
	for i, crate in ipairs({
		Vector3.new(-38, 0.75, -52),
		Vector3.new(-36.5, 0.75, -54),
		Vector3.new(38, 0.75, -68),
		Vector3.new(36.5, 0.75, -66),
	}) do
		newPart(folder, "MarketCrate" .. tostring(i), Vector3.new(1.5, 1.5, 1.5),
			CFrame.new(crate.X, crate.Y, crate.Z), Color3.fromRGB(140, 100, 50), Enum.Material.Wood)
	end
	newPart(folder, "MarketArchPostA", Vector3.new(1.2, 7, 1.2),
		CFrame.new(-7, 3.5, -50), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
	newPart(folder, "MarketArchPostB", Vector3.new(1.2, 7, 1.2),
		CFrame.new(7, 3.5, -50), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
	newPart(folder, "MarketArchTop", Vector3.new(15.2, 1.2, 1.2),
		CFrame.new(0, 7.2, -50), Color3.fromRGB(180, 80, 255), Enum.Material.Neon)
	local lanternA = newPart(folder, "MarketLanternA", Vector3.new(1, 1.4, 1),
		CFrame.new(-20, 4.5, -50), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	lanternA.CanCollide = false
	local lanternB = newPart(folder, "MarketLanternB", Vector3.new(1, 1.4, 1),
		CFrame.new(20, 4.5, -50), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	lanternB.CanCollide = false

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

	-- v1.1: each plot gets its own identity — a totem in the plot's
	-- colour (hue cycles with the plot index) and matching pillar
	-- colours, so bases are recognisable from across the map.
	local plotHue = (index - 1) / 12
	local plotColor = Color3.fromHSV(plotHue, 0.75, 1)
	local totemPos = center + Vector3.new(-9, 0, 9)
	newPart(folder, "PlotTotem", Vector3.new(2, 6, 2),
		CFrame.new(totemPos.X, 3, totemPos.Z), plotColor, Enum.Material.Neon)
	newPart(folder, "DecorPillarA", Vector3.new(1, 5, 1),
		CFrame.new(center.X - 10, 2.5, center.Z - 10), plotColor, Enum.Material.Neon)
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

	-- v1.1: channel dressing — warning buoys bobbing in the water,
	-- broken pier stubs at both ends (the tide has been here before),
	-- floating debris, and a tide-gauge tower so the water level has
	-- a story. All under Props; the wave path is untouched.
	for i, bx in ipairs({ -140, 0, 140 }) do
		local buoy = newPart(props, "Buoy" .. tostring(i), Vector3.new(2, 1.5, 2),
			CFrame.new(bx, 0.8, 75), Color3.fromRGB(255, 140, 40), Enum.Material.SmoothPlastic)
		buoy.CanCollide = false
	end
	for i, px in ipairs({ -155, 155 }) do
		local pier = newPart(props, "BrokenPier" .. tostring(i), Vector3.new(8, 1, 4),
			CFrame.new(px, 0.5, 75), Color3.fromRGB(120, 90, 50), Enum.Material.WoodPlanks)
		pier.CanCollide = false
	end
	for i, dx in ipairs({ -60 }) do
		local debris = newPart(props, "ChannelDebris" .. tostring(i), Vector3.new(3, 0.4, 2),
			CFrame.new(dx, 0.4, 75), Color3.fromRGB(150, 120, 70), Enum.Material.Wood)
		debris.CanCollide = false
	end
	newPart(props, "GaugePole", Vector3.new(1, 9, 1),
		CFrame.new(-170, 4.5, 88), Color3.fromRGB(80, 80, 90), Enum.Material.Metal)
	newPart(props, "GaugeBox", Vector3.new(3, 3, 1),
		CFrame.new(-170, 8, 88), Color3.fromRGB(40, 120, 255), Enum.Material.Neon)
	local gaugeBeacon = newPart(props, "GaugeBeacon", Vector3.new(1, 1, 1),
		CFrame.new(-170, 10, 88), Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
	gaugeBeacon.CanCollide = false
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

	-- v1.1: the lab gets plumbing and power — pipe runs from the
	-- machine to the chamber, two glowing specimen vats, spinning
	-- energy coils (animated by EnvironmentService), and a roof antenna.
	newPart(folder, "LabPipeA", Vector3.new(4, 0.8, 0.8),
		CFrame.new(c.X + 4, 5.5, c.Z), Color3.fromRGB(90, 120, 110), Enum.Material.Metal)
	newPart(folder, "LabPipeB", Vector3.new(0.8, 4, 0.8),
		CFrame.new(c.X - 5, 2, c.Z + 2), Color3.fromRGB(90, 120, 110), Enum.Material.Metal)
	newPart(folder, "LabVatA", Vector3.new(2.5, 4, 2.5),
		CFrame.new(c.X - 8, 2, c.Z + 6), Color3.fromRGB(120, 255, 200), Enum.Material.Glass).Transparency = 0.35
	newPart(folder, "LabVatB", Vector3.new(2.5, 4, 2.5),
		CFrame.new(c.X - 8, 2, c.Z - 6), Color3.fromRGB(255, 120, 220), Enum.Material.Glass).Transparency = 0.35
	newPart(folder, "LabCoil1", Vector3.new(1.5, 1.5, 1.5),
		CFrame.new(c.X + 8, 7, c.Z), Color3.fromRGB(120, 255, 200), Enum.Material.Neon)
	newPart(folder, "LabCoil2", Vector3.new(1.5, 1.5, 1.5),
		CFrame.new(c.X + 8, 7.8, c.Z), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	newPart(folder, "LabAntennaPole", Vector3.new(0.5, 5, 0.5),
		CFrame.new(c.X - 4, 8.5, c.Z - 2), Color3.fromRGB(80, 80, 90), Enum.Material.Metal)
	newPart(folder, "LabAntennaTip", Vector3.new(1, 1, 1),
		CFrame.new(c.X - 4, 11.2, c.Z - 2), Color3.fromRGB(255, 60, 60), Enum.Material.Neon)
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

	-- v1.1: the arena gets a fighting-pit silhouette — four corner
	-- pillars, two braziers, and a raised champion's dais at the back.
	for i = 1, 4 do
		local angle = (i - 1) * (math.pi / 2) + math.pi / 4
		local x = c.X + math.cos(angle) * 14.5
		local z = c.Z + math.sin(angle) * 14.5
		newPart(folder, "ArenaPillar" .. tostring(i), Vector3.new(1.5, 9, 1.5),
			CFrame.new(x, 4.5, z), Color3.fromRGB(90, 40, 40), Enum.Material.Concrete)
	end
	for i, bx in ipairs({ -8, 8 }) do
		newPart(folder, "ArenaBrazier" .. tostring(i), Vector3.new(1.5, 2.5, 1.5),
			CFrame.new(c.X + bx, 3.25, c.Z + 12), Color3.fromRGB(255, 120, 40), Enum.Material.Neon)
	end
	newPart(folder, "ChampionDais", Vector3.new(8, 1, 6),
		CFrame.new(c.X, 2.5, c.Z - 12), Color3.fromRGB(150, 70, 70), Enum.Material.Concrete)
end

local function buildForbiddenRift(parent: Model): ()
	local folder = Instance.new("Folder")
	folder.Name = "ForbiddenRift"
	folder.Parent = parent
	local c = Vector3.new(-150, 0, -150)
	-- The rift frame is built FIRST on purpose: QuestService takes the
	-- first BasePart descendant of this folder as the zone centre, and
	-- the centre should be the rift itself (v1.0.2 took the first path
	-- stone, ~47 studs away from the rift).
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
	-- Secret path: stepping stones from the plaza corner out to the rift.
	for i = 1, 5 do
		local t = i / 6
		local x = -110 - t * 40
		local z = -110 - t * 40
		local stone = newPart(folder, "PathStone" .. tostring(i), Vector3.new(4, 0.6, 4),
			CFrame.new(x, 0.3, z), Color3.fromRGB(90, 70, 130), Enum.Material.Slate)
		stone.CanCollide = true
	end
	-- Rare-material nodes.
	for i, offset in ipairs({ Vector3.new(-4, 0, 4), Vector3.new(4, 0, 5), Vector3.new(0, 0, -5) }) do
		newPart(folder, "RareNode" .. tostring(i), Vector3.new(1.5, 2.5, 1.5),
			CFrame.new(c.X + offset.X, 1.25, c.Z + offset.Z),
			Color3.fromRGB(120, 255, 230), Enum.Material.Neon)
	end
	-- v1.1: the rift gets teeth — fallen crystal shards, a collapsed
	-- second arch (something came through here once), and a warning totem.
	newPart(folder, "RiftCrystalA", Vector3.new(2, 4, 2),
		CFrame.new(c.X - 9, 2, c.Z + 4), Color3.fromRGB(255, 60, 200), Enum.Material.Neon)
	local broken = newPart(folder, "BrokenArch", Vector3.new(6, 1, 1),
		CFrame.new(c.X + 2, 0.6, c.Z + 8) * CFrame.Angles(0, math.rad(35), 0),
		Color3.fromRGB(40, 40, 60), Enum.Material.Concrete)
	broken.CanCollide = false
	newPart(folder, "RiftWarningTotem", Vector3.new(1.5, 5, 1.5),
		CFrame.new(c.X, 2.5, c.Z + 13), Color3.fromRGB(255, 220, 60), Enum.Material.Neon)
	local sign = newPart(folder, "RiftSign", Vector3.new(9, 3, 0.5),
		CFrame.new(c.X, 3, c.Z + 10), Color3.fromRGB(25, 25, 35), Enum.Material.SmoothPlastic)
	addLabel(sign, "FORBIDDEN RIFT", 22, Color3.fromRGB(255, 80, 220))
end

local function buildAbyssalKingdom(parent: Model): ()
	local def = Dimensions.GetById("abyssal")
	assert(def ~= nil, "[MapBuilder] Abyssal dimension def missing")
	local folder = Instance.new("Folder")
	folder.Name = "AbyssalKingdom"
	folder.Parent = parent
	_dimensionFolders["abyssal"] = folder
	local c = Vector3.new(-150, 0, 150)

	-- Sunken basin floor (top y = 0.6) and a translucent "sea ceiling"
	-- at y = 14 so the kingdom reads as underwater from inside.
	newPart(folder, "AbyssFloor", Vector3.new(52, 1, 52),
		CFrame.new(c.X, 0.1, c.Z), Color3.fromRGB(20, 40, 80), Enum.Material.Slate)
	local sea = newPart(folder, "SeaCeiling", Vector3.new(50, 0.5, 50),
		CFrame.new(c.X, 14, c.Z), Color3.fromRGB(40, 120, 200), Enum.Material.Glass)
	sea.Transparency = 0.55
	sea.CanCollide = false

	-- Basin rim: 7 blocks on a radius-26 ring; the north-east block is
	-- left out as the entrance gap (toward the hub).
	for i = 0, 7 do
		local angle = i * (math.pi * 2 / 8)
		if i ~= 3 then -- 135° (sin 0.707, cos -0.707) points NE toward the hub
			local x = c.X + math.sin(angle) * 26
			local z = c.Z + math.cos(angle) * 26
			newPart(folder, "BasinRim" .. tostring(i), Vector3.new(8, 3, 2),
				CFrame.new(x, 1.5, z) * CFrame.Angles(0, angle, 0),
				Color3.fromRGB(30, 50, 95), Enum.Material.Slate)
		end
	end

	-- Entrance arch over the gap.
	local archBase = CFrame.new(c.X + 18.4, 0, c.Z - 18.4) * CFrame.Angles(0, math.rad(45), 0)
	newPart(folder, "AbyssArchPostA", Vector3.new(1.2, 7, 1.2),
		archBase * CFrame.new(-3.5, 3.5, 0), Color3.fromRGB(30, 50, 95), Enum.Material.Slate)
	newPart(folder, "AbyssArchPostB", Vector3.new(1.2, 7, 1.2),
		archBase * CFrame.new(3.5, 3.5, 0), Color3.fromRGB(30, 50, 95), Enum.Material.Slate)
	newPart(folder, "AbyssArchTop", Vector3.new(8.2, 1.2, 1.2),
		archBase * CFrame.new(0, 7.2, 0), Color3.fromRGB(40, 140, 255), Enum.Material.Neon)
	local gateSign = newPart(folder, "AbyssGateSign", Vector3.new(9, 2.5, 0.5),
		archBase * CFrame.new(0, 5, 1), Color3.fromRGB(25, 25, 45), Enum.Material.SmoothPlastic)
	addLabel(gateSign, "ABYSSAL KINGDOM", 22, Color3.fromRGB(120, 200, 255))

	-- Bioluminescent plants: stem + glow bulb (EnvironmentService
	-- sways the bulbs). Coral clusters and kelp fill the floor.
	for i, pos in ipairs({
		Vector3.new(-165, 0, 140),
		Vector3.new(-138, 0, 140),
		Vector3.new(-170, 0, 160),
		Vector3.new(-132, 0, 168),
		Vector3.new(-158, 0, 172),
		Vector3.new(-142, 0, 172),
	}) do
		newPart(folder, "AbyssPlantStem" .. tostring(i), Vector3.new(0.6, 4, 0.6),
			CFrame.new(pos.X, 2.6, pos.Z), Color3.fromRGB(20, 120, 90), Enum.Material.SmoothPlastic)
		local bulbColor = (i % 2 == 1) and Color3.fromRGB(80, 255, 200) or Color3.fromRGB(120, 160, 255)
		newPart(folder, "PlantGlow" .. tostring(i), Vector3.new(1.4, 1.4, 1.4),
			CFrame.new(pos.X, 5, pos.Z), bulbColor, Enum.Material.Neon)
	end
	for i, pos in ipairs({
		Vector3.new(-160, 0, 158),
		Vector3.new(-140, 0, 158),
		Vector3.new(-155, 0, 145),
	}) do
		newPart(folder, "Coral" .. tostring(i), Vector3.new(1.5, 2.5, 1.5),
			CFrame.new(pos.X, 1.85, pos.Z), Color3.fromRGB(255, 120, 180), Enum.Material.Neon)
	end
	for i, pos in ipairs({
		Vector3.new(-170, 0, 155),
		Vector3.new(-130, 0, 145),
		Vector3.new(-155, 0, 168),
	}) do
		newPart(folder, "Kelp" .. tostring(i), Vector3.new(0.5, 7, 0.5),
			CFrame.new(pos.X, 4.1, pos.Z), Color3.fromRGB(30, 160, 90), Enum.Material.SmoothPlastic)
	end

	-- Drowned ruins: standing pillars, broken tilted pillars, and a
	-- two-wall nook sheltering the richest chest.
	newPart(folder, "RuinPillarA", Vector3.new(1.5, 8, 1.5),
		CFrame.new(-158, 4.6, 158), Color3.fromRGB(50, 60, 90), Enum.Material.Slate)
	newPart(folder, "RuinPillarB", Vector3.new(1.5, 8, 1.5),
		CFrame.new(-142, 4.6, 158), Color3.fromRGB(50, 60, 90), Enum.Material.Slate)
	newPart(folder, "RuinPillarBrokenA", Vector3.new(1.5, 4, 1.5),
		CFrame.new(-156, 2.6, 166) * CFrame.Angles(0, 0, math.rad(20)),
		Color3.fromRGB(50, 60, 90), Enum.Material.Slate)
	newPart(folder, "RuinPillarBrokenB", Vector3.new(1.5, 4, 1.5),
		CFrame.new(-144, 2.6, 166) * CFrame.Angles(0, 0, math.rad(-20)),
		Color3.fromRGB(50, 60, 90), Enum.Material.Slate)
	newPart(folder, "NookWallA", Vector3.new(1, 4, 6),
		CFrame.new(-169, 2.6, 168), Color3.fromRGB(40, 50, 80), Enum.Material.Slate)
	newPart(folder, "NookWallB", Vector3.new(6, 4, 1),
		CFrame.new(-166, 2.6, 173), Color3.fromRGB(40, 50, 80), Enum.Material.Slate)

	-- Treasure chests (positions from Dimensions.luau; base centre sits
	-- 0.75 above the ground point). DimensionsService adds the prompts.
	for _, chest in ipairs(def.Chests) do
		newPart(folder, chest.Name, Vector3.new(2.5, 1.5, 2),
			CFrame.new(chest.Position.X, chest.Position.Y + 0.75, chest.Position.Z),
			Color3.fromRGB(255, 200, 60), Enum.Material.Metal)
		-- Keep the lid as a separate part so a future open animation
		-- has something to move; it never blocks the prompt.
		local lid = newPart(folder, chest.Name .. "Lid", Vector3.new(2.5, 0.8, 2),
			CFrame.new(chest.Position.X, chest.Position.Y + 1.9, chest.Position.Z),
			Color3.fromRGB(200, 150, 40), Enum.Material.Metal)
		lid.CanCollide = false
	end

	-- Boss altar: platform + obelisk. DimensionsService puts the
	-- "Awaken" prompt on the obelisk (named BossAltar).
	newPart(folder, "AltarPlatform", Vector3.new(6, 1, 6),
		CFrame.new(-150, 1.1, 156), Color3.fromRGB(40, 40, 70), Enum.Material.Slate)
	local altar = newPart(folder, "BossAltar", Vector3.new(2, 6, 2),
		CFrame.new(-150, 4.6, 156), Color3.fromRGB(25, 25, 45), Enum.Material.Slate)
	addEmitter(altar, Color3.fromRGB(255, 60, 200), 8, 0.9)

	-- Dangerous-current markers (positions from Dimensions.luau).
	-- Translucent, non-colliding: they mark the hazard, they are not
	-- the hazard — DimensionsService enforces it.
	for _, hazard in ipairs(def.Hazards) do
		local marker = newPart(folder, hazard.Name, Vector3.new(hazard.Radius * 2, 0.5, hazard.Radius * 2),
			CFrame.new(hazard.Center.X, 0.9, hazard.Center.Z),
			Color3.fromRGB(60, 140, 255), Enum.Material.Neon)
		marker.Transparency = 0.75
		marker.CanCollide = false
		marker.CanTouch = false
	end

	-- Return portal (back to the hub), facing the basin centre.
	buildPortalRing(folder, "ReturnPortal",
		Vector3.new(def.ReturnPortalPosition.X, 4.5, def.ReturnPortalPosition.Z),
		0, 3.5, Color3.fromRGB(80, 200, 255), false)
end

local function buildSkyfallKingdom(parent: Model): ()
	local def = Dimensions.GetById("skyfall")
	assert(def ~= nil, "[MapBuilder] Skyfall dimension def missing")
	local folder = Instance.new("Folder")
	folder.Name = "SkyfallKingdom"
	folder.Parent = parent
	_dimensionFolders["skyfall"] = folder

	-- Floating islands: top slab + a crystal shard underneath, so each
	-- island reads as a floating rock from below. Tops (from the defs):
	-- main (150,46,-140) 14², east (172,51,-156) 10²,
	-- west (128,51,-160) 10², summit (150,57,-176) 12².
	local islands = {
		{ Name = "SkyIsland1", Pos = Vector3.new(150, 45, -140), Size = 14 },
		{ Name = "SkyIsland2", Pos = Vector3.new(172, 50, -156), Size = 10 },
		{ Name = "SkyIsland3", Pos = Vector3.new(128, 50, -160), Size = 10 },
		{ Name = "SkyIsland4", Pos = Vector3.new(150, 56, -176), Size = 12 },
	}
	for _, island in ipairs(islands) do
		newPart(folder, island.Name, Vector3.new(island.Size, 2, island.Size),
			CFrame.new(island.Pos.X, island.Pos.Y, island.Pos.Z),
			Color3.fromRGB(140, 190, 255), Enum.Material.Slate)
		local shardSize = island.Size * 0.55
		newPart(folder, island.Name .. "Shard", Vector3.new(shardSize, shardSize, 1.5),
			CFrame.new(island.Pos.X, island.Pos.Y - 2.5, island.Pos.Z)
				* CFrame.Angles(0, 0, math.rad(45)),
			Color3.fromRGB(120, 220, 255), Enum.Material.Neon)
	end

	-- Rope bridges between the islands (deck + visual rails).
	buildBridge(folder, "Bridge1", Vector3.new(157, 46, -148), Vector3.new(167, 51, -152), 3)
	buildBridge(folder, "Bridge2", Vector3.new(143, 46, -147), Vector3.new(133, 51, -155), 3)
	buildBridge(folder, "Bridge3", Vector3.new(133, 51, -165), Vector3.new(144, 57, -172), 3)

	-- Checkpoint pads (positions from Dimensions.luau).
	-- DimensionsService connects the Touched handlers.
	for _, cp in ipairs(def.Checkpoints) do
		local pad = newPart(folder, cp.Name, Vector3.new(4, 0.5, 4),
			CFrame.new(cp.Position), Color3.fromRGB(255, 220, 120), Enum.Material.Neon)
		pad.CanCollide = false
		addEmitter(pad, Color3.fromRGB(255, 220, 120), 6, 0.8)
	end

	-- Wind-hazard markers (positions from Dimensions.luau).
	for _, hazard in ipairs(def.Hazards) do
		local marker = newPart(folder, hazard.Name, Vector3.new(hazard.Radius * 2, 0.4, hazard.Radius * 2),
			CFrame.new(hazard.Center), Color3.fromRGB(200, 230, 255), Enum.Material.Neon)
		marker.Transparency = 0.8
		marker.CanCollide = false
		marker.CanTouch = false
	end

	-- Hidden reward cache (from Dimensions.luau — the SkyCache chest).
	for _, chest in ipairs(def.Chests) do
		newPart(folder, chest.Name, Vector3.new(2.5, 1.5, 2),
			CFrame.new(chest.Position.X, chest.Position.Y + 0.75, chest.Position.Z),
			Color3.fromRGB(255, 200, 60), Enum.Material.Metal)
		local lid = newPart(folder, chest.Name .. "Lid", Vector3.new(2.5, 0.8, 2),
			CFrame.new(chest.Position.X, chest.Position.Y + 1.9, chest.Position.Z),
			Color3.fromRGB(200, 150, 40), Enum.Material.Metal)
		lid.CanCollide = false
	end

	-- Flying-creature ambience: three Sky Wisps (body + trailing mote).
	-- Pure decoration — EnvironmentService orbits them; they are NOT
	-- NPCService spawns (no NPC dependency).
	for i, wisp in ipairs({
		{ Center = Vector3.new(150, 52, -155), Radius = 12 },
		{ Center = Vector3.new(160, 55, -165), Radius = 9 },
		{ Center = Vector3.new(140, 58, -150), Radius = 10 },
	}) do
		local body = newPart(folder, "SkyWisp" .. tostring(i), Vector3.new(2, 1, 3),
			CFrame.new(wisp.Center.X + wisp.Radius, wisp.Center.Y, wisp.Center.Z),
			Color3.fromRGB(255, 240, 160), Enum.Material.Neon)
		body.CanCollide = false
		local trail = newPart(folder, "SkyWispTrail" .. tostring(i), Vector3.new(1, 0.6, 1.6),
			CFrame.new(wisp.Center.X + wisp.Radius - 2, wisp.Center.Y, wisp.Center.Z),
			Color3.fromRGB(255, 220, 120), Enum.Material.Neon)
		trail.Transparency = 0.4
		trail.CanCollide = false
	end

	-- Cloud puffs drifting between the islands (bobbed by
	-- EnvironmentService; non-colliding so they never block a jump).
	for i, cloud in ipairs({
		Vector3.new(140, 42, -150),
		Vector3.new(165, 48, -140),
		Vector3.new(135, 55, -170),
	}) do
		local puff = newPart(folder, "Cloud" .. tostring(i), Vector3.new(8, 1.5, 6),
			CFrame.new(cloud), Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic)
		puff.Transparency = 0.6
		puff.CanCollide = false
	end

	-- Two sky-crystals on the summit island: the "you made it" landmark.
	newPart(folder, "SummitCrystalA", Vector3.new(1.5, 4, 1.5),
		CFrame.new(146, 59, -172), Color3.fromRGB(255, 220, 120), Enum.Material.Neon)
	newPart(folder, "SummitCrystalB", Vector3.new(1.2, 3, 1.2),
		CFrame.new(154, 58.5, -180), Color3.fromRGB(120, 220, 255), Enum.Material.Neon)

	-- Return portal (back to the hub), facing the island centre.
	buildPortalRing(folder, "ReturnPortal",
		Vector3.new(def.ReturnPortalPosition.X, 50.5, def.ReturnPortalPosition.Z),
		0, 3.5, Color3.fromRGB(255, 220, 120), false)
end

-- Build the world. Idempotent: a second call returns the same Model.
function MapBuilder.Build(): Model
	if _built and _model ~= nil then
		return _model
	end
	_lightCount = 0
	_partCount = 0
	_plots = {}
	_safeZones = {}
	_dimensionFolders = {}
	_dimensionPortals = {}

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
	buildAbyssalKingdom(model)
	buildSkyfallKingdom(model)

	model.Parent = Workspace
	_model = model
	_built = true
	print(string.format("[MapBuilder] World built (%d parts, %d PointLights, %d base plots)",
		_partCount, _lightCount, #_plots))
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

-- v1.1 dimension accessors (for DimensionsService / EnvironmentService).
function MapBuilder.GetMapModel(): Model?
	return _model
end

function MapBuilder.GetDimensionFolder(dimensionId: string): Folder?
	return _dimensionFolders[dimensionId]
end

-- The hub-side portal swirl for a dimension (the part
-- DimensionsService attaches the entry ProximityPrompt to).
function MapBuilder.GetDimensionPortal(dimensionId: string): BasePart?
	return _dimensionPortals[dimensionId]
end

function MapBuilder.GetDimensionSpawn(dimensionId: string): Vector3?
	local def = Dimensions.GetById(dimensionId)
	if def == nil then
		return nil
	end
	return def.SpawnPosition
end

function MapBuilder.GetLightCount(): number
	return _lightCount
end

function MapBuilder.GetPartCount(): number
	return _partCount
end

return MapBuilder
