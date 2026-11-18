--!strict
-- CharacterModels.luau
-- Procedural model builder for the 18 original Brainrots. Every model
-- is built from Parts only — no external asset IDs, no meshes, no
-- decals. Each BuildSpec.BodyShape has its own builder branch with
-- different part sizes, shapes, materials and a signature prop welded
-- on, so no two characters share a silhouette.
--
-- CharacterService (server) calls BuildCharacterModel(characterId);
-- the shared contract is Build(characterDef, parent). Both are
-- provided here and build the same model.
--
-- Every part carries a "KeepColor" attribute: CharacterService
-- recolors parts without it to the character's base Color, so the
-- distinct palettes built here survive the morph. Body parts carry
-- "IsBodyPart" so ApplyMutation knows what to recolour.
--
-- Models are built unanchored and welded to the HumanoidRootPart for
-- live NPC / player use. SetDisplayMode(model, true) anchors every
-- part for static display (conveyor / base / shop pedestal).

local Characters = require(script.Parent.Characters)
local Mutations = require(script.Parent.Mutations)

local CharacterModels = {}

local FALLBACK_DEF = {
	Id = "fallback",
	Name = "Fallback Friend",
	DisplayName = "Fallback Friend",
	Color = Color3.fromRGB(200, 200, 200),
	AccentColor = Color3.fromRGB(120, 120, 120),
	Scale = 1,
	BuildSpec = {
		BodyColor = Color3.fromRGB(200, 200, 200),
		HeadColor = Color3.fromRGB(220, 220, 220),
		BodyShape = "Unknown",
		Prop = "None",
		PropColor = Color3.fromRGB(255, 255, 255),
	},
}

-- Create one welded body/prop part.
local function makePart(
	model: Model,
	root: Part,
	name: string,
	size: Vector3,
	shape: Enum.PartType,
	color: Color3,
	material: Enum.Material,
	offset: CFrame,
	isBodyPart: boolean,
	transparency: number?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Shape = shape
	part.Color = color
	part.Material = material
	part.Transparency = transparency or 0
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part:SetAttribute("KeepColor", true)
	if isBodyPart then
		part:SetAttribute("IsBodyPart", true)
	end
	part.CFrame = offset
	part.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
	return part
end

-- Two eyes (white + black pupil) on the front (+Z) face of a head
-- centred at `center` with the given width/height/depth.
local function addEyes(model: Model, root: Part, center: Vector3, width: number, height: number, depth: number)
	local eyeY = center.Y + height * 0.12
	local eyeZ = center.Z + depth * 0.5 + 0.06
	local eyeX = width * 0.22
	for _, side in { -1, 1 } do
		makePart(model, root, "EyeWhite", Vector3.new(0.3, 0.34, 0.12), Enum.PartType.Ball,
			Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic,
			CFrame.new(center.X + side * eyeX, eyeY, eyeZ), false)
		makePart(model, root, "EyePupil", Vector3.new(0.15, 0.18, 0.1), Enum.PartType.Ball,
			Color3.fromRGB(20, 20, 25), Enum.Material.SmoothPlastic,
			CFrame.new(center.X + side * eyeX, eyeY, eyeZ + 0.06), false)
	end
end

local function addSmile(model: Model, root: Part, center: Vector3, depth: number)
	makePart(model, root, "Smile", Vector3.new(0.5, 0.1, 0.08), Enum.PartType.Block,
		Color3.fromRGB(60, 30, 30), Enum.Material.SmoothPlastic,
		CFrame.new(center.X, center.Y - 0.35, center.Z + depth * 0.5 + 0.05), false)
end

-- -- Shape builders: each receives the model, root and def, and builds
-- -- body + head + signature prop. All offsets are in studs from the
-- -- model origin (the HumanoidRootPart at y = 0); bodies sit around
-- -- y = 1.5-2.5 so the model stands on the ground plane.

local BUILDERS: { [string]: (Model, Part, any) -> () } = {}

BUILDERS["Waffle"] = function(model, root, def)
	-- Square waffle body with grid studs, on tiny mechanical legs.
	makePart(model, root, "Body", Vector3.new(2.2, 2.2, 0.7), Enum.PartType.Block,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.2, 0), true)
	for _, gx in { -0.55, 0.55 } do
		for _, gy in { -0.55, 0.55 } do
			makePart(model, root, "WaffleGrid", Vector3.new(0.5, 0.5, 0.12), Enum.PartType.Block,
				def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(gx, 2.2 + gy, 0.4), true)
		end
	end
	addEyes(model, root, Vector3.new(0, 2.5, 0), 2.2, 2.2, 0.7)
	addSmile(model, root, Vector3.new(0, 2.5, 0), 0.7)
	-- Tiny mechanical gear legs.
	for _, side in { -1, 1 } do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.35, 0.9, 0.35), Enum.PartType.Cylinder,
			def.BuildSpec.PropColor, Enum.Material.Metal, CFrame.new(side * 0.6, 0.6, 0) * CFrame.Angles(0, 0, 0), false)
		makePart(model, root, "GearFoot", Vector3.new(0.7, 0.2, 0.7), Enum.PartType.Block,
			Color3.fromRGB(60, 60, 70), Enum.Material.Metal, CFrame.new(side * 0.6, 0.15, 0), false)
	end
