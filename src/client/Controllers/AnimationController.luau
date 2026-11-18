--!strict
-- AnimationController.luau
-- Procedural client-side animation for GLITCH TIDE — BRAINROT HEIST:
-- THE MEMEVERSE. No external animation IDs are used: everything is driven
-- by RunService.RenderStepped plus CFrame offsets — Motor6D joints on a
-- rigged avatar, and whole-model root deltas on a morphed Brainrot
-- (morphed models have NO Motor6D joints and no Torso, so the old code
-- could only spin/idle them). Applies to the local player's character
-- only and stops cleanly on death / respawn. Includes the carry pose:
-- arms up, Brainrot held overhead and bobbing, with a slowed walk.
--
-- v1.1 (Workstream B): per-character animation profiles derived from
-- the character's own def (Personality / Speed / Scale), so a wobbly
-- waffle wobbles, a party dumpling dances, a glitchy goose glitches
-- and a regal king sways instead of bobbing. Full animation set:
-- idle / walk / run / jump / land / dance / celebrate / attack /
-- damage / rare-discovery, plus mutation/fusion transform effects
-- (PlayMutationTransform / PlayFusionTransform, and automatic pickup
-- of the "TransformKind" attribute CharacterModels.PlayTransformEffect
-- stamps on the model when MutationService / FusionService mutate or
-- fuse a Brainrot).
--
-- MORPH-MODEL TECHNIQUE: the root CFrame is physics-driven, so the
-- controller never SETS it — it applies only the DELTA of the desired
-- bob / roll / yaw since last frame (tracked in lastBobY / lastRoll /
-- lastYaw). Movement between frames is untouched, so the animation
-- cannot fight walking, teleporting or the camera snap.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local AnimationController = {}

local Characters: any = nil
pcall(function()
	Characters = require(ReplicatedStorage:WaitForChild("Characters", 10))
end)

-- EffectsController is optional (flash on rare discovery / transform).
local EffectsController: any = nil
pcall(function()
	EffectsController = require(script.Parent:WaitForChild("EffectsController", 5))
end)

type JointSet = {
	root: Motor6D?,
	leftArm: Motor6D?,
	rightArm: Motor6D?,
	leftLeg: Motor6D?,
	rightLeg: Motor6D?,
}

-- Per-character animation profile, derived from the character def.
export type AnimationProfile = {
	CharacterId: string,
	IdleStyle: string, -- "bob" | "wobble" | "float" | "bounce" | "glitch" | "calm" | "menace"
	WalkStyle: string, -- "normal" | "waddle" | "zoom" | "heavy"
	BobAmp: number,
	BobRate: number,
	WalkRate: number,
	DanceStyle: string, -- "spin" | "bounce" | "sway" | "glitch"
}

local DEFAULT_PROFILE: AnimationProfile = {
	CharacterId = "",
	IdleStyle = "bob",
	WalkStyle = "normal",
	BobAmp = 0.05,
	BobRate = 2.2,
	WalkRate = 9,
	DanceStyle = "bounce",
}

local currentCharacter: Model? = nil
local humanoid: Humanoid? = nil
local joints: JointSet = {
	root = nil,
	leftArm = nil,
	rightArm = nil,
	leftLeg = nil,
	rightLeg = nil,
}
local rootPart: BasePart? = nil
local torso: BasePart? = nil
local isMorph: boolean = false
local currentCharacterId: string = ""
local profile: AnimationProfile = DEFAULT_PROFILE

local renderConnection: RBXScriptConnection? = nil
local deathConnection: RBXScriptConnection? = nil

-- Animation state, written by other controllers / input handlers.
local state = {
	walking = false,
	attacking = false,
	jumping = false,
	spinning = false,
	carrying = false,
	attackTime = 0,
	spinTime = 0,
	walkPhase = 0,
	idlePhase = 0,
	-- v1.1 effect timers (seconds remaining).
	danceTime = 0,
	celebrateTime = 0,
	damageTime = 0,
	transformTime = 0,
	landTime = 0,
	wasAirborne = false,
	-- Morph root-delta bookkeeping (applied offsets last frame).
	lastBobY = 0,
	lastRoll = 0,
	lastYaw = 0,
	lastTransformKind = nil :: string?,
}

