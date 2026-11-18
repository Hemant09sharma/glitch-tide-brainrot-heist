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
-- Wave 3 (v1.1 E) ADDS ONE scan back, deliberately: the steal scan.
-- It does NOT use InteractType attributes — it reads the placed-model
-- names the server itself creates ("Placed_<InstanceId>") plus the
-- plot OwnerSigns, cached every 5s, and it is the StealBrainrot
-- firer audit F1 was missing. See findNearestStealable().
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

-- STEAL (v1.1 E, audit F1): the StealBrainrot remote had a server
-- handler (RaidService.onSteal) but NO client firer. The scan below
-- is the firer. Design (see QA_V11_E.md §13):
-- * Placed world models are named "Placed_<InstanceId>" (BaseService).
-- * Own instances (from RequestBase) are never steal targets.
-- * Victim resolution: nearest OwnerSign ("BASE n\n<ownerName>") within
--   ~25 studs of the model, matched to Players:GetPlayers() by name;
--   fallback: nearest OTHER player within 30 studs of the model.
-- * Fire {VictimUserId, InstanceId}. Client debounce 1s (server rate)
--   + 60s per-victim pair cooldown tracked client-side.
-- * The server still validates everything (protection, cooldown, gate,
--   25-stud distance); a StealAlert Phase "Started" with
--   Thief == LocalPlayer is the success signal, and a 5s watchdog
--   reports a generic failure otherwise (the server sends no failure
--   payload).
-- PERFORMANCE: the descendants walk runs once every 5s into a cache
-- (placed models + owner signs); the 0.25s tick only measures
-- distances against the cache, so the scan costs ~nothing per tick.
local ownPlacedIds: { [string]: boolean } = {}
local placedCache: { { model: Model, instanceId: string, position: Vector3 } } = {}
local signCache: { { position: Vector3, ownerName: string } } = {}
local stealCooldowns: { [number]: number } = {}
local stealPending: boolean = false
local stealPendingVictim: number? = nil

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
			elseif name == "steal" and sound.PlayStealAlarm then
				sound.PlayStealAlarm()
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

-- ---- Steal scan (v1.1 E) --------------------------------------------------
local function refreshOwnPlacedIds()
	local remote = getRemote(remoteName("RequestBase", "RequestBase"))
	if not remote or not remote:IsA("RemoteFunction") then
		return
	end
	local ok, base = pcall(function()
		return (remote :: RemoteFunction):InvokeServer()
	end)
	if not ok or typeof(base) ~= "table" then
		return
	end
	local nextIds: { [string]: boolean } = {}
	for _, inst in ipairs(base.Placed or {}) do
		if typeof(inst) == "table" and typeof(inst.InstanceId) == "string" then
			nextIds[inst.InstanceId] = true
		end
	end
	for _, inst in ipairs(base.Unplaced or {}) do
		if typeof(inst) == "table" and typeof(inst.InstanceId) == "string" then
			nextIds[inst.InstanceId] = true
		end
	end
	ownPlacedIds = nextIds
end

-- One descendants walk every 5s (called from the scan loop): rebuild
-- the placed-model cache and the owner-sign cache.
local function refreshPlacedCache()
	local nextPlaced: { { model: Model, instanceId: string, position: Vector3 } } = {}
	local nextSigns: { { position: Vector3, ownerName: string } } = {}
	local ok, err = pcall(function()
		for _, desc in ipairs(workspace:GetDescendants()) do
			if desc:IsA("Model") then
				local name = desc.Name
				if string.sub(name, 1, 7) == "Placed_" then
					local id = string.sub(name, 8)
					if id ~= "" then
						local pos: Vector3? = nil
						local primary = desc.PrimaryPart
						if primary then
							pos = primary.Position
						else
							local first = desc:FindFirstChildWhichIsA("BasePart")
							if first then
								pos = first.Position
							end
						end
						if pos then
							table.insert(nextPlaced, { model = desc, instanceId = id, position = pos })
						end
					end
				end
			elseif desc:IsA("BasePart") and desc.Name == "OwnerSign" then
				local labelGui = desc:FindFirstChild("LabelGui")
				local titleLabel: TextLabel? = nil
				if labelGui then
					titleLabel = labelGui:FindFirstChild("Title")
				end
				if titleLabel and titleLabel:IsA("TextLabel") then
					-- Text is "BASE n\n<ownerName>" or "BASE n\n(unclaimed)".
					local lines = string.split(titleLabel.Text, "\n")
					local owner = lines[2]
					if typeof(owner) == "string" and owner ~= "" and owner ~= "(unclaimed)" then
						table.insert(nextSigns, { position = desc.Position, ownerName = owner })
					end
				end
			end
		end
	end)
	if ok then
		placedCache = nextPlaced
		signCache = nextSigns
	else
		warn("[GlitchTide] InteractionController steal cache refresh failed: " .. tostring(err))
	end
end

