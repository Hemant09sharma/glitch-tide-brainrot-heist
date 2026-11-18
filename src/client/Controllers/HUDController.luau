-- HUDController.luau
-- Glitch Tide — heads-up display.
-- Builds ScreenGui "HUD" in PlayerGui: health bar, coins, gems, chaos
-- shards, income/sec, XP bar + level, region label, round timer, KOs,
-- wave indicator, player count and team label.
-- Also owns the damage vignette flash and the low-health pulse, the
-- Glitch Tide countdown banner, the carrying + base status chips, the
-- quest tracker, the event banner, and the bottom menu bar (Market /
-- Shop / Brainrots / Base / Quests / Collection) that opens the other
-- controllers. Menu buttons lazy-require their controller on click, so
-- the HUD never hard-depends on another controller's Init order.
-- Wave 3 (v1.1 E) added: a second menu row for the new panels (Lab /
-- Expeditions / Territory / Worlds / Achievements), the BossUpdate
-- health bar, the 10-stage tide line, the equipped-title slot, death
-- and victory screens, the welcome banner, the EventUpdate SoundHook
-- sounds, and the RequestEvents active-event fetch (60s). The dead
-- FireServer("GetStats") and the 5s stats polling fallback were
-- removed — PlayerStats is a server-pushed event.
-- Returns a table with Init() plus public Update* / FlashDamage helpers
-- so other controllers (e.g. AbilityController) can flash the vignette.
-- Rarity colours live in RarityColors.luau (required for the chips).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local HUDController = {}

local RarityColors = require(script.Parent.RarityColors)

local Utils: any = nil
pcall(function()
	Utils = require(ReplicatedStorage:WaitForChild("Utils", 10))
end)

-- Panel hotkeys come from the shared bind table (Utils.GetKeybinds),
-- never literals: the label text and the toggle key are the same value.
local function getBinds(): { [string]: string }
	if Utils and Utils.GetKeybinds then
		local ok, binds = pcall(function()
			return Utils.GetKeybinds()
		end)
		if ok and type(binds) == "table" then
			return binds
		end
	end
	return {
		Market = "N",
		Shop = "B",
		Brainrots = "C",
		Base = "V",
		Quests = "J",
		Collection = "L",
		Interact = "E",
	}
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local gui = nil
local healthFill = nil
local healthLabel = nil
local healthBarFrame = nil
local coinsLabel = nil
local gemsLabel = nil
local shardsLabel = nil
local incomeLabel = nil
local regionLabel = nil
local xpFill = nil
local xpLabel = nil
local levelLabel = nil
local timerLabel = nil
local timerFrame = nil
local kosLabel = nil
local waveLabel = nil
local playersLabel = nil
local teamLabel = nil
local vignette = nil
local tideBanner = nil
local tideLabel = nil
local eventLabel = nil
local carryingChip = nil
local carryingLabel = nil
local baseChip = nil
local baseLabel = nil
local questTracker = nil
local questLabel = nil
-- Wave 3 (v1.1 E): boss health bar, tide stage line, equipped title,
-- death / victory screens, welcome banner.
local bossBarFrame = nil
local bossFill = nil
local bossLabel = nil
local stageFrame = nil
local stageLabel = nil
local titleLabel = nil
local deathScreen = nil
local victoryScreen = nil
local victoryLabel = nil
local welcomeShown = false

local maxHealth = 100
local currentHealth = 100
local lowHealthTween = nil
local lowHealthActive = false
local vignetteTween = nil
local humanoidConnection = nil

local coins = 0
local gems = 0
local shards = 0
local incomePerSec = 0
local xp = 0
local xpToNext = 100
local level = 1
local kos = 0
local isTouch = false

-- ---------------------------------------------------------------------------
-- Small UI helpers
-- ---------------------------------------------------------------------------
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function makeLabel(parent, text, size, color, bold)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = size
	label.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = parent
	return label
end

local function makeBar(parent, size, position, bgColor, fillColor)
	local bg = Instance.new("Frame")
	bg.Size = size
	bg.Position = position
	bg.BackgroundColor3 = bgColor
	bg.BorderSizePixel = 0
	bg.Parent = parent
	corner(bg, 6)
	stroke(bg, Color3.fromRGB(0, 0, 0), 1)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Parent = bg
	corner(fill, 6)
	return bg, fill
end

-- ---------------------------------------------------------------------------
-- Public update functions
-- ---------------------------------------------------------------------------
function HUDController.SetHealth(health, max)
	maxHealth = max or maxHealth
	if maxHealth <= 0 then
		maxHealth = 100
	end
	currentHealth = math.clamp(health or currentHealth, 0, maxHealth)
	local ratio = currentHealth / maxHealth
	if healthFill then
		healthFill.Size = UDim2.new(math.clamp(ratio, 0, 1), 0, 1, 0)
		if ratio > 0.5 then
			healthFill.BackgroundColor3 = Color3.fromRGB(46, 204, 113)
		elseif ratio > 0.25 then
			healthFill.BackgroundColor3 = Color3.fromRGB(241, 196, 15)
		else
			healthFill.BackgroundColor3 = Color3.fromRGB(231, 76, 60)
		end
	end
	if healthLabel then
		healthLabel.Text = string.format("HP  %d / %d", math.floor(currentHealth + 0.5), math.floor(maxHealth + 0.5))
	end
	HUDController.UpdateLowHealth()
end

function HUDController.SetCoins(amount)
	coins = amount or coins
	if coinsLabel then
		coinsLabel.Text = "🪙 " .. tostring(math.floor(coins + 0.5))
	end
end

function HUDController.GetCoins()
	return coins
end

function HUDController.SetGems(amount)
	gems = amount or gems
	if gemsLabel then
		gemsLabel.Text = "💎 " .. tostring(math.floor(gems + 0.5))
	end
end

function HUDController.GetGems()
	return gems
end

function HUDController.SetShards(amount)
	shards = amount or shards
	if shardsLabel then
		shardsLabel.Text = "🌀 Chaos Shards: " .. tostring(math.floor(shards + 0.5))
	end
end

function HUDController.SetIncome(amount)
	incomePerSec = amount or incomePerSec
	if incomeLabel then
		incomeLabel.Text = "📈 +" .. string.format("%.1f", incomePerSec) .. "/s"
	end
end

function HUDController.SetRegion(regionName)
	if regionLabel then
		regionLabel.Text = "📍 " .. tostring(regionName or "Memeverse")
	end
end

function HUDController.SetXP(amount, needed, newLevel)
	xp = amount or xp
	xpToNext = needed or xpToNext
	if newLevel then
		level = newLevel
	end
	if xpToNext <= 0 then
		xpToNext = 100
	end
	if xpFill then
		xpFill.Size = UDim2.new(math.clamp(xp / xpToNext, 0, 1), 0, 1, 0)
	end
	if xpLabel then
		xpLabel.Text = string.format("XP  %d / %d", math.floor(xp + 0.5), math.floor(xpToNext + 0.5))
	end
	if levelLabel then
		levelLabel.Text = "LVL " .. tostring(level)
	end
end

function HUDController.SetLevel(newLevel)
	level = newLevel or level
	if levelLabel then
		levelLabel.Text = "LVL " .. tostring(level)
	end
end

function HUDController.SetKOs(count)
	kos = count or kos
	if kosLabel then
		kosLabel.Text = "💥 KOs: " .. tostring(kos)
	end