local BASE_C0: { [string]: CFrame } = {}

local function findMotor(parent: Instance, name: string): Motor6D?
	local child = parent:FindFirstChild(name)
	if child and child:IsA("Motor6D") then
		return child
	end
	return nil
end

-- R6 motors are "Left Shoulder" / "Left Hip" (spaced); R15 motors are
-- "LeftShoulder" / "LeftHip" (no space) and live on UpperTorso. Try
-- both spellings so the animation works on either rig.
local function findLimbMotor(torsoPart: BasePart, r6Name: string, r15Name: string): Motor6D?
	return findMotor(torsoPart, r6Name) or findMotor(torsoPart, r15Name)
end

local function cacheBaseC0()
	BASE_C0 = {}
	for name, joint in pairs(joints :: { [string]: Motor6D? }) do
		if joint then
			BASE_C0[name] = joint.C0
		end
	end
end

local function restoreJoints()
	for name, joint in pairs(joints :: { [string]: Motor6D? }) do
		if joint and BASE_C0[name] then
			joint.C0 = BASE_C0[name]
		end
	end
end

-- Remove any residual morph root offsets (best effort, pcall-guarded:
-- the root may already be destroyed on death).
local function clearMorphOffsets()
	local root = rootPart
	if root ~= nil and root.Parent ~= nil then
		local r = root :: BasePart
		pcall(function()
			r.CFrame = r.CFrame * CFrame.new(0, -state.lastBobY, 0)
			r.CFrame = r.CFrame * CFrame.Angles(0, -state.lastYaw, -state.lastRoll)
		end)
	end
	state.lastBobY = 0
	state.lastRoll = 0
	state.lastYaw = 0
end

local function stopLoop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if deathConnection then
		deathConnection:Disconnect()
		deathConnection = nil
	end
	restoreJoints()
	clearMorphOffsets()
end

-- Derive a character's animation profile from its def. Personality is
-- the primary signal (the defs were written with it in mind); Speed
-- and Scale tune the rates. Unknown ids get the default profile.
local function deriveProfile(characterId: string): AnimationProfile
	local out: AnimationProfile = {
		CharacterId = characterId,
		IdleStyle = "bob",
		WalkStyle = "normal",
		BobAmp = 0.05,
		BobRate = 2.2,
		WalkRate = 9,
		DanceStyle = "bounce",
	}
	local def: any = nil
	if Characters ~= nil and type(Characters.GetById) == "function" then
		local ok, found = pcall(function()
			return Characters.GetById(characterId)
		end)
		if ok then
			def = found
		end
	end
	if def == nil then
		return out
	end
	local personality = string.lower(tostring(def.Personality or ""))
	local speed = tonumber(def.Speed) or 16
	local scale = tonumber(def.Scale) or 1
	out.BobAmp = 0.04 + scale * 0.02
	out.BobRate = 1.8 + math.min(speed, 25) * 0.04
	out.WalkRate = 7 + speed * 0.15
	-- Idle style from Personality keywords.
	if string.find(personality, "wobbl") or string.find(personality, "jiggl") then
		out.IdleStyle = "wobble"
		out.DanceStyle = "sway"
	elseif string.find(personality, "party") or string.find(personality, "danc") or string.find(personality, "disco") then
		out.IdleStyle = "bounce"
		out.DanceStyle = "spin"
	elseif string.find(personality, "drift") or string.find(personality, "float") or string.find(personality, "orbit") or string.find(personality, "fly") then
		out.IdleStyle = "float"
		out.DanceStyle = "sway"
	elseif string.find(personality, "spring") or string.find(personality, "boing") or string.find(personality, "hyper") then
		out.IdleStyle = "bounce"
		out.DanceStyle = "bounce"
	elseif string.find(personality, "glitch") or string.find(personality, "chaotic") or string.find(personality, "flicker") or string.find(personality, "honk") then
		out.IdleStyle = "glitch"
		out.DanceStyle = "glitch"
	elseif string.find(personality, "serene") or string.find(personality, "calm") or string.find(personality, "soft") or string.find(personality, "lullab") then
		out.IdleStyle = "calm"
		out.DanceStyle = "sway"
	elseif string.find(personality, "majest") or string.find(personality, "regal") or string.find(personality, "menac") or string.find(personality, "royal") or string.find(personality, "rich") then
		out.IdleStyle = "menace"
		out.DanceStyle = "sway"
	elseif string.find(personality, "slow") or string.find(personality, "unbothered") or string.find(personality, "sunbeam") then
		out.IdleStyle = "calm"
		out.DanceStyle = "sway"
	end
	-- Walk style from Speed.
	if speed >= 22 then
		out.WalkStyle = "zoom"
	elseif speed <= 12 then
		out.WalkStyle = "heavy"
	elseif string.find(personality, "waddl") or string.find(personality, "totter") then
		out.WalkStyle = "waddle"
	end
	return out
