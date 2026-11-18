--!strict
-- CameraController.luau
-- Third-person camera for GLITCH TIDE. Two jobs:
--
--   1. CAMERA MANAGER (the fix for the stuck-camera bug). The default
--      Roblox camera only (re)binds its subject when the engine spawns a
--      character (CharacterAdded). CharacterService morphs the player by
--      DESTROYING the default avatar and assigning
--      `player.Character = <custom Brainrot model>` — that assignment
--      does NOT fire CharacterAdded, so the default camera kept pointing
--      at the destroyed Humanoid and stayed frozen at the spawn point
--      while the player walked away. This controller therefore owns the
--      binding explicitly: on EVERY CharacterAdded AND on every
--      `player.Character` property change (morph / swap), on respawn,
--      on teleport (camera left far behind the root), and on death /
--      recovery it waits for the live Humanoid + HumanoidRootPart
--      (with a timeout — never an infinite yield), sets
--      `CameraType = Custom` and `CameraSubject = <that Humanoid>`, and
--      snaps the CFrame to a sensible spot behind the character. A
--      watchdog every 0.5s rebinds if the subject is nil, dead, a
--      different Humanoid, or the CameraType drifted to Scriptable (no
--      scripted camera exists in this game, so any non-Custom type is
--      stale). It never fights the default camera afterwards: once
--      bound, the default camera script drives CFrame every frame.
--   2. FOV effects (unchanged): Glitch Tide punch-out, damage kick,
--      rare-purchase celebration. FOV-only; this file never writes
--      Camera.CFrame except for the one-off snap on (re)bind, and the
--      shake lives in EffectsController (BindToRenderStep, camera
--      priority + 1, offset-only).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

local CameraController = {}

local DEFAULT_FOV = 70
local activeTween: Tween? = nil
local restoring = false

-- Camera-manager tuning.
local BIND_TIMEOUT = 5 -- seconds to wait for Humanoid / HumanoidRootPart; never infinite
local WATCHDOG_INTERVAL = 0.5 -- seconds between watchdog checks
local SNAP_DISTANCE = 50 -- studs: camera farther than this from the root gets snapped (teleport / stuck camera)
local SNAP_BACK = 11 -- studs behind the character for the snap position
local SNAP_UP = 6 -- studs above the root for the snap position

local boundHumanoid: Humanoid? = nil
local boundCharacter: Model? = nil
local managerStarted = false

local function getCamera(): Camera?
	return workspace.CurrentCamera
end

-- Wait for a child with a hard timeout. Returns nil on timeout instead
-- of yielding forever (a morphed model that never replicates its
-- Humanoid must not hang the camera thread).
local function waitForChildTimeout(parent: Instance, name: string, timeout: number): Instance?
	local ok, child = pcall(function()
		return parent:WaitForChild(name, timeout)
	end)
	if ok and child then
		return child
	end
	return nil
end

-- The live (spawned, not dead, still parented) Humanoid + root of a
-- character model, or nil. A dead Humanoid is deliberately NOT returned:
-- the camera should keep looking at the corpse until the respawn /
-- morph arrives instead of rebinding to a dead subject every 0.5s.
local function getLiveHumanoid(character: Model?): (Humanoid?, BasePart?)
	if not character or not character.Parent then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return humanoid, nil
	end
	return humanoid, root :: BasePart
end

-- One-off snap: put the camera behind + above the root, looking at the
-- character. Only used on (re)bind / teleport recovery — never every
-- frame, or it would fight the default camera's own follow.
local function snapCameraToRoot(camera: Camera, root: BasePart)
	local rootPos = root.Position
	local look = root.CFrame.LookVector
	if look.Magnitude < 0.01 then
		look = Vector3.new(0, 0, 1)
	end
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 0.01 then
		look = Vector3.new(0, 0, 1)
	end
	look = look.Unit
	pcall(function()
		camera.CFrame = CFrame.lookAt(
			rootPos - look * SNAP_BACK + Vector3.new(0, SNAP_UP, 0),
			rootPos + Vector3.new(0, 2, 0)
		)
	end)
end

