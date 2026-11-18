--!strict
-- CarryService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Owns the carry state: at most one Brainrot per player, carried as a
-- small welded model above the player's head, slowing them to
-- Config.CarrySpeedMultiplier. Drops on death and on tide hits, and a
-- manual drop leaves a 30-second world pickup; if nobody recovers it,
-- the world model is deleted and the instance returns to the owner's
-- inventory list in data (no refund, no deletion of the instance).
-- Steal pickups are validated here for RaidService via TryPickupStolen;
-- the actual transfer is done by RaidService with ForceCarry.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local CarryService = {}

local _dataService: any = nil
local _baseService: any = nil
local _raidService: any = nil
local _running = false

local _carrying: { [Player]: { [string]: any } } = {}
local _carryModels: { [Player]: Model } = {}
local _dropped: { [string]: { [string]: any } } = {} -- InstanceId -> drop record
local _lastCall: { [Player]: number } = {}

local MIN_CALL_INTERVAL = 0.25
local PICKUP_DISTANCE = 12
local DROP_RECOVERY_SECONDS = 30

local _characterModels: any = nil
do
	local found = ReplicatedStorage:FindFirstChild("CharacterModels")
	if found then
		local ok, mod = pcall(require, found)
		if ok then
			_characterModels = mod
		end
	end
end

local function buildModelFor(def: any, scale: number): Model
	if _characterModels ~= nil then
		for _, fnName in ipairs({ "Build", "BuildModel", "BuildCharacter" }) do
			local fn = _characterModels[fnName]
			if type(fn) == "function" then
				local ok, model = pcall(fn, def)
				if ok and typeof(model) == "Instance" and model:IsA("Model") then
					return model
				end
				local ok2, model2 = pcall(fn, def.Id)
				if ok2 and typeof(model2) == "Instance" and model2:IsA("Model") then
					return model2
				end
			end
		end
	end
	local model = Instance.new("Model")
	model.Name = tostring(def.DisplayName or def.Id)
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2 * scale, 2.4 * scale, 2 * scale)
	body.Color = (def.Color :: Color3)
	body.Material = Enum.Material.SmoothPlastic
	body.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.6 * scale, 1.4 * scale, 1.6 * scale)
	head.Color = (def.AccentColor :: Color3)
	head.Material = Enum.Material.SmoothPlastic
	head.Parent = model
	body.CFrame = CFrame.new(0, 1.2 * scale, 0)
	head.CFrame = CFrame.new(0, 3.1 * scale, 0)
	model.PrimaryPart = body
	return model
end

local function getRemotesFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local ok, found = pcall(function()
		return ReplicatedStorage:WaitForChild("Remotes", 5)
	end)
	if ok and typeof(found) == "Instance" then
		return found :: Folder
	end
	return nil
end

local function getEvent(name: string): RemoteEvent?
	local folder = getRemotesFolder()
	if folder == nil then
		return nil
	end
	local child = folder:FindFirstChild(name)
	if child and child:IsA("RemoteEvent") then
		return child
	end
	return nil
end

local function rateLimited(player: Player): boolean
	local now = os.clock()
	local last = _lastCall[player] or 0
	if now - last < MIN_CALL_INTERVAL then
		return true
	end
	_lastCall[player] = now
	return false
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end
	return humanoid
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function applyCarrySpeed(player: Player, carrying: boolean): ()
	local humanoid = getHumanoid(player)
	if humanoid == nil then
		return
	end
	if carrying then
		humanoid.WalkSpeed = (tonumber(Config.BaseWalkSpeed) or 16)
			* (tonumber(Config.CarrySpeedMultiplier) or 0.6)
	else
		humanoid.WalkSpeed = tonumber(Config.BaseWalkSpeed) or 16
	end
end

