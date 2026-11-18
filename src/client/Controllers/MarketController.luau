--!strict
-- MarketController.luau
-- Conveyor HUD for GLITCH TIDE: the live market strip.
-- Shows the conveyor list from ConveyorUpdate (name / rarity / cost /
-- income / mutation), a next-spawn countdown, and a Buy button per item
-- that fires BuyConveyor. Buying is server-validated: the button shows
-- "Sent…" and the result arrives via the next ConveyorUpdate /
-- PlayerStats push (or a "no reply" note after 5s) — never assumed.
-- Proximity: if the server created ProximityPrompts on conveyor items,
-- their PromptTriggered fires the same buy path. Otherwise the GUI
-- buttons (and the E prompt from InteractionController) are the way in.
-- Toggle: N key, or the "MARKET" button on the HUD menu bar. The strip
-- stays visible while open; the panel is the same content, larger.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local MarketController = {}

local RarityColors = require(script.Parent.RarityColors)

local Characters: any = nil
local Config: any = nil
pcall(function()
	Characters = require(ReplicatedStorage:WaitForChild("Characters", 10))
end)
pcall(function()
	Config = require(ReplicatedStorage:WaitForChild("Config", 10))
end)

local RemotesModule: any = nil
pcall(function()
	RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes", 10))
end)

local gui: ScreenGui? = nil
local listFrame: ScrollingFrame? = nil
local spawnLabel: TextLabel? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local items: { any } = {}
local lastUpdateAt: number = 0
local spawnInterval: number = 8
local pendingBuy: { [string]: number } = {}

if Config and typeof(Config.ConveyorSpawnInterval) == "number" then
	spawnInterval = Config.ConveyorSpawnInterval
end

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

local function itemKey(item: any): string
	if typeof(item.Slot) == "number" then
		return "slot" .. tostring(item.Slot)
	end
	if typeof(item.Index) == "number" then
		return "slot" .. tostring(item.Index)
	end
	return tostring(item.InstanceId or item.Id or item.CharacterId or item.Name or "?")
end

-- The server's conveyor stock is keyed by InstanceId (a GUID per spawned
-- item). itemSnapshot sends {InstanceId, CharacterId, ...} — NO bare Id
-- field. The old code returned CharacterId here, so every BuyConveyor
-- fired with a CharacterId, the server looked it up in _items[guid] and
-- answered "item no longer for sale". Every Market buy failed.
local function itemInstanceId(item: any): string?
	if typeof(item) ~= "table" then
		return nil
	end
	if typeof(item.InstanceId) == "string" and item.InstanceId ~= "" then
		return item.InstanceId
	end
	if typeof(item.Id) == "string" and item.Id ~= "" then
		-- An Id that looks like a GUID is an InstanceId; a catalogue id
		-- (e.g. "turbo_turnip") is not — resolve it below instead.
		if string.find(item.Id, "-") ~= nil then
			return item.Id
		end
	end
	return nil
end

-- Resolve a buy target (which may only carry a CharacterId, e.g. from a
-- ProximityPrompt attribute or an InteractId) to the live conveyor
-- InstanceId, using the current items list. Returns nil when the item
-- is no longer on the belt.
local function resolveInstanceId(item: any): string?
	local direct = itemInstanceId(item)
	if direct then
		return direct
	end
	if typeof(item) ~= "table" then
		return nil
	end
	local charId = item.CharacterId or item.Id
	if typeof(charId) ~= "string" or charId == "" then
		return nil
	end
	for _, live in ipairs(items) do
		if live.CharacterId == charId then
			return itemInstanceId(live)
		end
	end
	return nil
end

local function itemId(item: any): string
	return itemInstanceId(item) or tostring(item.CharacterId or item.Id or item.Name or "")
end

