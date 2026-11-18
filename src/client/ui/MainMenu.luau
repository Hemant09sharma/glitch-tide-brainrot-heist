--!strict
-- MainMenu.luau
-- Main menu for GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE.
-- Title "GLITCH TIDE", subtitle "BRAINROT HEIST: THE MEMEVERSE",
-- tagline "COLLECT THE CHAOS. BUILD YOUR EMPIRE. SURVIVE THE TIDE."
-- Every button does something real — no fake buttons:
--   PLAY        closes the menu (ready poof at spawn, as before)
--   COLLECTION  opens CollectionController if present, else an in-menu
--               panel listing every Brainrot from the shared catalogue
--   SETTINGS    mute toggle that actually calls SoundController, plus
--               Master / SFX / Music volume steppers (v1.1 E) and a
--               controls recap
--   HOW TO PLAY shows the core loop steps + full keybind list
--   OBJECTIVES  the starter quest chain (live top quest from
--               QuestController when available, else the static
--               core-loop steps) — v1.1 E onboarding
--   LAB / EXPEDITIONS / TERRITORY / WORLDS / ACHIEVEMENTS open the
--               new Wave 3 panels directly from the menu (v1.1 E)
-- If a target controller is absent, the button opens a simple in-menu
-- panel with real content (controls list / credits) — never a dead end.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local MainMenu = {}

local gui: ScreenGui? = nil
local visible = false
local infoPanel: Frame? = nil
local infoTitle: TextLabel? = nil
local infoBody: TextLabel? = nil
local infoScroll: ScrollingFrame? = nil
local muteButton: TextButton? = nil
local volumeButton: TextButton? = nil
local sfxButton: TextButton? = nil
local musicButton: TextButton? = nil
local collectionButton: TextButton? = nil

local Utils: any = nil
pcall(function()
	Utils = require(ReplicatedStorage:WaitForChild("Utils", 10))
end)

-- Every key shown on this menu comes from the shared bind table
-- (Utils.GetKeybinds): ability keys from Config.GenericAbilities,
-- the rest from the single client-side bind table. No key is a
-- literal in the text below.
-- NOTE (v1.0.1): Config now binds slam to "F" (E is Interact), matching
-- AbilityController — the canonical mapping is Q primary / F Slam /
-- R Heal. Labels are dynamic via Utils.GetKeybinds, so a Config change
-- corrects them everywhere at once. See Utils.GetAbilityKey.
local function getBinds(): { [string]: string }
	if Utils and Utils.GetKeybinds then
		local ok, binds = pcall(function()
			return Utils.GetKeybinds()
		end)
		if ok and type(binds) == "table" then
			return binds
		end
	end
	return {
		Interact = "E",
		Drop = "G",
		Mute = "M",
		Market = "N",
		Shop = "B",
		Brainrots = "C",
		Base = "V",
		Quests = "J",
		Collection = "L",
		Primary = "Q",
		Slam = "F",
		Heal = "R",
	}
end

local function styleButton(button: TextButton, bg: Color3)
	button.BackgroundColor3 = bg
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = button
end

local function getControllersFolder(): Folder?
	-- MainMenu lives in StarterGui (cloned to PlayerGui); the controllers
	-- live in StarterPlayerScripts (cloned to PlayerScripts). They are
	-- NOT siblings, so go through PlayerScripts, not script.Parent.
	local ok, playerScripts = pcall(function()
		return player:WaitForChild("PlayerScripts", 5)
	end)
	if not ok or not playerScripts then
		return nil
	end
	return playerScripts:FindFirstChild("Controllers") :: Folder?
end

local function getSoundController(): any
	local controllers = getControllersFolder()
	local mod = controllers and controllers:FindFirstChild("SoundController")
	if not mod then
		return nil
	end
	local ok2, controller = pcall(require, mod)
	if ok2 then
		return controller
	end
	return nil
end