end

local function readCharacterId(character: Model): string
	local tag = character:FindFirstChild("CharacterId")
	if tag ~= nil and tag:IsA("StringValue") then
		return tag.Value
	end
	return ""
end

local function onCharacterAdded(character: Model)
	stopLoop()
	currentCharacter = character
	-- Bounded wait: an infinite WaitForChild here used to stall this
	-- handler forever when a morph / respawn produced a character with
	-- no Humanoid yet. 10s is ample; a nil Humanoid just means Step()
	-- no-ops (it guards `hum == nil`) until the next respawn.
	humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso") :: BasePart?

	local torsoPart = torso
	if torsoPart then
		joints.root = findMotor(torsoPart, "RootJoint")
		joints.leftArm = findLimbMotor(torsoPart, "Left Shoulder", "LeftShoulder")
		joints.rightArm = findLimbMotor(torsoPart, "Right Shoulder", "RightShoulder")
		joints.leftLeg = findLimbMotor(torsoPart, "Left Hip", "LeftHip")
		joints.rightLeg = findLimbMotor(torsoPart, "Right Hip", "RightHip")
	end
	-- Morphed Brainrot models (CharacterModels.Build) have NO Motor6D
	-- joints and no Torso at all: every joint above stays nil and the
	-- morph root-delta path in Step() animates the model instead.
	isMorph = joints.root == nil and joints.leftArm == nil and joints.rightArm == nil
		and joints.leftLeg == nil and joints.rightLeg == nil
	currentCharacterId = readCharacterId(character)
	profile = deriveProfile(currentCharacterId)
	cacheBaseC0()

	state.walkPhase = 0
	state.idlePhase = 0
	state.attacking = false
	state.spinning = false
	state.danceTime = 0
	state.celebrateTime = 0
	state.damageTime = 0
	state.transformTime = 0
	state.landTime = 0
	state.wasAirborne = false
	state.lastBobY = 0
	state.lastRoll = 0
	state.lastYaw = 0
	state.lastTransformKind = nil

	local hum = humanoid
	if hum then
		deathConnection = hum.Died:Connect(function()
			AnimationController.Stop()
		end)
	end

	renderConnection = RunService.RenderStepped:Connect(function(deltaTime: number)
		AnimationController.Step(deltaTime)
	end)
end

-- Idle bob for the current profile at phase t. Wobble sways side to
-- side (roll), float hovers high and slow, bounce is springy, glitch
-- jitters, calm barely moves, menace sways slow and heavy.
local function idleBobY(t: number): number
	local amp = profile.BobAmp
	if profile.IdleStyle == "float" then
		return math.sin(t * profile.BobRate * 0.6) * amp * 1.6 + amp * 0.8
	elseif profile.IdleStyle == "bounce" then
		return math.abs(math.sin(t * profile.BobRate * 1.4)) * amp * 1.4
	elseif profile.IdleStyle == "calm" then
		return math.sin(t * profile.BobRate * 0.5) * amp * 0.4
	elseif profile.IdleStyle == "glitch" then
		return math.sin(t * profile.BobRate) * amp * 0.7 + math.sin(t * 13.7) * amp * 0.35
	elseif profile.IdleStyle == "menace" then
		return math.sin(t * profile.BobRate * 0.45) * amp * 0.6
	else
		return math.sin(t * profile.BobRate) * amp
	end