end

BUILDERS["Turnip"] = function(model, root, def)
	-- Round purple turnip body, leafy top, oversized red racing boots.
	makePart(model, root, "Body", Vector3.new(1.9, 2.1, 1.9), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.0, 0), true)
	makePart(model, root, "Head", Vector3.new(1.3, 1.1, 1.3), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.2, 0), true)
	makePart(model, root, "Leaf", Vector3.new(1.4, 0.5, 0.8), Enum.PartType.Block,
		Color3.fromRGB(60, 180, 80), Enum.Material.SmoothPlastic, CFrame.new(0, 3.9, 0) * CFrame.Angles(0, 0.5, 0), false)
	addEyes(model, root, Vector3.new(0, 3.2, 0), 1.3, 1.1, 1.3)
	addSmile(model, root, Vector3.new(0, 3.2, 0), 1.3)
	for _, side in { -1, 1 } do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.95, 0.7, 1.4), Enum.PartType.Block,
			def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(side * 0.65, 0.35, 0.15), false)
	end
end

BUILDERS["Jelly"] = function(model, root, def)
	-- Double-layered jelly: translucent outer dome, glowing inner core.
	makePart(model, root, "Body", Vector3.new(2.4, 2.2, 2.4), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.Glass, CFrame.new(0, 2.0, 0), true, 0.3)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(1.3, 1.3, 1.3), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 2.0, 0), false)
	makePart(model, root, "Head", Vector3.new(1.2, 1.0, 1.2), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.Glass, CFrame.new(0, 3.3, 0), true, 0.3)
	addEyes(model, root, Vector3.new(0, 3.3, 0), 1.2, 1.0, 1.2)
	addSmile(model, root, Vector3.new(0, 3.3, 0), 1.2)
end

BUILDERS["Comet"] = function(model, root, def)
	-- Blazing pastry comet: round head, tapering glowing trail behind.
	makePart(model, root, "Head", Vector3.new(1.5, 1.5, 1.5), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.Neon, CFrame.new(0, 2.2, 0.6), true)
	makePart(model, root, "Body", Vector3.new(1.2, 1.2, 1.6), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.Neon, CFrame.new(0, 2.2, -0.4), true)
	addEyes(model, root, Vector3.new(0, 2.2, 0.6), 1.5, 1.5, 1.5)
	-- Glowing trail: three shrinking embers trailing behind (-Z).
	local trailSizes = { 1.0, 0.7, 0.45 }
	for i, size in trailSizes do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(size, size, size), Enum.PartType.Ball,
			def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 2.2, -1.3 - (i - 1) * 0.8), false)
	end
end

