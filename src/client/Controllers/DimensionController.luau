--!strict
-- DimensionController.luau
-- World Selection (v1.1 Wave 3, Workstream E): the Worlds panel + the
-- DimensionUpdate listener. Server side is Workstream A
-- (DimensionsService) + C's unlock gate (ProgressionService: Abyssal
-- requires Level 5, Skyfall Level 15 — shown here from the documented
-- levels; the SERVER enforces the gate and answers a locked request
-- with TeleportDenied, so this display can never grant access).
--
-- Remotes (all added to Remotes.luau by Wave 3 E):
--   RequestDimensions (RemoteFunction) -> GetDimensions() array:
--     {Id, DisplayName, Description, LightingMood,
--      ExclusiveCharacterId, HubPortalPosition, SpawnPosition,
--      CheckpointTimeLimit, CheckpointRewardCoins, CheckpointRewardXP,
--      Chests = {{Name, Title, Coins, XP}}}
--   TeleportDimension (RemoteEvent) <- {Action="Teleport", DimensionId}
--     | {Action="Return"}
--   DimensionUpdate (RemoteEvent) -> Teleported / Returned /
--     TeleportDenied / ChestOpened / ChestDenied / Checkpoint /
--     CheckpointComplete / CheckpointFailed / BossTriggered / BossDenied
-- Travel also works through the hub ProximityPrompts (server-side);
-- this panel is the remote path. No keybind (travel is a panel act).
-- The client never trusts its own level for access — a TeleportDenied
-- payload is shown as-is.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local DimensionController = {}

local PanelKit = require(script.Parent.PanelKit)

-- Documented unlock levels (QA_V11_C §2 Part 7). Display only — the
-- server enforces the gate.
local UNLOCK_LEVELS: { [string]: number } = {
	abyssal = 5,
	skyfall = 15,
}

local gui: ScreenGui? = nil
local contentFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local regionLabel: TextLabel? = nil
local isOpen = false
local dimensions: { any } = {}
local currentDimension = "hub"
local knownLevel = 1

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function setRegion(name: string)
	currentDimension = name
	if regionLabel then
		regionLabel.Text = "📍 " .. name
	end
	pcall(function()
		local mod = script.Parent:FindFirstChild("HUDController")
		if mod then
			local hud = require(mod)
			if hud.SetRegion then
				hud.SetRegion(name)
			end
		end
	end)
end

local function playSound(method: string)
	PanelKit.PlaySound(method)
end

function DimensionController.GetCurrentDimension(): string
	return currentDimension
end

function DimensionController.GetDimensions(): { any }
	return dimensions
end

-- Fallback defs from the shared Dimensions module (client-readable)
-- when the server function does not answer yet.
local function fallbackDimensions(): { any }
	local ok, list = pcall(function()
		local dims = require(ReplicatedStorage:WaitForChild("Dimensions", 10))
		return dims.GetAll()
	end)
	if ok and typeof(list) == "table" then
		return list
	end
	return {}
end

function DimensionController.RefreshFromServer()
	local ok, result = PanelKit.InvokeChecked("RequestDimensions")
	if ok and typeof(result) == "table" and #result > 0 then
		dimensions = result
		setStatus("Worlds loaded from the server.")
	else
		dimensions = fallbackDimensions()
		if #dimensions > 0 then
			setStatus("Server list unavailable — showing the shared world catalogue.", true)
		else
			setStatus("World list is not available yet.", true)
		end
	end
	DimensionController.Rebuild()
end

function DimensionController.Teleport(dimensionId: string)
	if typeof(dimensionId) ~= "string" or dimensionId == "" then
		return
	end
	if not PanelKit.Debounce("teleport", 3) then
		setStatus("Teleport is on cooldown — wait a moment.", true)
		return
	end
	local fired = PanelKit.FireServerChecked("TeleportDimension", 0, {
		Action = "Teleport",
		DimensionId = dimensionId,
	})
	if fired then
		setStatus("Travelling to " .. dimensionId .. " — waiting for the server…")
		playSound("teleport")
	else
		setStatus("TeleportDimension remote is not available yet.", true)
	end
end

function DimensionController.ReturnToHub()
	if not PanelKit.Debounce("teleport", 3) then
		setStatus("Teleport is on cooldown — wait a moment.", true)
		return
	end
	local fired = PanelKit.FireServerChecked("TeleportDimension", 0, { Action = "Return" })
	if fired then
		setStatus("Returning to the hub…")
		playSound("teleport")
	else
		setStatus("TeleportDimension remote is not available yet.", true)
	end
end