end

local function idleRoll(t: number): number
	if profile.IdleStyle == "wobble" then
		return math.sin(t * profile.BobRate) * 0.09
	elseif profile.IdleStyle == "menace" then
		return math.sin(t * profile.BobRate * 0.45) * 0.05
	elseif profile.IdleStyle == "glitch" then
		return math.sin(t * 11.3) * 0.04
	elseif profile.IdleStyle == "float" then
		return math.sin(t * profile.BobRate * 0.6) * 0.03
	end
	return 0
end

-- One frame of procedural animation. Kept public so tests / other
-- controllers can drive it, but normally called from RenderStepped.
function AnimationController.Step(deltaTime: number)
	local character = currentCharacter
	local hum = humanoid
	if not character or not hum or hum.Health <= 0 then
		return
	end
	local root = rootPart
	if not root then
		return
	end

	state.idlePhase += deltaTime
	local speed = hum.MoveDirection.Magnitude
	state.walking = speed > 0.1
	if state.walking then
		-- Carrying a Brainrot overhead slows the walk cycle down.
		-- Waddle / heavy walkers are slower still; zoomers are faster.
		local walkRate = profile.WalkRate
		if profile.WalkStyle == "waddle" or profile.WalkStyle == "heavy" then
			walkRate *= 0.7
		elseif profile.WalkStyle == "zoom" then
			walkRate *= 1.25
		end
		if state.carrying then
			walkRate *= 0.6
		end
		state.walkPhase += deltaTime * walkRate
	end

	-- Effect timers decay.
	if state.danceTime > 0 then
		state.danceTime = math.max(0, state.danceTime - deltaTime)
	end
	if state.celebrateTime > 0 then
		state.celebrateTime = math.max(0, state.celebrateTime - deltaTime)
	end
	if state.damageTime > 0 then
		state.damageTime = math.max(0, state.damageTime - deltaTime)
	end
	if state.transformTime > 0 then
		state.transformTime = math.max(0, state.transformTime - deltaTime)
	end
	if state.landTime > 0 then
		state.landTime = math.max(0, state.landTime - deltaTime)
	end

	-- Mutation / fusion transform hook: CharacterModels stamps a
	-- "TransformKind" attribute on the model when it mutates or fuses.
	-- Pick it up here so the animation plays with no cross-file call.
	if isMorph then
		local kind = character:GetAttribute("TransformKind")
		if type(kind) == "string" and kind ~= state.lastTransformKind then
			state.lastTransformKind = kind
			state.transformTime = 1.2
		end
	end

	-- Jump / land detection: tuck while airborne, squash on landing.
	local airborne = hum:GetState() == Enum.HumanoidStateType.Jumping
		or hum:GetState() == Enum.HumanoidStateType.Freefall
	if airborne then
		state.jumping = true
		state.wasAirborne = true
	else
		if state.jumping and state.wasAirborne then
			state.landTime = 0.25
		end
		state.jumping = false
		state.wasAirborne = false
	end

	if isMorph then
		AnimationController.StepMorph(deltaTime, airborne)
		return
	end

	-- Idle breathing: gentle torso bob + tiny arm sway, shaped by the
	-- character's profile (wobble / float / bounce / calm / menace).
	local breathe = idleBobY(state.idlePhase)
	if joints.root and BASE_C0.root then
		local base = BASE_C0.root
		local bobY = breathe
		if state.walking then
			bobY += math.abs(math.sin(state.walkPhase)) * 0.08
		end
		if state.landTime > 0 then
			bobY -= 0.12 * (state.landTime / 0.25)
		end
		joints.root.C0 = base * CFrame.new(0, bobY, 0) * CFrame.Angles(0, 0, idleRoll(state.idlePhase))
	end

	-- Walk bob: limbs swing in opposition, arms counter the legs.
	-- While carrying, the swing is smaller (short, careful steps) and the
	-- arms stay raised overhead instead of swinging.
	local swing = 0
	if state.walking then
		swing = math.sin(state.walkPhase) * 0.7
		if state.carrying then
			swing *= 0.45
		end
	end
	-- Dance / celebrate: arms up and waving, body bouncing.
	local dancing = state.danceTime > 0 or state.celebrateTime > 0
	if joints.leftArm and BASE_C0.leftArm then
		local sway = math.sin(state.idlePhase * 2.2) * 0.05
		if state.carrying then
			-- Left arm raised overhead, holding the Brainrot up. A small
			-- side-to-side wobble sells the weight of the carried Brainrot.
			local wobble = math.sin(state.idlePhase * 3.5) * 0.08
			joints.leftArm.C0 = BASE_C0.leftArm
				* CFrame.Angles(math.rad(-165), 0, math.rad(12) + wobble)
		elseif dancing then
			local wave = math.sin(state.idlePhase * 8) * 0.5
			joints.leftArm.C0 = BASE_C0.leftArm * CFrame.Angles(math.rad(-140) + wave, 0, math.rad(25))
		elseif state.damageTime > 0 then
			joints.leftArm.C0 = BASE_C0.leftArm * CFrame.Angles(math.rad(-60), 0, math.rad(40))
		else
			joints.leftArm.C0 = BASE_C0.leftArm * CFrame.Angles(swing + sway, 0, 0)
		end
	end
	if joints.rightArm and BASE_C0.rightArm then
		local sway = math.sin(state.idlePhase * 2.2 + 1) * 0.05
		if state.carrying then
			local wobble = math.sin(state.idlePhase * 3.5 + 1) * 0.08
			joints.rightArm.C0 = BASE_C0.rightArm
				* CFrame.Angles(math.rad(-165), 0, math.rad(-12) - wobble)
		elseif dancing then
			local wave = math.sin(state.idlePhase * 8 + 1.5) * 0.5
			joints.rightArm.C0 = BASE_C0.rightArm * CFrame.Angles(math.rad(-140) - wave, 0, math.rad(-25))
		elseif state.damageTime > 0 then
			joints.rightArm.C0 = BASE_C0.rightArm * CFrame.Angles(math.rad(-60), 0, math.rad(-40))
		else
			joints.rightArm.C0 = BASE_C0.rightArm * CFrame.Angles(-swing + sway, 0, 0)
		end
	end
	if joints.leftLeg and BASE_C0.leftLeg then
		if dancing then
			joints.leftLeg.C0 = BASE_C0.leftLeg * CFrame.Angles(math.sin(state.idlePhase * 8) * 0.5, 0, 0)
		else
			joints.leftLeg.C0 = BASE_C0.leftLeg * CFrame.Angles(-swing, 0, 0)
		end
	end
	if joints.rightLeg and BASE_C0.rightLeg then
		if dancing then
			joints.rightLeg.C0 = BASE_C0.rightLeg * CFrame.Angles(-math.sin(state.idlePhase * 8) * 0.5, 0, 0)
		else
			joints.rightLeg.C0 = BASE_C0.rightLeg * CFrame.Angles(swing, 0, 0)
		end
	end

	-- Attack swing: right arm raises and sweeps down over ~0.35s.
	-- Suppressed while carrying — you cannot swing while holding a Brainrot.
	if state.attacking and not state.carrying then
		state.attackTime += deltaTime
		local t = state.attackTime / 0.35
		if t >= 1 then
			state.attacking = false
			state.attackTime = 0
		elseif joints.rightArm and BASE_C0.rightArm then
			-- Raise on the first half, chop down on the second half.
			local angle = 0
			if t < 0.4 then
				angle = -math.rad(150) * (t / 0.4)
			else
				angle = -math.rad(150) + math.rad(200) * ((t - 0.4) / 0.6)
			end
			joints.rightArm.C0 = BASE_C0.rightArm * CFrame.Angles(angle, 0, 0)
		end
	end

	-- Jump: tuck the legs slightly while airborne.
	if airborne then
		if joints.leftLeg and BASE_C0.leftLeg then
			joints.leftLeg.C0 = BASE_C0.leftLeg * CFrame.Angles(math.rad(35), 0, 0)
		end
		if joints.rightLeg and BASE_C0.rightLeg then
			joints.rightLeg.C0 = BASE_C0.rightLeg * CFrame.Angles(math.rad(-20), 0, 0)
		end
	end

	-- Spawn spin: a full 360-degree turn over ~0.6s, driven on the root part.
	if state.spinning then
		state.spinTime += deltaTime
		local t = state.spinTime / 0.6
		if t >= 1 then
			state.spinning = false
			state.spinTime = 0
		else
			-- Rotate at 600 deg/sec for 0.6s = exactly one full turn.
			root.CFrame = root.CFrame * CFrame.Angles(0, math.rad(600) * deltaTime, 0)
		end
	end

	-- Celebrate spin: same 360-degree turn, slower (1s), for the
	-- celebrate / rare-discovery moment.
	if state.celebrateTime > 0 then
		root.CFrame = root.CFrame * CFrame.Angles(0, math.rad(360) * deltaTime, 0)
	end