BUILDERS["Noodle"] = function(model, root, def)
	-- Tangled noodle monster: stacked coiled strands, tiny orbiting stars.
	for i, y in { 1.3, 1.9, 2.5 } do
		makePart(model, root, "Body", Vector3.new(2.2, 0.55, 2.2), Enum.PartType.Cylinder,
			def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic,
			CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.pi / 2), true)
	end
	makePart(model, root, "Head", Vector3.new(1.4, 1.2, 1.4), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.3, 0), true)
	addEyes(model, root, Vector3.new(0, 3.3, 0), 1.4, 1.2, 1.4)
	addSmile(model, root, Vector3.new(0, 3.3, 0), 1.4)
	-- Tiny stars orbiting the head.
	local starAngles = { 0, 1.6, 3.1, 4.7 }
	for i, angle in starAngles do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.3, 0.3, 0.3), Enum.PartType.Ball,
			def.BuildSpec.PropColor, Enum.Material.Neon,
			CFrame.new(math.cos(angle) * 1.5, 3.9 + math.sin(angle * 2) * 0.2, math.sin(angle) * 1.5), false)
	end
end

BUILDERS["ToastGhost"] = function(model, root, def)
	-- Haunted toast: golden slice under a translucent ghost sheet.
	makePart(model, root, "Body", Vector3.new(1.8, 2.2, 0.5), Enum.PartType.Block,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.2, 0), true)
	makePart(model, root, "Crust", Vector3.new(2.0, 2.4, 0.35), Enum.PartType.Block,
		Color3.fromRGB(160, 110, 50), Enum.Material.SmoothPlastic, CFrame.new(0, 2.2, -0.08), true)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(2.2, 2.6, 1.2), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Glass, CFrame.new(0, 2.0, 0), false, 0.45)
	for _, x in { -0.7, 0, 0.7 } do
		makePart(model, root, "SheetHem", Vector3.new(0.55, 0.5, 0.55), Enum.PartType.Ball,
			def.BuildSpec.PropColor, Enum.Material.Glass, CFrame.new(x, 0.7, 0), false, 0.45)
	end
	addEyes(model, root, Vector3.new(0, 2.9, 0), 1.8, 2.2, 1.2)
end

BUILDERS["Dumpling"] = function(model, root, def)
	-- Plump dumpling with pleated top, disco ball floating overhead.
	makePart(model, root, "Body", Vector3.new(2.4, 1.6, 1.6), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 1.6, 0), true)
	for _, x in { -0.7, 0, 0.7 } do
		makePart(model, root, "Pleat", Vector3.new(0.35, 0.5, 0.4), Enum.PartType.Block,
			def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(x, 2.5, 0), true)
	end
	addEyes(model, root, Vector3.new(0, 1.8, 0), 2.4, 1.6, 1.6)
	addSmile(model, root, Vector3.new(0, 1.8, 0), 1.6)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.9, 0.9, 0.9), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Metal, CFrame.new(0, 3.8, 0), false)
	for i, color in { Color3.fromRGB(255, 60, 60), Color3.fromRGB(60, 255, 120), Color3.fromRGB(90, 140, 255) } do
		local angle = (i - 1) * 2.1
		makePart(model, root, "DiscoLight", Vector3.new(0.25, 0.25, 0.25), Enum.PartType.Ball,
			color, Enum.Material.Neon, CFrame.new(math.cos(angle) * 1.1, 3.8, math.sin(angle) * 1.1), false)
	end
end

BUILDERS["PicklePirate"] = function(model, root, def)
	-- Tall robotic pickle: vertical cylinder body, brass pirate hat, cutlass.
	makePart(model, root, "Body", Vector3.new(1.5, 2.6, 1.5), Enum.PartType.Cylinder,
		def.BuildSpec.BodyColor, Enum.Material.Metal, CFrame.new(0, 2.0, 0), true)
	makePart(model, root, "Head", Vector3.new(1.3, 1.1, 1.3), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.Metal, CFrame.new(0, 3.6, 0), true)
	addEyes(model, root, Vector3.new(0, 3.6, 0), 1.3, 1.1, 1.3)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(1.9, 0.25, 1.9), Enum.PartType.Cylinder,
		def.BuildSpec.PropColor, Enum.Material.SmoothPlastic, CFrame.new(0, 4.1, 0), false)
	makePart(model, root, "HatTop", Vector3.new(1.1, 0.7, 1.1), Enum.PartType.Cylinder,
		Color3.fromRGB(40, 40, 50), Enum.Material.SmoothPlastic, CFrame.new(0, 4.5, 0), false)
	-- Laser cutlass held to the side.
	makePart(model, root, "Cutlass", Vector3.new(0.18, 1.6, 0.4), Enum.PartType.Block,
		Color3.fromRGB(200, 220, 255), Enum.Material.Neon, CFrame.new(1.2, 2.0, 0.3) * CFrame.Angles(0.4, 0, -0.3), false)
