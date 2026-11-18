--!strict
-- SoundController.luau
-- Client-side sound effects for GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE
-- using ONLY Roblox built-in sounds. No external asset IDs are used
-- anywhere: every SoundId is an rbxasset:// path that ships with the
-- Roblox client, so the game works with zero uploaded audio. Every play
-- call is wrapped in pcall so a missing built-in path on some client can
-- never break gameplay.
--
-- VERIFIED PATHS (see docs/QA_V11_E.md §5 for sources — do not add a path
-- without a source in that table):
--   * Roblox client script RbxCharacterSounds.lua (CloneTrooper1019 /
--     Roblox-Client-Tracker, current client): action_get_up.mp3,
--     action_jump.mp3, action_jump_land.mp3, action_footsteps_plastic.mp3,
--     action_falling.ogg, action_swim.mp3, impact_water.mp3, uuhhh.mp3.
--   * RoClicks "Sound sourcing and upload" engine-built-ins list:
--     electronicpingshort.wav, switch.wav, button.wav, clickfast.wav,
--     snap.wav, hit.wav, victory.wav, collide.wav, splat.wav — with the
--     caveat that not every built-in exists on every build, so every
--     play is pcall-guarded and a missing file is silence, not an error.
--   * Gear-sound lists (weaker source, one path only): swordslash.wav
--     (melee swing). Used once, documented as the weakest verification.
-- UNASSIGNED SLOTS (no verified built-in exists — see SOUND_SLOTS below
-- and docs/QA_V11_E.md §5): market ambience loop, conveyor loop,
-- background music, dimension ambience, tide siren loop. These slots
-- are named in code so a licensed Creator Store / own-upload audio ID
-- can be dropped in later WITHOUT inventing an rbxassetid:// ID today.
-- NEVER invent a Roblox asset ID: an unassigned slot plays nothing.
--
-- VOLUMES: master (0..1, the old SetVolume/GetVolume API) × SFX (0..1)
-- scale every one-shot; music (0..1) is stored for the future music
-- system and currently scales nothing audible — it is NOT claimed to
-- change any sound today. Mute overrides everything. Settings are
-- CLIENT-LOCAL by design (see docs/REMOTES_WIRED_E.md): there is no
-- server settings store and no DataService field for them, so
-- SettingsUpdate is deliberately never fired — firing it would be a
-- silent no-op dressed as a sync. No server SoundService exists for
-- the same reason: every sound here is a client-side one-shot triggered
-- by a broadcast the client already receives.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local SoundController = {}

local muted = false
-- Master volume, 0..1. Multiplies every sound's default volume.
local volume = 1
-- SFX bus volume, 0..1. Multiplies with master on every one-shot.
local sfxVolume = 1
-- Music bus volume, 0..1. Stored for the future music system; no music
-- sound exists yet (see SOUND_SLOTS), so today it scales nothing.
local musicVolume = 0.7
local soundFolder: Folder? = nil
local sounds: { [string]: Sound } = {}

local Utils: any = nil
pcall(function()
	Utils = require(ReplicatedStorage:WaitForChild("Utils", 10))
end)