local function buildCard(def: any): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 118)
	row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	row.BorderSizePixel = 0
	PanelKit.Corner(row, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 80, 255)
	stroke.Thickness = 2
	stroke.Parent = row

	local displayName = tostring(def.DisplayName or def.Name or def.Id or "?")
	local id = tostring(def.Id or "")
	local desc = tostring(def.Description or "")
	local mood = tostring(def.LightingMood or def.Mood or "Hub")
	local exclusive = def.ExclusiveCharacterId
	local exclusiveName = if typeof(exclusive) == "string" and exclusive ~= ""
		then PanelKit.CharacterName(exclusive)
		else nil
	local requiredLevel = UNLOCK_LEVELS[id]
	local levelNote = if requiredLevel then "Requires Level " .. tostring(requiredLevel) else "Open to all"
	local lockedNote = ""
	if requiredLevel and knownLevel < requiredLevel then
		lockedNote = "  •  🔒 You are Level " .. tostring(knownLevel)
	end

	local titleLabel = PanelKit.MakeLabel(row, "🌍 " .. displayName .. "  •  " .. mood, 15, Color3.fromRGB(255, 255, 255), true)
	titleLabel.Size = UDim2.new(1, -190, 0, 22)
	titleLabel.Position = UDim2.new(0, 12, 0, 6)
	local descLabel = PanelKit.MakeLabel(row, desc, 11, Color3.fromRGB(190, 200, 220), false)
	descLabel.Size = UDim2.new(1, -190, 0, 34)
	descLabel.Position = UDim2.new(0, 12, 0, 30)
	local detailText = levelNote .. lockedNote
	if exclusiveName then
		detailText ..= "  •  Exclusive: " .. exclusiveName
	end
	if typeof(def.CheckpointTimeLimit) == "number" then
		detailText ..= string.format("  •  Checkpoint run: %ds for 🪙 %d + %d XP",
			def.CheckpointTimeLimit, def.CheckpointRewardCoins or 0, def.CheckpointRewardXP or 0)
	end
	local detailLabel = PanelKit.MakeLabel(row, detailText, 11, Color3.fromRGB(120, 220, 255), true)
	detailLabel.Size = UDim2.new(1, -190, 0, 18)
	detailLabel.Position = UDim2.new(0, 12, 0, 66)
	local chests = def.Chests
	local chestText = ""
	if typeof(chests) == "table" and #chests > 0 then
		local parts: { string } = {}
		for _, chest: any in ipairs(chests) do
			table.insert(parts, tostring(chest.Name or "?") .. " (🪙 " .. tostring(chest.Coins or 0) .. ")")
		end
		chestText = "Chests: " .. table.concat(parts, "  •  ")
	end
	local chestLabel = PanelKit.MakeLabel(row, chestText, 11, Color3.fromRGB(200, 210, 230), false)
	chestLabel.Size = UDim2.new(1, -190, 0, 18)
	chestLabel.Position = UDim2.new(0, 12, 0, 88)

	local isCurrent = currentDimension == id
	local btn = PanelKit.MakeButton(row, if isCurrent then "✓ HERE" else "TRAVEL", UDim2.new(0, 110, 0, 34), UDim2.new(1, -124, 0, 12), if isCurrent then Color3.fromRGB(40, 160, 90) else Color3.fromRGB(90, 70, 160), function()
		if isCurrent then
			setStatus("You are already in " .. displayName .. ".")
			return
		end
		DimensionController.Teleport(id)
	end)
	btn.Name = "Travel_" .. id
	return row
end