end

BUILDERS["Mochi"] = function(model, root, def)
	-- Soft round lunar dessert: two stacked mochi orbs, golden moon crest.
	makePart(model, root, "Body", Vector3.new(2.1, 1.7, 2.1), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 1.5, 0), true)
	makePart(model, root, "Head", Vector3.new(1.5, 1.3, 1.5), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.9, 0), true)
	addEyes(model, root, Vector3.new(0, 2.9, 0), 1.5, 1.3, 1.5)
	addSmile(model, root, Vector3.new(0, 2.9, 0), 1.5)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.7, 0.7, 0.3), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 3.9, 0), false)
	makePart(model, root, "MoonGlow", Vector3.new(1.0, 1.0, 0.2), Enum.PartType.Ball,
		Color3.fromRGB(255, 240, 160), Enum.Material.Neon, CFrame.new(0, 3.9, -0.15), false)
end

BUILDERS["Gumball"] = function(model, root, def)
	-- Enormous rolling candy beast: giant sphere with a swirl cap.
	makePart(model, root, "Body", Vector3.new(2.9, 2.9, 2.9), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 1.9, 0), true)
	makePart(model, root, "Stripe", Vector3.new(3.0, 0.4, 3.0), Enum.PartType.Cylinder,
		Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic, CFrame.new(0, 1.9, 0), true)
	makePart(model, root, "Head", Vector3.new(1.4, 1.2, 1.4), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.6, 0), true)
	addEyes(model, root, Vector3.new(0, 3.6, 0), 1.4, 1.2, 1.4)
	addSmile(model, root, Vector3.new(0, 3.6, 0), 1.4)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(1.1, 0.6, 1.1), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 4.4, 0), false)
end

BUILDERS["SoupShip"] = function(model, root, def)
	-- Flying soup-bowl spaceship: wide bowl, glowing broth, antenna.
	makePart(model, root, "Body", Vector3.new(2.8, 1.2, 2.8), Enum.PartType.Cylinder,
		def.BuildSpec.BodyColor, Enum.Material.Metal, CFrame.new(0, 1.8, 0), true)
	makePart(model, root, "Broth", Vector3.new(2.4, 0.4, 2.4), Enum.PartType.Cylinder,
		def.AccentColor, Enum.Material.Neon, CFrame.new(0, 2.4, 0), true)
	makePart(model, root, "Head", Vector3.new(1.3, 1.1, 1.3), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.2, 0), true)
	addEyes(model, root, Vector3.new(0, 3.2, 0), 1.3, 1.1, 1.3)
	addSmile(model, root, Vector3.new(0, 3.2, 0), 1.3)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.15, 1.2, 0.15), Enum.PartType.Cylinder,
		Color3.fromRGB(150, 150, 160), Enum.Material.Metal, CFrame.new(0, 4.3, 0), false)
	makePart(model, root, "AntennaTip", Vector3.new(0.45, 0.45, 0.45), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 5.0, 0), false)
	for _, side in { -1, 1 } do
		makePart(model, root, "Engine", Vector3.new(0.6, 0.6, 0.6), Enum.PartType.Ball,
			Color3.fromRGB(255, 240, 160), Enum.Material.Neon, CFrame.new(side * 1.1, 1.2, 0), false)
	end
end