end

-- Morph-model frame: the whole model is one welded lump, so idle /
-- walk / jump / dance / damage / transform are all expressed as small
-- root-CFrame DELTAS (never an absolute set — see the header note).
-- bobY: vertical bob; roll: side-to-side tilt; yaw: accumulated spin.
function AnimationController.StepMorph(deltaTime: number, airborne: boolean)
	local root = rootPart
	if root == nil then
		return
	end
	local bobY = idleBobY(state.idlePhase)
	local roll = idleRoll(state.idlePhase)
	local yaw = state.lastYaw

	if state.walking then
		-- Walk: faster bob + a forward lean wobble.
		bobY += math.abs(math.sin(state.walkPhase)) * 0.1
		roll += math.sin(state.walkPhase) * 0.05
	end
	if state.carrying then
		-- Carrying: careful, slower bob, slight backward lean (roll).
		bobY *= 0.6
	end
	if airborne then
		-- Jump: rise + tuck (a little extra height, no roll).
		bobY += 0.25
	elseif state.landTime > 0 then
		-- Land: squash down briefly.
		bobY -= 0.18 * (state.landTime / 0.25)
	end
	if state.attacking then
		-- Attack lunge: quick forward pitch (roll) + bob spike.
		state.attackTime += deltaTime
		local t = state.attackTime / 0.35
		if t >= 1 then
			state.attacking = false
			state.attackTime = 0
		else
			bobY += math.sin(t * math.pi) * 0.15
			roll += math.sin(t * math.pi) * 0.12
		end
	end
	if state.damageTime > 0 then
		-- Damage: sharp jitter — random small roll/yaw kicks that
		-- decay with the timer.
		local k = state.damageTime / 0.35
		roll += (math.random() - 0.5) * 0.25 * k
		yaw += (math.random() - 0.5) * 0.3 * k
	end
	if state.danceTime > 0 or state.celebrateTime > 0 then
		-- Dance / celebrate, shaped by the character's DanceStyle:
		-- spin = full turns, bounce = big hops, sway = wide roll,
		-- glitch = jittery hops + yaw kicks.
		local style = profile.DanceStyle
		local beat = state.idlePhase * 6
		if style == "spin" then
			yaw += math.rad(360) * deltaTime
			bobY += math.abs(math.sin(beat)) * 0.12
		elseif style == "sway" then
			roll += math.sin(beat * 0.5) * 0.16
			bobY += math.sin(beat * 0.5) * 0.06
		elseif style == "glitch" then
			bobY += math.abs(math.sin(beat * 1.7)) * 0.14
			yaw += (math.random() - 0.5) * 0.2
		else -- "bounce"
			bobY += math.abs(math.sin(beat)) * 0.22
		end
	end
	if state.transformTime > 0 then
		-- Mutation / fusion transform: one full spin + a big bounce
		-- over the 1.2s window, decaying as the timer runs out.
		local k = state.transformTime / 1.2
		yaw += math.rad(300) * deltaTime * k
		bobY += math.sin((1 - k) * math.pi) * 0.3
	end
	if state.spinning then
		state.spinTime += deltaTime
		local t = state.spinTime / 0.6
		if t >= 1 then
			state.spinning = false
			state.spinTime = 0
		else
			yaw += math.rad(600) * deltaTime
		end
	end

	-- Apply ONLY the deltas since last frame.
	local r = root :: BasePart
	pcall(function()
		r.CFrame = r.CFrame * CFrame.new(0, bobY - state.lastBobY, 0)
		r.CFrame = r.CFrame * CFrame.Angles(0, yaw - state.lastYaw, roll - state.lastRoll)
	end)
	state.lastBobY = bobY
	state.lastRoll = roll
	state.lastYaw = yaw
