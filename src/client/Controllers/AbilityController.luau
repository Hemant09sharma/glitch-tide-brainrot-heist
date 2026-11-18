--!strict
-- AbilityController.luau
-- Loadout bar of 3 powers for GLITCH TIDE.
--
-- KEYBINDS (canonical, Config.Keybinds — v1.0.1 QA; this file reads
-- them from Config and never hardcodes a key):
--   Q — character primary power
--   F — Slam (generic ground slam)
--   R — Heal (generic, restores health)
--   E — Interact (NOT an ability key; InteractionController owns it)
--   G — Drop carried Brainrot (NOT an ability key)
--   1/2/3 — equipped loadout powers (the 3 powers in
--     data.AbilityLoadout, pushed by the server on PlayerStats).
-- Touch: three large thumb buttons at the bottom-right for Q/F/R, a
-- smaller row above for the 1/2/3 loadout powers, plus tap = fire.
--
-- Firing: UseAbility RemoteEvent with the power id string. The server is
-- authoritative on cooldowns and validity. Cooldown display runs locally
-- from the shared Powers cooldowns, and is corrected whenever the
-- server sends a PowerUpdate event.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local AbilityController = {}

local Powers: any = nil
local Characters: any = nil
local Config: any = nil
pcall(function()
	Powers = require(ReplicatedStorage:WaitForChild("Powers", 10))
end)
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
local slotButtons: { [string]: TextButton } = {}
local cooldownLabels: { [string]: TextLabel } = {}
local cooldownOverlays: { [string]: Frame } = {}
local nameLabels: { [string]: TextLabel } = {}

-- Keybinds come from Config.Keybinds (single source of truth); the
-- literals here are only the fallback if Config failed to load.
local function keybind(name: string, fallback: string): string
	if Config and type(Config.Keybinds) == "table" and type(Config.Keybinds[name]) == "string" then
		return Config.Keybinds[name]
	end
	return fallback
end

-- Slots in bar order. key = input key, powerId filled in by SetLoadout.
-- Built from Config at load time (Q/F/R), never hardcoded below.
local slots: { { key: string, slot: string, powerId: string? } } = {
	{ key = keybind("Primary", "Q"), slot = "Primary", powerId = nil },
	{ key = keybind("Slam", "F"), slot = "Slam", powerId = "slam" },
	{ key = keybind("Heal", "R"), slot = "Heal", powerId = "heal" },
}
-- Loadout slots (keys 1/2/3 from Config.Keybinds): the 3 equipped
-- playable powers. powerIds arrive from the server on PlayerStats
-- (AbilityLoadout); defaults match the server DEFAULT_LOADOUT until
-- the first push lands.
local loadoutSlots: { { key: string, slot: string, powerId: string? } } = {
	{ key = keybind("Loadout1", "1"), slot = "Loadout1", powerId = "dash" },
	{ key = keybind("Loadout2", "2"), slot = "Loadout2", powerId = "energy_shield" },
	{ key = keybind("Loadout3", "3"), slot = "Loadout3", powerId = "magnet_pull" },
}
local cooldownEnds: { [string]: number } = {}
local lastFireAt: { [string]: number } = {}
local currentCharacterId: string = "wobble_waffleton"
local isTouch = false

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

local function getPowerDef(powerId: string): any
	if Powers and Powers.GetById then
		local ok, def = pcall(function()
			return Powers.GetById(powerId)
		end)
		if ok then
			return def
		end
	end
	return nil
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function remainingCooldown(slotKey: string): number
	local ends = cooldownEnds[slotKey]
	if not ends then
		return 0
	end
	return math.max(0, ends - os.clock())
end

local function setCooldown(slotKey: string, seconds: number)
	cooldownEnds[slotKey] = os.clock() + math.max(0, seconds)
end