-- Nearest stealable placed Brainrot within ~8 studs of the player.
-- Returns {kind="Steal", id, victimUserId, victimName} or nil.
local function findNearestStealable(): any?
	if carrying then
		return nil
	end
	local root = getRoot()
	if not root then
		return nil
	end
	local rootPos = root.Position
	local best: any = nil
	local bestDist = 8
	for _, entry in placedCache do
		if ownPlacedIds[entry.instanceId] then
			continue -- never steal your own Brainrot
		end
		local dist = (entry.position - rootPos).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = entry
		end
	end
	if not best then
		return nil
	end
	-- Victim resolution: nearest owner sign within 25 studs, else
	-- nearest other player within 30 studs of the model.
	local victimUserId: number? = nil
	local victimName: string? = nil
	local bestSignDist = 25
	for _, sign in signCache do
		local dist = (sign.position - best.position).Magnitude
		if dist < bestSignDist then
			bestSignDist = dist
			victimName = sign.ownerName
		end
	end
	if victimName then
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Name == victimName and player ~= LocalPlayer then
				victimUserId = player.UserId
				break
			end
		end
	end
	if not victimUserId then
		local bestPlayerDist = 30
		for _, player in ipairs(Players:GetPlayers()) do
			if player == LocalPlayer then
				continue
			end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local dist = (hrp.Position - best.position).Magnitude
				if dist < bestPlayerDist then
					bestPlayerDist = dist
					victimUserId = player.UserId
					victimName = player.Name
				end
			end
		end
	end
	if not victimUserId then
		return nil
	end
	return {
		kind = "Steal",
		id = best.instanceId,
		victimUserId = victimUserId,
		victimName = victimName,
	}
end

local function armStealWatchdog(victimUserId: number)
	stealPending = true
	stealPendingVictim = victimUserId
	task.delay(5, function()
		if stealPending and stealPendingVictim == victimUserId then
			stealPending = false
			stealPendingVictim = nil
			showPrompt("The steal didn't go through — the base may be protected, on cooldown, or too far away.")
			task.delay(2, function()
				if not currentTarget and not dialogueShowing then
					showPrompt(promptFor(currentTarget))
				end
			end)
		end
	end)
end

function InteractionController.ApplyStealAlert(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	-- Actual payload: {Thief, ThiefUserId, Victim, CharacterId, Phase}
	-- (+ a Lockdown variant {Victim, Phase="Lockdown", Duration}).
	local phase = tostring(payload.Phase or "")
	if phase == "Started" and tostring(payload.Thief or "") == LocalPlayer.Name then
		stealPending = false
		stealPendingVictim = nil
		showPrompt("🏃 You grabbed a Brainrot — run it back to your base!")
		playSound("steal")
	elseif phase == "Success" and tostring(payload.Thief or "") == LocalPlayer.Name then
		showPrompt("✅ Stolen Brainrot delivered to your base!")
	elseif phase == "Failed" and tostring(payload.Thief or "") == LocalPlayer.Name then
		stealPending = false
		stealPendingVictim = nil
		showPrompt("The steal failed — the base was protected.")
	elseif phase == "Lockdown" and tostring(payload.Victim or "") == LocalPlayer.Name then
		showPrompt("🔒 Your base is on lockdown for " .. tostring(payload.Duration or "?") .. "s!")
	end
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
	elseif kind == "Steal" then
		-- Steal target: another player's placed Brainrot within reach.
		local victim = tostring(target.victimName or "another player")
		return key .. " — Steal Brainrot from " .. victim
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
	elseif kind == "Steal" then
		-- StealBrainrot (v1.1 E): the firer audit F1 was missing.
		-- Payload is a table {VictimUserId, InstanceId} — the bare
		-- string form fails server-side (victim missing). Client
		-- debounce 1s (server rate) + 60s per-victim pair cooldown;
		-- the server still validates protection / cooldown / gate /
		-- 25-stud distance, and the 5s watchdog reports a generic
		-- failure if no StealAlert "Started" arrives.
		local victimUserId = target.victimUserId
		local instanceId = target.id
		if typeof(victimUserId) ~= "number" or typeof(instanceId) ~= "string" then
			showPrompt("Can't steal this one — no owner found nearby.")
			return
		end
		local now = os.clock()
		local last = stealCooldowns[victimUserId] or 0
		if now - last < 60 then
			showPrompt("You already tried " .. tostring(target.victimName or "that player") .. " recently — wait " .. tostring(math.ceil(60 - (now - last))) .. "s.")
			return
		end
		if stealPending then
			showPrompt("A steal is already in progress…")
			return
		end
		stealCooldowns[victimUserId] = now
		local fired = fireRemote("StealBrainrot", "StealBrainrot", {
			VictimUserId = victimUserId,
			InstanceId = instanceId,
		})
		if fired then
			armStealWatchdog(victimUserId)
			showPrompt("🏃 Grabbing it — run!")
		else
			showPrompt("StealBrainrot remote is not available yet.")
		end
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
	-- Wave 3 (v1.1 E): the steal scan runs here too, inside the same
	-- 0.25s loop — no new loop. The placed-model cache refreshes once
	-- every 5s (20 ticks); per-tick work is distance checks only.
	local scanTick = 0
	task.spawn(function()
		refreshOwnPlacedIds()
		refreshPlacedCache()
		while true do
			task.wait(0.25)
			scanTick += 1
			if scanTick % 20 == 0 then
				refreshPlacedCache()
			end
			if scanTick % 120 == 0 then
				refreshOwnPlacedIds()
			end
			local target = findNearest() or findNearestStealable()
			currentTarget = target
			if not dialogueShowing then
				showPrompt(promptFor(target))
			end
		end
	end)

	-- StealAlert feed (v1.1 E): the steal watchdog + prompts live here;
	-- BaseController also listens for its own alert banner.
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild(remoteName("StealAlert", "StealAlert"), 30)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				InteractionController.ApplyStealAlert(payload)
			end)
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
