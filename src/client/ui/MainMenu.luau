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
--               a controls recap
--   HOW TO PLAY shows the core loop steps + full keybind list
-- If a target controller is absent, the button opens a simple in-menu
-- panel with real content (controls list / credits) — never a dead end.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
	volumeButton.Text = "VOLUME: " .. tostring(math.floor(level * 100 + 0.5)) .. "% (tap to change)"
end

local function setSettingsButtonsVisible(visible: boolean)
	if muteButton then
		muteButton.Visible = visible
	end
	if volumeButton then
		volumeButton.Visible = visible
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

	local playButton = Instance.new("TextButton")
	playButton.Name = "PlayButton"
	playButton.AnchorPoint = Vector2.new(0.5, 0)
	playButton.Position = UDim2.new(0.5, 0, 0.31, 0)
	playButton.Size = UDim2.new(0.3, 0, 0.09, 0)
	playButton.Text = "▶  PLAY"
	styleButton(playButton, Color3.fromRGB(60, 200, 90))
	playButton.Parent = screenGui

	collectionButton = Instance.new("TextButton")
	collectionButton.Name = "CollectionButton"
	collectionButton.AnchorPoint = Vector2.new(0.5, 0)
	collectionButton.Position = UDim2.new(0.5, 0, 0.42, 0)
	collectionButton.Size = UDim2.new(0.3, 0, 0.07, 0)
	collectionButton.Text = "📖  COLLECTION"
	styleButton(collectionButton, Color3.fromRGB(190, 90, 200))
	collectionButton.Parent = screenGui

	local settingsButton = Instance.new("TextButton")
	settingsButton.Name = "SettingsButton"
	settingsButton.AnchorPoint = Vector2.new(0.5, 0)
	settingsButton.Position = UDim2.new(0.5, 0, 0.51, 0)
	settingsButton.Size = UDim2.new(0.3, 0, 0.07, 0)
	settingsButton.Text = "⚙  SETTINGS"
	styleButton(settingsButton, Color3.fromRGB(90, 90, 110))
	settingsButton.Parent = screenGui

	local howButton = Instance.new("TextButton")
	howButton.Name = "HowToPlayButton"
	howButton.AnchorPoint = Vector2.new(0.5, 0)
	howButton.Position = UDim2.new(0.5, 0, 0.60, 0)
	howButton.Size = UDim2.new(0.3, 0, 0.07, 0)
	howButton.Text = "HOW TO PLAY"
	styleButton(howButton, Color3.fromRGB(90, 90, 200))
	howButton.Parent = screenGui

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

	-- The info body is a scrolling frame: the collection list (18
	-- Brainrots) is far taller than this panel, and the old fixed
	-- TextLabel clipped it with no way to read past the fold.
	infoScroll = Instance.new("ScrollingFrame")
	infoScroll.Name = "InfoScroll"
	infoScroll.Size = UDim2.new(1, -20, 1, -44)
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
	-- SoundController for real, and the volume button cycles the
	-- master SFX volume. They share the bottom row, half-width each.
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
		local sound = getSoundController()
		if sound and sound.SetVolume and sound.GetVolume then
			pcall(function()
				local current = sound.GetVolume()
				local nextLevel = VOLUME_STEPS[1]
				for i, step in VOLUME_STEPS do
					if math.abs(current - step) < 0.01 then
						nextLevel = VOLUME_STEPS[(i % #VOLUME_STEPS) + 1]
						break
					end
				end
				sound.SetVolume(nextLevel)
			end)
		end
		refreshVolumeButton()
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

	-- SETTINGS: mute toggle (real) + volume cycle (real) + controls recap.
	settingsButton.MouseButton1Click:Connect(function()
		if infoPanel and infoPanel.Visible and infoTitle and infoTitle.Text == "⚙  SETTINGS" then
			hideInfo()
			setSettingsButtonsVisible(false)
			return
		end
		showInfo("⚙  SETTINGS", buildControlsText())
		setSettingsButtonsVisible(true)
		refreshMuteButton()
		refreshVolumeButton()
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
	refreshVolumeButton()
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
