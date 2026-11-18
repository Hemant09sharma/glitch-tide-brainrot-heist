--!strict
-- QuestController.luau
-- Quest list for GLITCH TIDE. Live data arrives two ways: QuestUpdate
-- pushes from QuestService (ClaimQuest is wired server-side and
-- pushProgress fires on quest events / claims, plus a push shortly
-- after join) and the RequestQuests RemoteFunction, wired in
-- QuestService.Init to QuestService.GetQuests (v1.0.1 integration QA).
-- While no live data has arrived, the panel shows a real preview of
-- the intended quest line (local, clearly labelled as "coming soon")
-- and a RETRY button that re-runs the lookup. Toggle: J key, or the
-- "QUESTS" button on the HUD menu bar. The HUD quest tracker reads
-- GetTopQuest() from here (nil while preview-only, so the HUD shows
-- no fake quest).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local QuestController = {}

local gui: ScreenGui? = nil
local listFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local quests: { any } = {}
local liveMode = false
-- Claim debounce (v1.1 E, Part 13 duplicate prevention): the server
-- pays a claim once, but a double-click used to fire ClaimQuest twice
-- before the refresh landed. Last claim time per quest id; repeats
-- inside 2s are ignored client-side.
local claimCooldowns: { [string]: number } = {}

-- Local preview line, shown ONLY while the server has no quest system.
-- Labelled "coming soon" so it is never mistaken for live progress.
local PREVIEW_QUESTS: { { id: string, title: string, desc: string, progress: number, goal: number, reward: string } } = {
	{ id = "preview_first_buy", title = "First Catch", desc = "Buy your first Brainrot from the conveyor.", progress = 0, goal = 1, reward = "100 coins" },
	{ id = "preview_base_3", title = "Growing Empire", desc = "Place 3 Brainrots in your base.", progress = 0, goal = 3, reward = "150 coins" },
	{ id = "preview_earn_1000", title = "Money Printer", desc = "Bank 1,000 coins of income in your base.", progress = 0, goal = 1000, reward = "200 coins" },
	{ id = "preview_steal_1", title = "Sticky Fingers", desc = "Steal a Brainrot from another player's base.", progress = 0, goal = 1, reward = "250 coins" },
	{ id = "preview_tide", title = "Tide Survivor", desc = "Survive a full Glitch Tide event.", progress = 0, goal = 1, reward = "300 coins" },
}

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

local function questProgress(q: any): (number, number)
	local progress = q.Progress or q.progress or q.Current or q.current or 0
	local goal = q.Goal or q.goal or q.Target or q.target or 1
	if typeof(progress) ~= "number" then
		progress = 0
	end
	if typeof(goal) ~= "number" or goal <= 0 then
		goal = 1
	end
	return progress, goal
end

local function isClaimable(q: any): boolean
	if q.Claimed == true or q.claimed == true then
		return false
	end
	if q.CanClaim == true or q.canClaim == true or q.Completed == true or q.completed == true then
		return true
	end
	local progress, goal = questProgress(q)
	return progress >= goal
end