function MarketController.BuyItem(item: any)
	if typeof(item) ~= "table" then
		return
	end
	local remote = getRemote(remoteName("BuyConveyor", "BuyConveyor"))
	if not remote or not remote:IsA("RemoteEvent") then
		setStatus("BuyConveyor remote is not available yet.", true)
		return
	end
	-- The server expects the conveyor InstanceId (GUID), not the
	-- catalogue CharacterId. Resolve it from the live list first; if
	-- the item is gone, say so instead of firing a doomed purchase.
	local instanceId = resolveInstanceId(item)
	if not instanceId then
		setStatus("That Brainrot is no longer on the conveyor — it sold or despawned.", true)
		return
	end
	local key = itemKey(item)
	setStatus("Buying " .. tostring(item.Name or itemId(item)) .. " — waiting for the server…")
	pendingBuy[key] = os.clock()
	pcall(function()
		-- Send ONLY the InstanceId: ConveyorService.BuyItem looks the
		-- item up by InstanceId and re-checks the server-side price,
		-- distance and balance. (The old code also sent a slot index;
		-- the server ignores that second argument.)
		(remote :: RemoteEvent):FireServer(instanceId)
	end)
	task.delay(5, function()
		if pendingBuy[key] and os.clock() - (pendingBuy[key] or 0) >= 4.9 then
			pendingBuy[key] = nil
			setStatus("No reply from the server for that purchase — check your coins.", true)
		end
	end)
end