-- Open a controller panel by module name (v1.1 E menu shortcuts).
-- Returns true when a panel actually opened.
local function openController(moduleName: string): boolean
	local opened = false
	pcall(function()
		local controllers = getControllersFolder()
		local mod = controllers and controllers:FindFirstChild(moduleName)
		if mod then
			local controller = require(mod)
			if controller and controller.Open then
				controller.Open()
				opened = true
			elseif controller and controller.Toggle then
				controller.Toggle()
				opened = true
			end
		end
	end)
	return opened
end

-- Objectives (v1.1 E onboarding): the live top quest when
-- QuestController can supply one, else the static starter chain.
local function buildObjectivesText(): string
	local top: any = nil
	pcall(function()
		local controllers = getControllersFolder()
		local mod = controllers and controllers:FindFirstChild("QuestController")
		if mod then
			local quests = require(mod)
			if quests and quests.GetTopQuest then
				top = quests.GetTopQuest()
			end
		end
	end)
	if typeof(top) == "table" then
		local progress = top.Progress or top.progress or top.Current or 0
		local goal = top.Goal or top.goal or top.Target or 1
		local title = tostring(top.Title or top.title or top.Name or "Quest")
		local desc = tostring(top.Description or top.description or "")
		return "YOUR NEXT OBJECTIVE\n"
			.. "📜 " .. title .. "  —  " .. tostring(math.floor(progress)) .. "/" .. tostring(goal) .. "\n"
			.. desc .. "\n\n"
			.. "Then keep going: buy Brainrots, place them, upgrade your\n"
			.. "base, explore the Worlds (Abyssal at Lv 5, Skyfall at Lv 15),\n"
			.. "and survive the Glitch Tide."
	end
	local b = getBinds()
	return "YOUR FIRST OBJECTIVES\n"
		.. "1. Buy a Brainrot on the conveyor (" .. b.Market .. " for Market).\n"
		.. "2. Carry it home and place it in your base (" .. b.Interact .. ").\n"
		.. "3. Collect the coins it earns (" .. b.Base .. " for Base).\n"
		.. "4. Buy base upgrades in the Shop (" .. b.Shop .. ").\n"
		.. "5. Check Quests (" .. b.Quests .. ") — the quest chain pays\n"
		.. "   coins and gems for doing the loop.\n"
		.. "6. Reach Lv 5 to unlock the Abyssal world, Lv 15 for Skyfall.\n\n"
		.. "Quests are not loaded yet — this is the starter chain.\n"
		.. "Open Quests in-game for the live list."
end

local function showInfo(title: string, body: string)
	if not infoPanel or not infoTitle or not infoBody then
		return
	end
	infoTitle.Text = title
	infoBody.Text = body
	infoPanel.Visible = true
end

local function hideInfo()
	if infoPanel then
		infoPanel.Visible = false
	end
end

local function buildCollectionText(): string
	local lines = { "BRAINROT COLLECTION\n" }
	local ok, chars = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Characters", 10))
	end)
	if ok and chars and chars.GetAll then
		local ok2, list = pcall(function()
			return chars.GetAll()
		end)
		if ok2 and typeof(list) == "table" then
			for _, def in list do
				table.insert(
					lines,
					string.format(
						"• %s  [%s]  🪙 %d  •  +%d/s",
						tostring(def.DisplayName or def.Name),
						tostring(def.Rarity),
						def.Cost or 0,
						def.IncomePerSec or 0
					)
				)
			end
			table.insert(lines, "\nOwn or equip one in-game (C) to reveal its full card.")
			return table.concat(lines, "\n")
		end
	end
	return "Collection data is not available yet."
end

