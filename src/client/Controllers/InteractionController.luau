--!strict
-- InteractionController.luau
-- Central E-interact for GLITCH TIDE.
-- Every 0.25s it finds the nearest interactable within range and shows
-- a context prompt at the bottom of the screen:
--   "E — Buy X (100 coins)"        conveyor Brainrot / world part
--   "E — Place Brainrot"           own base slot while carrying
--   "E — Pick Up Brainrot"         a loose Brainrot on the ground
--   "E — Talk"                     NPC
--   "E — Mutate" / "E — Upgrade"   mutation machine / upgrade station
-- Pressing E (or the touch Interact button) fires the matching server
-- remote with that target's id. G (or the Drop button) drops a carried
-- Brainrot via DropBrainrot. Carrying state comes from CarryUpdate and
-- is shared with the HUD chip + AnimationController carry pose.
-- Interactables are discovered ONLY through server-created
-- ProximityPrompts (NPC talk, conveyor buy via MarketController).
-- v1.0.1 integration QA: an earlier version of this controller scanned
-- world parts for InteractType / InteractId attributes, but NO producer
-- ever sets those attributes — MapBuilder, ConveyorService and
-- NPCService never tag parts — so the scan always found nothing and
-- the prompt stayed hidden. The scan has been removed (not left
-- pretending to work): findNearest is intentionally inert and E only
-- ever acts through a ProximityPrompt or an explicit panel (Market /
-- Shop / Base). If the map team ever tags parts, re-add a scan here
-- and set InteractType/InteractId in MapBuilder at the same time.
--   InteractType = "Conveyor" | "BaseSlot" | "Base" | "Pickup" |
--                  "NPC" | "Mutation" | "UpgradeStation"
--   InteractId   = id passed to the remote
--   InteractName / InteractCost = prompt text

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local InteractionController = {}

local RemotesModule: any = nil
pcall(function()
	RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes", 10))
end)

local Utils: any = nil
pcall(function()
	Utils = require(ReplicatedStorage:WaitForChild("Utils", 10))
end)

-- Key labels come from the shared bind table (Utils.GetKeybinds): the
-- prompt text, the touch buttons and the InputBegan handler all read
-- the same values, so a rebind moves every label with it.
local function getBinds(): { [string]: string }
	if Utils and Utils.GetKeybinds then
		local ok, binds = pcall(function()
			return Utils.GetKeybinds()
		end)
		if ok and type(binds) == "table" then
			return binds
		end
	end
	return { Interact = "E", Drop = "G" }
end

local gui: ScreenGui? = nil
local promptFrame: Frame? = nil
local promptLabel: TextLabel? = nil
local interactButton: TextButton? = nil
local dropButton: TextButton? = nil
local isTouch = false

local carrying: boolean = false
local carriedName: string? = nil
local carriedId: string? = nil
local currentTarget: any = nil
local currentPromptText: string = ""
-- While a server NPC dialogue is showing, the 0.25s scan loop must not
-- overwrite the prompt text with the nearest-target prompt.
local dialogueShowing = false

-- (INTERACT_RANGE removed with the attribute scan: no distance check
-- is needed while findNearest is inert. Re-add it if a scan returns.)

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

