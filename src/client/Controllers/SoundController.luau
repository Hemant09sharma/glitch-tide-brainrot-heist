--!strict
-- SoundController.luau
-- Client-side sound effects for GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE
-- using ONLY Roblox built-in sounds. No external asset IDs are used
-- anywhere: every SoundId is an rbxasset:// path that ships with the
-- Roblox client, so the game works with zero uploaded audio. Every play
-- call is wrapped in pcall so a missing built-in path on some client can
-- never break gameplay.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local SoundController = {}

local muted = false
-- Master SFX volume, 0..1. Multiplies every sound's default volume.
-- There is NO music system in v1.0.0 (no music asset, no music loop
-- anywhere in src/) — this volume governs SFX only. Mute (M / menu)
-- is separate and overrides volume.
local volume = 1
local soundFolder: Folder? = nil
local sounds: { [string]: Sound } = {}

local Utils: any = nil
pcall(function()
	Utils = require(ReplicatedStorage:WaitForChild("Utils", 10))
end)

-- Built-in Roblox sound paths only. These ship with the client and need no
-- upload, no asset ID and no moderation review.
local SOUND_PATHS: { [string]: string } = {
	hit = "rbxasset://sounds/impact_water.mp3",
	ko = "rbxasset://sounds/electronicpingshort.wav",
	coin = "rbxasset://sounds/electronicpingshort.wav",
	ability = "rbxasset://sounds/action_get_up.mp3",
	click = "rbxasset://sounds/electronicpingshort.wav",
	wave = "rbxasset://sounds/action_get_up.mp3",
	win = "rbxasset://sounds/electronicpingshort.wav",
	lose = "rbxasset://sounds/impact_water.mp3",
	spawn = "rbxasset://sounds/action_get_up.mp3",
	buy = "rbxasset://sounds/electronicpingshort.wav",
	error = "rbxasset://sounds/impact_water.mp3",
	-- Heist loop sounds (same built-in-only rule).
	conveyor = "rbxasset://sounds/action_get_up.mp3",
	chaChing = "rbxasset://sounds/electronicpingshort.wav",
	place = "rbxasset://sounds/impact_water.mp3",
	stealAlarm = "rbxasset://sounds/electronicpingshort.wav",
	glitchWarning = "rbxasset://sounds/action_get_up.mp3",
	pickup = "rbxasset://sounds/electronicpingshort.wav",
	upgrade = "rbxasset://sounds/electronicpingshort.wav",
}

-- Per-sound defaults. Pitch is varied at play time for variety.
local SOUND_DEFAULTS: { [string]: { volume: number, pitch: number } } = {
	hit = { volume = 0.6, pitch = 1.0 },
	ko = { volume = 0.8, pitch = 0.8 },
	coin = { volume = 0.5, pitch = 1.4 },
	ability = { volume = 0.7, pitch = 1.1 },
	click = { volume = 0.4, pitch = 1.2 },
	wave = { volume = 0.7, pitch = 0.9 },
	win = { volume = 0.8, pitch = 1.2 },
	lose = { volume = 0.7, pitch = 0.6 },
	spawn = { volume = 0.5, pitch = 1.0 },
	buy = { volume = 0.6, pitch = 1.3 },
	error = { volume = 0.5, pitch = 0.7 },
	conveyor = { volume = 0.45, pitch = 1.0 },
	chaChing = { volume = 0.7, pitch = 1.5 },
	place = { volume = 0.6, pitch = 0.9 },
	stealAlarm = { volume = 0.8, pitch = 0.7 },
	glitchWarning = { volume = 0.8, pitch = 0.6 },
	pickup = { volume = 0.5, pitch = 1.1 },
	upgrade = { volume = 0.7, pitch = 1.4 },
}

local function ensureFolder(): Folder
	if soundFolder then
		return soundFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "BrainrotSounds"
	folder.Parent = player:WaitForChild("PlayerGui")
	soundFolder = folder
	return folder
end

local function getSound(name: string): Sound?
	local existing = sounds[name]
	if existing then
		return existing
	end
	local path = SOUND_PATHS[name]
	if not path then
		return nil
	end
	local ok, sound = pcall(function()
		local s = Instance.new("Sound")
		s.Name = name
		s.SoundId = path
		s.Parent = ensureFolder()
		return s
	end)
	if not ok or not sound then
		return nil
	end
	sounds[name] = sound
	return sound
end