local function fireCarryUpdate(player: Player): ()
	local carried = _carrying[player]
	local payload: { [string]: any } = {
		Carrying = carried ~= nil,
		InstanceId = carried and carried.InstanceId or nil,
		CharacterId = carried and carried.CharacterId or nil,
		Glitched = carried and carried.Glitched == true or false,
		Stolen = carried and carried.Stolen == true or false,
		CarryStartedAt = carried and carried.CarryStartedAt or 0,
	}
	local remote = getEvent(Remotes.Names.CarryUpdate)
	if remote ~= nil then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

local function destroyCarryModel(player: Player): ()
	local model = _carryModels[player]
	if model ~= nil then
		_carryModels[player] = nil
		pcall(function()
			model:Destroy()
		end)
	end
end

-- Build the small welded carry visual above the player's head.
local function attachCarryModel(player: Player, characterId: string): boolean
	destroyCarryModel(player)
	local def = Characters.GetById(characterId)
	if def == nil then
		return false
	end
	local character = player.Character
	local root = getRoot(player)
	if character == nil or root == nil then
		return false
	end
	local model = buildModelFor(def, 0.6)
	model.Name = "Carried_" .. tostring(characterId)
	-- Un-anchor, make weightless and non-colliding, then weld to the root.
	if _characterModels ~= nil and type(_characterModels.SetDisplayMode) == "function" then
		pcall(_characterModels.SetDisplayMode, model, false)
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end
	local primary = model.PrimaryPart
	if primary == nil or not primary:IsA("BasePart") then
		pcall(function()
			model:Destroy()
		end)
		return false
	end
	pcall(function()
		model:PivotTo(root.CFrame * CFrame.new(0, 3.2, 0))
	end)
	model.Parent = character
	local weld = Instance.new("Weld")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = primary
	weld.C0 = CFrame.new(0, 3.2, 0)
	weld.Parent = primary
	_carryModels[player] = model
	return true
end

-- -------------------------------------------------------------------------
-- Public carry API
-- -------------------------------------------------------------------------

function CarryService.GetCarried(player: Player): { [string]: any }?
	return _carrying[player]
end

function CarryService.IsCarrying(player: Player): boolean
	return _carrying[player] ~= nil
end

-- Start carrying an owned record (conveyor purchase, inventory pickup,
-- or a steal transfer from RaidService). Returns (true) / (false, reason).
function CarryService.PickupOwned(player: Player, owned: { [string]: any }): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(owned) ~= "table" or type(owned.InstanceId) ~= "string" then
		return false, "invalid brainrot"
	end
	if _carrying[player] ~= nil then
		return false, "already carrying"
	end
	local data = _dataService.GetOrLoad(player)
	local found = false
	if type(data.OwnedInstances) == "table" then
		for _, record in ipairs(data.OwnedInstances) do
			if record.InstanceId == owned.InstanceId then
				found = true
				break
			end
		end
	end
	if not found then
		return false, "brainrot not owned"
	end
	-- Never carry something that is placed in a base.
	if owned.Placed == true then
		return false, "brainrot is placed in your base"
	end
	if _baseService ~= nil and type(_baseService.GetPlaced) == "function" then
		for _, placed in ipairs(_baseService.GetPlaced(player)) do
			if placed.InstanceId == owned.InstanceId then
				return false, "brainrot is placed in your base"
			end
		end
	end
	_carrying[player] = {
		InstanceId = owned.InstanceId,
		CharacterId = owned.CharacterId,
		Glitched = owned.Glitched == true,
		Mutation = owned.Mutation,
		Level = tonumber(owned.Level) or 1,
		CarryStartedAt = os.time(),
	}
	attachCarryModel(player, owned.CharacterId)
	applyCarrySpeed(player, true)
	fireCarryUpdate(player)
	return true, owned.InstanceId
end