-- Bind the default camera to `character`'s live Humanoid. Returns true
-- on success. `snap` repositions the camera behind the character
-- (spawn / morph / teleport recovery); without it the camera keeps its
-- current position and the default script follows from there.
local function bindCamera(character: Model?, snap: boolean): boolean
	if not character then
		return false
	end
	-- Fast path: already bound to this character's live Humanoid.
	local liveHumanoid, liveRoot = getLiveHumanoid(character)
	if liveHumanoid and liveRoot and boundHumanoid == liveHumanoid and boundCharacter == character then
		local camera = getCamera()
		if camera and camera.CameraSubject == liveHumanoid and camera.CameraType == Enum.CameraType.Custom then
			return true
		end
	end

	-- Wait for the pieces the camera needs, with timeouts. The morph
	-- path parents the new model before assigning player.Character, so
	-- these usually exist already; the waits cover the respawn race
	-- where CharacterAdded fires before replication finishes.
	local humanoidObj = waitForChildTimeout(character, "Humanoid", BIND_TIMEOUT)
	local humanoid: Humanoid? = nil
	if humanoidObj and humanoidObj:IsA("Humanoid") then
		humanoid = humanoidObj
	end
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local rootObj = waitForChildTimeout(character, "HumanoidRootPart", BIND_TIMEOUT)
	local root: BasePart? = nil
	if rootObj and rootObj:IsA("BasePart") then
		root = rootObj
	end
	if not root then
		return false
	end

	-- The camera instance itself can be nil / replaced around respawns.
	local camera = getCamera()
	if not camera then
		for _ = 1, 20 do
			task.wait(0.1)
			camera = getCamera()
			if camera then
				break
			end
		end
	end
	if not camera then
		return false
	end

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	boundHumanoid = humanoid
	boundCharacter = character
	if snap then
		snapCameraToRoot(camera, root)
	end
	return true
end

-- True when the current binding is stale and must be repaired. Any
-- non-Custom CameraType counts as stale: nothing in this game ever sets
-- a scripted camera, so Scriptable / Fixed / etc. can only be leftovers
-- of a broken bind.
local function needsRebind(): boolean
	local camera = getCamera()
	if not camera then
		return false
	end
	if camera.CameraType ~= Enum.CameraType.Custom then
		return true
	end
	local character = LocalPlayer.Character
	local liveHumanoid, _ = getLiveHumanoid(character)
	if not liveHumanoid then
		-- No live character (dead / between spawns): leave the camera
		-- alone — it is correctly watching the corpse / nothing.
		return false
	end
	if camera.CameraSubject ~= liveHumanoid then
		return true
	end
	if boundHumanoid ~= liveHumanoid or boundCharacter ~= character then
		return true
	end
	return false
end

-- One watchdog pass: repair a stale binding (snapping, because the
-- camera was stuck or pointing at a destroyed Humanoid), otherwise
-- recover a camera left far behind its character (teleport / fling).
local function watchdogTick()
	if needsRebind() then
		task.spawn(bindCamera, LocalPlayer.Character, true)
		return
	end
	local camera = getCamera()
	local character = LocalPlayer.Character
	if not camera or not character then
		return
	end
	local _, root = getLiveHumanoid(character)
	if not root then
		return
	end
	if (camera.CFrame.Position - root.Position).Magnitude > SNAP_DISTANCE then
		snapCameraToRoot(camera, root)
	end
end

local function startCameraManager()
	if managerStarted then
		return
	end
	managerStarted = true

	-- Respawn: the engine fires this when a fresh default avatar loads
	-- (before CharacterService morphs it 0.2s later — the morph itself
	-- is caught by the Character property listener below).
	LocalPlayer.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindCamera, character, true)
	end)

	-- Morph / character swap: `player.Character = newModel` on the
	-- server does NOT fire CharacterAdded, but it DOES change the
	-- Character property. This is the listener that actually fixes the
	-- reported bug — without it the camera never learns about a morph.
	LocalPlayer:GetPropertyChangedSignal("Character"):Connect(function()
		local character = LocalPlayer.Character
		if character and character ~= boundCharacter then
			task.spawn(bindCamera, character, true)
		end
	end)

	-- Removal: forget the binding so the next spawn is not mistaken
	-- for "already bound" to a destroyed Humanoid.
	LocalPlayer.CharacterRemoving:Connect(function(_character: Model)
		boundHumanoid = nil
		boundCharacter = nil
	end)

	-- The camera instance can be replaced (respawn / streaming); bind
	-- the fresh instance to the same Humanoid.
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		task.spawn(bindCamera, LocalPlayer.Character, false)
	end)

	-- Bind whatever character is already present (Main waits for the
	-- first CharacterAdded before loading controllers, so this is the
	-- normal first-bind path, including a character already morphed).
	task.spawn(bindCamera, LocalPlayer.Character, true)

	-- Watchdog: repair drift the event listeners miss (subject cleared,
	-- CameraType flipped, teleport leaving the camera behind, a bind
	-- that raced replication and failed).
	task.spawn(function()
		while true do
			task.wait(WATCHDOG_INTERVAL)
			local ok, err = pcall(watchdogTick)
			if not ok then
				warn("[GlitchTide] CameraController watchdog error: " .. tostring(err))
			end
		end
	end)
end

-- Public API: other controllers / Main.client.luau can force a rebind
-- after a respawn, morph, or teleport they observe.
function CameraController.BindCamera(character: Model?)
	return bindCamera(character or LocalPlayer.Character, true)
end