BUILDERS["Puddle"] = function(model, root, def)
	-- Intelligent liquid creature: flat spreading puddle, head rising out.
	makePart(model, root, "Body", Vector3.new(3.1, 0.8, 2.5), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.Glass, CFrame.new(0, 0.6, 0), true, 0.15)
	makePart(model, root, "Head", Vector3.new(1.3, 1.3, 1.3), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.Glass, CFrame.new(0, 1.8, 0), true, 0.15)
	makePart(model, root, "SplashDrop", Vector3.new(0.5, 0.7, 0.5), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.Glass, CFrame.new(1.2, 1.2, 0.4), false, 0.15)
	addEyes(model, root, Vector3.new(0, 1.9, 0), 1.3, 1.3, 1.3)
	addSmile(model, root, Vector3.new(0, 1.9, 0), 1.3)
	-- Tiny gold glasses.
	for _, side in { -1, 1 } do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.5, 0.5, 0.1), Enum.PartType.Cylinder,
			def.BuildSpec.PropColor, Enum.Material.Metal, CFrame.new(side * 0.32, 2.0, 0.68) * CFrame.Angles(math.pi / 2, 0, 0), false)
	end
	makePart(model, root, "GlassesBridge", Vector3.new(0.35, 0.08, 0.08), Enum.PartType.Block,
		def.BuildSpec.PropColor, Enum.Material.Metal, CFrame.new(0, 2.0, 0.68), false)
end

BUILDERS["Spaghetti"] = function(model, root, def)
	-- Spring-legged pasta: noodle coil body, sauce swirl, spring legs.
	for i, y in { 1.4, 1.9, 2.4 } do
		makePart(model, root, "Body", Vector3.new(2.0, 0.5, 2.0), Enum.PartType.Cylinder,
			def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic,
			CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.pi / 2), true)
	end
	makePart(model, root, "SauceSwirl", Vector3.new(1.2, 0.3, 1.2), Enum.PartType.Ball,
		def.AccentColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.7, 0), true)
	makePart(model, root, "Head", Vector3.new(1.3, 1.1, 1.3), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.3, 0), true)
	addEyes(model, root, Vector3.new(0, 3.3, 0), 1.3, 1.1, 1.3)
	addSmile(model, root, Vector3.new(0, 3.3, 0), 1.3)
	-- Spring legs: coiled grey springs with red feet.
	for _, side in { -1, 1 } do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.3, 0.9, 0.3), Enum.PartType.Cylinder,
			Color3.fromRGB(150, 150, 160), Enum.Material.Metal, CFrame.new(side * 0.6, 0.65, 0), false)
		makePart(model, root, "SpringFoot", Vector3.new(0.6, 0.2, 0.6), Enum.PartType.Block,
			def.BuildSpec.PropColor, Enum.Material.SmoothPlastic, CFrame.new(side * 0.6, 0.15, 0), false)
	end
end

BUILDERS["Zucchini"] = function(model, root, def)
	-- Electrical vegetable: long horizontal zucchini, tesla coil on top.
	makePart(model, root, "Body", Vector3.new(1.4, 1.4, 2.8), Enum.PartType.Cylinder,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic,
		CFrame.new(0, 1.8, 0) * CFrame.Angles(math.pi / 2, 0, 0), true)
	makePart(model, root, "Head", Vector3.new(1.3, 1.3, 1.3), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 1.8, 1.6), true)
	addEyes(model, root, Vector3.new(0, 1.9, 1.6), 1.3, 1.3, 1.3)
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.35, 1.3, 0.35), Enum.PartType.Cylinder,
		Color3.fromRGB(150, 150, 160), Enum.Material.Metal, CFrame.new(0, 3.0, -0.6), false)
	makePart(model, root, "CoilTop", Vector3.new(0.7, 0.7, 0.7), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 3.8, -0.6), false)
	for _, x in { -0.5, 0.5 } do
		makePart(model, root, "Spark", Vector3.new(0.25, 0.25, 0.25), Enum.PartType.Ball,
			Color3.fromRGB(255, 255, 200), Enum.Material.Neon, CFrame.new(x, 3.9, -0.6), false)
	end
end