local function buildRow(q: any): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 78)
	row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	row.BorderSizePixel = 0
	corner(row, 10)

	local titleLabel = makeLabel(row, tostring(q.Title or q.title or q.Name or "Quest"), 14, Color3.fromRGB(255, 255, 255), true)
	titleLabel.Size = UDim2.new(1, -130, 0, 20)
	titleLabel.Position = UDim2.new(0, 12, 0, 6)
	local descLabel = makeLabel(row, tostring(q.Description or q.description or q.Desc or ""), 11, Color3.fromRGB(190, 200, 220), false)
	descLabel.Size = UDim2.new(1, -130, 0, 18)
	descLabel.Position = UDim2.new(0, 12, 0, 28)

	local progress, goal = questProgress(q)
	local barBg = Instance.new("Frame")
	barBg.Size = UDim2.new(1, -130, 0, 10)
	barBg.Position = UDim2.new(0, 12, 0, 52)
	barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 60)
	barBg.BorderSizePixel = 0
	barBg.Parent = row
	corner(barBg, 5)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(math.clamp(progress / goal, 0, 1), 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(90, 200, 90)
	fill.BorderSizePixel = 0
	fill.Parent = barBg
	corner(fill, 5)

	local progressLabel = makeLabel(row, tostring(math.floor(progress)) .. " / " .. tostring(goal), 11, Color3.fromRGB(200, 220, 255), true)
	progressLabel.Size = UDim2.new(0, 100, 0, 16)
	progressLabel.Position = UDim2.new(1, -118, 0, 48)
	progressLabel.TextXAlignment = Enum.TextXAlignment.Right

	local reward = q.Reward or q.reward or ""
	local claimBtn = Instance.new("TextButton")
	claimBtn.Size = UDim2.new(0, 96, 0, 30)
	claimBtn.Position = UDim2.new(1, -108, 0, 8)
	claimBtn.Font = Enum.Font.GothamBold
	claimBtn.TextSize = 12
	claimBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	claimBtn.BorderSizePixel = 0
	corner(claimBtn, 8)
	claimBtn.Parent = row
	if not liveMode then
		-- Preview-only: the button is NOT dead — it retries the live
		-- lookup (the server may have started serving quests since the
		-- panel opened). The old "SOON" button had no handler at all.
		claimBtn.Text = "↻ RETRY"
		claimBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
		claimBtn.MouseButton1Click:Connect(function()
			QuestController.Refresh()
		end)
	elseif q.Claimed == true or q.claimed == true then
		claimBtn.Text = "✓ DONE"
		claimBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 70)
		claimBtn.AutoButtonColor = false
	elseif isClaimable(q) then
		claimBtn.Text = "CLAIM" .. (if reward ~= "" then " 🎁" else "")
		claimBtn.BackgroundColor3 = Color3.fromRGB(200, 150, 30)
		claimBtn.MouseButton1Click:Connect(function()
			QuestController.Claim(q.Id or q.id)
		end)
	else
		claimBtn.Text = tostring(reward)
		claimBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
		claimBtn.AutoButtonColor = false
	end
	return row
end