function CameraController.Rebind(snap: boolean?)
	return bindCamera(LocalPlayer.Character, snap ~= false)
end

function CameraController.ForceSnap()
	local camera = getCamera()
	local character = LocalPlayer.Character
	if not camera or not character then
		return false
	end
	local _, root = getLiveHumanoid(character)
	if not root then
		return false
	end
	snapCameraToRoot(camera, root)
	return true
end

function CameraController.GetBoundHumanoid(): Humanoid?
	return boundHumanoid
end

-- ---------------------------------------------------------------------------
-- FOV effects (unchanged behaviour).
-- ---------------------------------------------------------------------------

local function tweenFov(target: number, duration: number, onDone: (() -> ())?)
	local camera = getCamera()
	if not camera then
		return
	end
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	restoring = false
	local tween = TweenService:Create(
		camera,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = target }
	)
	activeTween = tween
	tween.Completed:Connect(function()
		activeTween = nil
		if onDone then
			onDone()
		end
	end)
	tween:Play()
end

local function restoreFov(duration: number?)
	if restoring then
		return
	end
	restoring = true
	tweenFov(DEFAULT_FOV, duration or 0.5, function()
		restoring = false
	end)
end

-- Short punch-out then restore (tide start, big hits).
function CameraController.Punch(strength: number?)
	local amount = math.clamp(strength or 0.5, 0.1, 1)
	tweenFov(DEFAULT_FOV + 8 * amount, 0.25, function()
		restoreFov(0.6)
	end)
end

-- Slow zoom-in then restore (rare purchase celebration).
function CameraController.Celebrate()
	tweenFov(DEFAULT_FOV - 8, 0.6, function()
		task.wait(0.4)
		restoreFov(0.8)
	end)
end

local RARE_RARITIES: { [string]: boolean } = {
	Legendary = true,
	Mythic = true,
	Divine = true,
	Celestial = true,
	Secret = true,
	Glitch = true,
	Impossible = true,
}

local function onSpawnEffect(effectType: any, _position: any, extra: any)
	if typeof(effectType) ~= "string" then
		return
	end
	if effectType == "celebrate" or effectType == "rare" or effectType == "legendary" then
		CameraController.Celebrate()
		return
	end
	if effectType == "purchase" or effectType == "buy" then
		local rarity: string? = nil
		if typeof(extra) == "table" then
			rarity = extra.Rarity or extra.rarity
		elseif typeof(extra) == "string" then
			rarity = extra
		end
		if rarity and RARE_RARITIES[rarity] then
			CameraController.Celebrate()
		end
	end
end

local function onDamageNumber(a: any, b: any, _c: any, _d: any)
	-- DamageNumber payloads vary: (position, amount, ...) from the
	-- EffectsController, or (targetPlayer, amount) from the HUD path.
	-- Only react to a plain number amount aimed at the local player.
	local amount: number? = nil
	if typeof(a) == "number" then
		amount = a
	elseif typeof(b) == "number" and a == LocalPlayer then
		amount = b
	end
	if amount and amount > 0 then
		CameraController.Punch(math.clamp(amount / 60, 0.15, 0.6))
	end
end

local function onGlitchTideUpdate(payload: any, _seconds: any)
	local phase: string? = nil
	if typeof(payload) == "table" then
		phase = payload.Phase or payload.phase
	elseif typeof(payload) == "string" then
		phase = payload
	end
	if phase == "Tide" or phase == "active" then
		CameraController.Punch(1)
	end
end

function CameraController.Init()
	-- Camera manager first: bind the current character and start the
	-- watchdog before any FOV remote can fire.
	startCameraManager()

	task.spawn(function()
		local folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			local ok, found = pcall(function()
				return ReplicatedStorage:WaitForChild("Remotes", 10)
			end)
			if not ok or not found then
				return
			end
			folder = found :: Folder
		end
		local function waitRemote(name: string, timeout: number): RemoteEvent?
			local ok, remote = pcall(function()
				return folder:WaitForChild(name, timeout)
			end)
			if ok and remote and remote:IsA("RemoteEvent") then
				return remote :: RemoteEvent
			end
			return nil
		end
		local spawnEffect = waitRemote("SpawnEffect", 30)
		if spawnEffect then
			spawnEffect.OnClientEvent:Connect(onSpawnEffect)
		end
		local damageNumber = waitRemote("DamageNumber", 10)
		if damageNumber then
			damageNumber.OnClientEvent:Connect(onDamageNumber)
		end
		local tide = waitRemote("GlitchTideUpdate", 10)
		if tide then
			tide.OnClientEvent:Connect(onGlitchTideUpdate)
		end
	end)
	print("[GlitchTide] CameraController ready (CameraManager: Custom + subject bind + 0.5s watchdog; FOV-only effects)")
end

return CameraController