local function buildHowToPlayText(): string
	local b = getBinds()
	return "THE CORE LOOP\n"
		.. "1. Watch the conveyor — rare Brainrots roll past.\n"
		.. "2. Buy one (" .. b.Market .. " for Market, or " .. b.Interact .. " when close).\n"
		.. "3. Carry it home and place it in your base (" .. b.Interact .. ").\n"
		.. "4. It earns coins every second. Collect them (" .. b.Base .. ").\n"
		.. "5. Spend coins on base upgrades (" .. b.Shop .. ") and new Brainrots.\n"
		.. "6. Steal from rivals — and guard your own base!\n"
		.. "7. When the GLITCH TIDE hits, income doubles — and\n"
		.. "   glitched Brainrots flood the conveyor.\n\n"
		.. "CONTROLS\n"
		.. "WASD — Move    •    Mouse — Look / aim\n"
		.. "Left Click — Attack\n"
		.. b.Interact .. " — Interact (buy / place / pick up / talk)\n"
		.. b.Primary .. " — Primary power    •    " .. b.Slam .. " — Slam    •    " .. b.Heal .. " — Heal\n"
		.. b.Drop .. " — Drop carried Brainrot\n"
		.. b.Market .. " — Market    •    " .. b.Shop .. " — Shop    •    " .. b.Brainrots .. " — Brainrots\n"
		.. b.Base .. " — Base    •    " .. b.Quests .. " — Quests    •    " .. b.Collection .. " — Collection\n"
		.. b.Mute .. " — Mute sounds"
end

local function buildControlsText(): string
	local b = getBinds()
	return "CONTROLS\n"
		.. "WASD — Move    •    Mouse — Look / aim\n"
		.. "Left Click — Attack\n"
		.. b.Interact .. " — Interact    •    " .. b.Drop .. " — Drop carried Brainrot\n"
		.. b.Primary .. " — Primary power    •    " .. b.Slam .. " — Slam    •    " .. b.Heal .. " — Heal\n"
		.. b.Market .. " — Market    •    " .. b.Shop .. " — Shop    •    " .. b.Brainrots .. " — Brainrots\n"
		.. b.Base .. " — Base    •    " .. b.Quests .. " — Quests    •    " .. b.Collection .. " — Collection\n"
		.. b.Mute .. " — Mute sounds\n\n"
		.. "VOLUME\n"
		.. "Master / SFX / Music steppers below (100% → 70% → 40%).\n"
		.. "Music volume is stored for the future music system — no\n"
		.. "music tracks exist yet, so it scales nothing audible today.\n"
		.. "Volumes are client-local (no server sound store exists).\n\n"
		.. "CREDITS\n"
		.. "Glitch Tide — Brainrot Heist: The Memeverse.\n"
		.. "Original fan-inspired game — no assets copied."
end

local function refreshMuteButton()
	if not muteButton then
		return
	end
	local sound = getSoundController()
	local muted = false
	if sound and sound.IsMuted then
		local ok, value = pcall(function()
			return sound.IsMuted()
		end)
		if ok then
			muted = value
		end
	end
	muteButton.Text = if muted then "🔇 SOUND: MUTED (tap to unmute)" else "🔊 SOUND: ON (tap to mute)"
end

-- Volume cycles 100% → 70% → 40% → 100% (SoundController.SetVolume).
-- Volume is separate from mute: 40% still plays, mute silences all.
local VOLUME_STEPS: { number } = { 1, 0.7, 0.4 }

