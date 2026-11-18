--!strict
-- AchievementController.luau
-- Achievements + Titles panel (v1.1 Wave 3, Workstream E): list,
-- progress, title equip, and the secret-discovery banner. Server side
-- is Workstream C (AchievementService).
--
-- Remotes:
--   RequestAchievements (RemoteFunction) ->
--     {Achievements={{Id, Name, Description, Kind, Goal, Progress,
--     Unlocked, Reward, Title}}, Titles, EquippedTitle}
--   AchievementUnlocked (RemoteEvent) -> {Action, Id, Name, Reward,
--     Title}
--   SecretDiscovered (RemoteEvent) -> {Action="SecretDiscovered"} ONLY.
--     The payload deliberately carries NO secret id or name, so the
--     client shows a generic mysterious banner and nothing more.
--   EquipTitle (RemoteEvent) <- {TitleId} — ADDED by Wave 3 E per
--     REMOTES_NEEDED_C.md's explicit instruction. !!! HANDLER PENDING:
--     AchievementService.SetEquippedTitle(player, titleId) EXISTS
--     server-side but NO remote handler calls it (verified by grep).
--     The Equip button fires the remote AND keeps the choice local
--     (the title shows as equipped in this panel only) and the status
--     text says so plainly. Equips do NOT persist across sessions
--     until AchievementService connects the handler.
--   The title-equip integrator step: in AchievementService's remote
--     table add  ["EquipTitle"] = function(player, payload)
--       AchievementService.SetEquippedTitle(player, payload.TitleId)
--     end  (one handler; the rest of the path already exists).
--
-- Title equip also updates the HUD title display (if HUD exposes
-- SetEquippedTitle). No polling: refresh on open + on
-- AchievementUnlocked / SecretDiscovered pushes.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local AchievementController = {}

local PanelKit = require(script.Parent.PanelKit)

local gui: ScreenGui? = nil
local contentFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local data: any = nil
local localEquippedTitle: string? = nil
local activeTab: string = "Achievements"

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function playSound(method: string)
	PanelKit.PlaySound(method)
end

function AchievementController.GetData(): any
	return data
end

function AchievementController.GetEquippedTitle(): string?
	if localEquippedTitle ~= nil then
		return localEquippedTitle
	end
	if typeof(data) == "table" and typeof(data.EquippedTitle) == "string" and data.EquippedTitle ~= "" then
		return data.EquippedTitle
	end
	return nil
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

local function note(text: string)
	local label = PanelKit.MakeLabel(contentFrame, text, 13, Color3.fromRGB(200, 210, 230), false)
	label.Size = UDim2.new(1, -16, 0, 48)
	label.Position = UDim2.new(0, 8, 0, 8)
end

