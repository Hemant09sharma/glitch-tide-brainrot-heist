-- CharacterService (server)
-- Owns character selection, ownership validation, and morphing the player's
-- avatar into the selected Brainrot character. Server-authoritative: the
-- client may only *request* a character; this service decides if it is allowed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local CharacterModels = require(ReplicatedStorage:WaitForChild("CharacterModels"))
local Utils = require(ReplicatedStorage:WaitForChild("Utils"))

local CharacterService = {}

local DataService = nil

-- Burst-limit state lives in SecurityService (BurstLimit); require it
-- lazily so a missing SecurityService module never breaks morphing.
local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

-- player -> characterId currently applied (authoritative, server-side)
local AppliedCharacters = {}
-- player -> debounce so rapid re-morphs cannot stack
local MorphDebounce = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function safeFireClient(remote, player, payload)
	if not remote then
		return
	end
	pcall(function()
		remote:FireClient(player, payload)
	end)
end

-- Resolve one live RemoteEvent by name. Remotes exposes GetRemote /
-- GetFunction per name (there is no GetRemotes()); see EconomyService.
local function getRemote(name: string): RemoteEvent?
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

local function safeGetData(player)
	if not DataService then
		return nil
	end
	local ok, data = pcall(function()
		return DataService.GetData(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

-- Ownership: a character is usable when it costs 0 (Characters.
-- IsUnlockedByDefault) or DataService.HasCharacter says the player owns it
-- (data.Unlocked list). Never trust a client claim of ownership.
local function isOwned(player, characterId)
	local def = Characters.GetById(characterId)
	if not def then
		return false
	end
	if Characters.IsUnlockedByDefault(characterId) then
		return true
	end
	if DataService and DataService.HasCharacter then
		local ok, owned = pcall(function()
			return DataService.HasCharacter(player, characterId)
		end)
		if ok and owned then
			return true
		end
	end
	-- Fallback for data shapes without HasCharacter: scan data.Unlocked.
	local data = safeGetData(player)
	if data and type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			if id == characterId then
				return true
			end
		end
	end
	return false
end

local function getSelectedId(player)
	if DataService and DataService.GetSelected then
		local ok, selected = pcall(function()
			return DataService.GetSelected(player)
		end)
		if ok and type(selected) == "string" and selected ~= "" then
			return selected
		end
	end
	local data = safeGetData(player)
	if data and type(data.Selected) == "string" and data.Selected ~= "" then
		return data.Selected
	end
	return AppliedCharacters[player] or "wobble_waffleton"
end

-- Signature prop: CharacterModels already builds the character's prop from
-- def.BuildSpec (e.g. Wobble Waffleton's waffle). Only add a fallback prop when the
-- build has none, so a morph never ends up prop-less or double-propped.
local function attachSignatureProp(model, def)
	if def.BuildSpec and type(def.BuildSpec.Prop) == "string" then
		if model:FindFirstChild(def.BuildSpec.Prop, true) then
			return
		end
	end
	if model:FindFirstChild("SignatureProp") then
		return
	end
	local humanoidRootPart = model:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return
	end
	local torso = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
	if not torso then
		return
	end

	local prop = Instance.new("Part")
	prop.Name = "SignatureProp"
	prop.Size = Vector3.new(0.6, 0.6, 0.6)
	prop.Shape = Enum.PartType.Ball
	prop.Material = Enum.Material.Neon
	prop.Color = def.Color or Color3.fromRGB(255, 255, 255)
	prop.CanCollide = false
	prop.CanQuery = false
	prop.CanTouch = false
	prop.Massless = true
	prop.Anchored = false
	prop.Parent = model

	-- Float it beside the torso so it never blocks the head / hitbox.
	prop.CFrame = torso.CFrame * CFrame.new(1.1, 0.4, 0)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = prop
	weld.Parent = prop
end

local function applyBodyColors(model, def)
	local color = def.Color or Color3.fromRGB(255, 255, 255)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "SignatureProp" then
			-- Only recolor plain body parts; keep any intentionally colored
			-- detail parts built by CharacterModels untouched when they are
			-- marked with a "KeepColor" attribute.
			if not descendant:GetAttribute("KeepColor") then
				descendant.Color = color
			end
		end
	end

	-- Humanoid body colors, when present, drive the classic avatar palette.
	local bodyColors = model:FindFirstChildOfClass("BodyColors")
	if bodyColors then
		bodyColors.HeadColor3 = color
		bodyColors.TorsoColor3 = color
		bodyColors.LeftArmColor3 = color
		bodyColors.RightArmColor3 = color
		bodyColors.LeftLegColor3 = color
		bodyColors.RightLegColor3 = color
	end
end

local function applyScale(model, def)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	-- Character defs may carry a Scale multiplier; default 1.
	local scale = def.Scale or 1
	scale = math.clamp(scale, 0.7, 1.6)
	if humanoid:FindFirstChild("BodyHeightScale") then
		humanoid.BodyHeightScale.Value = scale
	end
	if humanoid:FindFirstChild("BodyWidthScale") then
		humanoid.BodyWidthScale.Value = scale
	end
	if humanoid:FindFirstChild("BodyDepthScale") then
		humanoid.BodyDepthScale.Value = scale
	end
	if humanoid:FindFirstChild("HeadScale") then
		humanoid.HeadScale.Value = scale
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ApplyCharacter(player, characterId)
-- Validates ownership, then morphs the player's current character in place:
-- swaps in the CharacterModels build, applies stats, colors, scale and prop.
-- Returns (true) on success, (false, reason) on failure.
function CharacterService.ApplyCharacter(player, characterId)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	if type(characterId) ~= "string" or characterId == "" then
		return false, "invalid character id"
	end

	local def = Characters.GetById(characterId)
	if not def then
		return false, "unknown character"
	end
	if not isOwned(player, characterId) then
		return false, "not owned"
	end

	-- Debounce: at most one morph per player per 0.5s.
	local now = os.clock()
	if MorphDebounce[player] and now - MorphDebounce[player] < 0.5 then
		return false, "too fast"
	end
	MorphDebounce[player] = now

	local character = player.Character
	if not character then
		-- Player has no character yet (still loading); remember the pick and
		-- apply it when CharacterAdded fires.
		AppliedCharacters[player] = characterId
		return true
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then
		return false, "character not ready"
	end
	if humanoid.Health <= 0 then
		return false, "character is dead"
	end

	-- Build the new model. CharacterModels is the single source of truth for
	-- what a character looks like.
	local ok, newModel = pcall(function()
		return CharacterModels.BuildCharacterModel(characterId)
	end)
	if not ok or not newModel or not newModel:IsA("Model") then
		warn("[CharacterService] BuildCharacterModel failed for " .. characterId .. ": " .. tostring(newModel))
		return false, "build failed"
	end

	-- Preserve position / orientation and health fraction across the morph.
	local oldCFrame = rootPart.CFrame
	local healthFraction = 1
	if humanoid.MaxHealth > 0 then
		healthFraction = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
	end

	-- Replace the old model: move the new model into place, parent it, then
	-- destroy the old one. Player.Character must point at the new model.
	local newHumanoid = newModel:FindFirstChildOfClass("Humanoid")
	local newRoot = newModel:FindFirstChild("HumanoidRootPart")
	if not newHumanoid or not newRoot then
		newModel:Destroy()
		return false, "built model missing Humanoid/HumanoidRootPart"
	end

	-- Stats from the character definition (never from the client).
	local maxHealth = def.Health or 100
	local walkSpeed = def.Speed or Config.BaseWalkSpeed or 16

	newHumanoid.MaxHealth = maxHealth
	newHumanoid.Health = math.max(1, math.floor(maxHealth * healthFraction))
	newHumanoid.WalkSpeed = walkSpeed
	newHumanoid.JumpPower = 50
	newHumanoid.DisplayName = def.DisplayName or characterId

	applyBodyColors(newModel, def)
	applyScale(newModel, def)
	attachSignatureProp(newModel, def)

	-- CAMERA COMPAT (camera-bug fix, minimal): the morphed model is what
	-- the client camera must follow, so it must be a valid camera
	-- subject — PrimaryPart set to the HumanoidRootPart, root unanchored
	-- (it is the physics root; an anchored root would freeze the
	-- character in place), Humanoid alive. Size / transparency /
	-- massless behaviour is unchanged from CharacterModels.Build.
	newModel.PrimaryPart = newRoot
	newRoot.Anchored = false
	if newHumanoid.Health <= 0 then
		newHumanoid.Health = maxHealth
	end

	-- Replace the old model: move the new model into place, parent it,
	-- THEN destroy the old one and point player.Character at the new
	-- model. Parenting first matters for the client camera: the client
	-- rebinds on the `player.Character` property change, and it can only
	-- find the new Humanoid / HumanoidRootPart immediately if the model
	-- has already replicated. Destroying the old model first left the
	-- client briefly pointing at a destroyed Humanoid with the new
	-- model not yet visible.
	newModel.Name = player.Name
	newModel:PivotTo(oldCFrame)

	-- Tag the model so combat / waves can identify it as a player character.
	local tag = Instance.new("StringValue")
	tag.Name = "CharacterId"
	tag.Value = characterId
	tag.Parent = newModel

	-- Swap. Anchoring the old model first avoids a physics pop.
	newModel.Parent = workspace
	character:Destroy()
	player.Character = newModel

	AppliedCharacters[player] = characterId
	return true
end

-- GetSelected(player) -> characterId (string)
function CharacterService.GetSelected(player)
	if not player then
		return "wobble_waffleton"
	end
	return getSelectedId(player)
end

-- SwitchCharacter(player, id): validate + persist + apply immediately.
-- Returns (true) / (false, reason).
function CharacterService.SwitchCharacter(player, characterId)
	local ok, reason = CharacterService.ApplyCharacter(player, characterId)
	if not ok then
		return false, reason
	end

	-- Persist the selection so it survives rejoin / respawn.
	if DataService and DataService.SetSelected then
		pcall(function()
			DataService.SetSelected(player, characterId)
		end)
	end
	return true
end

--------------------------------------------------------------------------------
-- Remote handling
--------------------------------------------------------------------------------

local function onSelectCharacter(player, characterId)
	if type(characterId) ~= "string" then
		return
	end
	-- Basic sanity: ids are short alphanumeric/underscore tokens.
	if #characterId > 64 or not string.match(characterId, "^[%w_%-]+$") then
		return
	end
	-- Burst limit (v1.0.1 integration QA): at most 5 SelectCharacter
	-- attempts per 5s per player. A scripted client firing hundreds of
	-- equip attempts per second is rejected with a clear reason instead
	-- of costing the server a morph attempt each time.
	if Security and Security.BurstLimit then
		local allowed = false
		pcall(function()
			allowed = Security.BurstLimit(player, "SelectCharacter", 5, 5)
		end)
		if not allowed then
			warn("[CharacterService] SelectCharacter burst limit for " .. player.Name)
			safeFireClient(getRemote("PlayerStats"), player, {
				type = "CharacterSwitchFailed",
				characterId = characterId,
				reason = "too many requests — slow down",
			})
			return
		end
	end
	local ok, reason = CharacterService.SwitchCharacter(player, characterId)
	if not ok then
		-- Tell the client the switch failed (and why) without kicking them;
		-- the client should keep showing the previously applied character.
		safeFireClient(getRemote("PlayerStats"), player, {
			type = "CharacterSwitchFailed",
			characterId = characterId,
			reason = reason or "unknown",
		})
	end
end

--------------------------------------------------------------------------------
-- Init / lifecycle
--------------------------------------------------------------------------------

function CharacterService.Init(dataService)
	DataService = dataService

	-- SelectCharacter remote: client requests a character switch. Remotes
	-- are created by Main before services init, but poll briefly in case
	-- this service loads first (same pattern as EconomyService).
	task.spawn(function()
		local selectRemote: RemoteEvent? = nil
		for _ = 1, 50 do
			selectRemote = getRemote("SelectCharacter")
			if selectRemote then
				break
			end
			task.wait(0.2)
		end
		if selectRemote then
			selectRemote.OnServerEvent:Connect(onSelectCharacter)
		else
			warn("[CharacterService] SelectCharacter remote not available")
		end
	end)

	-- Re-apply the saved character whenever the player (re)spawns. The
	-- character model is rebuilt fresh each spawn, so the morph must run
	-- after the default avatar loads.
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- Small delay: let the default character finish loading first.
			task.wait(0.2)
			local selected = getSelectedId(player)
			-- Only re-apply when the player actually owns it; otherwise fall
			-- back to the starter so nobody is stuck with an invalid pick.
			if not isOwned(player, selected) then
				selected = "wobble_waffleton"
			end
			CharacterService.ApplyCharacter(player, selected)
		end)
	end)

	-- Players already in the game when this service inits (studio / reload).
	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			task.wait(0.2)
			local selected = getSelectedId(player)
			if not isOwned(player, selected) then
				selected = "wobble_waffleton"
			end
			CharacterService.ApplyCharacter(player, selected)
		end)
		if player.Character then
			task.spawn(function()
				task.wait(0.2)
				local selected = getSelectedId(player)
				if isOwned(player, selected) then
					CharacterService.ApplyCharacter(player, selected)
				end
			end)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		AppliedCharacters[player] = nil
		MorphDebounce[player] = nil
	end)
end

return CharacterService