-- Built-in Roblox sound paths only. These ship with the client and need no
-- upload, no asset ID and no moderation review. See the header for the
-- verification source of each path.
local SOUND_PATHS: { [string]: string } = {
	hit = "rbxasset://sounds/impact_water.mp3",
	ko = "rbxasset://sounds/electronicpingshort.wav",
	coin = "rbxasset://sounds/electronicpingshort.wav",
	ability = "rbxasset://sounds/action_get_up.mp3",
	click = "rbxasset://sounds/clickfast.wav",
	wave = "rbxasset://sounds/action_get_up.mp3",
	win = "rbxasset://sounds/victory.wav",
	lose = "rbxasset://sounds/uuhhh.mp3",
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
	-- Wave 3 (v1.1 E) cues — verified paths only (see header).
	swing = "rbxasset://sounds/swordslash.wav",
	damage = "rbxasset://sounds/hit.wav",
	rare = "rbxasset://sounds/electronicpingshort.wav",
	secret = "rbxasset://sounds/victory.wav",
	discover = "rbxasset://sounds/snap.wav",
	mutation = "rbxasset://sounds/switch.wav",
	fusion = "rbxasset://sounds/snap.wav",
	evolve = "rbxasset://sounds/action_get_up.mp3",
	boss = "rbxasset://sounds/collide.wav",
	siren = "rbxasset://sounds/electronicpingshort.wav",
	victory = "rbxasset://sounds/victory.wav",
	defeat = "rbxasset://sounds/uuhhh.mp3",
	teleport = "rbxasset://sounds/action_jump.mp3",
	land = "rbxasset://sounds/action_jump_land.mp3",
	jump = "rbxasset://sounds/action_jump.mp3",
	capture = "rbxasset://sounds/button.wav",
	achievement = "rbxasset://sounds/victory.wav",
	expedition = "rbxasset://sounds/electronicpingshort.wav",
	splash = "rbxasset://sounds/impact_water.mp3",
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
	swing = { volume = 0.7, pitch = 1.0 },
	damage = { volume = 0.6, pitch = 0.9 },
	rare = { volume = 0.8, pitch = 1.8 },
	secret = { volume = 0.8, pitch = 1.0 },
	discover = { volume = 0.7, pitch = 1.3 },
	mutation = { volume = 0.7, pitch = 1.0 },
	fusion = { volume = 0.7, pitch = 1.1 },
	evolve = { volume = 0.8, pitch = 1.2 },
	boss = { volume = 0.9, pitch = 0.7 },
	siren = { volume = 0.8, pitch = 0.6 },
	victory = { volume = 0.8, pitch = 1.0 },
	defeat = { volume = 0.7, pitch = 0.8 },
	teleport = { volume = 0.7, pitch = 1.1 },
	land = { volume = 0.5, pitch = 1.0 },
	jump = { volume = 0.5, pitch = 1.1 },
	capture = { volume = 0.7, pitch = 1.2 },
	achievement = { volume = 0.8, pitch = 1.0 },
	expedition = { volume = 0.7, pitch = 1.5 },
	splash = { volume = 0.6, pitch = 1.0 },
}

-- UNASSIGNED SOUND SLOTS — deliberately empty. There is no verified
-- built-in loop/ambience/music path for these, and inventing an
-- rbxassetid:// ID would be a fake. To fill a slot later: add a
-- licensed audio asset (Creator Store audio you have rights to, or an
-- own upload), put its SoundId in SOUND_PATHS under the slot's key,
-- add a SOUND_DEFAULTS entry, and add a Play* wrapper below. Until
-- then PlaySound(slot) is a silent no-op and IsAssigned(slot) is false.
local SOUND_SLOTS: { [string]: string } = {
	marketAmbience = "Looped market ambience (no verified built-in loop; add a licensed Creator Store / own-upload audio ID).",
	conveyorLoop = "Looped conveyor hum (no verified built-in loop; add a licensed audio ID).",
	music = "Background music loop (no verified built-in music; add a licensed audio ID).",
	dimensionAmbience = "Abyssal / Skyfall ambience loop (no verified built-in loop; add a licensed audio ID).",
	tideSirenLoop = "Looped tide siren (the one-shot siren cue IS assigned; a loop is not — add a licensed audio ID).",
}

function SoundController.IsAssigned(name: string): boolean
	return SOUND_PATHS[name] ~= nil
end

function SoundController.GetUnassignedSlots(): { [string]: string }
	local copy: { [string]: string } = {}
	for k, v in SOUND_SLOTS do
		copy[k] = v
	end
	return copy
end

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
		-- master × SFX volumes scale the default.
		sound.Volume = if volumeOverride ~= nil then volumeOverride else defaults.volume * volume * sfxVolume
		-- Small random pitch variation keeps repeated hits from sounding robotic.
		sound.PlaybackSpeed = math.clamp(jitter(defaults.pitch, 0.12), 0.4, 2.5)
		sound:Play()
	end)
	if not ok then
		-- A failed built-in sound must never surface as an error to the player.
		return
	end