BUILDERS["Cupcake"] = function(model, root, def)
	-- Dessert with planetary rings: ridged wrapper, frosting dome, cherry.
	makePart(model, root, "Body", Vector3.new(2.1, 1.5, 2.1), Enum.PartType.Cylinder,
		Color3.fromRGB(180, 90, 60), Enum.Material.SmoothPlastic, CFrame.new(0, 1.4, 0), true)
	for i = 1, 6 do
		local angle = (i - 1) * math.pi / 3
		makePart(model, root, "WrapperRidge", Vector3.new(0.25, 1.4, 0.25), Enum.PartType.Block,
			Color3.fromRGB(200, 110, 70), Enum.Material.SmoothPlastic,
			CFrame.new(math.cos(angle) * 1.0, 1.4, math.sin(angle) * 1.0), true)
	end
	makePart(model, root, "Head", Vector3.new(1.9, 1.4, 1.9), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.9, 0), true)
	makePart(model, root, "Cherry", Vector3.new(0.55, 0.55, 0.55), Enum.PartType.Ball,
		Color3.fromRGB(220, 30, 50), Enum.Material.SmoothPlastic, CFrame.new(0, 3.8, 0), false)
	addEyes(model, root, Vector3.new(0, 2.9, 0), 1.9, 1.4, 1.9)
	addSmile(model, root, Vector3.new(0, 2.9, 0), 1.9)
	-- Two tilted planetary rings around the whole cupcake.
	for _, tilt in { 0.5, -0.4 } do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(3.6, 0.12, 3.6), Enum.PartType.Cylinder,
			def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(0, 2.2, 0) * CFrame.Angles(tilt, 0, 0.3), false)
	end
end

BUILDERS["Goose"] = function(model, root, def)
	-- Unstable pixelated bird: long neck, orange beak, stepped pixel wings.
	makePart(model, root, "Body", Vector3.new(1.6, 1.4, 2.3), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 1.7, 0), true)
	makePart(model, root, "Neck", Vector3.new(0.55, 1.4, 0.55), Enum.PartType.Cylinder,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.9, 0.8), true)
	makePart(model, root, "Head", Vector3.new(0.95, 0.9, 1.1), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.8, 0.8), true)
	makePart(model, root, "Beak", Vector3.new(0.5, 0.3, 0.7), Enum.PartType.Wedge,
		Color3.fromRGB(255, 160, 40), Enum.Material.SmoothPlastic, CFrame.new(0, 3.7, 1.5), false)
	addEyes(model, root, Vector3.new(0, 3.9, 0.8), 0.95, 0.9, 1.1)
	-- Stepped pixel wings in glitch magenta/cyan.
	for _, side in { -1, 1 } do
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(0.25, 0.9, 1.2), Enum.PartType.Block,
			def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(side * 1.0, 2.0, -0.2), false)
		makePart(model, root, "PixelWingStep", Vector3.new(0.25, 0.5, 0.7), Enum.PartType.Block,
			Color3.fromRGB(80, 240, 255), Enum.Material.Neon, CFrame.new(side * 1.25, 1.7, -0.2), false)
	end
end

BUILDERS["Crab"] = function(model, root, def)
	-- Caramel-coated crab: wide flat body, six thin legs, giant claws.
	makePart(model, root, "Body", Vector3.new(2.7, 1.4, 2.0), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 1.5, 0), true)
	makePart(model, root, "Head", Vector3.new(1.5, 1.1, 1.2), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.3, 0.3), true)
	addEyes(model, root, Vector3.new(0, 2.5, 0.3), 1.5, 1.1, 1.2)
	for _, side in { -1, 1 } do
		for _, z in { -0.7, 0, 0.7 } do
			makePart(model, root, "Leg", Vector3.new(0.18, 0.18, 1.1), Enum.PartType.Cylinder,
				def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic,
				CFrame.new(side * 1.6, 1.0, z) * CFrame.Angles(0, 0, math.pi / 2), false)
		end
		-- Oversized golden claw on each side.
		makePart(model, root, def.BuildSpec.Prop, Vector3.new(1.0, 0.8, 0.9), Enum.PartType.Ball,
			def.BuildSpec.PropColor, Enum.Material.Metal, CFrame.new(side * 1.9, 1.6, 0.6), false)
		makePart(model, root, "ClawPincer", Vector3.new(0.35, 0.5, 0.5), Enum.PartType.Block,
			def.BuildSpec.PropColor, Enum.Material.Metal, CFrame.new(side * 1.9, 1.9, 1.2), false)
	end