end

function HUDController.SetTimer(secondsLeft, phase)
	if timerLabel then
		local seconds = math.max(0, math.floor((secondsLeft or 0) + 0.5))
		local minutes = math.floor(seconds / 60)
		local secs = seconds % 60
		local text = string.format("%d:%02d", minutes, secs)
		if phase and phase ~= "" then
			text = phase .. "  •  " .. text
		end
		timerLabel.Text = text
	end
end

function HUDController.SetWave(wave, enemiesLeft, totalEnemies)
	if waveLabel then
		local text = "Wave " .. tostring(wave or 1)
		if enemiesLeft ~= nil then
			text ..= "  •  " .. tostring(enemiesLeft)
			if totalEnemies ~= nil then
				text ..= "/" .. tostring(totalEnemies)
			end
			text ..= " left"
		end
		waveLabel.Text = text
	end
end

function HUDController.SetPlayerCount(count, maxPlayers)
	if playersLabel then
		if maxPlayers then
			playersLabel.Text = "👥 " .. tostring(count) .. "/" .. tostring(maxPlayers)
		else
			playersLabel.Text = "👥 " .. tostring(count)
		end
	end
end

function HUDController.SetTeam(teamName, teamColor)
	if teamLabel then
		teamLabel.Text = "Team: " .. tostring(teamName or "—")
		if teamColor then
			teamLabel.TextColor3 = teamColor
		end
	end
end

