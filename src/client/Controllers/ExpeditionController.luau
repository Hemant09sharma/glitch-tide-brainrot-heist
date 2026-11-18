--!strict
-- ExpeditionController.luau
-- Expedition panel (v1.1 Wave 3, Workstream E): start / claim / status.
-- Server side is Workstream C (ExpeditionService). RemoteFunction
-- GetExpeditions returns the LIVE shape {Definitions, Active,
-- Completed, Eligible} — NOT the {Active, Available, OnExpedition}
-- shape REMOTES_NEEDED_C.md describes (the doc was written from the
-- design; the server code wins):
--   Definitions: array of {Id, Name, Description, DurationSeconds,
--     MinLevel, MinRarityRank, MinTrait, Rewards, RiskChance,
--     DiscoveryChance, RequiresSecretId}
--   Active: {InstanceId, CharacterId, ExpeditionId, Name, StartedAt,
--     EndsAt, SecondsRemaining, Ready} | nil (ONE active trip per
--     player, server-enforced)
--   Completed: array of {Id, Name, CompletedAt}
--   Eligible: { [expeditionId]: {instanceId, ...} } — instances that
--     are unplaced, not on expedition, and meet the minimums.
-- Remotes:
--   RequestExpeditions (RemoteFunction) -> GetExpeditions()
--   ExpeditionUpdate (RemoteEvent) -> {Action="ExpeditionUpdate",
--     Expeditions=<GetExpeditions>}
--   StartExpedition (RemoteEvent) <- {InstanceId, ExpeditionId}
--   ClaimExpedition (RemoteEvent) <- {ExpeditionId}
-- The 1s countdown runs ONLY while the panel is open AND a trip is
-- active — it stops when the panel closes (the server is the clock;
-- the tick is a display convenience). A trip ready to claim shows a
-- banner via PanelKit.ShowBanner when the push arrives.
-- ON-EXPEDITION RULE: the active instance is surfaced here as
-- GetActiveInstanceId() so Lab/Shop/fuse lists can hide it; this
-- panel itself never offers an on-expedition instance for a second
-- trip (server enforces one active trip anyway).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local ExpeditionController = {}

local PanelKit = require(script.Parent.PanelKit)

local gui: ScreenGui? = nil
local contentFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local expeditions: any = nil
local selectedInstance: string? = nil
local ticking = false

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function playSound(method: string)
	PanelKit.PlaySound(method)
end

function ExpeditionController.GetActiveInstanceId(): string?
	if typeof(expeditions) == "table" and typeof(expeditions.Active) == "table" then
		local id = expeditions.Active.InstanceId
		if typeof(id) == "string" and id ~= "" then
			return id
		end
	end
	return nil
end

function ExpeditionController.GetActiveExpedition(): any?
	if typeof(expeditions) == "table" then
		return expeditions.Active
	end
	return nil
end

local function startTicker()
	if ticking then
		return
	end
	ticking = true
	task.spawn(function()
		while ticking and isOpen do
			task.wait(1)
			if not isOpen then
				break
			end
			local active = ExpeditionController.GetActiveExpedition()
			if active == nil then
				-- Nothing running: stop ticking until a refresh.
				break
			end
			ExpeditionController.Rebuild()
		end
		ticking = false
	end)
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