local function rebuildAchievements()
	clearContent()
	local list: { any } = {}
	if typeof(data) == "table" and typeof(data.Achievements) == "table" then
		list = data.Achievements
	end
	if #list == 0 then
		note("No achievements loaded yet — reopen the panel to retry.")
		return
	end
	local unlocked = 0
	for _, a in list do
		if a.Unlocked == true then
			unlocked += 1
		end
	end
	local head = PanelKit.MakeLabel(contentFrame, "Unlocked " .. tostring(unlocked) .. " / " .. tostring(#list) .. " achievements. Rewards are paid by the server when you unlock one.", 12, Color3.fromRGB(200, 210, 230), false)
	head.Size = UDim2.new(1, -16, 0, 20)
	head.Position = UDim2.new(0, 8, 0, 8)
	-- Grouped by Kind (story / daily / weekly / secret / ...), in
	-- first-seen order.
	local kinds: { string } = {}
	local byKind: { [string]: { any } } = {}
	for _, a in list do
		local kind = tostring(a.Kind or "general")
		if byKind[kind] == nil then
			byKind[kind] = {}
			table.insert(kinds, kind)
		end
		table.insert(byKind[kind], a)
	end
	for _, kind in kinds do
		local kindLabel = PanelKit.MakeLabel(contentFrame, "— " .. string.upper(kind) .. " —", 13, Color3.fromRGB(255, 215, 0), true)
		kindLabel.Size = UDim2.new(1, -16, 0, 20)
		kindLabel.Position = UDim2.new(0, 8, 0, 8)
		for _, a in byKind[kind] do
			local goal = tonumber(a.Goal) or 1
			local progress = tonumber(a.Progress) or 0
			local percent = math.clamp(math.floor(progress / math.max(goal, 1) * 100), 0, 100)
			local rewardText = ""
			if typeof(a.Reward) == "table" then
				local parts: { string } = {}
				if typeof(a.Reward.Coins) == "number" and a.Reward.Coins > 0 then
					table.insert(parts, "🪙 " .. tostring(a.Reward.Coins))
				end
				if typeof(a.Reward.Gems) == "number" and a.Reward.Gems > 0 then
					table.insert(parts, "💎 " .. tostring(a.Reward.Gems))
				end
				rewardText = table.concat(parts, "  •  ")
			end
			if typeof(a.Title) == "string" and a.Title ~= "" then
				rewardText ..= (if rewardText ~= "" then "  •  " else "") .. "🏆 " .. a.Title
			end
			local row = buildRow(
				(if a.Unlocked == true then "🏆 " else "🔒 ") .. tostring(a.Name or "?"),
				tostring(a.Description or "") .. "  •  " .. tostring(progress) .. "/" .. tostring(goal) .. " (" .. tostring(percent) .. "%)",
				rewardText,
				if a.Unlocked == true then "DONE ✓" else "…",
				if a.Unlocked == true then Color3.fromRGB(40, 160, 90) else Color3.fromRGB(70, 70, 90),
				function()
					if a.Unlocked == true then
						setStatus(tostring(a.Name) .. " is unlocked — reward already paid by the server.")
					else
						setStatus(tostring(a.Name) .. ": " .. tostring(progress) .. " of " .. tostring(goal) .. " done.")
					end
				end
			)
			row.Parent = contentFrame
		end
	end
end

local function rebuildTitles()
	clearContent()
	local titles: { any } = {}
	if typeof(data) == "table" and typeof(data.Titles) == "table" then
		titles = data.Titles
	end
	if #titles == 0 then
		note("No titles earned yet — titles come from achievements and from Prestige. Keep playing!")
		return
	end
	local equipped = AchievementController.GetEquippedTitle()
	local warn = PanelKit.MakeLabel(contentFrame, "Equipping a title saves it to your profile — it shows in the HUD and persists across sessions.", 12, Color3.fromRGB(120, 220, 140), false)
	warn.Size = UDim2.new(1, -16, 0, 44)
	warn.Position = UDim2.new(0, 8, 0, 8)
	for _, titleId in titles do
		local id = tostring(titleId)
		local isEquipped = equipped == id
		local row = buildRow(
			"🏆 " .. id,
			"Title earned from an achievement or Prestige.",
			"",
			if isEquipped then "EQUIPPED ✓" else "EQUIP",
			if isEquipped then Color3.fromRGB(40, 160, 90) else Color3.fromRGB(90, 70, 160),
			function()
				if isEquipped then
					setStatus("Title " .. id .. " is already equipped (this session).")
					return
				end
				if not PanelKit.Debounce("title:equip", 1) then
					return
				end
				local fired = PanelKit.FireServerChecked("EquipTitle", 0, { TitleId = id })
				-- Equip locally for immediate feedback; the server
				-- handler (AchievementService, wired at integration)
				-- validates ownership and persists it.
				localEquippedTitle = id
				pcall(function()
					local mod = script.Parent:FindFirstChild("HUDController")
					if mod then
						local hud = require(mod)
						if hud.SetEquippedTitle then
							hud.SetEquippedTitle(id)
						end
					end
				end)
				AchievementController.Rebuild()
				if fired then
					setStatus("Title " .. id .. " equipped — saved to your profile.")
				else
					setStatus("Title " .. id .. " equipped locally — the EquipTitle remote is not available yet, so the server was not told.", true)
				end
				playSound("click")
			end
		)
		row.Parent = contentFrame
	end
end

function AchievementController.Rebuild()
	if activeTab == "Titles" then
		rebuildTitles()
	else
		rebuildAchievements()
	end
end

function AchievementController.SetTab(tab: string)
	activeTab = tab
	AchievementController.Rebuild()
end

function AchievementController.RefreshFromServer()
	local ok, result = PanelKit.InvokeChecked("RequestAchievements")
	if ok and typeof(result) == "table" then
		data = result
		if typeof(result.EquippedTitle) == "string" and result.EquippedTitle ~= "" then
			localEquippedTitle = result.EquippedTitle
		end
		setStatus("Achievements loaded.")
	else
		data = nil
		setStatus("Achievement data is not available from the server yet.", true)
	end
	AchievementController.Rebuild()
end

function AchievementController.ApplyAchievementUnlocked(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local name = tostring(payload.Name or payload.Id or "an achievement")
	local rewardText = ""
	if typeof(payload.Reward) == "table" then
		local parts: { string } = {}
		if typeof(payload.Reward.Coins) == "number" and payload.Reward.Coins > 0 then
			table.insert(parts, "🪙 " .. tostring(payload.Reward.Coins))
		end
		if typeof(payload.Reward.Gems) == "number" and payload.Reward.Gems > 0 then
			table.insert(parts, "💎 " .. tostring(payload.Reward.Gems))
		end
		rewardText = table.concat(parts, "  •  ")
	end
	if typeof(payload.Title) == "string" and payload.Title ~= "" then
		rewardText ..= (if rewardText ~= "" then "  •  " else "") .. "🏆 Title: " .. payload.Title
	end
	PanelKit.ShowBanner("🏆 Achievement unlocked: " .. name .. (if rewardText ~= "" then " — " .. rewardText else ""), 8)
	setStatus("Achievement unlocked: " .. name .. "!")
	playSound("achievement")
	AchievementController.RefreshFromServer()
end

-- SecretDiscovered: the payload carries NO secret id or name, so the
-- banner is generic by design. Never print a secret id here — the
-- server deliberately does not send one.
function AchievementController.ApplySecretDiscovered(payload: any)
	_ = payload
	setStatus("Something hidden was found… the Memeverse keeps its secrets.")
	PanelKit.ShowBanner("✨ You discovered something hidden…", 8)
	playSound("secret")
end

function AchievementController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	AchievementController.RefreshFromServer()
end

function AchievementController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function AchievementController.Toggle()
	if isOpen then
		AchievementController.Close()
	else
		AchievementController.Open()
	end
end

function AchievementController.IsOpen(): boolean
	return isOpen
end

function AchievementController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Achievements"
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
	pStroke.Color = Color3.fromRGB(255, 215, 0)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = PanelKit.MakeLabel(panel, "🏆  ACHIEVEMENTS", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 300, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	PanelKit.MakeButton(panel, "✕", UDim2.new(0, 36, 0, 30), UDim2.new(1, -48, 0, 10), Color3.fromRGB(200, 60, 60), function()
		AchievementController.Close()
	end)

	statusLabel = PanelKit.MakeLabel(panel, "24 achievements, 13 titles — earned by playing, not by buying.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	local tabButtons: { [string]: TextButton } = {}
	for i, tab in { "Achievements", "Titles" } do
		local btn = PanelKit.MakeButton(panel, string.upper(tab), UDim2.new(0, 130, 0, 30), UDim2.new(0, 16 + (i - 1) * 138, 0, 66), if tab == activeTab then Color3.fromRGB(90, 70, 160) else Color3.fromRGB(50, 48, 80), function()
			for name, b in tabButtons do
				b.BackgroundColor3 = if name == tab then Color3.fromRGB(90, 70, 160) else Color3.fromRGB(50, 48, 80)
			end
			AchievementController.SetTab(tab)
		end)
		btn.Name = "Tab_" .. tab
		tabButtons[tab] = btn
	end

	contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Name = "Content"
	contentFrame.Size = UDim2.new(1, -24, 1, -116)
	contentFrame.Position = UDim2.new(0, 12, 0, 106)
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

	PanelKit.Listen("AchievementUnlocked", function(payload: any)
		AchievementController.ApplyAchievementUnlocked(payload)
	end)
	PanelKit.Listen("SecretDiscovered", function(payload: any)
		AchievementController.ApplySecretDiscovered(payload)
	end)

	AchievementController.Rebuild()
	print("[GlitchTide] AchievementController ready")
end

return AchievementController