function AbilityController.UseSlot(slotKey: string)
	local slotDef: any = nil
	for _, slot in slots do
		if slot.key == slotKey then
			slotDef = slot
			break
		end
	end
	if not slotDef then
		for _, slot in loadoutSlots do
			if slot.key == slotKey then
				slotDef = slot
				break
			end
		end
	end
	if not slotDef or not slotDef.powerId then
		return
	end
	if remainingCooldown(slotKey) > 0 then
		return
	end
	-- Rate-limit: never fire the same slot more than once per 0.25s.
	local last = lastFireAt[slotKey] or 0
	if os.clock() - last < 0.25 then
		return
	end
	lastFireAt[slotKey] = os.clock()
	local powerId = slotDef.powerId
	local remote = getRemote(remoteName("UseAbility", "UseAbility"))
	if not remote or not remote:IsA("RemoteEvent") then
		return
	end
	pcall(function()
		(remote :: RemoteEvent):FireServer(powerId)
	end)
	-- Local display cooldown from the shared def. The server still
	-- enforces the real cooldown; this only drives the radial/text.
	local def = getPowerDef(powerId)
	if def and typeof(def.Cooldown) == "number" then
		setCooldown(slotKey, def.Cooldown)
	end
	-- Button press feedback (shrinks toward the button's own size).
	local button = slotButtons[slotKey]
	if button then
		local originalSize = button.Size
		local shrink = UDim2.new(
			originalSize.X.Scale, math.max(20, originalSize.X.Offset - 6),
			originalSize.Y.Scale, math.max(20, originalSize.Y.Offset - 6)
		)
		local tween = TweenService:Create(
			button,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = shrink }
		)
		tween:Play()
		tween.Completed:Connect(function()
			TweenService:Create(
				button,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = originalSize }
			):Play()
		end)
	end
end

-- Rebuild the bar for a character: slot Q becomes that character's
-- primary power; F and R stay Slam / Heal.
function AbilityController.SetCharacter(characterId: string)
	if typeof(characterId) ~= "string" or characterId == "" then
		return
	end
	currentCharacterId = characterId
	local primaryId: string? = nil
	if Powers and Powers.GetForCharacter then
		local ok, def = pcall(function()
			return Powers.GetForCharacter(characterId)
		end)
		if ok and def and typeof(def.Id) == "string" then
			primaryId = def.Id
		end
	end
	if not primaryId and Characters and Characters.GetById then
		local ok, charDef = pcall(function()
			return Characters.GetById(characterId)
		end)
		if ok and charDef and typeof(charDef.AbilityId) == "string" then
			primaryId = charDef.AbilityId
		end
	end
	for _, slot in slots do
		if slot.slot == "Primary" then
			slot.powerId = primaryId
		end
	end
	AbilityController.RefreshBar()
end

-- Rebuild the loadout bar from the server-pushed loadout (PlayerStats
-- AbilityLoadout). Unknown / duplicate ids are ignored; the bar keeps
-- whatever it had for that slot.
function AbilityController.SetLoadout(loadout: any)
	if type(loadout) ~= "table" then
		return
	end
	for i, slot in ipairs(loadoutSlots) do
		local id = loadout[i]
		if type(id) == "string" and id ~= "" then
			local def = getPowerDef(id)
			if def then
				slot.powerId = id
			end
		end
	end
	AbilityController.RefreshBar()
end

function AbilityController.GetLoadout(): { string? }
	local out: { string? } = {}
	for _, slot in ipairs(loadoutSlots) do
		table.insert(out, slot.powerId)
	end
	return out
end

function AbilityController.GetCharacterId(): string
	return currentCharacterId
end

function AbilityController.RefreshBar()
	local allSlots: { any } = {}
	for _, slot in slots do
		table.insert(allSlots, slot)
	end
	for _, slot in loadoutSlots do
		table.insert(allSlots, slot)
	end
	for _, slot in allSlots do
		local key = slot.key
		local button = slotButtons[key]
		local nameLabel = nameLabels[key]
		if button and slot.powerId then
			local def = getPowerDef(slot.powerId)
			if def then
				button.BackgroundColor3 = def.Color or Color3.fromRGB(80, 80, 120)
				if nameLabel then
					nameLabel.Text = tostring(def.Name or slot.powerId)
				end
				-- Key hint on the button face.
				local keyLabel = button:FindFirstChild("KeyLabel") :: TextLabel?
				if keyLabel then
					keyLabel.Text = key
				end
			end
		elseif button then
			button.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
			if nameLabel then
				nameLabel.Text = "—"
			end
		end
	end