-- Glitch Tide banner. phase: "Warning" | "Tide" | "Calm" (also accepts
-- the server's lowercase spellings "warning" / "active" / "ended").
-- Hidden while Calm with no time left.
function HUDController.SetTide(phase, secondsLeft)
	if not tideBanner or not tideLabel then
		return
	end
	local phaseText = tostring(phase or "Calm")
	local lower = string.lower(phaseText)
	local seconds = 0
	if typeof(secondsLeft) == "number" then
		seconds = math.max(0, math.floor(secondsLeft + 0.5))
	end
	if lower == "calm" or lower == "ended" or lower == "idle" then
		tideBanner.Visible = false
		return
	end
	tideBanner.Visible = true
	local label = "GLITCH TIDE"
	local color = Color3.fromRGB(190, 90, 255)
	if lower == "warning" or lower == "countdown" then
		label = "⚠ GLITCH TIDE INCOMING"
		color = Color3.fromRGB(255, 170, 40)
	elseif lower == "tide" or lower == "active" then
		label = "🌊 GLITCH TIDE — 2x INCOME!"
		color = Color3.fromRGB(190, 90, 255)
	end
	if seconds > 0 then
		local minutes = math.floor(seconds / 60)
		local secs = seconds % 60
		label ..= string.format("  •  %d:%02d", minutes, secs)
	end
	tideLabel.Text = label
	tideBanner.BackgroundColor3 = color
end

-- Boss health bar (v1.1 E, Workstream D's BossUpdate remote).
-- BossUpdate is fired by BossService on spawn / phase change / every
-- 2s while the boss is alive / death: {Event, BossId, BossName, Arena,
-- Active, Health, MaxHealth, Phase}. Event "BossSpawned" shows the bar,
-- "BossDied" hides it after a short beat; Active=false hides it.
function HUDController.SetBoss(bossName, health, maxHealth, phase)
	if not bossBarFrame or not bossFill or not bossLabel then
		return
	end
	if bossName == nil or bossName == "" then
		bossBarFrame.Visible = false
		return
	end
	bossBarFrame.Visible = true
	local h = math.max(0, health or 0)
	local m = math.max(1, maxHealth or 1)
	bossFill.Size = UDim2.new(math.clamp(h / m, 0, 1), 0, 1, 0)
	local phaseText = if typeof(phase) == "string" and phase ~= "" then "  •  " .. phase else ""
	bossLabel.Text = "👹 " .. tostring(bossName) .. "   " .. tostring(math.floor(h)) .. " / " .. tostring(math.floor(m)) .. phaseText
end

-- Tide stage line (v1.1 E, Workstream D's 10-stage anticipation):
-- "Stage 3/10 — The sky glitches" under the tide banner. The
-- announcement text is shown in the event banner for a few seconds.
function HUDController.SetTideStage(stage, stageName, announcement)
	if not stageFrame or not stageLabel then
		return
	end
	if typeof(stage) ~= "number" or stage <= 0 then
		stageFrame.Visible = false
		return
	end
	stageFrame.Visible = true
	local name = if typeof(stageName) == "string" and stageName ~= "" then " — " .. stageName else ""
	stageLabel.Text = "Stage " .. tostring(stage) .. "/10" .. name
	if typeof(announcement) == "string" and announcement ~= "" then
		HUDController.ShowEventBanner("📣 " .. announcement, 6)
	end
end

-- Equipped title (v1.1 E): shown under the team line. Set by
-- AchievementController (local-only until the EquipTitle server
-- handler is wired — see docs/QA_V11_E.md).
function HUDController.SetEquippedTitle(titleId)
	if not titleLabel then
		return
	end
	if typeof(titleId) == "string" and titleId ~= "" then
		titleLabel.Text = "🏆 " .. titleId
		titleLabel.Visible = true
	else
		titleLabel.Visible = false
	end
end

-- Generic banner used by PanelKit.ShowBanner (shared banner helper).
-- Reuses the event banner slot so there is exactly one banner queue.
function HUDController.ShowBanner(text, durationSeconds)
	HUDController.ShowEventBanner(text, durationSeconds or 6)
end

-- Death screen (v1.1 E): shown when the local Humanoid dies; hidden
-- when the new character binds (respawn).
function HUDController.ShowDeathScreen()
	if not deathScreen then
		return
	end
	deathScreen.Visible = true
	pcall(function()
		local mod = script.Parent:FindFirstChild("SoundController")
		if mod then
			local sound = require(mod)
			if sound.PlayDefeat then
				sound.PlayDefeat()
			end
		end
	end)
end

-- Victory screen (v1.1 E): the local player survived a tide.
function HUDController.ShowVictoryScreen(variation, rewardMultiplier)
	if not victoryScreen or not victoryLabel then
		return
	end
	local multText = if typeof(rewardMultiplier) == "number" and rewardMultiplier > 1
		then "\nReward ×" .. tostring(rewardMultiplier)
		else ""
	victoryLabel.Text = "🌊 YOU SURVIVED THE " .. string.upper(tostring(variation or "GLITCH TIDE")) .. "!" .. multText
	victoryScreen.Visible = true
	pcall(function()
		local mod = script.Parent:FindFirstChild("SoundController")
		if mod then
			local sound = require(mod)
			if sound.PlayVictory then
				sound.PlayVictory()
			end
		end
	end)
	task.delay(6, function()
		if victoryScreen then
			victoryScreen.Visible = false
		end
	end)
end

-- One-line event banner under the tide banner (e.g. double-income
-- weekends, bonus conveyor hours). Pass nil/"" to hide.
function HUDController.ShowEventBanner(text, durationSeconds)
	if not eventLabel then
		return
	end
	local frame = eventLabel.Parent
	if not text or text == "" then
		if frame then
			frame.Visible = false
		end
		return
	end
	eventLabel.Text = tostring(text)
	if frame then
		frame.Visible = true
	end
	if durationSeconds and durationSeconds > 0 then
		task.delay(durationSeconds, function()
			if frame then
				frame.Visible = false
			end
		end)
	end
end

-- Carrying chip (bottom-left): "Carrying: <name> — Place at base".
-- The key shown is the live Interact bind from Utils, not a literal.
function HUDController.SetCarrying(isCarrying, brainrotName)
	if not carryingChip or not carryingLabel then
		return
	end
	if isCarrying then
		carryingChip.Visible = true
		local interactKey = getBinds().Interact or "E"
		carryingLabel.Text = "📦 Carrying: " .. tostring(brainrotName or "Brainrot") .. " — Place at base (" .. interactKey .. ")"
	else
		carryingChip.Visible = false
	end
end

-- Base status chip (bottom-left, under the carrying chip).
function HUDController.SetBaseStatus(text)
	if not baseChip or not baseLabel then
		return
	end
	if not text or text == "" then
		baseChip.Visible = false
		return
	end
	baseChip.Visible = true
	baseLabel.Text = tostring(text)
end

-- Quest tracker (top-left, under the health panel): top quest + progress.
function HUDController.SetQuestTracker(text)
	if not questTracker or not questLabel then
		return
	end
	if not text or text == "" then
		questTracker.Visible = false
		return
	end
	questTracker.Visible = true
	questLabel.Text = text
end

function HUDController.RefreshQuestTracker()
	local ok, questModule = pcall(function()
		return require(script.Parent.QuestController)
	end)
	if not ok or not questModule or not questModule.GetTopQuest then
		return
	end
	local top = questModule.GetTopQuest()
	if not top then
		HUDController.SetQuestTracker("")
		return
	end
	local progress = top.Progress or top.progress or top.Current or 0
	local goal = top.Goal or top.goal or top.Target or 1
	if typeof(progress) ~= "number" then
		progress = 0
	end
	if typeof(goal) ~= "number" or goal <= 0 then
		goal = 1
	end
	local title = tostring(top.Title or top.title or top.Name or "Quest")
	HUDController.SetQuestTracker("📜 " .. title .. "  " .. tostring(math.floor(progress)) .. "/" .. tostring(goal))
end

-- Red flash over the whole screen when the player takes damage.
-- `strength` 0..1 scales the peak opacity.
function HUDController.FlashDamage(strength)
	if not vignette then
		return
	end
	strength = math.clamp(strength or 0.55, 0, 1)
	if vignetteTween then
		vignetteTween:Cancel()
	end
	vignette.BackgroundTransparency = 1 - (0.45 * strength)
	vignetteTween = TweenService:Create(
		vignette,
		TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	vignetteTween:Play()
end

function HUDController.UpdateLowHealth()
	if not healthBarFrame then
		return
	end
	local ratio = currentHealth / math.max(1, maxHealth)
	local shouldPulse = ratio > 0 and ratio <= 0.3
	if shouldPulse and not lowHealthActive then
		lowHealthActive = true
		lowHealthTween = TweenService:Create(
			healthBarFrame,
			TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.25 }
		)
		lowHealthTween:Play()
	elseif not shouldPulse and lowHealthActive then
		lowHealthActive = false
		if lowHealthTween then
			lowHealthTween:Cancel()
			lowHealthTween = nil
		end
		healthBarFrame.BackgroundTransparency = 0
	end
end

-- Open another controller's panel by module name (lazy require, so the
-- HUD never depends on that controller having finished Init).
local function openController(moduleName)
	local mod = script.Parent:FindFirstChild(moduleName)
	if not mod then
		return
	end
	local ok, controller = pcall(require, mod)
	if not ok or typeof(controller) ~= "table" then
		return
	end
	if typeof(controller.Toggle) == "function" then
		pcall(controller.Toggle)
	elseif typeof(controller.Open) == "function" then
		pcall(controller.Open)
	end
end

function HUDController.OpenPanel(moduleName)
	openController(moduleName)
end

-- Apply one PlayerStats payload, accepting several field spellings so the
-- HUD stays correct whatever exact shape the server sends.
local function applyPlayerStats(data)
	if typeof(data) ~= "table" then
		return
	end
	if data.type == "CharacterSwitchFailed" then
		return -- handled by CharacterSelectController, not a stat update
	end
	if data.Coins ~= nil then
		HUDController.SetCoins(data.Coins)
	elseif data.coins ~= nil then
		HUDController.SetCoins(data.coins)
	end
	if data.Gems ~= nil then
		HUDController.SetGems(data.Gems)
	elseif data.gems ~= nil then
		HUDController.SetGems(data.gems)
	end
	local shardValue = data.ChaosShards or data.Shards or data.chaosShards or data.shards
	if shardValue ~= nil then
		HUDController.SetShards(shardValue)
	end
	local incomeValue = data.IncomePerSec or data.incomePerSec or data.Income
	if incomeValue ~= nil then
		HUDController.SetIncome(incomeValue)
	end
	if data.Region ~= nil then
		HUDController.SetRegion(data.Region)
	elseif data.region ~= nil then
		HUDController.SetRegion(data.region)
	end
	if data.KOs ~= nil then
		HUDController.SetKOs(data.KOs)
	elseif data.Kills ~= nil then
		HUDController.SetKOs(data.Kills)
	elseif data.kos ~= nil then
		HUDController.SetKOs(data.kos)
	end
	local xpValue = data.XP or data.xp
	local xpNeeded = data.XPToNext or data.XPNeeded or data.xpToNext or data.NextLevelXP
	local lvl = data.Level or data.level
	if xpValue ~= nil or xpNeeded ~= nil or lvl ~= nil then
		HUDController.SetXP(xpValue, xpNeeded, lvl)
	end
	if data.Health ~= nil and data.MaxHealth ~= nil then
		HUDController.SetHealth(data.Health, data.MaxHealth)
	end
	if data.Team ~= nil then
		local teamColor = data.TeamColor
		HUDController.SetTeam(data.Team, teamColor)
	end
end

-- GlitchTideUpdate payload: {Phase=..., TimeLeft=...} / {phase,
-- secondsRemaining} / (phaseString, seconds) — all accepted.
-- Wave 3 (v1.1 E, D's new fields): Stage (1-10), StageName,
-- Announcement, EscapeRoutes (stage 5 only), WavePosition, CoopBonus,
-- Survivors, RewardMultiplier. The stage line and announcement are
-- surfaced; EscapeRoutes are drawn by the client map markers, not the
-- HUD (no map-marker API exists on the client yet — see QA_V11_E.md).
local function applyTideUpdate(a, b)
	local phase: string? = nil
	local seconds: number? = nil
	local stage: number? = nil
	local stageName: string? = nil
	local announcement: string? = nil
	if typeof(a) == "table" then
		phase = a.Phase or a.phase
		seconds = a.TimeLeft or a.timeLeft or a.SecondsLeft or a.secondsRemaining
		stage = a.Stage
		stageName = a.StageName
		announcement = a.Announcement
	elseif typeof(a) == "string" then
		phase = a
		if typeof(b) == "number" then
			seconds = b
		end
	end
	if phase then
		HUDController.SetTide(phase, seconds)
	end
	if stage ~= nil then
		HUDController.SetTideStage(stage, stageName, announcement)
	end
end

local function applyBaseUpdate(data)
	if typeof(data) ~= "table" then
		return
	end
	local income = data.IncomePerSec or data.incomePerSec
	if typeof(income) == "number" then
		HUDController.SetIncome(income)
	end
	local used = data.SlotsUsed or data.slotsUsed
	local total = data.SlotsTotal or data.Slots or data.slotsTotal or data.MaxSlots
	if used ~= nil and total ~= nil then
		HUDController.SetBaseStatus("🏠 Base: " .. tostring(used) .. "/" .. tostring(total) .. " slots")
	elseif data.Banked ~= nil or data.BankedIncome ~= nil then
		local banked = data.Banked or data.BankedIncome or 0
		HUDController.SetBaseStatus("🏠 Base banked: 🪙 " .. tostring(math.floor(banked + 0.5)))
	end
end

local function applyCarryUpdate(payload)
	local isCarrying = false
	local name: string? = nil
	if typeof(payload) == "table" then
		isCarrying = payload.Carrying == true or payload.carrying == true
		name = payload.Name or payload.BrainrotName or payload.CharacterName
	elseif typeof(payload) == "boolean" then
		isCarrying = payload
	elseif typeof(payload) == "string" then
		isCarrying = true
		name = payload
	end
	HUDController.SetCarrying(isCarrying, if typeof(name) == "string" then name else nil)
end

-- ---------------------------------------------------------------------------
-- Humanoid tracking
-- ---------------------------------------------------------------------------
local function bindHumanoid(humanoid)
	if not humanoid then
		return
	end
	if humanoidConnection then
		humanoidConnection:Disconnect()
		humanoidConnection = nil
	end
	maxHealth = humanoid.MaxHealth
	HUDController.SetHealth(humanoid.Health, humanoid.MaxHealth)
	humanoidConnection = humanoid.HealthChanged:Connect(function(newHealth)
		local previous = currentHealth
		HUDController.SetHealth(newHealth, humanoid.MaxHealth)
		if newHealth < previous then
			local lost = previous - newHealth
			HUDController.FlashDamage(math.clamp(lost / math.max(1, maxHealth) * 2.2, 0.25, 1))
		end
	end)
	-- Death screen (v1.1 E): the Humanoid fires Died once per life;
	-- the screen hides when the next character binds (respawn).
	humanoid.Died:Connect(function()
		HUDController.ShowDeathScreen()
	end)
end

local function bindCharacter(character)
	if not character then
		return
	end
	-- Respawn: hide the death screen from the previous life.
	if deathScreen then
		deathScreen.Visible = false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		bindHumanoid(humanoid)
	else
		task.spawn(function()
			local found = character:WaitForChild("Humanoid", 10)
			if found then
				bindHumanoid(found)
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function build()
	isTouch = UserInputService.TouchEnabled
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	-- Damage vignette: sits above everything, normally fully transparent.
	vignette = Instance.new("Frame")
	vignette.Name = "DamageVignette"
	vignette.Size = UDim2.new(1, 0, 1, 0)
	vignette.Position = UDim2.new(0, 0, 0, 0)
	vignette.BackgroundColor3 = Color3.fromRGB(200, 0, 0)
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.ZIndex = 50
	vignette.Parent = gui
	local vignetteGradient = Instance.new("UIGradient")
	vignetteGradient.Rotation = 90
	vignetteGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, 0.55),
		NumberSequenceKeypoint.new(0.65, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	vignetteGradient.Parent = vignette

	-- ---- Top-left: health + XP -------------------------------------------
	local leftPanel = Instance.new("Frame")
	leftPanel.Name = "LeftPanel"
	leftPanel.Size = UDim2.new(0, 280, 0, 86)
	leftPanel.Position = UDim2.new(0, 14, 0, 14)
	leftPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	leftPanel.BackgroundTransparency = 0.25
	leftPanel.BorderSizePixel = 0
	leftPanel.Parent = gui
	corner(leftPanel, 10)
	stroke(leftPanel, Color3.fromRGB(255, 255, 255), 1).Transparency = 0.8

	healthBarFrame, healthFill = makeBar(
		leftPanel,
		UDim2.new(1, -20, 0, 22),
		UDim2.new(0, 10, 0, 10),
		Color3.fromRGB(40, 40, 50),
		Color3.fromRGB(46, 204, 113)
	)
	healthBarFrame.Name = "HealthBar"
	healthLabel = makeLabel(leftPanel, "HP  100 / 100", 13, Color3.fromRGB(255, 255, 255), true)
	healthLabel.Size = UDim2.new(1, -20, 0, 22)
	healthLabel.Position = UDim2.new(0, 10, 0, 10)
	healthLabel.TextXAlignment = Enum.TextXAlignment.Center
	healthLabel.ZIndex = 2

	local xpBarBg, xpFillInner = makeBar(
		leftPanel,
		UDim2.new(1, -20, 0, 12),
		UDim2.new(0, 10, 0, 40),
		Color3.fromRGB(40, 40, 50),
		Color3.fromRGB(155, 89, 182)
	)
	xpBarBg.Name = "XPBar"
	xpFill = xpFillInner

	xpLabel = makeLabel(leftPanel, "XP  0 / 100", 11, Color3.fromRGB(220, 220, 230), false)
	xpLabel.Size = UDim2.new(0, 140, 0, 16)
	xpLabel.Position = UDim2.new(0, 10, 0, 56)

	levelLabel = makeLabel(leftPanel, "LVL 1", 13, Color3.fromRGB(255, 215, 0), true)
	levelLabel.Size = UDim2.new(0, 80, 0, 16)
	levelLabel.Position = UDim2.new(1, -90, 0, 56)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Right

	-- ---- Quest tracker (under the health panel) --------------------------
	questTracker = Instance.new("Frame")
	questTracker.Name = "QuestTracker"
	questTracker.Size = UDim2.new(0, 280, 0, 30)
	questTracker.Position = UDim2.new(0, 14, 0, 106)
	questTracker.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	questTracker.BackgroundTransparency = 0.25
	questTracker.BorderSizePixel = 0
	questTracker.Visible = false
	questTracker.Parent = gui
	corner(questTracker, 8)
	stroke(questTracker, Color3.fromRGB(255, 215, 0), 1).Transparency = 0.7
	questLabel = makeLabel(questTracker, "", 12, Color3.fromRGB(255, 240, 180), true)
	questLabel.Size = UDim2.new(1, -16, 1, 0)
	questLabel.Position = UDim2.new(0, 8, 0, 0)

	-- ---- Top-center: timer + wave + region -------------------------------
	local centerPanel = Instance.new("Frame")
	centerPanel.Name = "CenterPanel"
	centerPanel.Size = UDim2.new(0, 240, 0, 84)
	centerPanel.Position = UDim2.new(0.5, -120, 0, 14)
	centerPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	centerPanel.BackgroundTransparency = 0.25
	centerPanel.BorderSizePixel = 0
	centerPanel.Parent = gui
	corner(centerPanel, 10)
	stroke(centerPanel, Color3.fromRGB(255, 255, 255), 1).Transparency = 0.8

	timerFrame = centerPanel
	timerLabel = makeLabel(centerPanel, "0:00", 22, Color3.fromRGB(255, 255, 255), true)
	timerLabel.Size = UDim2.new(1, 0, 0, 30)
	timerLabel.Position = UDim2.new(0, 0, 0, 4)
	timerLabel.TextXAlignment = Enum.TextXAlignment.Center

	waveLabel = makeLabel(centerPanel, "Wave 1", 13, Color3.fromRGB(255, 215, 0), true)
	waveLabel.Size = UDim2.new(1, 0, 0, 20)
	waveLabel.Position = UDim2.new(0, 0, 0, 34)
	waveLabel.TextXAlignment = Enum.TextXAlignment.Center

	regionLabel = makeLabel(centerPanel, "📍 Memeverse", 11, Color3.fromRGB(120, 220, 255), true)
	regionLabel.Size = UDim2.new(1, 0, 0, 18)
	regionLabel.Position = UDim2.new(0, 0, 0, 58)
	regionLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- Glitch Tide banner (under the center panel) ----------------------
	tideBanner = Instance.new("Frame")
	tideBanner.Name = "TideBanner"
	tideBanner.Size = UDim2.new(0, 320, 0, 34)
	tideBanner.Position = UDim2.new(0.5, -160, 0, 106)
	tideBanner.BackgroundColor3 = Color3.fromRGB(190, 90, 255)
	tideBanner.BorderSizePixel = 0
	tideBanner.Visible = false
	tideBanner.Parent = gui
	corner(tideBanner, 10)
	tideLabel = makeLabel(tideBanner, "", 15, Color3.fromRGB(255, 255, 255), true)
	tideLabel.Size = UDim2.new(1, -16, 1, 0)
	tideLabel.Position = UDim2.new(0, 8, 0, 0)
	tideLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- Tide stage line (under the tide banner, v1.1 E) ---------------
	stageFrame = Instance.new("Frame")
	stageFrame.Name = "TideStage"
	stageFrame.Size = UDim2.new(0, 320, 0, 18)
	stageFrame.Position = UDim2.new(0.5, -160, 0, 142)
	stageFrame.BackgroundTransparency = 1
	stageFrame.BorderSizePixel = 0
	stageFrame.Visible = false
	stageFrame.Parent = gui
	stageLabel = makeLabel(stageFrame, "", 11, Color3.fromRGB(220, 180, 255), true)
	stageLabel.Size = UDim2.new(1, 0, 1, 0)
	stageLabel.Position = UDim2.new(0, 0, 0, 0)
	stageLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- Event banner (under the stage line) ----------------------------
	local eventFrame = Instance.new("Frame")
	eventFrame.Name = "EventBanner"
	eventFrame.Size = UDim2.new(0, 320, 0, 26)
	eventFrame.Position = UDim2.new(0.5, -160, 0, 164)
	eventFrame.BackgroundColor3 = Color3.fromRGB(30, 90, 140)
	eventFrame.BorderSizePixel = 0
	eventFrame.Visible = false
	eventFrame.Parent = gui
	corner(eventFrame, 8)
	eventLabel = makeLabel(eventFrame, "", 12, Color3.fromRGB(255, 255, 255), true)
	eventLabel.Size = UDim2.new(1, -16, 1, 0)
	eventLabel.Position = UDim2.new(0, 8, 0, 0)
	eventLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- Boss health bar (under the event banner, v1.1 E) --------------
	bossBarFrame = Instance.new("Frame")
	bossBarFrame.Name = "BossBar"
	bossBarFrame.Size = UDim2.new(0, 340, 0, 26)
	bossBarFrame.Position = UDim2.new(0.5, -170, 0, 198)
	bossBarFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	bossBarFrame.BackgroundTransparency = 0.25
	bossBarFrame.BorderSizePixel = 0
	bossBarFrame.Visible = false
	bossBarFrame.Parent = gui
	corner(bossBarFrame, 8)
	stroke(bossBarFrame, Color3.fromRGB(255, 60, 60), 1).Transparency = 0.5
	local bossFillBg = Instance.new("Frame")
	bossFillBg.Size = UDim2.new(1, -8, 0, 8)
	bossFillBg.Position = UDim2.new(0, 4, 1, -12)
	bossFillBg.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	bossFillBg.BorderSizePixel = 0
	bossFillBg.Parent = bossBarFrame
	corner(bossFillBg, 4)
	bossFill = Instance.new("Frame")
	bossFill.Size = UDim2.new(1, 0, 1, 0)
	bossFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
	bossFill.BorderSizePixel = 0
	bossFill.Parent = bossFillBg
	corner(bossFill, 4)
	bossLabel = makeLabel(bossBarFrame, "", 12, Color3.fromRGB(255, 255, 255), true)
	bossLabel.Size = UDim2.new(1, -16, 0, 14)
	bossLabel.Position = UDim2.new(0, 8, 0, 0)
	bossLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- Top-right: coins, gems, shards, income, KOs, players, team -----
	local rightPanel = Instance.new("Frame")
	rightPanel.Name = "RightPanel"
	rightPanel.Size = UDim2.new(0, 220, 0, 164)
	rightPanel.Position = UDim2.new(1, -234, 0, 14)
	rightPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	rightPanel.BackgroundTransparency = 0.25
	rightPanel.BorderSizePixel = 0
	rightPanel.Parent = gui
	corner(rightPanel, 10)
	stroke(rightPanel, Color3.fromRGB(255, 255, 255), 1).Transparency = 0.8

	coinsLabel = makeLabel(rightPanel, "🪙 0", 16, Color3.fromRGB(255, 215, 0), true)
	coinsLabel.Size = UDim2.new(1, -20, 0, 22)
	coinsLabel.Position = UDim2.new(0, 10, 0, 8)

	gemsLabel = makeLabel(rightPanel, "💎 0", 13, Color3.fromRGB(120, 200, 255), true)
	gemsLabel.Size = UDim2.new(0.5, -10, 0, 18)
	gemsLabel.Position = UDim2.new(0, 10, 0, 32)

	incomeLabel = makeLabel(rightPanel, "📈 +0.0/s", 13, Color3.fromRGB(120, 220, 120), true)
	incomeLabel.Size = UDim2.new(0.5, -10, 0, 18)
	incomeLabel.Position = UDim2.new(0.5, 0, 0, 32)
	incomeLabel.TextXAlignment = Enum.TextXAlignment.Right

	shardsLabel = makeLabel(rightPanel, "🌀 Chaos Shards: 0", 12, Color3.fromRGB(200, 140, 255), true)
	shardsLabel.Size = UDim2.new(1, -20, 0, 18)
	shardsLabel.Position = UDim2.new(0, 10, 0, 54)

	kosLabel = makeLabel(rightPanel, "💥 KOs: 0", 13, Color3.fromRGB(255, 255, 255), true)
	kosLabel.Size = UDim2.new(1, -20, 0, 18)
	kosLabel.Position = UDim2.new(0, 10, 0, 76)

	playersLabel = makeLabel(rightPanel, "👥 1", 12, Color3.fromRGB(200, 200, 210), false)
	playersLabel.Size = UDim2.new(0.5, -10, 0, 18)
	playersLabel.Position = UDim2.new(0, 10, 0, 98)

	teamLabel = makeLabel(rightPanel, "Team: —", 12, Color3.fromRGB(120, 200, 255), true)
	teamLabel.Size = UDim2.new(0.5, -10, 0, 18)
	teamLabel.Position = UDim2.new(0.5, 0, 0, 98)
	teamLabel.TextXAlignment = Enum.TextXAlignment.Right

	local rarityHint = makeLabel(rightPanel, "Rarity colours: see shop cards", 10, Color3.fromRGB(150, 150, 170), false)
	rarityHint.Size = UDim2.new(1, -20, 0, 16)
	rarityHint.Position = UDim2.new(0, 10, 0, 140)
	-- Equipped title (v1.1 E): set by AchievementController.
	titleLabel = makeLabel(rightPanel, "", 12, Color3.fromRGB(255, 215, 0), true)
	titleLabel.Size = UDim2.new(1, -20, 0, 16)
	titleLabel.Position = UDim2.new(0, 10, 0, 122)
	titleLabel.Visible = false
	-- Keep the RarityColors module referenced so the shared palette is
	-- loaded with the HUD (other controllers require it directly too).
	_ = RarityColors.Get("Legendary")

	-- Team colour from the player's Team object, if one is assigned.
	local team = LocalPlayer.Team
	if team then
		HUDController.SetTeam(team.Name, team.TeamColor.Color)
	end
	LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
		local newTeam = LocalPlayer.Team
		if newTeam then
			HUDController.SetTeam(newTeam.Name, newTeam.TeamColor.Color)
		end
	end)

	-- Player count updates whenever anyone joins or leaves.
	local function refreshPlayerCount()
		HUDController.SetPlayerCount(#Players:GetPlayers())
	end
	Players.PlayerAdded:Connect(refreshPlayerCount)
	Players.PlayerRemoving:Connect(refreshPlayerCount)
	refreshPlayerCount()

	-- ---- Bottom-left: carrying chip + base chip ---------------------------
	carryingChip = Instance.new("Frame")
	carryingChip.Name = "CarryingChip"
	carryingChip.Size = UDim2.new(0, 320, 0, 32)
	carryingChip.Position = UDim2.new(0, 14, 1, -118)
	carryingChip.BackgroundColor3 = Color3.fromRGB(200, 150, 30)
	carryingChip.BorderSizePixel = 0
	carryingChip.Visible = false
	carryingChip.Parent = gui
	corner(carryingChip, 8)
	carryingLabel = makeLabel(carryingChip, "", 13, Color3.fromRGB(255, 255, 255), true)
	carryingLabel.Size = UDim2.new(1, -16, 1, 0)
	carryingLabel.Position = UDim2.new(0, 8, 0, 0)

	baseChip = Instance.new("Frame")
	baseChip.Name = "BaseChip"
	baseChip.Size = UDim2.new(0, 320, 0, 28)
	baseChip.Position = UDim2.new(0, 14, 1, -82)
	baseChip.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	baseChip.BackgroundTransparency = 0.25
	baseChip.BorderSizePixel = 0
	baseChip.Visible = false
	baseChip.Parent = gui
	corner(baseChip, 8)
	stroke(baseChip, Color3.fromRGB(120, 220, 120), 1).Transparency = 0.6
	baseLabel = makeLabel(baseChip, "", 12, Color3.fromRGB(200, 240, 200), true)
	baseLabel.Size = UDim2.new(1, -16, 1, 0)
	baseLabel.Position = UDim2.new(0, 8, 0, 0)

	-- ---- Bottom-center: menu bar ------------------------------------------
	local menuBar = Instance.new("Frame")
	menuBar.Name = "MenuBar"
	menuBar.AnchorPoint = Vector2.new(0.5, 1)
	menuBar.Position = UDim2.new(0.5, 0, 1, -10)
	menuBar.Size = UDim2.new(0, 516, 0, 38)
	menuBar.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	menuBar.BackgroundTransparency = 0.25
	menuBar.BorderSizePixel = 0
	menuBar.Parent = gui
	corner(menuBar, 10)
	stroke(menuBar, Color3.fromRGB(255, 255, 255), 1).Transparency = 0.8

	local binds = getBinds()
	local menuButtons = {
		{ text = "MARKET", key = binds.Market or "N", module = "MarketController" },
		{ text = "SHOP", key = binds.Shop or "B", module = "ShopController" },
		{ text = "BRAINROTS", key = binds.Brainrots or "C", module = "CharacterSelectController" },
		{ text = "BASE", key = binds.Base or "V", module = "BaseController" },
		{ text = "QUESTS", key = binds.Quests or "J", module = "QuestController" },
		{ text = "COLLECTION", key = binds.Collection or "L", module = "CollectionController" },
	}
	for i, entry in menuButtons do
		local btn = Instance.new("TextButton")
		btn.Name = "Menu_" .. entry.module
		btn.Size = UDim2.new(0, 80, 0, 28)
		btn.Position = UDim2.new(0, 6 + (i - 1) * 85, 0, 5)
		btn.Text = entry.text .. " [" .. entry.key .. "]"
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = if isTouch then 10 else 11
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.BackgroundColor3 = Color3.fromRGB(60, 60, 100)
		btn.BorderSizePixel = 0
		corner(btn, 8)
		btn.Parent = menuBar
		btn.MouseButton1Click:Connect(function()
			openController(entry.module)
		end)
	end

	-- ---- Second menu row (v1.1 E): the new Wave 1+2 panels ------------
	-- LAB / EXPEDITIONS / TERRITORY / WORLDS / ACHIEVEMENTS open the
	-- new Wave 3 controllers through the same lazy openController.
	local menuBar2 = Instance.new("Frame")
	menuBar2.Name = "MenuBar2"
	menuBar2.AnchorPoint = Vector2.new(0.5, 1)
	menuBar2.Position = UDim2.new(0.5, 0, 1, -58)
	menuBar2.Size = UDim2.new(0, 440, 0, 38)
	menuBar2.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	menuBar2.BackgroundTransparency = 0.25
	menuBar2.BorderSizePixel = 0
	menuBar2.Parent = gui
	corner(menuBar2, 10)
	stroke(menuBar2, Color3.fromRGB(120, 80, 255), 1).Transparency = 0.8
	local menuButtons2 = {
		{ text = "LAB", module = "LaboratoryController" },
		{ text = "EXPEDITIONS", module = "ExpeditionController" },
		{ text = "TERRITORY", module = "TerritoryController" },
		{ text = "WORLDS", module = "DimensionController" },
		{ text = "ACHIEVEMENTS", module = "AchievementController" },
	}
	for i, entry in menuButtons2 do
		local btn = Instance.new("TextButton")
		btn.Name = "Menu2_" .. entry.module
		btn.Size = UDim2.new(0, 82, 0, 28)
		btn.Position = UDim2.new(0, 6 + (i - 1) * 87, 0, 5)
		btn.Text = entry.text
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = if isTouch then 10 else 11
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.BackgroundColor3 = Color3.fromRGB(90, 70, 160)
		btn.BorderSizePixel = 0
		corner(btn, 8)
		btn.Parent = menuBar2
		btn.MouseButton1Click:Connect(function()
			openController(entry.module)
		end)
	end

	-- ---- Death / victory screens (v1.1 E) -------------------------------
	deathScreen = Instance.new("Frame")
	deathScreen.Name = "DeathScreen"
	deathScreen.Size = UDim2.new(1, 0, 1, 0)
	deathScreen.BackgroundColor3 = Color3.fromRGB(20, 0, 0)
	deathScreen.BackgroundTransparency = 0.4
	deathScreen.BorderSizePixel = 0
	deathScreen.Visible = false
	deathScreen.ZIndex = 40
	deathScreen.Parent = gui
	local deathLabel = makeLabel(deathScreen, "💀 YOU DIED", 40, Color3.fromRGB(255, 80, 80), true)
	deathLabel.Size = UDim2.new(1, 0, 0, 60)
	deathLabel.Position = UDim2.new(0, 0, 0.4, -30)
	deathLabel.TextXAlignment = Enum.TextXAlignment.Center
	deathLabel.ZIndex = 41
	local deathSub = makeLabel(deathScreen, "Respawning… your Brainrots keep earning while you're away.", 14, Color3.fromRGB(255, 220, 220), false)
	deathSub.Size = UDim2.new(1, 0, 0, 22)
	deathSub.Position = UDim2.new(0, 0, 0.4, 34)
	deathSub.TextXAlignment = Enum.TextXAlignment.Center
	deathSub.ZIndex = 41

	victoryScreen = Instance.new("Frame")
	victoryScreen.Name = "VictoryScreen"
	victoryScreen.Size = UDim2.new(1, 0, 1, 0)
	victoryScreen.BackgroundColor3 = Color3.fromRGB(0, 30, 10)
	victoryScreen.BackgroundTransparency = 0.4
	victoryScreen.BorderSizePixel = 0
	victoryScreen.Visible = false
	victoryScreen.ZIndex = 40
	victoryScreen.Parent = gui
	victoryLabel = makeLabel(victoryScreen, "", 32, Color3.fromRGB(120, 255, 120), true)
	victoryLabel.Size = UDim2.new(1, 0, 0, 60)
	victoryLabel.Position = UDim2.new(0, 0, 0.4, -30)
	victoryLabel.TextXAlignment = Enum.TextXAlignment.Center
	victoryLabel.ZIndex = 41

	-- Mobile compact layout: narrower side panels so nothing overlaps.
	if isTouch then
		leftPanel.Size = UDim2.new(0, 210, 0, 86)
		questTracker.Size = UDim2.new(0, 210, 0, 30)
		rightPanel.Size = UDim2.new(0, 190, 0, 164)
		rightPanel.Position = UDim2.new(1, -204, 0, 14)
		centerPanel.Size = UDim2.new(0, 190, 0, 84)
		centerPanel.Position = UDim2.new(0.5, -95, 0, 14)
		tideBanner.Size = UDim2.new(0, 260, 0, 34)
		tideBanner.Position = UDim2.new(0.5, -130, 0, 106)
		menuBar.Size = UDim2.new(0, 516, 0, 44)
		carryingChip.Size = UDim2.new(0, 260, 0, 32)
		baseChip.Size = UDim2.new(0, 260, 0, 28)
	end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function HUDController.Init()
	if gui then
		return
	end
	build()

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		local ok, found = pcall(function()
			return ReplicatedStorage:WaitForChild("Remotes", 10)
		end)
		if ok and found then
			remotesFolder = found :: Folder
		end
	end
	if not remotesFolder then
		warn("[GlitchTide] HUDController: Remotes folder not found; HUD running without live feeds")
	else
		local remotes = remotesFolder :: Folder

		-- Round timer: server sends {TimeLeft=..., Phase=...} or a plain number.
		task.spawn(function()
			local ok, roundRemote = pcall(function()
				return remotes:WaitForChild("RoundUpdate", 10)
			end)
			if ok and roundRemote and roundRemote:IsA("RemoteEvent") then
				(roundRemote :: RemoteEvent).OnClientEvent:Connect(function(payload, phase)
					if typeof(payload) == "table" then
						HUDController.SetTimer(payload.TimeLeft or payload.timeLeft or payload.SecondsLeft, payload.Phase or payload.phase)
					elseif typeof(payload) == "number" then
						HUDController.SetTimer(payload, phase)
					end
				end)
			end
		end)

		-- Wave indicator: {Wave=..., EnemiesLeft=..., TotalEnemies=...} or a number.
		task.spawn(function()
			local ok, waveRemote = pcall(function()
				return remotes:WaitForChild("WaveUpdate", 10)
			end)
			if ok and waveRemote and waveRemote:IsA("RemoteEvent") then
				(waveRemote :: RemoteEvent).OnClientEvent:Connect(function(payload, enemiesLeft, totalEnemies)
					if typeof(payload) == "table" then
						HUDController.SetWave(
							payload.Wave or payload.wave,
							payload.EnemiesLeft or payload.enemiesLeft,
							payload.TotalEnemies or payload.totalEnemies
						)
					elseif typeof(payload) == "number" then
						HUDController.SetWave(payload, enemiesLeft, totalEnemies)
					end
				end)
			end
		end)

		-- Player stats: coins / gems / shards / XP / level / KOs / team.
		-- PlayerStats is a RemoteEvent in Remotes.luau and the server
		-- pushes it on join and on every change. WAVE 3 (v1.1 E)
		-- removed the old RemoteFunction branch: it polled InvokeServer
		-- every 5s on a remote that has no function handler — dead
		-- traffic (optimization note, QA_V11_E.md §15).
		local statsRemote = remotes:FindFirstChild("PlayerStats")
		if statsRemote and statsRemote:IsA("RemoteEvent") then
			(statsRemote :: RemoteEvent).OnClientEvent:Connect(applyPlayerStats)
		end

		-- Damage numbers landing on this player also flash the vignette lightly,
		-- in case a hit does not go through the Humanoid (e.g. shielded damage).
		-- Wave 3 (v1.1 E): the server fires a TABLE {target, amount, isCrit,
		-- isHeal} (CombatService) — the old positional (targetPlayer, amount)
		-- form never matched it, so the flash never fired.
		local damageRemote = remotes:FindFirstChild("DamageNumber")
		if damageRemote and damageRemote:IsA("RemoteEvent") then
			(damageRemote :: RemoteEvent).OnClientEvent:Connect(function(target, amount)
				local amt: number? = nil
				if typeof(target) == "table" then
					amt = tonumber(target.amount)
				elseif target == LocalPlayer and typeof(amount) == "number" then
					amt = amount
				end
				if amt ~= nil then
					HUDController.FlashDamage(math.clamp(amt / 50, 0.2, 0.8))
				end
			end)
		end

		-- Glitch Tide countdown banner.
		task.spawn(function()
			local ok, tideRemote = pcall(function()
				return remotes:WaitForChild("GlitchTideUpdate", 30)
			end)
			if ok and tideRemote and tideRemote:IsA("RemoteEvent") then
				(tideRemote :: RemoteEvent).OnClientEvent:Connect(applyTideUpdate)
			end
		end)

		-- World-event banner (v1.0.1 integration QA — EventService fired
		-- EventUpdate but NO client listened, so Golden Hour etc. ran
		-- silently). ShowEventBanner already existed; nothing called it.
		-- Wave 3 (v1.1 E, B): the rare-acquisition banner carries an
		-- extra SoundHook field ("rare" / "secret") — play it here.
		task.spawn(function()
			local ok, eventRemote = pcall(function()
				return remotes:WaitForChild("EventUpdate", 30)
			end)
			if ok and eventRemote and eventRemote:IsA("RemoteEvent") then
				(eventRemote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
					if typeof(payload) ~= "table" then
						return
					end
					local name = tostring(payload.Name or payload.EventId or "Event")
					local phase = tostring(payload.Phase or payload.phase or "")
					local text = "✨ " .. name
					if phase == "Started" then
						text ..= " started!"
						local mult = payload.IncomeMultiplier
						if typeof(mult) == "number" and mult > 1 then
							text ..= "  " .. tostring(mult) .. "x income!"
						end
					elseif phase == "Ended" then
						text ..= " ended."
					elseif phase ~= "" then
						text ..= " — " .. phase
					end
					local duration = payload.Duration
					HUDController.ShowEventBanner(text, if typeof(duration) == "number" and duration > 0 then duration else 8)
					local hook = payload.SoundHook
					if hook == "rare" or hook == "secret" then
						pcall(function()
							local mod = script.Parent:FindFirstChild("SoundController")
							if mod then
								local sound = require(mod)
								if sound.PlaySoundHook then
									sound.PlaySoundHook(hook)
								end
							end
						end)
					end
				end)
			end
		end)

		-- Boss health bar (v1.1 E, Workstream D): BossService fires
		-- BossUpdate on spawn / phase change / every 2s / death:
		-- {Event, BossId, BossName, Arena, Active, Health, MaxHealth,
		-- Phase}. Event "BossSpawned" shows the bar, "BossDied" hides
		-- it after a beat; Active=false hides it.
		task.spawn(function()
			local ok, bossRemote = pcall(function()
				return remotes:WaitForChild("BossUpdate", 30)
			end)
			if ok and bossRemote and bossRemote:IsA("RemoteEvent") then
				(bossRemote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
					if typeof(payload) ~= "table" then
						return
					end
					local event = tostring(payload.Event or "")
					local active = payload.Active ~= false
					if event == "BossDied" or not active then
						HUDController.SetBoss("", 0, 1)
						if event == "BossDied" then
							HUDController.ShowEventBanner("👹 " .. tostring(payload.BossName or "Boss") .. " defeated!", 8)
							pcall(function()
								local mod = script.Parent:FindFirstChild("SoundController")
								if mod then
									local sound = require(mod)
									if sound.PlayVictory then
										sound.PlayVictory()
									end
								end
							end)
						end
						return
					end
					HUDController.SetBoss(payload.BossName, payload.Health, payload.MaxHealth, payload.Phase)
					if event == "BossSpawned" then
						HUDController.ShowEventBanner("👹 BOSS: " .. tostring(payload.BossName or "?") .. " appeared in " .. tostring(payload.Arena or "the arena") .. "!", 8)
						pcall(function()
							local mod = script.Parent:FindFirstChild("SoundController")
							if mod then
								local sound = require(mod)
								if sound.PlayBoss then
									sound.PlayBoss()
								end
							end
						end)
					end
				end)
			end
		end)

		-- Active event on join + slow refresh (v1.1 E): the server's
		-- RequestEvents function returns GetActiveEvent() {Id, Name,
		-- EndsIn}; the HUD shows it so a player who joins mid-event
		-- sees it. 60s cadence — this is state, not a hot path.
		task.spawn(function()
			local requestEvents = remotes:FindFirstChild("RequestEvents")
			if not requestEvents or not requestEvents:IsA("RemoteFunction") then
				return
			end
			while gui do
				local ok, result = pcall(function()
					return (requestEvents :: RemoteFunction):InvokeServer()
				end)
				if ok and typeof(result) == "table" and typeof(result.Name) == "string" and result.Name ~= "" then
					local endsIn = result.EndsIn
					local suffix = if typeof(endsIn) == "number" and endsIn > 0
						then "  •  ends in " .. tostring(math.floor(endsIn / 60)) .. "m"
						else ""
					HUDController.ShowEventBanner("✨ Active event: " .. result.Name .. suffix, 10)
				end
				task.wait(60)
			end
		end)

		-- Tide survivor notice (v1.0.1 integration QA — TideService
		-- fired TideSurvivor {Survivors, Variation, RewardMultiplier}
		-- but NO client listened). Survivors are player names; show a
		-- personal line when this player survived, else the count.
		task.spawn(function()
			local ok, survivorRemote = pcall(function()
				return remotes:WaitForChild("TideSurvivor", 30)
			end)
			if ok and survivorRemote and survivorRemote:IsA("RemoteEvent") then
				(survivorRemote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
					if typeof(payload) ~= "table" then
						return
					end
					local variation = tostring(payload.Variation or "Glitch Tide")
					local survivors = payload.Survivors
					local count = 0
					local survived = false
					if typeof(survivors) == "table" then
						for _, name in survivors do
							count += 1
							if tostring(name) == LocalPlayer.Name then
								survived = true
							end
						end
					end
					local mult = payload.RewardMultiplier
					local multText = if typeof(mult) == "number" and mult > 1
						then "  Reward ×" .. tostring(mult) .. "!"
						else ""
					if survived then
						HUDController.ShowEventBanner("🌊 You survived the " .. variation .. " tide!" .. multText, 8)
						HUDController.ShowVictoryScreen(variation, mult)
					elseif count > 0 then
						HUDController.ShowEventBanner("🌊 " .. variation .. " tide ended — " .. tostring(count) .. " survivor" .. (if count == 1 then "" else "s") .. "." .. multText, 8)
					else
						HUDController.ShowEventBanner("🌊 " .. variation .. " tide ended." .. multText, 8)
					end
				end)
			end
		end)

		-- Base chip feed.
		task.spawn(function()
			local ok, baseRemote = pcall(function()
				return remotes:WaitForChild("BaseUpdate", 30)
			end)
			if ok and baseRemote and baseRemote:IsA("RemoteEvent") then
				(baseRemote :: RemoteEvent).OnClientEvent:Connect(applyBaseUpdate)
			end
		end)

		-- Carrying chip feed (InteractionController also drives it).
		task.spawn(function()
			local ok, carryRemote = pcall(function()
				return remotes:WaitForChild("CarryUpdate", 30)
			end)
			if ok and carryRemote and carryRemote:IsA("RemoteEvent") then
				(carryRemote :: RemoteEvent).OnClientEvent:Connect(applyCarryUpdate)
			end
		end)

		-- Ask the server for the current stats snapshot.
		-- WAVE 3 (v1.1 E) FIX: the old code fired PlayerStats with
		-- "GetStats" — PlayerStats is a RemoteEvent with NO server
		-- handler, so the fire was dead (audit F1). The server pushes
		-- PlayerStats itself on join and on every change; nothing
		-- needs to be asked for. Removed, not replaced.
	end

	-- Character / Humanoid binding, including respawns.
	if LocalPlayer.Character then
		bindCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(bindCharacter)

	HUDController.SetHealth(currentHealth, maxHealth)
	HUDController.SetCoins(coins)
	HUDController.SetGems(gems)
	HUDController.SetShards(shards)
	HUDController.SetIncome(incomePerSec)
	HUDController.SetRegion("Memeverse")
	HUDController.SetXP(xp, xpToNext, level)
	HUDController.SetKOs(kos)
	HUDController.SetTimer(0, "Waiting")
	HUDController.SetWave(1)
	HUDController.RefreshQuestTracker()

	-- Welcome banner on first open (v1.1 E onboarding): one line that
	-- tells a new player what to do first.
	if not welcomeShown then
		welcomeShown = true
		HUDController.ShowEventBanner("👋 Welcome to GLITCH TIDE! Buy Brainrots on the conveyor, place them in your base, and check 📜 Quests for your first goal.", 12)
	end

	print("[GlitchTide] HUDController ready")
end

return HUDController