function ExpeditionController.Rebuild()
	if not contentFrame then
		return
	end
	clearContent()
	if typeof(expeditions) ~= "table" then
		note("Expedition data is not loaded yet — reopen the panel to retry.")
		return
	end
	local active = expeditions.Active
	if typeof(active) == "table" then
		local ready = active.Ready == true
		local charName = PanelKit.CharacterName(active.CharacterId or active.characterId)
		local remaining = tonumber(active.SecondsRemaining) or 0
		local title = "🧭 " .. tostring(active.Name or "Expedition") .. " — " .. charName
		local desc = "Away on expedition. Returns in " .. PanelKit.FormatDuration(math.max(0, remaining)) .. "."
		if ready then
			desc = "Your Brainrot is back! Claim the rewards now."
		end
		local row = buildRow(title, desc, if ready then "READY ✓" else "⏳ " .. PanelKit.FormatDuration(math.max(0, remaining)), if ready then "CLAIM" else "RUNNING…", if ready then Color3.fromRGB(40, 160, 90) else Color3.fromRGB(70, 70, 90), function()
			if not ready then
				setStatus("Still running — " .. PanelKit.FormatDuration(math.max(0, remaining)) .. " left.")
				return
			end
			if not PanelKit.Debounce("exp:claim", 1) then
				return
			end
			local fired = PanelKit.FireServerChecked("ClaimExpedition", 0, { ExpeditionId = active.ExpeditionId })
			if fired then
				setStatus("Claiming " .. tostring(active.Name) .. " rewards…")
				playSound("expedition")
			else
				setStatus("ClaimExpedition remote is not available yet.", true)
			end
		end)
		row.Parent = contentFrame
	end
	local definitions: { any } = expeditions.Definitions or {}
	local eligible: { [string]: any } = expeditions.Eligible or {}
	if #definitions == 0 then
		note("No expedition definitions loaded yet.")
		return
	end
	local head = PanelKit.MakeLabel(contentFrame, "Send an UNPLACED Brainrot on an expedition. It returns with rewards — a few come back empty-pawed (risk), and rare ones come back with something extra (discovery).", 12, Color3.fromRGB(200, 210, 230), false)
	head.Size = UDim2.new(1, -16, 0, 44)
	head.Position = UDim2.new(0, 8, 0, 8)
	for _, def in definitions do
		local defId = tostring(def.Id)
		local list = eligible[defId]
		local eligibleCount = if typeof(list) == "table" then #list else 0
		local rewards = def.Rewards
		local rewardText = ""
		if typeof(rewards) == "table" then
			local parts: { string } = {}
			if typeof(rewards.Coins) == "number" and rewards.Coins > 0 then
				table.insert(parts, "🪙 " .. tostring(rewards.Coins))
			end
			if typeof(rewards.Gems) == "number" and rewards.Gems > 0 then
				table.insert(parts, "💎 " .. tostring(rewards.Gems))
			end
			if typeof(rewards.MutationCrystals) == "number" and rewards.MutationCrystals > 0 then
				table.insert(parts, "💠 " .. tostring(rewards.MutationCrystals))
			end
			if typeof(rewards.XP) == "number" and rewards.XP > 0 then
				table.insert(parts, tostring(rewards.XP) .. " XP")
			end
			rewardText = table.concat(parts, "  •  ")
		end
		local row = buildRow(
			tostring(def.Name) .. "  •  " .. PanelKit.FormatDuration(def.DurationSeconds or 0),
			tostring(def.Description or "")
				.. "  •  Risk: " .. tostring(math.floor((def.RiskChance or 0) * 100)) .. "%"
				.. "  •  Eligible Brainrots: " .. tostring(eligibleCount),
			rewardText,
			if eligibleCount > 0 then "SEND" else "NO FIT",
			if eligibleCount > 0 then Color3.fromRGB(60, 120, 220) else Color3.fromRGB(70, 70, 90),
			function()
				if eligibleCount == 0 then
					setStatus("No unplaced Brainrot meets " .. tostring(def.Name) .. "'s minimums (level / rarity / trait).", true)
					return
				end
				selectedInstance = list[1]
				if not PanelKit.Debounce("exp:start", 1) then
					return
				end
				local fired = PanelKit.FireServerChecked("StartExpedition", 0, {
					InstanceId = selectedInstance,
					ExpeditionId = defId,
				})
				if fired then
					setStatus("Sending a Brainrot on " .. tostring(def.Name) .. "…")
					playSound("expedition")
				else
					setStatus("StartExpedition remote is not available yet.", true)
				end
			end
		)
		row.Parent = contentFrame
	end
	if typeof(expeditions.Completed) == "table" and #expeditions.Completed > 0 then
		local done = PanelKit.MakeLabel(contentFrame, "Completed expeditions: " .. tostring(#expeditions.Completed), 12, Color3.fromRGB(120, 220, 255), true)
		done.Size = UDim2.new(1, -16, 0, 20)
		done.Position = UDim2.new(0, 8, 0, 8)
	end
	if active ~= nil then
		startTicker()
	end
end

function ExpeditionController.RefreshFromServer()
	local ok, result = PanelKit.InvokeChecked("RequestExpeditions")
	if ok and typeof(result) == "table" then
		expeditions = result
		setStatus("Expeditions loaded.")
	else
		expeditions = nil
		setStatus("Expedition data is not available from the server yet.", true)
	end
	ExpeditionController.Rebuild()
end

function ExpeditionController.ApplyExpeditionUpdate(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local nextState = payload.Expeditions
	if typeof(nextState) == "table" then
		local wasActive = ExpeditionController.GetActiveExpedition() ~= nil
		local wasReady = false
		local old = ExpeditionController.GetActiveExpedition()
		if typeof(old) == "table" then
			wasReady = old.Ready == true
		end
		expeditions = nextState
		local active = ExpeditionController.GetActiveExpedition()
		if wasActive and active == nil and not wasReady then
			-- Trip vanished without a claim: the server ended it
			-- (likely claimed from another path).
			setStatus("Expedition finished.")
		elseif typeof(active) == "table" and active.Ready == true and not wasReady then
			setStatus("Your Brainrot returned from " .. tostring(active.Name) .. " — claim the rewards!")
			PanelKit.ShowBanner("🧭 Expedition complete: " .. tostring(active.Name) .. "! Claim your rewards.", 8)
			playSound("expedition")
		end
		if isOpen then
			ExpeditionController.Rebuild()
		end
	end
end

function ExpeditionController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	ExpeditionController.RefreshFromServer()
end

function ExpeditionController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function ExpeditionController.Toggle()
	if isOpen then
		ExpeditionController.Close()
	else
		ExpeditionController.Open()
	end
end

function ExpeditionController.IsOpen(): boolean
	return isOpen
end

function ExpeditionController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Expeditions"
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
	pStroke.Color = Color3.fromRGB(90, 160, 255)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = PanelKit.MakeLabel(panel, "🧭  EXPEDITIONS", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 260, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	PanelKit.MakeButton(panel, "✕", UDim2.new(0, 36, 0, 30), UDim2.new(1, -48, 0, 10), Color3.fromRGB(200, 60, 60), function()
		ExpeditionController.Close()
	end)

	statusLabel = PanelKit.MakeLabel(panel, "Send unplaced Brainrots out into the Memeverse — they come back richer.", 12, Color3.fromRGB(200, 220, 255), false)
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

	PanelKit.Listen("ExpeditionUpdate", function(payload: any)
		ExpeditionController.ApplyExpeditionUpdate(payload)
	end)

	ExpeditionController.Rebuild()
	print("[GlitchTide] ExpeditionController ready")
end

return ExpeditionController