end

-- Server-sent cooldown state, if the server ever adds PowerUpdate.
-- Accepts {PowerId=..., Cooldown=..., Remaining=...} or
-- {slotKey=..., Remaining=...} or a plain (powerId, remaining) pair.
local function onPowerUpdate(a: any, b: any)
	local powerId: string? = nil
	local remaining: number? = nil
	if typeof(a) == "table" then
		powerId = a.PowerId or a.powerId or a.Id
		remaining = a.Remaining or a.remaining or a.Cooldown or a.cooldown
	elseif typeof(a) == "string" then
		powerId = a
		if typeof(b) == "number" then
			remaining = b
		end
	end
	if powerId and remaining then
		for _, slot in slots do
			if slot.powerId == powerId then
				setCooldown(slot.key, remaining)
			end
		end
		for _, slot in loadoutSlots do
			if slot.powerId == powerId then
				setCooldown(slot.key, remaining)
			end
		end
	end
end

-- Server-pushed state on PlayerStats: the loadout (AbilityLoadout)
-- rebuilds the 1/2/3 bar. Other PlayerStats fields are owned by other
-- controllers; this handler only reads AbilityLoadout.
local function onPlayerStats(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.AbilityLoadout) == "table" then
		AbilityController.SetLoadout(payload.AbilityLoadout)
	end
end

