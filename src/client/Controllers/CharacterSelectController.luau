--!strict
-- CharacterSelectController.luau
-- Brainrot picker for GLITCH TIDE. Grid of every Brainrot from the shared
-- Characters module (client-readable, so the grid works even before the
-- server answers), merged with the server's owned list from RequestShop
-- (RemoteFunction) when it replies. Owned Brainrots get an Equip button
-- (fires SelectCharacter, server-validated); locked ones get a Buy button
-- (fires BuyCharacter, server-validated). Morph feedback comes from the
-- server: a CharacterSwitchFailed payload on PlayerStats, or the
-- character respawning with the new morph.
-- Toggle: C key, or the "BRAINROTS" button on the HUD menu bar.
-- Works with a partial server list: any character missing from the
-- server reply is shown from local data as "locked" until proven owned.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local CharacterSelectController = {}

local RarityColors = require(script.Parent.RarityColors)

local Characters: any = nil
local Powers: any = nil
pcall(function()
	Characters = require(ReplicatedStorage:WaitForChild("Characters", 10))
end)
pcall(function()
	Powers = require(ReplicatedStorage:WaitForChild("Powers", 10))
end)

local RemotesModule: any = nil
pcall(function()
	RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes", 10))
end)

local Config: any = nil
pcall(function()
	Config = require(ReplicatedStorage:WaitForChild("Config", 10))
end)

-- The free starter, from Config — never a hardcoded id.
local function getStarterId(): string
	if Config and type(Config.StarterCharacterId) == "string" and Config.StarterCharacterId ~= "" then
		return Config.StarterCharacterId
	end
	return "wobble_waffleton"
end

local gui: ScreenGui? = nil
local grid: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local coinsLabel: TextLabel? = nil
local isOpen = false
local owned: { [string]: boolean } = {}
local selectedId: string = getStarterId()
local knownCoins: number = 0
local pendingEquipId: string? = nil
local pendingEquipAt: number = 0

local function getRemotesFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder then
		return folder :: Folder
	end
	local ok, found = pcall(function()
		return ReplicatedStorage:WaitForChild("Remotes", 5)
	end)
	if ok and found then
		return found :: Folder
	end
	return nil
end

local function getRemote(name: string): Instance?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end
	return folder:FindFirstChild(name)
end

local function remoteName(key: string, fallback: string): string
	if RemotesModule and RemotesModule.Names and RemotesModule.Names[key] then
		return RemotesModule.Names[key]
	end
	return fallback
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function makeLabel(parent: Instance, text: string, size: number, color: Color3, bold: boolean?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = true
	label.Parent = parent
	return label
end

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function refreshCoinsLabel()
	if coinsLabel then
		coinsLabel.Text = "🪙 " .. tostring(math.floor(knownCoins + 0.5))
	end
end

-- Ask the server for the shop snapshot (owned flags + coins). The
-- RemoteFunction reply is the only source of truth for ownership; the
-- local Characters list is only the catalogue.
local function refreshFromServer()
	local shopFn = getRemote(remoteName("RequestShop", "RequestShop"))
	if shopFn and shopFn:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (shopFn :: RemoteFunction):InvokeServer()
			end)
			if not ok or typeof(result) ~= "table" then
				setStatus("Server shop list unavailable — showing catalogue. Ownership may be out of date.", true)
				return
			end
			if typeof(result.Coins) == "number" then
				knownCoins = result.Coins
				refreshCoinsLabel()
			end
			local list = result.Characters or result.characters
			if typeof(list) == "table" then
				for _, entry in list do
					if typeof(entry) == "table" and typeof(entry.Id) == "string" then
						owned[entry.Id] = entry.Owned == true
					end
				end
				CharacterSelectController.Rebuild()
			end
		end)
	end
end

