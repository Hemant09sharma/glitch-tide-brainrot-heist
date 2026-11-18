--!strict
-- BaseController.luau
-- Personal base panel for GLITCH TIDE: income/sec, banked income with a
-- Collect button (CollectIncome), slots used/total, upgrade buttons
-- (UpgradeBase), the placed-Brainrots list, a Rebirth button (Rebirth
-- remote, {Action="Rebirth"}; requirements shown from
-- Config.RebirthRequirements), a Prestige button (same remote,
-- {Action="Prestige"}; documented requirements, server-validated),
-- and the steal-alert banner.
-- State comes from BaseUpdate pushes and RequestBase (RemoteFunction);
-- every action is a server-validated request, and results are only shown
-- when the server pushes back. Toggle: V key, or the "BASE" button on
-- the HUD menu bar. StealAlert shows a red banner + alarm sound + a
-- "Return to base" hint for 8 seconds. Wave 3 (v1.1 E) fixed the
-- StealAlert parsing (the real payload is {Thief, ThiefUserId,
-- Victim, CharacterId, Phase}) and removed the dead FireServer
-- ("GetBase") branch — RequestBase is a function, not an event.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local BaseController = {}

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
local incomeLabel: TextLabel? = nil
local bankedLabel: TextLabel? = nil
local slotsLabel: TextLabel? = nil
local placedFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local stealBanner: Frame? = nil
local stealLabel: TextLabel? = nil
local isOpen = false
local baseState: any = nil
local placedList: { any } = {}
local pendingCollect = false

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

local function playSound(name: string)
	pcall(function()
		local mod = script.Parent:FindFirstChild("SoundController")
		if mod then
			local sound = require(mod)
			if name == "stealAlarm" and sound.PlayStealAlarm then
				sound.PlayStealAlarm()
			elseif name == "coin" and sound.PlayCoin then
				sound.PlayCoin()
			elseif name == "upgrade" and sound.PlayUpgrade then
				sound.PlayUpgrade()
			end
		end
	end)
end

local function incomeOf(placed: any): number
	if typeof(placed.IncomePerSec) == "number" then
		return placed.IncomePerSec
	end
	if typeof(placed.incomePerSec) == "number" then
		return placed.incomePerSec
	end
	if Characters and Characters.GetById and typeof(placed.CharacterId) == "string" then
		local def = Characters.GetById(placed.CharacterId)
		if def then
			return def.IncomePerSec or 0
		end
	end
	return 0
end

function BaseController.ApplyBaseUpdate(data: any)
	if typeof(data) ~= "table" then
		return
	end
	baseState = data
	local placed = data.Placed or data.placed or data.Brainrots
	if typeof(placed) == "table" then
		placedList = placed
	end
	if incomeLabel then
		local income = data.IncomePerSec or data.incomePerSec
		if typeof(income) ~= "number" then
			local total = 0
			for _, p in placedList do
				total += incomeOf(p)
			end
			income = total
		end
		incomeLabel.Text = "Income: +" .. string.format("%.1f", income) .. "/s"
	end
	if bankedLabel then
		local banked = data.Banked or data.BankedIncome or data.bankedIncome or data.BankedCoins or 0
		bankedLabel.Text = "Banked: 🪙 " .. tostring(math.floor((banked :: number) + 0.5))
	end
	if slotsLabel then
		local used = data.SlotsUsed or data.slotsUsed or #placedList
		local total = data.SlotsTotal or data.Slots or data.slotsTotal or data.MaxSlots or 0
		slotsLabel.Text = "Slots: " .. tostring(used) .. " / " .. tostring(total)
	end
	if pendingCollect then
		pendingCollect = false
		setStatus("Income collected!")
		playSound("coin")
	end
	BaseController.RebuildPlaced()
	-- Keep the shop's upgrade rows in sync with the new base state.
	pcall(function()
		local mod = script.Parent:FindFirstChild("ShopController")
		if mod then
			local shop = require(mod)
			if shop.OnBaseUpdate then
				shop.OnBaseUpdate(data)
			end
		end
	end)
end

function BaseController.GetPlaced(): { any }
	return placedList
end

function BaseController.GetBaseState(): any
	return baseState
end