local function cycleVolume(getter: string, setter: string)
	local sound = getSoundController()
	if not sound then
		return
	end
	pcall(function()
		local get = sound[getter]
		local set = sound[setter]
		if not get or not set then
			return
		end
		local current = get()
		local nextLevel = VOLUME_STEPS[1]
		for i, step in VOLUME_STEPS do
			if math.abs(current - step) < 0.01 then
				nextLevel = VOLUME_STEPS[(i % #VOLUME_STEPS) + 1]
				break
			end
		end
		set(nextLevel)
	end)
end

local function refreshVolumeButton()
	if not volumeButton then
		return
	end
	local sound = getSoundController()
	local level = 1
	if sound and sound.GetVolume then
		local ok, value = pcall(function()
			return sound.GetVolume()
		end)
		if ok and typeof(value) == "number" then
			level = value
		end
	end
	volumeButton.Text = "MASTER: " .. tostring(math.floor(level * 100 + 0.5)) .. "%"
end

-- v1.1 E: three steppers — Master (all sound), SFX (effects), Music
-- (stored for the future music system; scales nothing audible yet).
local function refreshSFXButton()
	if not sfxButton then
		return
	end
	local sound = getSoundController()
	local level = 1
	if sound and sound.GetSFXVolume then
		local ok, value = pcall(function()
			return sound.GetSFXVolume()
		end)
		if ok and typeof(value) == "number" then
			level = value
		end
	end
	sfxButton.Text = "SFX: " .. tostring(math.floor(level * 100 + 0.5)) .. "%"
end

local function refreshMusicButton()
	if not musicButton then
		return
	end
	local sound = getSoundController()
	local level = 1
	if sound and sound.GetMusicVolume then
		local ok, value = pcall(function()
			return sound.GetMusicVolume()
		end)
		if ok and typeof(value) == "number" then
			level = value
		end
	end
	musicButton.Text = "MUSIC: " .. tostring(math.floor(level * 100 + 0.5)) .. "%"
end

local function refreshAllVolumeButtons()
	refreshVolumeButton()
	refreshSFXButton()
	refreshMusicButton()
end

local function setSettingsButtonsVisible(visible: boolean)
	if muteButton then
		muteButton.Visible = visible
	end
	if volumeButton then
		volumeButton.Visible = visible
	end
	if sfxButton then
		sfxButton.Visible = visible
	end
	if musicButton then
		musicButton.Visible = visible
	end
end

-- Starter preview line, from Config.StarterCharacterId + the catalogue
-- display name — never a hardcoded character name or key.
local function getStarterPreviewText(): string
	local key = getBinds().Brainrots or "C"
	local fallback = "Your Brainrot: Wobble Waffleton (free starter — press " .. key .. " in-game to switch)"
	local ok, text = pcall(function()
		local config = require(ReplicatedStorage:WaitForChild("Config", 10))
		local starterId = config.StarterCharacterId or "wobble_waffleton"
		local name = starterId
		local ok2, chars = pcall(function()
			return require(ReplicatedStorage:WaitForChild("Characters", 10))
		end)
		if ok2 and chars and chars.GetById then
			local def = chars.GetById(starterId)
			if def then
				name = def.DisplayName or def.Name or starterId
			end
		end
		return "Your Brainrot: " .. tostring(name) .. " (free starter — press " .. key .. " in-game to switch)"
	end)
	if ok and typeof(text) == "string" and text ~= "" then
		return text
	end
	return fallback
end

local function build(): ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MainMenu"
	screenGui.DisplayOrder = 100
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false

	-- Dimmed backdrop.
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(12, 10, 28)
	backdrop.BackgroundTransparency = 0.25
	backdrop.BorderSizePixel = 0
	backdrop.Parent = screenGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.06, 0)
	title.Size = UDim2.new(0.9, 0, 0.13, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.Text = "GLITCH TIDE"
	title.TextColor3 = Color3.fromRGB(190, 90, 255)
	title.TextStrokeTransparency = 0.1
	title.TextStrokeColor3 = Color3.fromRGB(20, 0, 40)
	title.Parent = screenGui

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.new(0.5, 0, 0.19, 0)
	subtitle.Size = UDim2.new(0.85, 0, 0.05, 0)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamBold
	subtitle.TextScaled = true
	subtitle.Text = "BRAINROT HEIST: THE MEMEVERSE"
	subtitle.TextColor3 = Color3.fromRGB(255, 215, 0)
	subtitle.Parent = screenGui

	local tagline = Instance.new("TextLabel")
	tagline.Name = "Tagline"
	tagline.AnchorPoint = Vector2.new(0.5, 0)
	tagline.Position = UDim2.new(0.5, 0, 0.245, 0)
	tagline.Size = UDim2.new(0.9, 0, 0.04, 0)
	tagline.BackgroundTransparency = 1
	tagline.Font = Enum.Font.Gotham
	tagline.TextScaled = true
	tagline.Text = "COLLECT THE CHAOS. BUILD YOUR EMPIRE. SURVIVE THE TIDE."
	tagline.TextColor3 = Color3.fromRGB(255, 255, 255)
	tagline.Parent = screenGui

	-- Two-column menu (v1.1 E): left column is the classic menu,
	-- right column opens the new Wave 3 panels directly. On touch the
	-- columns move outward and the buttons get wider.
	local isTouch = UserInputService.TouchEnabled
	local function menuButton(name: string, text: string, bg: Color3, col: number, row: number): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AnchorPoint = Vector2.new(0.5, 0)
		local x = if col == 1 then 0.32 else 0.68
		if isTouch then
			x = if col == 1 then 0.25 else 0.75
		end
		btn.Position = UDim2.new(x, 0, 0.31 + (row - 1) * 0.075, 0)
		btn.Size = UDim2.new(if isTouch then 0.44 else 0.28, 0, 0.06, 0)
		btn.Text = text
		styleButton(btn, bg)
		btn.Parent = screenGui
		return btn
	end

	local playButton = menuButton("PlayButton", "▶  PLAY", Color3.fromRGB(60, 200, 90), 1, 1)
	collectionButton = menuButton("CollectionButton", "📖  COLLECTION", Color3.fromRGB(190, 90, 200), 1, 2)
	local settingsButton = menuButton("SettingsButton", "⚙  SETTINGS", Color3.fromRGB(90, 90, 110), 1, 3)
	local howButton = menuButton("HowToPlayButton", "HOW TO PLAY", Color3.fromRGB(90, 90, 200), 1, 4)
	local objectivesButton = menuButton("ObjectivesButton", "📜  OBJECTIVES", Color3.fromRGB(200, 150, 30), 1, 5)
	local labButton = menuButton("LabButton", "🧪  MUTATION LAB", Color3.fromRGB(90, 70, 160), 2, 1)
	local expeditionButton = menuButton("ExpeditionButton", "🧭  EXPEDITIONS", Color3.fromRGB(60, 120, 220), 2, 2)
	local territoryButton = menuButton("TerritoryButton", "🏴  TERRITORY", Color3.fromRGB(200, 120, 30), 2, 3)
	local worldsButton = menuButton("WorldsButton", "🌍  WORLDS", Color3.fromRGB(90, 160, 90), 2, 4)
	local achievementsButton = menuButton("AchievementsButton", "🏆  ACHIEVEMENTS", Color3.fromRGB(200, 170, 30), 2, 5)

	-- Shared info panel, hidden until a button opens it.
	infoPanel = Instance.new("Frame")
	infoPanel.Name = "InfoPanel"
	infoPanel.AnchorPoint = Vector2.new(0.5, 0)
	infoPanel.Position = UDim2.new(0.5, 0, 0.68, 0)
	infoPanel.Size = UDim2.new(0.6, 0, 0.26, 0)
	infoPanel.BackgroundColor3 = Color3.fromRGB(24, 20, 48)
	infoPanel.BackgroundTransparency = 0.1
	infoPanel.BorderSizePixel = 0
	infoPanel.Visible = false
	infoPanel.Parent = screenGui
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 12)
	panelCorner.Parent = infoPanel

	infoTitle = Instance.new("TextLabel")
	infoTitle.Name = "InfoTitle"
	infoTitle.Size = UDim2.new(1, -20, 0, 24)
	infoTitle.Position = UDim2.new(0, 10, 0, 8)
	infoTitle.BackgroundTransparency = 1
	infoTitle.Font = Enum.Font.GothamBold
	infoTitle.TextSize = 16
	infoTitle.TextXAlignment = Enum.TextXAlignment.Left
	infoTitle.TextColor3 = Color3.fromRGB(255, 215, 0)
	infoTitle.Text = ""
	infoTitle.Parent = infoPanel

	-- The info body is a scrolling frame: the collection list (27
	-- Brainrots) is far taller than this panel, and the old fixed
	-- TextLabel clipped it with no way to read past the fold.
	infoScroll = Instance.new("ScrollingFrame")
	infoScroll.Name = "InfoScroll"
	infoScroll.Size = UDim2.new(1, -20, 1, -128)
	infoScroll.Position = UDim2.new(0, 10, 0, 36)
	infoScroll.BackgroundTransparency = 1
	infoScroll.BorderSizePixel = 0
	infoScroll.ScrollBarThickness = 4
	infoScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	infoScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	infoScroll.Parent = infoPanel

	infoBody = Instance.new("TextLabel")
	infoBody.Name = "InfoBody"
	infoBody.Size = UDim2.new(1, 0, 0, 0)
	infoBody.AutomaticSize = Enum.AutomaticSize.Y
	infoBody.BackgroundTransparency = 1
	infoBody.Font = Enum.Font.Gotham
	infoBody.TextSize = 14
	infoBody.TextXAlignment = Enum.TextXAlignment.Left
	infoBody.TextYAlignment = Enum.TextYAlignment.Top
	infoBody.TextWrapped = true
	infoBody.TextColor3 = Color3.fromRGB(240, 240, 240)
	infoBody.Text = ""
	infoBody.Parent = infoScroll

	-- Settings live inside the info panel: the mute button toggles
	-- SoundController for real, and three steppers cycle Master / SFX /
	-- Music volumes (v1.1 E). Two rows, half-width each.
	muteButton = Instance.new("TextButton")
	muteButton.Name = "MuteButton"
	muteButton.Size = UDim2.new(0.5, -15, 0, 34)
	muteButton.Position = UDim2.new(0, 10, 1, -44)
	muteButton.Font = Enum.Font.GothamBold
	muteButton.TextSize = 13
	muteButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	muteButton.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
	muteButton.BorderSizePixel = 0
	muteButton.Visible = false
	muteButton.Parent = infoPanel
	local muteCorner = Instance.new("UICorner")
	muteCorner.CornerRadius = UDim.new(0, 8)
	muteCorner.Parent = muteButton
	muteButton.MouseButton1Click:Connect(function()
		local sound = getSoundController()
		if sound and sound.ToggleMute then
			pcall(function()
				sound.ToggleMute()
			end)
		end
		refreshMuteButton()
	end)

	volumeButton = Instance.new("TextButton")
	volumeButton.Name = "VolumeButton"
	volumeButton.Size = UDim2.new(0.5, -15, 0, 34)
	volumeButton.Position = UDim2.new(0.5, 5, 1, -44)
	volumeButton.Font = Enum.Font.GothamBold
	volumeButton.TextSize = 13
	volumeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	volumeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
	volumeButton.BorderSizePixel = 0
	volumeButton.Visible = false
	volumeButton.Parent = infoPanel
	local volumeCorner = Instance.new("UICorner")
	volumeCorner.CornerRadius = UDim.new(0, 8)
	volumeCorner.Parent = volumeButton
	volumeButton.MouseButton1Click:Connect(function()
		cycleVolume("GetVolume", "SetVolume")
		refreshVolumeButton()
	end)

	sfxButton = Instance.new("TextButton")
	sfxButton.Name = "SFXButton"
	sfxButton.Size = UDim2.new(0.5, -15, 0, 34)
	sfxButton.Position = UDim2.new(0, 10, 1, -84)
	sfxButton.Font = Enum.Font.GothamBold
	sfxButton.TextSize = 13
	sfxButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	sfxButton.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
	sfxButton.BorderSizePixel = 0
	sfxButton.Visible = false
	sfxButton.Parent = infoPanel
	local sfxCorner = Instance.new("UICorner")
	sfxCorner.CornerRadius = UDim.new(0, 8)
	sfxCorner.Parent = sfxButton
	sfxButton.MouseButton1Click:Connect(function()
		cycleVolume("GetSFXVolume", "SetSFXVolume")
		refreshSFXButton()
	end)

	musicButton = Instance.new("TextButton")
	musicButton.Name = "MusicButton"
	musicButton.Size = UDim2.new(0.5, -15, 0, 34)
	musicButton.Position = UDim2.new(0.5, 5, 1, -84)
	musicButton.Font = Enum.Font.GothamBold
	musicButton.TextSize = 13
	musicButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	musicButton.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
	musicButton.BorderSizePixel = 0
	musicButton.Visible = false
	musicButton.Parent = infoPanel
	local musicCorner = Instance.new("UICorner")
	musicCorner.CornerRadius = UDim.new(0, 8)
	musicCorner.Parent = musicButton
	musicButton.MouseButton1Click:Connect(function()
		cycleVolume("GetMusicVolume", "SetMusicVolume")
		refreshMusicButton()
	end)

	local preview = Instance.new("TextLabel")
	preview.Name = "CharacterPreview"
	preview.AnchorPoint = Vector2.new(0.5, 0)
	preview.Position = UDim2.new(0.5, 0, 0.95, 0)
	preview.Size = UDim2.new(0.7, 0, 0.04, 0)
	preview.BackgroundTransparency = 1
	preview.Font = Enum.Font.GothamBold
	preview.TextScaled = true
	preview.Text = getStarterPreviewText()
	preview.TextColor3 = Color3.fromRGB(200, 220, 255)
	preview.Parent = screenGui

	local credits = Instance.new("TextLabel")
	credits.Name = "Credits"
	credits.AnchorPoint = Vector2.new(0.5, 1)
	credits.Position = UDim2.new(0.5, 0, 0.99, 0)
	credits.Size = UDim2.new(0.9, 0, 0.03, 0)
	credits.BackgroundTransparency = 1
	credits.Font = Enum.Font.Gotham
	credits.TextScaled = true
	credits.Text = "Original fan-inspired game — no assets copied"
	credits.TextColor3 = Color3.fromRGB(170, 170, 190)
	credits.Parent = screenGui

	-- PLAY: close the menu + ready poof at spawn, played locally.
	-- The old code fired SpawnEffect TO the server, but no server
	-- service listens for SpawnEffect from clients — it is a
	-- server-to-client broadcast (EffectsController renders it). The
	-- poof therefore never happened. EffectsController.Poof does the
	-- same effect on this client, directly.
	playButton.MouseButton1Click:Connect(function()
		MainMenu.Hide()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			pcall(function()
				local controllers = getControllersFolder()
				local mod = controllers and controllers:FindFirstChild("EffectsController")
				if mod then
					local fx = require(mod)
					if fx and fx.Poof then
						fx.Poof(root.Position)
					end
				end
			end)
		end
	end)

	-- COLLECTION: real controller panel when it exists, else the
	-- in-menu catalogue panel (real content, not a dead button).
	collectionButton.MouseButton1Click:Connect(function()
		local opened = false
		pcall(function()
			local controllers = getControllersFolder()
			local mod = controllers and controllers:FindFirstChild("CollectionController")
			if mod then
				local collection = require(mod)
				if collection and collection.Open then
					collection.Open()
					opened = true
				end
			end
		end)
		if not opened then
			setSettingsButtonsVisible(false)
			showInfo("📖  BRAINROT COLLECTION", buildCollectionText())
		end
	end)

	-- SETTINGS: mute toggle (real) + Master / SFX / Music steppers
	-- (real) + controls recap.
	settingsButton.MouseButton1Click:Connect(function()
		if infoPanel and infoPanel.Visible and infoTitle and infoTitle.Text == "⚙  SETTINGS" then
			hideInfo()
			setSettingsButtonsVisible(false)
			return
		end
		showInfo("⚙  SETTINGS", buildControlsText())
		setSettingsButtonsVisible(true)
		refreshMuteButton()
		refreshAllVolumeButtons()
	end)

	-- HOW TO PLAY: the core loop + keybinds.
	howButton.MouseButton1Click:Connect(function()
		if infoPanel and infoPanel.Visible and infoTitle and infoTitle.Text == "HOW TO PLAY" then
			hideInfo()
			setSettingsButtonsVisible(false)
			return
		end
		setSettingsButtonsVisible(false)
		showInfo("HOW TO PLAY", buildHowToPlayText())
	end)

	-- OBJECTIVES (v1.1 E): the starter quest chain — live top quest
	-- when QuestController can supply one, else the static steps.
	objectivesButton.MouseButton1Click:Connect(function()
		if infoPanel and infoPanel.Visible and infoTitle and infoTitle.Text == "📜  OBJECTIVES" then
			hideInfo()
			setSettingsButtonsVisible(false)
			return
		end
		setSettingsButtonsVisible(false)
		showInfo("📜  OBJECTIVES", buildObjectivesText())
	end)

	-- New-panel shortcuts (v1.1 E): open the Wave 3 panels directly.
	-- If a controller is absent, show the info panel with a plain
	-- explanation instead of a dead button.
	local function panelShortcut(moduleName: string, title: string, missing: string)
		return function()
			if not openController(moduleName) then
				setSettingsButtonsVisible(false)
				showInfo(title, missing)
			end
		end
	end
	labButton.MouseButton1Click:Connect(panelShortcut("LaboratoryController", "🧪  MUTATION LAB", "The Mutation Lab panel is not loaded yet. It opens from the Shop (B) once the client finishes loading."))
	expeditionButton.MouseButton1Click:Connect(panelShortcut("ExpeditionController", "🧭  EXPEDITIONS", "The Expeditions panel is not loaded yet. It opens from the HUD menu once the client finishes loading."))
	territoryButton.MouseButton1Click:Connect(panelShortcut("TerritoryController", "🏴  TERRITORY", "The Territories panel is not loaded yet. It opens from the HUD menu once the client finishes loading."))
	worldsButton.MouseButton1Click:Connect(panelShortcut("DimensionController", "🌍  WORLDS", "The Worlds panel is not loaded yet. It opens from the HUD menu once the client finishes loading."))
	achievementsButton.MouseButton1Click:Connect(panelShortcut("AchievementController", "🏆  ACHIEVEMENTS", "The Achievements panel is not loaded yet. It opens from the HUD menu once the client finishes loading."))

	-- Title pop-in.
	task.spawn(function()
		title.TextTransparency = 1
		local tween = TweenService:Create(title, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextTransparency = 0 })
		tween:Play()
	end)

	return screenGui
end

function MainMenu.Show()
	if not gui then
		gui = build()
		gui.Parent = player:WaitForChild("PlayerGui")
	end
	gui.Enabled = true
	visible = true
	refreshMuteButton()
	refreshAllVolumeButtons()
end

function MainMenu.Hide()
	if gui then
		gui.Enabled = false
	end
	visible = false
	hideInfo()
end

function MainMenu.IsVisible(): boolean
	return visible
end

function MainMenu.SetCharacterPreview(text: string)
	if gui then
		local preview = gui:FindFirstChild("CharacterPreview") :: TextLabel?
		if preview then
			preview.Text = text
		end
	end
end

function MainMenu.Init()
	MainMenu.Show()
end

return MainMenu