end

function AnimationController.PlayAttack()
	if state.attacking or state.carrying then
		return
	end
	state.attacking = true
	state.attackTime = 0
end

-- Carry pose: arms up, Brainrot held overhead (the held Brainrot model
-- itself is parented by the server / carry system; this only poses the
-- arms and slows the walk). Call with false on place / drop / steal loss.
function AnimationController.SetCarrying(carrying: boolean)
	state.carrying = carrying
	if carrying then
		state.attacking = false
		state.attackTime = 0
	end
end

function AnimationController.IsCarrying(): boolean
	return state.carrying
end

function AnimationController.PlayJump()
	-- Jump pose is derived from Humanoid state in Step(); this is kept as
	-- an explicit trigger for controllers that want to force the tuck.
	state.jumping = true
end

function AnimationController.PlaySpawnSpin()
	state.spinning = true
	state.spinTime = 0
end

-- Dance (2s): the character's own DanceStyle — spin / bounce / sway /
-- glitch. Used by the disco / party moments and the collection UI.
function AnimationController.PlayDance()
	state.danceTime = 2
end

-- Celebrate (2.5s): bounce + a slow 360-degree spin, for wins,
-- quest claims and rare acquisitions. Rare discovery uses this with
-- a flash (PlayRareDiscovery).
function AnimationController.PlayCelebrate()
	state.celebrateTime = 2.5