local function jitter(value: number, amount: number): number
	return value + (math.random() * 2 - 1) * amount
end

function SoundController.PlaySound(name: string, volumeOverride: number?)
	if muted then
		return
	end
	local sound = getSound(name)
	if not sound then
		return
	end
	local defaults = SOUND_DEFAULTS[name] or { volume = 0.5, pitch = 1.0 }
	local ok = pcall(function()
		-- volumeOverride replaces the default outright; otherwise the
		-- master volume scales the default.
		sound.Volume = if volumeOverride ~= nil then volumeOverride else defaults.volume * volume
		-- Small random pitch variation keeps repeated hits from sounding robotic.
		sound.PlaybackSpeed = math.clamp(jitter(defaults.pitch, 0.12), 0.4, 2.5)
		sound:Play()
	end)
	if not ok then
		-- A failed built-in sound must never surface as an error to the player.
		return
	end
end

function SoundController.PlayHit()
	SoundController.PlaySound("hit")
end

function SoundController.PlayKO()
	SoundController.PlaySound("ko")
end

function SoundController.PlayCoin()
	SoundController.PlaySound("coin")
end

function SoundController.PlayAbility()
	SoundController.PlaySound("ability")
end

function SoundController.PlayClick()
	SoundController.PlaySound("click")
end

function SoundController.PlayWaveStart()
	SoundController.PlaySound("wave")
end

function SoundController.PlayWin()
	SoundController.PlaySound("win")
end

function SoundController.PlayLose()
	SoundController.PlaySound("lose")
end

function SoundController.PlaySpawn()
	SoundController.PlaySound("spawn")
end

function SoundController.PlayBuy()
	SoundController.PlaySound("buy")
end

-- Cha-ching: the buy confirmation sound (same built-in ping, higher pitch).
function SoundController.PlayBuyChaChing()
	SoundController.PlaySound("chaChing")
end

function SoundController.PlayConveyorSpawn()
	SoundController.PlaySound("conveyor")
end

function SoundController.PlayPlace()
	SoundController.PlaySound("place")
end

function SoundController.PlayPickup()
	SoundController.PlaySound("pickup")
end

function SoundController.PlayUpgrade()
	SoundController.PlaySound("upgrade")
end

-- Steal alarm: played twice in quick succession so it cuts through combat.
function SoundController.PlayStealAlarm()
	SoundController.PlaySound("stealAlarm")
	task.delay(0.25, function()
		SoundController.PlaySound("stealAlarm")
	end)
end

function SoundController.PlayGlitchWarning()
	SoundController.PlaySound("glitchWarning")
	task.delay(0.3, function()
		SoundController.PlaySound("glitchWarning")
	end)
end

function SoundController.PlayError()
	SoundController.PlaySound("error")
end

function SoundController.IsMuted(): boolean
	return muted
end

-- Master SFX volume 0..1 (clamped). Applies to sounds already playing
-- as well as future ones; 0 is silence but is NOT mute (IsMuted stays
-- false, so un-muting logic never fights it).
function SoundController.GetVolume(): number
	return volume
end

function SoundController.SetVolume(value: number)
	-- Applies to the next PlaySound call (SFX are short one-shots, so
	-- there is no long-lived sound worth re-scaling mid-play).
	volume = math.clamp(tonumber(value) or 1, 0, 1)
end

function SoundController.SetMuted(value: boolean)
	muted = value
	if muted then
		for _, sound in sounds do
			pcall(function()
				sound:Stop()
			end)
		end
	end
end

function SoundController.ToggleMute(): boolean
	SoundController.SetMuted(not muted)
	return muted
end

function SoundController.Init()
	-- Pre-create the folder and the most common sounds so the first hit
	-- does not pay the Instance creation cost mid-combat.
	ensureFolder()
	getSound("hit")
	getSound("click")
	getSound("coin")

	-- Mute key from the shared bind table (Utils), resolved once here
	-- instead of a literal Enum.KeyCode.M in the handler.
	local muteCode: Enum.KeyCode = Enum.KeyCode.M
	if Utils and Utils.GetKeybinds and Utils.KeyCodeFor then
		local ok, binds = pcall(function()
			return Utils.GetKeybinds()
		end)
		if ok and type(binds) == "table" and type(binds.Mute) == "string" then
			muteCode = Utils.KeyCodeFor(binds.Mute) or Enum.KeyCode.M
		end
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == muteCode then
			SoundController.ToggleMute()
		end
	end)
end

return SoundController