-- RaidService entry point: force a validated steal into the thief's hands.
-- This is ALWAYS a stolen Brainrot, so it is marked Stolen: drops route
-- back to the victim through RaidService.DropStolen instead of becoming
-- a world pickup the thief could re-collect (the old code left Stolen
-- unset, so a manual drop or a death drop became a thief-owned world
-- pickup and DropStolen never ran).
function CarryService.ForceCarry(player: Player, record: { [string]: any }): (boolean, any)
	if _carrying[player] ~= nil then
		return false, "already carrying"
	end
	_carrying[player] = {
		InstanceId = record.InstanceId,
		CharacterId = record.CharacterId,
		Glitched = record.Glitched == true,
		Mutation = record.Mutation,
		Level = tonumber(record.Level) or 1,
		Stolen = true,
		CarryStartedAt = os.time(),
	}
	attachCarryModel(player, record.CharacterId)
	applyCarrySpeed(player, true)
	fireCarryUpdate(player)
	return true, record.InstanceId
end

-- Set the thief's carry state for a stolen Brainrot (RaidService hook).
-- The thief does not own the instance yet — it lives in _inTransit on the
-- RaidService side — so the character is resolved by scanning every
-- connected player's OwnedInstances (the victim still owns the record
-- until ConfirmDelivery). Accepts an instance id string, or a record
-- table {InstanceId, CharacterId, ...}. Marks the carry Stolen so drops
-- route back to the victim through RaidService instead of becoming a
-- world pickup. Returns (true) / (false, reason).
function CarryService.SetCarried(player: Player, instance: any): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if _carrying[player] ~= nil then
		return false, "already carrying"
	end
	local instanceId: string? = nil
	local characterId: string? = nil
	local glitched = false
	local mutation: string? = nil
	if type(instance) == "table" then
		instanceId = instance.InstanceId
		characterId = instance.CharacterId
		glitched = instance.Glitched == true
		mutation = instance.Mutation
	elseif type(instance) == "string" then
		instanceId = instance
		-- Resolve the character from any player's instance registry.
		for _, other in ipairs(Players:GetPlayers()) do
			local data = _dataService.GetData(other)
			if data ~= nil and type(data.OwnedInstances) == "table" then
				for _, record in ipairs(data.OwnedInstances) do
					if record.InstanceId == instanceId then
						characterId = record.CharacterId
						glitched = record.Glitched == true
						mutation = record.Mutation
						break
					end
				end
			end
			if characterId ~= nil then
				break
			end
		end
	end
	if type(instanceId) ~= "string" or instanceId == "" or type(characterId) ~= "string" then
		return false, "unknown brainrot"
	end
	_carrying[player] = {
		InstanceId = instanceId,
		CharacterId = characterId,
		Glitched = glitched,
		Mutation = mutation,
		Stolen = true,
		CarryStartedAt = os.time(),
	}
	attachCarryModel(player, characterId)
	applyCarrySpeed(player, true)
	fireCarryUpdate(player)
	return true, instanceId
end

function CarryService.SetRaidService(raidService: any): ()
	_raidService = raidService
end

-- Clear carry state without dropping a world model (place / silent cleanup).
-- Returns the record that was being carried, or nil.
function CarryService.ClearCarried(player: Player, silent: boolean?): { [string]: any }?
	local carried = _carrying[player]
	if carried == nil then
		return nil
	end
	_carrying[player] = nil
	destroyCarryModel(player)
	applyCarrySpeed(player, false)
	if silent ~= true then
		fireCarryUpdate(player)
	end
	return carried
end

-- Recovery timer for a world drop: after DROP_RECOVERY_SECONDS the
-- world model is deleted and the instance simply stays in the owner's
-- inventory list (no refund, no loss). The timer is bound to the exact
-- drop record table it was scheduled for: if the same instance is
-- dropped, picked up and dropped again, the first timer must NOT
-- delete the second drop's model.
local function scheduleDropExpiry(instanceId: string, dropRecord: { [string]: any }, owner: Player): ()
	task.delay(DROP_RECOVERY_SECONDS, function()
		if _dropped[instanceId] ~= dropRecord then
			return
		end
		_dropped[instanceId] = nil
		local dropModel = dropRecord.Model
		if typeof(dropModel) == "Instance" then
			pcall(function()
				(dropModel :: Instance):Destroy()
			end)
		end
		print(string.format("[CarryService] Dropped %s expired; returned to %s's inventory",
			tostring(instanceId), owner.Name))
	end)
