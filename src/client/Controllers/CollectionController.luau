--!strict
-- CollectionController.luau
-- Brainrot encyclopedia for GLITCH TIDE. Every Brainrot in the shared
-- Characters catalogue gets a card. Discovered = full card (colour
-- swatch, name, rarity, income, trait, description). Undiscovered =
-- silhouette "???" card with a hint (rarity + cost + income band).
-- Discovery is real data, not guesswork: a Brainrot counts as discovered
-- when the server's collection list says so (RequestCollection returns
-- {Discovered, Total, Owned, ByRarity} — ProgressionService.GetCollection),
-- with the RequestShop Owned flags as a fallback merge. Without a server
-- reply, only the equipped starter is discovered and the rest are
-- silhouettes.
-- Milestone text at the top shows X / 27 discovered (the roster grew
-- 18 → 27 in v1.1 Wave 1). Toggle: L key, or the "COLLECTION" button
-- on the HUD menu bar / main menu.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local CollectionController = {}

local RarityColors = require(script.Parent.RarityColors)

local Characters: any = nil
pcall(function()
	Characters = require(ReplicatedStorage:WaitForChild("Characters", 10))
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
local milestoneLabel: TextLabel? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local discovered: { [string]: boolean } = {}
local totalCount: number = 0

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

local function discoveredCount(): number
	local count = 0
	for _, v in discovered do
		if v then
			count += 1
		end
	end
	return count
end

function CollectionController.MarkDiscovered(characterId: string)
	if typeof(characterId) == "string" and characterId ~= "" then
		discovered[characterId] = true
		CollectionController.Rebuild()
	end
end

function CollectionController.GetDiscoveredCount(): (number, number)
	return discoveredCount(), totalCount
end

function CollectionController.Rebuild()
	if not grid then
		return
	end
	for _, child in grid:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local defs: { any } = {}
	if Characters and Characters.GetAll then
		local ok, list = pcall(function()
			return Characters.GetAll()
		end)
		if ok and typeof(list) == "table" then
			defs = list
		end
	end
	totalCount = #defs
	if milestoneLabel then
		milestoneLabel.Text = string.format("Discovered: %d / %d", discoveredCount(), totalCount)
	end
	if #defs == 0 then
		if statusLabel then
			statusLabel.Text = "Brainrot catalogue is not available yet."
		end
		return
	end
	for _, def in defs do
		local found = discovered[def.Id] == true
		local card = Instance.new("Frame")
		card.Name = "Card_" .. tostring(def.Id)
		card.Size = UDim2.new(0, 168, 0, 196)
		card.BackgroundColor3 = if found then Color3.fromRGB(28, 26, 48) else Color3.fromRGB(16, 16, 24)
		card.BorderSizePixel = 0
		corner(card, 10)
		local stroke = Instance.new("UIStroke")
		stroke.Color = if found then RarityColors.Get(def.Rarity) else Color3.fromRGB(70, 70, 80)
		stroke.Thickness = 2
		stroke.Parent = card

		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.new(1, -16, 0, 56)
		swatch.Position = UDim2.new(0, 8, 0, 8)
		swatch.BackgroundColor3 = if found then (def.Color or Color3.fromRGB(120, 120, 120)) else Color3.fromRGB(35, 35, 45)
		swatch.BorderSizePixel = 0
		corner(swatch, 8)
		swatch.Parent = card
		local icon = makeLabel(swatch, if found then "🧠" else "?", 28, Color3.fromRGB(255, 255, 255), true)
		icon.Size = UDim2.new(1, 0, 1, 0)
		icon.TextXAlignment = Enum.TextXAlignment.Center
		icon.TextYAlignment = Enum.TextYAlignment.Center

		if found then
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
				string.format("+%d/s  •  ❤ %d  •  %s", def.IncomePerSec or 0, def.Health or 0, tostring(def.DefenseTrait or "")),
				11,
				Color3.fromRGB(200, 210, 230),
				false
			)
			statsLabel.Size = UDim2.new(1, -16, 0, 16)
			statsLabel.Position = UDim2.new(0, 8, 0, 114)
			local descLabel = makeLabel(card, tostring(def.Description or ""), 10, Color3.fromRGB(170, 180, 200), false)
			descLabel.Size = UDim2.new(1, -16, 0, 52)
			descLabel.Position = UDim2.new(0, 8, 0, 134)
			descLabel.TextYAlignment = Enum.TextYAlignment.Top
		else
			local unknownLabel = makeLabel(card, "???", 18, Color3.fromRGB(150, 150, 170), true)
			unknownLabel.Size = UDim2.new(1, -16, 0, 24)
			unknownLabel.Position = UDim2.new(0, 8, 0, 90)
			unknownLabel.TextXAlignment = Enum.TextXAlignment.Center
			local hintLabel = makeLabel(
				card,
				"Hint: " .. tostring(def.Rarity or "?") .. "  •  costs 🪙 " .. tostring(def.Cost or "?") .. "  •  earns +" .. tostring(def.IncomePerSec or "?") .. "/s",
				11,
				Color3.fromRGB(150, 160, 180),
				false
			)
			hintLabel.Size = UDim2.new(1, -16, 0, 48)
			hintLabel.Position = UDim2.new(0, 8, 0, 118)
			hintLabel.TextYAlignment = Enum.TextYAlignment.Top
			local howLabel = makeLabel(card, "Own it or equip it to reveal.", 10, Color3.fromRGB(120, 130, 150), false)
			howLabel.Size = UDim2.new(1, -16, 0, 16)
			howLabel.Position = UDim2.new(0, 8, 0, 170)
		end
		card.Parent = grid
	end
	local layout = grid:FindFirstChildOfClass("UIGridLayout")
	if layout then
		grid.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 12)
	end