end

BUILDERS["WobbleKing"] = function(model, root, def)
	-- Legendary ruler: tall golden waffle body, purple cape, crown, sceptre.
	makePart(model, root, "Cape", Vector3.new(2.7, 2.8, 0.25), Enum.PartType.Block,
		def.BuildSpec.PropColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.2, -0.65), false)
	makePart(model, root, "Body", Vector3.new(2.4, 2.4, 1.0), Enum.PartType.Block,
		def.BuildSpec.BodyColor, Enum.Material.Foil, CFrame.new(0, 2.3, 0), true)
	for _, gx in { -0.6, 0.6 } do
		for _, gy in { -0.6, 0.6 } do
			makePart(model, root, "WaffleGrid", Vector3.new(0.5, 0.5, 0.12), Enum.PartType.Block,
				def.BuildSpec.HeadColor, Enum.Material.Foil, CFrame.new(gx, 2.3 + gy, 0.55), true)
		end
	end
	makePart(model, root, "Head", Vector3.new(1.6, 1.4, 1.2), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.Foil, CFrame.new(0, 4.0, 0), true)
	addEyes(model, root, Vector3.new(0, 4.1, 0), 1.6, 1.4, 1.2)
	addSmile(model, root, Vector3.new(0, 4.1, 0), 1.2)
	-- Royal crown: gold band with three points.
	makePart(model, root, def.BuildSpec.Prop, Vector3.new(1.5, 0.35, 1.5), Enum.PartType.Cylinder,
		Color3.fromRGB(255, 220, 80), Enum.Material.Foil, CFrame.new(0, 4.8, 0), false)
	for _, x in { -0.55, 0, 0.55 } do
		makePart(model, root, "CrownPoint", Vector3.new(0.3, 0.5, 0.3), Enum.PartType.Block,
			Color3.fromRGB(255, 220, 80), Enum.Material.Foil, CFrame.new(x, 5.1, 0), false)
	end
	-- Royal sceptre held to the side.
	makePart(model, root, "Sceptre", Vector3.new(0.18, 2.2, 0.18), Enum.PartType.Cylinder,
		Color3.fromRGB(255, 220, 80), Enum.Material.Foil, CFrame.new(1.6, 2.2, 0.3), false)
	makePart(model, root, "SceptreOrb", Vector3.new(0.5, 0.5, 0.5), Enum.PartType.Ball,
		def.BuildSpec.PropColor, Enum.Material.Neon, CFrame.new(1.6, 3.4, 0.3), false)
end

-- Fallback for an unknown BodyShape: a simple rounded body with a
-- warning, so a bad shape name can never break a build.
local function buildFallback(model: Model, root: Part, def: any)
	warn("[CharacterModels] Unknown BodyShape \"" .. tostring(def.BuildSpec.BodyShape) .. "\" for " .. tostring(def.Id) .. " — using fallback body.")
	makePart(model, root, "Body", Vector3.new(2.0, 2.0, 2.0), Enum.PartType.Ball,
		def.BuildSpec.BodyColor, Enum.Material.SmoothPlastic, CFrame.new(0, 2.0, 0), true)
	makePart(model, root, "Head", Vector3.new(1.4, 1.2, 1.4), Enum.PartType.Ball,
		def.BuildSpec.HeadColor, Enum.Material.SmoothPlastic, CFrame.new(0, 3.4, 0), true)
	addEyes(model, root, Vector3.new(0, 3.4, 0), 1.4, 1.2, 1.4)
	addSmile(model, root, Vector3.new(0, 3.4, 0), 1.4)
end

