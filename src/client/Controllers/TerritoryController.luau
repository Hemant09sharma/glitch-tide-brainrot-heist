--!strict
-- TerritoryController.luau
-- Territory panel (v1.1 Wave 3, Workstream E): capture / status /
-- bonuses. Server side is Workstream C (TerritoryService). GetTerritories
-- returns an array of {Id, Name, Position={X,Y,Z}, Radius, Tier,
-- CoinsPerSec, XPPerMinute, Holder, HolderUserId, Channeler,
-- ChannelProgress, ChannelSeconds, Contested} — income is FLAT
-- (tier 1: 5 coins/s + 10 XP/min; tier 2: 10 + 20; tier 3: 15 + 30),
-- NOT a multiplier (QA_V11_C §7).
--
-- Remotes:
--   RequestTerritories (RemoteFunction) -> GetTerritories()
--   TerritoryUpdate (RemoteEvent, to ALL) -> TerritoryUpdate payload:
--     {Action="TerritoryUpdate", Territories=<GetTerritories>}
--   CaptureTerritory (RemoteEvent) <- {TerritoryId}
-- Capture is a 10s channel with a 60s per-player cooldown on the
-- server. The client debounces the fire (1s) and then shows the
-- server's verdict from the TerritoryUpdate push; the server owns
-- the channel state, so the panel reads the channel from the push
-- rather than predicting it. No polling: refresh happens on open and
-- on the push, plus a manual Refresh button.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local TerritoryController = {}

local PanelKit = require(script.Parent.PanelKit)

local gui: ScreenGui? = nil
local contentFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local territories: { any } = {}

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function playSound(method: string)
	PanelKit.PlaySound(method)
end

function TerritoryController.GetTerritories(): { any }
	return territories
end

local function heldByMe(t: any): boolean
	if typeof(t) == "table" and typeof(t.HolderUserId) == "number" then
		return t.HolderUserId == LocalPlayer.UserId
	end
	return false
end

local function clearContent()
	if not contentFrame then
		return
	end
	for _, child in contentFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function buildRow(title: string, desc: string, priceText: string, buttonText: string, bg: Color3, onClick: () -> ()): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 64)
	row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	row.BorderSizePixel = 0
	PanelKit.Corner(row, 10)
	local titleLabel = PanelKit.MakeLabel(row, title, 14, Color3.fromRGB(255, 255, 255), true)
	titleLabel.Size = UDim2.new(1, -190, 0, 22)
	titleLabel.Position = UDim2.new(0, 12, 0, 6)
	local descLabel = PanelKit.MakeLabel(row, desc, 11, Color3.fromRGB(190, 200, 220), false)
	descLabel.Size = UDim2.new(1, -190, 0, 30)
	descLabel.Position = UDim2.new(0, 12, 0, 28)
	local priceLabel = PanelKit.MakeLabel(row, priceText, 12, Color3.fromRGB(255, 215, 0), true)
	priceLabel.Size = UDim2.new(0, 120, 0, 22)
	priceLabel.Position = UDim2.new(1, -218, 0, 8)
	priceLabel.TextXAlignment = Enum.TextXAlignment.Right
	PanelKit.MakeButton(row, buttonText, UDim2.new(0, 84, 0, 30), UDim2.new(1, -96, 0, 28), bg, onClick)
	return row
end