function DimensionController.Rebuild()
	if not contentFrame then
		return
	end
	for _, child in contentFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	-- Hub card first (always available; return target).
	local hubRow = Instance.new("Frame")
	hubRow.Size = UDim2.new(1, -12, 0, 64)
	hubRow.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	hubRow.BorderSizePixel = 0
	PanelKit.Corner(hubRow, 10)
	local hubTitle = PanelKit.MakeLabel(hubRow, "🏠 Memeverse Hub  •  the home world", 15, Color3.fromRGB(255, 255, 255), true)
	hubTitle.Size = UDim2.new(1, -190, 0, 22)
	hubTitle.Position = UDim2.new(0, 12, 0, 6)
	local hubDesc = PanelKit.MakeLabel(hubRow, "Plaza, Rift Market, bases, Mutation Lab, Chaos Arena, Forbidden Rift.", 11, Color3.fromRGB(190, 200, 220), false)
	hubDesc.Size = UDim2.new(1, -190, 0, 18)
	hubDesc.Position = UDim2.new(0, 12, 0, 32)
	PanelKit.MakeButton(hubRow, if currentDimension == "hub" then "✓ HERE" else "RETURN", UDim2.new(0, 110, 0, 34), UDim2.new(1, -124, 0, 12), Color3.fromRGB(60, 120, 220), function()
		if currentDimension == "hub" then
			setStatus("You are already in the hub.")
			return
		end
		DimensionController.ReturnToHub()
	end)
	hubRow.Parent = contentFrame
	if #dimensions == 0 then
		local note = PanelKit.MakeLabel(contentFrame, "No other worlds loaded yet — the hub portals still work in-game.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	for _, def in dimensions do
		buildCard(def).Parent = contentFrame
	end
end

function DimensionController.ApplyDimensionUpdate(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local action = payload.Action
	if action == "Teleported" then
		local dim = tostring(payload.Dimension or payload.DimensionId or "?")
		local displayName = tostring(payload.DisplayName or dim)
		setRegion(displayName)
		setStatus("Arrived in " .. displayName .. ".")
		PanelKit.ShowBanner("🌍 You arrived in " .. displayName .. "!", 6)
		playSound("teleport")
		DimensionController.Rebuild()
	elseif action == "Returned" then
		setRegion("Memeverse")
		setStatus("Back in the hub.")
		PanelKit.ShowBanner("🏠 Back in the Memeverse Hub.", 6)
		playSound("teleport")
		DimensionController.Rebuild()
	elseif action == "TeleportDenied" then
		setStatus("Travel denied: " .. tostring(payload.Reason or "locked"), true)
		PanelKit.ShowBanner("🔒 Travel denied: " .. tostring(payload.Reason or "locked"), 6)
		playSound("error")
	elseif action == "ChestOpened" then
		setStatus("Chest opened: " .. tostring(payload.Chest or "?") .. " — 🪙 " .. tostring(payload.Coins or 0) .. " + " .. tostring(payload.XP or 0) .. " XP.")
		PanelKit.ShowBanner("🗝️ Chest opened: " .. tostring(payload.Title or payload.Chest or "treasure") .. "! 🪙 " .. tostring(payload.Coins or 0), 6)
		playSound("discover")
	elseif action == "ChestDenied" then
		setStatus("Chest denied: " .. tostring(payload.Reason or "not ready"), true)
		playSound("error")
	elseif action == "Checkpoint" then
		setStatus("Checkpoint " .. tostring(payload.Index or "?") .. "/" .. tostring(payload.Total or "?") .. " reached!")
		playSound("discover")
	elseif action == "CheckpointComplete" then
		setStatus("Checkpoint run complete! 🪙 " .. tostring(payload.Coins or 0) .. " + " .. tostring(payload.XP or 0) .. " XP" .. (if payload.FirstCompletion then " — first completion!" else "") .. ".")
		PanelKit.ShowBanner("🏁 Checkpoint run complete! 🪙 " .. tostring(payload.Coins or 0) .. " + " .. tostring(payload.XP or 0) .. " XP", 8)
		playSound("achievement")
	elseif action == "CheckpointFailed" then
		setStatus("Checkpoint run failed (" .. tostring(payload.Reason or "?") .. ") — " .. tostring(payload.ElapsedSeconds or 0) .. "s / " .. tostring(payload.TimeLimit or 0) .. "s.", true)
		playSound("error")
	elseif action == "BossTriggered" then
		setStatus("Something stirs in the deep… the altar has woken a boss!", true)
		PanelKit.ShowBanner("👁️ The Abyssal altar has woken something!", 8)
		playSound("boss")
	elseif action == "BossDenied" then
		setStatus("Boss trigger denied: " .. tostring(payload.Reason or "?"), true)
		playSound("error")
	end
end

function DimensionController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	DimensionController.RefreshFromServer()
end

function DimensionController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function DimensionController.Toggle()
	if isOpen then
		DimensionController.Close()
	else
		DimensionController.Open()
	end
end

function DimensionController.IsOpen(): boolean
	return isOpen
end

function DimensionController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Dimensions"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 620, 0, 480)
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 36)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	PanelKit.Corner(panel, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(120, 80, 255)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = PanelKit.MakeLabel(panel, "🌍  WORLDS", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 200, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	regionLabel = PanelKit.MakeLabel(panel, "📍 Memeverse", 13, Color3.fromRGB(120, 220, 255), true)
	regionLabel.Size = UDim2.new(0, 220, 0, 22)
	regionLabel.Position = UDim2.new(1, -280, 0, 12)
	regionLabel.TextXAlignment = Enum.TextXAlignment.Right

	PanelKit.MakeButton(panel, "✕", UDim2.new(0, 36, 0, 30), UDim2.new(1, -48, 0, 10), Color3.fromRGB(200, 60, 60), function()
		DimensionController.Close()
	end)

	statusLabel = PanelKit.MakeLabel(panel, "Pick a world to travel to. The hub portals in-game go to the same places.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Name = "Content"
	contentFrame.Size = UDim2.new(1, -24, 1, -76)
	contentFrame.Position = UDim2.new(0, 12, 0, 66)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 6
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	contentFrame.Parent = panel
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = contentFrame

	if UserInputService.TouchEnabled then
		panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	end

	-- Live dimension feed.
	PanelKit.Listen("DimensionUpdate", function(payload: any)
		DimensionController.ApplyDimensionUpdate(payload)
	end)
	-- Own level (for the unlock-level display) from PlayerStats pushes.
	PanelKit.Listen("PlayerStats", function(payload: any)
		if typeof(payload) == "table" and typeof(payload.Level) == "number" then
			knownLevel = payload.Level
		end
	end)

	DimensionController.Rebuild()
	print("[GlitchTide] DimensionController ready")
end

return DimensionController
