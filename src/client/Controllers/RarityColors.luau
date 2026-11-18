--!strict
-- RarityColors.luau
-- Single source of truth for rarity colours on the client. Every
-- controller requires this module instead of keeping its own copy, so a
-- rarity always looks the same in the HUD, shop, conveyor and collection.
-- No _G, no external assets.
--
-- Rarities: Common grey, Uncommon green, Rare blue, Epic purple,
-- Legendary gold, Mythic pink, Divine cyan, Celestial white,
-- Secret black/red, Impossible rainbow. "Glitch" is the roster's own
-- rarity (see Characters.luau) and maps to a hot magenta/purple.

local RarityColors = {}

RarityColors.Colors = {
	Common = Color3.fromRGB(170, 170, 170),
	Uncommon = Color3.fromRGB(90, 200, 90),
	Rare = Color3.fromRGB(80, 140, 255),
	Epic = Color3.fromRGB(170, 90, 230),
	Legendary = Color3.fromRGB(255, 200, 40),
	Mythic = Color3.fromRGB(255, 110, 200),
	Divine = Color3.fromRGB(60, 220, 230),
	Celestial = Color3.fromRGB(245, 245, 255),
	Secret = Color3.fromRGB(30, 30, 34),
	Impossible = Color3.fromRGB(255, 90, 170),
	Glitch = Color3.fromRGB(190, 90, 255),
}

-- Order used when sorting cards by rarity (highest last).
RarityColors.Order = {
	Common = 1,
	Uncommon = 2,
	Rare = 3,
	Epic = 4,
	Legendary = 5,
	Mythic = 6,
	Divine = 7,
	Celestial = 8,
	Secret = 9,
	Glitch = 9,
	Impossible = 10,
}

local RAINBOW: { Color3 } = {
	Color3.fromRGB(255, 60, 60),
	Color3.fromRGB(255, 170, 0),
	Color3.fromRGB(120, 220, 60),
	Color3.fromRGB(60, 200, 255),
	Color3.fromRGB(170, 90, 255),
	Color3.fromRGB(255, 90, 200),
}

function RarityColors.Get(rarity: string?): Color3
	if rarity == nil then
		return RarityColors.Colors.Common
	end
	return RarityColors.Colors[rarity] or RarityColors.Colors.Common
end

function RarityColors.GetRank(rarity: string?): number
	if rarity == nil then
		return 0
	end
	return RarityColors.Order[rarity] or 0
end

-- Text colour that stays readable on a chip of this rarity's colour.
function RarityColors.GetTextColor(rarity: string?): Color3
	if rarity == "Secret" then
		return Color3.fromRGB(255, 80, 80)
	end
	if rarity == "Celestial" then
		return Color3.fromRGB(40, 40, 60)
	end
	return Color3.fromRGB(255, 255, 255)
end

function RarityColors.IsRainbow(rarity: string?): boolean
	return rarity == "Impossible"
end

-- Paint a Frame/TextButton in the rarity colour. "Impossible" gets a
-- rainbow UIGradient instead of a flat colour.
function RarityColors.Apply(instance: GuiObject, rarity: string?)
	local gui = instance :: Frame
	if RarityColors.IsRainbow(rarity) then
		gui.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		local existing = gui:FindFirstChild("RarityRainbow")
		if existing then
			existing:Destroy()
		end
		local gradient = Instance.new("UIGradient")
		gradient.Name = "RarityRainbow"
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, RAINBOW[1]),
			ColorSequenceKeypoint.new(0.2, RAINBOW[2]),
			ColorSequenceKeypoint.new(0.4, RAINBOW[3]),
			ColorSequenceKeypoint.new(0.6, RAINBOW[4]),
			ColorSequenceKeypoint.new(0.8, RAINBOW[5]),
			ColorSequenceKeypoint.new(1, RAINBOW[6]),
		})
		gradient.Parent = gui
	else
		local existing = gui:FindFirstChild("RarityRainbow")
		if existing then
			existing:Destroy()
		end
		gui.BackgroundColor3 = RarityColors.Get(rarity)
	end
end

-- Library module: no Init work needed, but Main.client.luau's fallback
-- loader only loads modules that expose Init(), so this no-op keeps the
-- loader quiet instead of warning about a "missing" controller.
function RarityColors.Init() end

return RarityColors