function TerritoryController.Rebuild()
	if not contentFrame then
		return
	end
	clearContent()
	if #territories == 0 then
		local note = PanelKit.MakeLabel(contentFrame, "No territory data yet — reopen the panel to retry.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	local mine = 0
	for _, t in territories do
		if heldByMe(t) then
			mine += 1
		end
	end
	local head = PanelKit.MakeLabel(contentFrame, "You hold " .. tostring(mine) .. " of " .. tostring(#territories) .. " territories. Capture is a 10s channel — stand in the zone; the server owns the channel and the 60s cooldown.", 12, Color3.fromRGB(200, 210, 230), false)
	head.Size = UDim2.new(1, -16, 0, 34)
	head.Position = UDim2.new(0, 8, 0, 8)
	for _, t in territories do
		local id = tostring(t.Id or "?")
		local name = tostring(t.Name or id)
		local tier = tonumber(t.Tier) or 1
		local incomeText = "🪙 " .. tostring(t.CoinsPerSec or 0) .. "/s  •  +" .. tostring(t.XPPerMinute or 0) .. " XP/min"
		local holder = tostring(t.Holder or "Unclaimed")
		local desc = "Tier " .. tostring(tier) .. "  •  Held by: " .. holder
		if t.Contested == true then
			desc ..= "  •  ⚔️ CONTESTED"
		end
		if typeof(t.Channeler) == "string" and t.Channeler ~= "" then
			desc ..= "  •  " .. t.Channeler .. " is capturing (" .. tostring(math.floor((t.ChannelProgress or 0) * 100)) .. "%)"
		end
		local mine2 = heldByMe(t)
		local row = buildRow(
			"🏴 " .. name .. (if mine2 then "  •  YOURS" else ""),
			desc,
			incomeText,
			if mine2 then "HELD ✓" elseif typeof(t.Channeler) == "string" and t.Channeler ~= "" then "BUSY" else "CAPTURE",
			if mine2 then Color3.fromRGB(40, 160, 90) else Color3.fromRGB(200, 120, 30),
			function()
				if mine2 then
					setStatus("You already hold " .. name .. ".")
					return
				end
				if not PanelKit.Debounce("terr:capture", 1) then
					setStatus("Capture request sent — wait for the server's answer.", true)
					return
				end
				local fired = PanelKit.FireServerChecked("CaptureTerritory", 0, { TerritoryId = id })
				if fired then
					setStatus("Capture requested for " .. name .. " — channel for 10s (the server decides).")
					playSound("capture")
				else
					setStatus("CaptureTerritory remote is not available yet.", true)
				end
			end
		)
		row.Parent = contentFrame
	end
end

function TerritoryController.RefreshFromServer()
	local ok, result = PanelKit.InvokeChecked("RequestTerritories")
	if ok and typeof(result) == "table" then
		territories = result
		setStatus("Territories loaded.")
	else
		territories = {}
		setStatus("Territory data is not available from the server yet.", true)
	end
	TerritoryController.Rebuild()
end

function TerritoryController.ApplyTerritoryUpdate(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local list = payload.Territories
	if typeof(list) == "table" then
		local before: { [string]: any } = {}
		for _, t in territories do
			if typeof(t) == "table" and typeof(t.Id) == "string" then
				before[t.Id] = t
			end
		end
		territories = list
		for _, t in list do
			if typeof(t) ~= "table" or typeof(t.Id) ~= "string" then
				continue
			end
			local old = before[t.Id]
			local wasMine = old ~= nil and heldByMe(old)
			local isMine = heldByMe(t)
			if isMine and not wasMine then
				PanelKit.ShowBanner("🏴 You captured " .. tostring(t.Name or t.Id) .. "! +" .. tostring(t.CoinsPerSec or 0) .. " coins/s", 6)
				playSound("capture")
			end
		end
		if isOpen then
			TerritoryController.Rebuild()
		end
	end
end

function TerritoryController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	TerritoryController.RefreshFromServer()
end

function TerritoryController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function TerritoryController.Toggle()
	if isOpen then
		TerritoryController.Close()
	else
		TerritoryController.Open()
	end
end

function TerritoryController.IsOpen(): boolean
	return isOpen
end

function TerritoryController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Territories"
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
	pStroke.Color = Color3.fromRGB(200, 120, 30)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = PanelKit.MakeLabel(panel, "🏴  TERRITORIES", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 280, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	PanelKit.MakeButton(panel, "✕", UDim2.new(0, 36, 0, 30), UDim2.new(1, -48, 0, 10), Color3.fromRGB(200, 60, 60), function()
		TerritoryController.Close()
	end)
	PanelKit.MakeButton(panel, "↻ REFRESH", UDim2.new(0, 90, 0, 30), UDim2.new(1, -146, 0, 10), Color3.fromRGB(60, 120, 220), function()
		TerritoryController.RefreshFromServer()
	end)

	statusLabel = PanelKit.MakeLabel(panel, "Territories pay flat income while you hold them — no multiplier.", 12, Color3.fromRGB(200, 220, 255), false)
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

	PanelKit.Listen("TerritoryUpdate", function(payload: any)
		TerritoryController.ApplyTerritoryUpdate(payload)
	end)

	TerritoryController.Rebuild()
	print("[GlitchTide] TerritoryController ready")
end

return TerritoryController