function BaseController.RebuildPlaced()
	if not placedFrame then
		return
	end
	for _, child in placedFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	if #placedList == 0 then
		local note = makeLabel(placedFrame, "Your base is empty. Buy a Brainrot on the conveyor, carry it home, and place it here to start earning.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 48)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	for _, placed in placedList do
		local charId = placed.CharacterId or placed.characterId or placed.Id
		local def: any = nil
		if Characters and Characters.GetById and typeof(charId) == "string" then
			def = Characters.GetById(charId)
		end
		local name = def and (def.DisplayName or def.Name) or tostring(placed.Name or charId or "?")
		local level = placed.Level or placed.level or 1
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -12, 0, 48)
		row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
		row.BorderSizePixel = 0
		corner(row, 10)
		local stroke = Instance.new("UIStroke")
		stroke.Color = RarityColors.Get(def and def.Rarity or "Common")
		stroke.Thickness = 2
		stroke.Parent = row
		local nameLabel = makeLabel(row, name .. "  •  Lv " .. tostring(level), 13, Color3.fromRGB(255, 255, 255), true)
		nameLabel.Size = UDim2.new(1, -220, 0, 20)
		nameLabel.Position = UDim2.new(0, 12, 0, 5)
		local subLabel = makeLabel(
			row,
			"+" .. string.format("%.1f", incomeOf(placed)) .. "/s" .. (if placed.Glitched then "  •  ✨ Glitched (2x)" else ""),
			11,
			Color3.fromRGB(190, 200, 220),
			false
		)
		subLabel.Size = UDim2.new(1, -220, 0, 16)
		subLabel.Position = UDim2.new(0, 12, 0, 27)
		local upBtn = Instance.new("TextButton")
		upBtn.Size = UDim2.new(0, 96, 0, 28)
		upBtn.Position = UDim2.new(1, -108, 0, 10)
		upBtn.Text = "LEVEL UP"
		upBtn.Font = Enum.Font.GothamBold
		upBtn.TextSize = 12
		upBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		upBtn.BackgroundColor3 = Color3.fromRGB(60, 160, 90)
		upBtn.BorderSizePixel = 0
		corner(upBtn, 8)
		upBtn.Parent = row
		upBtn.MouseButton1Click:Connect(function()
			local remote = getRemote(remoteName("UpgradeBrainrot", "UpgradeBrainrot"))
			if not remote or not remote:IsA("RemoteEvent") then
				setStatus("UpgradeBrainrot remote is not available yet.", true)
				return
			end
			-- The server matches placed records on InstanceId (a GUID),
			-- NOT CharacterId. The old code sent the CharacterId, so
			-- every level-up was rejected with "brainrot not placed".
			local instanceId = placed.InstanceId or placed.instanceId
			if typeof(instanceId) ~= "string" or instanceId == "" then
				setStatus("That Brainrot has no server id yet — reopen the panel to refresh.", true)
				return
			end
			setStatus("Sent level-up for " .. name .. " — waiting for the server…")
			playSound("upgrade")
			pcall(function()
				(remote :: RemoteEvent):FireServer(instanceId)
			end)
		end)
		row.Parent = placedFrame
	end
end

-- Rebirth: reset coins + Brainrot levels for gems and a permanent income
-- bonus. The server (ProgressionService) re-validates the requirements;
-- the client only displays them from Config.RebirthRequirements.
function BaseController.Rebirth()
	local remote = getRemote(remoteName("Rebirth", "Rebirth"))
	if not remote or not remote:IsA("RemoteEvent") then
		setStatus("Rebirth remote is not available yet.", true)
		return
	end
	setStatus("Requesting rebirth — waiting for the server…")
	playSound("upgrade")
	pcall(function()
		(remote :: RemoteEvent):FireServer({ Action = "Rebirth" })
	end)
	task.delay(5, function()
		BaseController.RefreshFromServer()
	end)
end

-- Prestige (v1.1 E, Workstream C): the endgame reset on the same
-- Rebirth remote, envelope {Action="Prestige"}. Requirements are
-- documented in QA_V11_C §2 Part 7 (10 rebirths, Level 25, 250,000
-- coins, 15 distinct Brainrots); the server re-validates them, so
-- the client shows them and lets the server answer. Grants +50 gems,
-- the title_prestiged title, +5% income/rank.
function BaseController.Prestige()
	local remote = getRemote(remoteName("Rebirth", "Rebirth"))
	if not remote or not remote:IsA("RemoteEvent") then
		setStatus("Rebirth remote is not available yet.", true)
		return
	end
	setStatus("Requesting prestige — the server checks the requirements…")
	playSound("upgrade")
	pcall(function()
		(remote :: RemoteEvent):FireServer({ Action = "Prestige" })
	end)
	task.delay(5, function()
		BaseController.RefreshFromServer()
	end)
end