function AbilityController.Init()
	isTouch = UserInputService.TouchEnabled
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "AbilityBar"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 15
	gui.Parent = playerGui

	local barSize = if isTouch then 76 else 64
	local loadoutSize = if isTouch then 52 else 44
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(1, 1)
	bar.Position = UDim2.new(1, -14, 1, -14)
	bar.Size = UDim2.new(0, barSize * 3 + 24, 0, barSize + loadoutSize + 44)
	bar.BackgroundTransparency = 1
	bar.Parent = gui

	-- One slot button (main bar or loadout row): icon button + cooldown
	-- overlay + key hint + countdown + name label underneath.
	local function buildSlotButton(parent: Instance, slot: any, index: number, size: number, yOffset: number)
		local key = slot.key
		local button = Instance.new("TextButton")
		button.Name = "Slot_" .. key
		button.Size = UDim2.new(0, size, 0, size)
		button.Position = UDim2.new(0, (index - 1) * (size + 12), 0, yOffset)
		button.BackgroundColor3 = Color3.fromRGB(70, 70, 100)
		button.Text = ""
		button.BorderSizePixel = 0
		corner(button, 12)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Thickness = 1
		stroke.Transparency = 0.6
		stroke.Parent = button
		button.Parent = parent
		slotButtons[key] = button

		local overlay = Instance.new("Frame")
		overlay.Name = "CooldownOverlay"
		overlay.Size = UDim2.new(1, 0, 0, 0)
		overlay.Position = UDim2.new(0, 0, 0, 0)
		overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		overlay.BackgroundTransparency = 0.45
		overlay.BorderSizePixel = 0
		corner(overlay, 12)
		overlay.Parent = button
		cooldownOverlays[key] = overlay

		local keyLabel = Instance.new("TextLabel")
		keyLabel.Name = "KeyLabel"
		keyLabel.Size = UDim2.new(0, 22, 0, 22)
		keyLabel.Position = UDim2.new(0, 4, 0, 4)
		keyLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		keyLabel.BackgroundTransparency = 0.35
		keyLabel.Text = key
		keyLabel.Font = Enum.Font.GothamBold
		keyLabel.TextSize = 13
		keyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		keyLabel.Parent = button
		corner(keyLabel, 6)

		local cdLabel = Instance.new("TextLabel")
		cdLabel.Name = "CooldownLabel"
		cdLabel.Size = UDim2.new(1, 0, 1, 0)
		cdLabel.BackgroundTransparency = 1
		cdLabel.Text = ""
		cdLabel.Font = Enum.Font.GothamBold
		cdLabel.TextSize = 22
		cdLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		cdLabel.Parent = button
		cooldownLabels[key] = cdLabel

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "PowerName"
		nameLabel.Size = UDim2.new(0, size + 12, 0, 16)
		nameLabel.Position = UDim2.new(0, (index - 1) * (size + 12) - 6, 0, yOffset + size + 4)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = "—"
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 10
		nameLabel.TextColor3 = Color3.fromRGB(230, 230, 240)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Center
		nameLabel.Parent = parent
		nameLabels[key] = nameLabel

		button.MouseButton1Click:Connect(function()
			AbilityController.UseSlot(key)
		end)
	end

	-- Main bar (bottom row): Q primary / F Slam / R Heal.
	for i, slot in slots do
		buildSlotButton(bar, slot, i, barSize, loadoutSize + 18)
	end
	-- Loadout row (top row, smaller): keys 1/2/3, the equipped powers.
	for i, slot in loadoutSlots do
		buildSlotButton(bar, slot, i, loadoutSize, 0)
	end

	-- Cooldown ticker: refresh overlays + countdown text every frame.
	RunService.RenderStepped:Connect(function()
		local allSlots: { any } = {}
		for _, slot in slots do
			table.insert(allSlots, slot)
		end
		for _, slot in loadoutSlots do
			table.insert(allSlots, slot)
		end
		for _, slot in allSlots do
			local key = slot.key
			local overlay = cooldownOverlays[key]
			local label = cooldownLabels[key]
			local button = slotButtons[key]
			if overlay and label and button then
				local remaining = remainingCooldown(key)
				if remaining > 0 then
					local def = slot.powerId and getPowerDef(slot.powerId)
					local total = 1
					if def and typeof(def.Cooldown) == "number" and def.Cooldown > 0 then
						total = def.Cooldown
					end
					local ratio = math.clamp(remaining / total, 0, 1)
					overlay.Size = UDim2.new(1, 0, ratio, 0)
					label.Text = string.format("%.0f", math.ceil(remaining))
					button.AutoButtonColor = false
				else
					overlay.Size = UDim2.new(1, 0, 0, 0)
					label.Text = ""
					button.AutoButtonColor = true
				end
			end
		end
	end)

	-- Server cooldown sync on PowerUpdate (exists in Remotes.Names).
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild("PowerUpdate", 10)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(onPowerUpdate)
		end
	end)

	-- Server loadout push on PlayerStats (AbilityLoadout field).
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild("PlayerStats", 10)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(onPlayerStats)
		end
	end)

	-- Keyboard: keys come from Config.Keybinds (Q/F/R + 1/2/3). E is
	-- deliberately NOT an ability key (Interact), and G is Drop.
	local keyToSlot: { [Enum.KeyCode]: string } = {}
	local DIGIT_NAMES: { [string]: string } = { ["1"] = "One", ["2"] = "Two", ["3"] = "Three" }
	local function bindKey(keyName: string, slotKey: string)
		-- Enum.KeyCode has no "1" member — digits are One/Two/Three.
		local enumName = DIGIT_NAMES[keyName] or keyName
		local code = Enum.KeyCode[enumName]
		if code ~= nil then
			keyToSlot[code] = slotKey
		end
	end
	for _, slot in slots do
		bindKey(slot.key, slot.key)
	end
	for _, slot in loadoutSlots do
		bindKey(slot.key, slot.key)
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		local slotKey = keyToSlot[input.KeyCode]
		if slotKey then
			AbilityController.UseSlot(slotKey)
		end
	end)

	AbilityController.SetCharacter(currentCharacterId)
	AbilityController.RefreshBar()
	print("[GlitchTide] AbilityController ready (Q=primary, F=Slam, R=Heal, 1/2/3=loadout; E=Interact)")
end

return AbilityController