-- Build a Model from a CharacterDef (or a character Id string).
-- parent: optional Instance to parent the finished model to; when
-- omitted the model is returned unparented.
function CharacterModels.Build(characterDef: any, parent: Instance?): Model
	local def = characterDef
	if type(def) == "string" then
		def = Characters.GetById(def)
	end
	if type(def) ~= "table" or def.BuildSpec == nil then
		warn("[CharacterModels] Build called with an unknown character — using fallback model.")
		def = FALLBACK_DEF
	end

	local model = Instance.new("Model")
	model.Name = def.DisplayName or def.Id or "Brainrot"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Shape = Enum.PartType.Block
	root.Color = def.Color or Color3.fromRGB(255, 255, 255)
	root.Material = Enum.Material.SmoothPlastic
	root.Transparency = 1
	root.Anchored = false
	root.CanCollide = true
	root.CanQuery = false
	root.CanTouch = false
	root.Massless = true
	root:SetAttribute("KeepColor", true)
	root.CFrame = CFrame.new(0, 2, 0)
	root.Parent = model
	model.PrimaryPart = root

	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayName = def.DisplayName or def.Id or "Brainrot"
	humanoid.MaxHealth = def.Health or 100
	humanoid.Health = def.Health or 100
	humanoid.WalkSpeed = def.Speed or 16
	humanoid.Parent = model

	local builder = BUILDERS[def.BuildSpec.BodyShape]
	if builder ~= nil then
		builder(model, root, def)
	else
		buildFallback(model, root, def)
	end

	-- Tag the model so combat / waves can identify the character.
	local tag = Instance.new("StringValue")
	tag.Name = "CharacterId"
	tag.Value = def.Id or "fallback"
	tag.Parent = model

	if parent ~= nil then
		model.Parent = parent
	end
	return model
end

-- Build a Model from a character Id. This is the entry point
-- CharacterService uses (BuildCharacterModel(characterId)).
function CharacterModels.BuildCharacterModel(characterId: string, parent: Instance?): Model
	local def = Characters.GetById(characterId)
	if def == nil then
		warn("[CharacterModels] BuildCharacterModel called with unknown id \"" .. tostring(characterId) .. "\" — using fallback model.")
		return CharacterModels.Build(FALLBACK_DEF, parent)
	end
	return CharacterModels.Build(def, parent)
end

-- Anchor (true) or un-anchor (false) every part of a model. Use true
-- for static display (conveyor, base, shop pedestal) and false for
-- live NPC / player use, where parts must stay welded to the root.
function CharacterModels.SetDisplayMode(model: Model, anchored: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = anchored
		end
	end
end

-- Visibly mutate a built model: body parts take the mutation's
-- material and colour, a particle emitter in the mutation's
-- ParticleColor is attached to the root, and a "MutationId" attribute
-- records the mutation. Returns false when the mutation Id is unknown.
function CharacterModels.ApplyMutation(model: Model, mutationId: string): boolean
	local mutation = Mutations.GetById(mutationId)
	if mutation == nil then
		warn("[CharacterModels] ApplyMutation called with unknown mutation \"" .. tostring(mutationId) .. "\".")
		return false
	end

	local material = Enum.Material.SmoothPlastic
	local ok = pcall(function()
		material = (Enum.Material :: any)[mutation.Material]
	end)
	if not ok or material == nil then
		material = Enum.Material.SmoothPlastic
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:GetAttribute("IsBodyPart") then
			descendant.Material = material
			descendant.Color = mutation.Color
		end
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		local old = root:FindFirstChild("MutationParticles")
		if old ~= nil then
			old:Destroy()
		end
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "MutationParticles"
		emitter.Color = ColorSequence.new(mutation.ParticleColor)
		emitter.Rate = 8
		emitter.Lifetime = NumberRange.new(0.8, 1.6)
		emitter.Speed = NumberRange.new(1, 3)
		emitter.Size = NumberSequence.new(0.4)
		emitter.Transparency = NumberSequence.new(0.2, 0.9)
		emitter.Parent = root
	end

	model:SetAttribute("MutationId", mutationId)
	return true
end

-- Vertical idle bob offset (in studs) for a floating / dancing idle
-- pose at time `t` (seconds). Client animation code adds this to the
-- model's Y position; it is a pure function with no side effects.
function CharacterModels.GetIdleOffset(t: number): number
	return math.sin(t * 2) * 0.15
end

return CharacterModels