end

-- Damage flinch (0.35s): arms up on a rig, jitter on a morph model.
function AnimationController.PlayDamage()
	state.damageTime = 0.35
end

-- Land squash is derived from the airborne transition in Step(); this
-- is the explicit trigger for controllers that want to force it.
function AnimationController.PlayLand()
	state.landTime = 0.25
end

-- Rare discovery (3s celebrate + white flash): called when the local
-- player acquires an Epic+ Brainrot (CompanionService announces it
-- server-side; the client UI / MarketController can call this when
-- the ConveyorUpdate announcement names the local player).
function AnimationController.PlayRareDiscovery()
	state.celebrateTime = 3
	if EffectsController ~= nil and type(EffectsController.Flash) == "function" then
		pcall(function()
			EffectsController.Flash(Color3.fromRGB(255, 240, 160), 0.5)
		end)
	end
end

-- Mutation transform (1.2s spin + bounce). Also fires automatically
-- when CharacterModels stamps "TransformKind" on the model.
function AnimationController.PlayMutationTransform()
	state.transformTime = 1.2
	state.lastTransformKind = "Mutation"
end

-- Fusion transform (1.2s spin + bounce, same window as mutation).
function AnimationController.PlayFusionTransform()
	state.transformTime = 1.2
	state.lastTransformKind = "Fusion"
end

-- Explicit character select (for controllers that know the id before
-- the model carries its CharacterId tag). Normally derived in
-- onCharacterAdded; this is the override.
function AnimationController.SetCharacterId(characterId: string)
	currentCharacterId = characterId
	profile = deriveProfile(characterId)
end

function AnimationController.GetCharacterId(): string
	return currentCharacterId
end

function AnimationController.GetProfile(): AnimationProfile
	return profile
end

function AnimationController.IsMorph(): boolean
	return isMorph
end

function AnimationController.Stop()
	state.attacking = false
	state.spinning = false
	state.jumping = false
	state.carrying = false
	state.danceTime = 0
	state.celebrateTime = 0
	state.damageTime = 0
	state.transformTime = 0
	state.landTime = 0
	stopLoop()
end

function AnimationController.Init()
	player.CharacterAdded:Connect(onCharacterAdded)
	local existing = player.Character
	if existing then
		onCharacterAdded(existing)
	end
end

return AnimationController