end

function CollectionController.RefreshFromServer()
	-- The starter Brainrot is free, so it is always discovered.
	discovered[getStarterId()] = true
	pcall(function()
		local mod = script.Parent:FindFirstChild("CharacterSelectController")
		if mod then
			local select = require(mod)
			if select.GetSelectedId then
				discovered[select.GetSelectedId()] = true
			end
		end
	end)
	-- RequestCollection (v1.1 E, audit F1): the server handler existed
	-- (ProgressionService.GetCollection) but NO client ever called it.
	-- It returns {Discovered, Total, Owned, ByRarity}; Discovered is
	-- the authoritative id list. RequestShop Owned flags are merged
	-- as a fallback so a collection reply that lags still shows owned
	-- Brainrots.
	local collectionFn = getRemote(remoteName("RequestCollection", "RequestCollection"))
	if collectionFn and collectionFn:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (collectionFn :: RemoteFunction):InvokeServer()
			end)
			if ok and typeof(result) == "table" then
				local list = result.Discovered or result.discovered
				if typeof(list) == "table" then
					for _, id in list do
						if typeof(id) == "string" then
							discovered[id] = true
						end
					end
				end
				if typeof(result.Total) == "number" and result.Total > 0 then
					totalCount = result.Total
				end
				CollectionController.Rebuild()
			end
		end)
	end
	local shopFn = getRemote(remoteName("RequestShop", "RequestShop"))
	if shopFn and shopFn:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (shopFn :: RemoteFunction):InvokeServer()
			end)
			if ok and typeof(result) == "table" then
				local list = result.Characters or result.characters
				if typeof(list) == "table" then
					for _, entry in list do
						if typeof(entry) == "table" and typeof(entry.Id) == "string" and entry.Owned == true then
							discovered[entry.Id] = true
						end
					end
				end
				CollectionController.Rebuild()
			end
		end)
	end
	CollectionController.Rebuild()
end

function CollectionController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	CollectionController.RefreshFromServer()
end

function CollectionController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function CollectionController.Toggle()
	if isOpen then
		CollectionController.Close()
	else
		CollectionController.Open()
	end
end

function CollectionController.IsOpen(): boolean
	return isOpen
end

function CollectionController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Collection"
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
	pStroke.Color = Color3.fromRGB(255, 110, 200)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = makeLabel(panel, "📖  BRAINROT COLLECTION", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(1, -120, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

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
		CollectionController.Close()
	end)

	milestoneLabel = makeLabel(panel, "Discovered: 0 / 0", 13, Color3.fromRGB(120, 220, 255), true)
	milestoneLabel.Size = UDim2.new(1, -32, 0, 18)
	milestoneLabel.Position = UDim2.new(0, 16, 0, 44)

	statusLabel = makeLabel(panel, "Own or equip a Brainrot to reveal its full card.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 62)
	-- Shift the grid down to clear the two header lines.
	grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.Size = UDim2.new(1, -24, 1, -96)
	grid.Position = UDim2.new(0, 12, 0, 86)
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

	if UserInputService.TouchEnabled then
		panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.L then
			CollectionController.Toggle()
		end
	end)

	CollectionController.RefreshFromServer()
	print("[GlitchTide] CollectionController ready")
end

return CollectionController
