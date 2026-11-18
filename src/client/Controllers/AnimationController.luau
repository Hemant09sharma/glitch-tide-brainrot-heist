--!strict
-- AnimationController.luau
-- Procedural client-side animation for GLITCH TIDE — BRAINROT HEIST:
-- THE MEMEVERSE. No external animation IDs are used: everything is driven
-- by RunService.RenderStepped plus CFrame offsets on the character's
-- Motor6D joints and parts. Applies to the local player's character only
-- and stops cleanly on death / respawn. Includes the carry pose: arms up,
-- Brainrot held overhead and bobbing, with a slowed walk.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local AnimationController = {}

type JointSet = {
	root: Motor6D?,
	leftArm: Motor6D?,
	rightArm: Motor6D?,
	leftLeg: Motor6D?,
	rightLeg: Motor6D?,
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
	-- joints and no Torso at all: every joint above stays nil and
	-- Step() then only drives the root spin / idle timers — it never
	-- errors, it simply has nothing to pose. That is expected, not a
	-- bug: the morph is a static welded model, not a rigged avatar.
	cacheBaseC0()

	state.walkPhase = 0
	state.idlePhase = 0
	state.attacking = false
	state.spinning = false

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
		local walkRate = 9
		if state.carrying then
			walkRate = 5.5
		end
		state.walkPhase += deltaTime * walkRate
	end

	-- Idle breathing: gentle torso bob + tiny arm sway.
	local breathe = math.sin(state.idlePhase * 2.2) * 0.04
	if joints.root and BASE_C0.root then
		local base = BASE_C0.root
		local bobY = breathe
		if state.walking then
			bobY += math.abs(math.sin(state.walkPhase)) * 0.08
		end
		joints.root.C0 = base * CFrame.new(0, bobY, 0)
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
	if joints.leftArm and BASE_C0.leftArm then
		local sway = math.sin(state.idlePhase * 2.2) * 0.05
		if state.carrying then
			-- Left arm raised overhead, holding the Brainrot up. A small
			-- side-to-side wobble sells the weight of the carried Brainrot.
			local wobble = math.sin(state.idlePhase * 3.5) * 0.08
			joints.leftArm.C0 = BASE_C0.leftArm
				* CFrame.Angles(math.rad(-165), 0, math.rad(12) + wobble)
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
		else
			joints.rightArm.C0 = BASE_C0.rightArm * CFrame.Angles(-swing + sway, 0, 0)
		end
	end
	if joints.leftLeg and BASE_C0.leftLeg then
		joints.leftLeg.C0 = BASE_C0.leftLeg * CFrame.Angles(-swing, 0, 0)
	end
	if joints.rightLeg and BASE_C0.rightLeg then
		joints.rightLeg.C0 = BASE_C0.rightLeg * CFrame.Angles(swing, 0, 0)
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
	if hum:GetState() == Enum.HumanoidStateType.Jumping
		or hum:GetState() == Enum.HumanoidStateType.Freefall then
		state.jumping = true
		if joints.leftLeg and BASE_C0.leftLeg then
			joints.leftLeg.C0 = BASE_C0.leftLeg * CFrame.Angles(math.rad(35), 0, 0)
		end
		if joints.rightLeg and BASE_C0.rightLeg then
			joints.rightLeg.C0 = BASE_C0.rightLeg * CFrame.Angles(math.rad(-20), 0, 0)
		end
	else
		state.jumping = false
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

function AnimationController.Stop()
	state.attacking = false
	state.spinning = false
	state.jumping = false
	state.carrying = false
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