function QuestController.Rebuild()
	if not listFrame then
		return
	end
	for _, child in listFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local source = if liveMode then quests else PREVIEW_QUESTS
	if #source == 0 then
		local note = makeLabel(listFrame, "No quests right now — check back after the next tide.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	-- Grouped by Category (v1.1 E): story / daily / weekly / expedition
	-- / territory / secret / … in first-seen order, with a header per
	-- group so a 54-quest list stays scannable.
	local categories: { string } = {}
	local byCategory: { [string]: { any } } = {}
	for _, q in source do
		local category = tostring(q.Category or q.category or "general")
		if byCategory[category] == nil then
			byCategory[category] = {}
			table.insert(categories, category)
		end
		table.insert(byCategory[category], q)
	end
	for _, category in categories do
		local header = makeLabel(listFrame, "— " .. string.upper(category) .. " —", 13, Color3.fromRGB(255, 215, 0), true)
		header.Size = UDim2.new(1, -16, 0, 20)
		header.Position = UDim2.new(0, 8, 0, 8)
		for _, q in byCategory[category] do
			buildRow(q).Parent = listFrame
		end
	end
end

function QuestController.ApplyQuests(payload: any)
	local list: any = nil
	if typeof(payload) == "table" then
		list = payload.Quests or payload.quests or payload
	end
	if typeof(list) == "table" and typeof(list[1]) == "table" then
		quests = list
		liveMode = true
		setStatus("Live quests from the server.")
		QuestController.Rebuild()
		pcall(function()
			local mod = script.Parent:FindFirstChild("HUDController")
			if mod then
				local hud = require(mod)
				if hud.RefreshQuestTracker then
					hud.RefreshQuestTracker()
				end
			end
		end)
	end
end

function QuestController.GetTopQuest(): any?
	if liveMode then
		for _, q in quests do
			if not (q.Claimed == true or q.claimed == true) then
				return q
			end
		end
		return nil
	end
	-- Preview-only: return nil so the HUD tracker hides instead of
	-- showing a fake "First Catch 0/1" quest that is not real progress.
	return nil
end

function QuestController.IsLive(): boolean
	return liveMode
end

function QuestController.Claim(questId: any)
	local folder = getRemotesFolder()
	local remote = folder and folder:FindFirstChild("ClaimQuest")
	if not remote or not remote:IsA("RemoteEvent") then
		setStatus("ClaimQuest remote is not available yet.", true)
		return
	end
	local id = tostring(questId or "")
	local now = os.clock()
	if now - (claimCooldowns[id] or 0) < 2 then
		return -- double-click guard: the claim is already in flight
	end
	claimCooldowns[id] = now
	setStatus("Claiming reward — waiting for the server…")
	pcall(function()
		(remote :: RemoteEvent):FireServer(questId)
	end)
	task.delay(1.5, function()
		QuestController.Refresh()
	end)
end

function QuestController.Refresh()
	local folder = getRemotesFolder()
	if not folder then
		return
	end
	local requestRemote = folder:FindFirstChild("RequestQuests")
	-- WAVE 3 (v1.1 E) FIX: the old first branch fired RequestQuests
	-- as a RemoteEvent — RequestQuests is a RemoteFunction and has no
	-- event handler, so that fire was dead (audit F1). Only the
	-- function branch remains.
	if requestRemote and requestRemote:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (requestRemote :: RemoteFunction):InvokeServer()
			end)
			if ok then
				QuestController.ApplyQuests(result)
			else
				-- InvokeServer failed (server unreachable / handler
				-- error). Live quests can still arrive via QuestUpdate
				-- pushes (server fires those on quest events, claims
				-- and shortly after join).
				liveMode = false
				setStatus("Could not fetch quests from the server — live quests will appear here when the server pushes them.", true)
				QuestController.Rebuild()
			end
		end)
	else
		liveMode = false
		setStatus("Quest system is not live on the server yet — showing the coming quest line.")
		QuestController.Rebuild()
	end
end

function QuestController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	QuestController.Refresh()
end

function QuestController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function QuestController.Toggle()
	if isOpen then
		QuestController.Close()
	else
		QuestController.Open()
	end
end

function QuestController.IsOpen(): boolean
	return isOpen
end

function QuestController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Quests"
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
	pStroke.Color = Color3.fromRGB(255, 200, 40)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = makeLabel(panel, "📜  QUESTS", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 200, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	local refreshBtn = Instance.new("TextButton")
	refreshBtn.Name = "RefreshButton"
	refreshBtn.Size = UDim2.new(0, 90, 0, 30)
	refreshBtn.Position = UDim2.new(1, -148, 0, 10)
	refreshBtn.Text = "↻ REFRESH"
	refreshBtn.Font = Enum.Font.GothamBold
	refreshBtn.TextSize = 12
	refreshBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	refreshBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
	refreshBtn.BorderSizePixel = 0
	corner(refreshBtn, 8)
	refreshBtn.Parent = panel
	refreshBtn.MouseButton1Click:Connect(function()
		QuestController.Refresh()
	end)

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
		QuestController.Close()
	end)

	statusLabel = makeLabel(panel, "Loading quests…", 12, Color3.fromRGB(200, 220, 255), false)
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

	-- Live quest pushes from QuestService (QuestUpdate).
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild("QuestUpdate", 10)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				QuestController.ApplyQuests(payload)
			end)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.J then
			QuestController.Toggle()
		end
	end)

	QuestController.Refresh()
	print("[GlitchTide] QuestController ready (live via QuestUpdate pushes + RequestQuests fetch)")
end

return QuestController