function BaseController.Collect()
	local remote = getRemote(remoteName("CollectIncome", "CollectIncome"))
	if not remote or not remote:IsA("RemoteEvent") then
		setStatus("CollectIncome remote is not available yet.", true)
		return
	end
	pendingCollect = true
	setStatus("Collecting income — waiting for the server…")
	pcall(function()
		(remote :: RemoteEvent):FireServer()
	end)
	task.delay(5, function()
		if pendingCollect then
			pendingCollect = false
			setStatus("No reply from the server for Collect — check your coins.", true)
		end
	end)
end

function BaseController.RefreshFromServer()
	local baseFn = getRemote(remoteName("RequestBase", "RequestBase"))
	if baseFn and baseFn:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (baseFn :: RemoteFunction):InvokeServer()
			end)
			if ok and typeof(result) == "table" then
				BaseController.ApplyBaseUpdate(result)
			else
				setStatus("Could not load base data from the server.", true)
			end
		end)
	else
		-- WAVE 3 (v1.1 E) FIX: the old elseif branch fired "GetBase"
		-- on RequestBase as a RemoteEvent — RequestBase is a
		-- RemoteFunction and has no event handler, so the fire was
		-- dead (audit F1). Removed, not replaced.
		setStatus("RequestBase remote is not available yet.", true)
	end
end