local function onEquipPressed(def: any)
	local selectRemote = getRemote(remoteName("SelectCharacter", "SelectCharacter"))
	if not selectRemote or not selectRemote:IsA("RemoteEvent") then
		setStatus("SelectCharacter remote is not available yet.", true)
		return
	end
	pendingEquipId = def.Id
	pendingEquipAt = os.clock()
	setStatus("Equipping " .. tostring(def.DisplayName or def.Name) .. "…")
	pcall(function()
		(selectRemote :: RemoteEvent):FireServer(def.Id)
	end)
	-- If the server says nothing in 3s, assume it applied: CharacterService
	-- only replies on failure (CharacterSwitchFailed via PlayerStats).
	task.delay(3, function()
		if pendingEquipId == def.Id and os.clock() - pendingEquipAt >= 2.9 then
			selectedId = def.Id
			pendingEquipId = nil
			setStatus("Equipped " .. tostring(def.DisplayName or def.Name) .. "!")
			CharacterSelectController.Rebuild()
			local ability: any = nil
			pcall(function()
				local folder = script.Parent
				local mod = folder:FindFirstChild("AbilityController")
				if mod then
					ability = require(mod)
				end
			end)
			if ability and ability.SetCharacter then
				ability.SetCharacter(def.Id)
			end
			pcall(function()
				-- MainMenu lives in StarterGui (cloned into PlayerGui),
				-- not beside the Controllers folder.
				local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
				local menuMod = playerGui and playerGui:FindFirstChild("MainMenu")
				if menuMod then
					local menu = require(menuMod)
					if menu.SetCharacterPreview then
						menu.SetCharacterPreview("Your Brainrot: " .. tostring(def.DisplayName or def.Name))
					end
				end
			end)
		end
	end)
end

local function onBuyPressed(def: any)
	local buyRemote = getRemote(remoteName("BuyCharacter", "BuyCharacter"))
	if not buyRemote or not buyRemote:IsA("RemoteEvent") then
		setStatus("BuyCharacter remote is not available yet.", true)
		return
	end
	setStatus("Buying " .. tostring(def.DisplayName or def.Name) .. " — waiting for the server…")
	pcall(function()
		(buyRemote :: RemoteEvent):FireServer(def.Id)
	end)
	-- Ownership is confirmed by the server: a fresh RequestShop reply (or a
	-- PlayerStats push) flips the card to owned. Refresh shortly after.
	task.delay(1.5, refreshFromServer)
end

local function buildCard(def: any): Frame
	local card = Instance.new("Frame")
	card.Name = "Card_" .. tostring(def.Id)
	card.Size = UDim2.new(0, 168, 0, 196)
	card.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	card.BorderSizePixel = 0
	corner(card, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = RarityColors.Get(def.Rarity)
	stroke.Thickness = 2
	stroke.Parent = card

	-- Colour swatch: the Brainrot's body colour, no asset needed.
	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.new(1, -16, 0, 56)
	swatch.Position = UDim2.new(0, 8, 0, 8)
	swatch.BackgroundColor3 = def.Color or Color3.fromRGB(120, 120, 120)
	swatch.BorderSizePixel = 0
	corner(swatch, 8)
	swatch.Parent = card
	local swatchLabel = makeLabel(swatch, "🧠", 28, Color3.fromRGB(255, 255, 255), true)
	swatchLabel.Size = UDim2.new(1, 0, 1, 0)
	swatchLabel.TextXAlignment = Enum.TextXAlignment.Center
	swatchLabel.TextYAlignment = Enum.TextYAlignment.Center

	local rarityChip = Instance.new("TextLabel")
	rarityChip.Size = UDim2.new(0, 84, 0, 18)
	rarityChip.Position = UDim2.new(0, 8, 0, 70)
	rarityChip.BackgroundColor3 = RarityColors.Get(def.Rarity)
	rarityChip.Text = string.upper(tostring(def.Rarity or "Common"))
	rarityChip.Font = Enum.Font.GothamBold
	rarityChip.TextSize = 10
	rarityChip.TextColor3 = RarityColors.GetTextColor(def.Rarity)
	rarityChip.Parent = card
	corner(rarityChip, 5)
	RarityColors.Apply(rarityChip, def.Rarity)

	local nameLabel = makeLabel(card, tostring(def.DisplayName or def.Name), 13, Color3.fromRGB(255, 255, 255), true)
	nameLabel.Size = UDim2.new(1, -16, 0, 20)
	nameLabel.Position = UDim2.new(0, 8, 0, 92)

	local statsLabel = makeLabel(
		card,
		string.format("💰 %d  •  +%d/s  •  ❤ %d", def.Cost or 0, def.IncomePerSec or 0, def.Health or 0),
		11,
		Color3.fromRGB(200, 210, 230),
		false
	)
	statsLabel.Size = UDim2.new(1, -16, 0, 16)
	statsLabel.Position = UDim2.new(0, 8, 0, 114)

	local traitLabel = makeLabel(card, "Trait: " .. tostring(def.DefenseTrait or "—"), 11, Color3.fromRGB(170, 190, 220), false)
	traitLabel.Size = UDim2.new(1, -16, 0, 16)
	traitLabel.Position = UDim2.new(0, 8, 0, 132)

	local isOwned = owned[def.Id] == true or (def.Cost or 0) == 0
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -16, 0, 30)
	button.Position = UDim2.new(0, 8, 0, 156)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.BorderSizePixel = 0
	corner(button, 8)
	button.Parent = card
	if isOwned then
		if selectedId == def.Id then
			button.Text = "✓ EQUIPPED"
			button.BackgroundColor3 = Color3.fromRGB(40, 160, 90)
		else
			button.Text = "EQUIP"
			button.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
		end
		button.MouseButton1Click:Connect(function()
			onEquipPressed(def)
		end)
	else
		button.Text = "BUY  🪙 " .. tostring(def.Cost or 0)
		button.BackgroundColor3 = Color3.fromRGB(200, 150, 30)
		button.MouseButton1Click:Connect(function()
			onBuyPressed(def)
		end)
	end
	return card