end

-- SoundHook entry point: EventUpdate payloads from CompanionService carry
-- SoundHook "rare" | "secret". The HUD calls this with the hook value;
-- unknown hooks are ignored (never an error, never a fake sound).
function SoundController.PlaySoundHook(hook: any)
	if hook == "rare" then
		SoundController.PlayRare()
	elseif hook == "secret" then
		SoundController.PlaySecret()
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

-- ---- Wave 3 (v1.1 E) cues -----------------------------------------------
-- Melee swing (left-click Attack) + taking damage.
function SoundController.PlaySwing()
	SoundController.PlaySound("swing")
end

function SoundController.PlayDamage()
	SoundController.PlaySound("damage")
end

-- Rare acquisition sting (SoundHook "rare" from CompanionService).
function SoundController.PlayRare()
	SoundController.PlaySound("rare")
	task.delay(0.18, function()
		SoundController.PlaySound("rare")
	end)
end

-- Secret acquisition sting (SoundHook "secret"). Longer than the rare
-- sting so a Secret / Impossible pull sounds different.
function SoundController.PlaySecret()
	SoundController.PlaySound("secret")
	task.delay(0.25, function()
		SoundController.PlaySound("rare")
	end)
	task.delay(0.5, function()
		SoundController.PlaySound("secret")
	end)
end

-- Generic discovery tick (secret found, chest opened, checkpoint done).
function SoundController.PlayDiscover()
	SoundController.PlaySound("discover")
end

function SoundController.PlayMutation()
	SoundController.PlaySound("mutation")
end

function SoundController.PlayFusion()
	SoundController.PlaySound("fusion")
	task.delay(0.2, function()
		SoundController.PlaySound("mutation")
	end)
end

function SoundController.PlayEvolve()
	SoundController.PlaySound("evolve")
	task.delay(0.2, function()
		SoundController.PlaySound("mutation")
	end)
end

-- Boss spawn / phase change: low collide thud + alarm ping.
function SoundController.PlayBoss()
	SoundController.PlaySound("boss")
	task.delay(0.3, function()
		SoundController.PlaySound("stealAlarm")
	end)
end

-- Tide siren: three low pings (stage 3 of the tide anticipation).
function SoundController.PlaySiren()
	for i = 1, 3 do
		task.delay((i - 1) * 0.35, function()
			SoundController.PlaySound("siren")
		end)
	end
end

function SoundController.PlayVictory()
	SoundController.PlaySound("victory")
end

function SoundController.PlayDefeat()
	SoundController.PlaySound("defeat")
end

function SoundController.PlayTeleport()
	SoundController.PlaySound("teleport")
end

function SoundController.PlayJump()
	SoundController.PlaySound("jump")
end

function SoundController.PlayLand()
	SoundController.PlaySound("land")
end

function SoundController.PlayCapture()
	SoundController.PlaySound("capture")
end

function SoundController.PlayAchievement()
	SoundController.PlaySound("achievement")
end

function SoundController.PlayExpedition()
	SoundController.PlaySound("expedition")
end

function SoundController.PlaySplash()
	SoundController.PlaySound("splash")
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

-- SFX bus volume 0..1 (clamped). Multiplies with master on every
-- one-shot. This is what the Settings SFX stepper changes.
function SoundController.GetSFXVolume(): number
	return sfxVolume
end

function SoundController.SetSFXVolume(value: number)
	sfxVolume = math.clamp(tonumber(value) or 1, 0, 1)
end

-- Music bus volume 0..1 (clamped). Stored for the future music system;
-- no music sound exists yet (see SOUND_SLOTS), so today it scales
-- nothing audible. It is exposed now so the Settings music stepper is
-- wired to a real value instead of a dead control.
function SoundController.GetMusicVolume(): number
	return musicVolume
end

function SoundController.SetMusicVolume(value: number)
	musicVolume = math.clamp(tonumber(value) or 0.7, 0, 1)
end

function SoundController.GetVolumes(): { Master: number, SFX: number, Music: number }
	return { Master = volume, SFX = sfxVolume, Music = musicVolume }
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