end

-- Drop what is being carried as a world pickup at the player's position.
-- After DROP_RECOVERY_SECONDS the world model is deleted and the instance
-- simply stays in the owner's inventory list (no refund, no loss).
function CarryService.DropCarried(player: Player, reason: string?): (boolean, any)
	local carried = _carrying[player]
	if carried == nil then
		return false, "not carrying"
	end
	_carrying[player] = nil
	destroyCarryModel(player)
	applyCarrySpeed(player, false)
	if carried.Stolen == true then
		-- Stolen goods never become a world pickup: they return to the
		-- victim through RaidService (its documented contract: CarryService
		-- calls DropStolen when the thief drops what they are carrying).
		fireCarryUpdate(player)
		if _raidService ~= nil and type(_raidService.DropStolen) == "function" then
			pcall(function()
				_raidService.DropStolen(player)
			end)
		else
			-- No RaidService to return it to: keep the instance safe
			-- as a thief-owned world pickup (the in-transit record
			-- already lives in the thief's OwnedInstances) instead of
			-- deleting the Brainrot outright.
			warn("[CarryService] No RaidService; stolen drop kept as world pickup for " .. player.Name)
			local root = getRoot(player)
			if root ~= nil then
				local def = Characters.GetById(carried.CharacterId)
				if def ~= nil then
					local model = buildModelFor(def, 0.8)
					model.Name = "Dropped_" .. tostring(carried.InstanceId)
					for _, descendant in ipairs(model:GetDescendants()) do
						if descendant:IsA("BasePart") then
							descendant.Anchored = true
							descendant.CanCollide = false
						end
					end
					pcall(function()
						model:PivotTo(CFrame.new(root.Position))
					end)
					model.Parent = Workspace
					_dropped[carried.InstanceId] = {
						InstanceId = carried.InstanceId,
						CharacterId = carried.CharacterId,
						Glitched = carried.Glitched,
						Owner = player,
						Model = model,
						ExpiresAt = os.time() + DROP_RECOVERY_SECONDS,
					}
					scheduleDropExpiry(carried.InstanceId, _dropped[carried.InstanceId], player)
				end
			end
		end
		print(string.format("[CarryService] %s dropped stolen %s (%s); returned to victim",
			player.Name, tostring(carried.CharacterId), tostring(reason or "drop")))
		return true, carried
	end

	local root = getRoot(player)
	local dropPos: Vector3? = nil
	if root ~= nil then
		dropPos = root.Position
	end
	if dropPos ~= nil and reason ~= "inventory" then
		local def = Characters.GetById(carried.CharacterId)
		if def ~= nil then
			local model = buildModelFor(def, 0.8)
			model.Name = "Dropped_" .. tostring(carried.InstanceId)
			for _, descendant in ipairs(model:GetDescendants()) do
				if descendant:IsA("BasePart") then
					descendant.Anchored = true
					descendant.CanCollide = false
				end
			end
			pcall(function()
				model:PivotTo(CFrame.new(dropPos :: Vector3))
			end)
			model.Parent = Workspace
			_dropped[carried.InstanceId] = {
				InstanceId = carried.InstanceId,
				CharacterId = carried.CharacterId,
				Glitched = carried.Glitched,
				Owner = player,
				Model = model,
				ExpiresAt = os.time() + DROP_RECOVERY_SECONDS,
			}
			-- Recovery timer: delete the world model; the instance stays
			-- in data.OwnedInstances, i.e. back in the owner's inventory.
			scheduleDropExpiry(carried.InstanceId, _dropped[carried.InstanceId], player)
		end
	end
	fireCarryUpdate(player)
	print(string.format("[CarryService] %s dropped %s (%s)",
		player.Name, tostring(carried.CharacterId), tostring(reason or "drop")))
	return true, carried
end

-- Pickup from a ground drop (owner only) or from the player's inventory.
-- Returns (true, instanceId) / (false, reason).
function CarryService.PickupBrainrot(player: Player, instanceId: any): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid instance"
	end
	if _carrying[player] ~= nil then
		return false, "already carrying"
	end
	local rootPos: Vector3? = nil
	local root = getRoot(player)
	if root ~= nil then
		rootPos = root.Position
	end

	-- Case 1: a dropped world model. Only its owner may recover it;
	-- stealing goes through RaidService.TryPickupStolen, not this remote.
	local drop = _dropped[instanceId]
	if drop ~= nil then
		if drop.Owner ~= player then
			return false, "that brainrot belongs to someone else"
		end
		local model = drop.Model
		local dropPos: Vector3? = nil
		if typeof(model) == "Instance" then
			local ok, pivot = pcall(function()
				return (model :: Model):GetPivot().Position
			end)
			if ok then
				dropPos = pivot
			end
		end
		if rootPos == nil or dropPos == nil or (rootPos - dropPos).Magnitude > PICKUP_DISTANCE then
			return false, "too far from the dropped brainrot"
		end
		_dropped[instanceId] = nil
		if typeof(model) == "Instance" then
			pcall(function()
				(model :: Instance):Destroy()
			end)
		end
		local data = _dataService.GetOrLoad(player)
		local owned: { [string]: any }? = nil
		if type(data.OwnedInstances) == "table" then
			for _, record in ipairs(data.OwnedInstances) do
				if record.InstanceId == instanceId then
					owned = record
					break
				end
			end
		end
		if owned == nil then
			return false, "brainrot not owned"
		end
		return CarryService.PickupOwned(player, owned)
	end

	-- Case 2: carry straight from the inventory list.
	local data = _dataService.GetOrLoad(player)
	local owned: { [string]: any }? = nil
	if type(data.OwnedInstances) == "table" then
		for _, record in ipairs(data.OwnedInstances) do
			if record.InstanceId == instanceId then
				owned = record
				break
			end
		end
	end
	if owned == nil then
		return false, "brainrot not owned"
	end
	return CarryService.PickupOwned(player, owned)
end

-- Validation hook for RaidService: can `player` steal this placed Brainrot
-- from `fromPlayer`'s base? Pure validation — no transfer happens here.
-- Returns (true, placedRecord) or (false, reason).
function CarryService.TryPickupStolen(player: Player, instanceId: string, fromPlayer: Player): (boolean, any)
	if not player or not player.Parent or not fromPlayer or not fromPlayer.Parent then
		return false, "invalid player"
	end
	if player == fromPlayer then
		return false, "cannot steal from yourself"
	end
	if _carrying[player] ~= nil then
		return false, "already carrying"
	end
	if _baseService == nil or type(_baseService.GetPlaced) ~= "function" then
		return false, "base service unavailable"
	end
	local placedRecord: { [string]: any }? = nil
	for _, placed in ipairs(_baseService.GetPlaced(fromPlayer)) do
		if placed.InstanceId == instanceId then
			placedRecord = placed
			break
		end
	end
	if placedRecord == nil then
		return false, "brainrot not in that base"
	end
	if type(_baseService.IsLocked) == "function" and _baseService.IsLocked(fromPlayer) then
		return false, "base is locked"
	end
	local pedestalPos: Vector3? = nil
	if type(_baseService.GetPlacedPosition) == "function" then
		pedestalPos = _baseService.GetPlacedPosition(fromPlayer, instanceId)
	end
	local root = getRoot(player)
	if root == nil or pedestalPos == nil or (root.Position - pedestalPos).Magnitude > PICKUP_DISTANCE then
		return false, "too far from the victim's base"
	end
	return true, placedRecord
end

function CarryService.GetDropped(): { { [string]: any } }
	local list: { { [string]: any } } = {}
	for _, drop in pairs(_dropped) do
		table.insert(list, {
			InstanceId = drop.InstanceId,
			CharacterId = drop.CharacterId,
			OwnerUserId = drop.Owner and drop.Owner.UserId or 0,
			ExpiresAt = drop.ExpiresAt,
		})
	end
	return list
end

-- -------------------------------------------------------------------------
-- Remote wiring + lifecycle
-- -------------------------------------------------------------------------

local function onPickupBrainrot(player: Player, instanceId: any): ()
	if rateLimited(player) then
		return
	end
	local ok, success, reason = pcall(function()
		return CarryService.PickupBrainrot(player, instanceId)
	end)
	if not ok then
		warn("[CarryService] PickupBrainrot error for " .. player.Name .. ": " .. tostring(success))
	elseif not success then
		warn("[CarryService] PickupBrainrot denied for " .. player.Name .. ": " .. tostring(reason))
	end
end

local function onDropBrainrot(player: Player): ()
	if rateLimited(player) then
		return
	end
	pcall(function()
		CarryService.DropCarried(player, "manual")
	end)
end

local function hookCharacter(player: Player): ()
	player.CharacterAdded:Connect(function(character: Model)
		-- Restore normal speed on a fresh spawn; carry state was cleared
		-- when the old character died / was removed.
		task.wait(0.2)
		if _carrying[player] == nil then
			applyCarrySpeed(player, false)
		else
			-- Re-attach the visual if the player respawned while carrying
			-- (e.g. a tide hit that did not kill them).
			attachCarryModel(player, _carrying[player].CharacterId)
			applyCarrySpeed(player, true)
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.Died:Connect(function()
				if Config.CarryDropOnDeath ~= false then
					-- Drop at the death position if the body is still there.
					CarryService.DropCarried(player, "death")
				else
					CarryService.ClearCarried(player, false)
				end
			end)
		end
	end)
	player.CharacterRemoving:Connect(function()
		-- The welded visual dies with the character; forget the model ref
		-- but keep the carry record — Died already dropped it, and if the
		-- character vanished another way the record is cleared on respawn.
		_carryModels[player] = nil
	end)
end

function CarryService.Init(dataService: any, baseService: any): ()
	assert(dataService ~= nil, "[CarryService] Init requires DataService")
	assert(baseService ~= nil, "[CarryService] Init requires BaseService")
	if _running then
		return
	end
	_running = true
	_dataService = dataService
	_baseService = baseService

	task.spawn(function()
		local pickupRemote: RemoteEvent? = nil
		local dropRemote: RemoteEvent? = nil
		for _ = 1, 50 do
			pickupRemote = pickupRemote or getEvent(Remotes.Names.PickupBrainrot)
			dropRemote = dropRemote or getEvent(Remotes.Names.DropBrainrot)
			if pickupRemote ~= nil and dropRemote ~= nil then
				break
			end
			task.wait(0.2)
		end
		if pickupRemote ~= nil then
			pickupRemote.OnServerEvent:Connect(onPickupBrainrot)
		else
			warn("[CarryService] PickupBrainrot remote not available")
		end
		if dropRemote ~= nil then
			dropRemote.OnServerEvent:Connect(onDropBrainrot)
		else
			warn("[CarryService] DropBrainrot remote not available")
		end
	end)

	Players.PlayerAdded:Connect(hookCharacter)
	for _, player in ipairs(Players:GetPlayers()) do
		hookCharacter(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		-- Leaving while carrying: the instance stays owned in data, the
		-- visual and state are discarded. Any world drops they owned are
		-- removed (the instance is back in their inventory list in data).
		CarryService.ClearCarried(player, true)
		for instanceId, drop in pairs(_dropped) do
			if drop.Owner == player then
				_dropped[instanceId] = nil
				local model = drop.Model
				if typeof(model) == "Instance" then
					pcall(function()
						(model :: Instance):Destroy()
					end)
				end
			end
		end
		_lastCall[player] = nil
	end)
end

return CarryService