local function getRoot(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function playSound(name: string)
	pcall(function()
		local mod = script.Parent:FindFirstChild("SoundController")
		if mod then
			local sound = require(mod)
			if name == "pickup" and sound.PlayPickup then
				sound.PlayPickup()
			elseif name == "place" and sound.PlayPlace then
				sound.PlayPlace()
			elseif name == "click" and sound.PlayClick then
				sound.PlayClick()
			end
		end
	end)
end

local function setCarrying(value: boolean, name: string?, id: string?)
	carrying = value
	carriedName = name
	carriedId = id
	pcall(function()
		local mod = script.Parent:FindFirstChild("AnimationController")
		if mod then
			local anim = require(mod)
			if anim.SetCarrying then
				anim.SetCarrying(value)
			end
		end
	end)
	pcall(function()
		local mod = script.Parent:FindFirstChild("HUDController")
		if mod then
			local hud = require(mod)
			if hud.SetCarrying then
				hud.SetCarrying(value, name)
			end
		end
	end)
	if dropButton then
		dropButton.Visible = value
	end
end

function InteractionController.IsCarrying(): boolean
	return carrying
end

function InteractionController.GetCarried(): (string?, string?)
	return carriedName, carriedId
end

-- findNearest: INTENTIONALLY INERT (v1.0.1 integration QA, option b).
-- The attribute scan that used to live here is removed, not left
-- pretending to work: no producer in the shipped game ever sets
-- InteractType/InteractId attributes, so the scan always returned nil
-- while costing a descendants walk 4x/second. The sole interaction
-- path is server ProximityPrompts (NPC talk, conveyor buy via
-- MarketController) plus explicit panels (Market / Shop / Base).
-- Kept as a function (returning nil) so the 0.25s loop and Interact()
-- keep their shape: with no target, E shows the "nothing nearby"
-- hint and never spends coins. If MapBuilder ever tags parts, restore
-- a scan here AND set the attributes in MapBuilder at the same time.
local function findNearest(): any?
	return nil
end

local function promptFor(target: any): string?
	if not target then
		return nil
	end
	local kind = target.kind
	local name = tostring(target.name or "?")
	local key = getBinds().Interact or "E"
	if kind == "Conveyor" then
		local cost = target.cost
		if typeof(cost) == "number" then
			return key .. " — Buy " .. name .. " (" .. tostring(cost) .. " coins)"
		end
		return key .. " — Buy " .. name
	elseif kind == "BaseSlot" or kind == "Base" then
		if carrying then
			return key .. " — Place " .. tostring(carriedName or "Brainrot") .. " at base"
		end
		return key .. " — Open base"
	elseif kind == "Pickup" then
		return key .. " — Pick Up " .. name
	elseif kind == "NPC" then
		return key .. " — Talk to " .. name
	elseif kind == "Mutation" then
		return key .. " — Mutate " .. name
	elseif kind == "UpgradeStation" then
		return key .. " — Upgrade at station"
	end
	return key .. " — Interact"
end

local function showPrompt(text: string?)
	if not promptFrame or not promptLabel then
		return
	end
	if text then
		currentPromptText = text
		promptLabel.Text = text
		promptFrame.Visible = true
		if interactButton then
			interactButton.Visible = true
		end
	else
		currentPromptText = ""
		promptFrame.Visible = false
		if interactButton and not isTouch then
			interactButton.Visible = false
		elseif interactButton then
			-- On touch the Interact button stays visible (it is the
			-- only way to interact); only the text prompt hides.
			interactButton.Visible = true
		end
	end
end

local function fireRemote(key: string, fallback: string, ...: any)
	local remote = getRemote(remoteName(key, fallback))
	if not remote or not remote:IsA("RemoteEvent") then
		return false
	end
	local args = { ... }
	pcall(function()
		(remote :: RemoteEvent):FireServer(unpack(args))
	end)
	return true
end

function InteractionController.Interact()
	if not currentTarget then
		-- No tagged target nearby: do NOTHING that spends coins.
		-- The old code blind-bought the first conveyor item here, so
		-- pressing E anywhere (e.g. mid-fight, or while the attribute
		-- scan finds nothing — which is always, see findNearest) spent
		-- the player's coins on an unchosen Brainrot. Buying is only
		-- ever an explicit act: the Market panel, a conveyor prompt, or
		-- a ProximityPrompt.
		showPrompt("Nothing to interact with nearby — open the Market ("
			.. (getBinds().Market or "N") .. ") to buy from the conveyor.")
		task.delay(2, function()
			if not currentTarget and not dialogueShowing then
				showPrompt(promptFor(currentTarget))
			end
		end)
		return
	end
	local target = currentTarget
	local kind = target.kind
	if kind == "Conveyor" then
		pcall(function()
			local mod = script.Parent:FindFirstChild("MarketController")
			if mod then
				local market = require(mod)
				if market.BuyItem then
					market.BuyItem({
						Id = target.id,
						CharacterId = target.id,
						Name = target.name,
						Cost = target.cost,
					})
				end
			end
		end)
	elseif kind == "BaseSlot" or kind == "Base" then
		if carrying then
			playSound("place")
			fireRemote("PlaceBrainrot", "PlaceBrainrot", carriedId, target.id)
			setCarrying(false, nil, nil)
		else
			pcall(function()
				local mod = script.Parent:FindFirstChild("BaseController")
				if mod then
					local base = require(mod)
					if base.Open then
						base.Open()
					end
				end
			end)
		end
	elseif kind == "Pickup" then
		playSound("pickup")
		fireRemote("PickupBrainrot", "PickupBrainrot", target.id)
	elseif kind == "NPC" then
		playSound("click")
		-- Server NPCs talk through their own ProximityPrompts
		-- (NPCService fires real NPCDialogue lines at the player).
		-- An attribute-tagged NPC has no server dialogue of its own,
		-- so point at the prompt instead of inventing a line: the old
		-- code showed a hardcoded fake quote here.
		showPrompt("💬 " .. tostring(target.name) .. " — walk up and use the Talk prompt to chat.")
		task.delay(3, function()
			if not dialogueShowing then
				showPrompt(promptFor(currentTarget))
			end
		end)
	elseif kind == "Mutation" then
		-- Mutation Lab lives in the Shop's Mutations tab: pick a placed
		-- Brainrot, pick a mutation, pay Mutation Crystals. The old
		-- code showed a dead "not wired up yet" message even though
		-- MutateBrainrot has a server handler.
		pcall(function()
			local mod = script.Parent:FindFirstChild("ShopController")
			if mod then
				local shop = require(mod)
				if shop.Open then
					shop.Open()
				end
				if shop.SetTab then
					shop.SetTab("Mutations")
				end
			end
		end)
	elseif kind == "UpgradeStation" then
		pcall(function()
			local mod = script.Parent:FindFirstChild("ShopController")
			if mod then
				local shop = require(mod)
				if shop.Open then
					shop.Open()
				end
			end
		end)
	end
end

function InteractionController.Drop()
	if not carrying then
		return
	end
	fireRemote("DropBrainrot", "DropBrainrot", carriedId)
	setCarrying(false, nil, nil)
	playSound("click")
end

function InteractionController.ApplyCarryUpdate(payload: any)
	if typeof(payload) == "table" then
		local isCarrying = payload.Carrying == true or payload.carrying == true
		local name = payload.Name or payload.BrainrotName or payload.CharacterName
		-- The server's carry id is the InstanceId (a GUID). PlaceBrainrot
		-- matches placed/owned records on InstanceId only — the old
		-- code stored payload.CharacterId here, so every PlaceBrainrot
		-- fired with a CharacterId and the server rejected it with
		-- "brainrot not owned" / "not carrying that brainrot".
		local id = payload.InstanceId or payload.instanceId or payload.Id
		setCarrying(isCarrying, if typeof(name) == "string" then name else nil, if typeof(id) == "string" then id else nil)
	elseif typeof(payload) == "boolean" then
		setCarrying(payload, nil, nil)
	elseif typeof(payload) == "string" then
		setCarrying(true, payload, nil)
	end
end

-- NPCDialogue payload from the server ({NPC, Lines = {...}, Hint}):
-- show the real lines in the prompt area instead of a hardcoded quote.
-- Lines are shown one at a time (3.5s each) so a long dialogue stays
-- readable in the single-line prompt; the Hint stays on the last line.
local dialogueToken = 0
function InteractionController.ShowDialogue(payload: any)
	if not promptFrame or not promptLabel then
		return
	end
	local lines: { string } = {}
	local npcName = "NPC"
	local hint: string? = nil
	if typeof(payload) == "table" then
		npcName = tostring(payload.NPC or payload.Name or npcName)
		local raw = payload.Lines or payload.lines
		if typeof(raw) == "table" then
			for _, line in ipairs(raw) do
				if typeof(line) == "string" and line ~= "" then
					table.insert(lines, line)
				end
			end
		elseif typeof(payload.Text) == "string" then
			table.insert(lines, payload.Text)
		end
		if typeof(payload.Hint) == "string" then
			hint = payload.Hint
		end
	elseif typeof(payload) == "string" then
		table.insert(lines, payload)
	end
	if #lines == 0 then
		return
	end
	dialogueToken += 1
	local token = dialogueToken
	dialogueShowing = true
	playSound("click")
	promptLabel.TextWrapped = true
	promptFrame.Size = UDim2.new(0, 460, 0, 64)
	task.spawn(function()
		for i, line in ipairs(lines) do
			if token ~= dialogueToken then
				return
			end
			showPrompt("💬 " .. npcName .. ": \"" .. line .. "\"")
			task.wait(3.5)
		end
		if token ~= dialogueToken then
			return
		end
		if hint then
			showPrompt("💡 " .. hint)
			task.wait(3)
		end
		if token == dialogueToken then
			dialogueShowing = false
			promptLabel.TextWrapped = false
			promptFrame.Size = UDim2.new(0, 420, 0, 40)
			showPrompt(promptFor(currentTarget))
		end
	end)
end

function InteractionController.Init()
	isTouch = UserInputService.TouchEnabled
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Interaction"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 14
	gui.Parent = playerGui

	-- Context prompt, bottom-center above the HUD menu bar.
	promptFrame = Instance.new("Frame")
	promptFrame.Name = "Prompt"
	promptFrame.AnchorPoint = Vector2.new(0.5, 1)
	promptFrame.Position = UDim2.new(0.5, 0, 1, -64)
	promptFrame.Size = UDim2.new(0, 420, 0, 40)
	promptFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	promptFrame.BackgroundTransparency = 0.2
	promptFrame.BorderSizePixel = 0
	promptFrame.Visible = false
	promptFrame.Parent = gui
	corner(promptFrame, 10)
	local promptStroke = Instance.new("UIStroke")
	promptStroke.Color = Color3.fromRGB(255, 215, 0)
	promptStroke.Thickness = 1
	promptStroke.Transparency = 0.5
	promptStroke.Parent = promptFrame
	promptLabel = Instance.new("TextLabel")
	promptLabel.Size = UDim2.new(1, -16, 1, 0)
	promptLabel.Position = UDim2.new(0, 8, 0, 0)
	promptLabel.BackgroundTransparency = 1
	promptLabel.Text = ""
	promptLabel.Font = Enum.Font.GothamBold
	promptLabel.TextSize = 15
	promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	promptLabel.TextXAlignment = Enum.TextXAlignment.Center
	promptLabel.Parent = promptFrame

	-- Touch Interact button: big, thumb-sized, right edge. Label is the
	-- live Interact bind, not a hardcoded "E".
	interactButton = Instance.new("TextButton")
	interactButton.Name = "InteractButton"
	interactButton.AnchorPoint = Vector2.new(1, 0.5)
	interactButton.Position = UDim2.new(1, -16, 0.5, 40)
	interactButton.Size = UDim2.new(0, 84, 0, 84)
	interactButton.Text = (getBinds().Interact or "E") .. "\nINTERACT"
	interactButton.Font = Enum.Font.GothamBold
	interactButton.TextSize = 15
	interactButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	interactButton.BackgroundColor3 = Color3.fromRGB(200, 150, 30)
	interactButton.BorderSizePixel = 0
	interactButton.Visible = isTouch
	interactButton.Parent = gui
	corner(interactButton, 42)
	interactButton.MouseButton1Click:Connect(function()
		InteractionController.Interact()
	end)

	-- Drop button: only visible while carrying.
	dropButton = Instance.new("TextButton")
	dropButton.Name = "DropButton"
	dropButton.AnchorPoint = Vector2.new(1, 0.5)
	dropButton.Position = UDim2.new(1, -16, 0.5, 140)
	dropButton.Size = UDim2.new(0, 84, 0, 44)
	dropButton.Text = (getBinds().Drop or "G") .. " — DROP"
	dropButton.Font = Enum.Font.GothamBold
	dropButton.TextSize = 13
	dropButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	dropButton.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
	dropButton.BorderSizePixel = 0
	dropButton.Visible = false
	dropButton.Parent = gui
	corner(dropButton, 10)
	dropButton.MouseButton1Click:Connect(function()
		InteractionController.Drop()
	end)

	-- Nearest-target scan. Skips the prompt refresh while a server NPC
	-- dialogue is showing (ShowDialogue owns the prompt then).
	task.spawn(function()
		while true do
			task.wait(0.25)
			local target = findNearest()
			currentTarget = target
			if not dialogueShowing then
				showPrompt(promptFor(target))
			end
		end
	end)

	-- Carry state from the server.
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild(remoteName("CarryUpdate", "CarryUpdate"), 30)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				InteractionController.ApplyCarryUpdate(payload)
			end)
		end
	end)

	-- NPC dialogue from the server (NPCService fires NPCDialogue when a
	-- vendor / quest-giver ProximityPrompt triggers). Until this
	-- listener existed, nothing on the client ever displayed those
	-- lines — the E-interact path just showed a hardcoded fake quote.
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild(remoteName("NPCDialogue", "NPCDialogue"), 30)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				InteractionController.ShowDialogue(payload)
			end)
		end
	end)

	-- Interact / Drop keys from the shared bind table.
	local binds = getBinds()
	local interactCode = Utils and Utils.KeyCodeFor and Utils.KeyCodeFor(binds.Interact or "E") or Enum.KeyCode.E
	local dropCode = Utils and Utils.KeyCodeFor and Utils.KeyCodeFor(binds.Drop or "G") or Enum.KeyCode.G
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == interactCode then
			InteractionController.Interact()
		elseif input.KeyCode == dropCode then
			InteractionController.Drop()
		end
	end)

	print("[GlitchTide] InteractionController ready ("
		.. (binds.Interact or "E") .. "=Interact, " .. (binds.Drop or "G") .. "=Drop)")
end

return InteractionController