-- StealAlert ACTUAL payload (v1.1 E fix — the old parsing read
-- ThiefName / CharacterName / BrainrotName / Name, none of which
-- exist, so the banner always showed "Someone" / "a Brainrot"):
--   {Thief, ThiefUserId, Victim, CharacterId, Phase}
--   Phase = Started | Success | Failed | Returned | Delivered
-- plus a Lockdown variant {Victim, Phase="Lockdown", Duration}.
-- This banner is the VICTIM side (Victim == LocalPlayer). The thief
-- side is handled by InteractionController.ApplyStealAlert.
function BaseController.ShowStealAlert(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local phase = tostring(payload.Phase or "")
	local victim = tostring(payload.Victim or "")
	if victim ~= "" and victim ~= LocalPlayer.Name then
		-- Not our base — the thief-side prompt lives in
		-- InteractionController; this banner is victim-only.
		return
	end
	local thief = tostring(payload.Thief or "Someone")
	local what = "a Brainrot"
	local charId = payload.CharacterId
	if typeof(charId) == "string" and Characters and Characters.GetById then
		local ok, def = pcall(function()
			return Characters.GetById(charId)
		end)
		if ok and def then
			what = tostring(def.DisplayName or def.Name or charId)
		end
	end
	if phase == "Lockdown" then
		if stealLabel then
			stealLabel.Text = "🔒 Your base is on lockdown for " .. tostring(payload.Duration or "?") .. "s!"
		end
		setStatus("Your base is on lockdown.", true)
	elseif phase == "Started" then
		if stealLabel then
			stealLabel.Text = "⚠ " .. thief .. " is stealing " .. what .. " from your base!  •  Return to base!"
		end
		setStatus("Your base is being robbed — get back there!", true)
	elseif phase == "Success" or phase == "Delivered" then
		if stealLabel then
			stealLabel.Text = "💀 " .. thief .. " stole " .. what .. " from your base!"
		end
		setStatus(thief .. " stole " .. what .. " from your base.", true)
	elseif phase == "Failed" or phase == "Returned" then
		if stealLabel then
			stealLabel.Text = "✅ The steal of " .. what .. " was stopped!"
		end
		setStatus("The steal attempt was stopped.")
	else
		return
	end
	if stealBanner then
		stealBanner.Visible = true
	end
	playSound("stealAlarm")
	task.delay(8, function()
		if stealBanner then
			stealBanner.Visible = false
		end
	end)
end

function BaseController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	BaseController.RefreshFromServer()
end

function BaseController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function BaseController.Toggle()
	if isOpen then
		BaseController.Close()
	else
		BaseController.Open()
	end
end

function BaseController.IsOpen(): boolean
	return isOpen
end

function BaseController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	-- Steal banner lives in its own ScreenGui so it shows even when the
	-- base panel is closed.
	local bannerGui = Instance.new("ScreenGui")
	bannerGui.Name = "StealAlert"
	bannerGui.ResetOnSpawn = false
	bannerGui.DisplayOrder = 40
	bannerGui.Parent = playerGui
	stealBanner = Instance.new("Frame")
	stealBanner.Name = "Banner"
	stealBanner.AnchorPoint = Vector2.new(0.5, 0)
	stealBanner.Position = UDim2.new(0.5, 0, 0, 64)
	stealBanner.Size = UDim2.new(0, 520, 0, 44)
	stealBanner.BackgroundColor3 = Color3.fromRGB(180, 20, 20)
	stealBanner.BorderSizePixel = 0
	stealBanner.Visible = false
	stealBanner.Parent = bannerGui
	corner(stealBanner, 10)
	stealLabel = makeLabel(stealBanner, "", 14, Color3.fromRGB(255, 255, 255), true)
	stealLabel.Size = UDim2.new(1, -16, 1, 0)
	stealLabel.Position = UDim2.new(0, 8, 0, 0)
	stealLabel.TextXAlignment = Enum.TextXAlignment.Center

	gui = Instance.new("ScreenGui")
	gui.Name = "BasePanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 560, 0, 470)
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 36)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(90, 200, 90)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = makeLabel(panel, "🏠  MY BASE", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 200, 0, 30)
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
		BaseController.Close()
	end)

	statusLabel = makeLabel(panel, "Your empire, earning while you fight.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	-- Stats row.
	local statsRow = Instance.new("Frame")
	statsRow.Size = UDim2.new(1, -32, 0, 74)
	statsRow.Position = UDim2.new(0, 16, 0, 66)
	statsRow.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	statsRow.BorderSizePixel = 0
	statsRow.Parent = panel
	corner(statsRow, 10)

	incomeLabel = makeLabel(statsRow, "Income: +0.0/s", 15, Color3.fromRGB(120, 220, 120), true)
	incomeLabel.Size = UDim2.new(0.5, -12, 0, 22)
	incomeLabel.Position = UDim2.new(0, 12, 0, 8)
	bankedLabel = makeLabel(statsRow, "Banked: 🪙 0", 15, Color3.fromRGB(255, 215, 0), true)
	bankedLabel.Size = UDim2.new(0.5, -12, 0, 22)
	bankedLabel.Position = UDim2.new(0.5, 0, 0, 8)
	slotsLabel = makeLabel(statsRow, "Slots: 0 / 0", 13, Color3.fromRGB(200, 210, 230), true)
	slotsLabel.Size = UDim2.new(0.5, -12, 0, 20)
	slotsLabel.Position = UDim2.new(0, 12, 0, 38)

	local collectBtn = Instance.new("TextButton")
	collectBtn.Name = "CollectButton"
	collectBtn.Size = UDim2.new(0, 130, 0, 32)
	collectBtn.Position = UDim2.new(1, -142, 0, 32)
	collectBtn.Text = "💰 COLLECT"
	collectBtn.Font = Enum.Font.GothamBold
	collectBtn.TextSize = 14
	collectBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	collectBtn.BackgroundColor3 = Color3.fromRGB(200, 150, 30)
	collectBtn.BorderSizePixel = 0
	corner(collectBtn, 8)
	collectBtn.Parent = statsRow
	collectBtn.MouseButton1Click:Connect(function()
		BaseController.Collect()
	end)

	-- Upgrade shortcuts (full list lives in the Shop).
	local upgradeLabel = makeLabel(panel, "Quick upgrades (full list in the Shop — B):", 12, Color3.fromRGB(200, 220, 255), true)
	upgradeLabel.Size = UDim2.new(1, -32, 0, 18)
	upgradeLabel.Position = UDim2.new(0, 16, 0, 148)
	local quickKinds = { "BaseSlot", "IncomeMultiplier" }
	for i, kind in quickKinds do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(0, 150, 0, 30)
		btn.Position = UDim2.new(0, 16 + (i - 1) * 160, 0, 170)
		btn.Text = if kind == "BaseSlot" then "+1 BASE SLOT" else "INCOME BOOST"
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 12
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
		btn.BorderSizePixel = 0
		corner(btn, 8)
		btn.Parent = panel
		btn.MouseButton1Click:Connect(function()
			local remote = getRemote(remoteName("UpgradeBase", "UpgradeBase"))
			if not remote or not remote:IsA("RemoteEvent") then
				setStatus("UpgradeBase remote is not available yet.", true)
				return
			end
			setStatus("Sent " .. kind .. " upgrade — waiting for the server…")
			playSound("upgrade")
			pcall(function()
				(remote :: RemoteEvent):FireServer(kind)
			end)
		end)
	end

	-- Rebirth row: requirements from Config, button fires the Rebirth
	-- remote ({Action="Rebirth"}). There was no Rebirth button anywhere
	-- on the client before this — the server handler existed, unwired.
	local reqs = Config and Config.RebirthRequirements or {}
	local rebirthText = "Rebirth: Lv " .. tostring(reqs.Level or 25)
		.. "  •  🪙 " .. tostring(reqs.Coins or 100000)
		.. "  •  " .. tostring(reqs.Brainrots or 10) .. " Brainrots"
		.. "  →  +" .. tostring(reqs.RewardGems or 25) .. " 💎, +"
		.. tostring(math.floor(((reqs.IncomeBonusPerRebirth or 0.10) * 100) + 0.5))
		.. "% income forever"
	local rebirthLabel = makeLabel(panel, rebirthText, 11, Color3.fromRGB(200, 220, 255), true)
	rebirthLabel.Size = UDim2.new(1, -170, 0, 30)
	rebirthLabel.Position = UDim2.new(0, 16, 0, 204)
	rebirthLabel.TextYAlignment = Enum.TextYAlignment.Top
	local rebirthBtn = Instance.new("TextButton")
	rebirthBtn.Name = "RebirthButton"
	rebirthBtn.Size = UDim2.new(0, 130, 0, 30)
	rebirthBtn.Position = UDim2.new(1, -146, 0, 204)
	rebirthBtn.Text = "♻ REBIRTH"
	rebirthBtn.Font = Enum.Font.GothamBold
	rebirthBtn.TextSize = 13
	rebirthBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	rebirthBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 200)
	rebirthBtn.BorderSizePixel = 0
	corner(rebirthBtn, 8)
	rebirthBtn.Parent = panel
	rebirthBtn.MouseButton1Click:Connect(function()
		BaseController.Rebirth()
	end)

	-- Prestige row (v1.1 E): same Rebirth remote, {Action="Prestige"}.
	-- Requirements are the documented ones (QA_V11_C §2 Part 7);
	-- the server validates them and answers via RebirthUpdate.
	local prestigeText = "Prestige: 10 rebirths  •  Lv 25  •  🪙 250,000  •  15 distinct Brainrots"
		.. "  →  +50 💎, title_prestiged, +5% income/rank"
	local prestigeLabel = makeLabel(panel, prestigeText, 11, Color3.fromRGB(255, 220, 120), true)
	prestigeLabel.Size = UDim2.new(1, -170, 0, 30)
	prestigeLabel.Position = UDim2.new(0, 16, 0, 236)
	prestigeLabel.TextYAlignment = Enum.TextYAlignment.Top
	local prestigeBtn = Instance.new("TextButton")
	prestigeBtn.Name = "PrestigeButton"
	prestigeBtn.Size = UDim2.new(0, 130, 0, 30)
	prestigeBtn.Position = UDim2.new(1, -146, 0, 236)
	prestigeBtn.Text = "👑 PRESTIGE"
	prestigeBtn.Font = Enum.Font.GothamBold
	prestigeBtn.TextSize = 13
	prestigeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	prestigeBtn.BackgroundColor3 = Color3.fromRGB(200, 150, 30)
	prestigeBtn.BorderSizePixel = 0
	corner(prestigeBtn, 8)
	prestigeBtn.Parent = panel
	prestigeBtn.MouseButton1Click:Connect(function()
		BaseController.Prestige()
	end)

	local placedTitle = makeLabel(panel, "Placed Brainrots:", 13, Color3.fromRGB(255, 255, 255), true)
	placedTitle.Size = UDim2.new(1, -32, 0, 20)
	placedTitle.Position = UDim2.new(0, 16, 0, 268)

	placedFrame = Instance.new("ScrollingFrame")
	placedFrame.Name = "PlacedList"
	placedFrame.Size = UDim2.new(1, -24, 1, -298)
	placedFrame.Position = UDim2.new(0, 12, 0, 290)
	placedFrame.BackgroundTransparency = 1
	placedFrame.BorderSizePixel = 0
	placedFrame.ScrollBarThickness = 6
	placedFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	placedFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	placedFrame.Parent = panel
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = placedFrame

	if UserInputService.TouchEnabled then
		panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	end

	-- Live base feed + steal alerts (wait in background, never block Init).
	task.spawn(function()
		local folder = getRemotesFolder()
		if not folder then
			return
		end
		local okBase, baseRemote = pcall(function()
			return folder:WaitForChild(remoteName("BaseUpdate", "BaseUpdate"), 30)
		end)
		if okBase and baseRemote and baseRemote:IsA("RemoteEvent") then
			(baseRemote :: RemoteEvent).OnClientEvent:Connect(function(data: any)
				BaseController.ApplyBaseUpdate(data)
			end)
		end
		local okSteal, stealRemote = pcall(function()
			return folder:WaitForChild(remoteName("StealAlert", "StealAlert"), 10)
		end)
		if okSteal and stealRemote and stealRemote:IsA("RemoteEvent") then
			(stealRemote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				BaseController.ShowStealAlert(payload)
			end)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.V then
			BaseController.Toggle()
		end
	end)

	BaseController.RebuildPlaced()
	BaseController.RefreshFromServer()
	print("[GlitchTide] BaseController ready")
end

return BaseController