end

function CharacterSelectController.Rebuild()
	local frame = grid
	if not frame then
		return
	end
	for _, child in frame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local defs: { any } = {}
	if Characters and Characters.GetSortedByCost then
		local ok, list = pcall(function()
			return Characters.GetSortedByCost()
		end)
		if ok and typeof(list) == "table" then
			defs = list
		end
	end
	if #defs == 0 then
		setStatus("No Brainrot catalogue available yet.", true)
		return
	end
	-- Rarity order as secondary sort is already cost order; keep it.
	for _, def in defs do
		buildCard(def).Parent = frame
	end
	local layout = frame:FindFirstChildOfClass("UIGridLayout")
	if layout then
		frame.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 12)
	end
end

function CharacterSelectController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	refreshFromServer()
end

function CharacterSelectController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function CharacterSelectController.Toggle()
	if isOpen then
		CharacterSelectController.Close()
	else
		CharacterSelectController.Open()
	end
end

function CharacterSelectController.IsOpen(): boolean
	return isOpen
end

function CharacterSelectController.GetSelectedId(): string
	return selectedId
end

function CharacterSelectController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "CharacterSelect"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 600, 0, 480)
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 36)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(190, 90, 255)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = makeLabel(panel, "CHOOSE YOUR BRAINROT", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(1, -120, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	coinsLabel = makeLabel(panel, "🪙 0", 16, Color3.fromRGB(255, 215, 0), true)
	coinsLabel.Size = UDim2.new(0, 100, 0, 24)
	coinsLabel.Position = UDim2.new(1, -170, 0, 12)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, 36, 0, 30)
	closeBtn.Position = UDim2.new(1, -48, 0, 10)
	closeBtn.Text = "✕"
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 16
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	closeBtn.BorderSizePixel = 0
	corner(closeBtn, 8)
	closeBtn.Parent = panel
	closeBtn.MouseButton1Click:Connect(function()
		CharacterSelectController.Close()
	end)

	statusLabel = makeLabel(panel, "Pick a Brainrot to morph into. Locked ones can be bought with coins.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.Size = UDim2.new(1, -24, 1, -76)
	grid.Position = UDim2.new(0, 12, 0, 66)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.Parent = panel
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0, 168, 0, 196)
	gridLayout.CellPadding = UDim2.new(0, 10, 0, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingTop = UDim.new(0, 6)
	padding.Parent = grid

	-- Small screens: shrink the panel so it still fits.
	if UserInputService.TouchEnabled then
		panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	end

	CharacterSelectController.Rebuild()
	refreshFromServer()

	-- Server failure replies for equip attempts.
	local statsRemote = getRemote(remoteName("PlayerStats", "PlayerStats"))
	if statsRemote and statsRemote:IsA("RemoteEvent") then
		(statsRemote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
			if typeof(payload) ~= "table" then
				return
			end
			if payload.type == "CharacterSwitchFailed" then
				pendingEquipId = nil
				setStatus("Could not equip: " .. tostring(payload.reason or "server refused"), true)
			elseif payload.Coins ~= nil then
				knownCoins = payload.Coins
				refreshCoinsLabel()
			end
		end)
	elseif statsRemote and statsRemote:IsA("RemoteFunction") then
		task.spawn(function()
			task.wait(1)
			pcall(function()
				local data = (statsRemote :: RemoteFunction):InvokeServer("GetStats")
				if typeof(data) == "table" and typeof(data.Coins) == "number" then
					knownCoins = data.Coins
					refreshCoinsLabel()
				end
			end)
		end)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.C then
			CharacterSelectController.Toggle()
		end
	end)

	print("[GlitchTide] CharacterSelectController ready")
end

return CharacterSelectController