local function buildRow(item: any): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 56)
	row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	row.BorderSizePixel = 0
	corner(row, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = RarityColors.Get(item.Rarity)
	stroke.Thickness = 2
	stroke.Parent = row

	local mutation = item.Mutation or item.mutation or (item.Glitched and "Glitched" or nil)
	local nameText = tostring(item.Name or itemId(item))
	if mutation then
		nameText ..= "  ✨ " .. tostring(mutation)
	end
	local nameLabel = makeLabel(row, nameText, 14, Color3.fromRGB(255, 255, 255), true)
	nameLabel.Size = UDim2.new(1, -200, 0, 22)
	nameLabel.Position = UDim2.new(0, 12, 0, 5)

	local rarityLabel = makeLabel(row, string.upper(tostring(item.Rarity or "Common")), 11, RarityColors.Get(item.Rarity), true)
	rarityLabel.Size = UDim2.new(0, 110, 0, 16)
	rarityLabel.Position = UDim2.new(0, 12, 0, 30)

	local income = item.IncomePerSec or item.incomePerSec or item.Income
	local infoLabel = makeLabel(
		row,
		"🪙 " .. tostring(item.Cost or item.Price or "?") .. "    •    +" .. tostring(income or "?") .. "/s",
		12,
		Color3.fromRGB(255, 215, 0),
		true
	)
	infoLabel.Size = UDim2.new(0, 150, 0, 18)
	infoLabel.Position = UDim2.new(0, 130, 0, 29)

	local buyBtn = Instance.new("TextButton")
	buyBtn.Size = UDim2.new(0, 76, 0, 32)
	buyBtn.Position = UDim2.new(1, -88, 0, 12)
	buyBtn.Text = "BUY"
	buyBtn.Font = Enum.Font.GothamBold
	buyBtn.TextSize = 13
	buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	buyBtn.BackgroundColor3 = Color3.fromRGB(60, 160, 90)
	buyBtn.BorderSizePixel = 0
	corner(buyBtn, 8)
	buyBtn.Parent = row
	buyBtn.MouseButton1Click:Connect(function()
		MarketController.BuyItem(item)
	end)
	return row
end

function MarketController.Rebuild()
	if not listFrame then
		return
	end
	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	if #items == 0 then
		local note = makeLabel(listFrame, "Conveyor is empty — the next Brainrot spawns soon.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	for _, item in items do
		buildRow(item).Parent = listFrame
	end
end

-- Normalise the many shapes a ConveyorUpdate payload can take:
-- an array of items, {Items={...}}, or a single item table.
function MarketController.ApplyConveyorUpdate(payload: any)
	if typeof(payload) == "table" then
		local list = payload.Items or payload.items or payload
		if typeof(list) == "table" then
			if typeof(list[1]) == "table" then
				items = list
			elseif typeof(list.Name) == "string" or typeof(list.CharacterId) == "string" then
				items = { list }
			else
				items = {}
			end
		end
		if typeof(payload.NextSpawnIn) == "number" then
			spawnInterval = math.max(1, payload.NextSpawnIn)
			lastUpdateAt = os.clock()
		elseif typeof(payload.SpawnInterval) == "number" then
			spawnInterval = payload.SpawnInterval
		end
	elseif typeof(payload) == "string" then
		-- A single character id was pushed; look up its catalogue entry.
		if Characters and Characters.GetById then
			local def = Characters.GetById(payload)
			if def then
				items = { def }
			end
		end
	end
	lastUpdateAt = os.clock()
	for key, _ in pendingBuy do
		pendingBuy[key] = nil
	end
	setStatus("Conveyor updated — " .. tostring(#items) .. " Brainrot(s) on the belt.")
	MarketController.Rebuild()
end

function MarketController.GetItems(): { any }
	return items
end

-- Nearest conveyor item (for the E prompt in InteractionController).
function MarketController.GetNearestItem(maxDistance: number?): any?
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	-- Conveyor items are world parts in the real game; without a server
	-- model to measure against, the GUI list is the source of truth and
	-- the nearest item is simply the first (cheapest / earliest) one.
	-- Proximity buying still works through ProximityPrompts below.
	_ = maxDistance
	return items[1]
end

function MarketController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
end

function MarketController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function MarketController.Toggle()
	if isOpen then
		MarketController.Close()
	else
		MarketController.Open()
	end
end

function MarketController.IsOpen(): boolean
	return isOpen
end

function MarketController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Market"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 560, 0, 460)
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 36)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(60, 220, 230)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = makeLabel(panel, "🛒  CONVEYOR MARKET", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 300, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	spawnLabel = makeLabel(panel, "Next spawn: —", 13, Color3.fromRGB(120, 220, 255), true)
	spawnLabel.Size = UDim2.new(0, 150, 0, 22)
	spawnLabel.Position = UDim2.new(1, -210, 0, 12)
	spawnLabel.TextXAlignment = Enum.TextXAlignment.Right

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
		MarketController.Close()
	end)

	statusLabel = makeLabel(panel, "Live conveyor — buy fast, rare ones go quick.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Size = UDim2.new(1, -24, 1, -76)
	listFrame.Position = UDim2.new(0, 12, 0, 66)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 6
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = panel
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = listFrame

	if UserInputService.TouchEnabled then
		panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	end

	-- Next-spawn countdown ticker (resets on every ConveyorUpdate).
	task.spawn(function()
		while true do
			task.wait(1)
			if spawnLabel and gui and gui.Enabled then
				local elapsed = os.clock() - lastUpdateAt
				local remaining = math.max(0, math.ceil(spawnInterval - elapsed))
				spawnLabel.Text = "Next spawn: " .. tostring(remaining) .. "s"
			end
		end
	end)

	-- Live conveyor feed.
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			setStatus("Remotes folder not found — conveyor cannot update.", true)
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild(remoteName("ConveyorUpdate", "ConveyorUpdate"), 30)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				MarketController.ApplyConveyorUpdate(payload)
			end)
		else
			setStatus("ConveyorUpdate remote is not available yet.", true)
		end
	end)

	-- Server-created ProximityPrompts on conveyor items: same buy path.
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= LocalPlayer then
			return
		end
		local parent = prompt.Parent
		if not parent then
			return
		end
		local id = parent:GetAttribute("BrainrotId") or parent:GetAttribute("CharacterId") or parent:GetAttribute("ItemId")
		local slot = parent:GetAttribute("Slot") or parent:GetAttribute("Index")
		if id then
			MarketController.BuyItem({
				Id = tostring(id),
				CharacterId = tostring(id),
				Slot = slot,
				Name = parent:GetAttribute("BrainrotName") or tostring(id),
			})
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.N then
			MarketController.Toggle()
		end
	end)

	MarketController.Rebuild()
	print("[GlitchTide] MarketController ready")
end

return MarketController
