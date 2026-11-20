--!strict
-- ConveyorService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Owns the shared Rift Market conveyor: server-side weighted rarity
-- spawns, movement along the conveyor waypoints, price billboards, and
-- the BuyConveyor purchase (server price, distance and balance checks —
-- the client can only ask). Bought Brainrots go straight into the
-- buyer's carry via CarryService. Conveyor items are world stock: a
-- player leaving never removes them.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require("../shared/Config")
local Characters = require("../shared/Characters")
local Remotes = require("../shared/Remotes")

local MapBuilder = require("./MapBuilderStub")

local ConveyorService = {}

local _dataService: any = nil
local _economyService: any = nil
local _carryService: any = nil
local _mutationService: any = nil
local _luckProvider: (() -> number)? = nil
local _glitchMode = false
local _running = false

local _items: { [string]: { [string]: any } } = {} -- InstanceId -> item record
local _lastCall: { [Player]: number } = {}
local _waypoints: { Vector3 } = {}
local _pathLength = 0
local _segmentLengths: { number } = {}
-- One-shot rare-spawn announcement, consumed by the next broadcast.
local _announcement: string? = nil

-- Rarity rank for announcement threshold (Characters ladder order).
local RARITY_RANK: { [string]: number } = {
	Common = 1,
	Uncommon = 2,
	Rare = 3,
	Epic = 4,
	Legendary = 5,
	Mythic = 6,
	Divine = 7,
	Celestial = 8,
	Secret = 9,
	Impossible = 10,
}

local MIN_CALL_INTERVAL = 0.25
local BUY_DISTANCE = 12
local MOVE_SPEED = 1 -- studs per second along the belt
local GLITCHED_DESPAWN_SECONDS = 25

type OwnedRecord = {
	InstanceId: string,
	CharacterId: string,
	Level: number,
	Glitched: boolean,
	Mutation: string?,
	Placed: boolean,
	Slot: number,
	PurchasedAt: number,
}

-- -------------------------------------------------------------------------
-- Shared-module helpers (defensive: the other agent may replace these)
-- -------------------------------------------------------------------------

local _economyMod: any = nil
do
	local ok, mod = pcall(function()
		return require("../shared/Economy")
	end)
	if ok then
		_economyMod = mod
	end
end

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
	-- Prefer the shared CharacterModels builder; fall back to a small
	-- procedural stand-in built from the character's colours so the
	-- conveyor never breaks when that module is absent.
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
	body.Anchored = true
	body.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.6 * scale, 1.4 * scale, 1.6 * scale)
	head.Color = (def.AccentColor :: Color3)
	head.Material = Enum.Material.SmoothPlastic
	head.Anchored = true
	head.Parent = model
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

local function fireAll(name: string, payload: any): ()
	local remote = getEvent(name)
	if remote ~= nil then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function fireClient(name: string, player: Player, payload: any): ()
	local remote = getEvent(name)
	if remote ~= nil then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
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

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return (root :: BasePart).Position
end

local function priceFor(characterId: string, glitched: boolean): number
	if _economyMod ~= nil and type(_economyMod.ConveyorPrice) == "function" then
		local ok, price = pcall(_economyMod.ConveyorPrice, characterId, glitched)
		if ok and type(price) == "number" then
			return price
		end
	end
	local def = Characters.GetById(characterId)
	if def == nil then
		return 0
	end
	if glitched then
		return math.floor(def.Cost * 1.5 + 0.5)
	end
	return def.Cost
end

-- -------------------------------------------------------------------------
-- Weighted rarity pick (Characters has no GetRandomWeighted).
-- Config.ConveyorRarityWeights only covers part of the 10-tier ladder,
-- so weights are intersected with the rarities the live roster actually
-- has; a weight for a missing rarity can never be rolled.
local _effectiveWeights: { [string]: number }? = nil
local function effectiveWeights(): { [string]: number }
	if _effectiveWeights ~= nil then
		return _effectiveWeights
	end
	local present: { [string]: boolean } = {}
	local ok, list = pcall(function()
		return Characters.GetRarityList()
	end)
	if ok and type(list) == "table" then
		for _, rarity in ipairs(list) do
			present[rarity] = true
		end
	else
		for _, def in ipairs(Characters.GetAll()) do
			present[def.Rarity] = true
		end
	end
	local weights: { [string]: number } = {}
	for rarity, w in pairs(Config.ConveyorRarityWeights) do
		if present[rarity] then
			weights[rarity] = tonumber(w) or 0
		end
	end
	if next(weights) == nil then
		-- No overlap at all (e.g. weights predate the roster): every
		-- present rarity gets equal weight rather than breaking spawns.
		for rarity in pairs(present) do
			weights[rarity] = 1
		end
	end
	_effectiveWeights = weights
	return weights
end

local function pickRarity(): string
	local weights = effectiveWeights()
	-- v1.1 companion RareDetection: the strongest detection bonus among
	-- players currently in-game boosts Epic+ weights on the SHARED
	-- conveyor (the spawn roll has no buying player, so a per-player
	-- roll is impossible — the server-wide best bonus applies instead).
	-- Capped at +20%, matching CompanionService's cap.
	local detectBonus = 0
	pcall(function()
		local mod = script.Parent:FindFirstChild("CompanionService")
		if not mod then
			return
		end
		local svc = require(mod)
		if type(svc.GetRareWeightMultiplier) ~= "function" then
			return
		end
		for _, p in ipairs(Players:GetPlayers()) do
			local ok, mult = pcall(svc.GetRareWeightMultiplier, p, "Epic")
			if ok and type(mult) == "number" then
				detectBonus = math.max(detectBonus, mult - 1)
			end
		end
	end)
	detectBonus = math.clamp(detectBonus, 0, 0.20)
	-- Adjusted weights (the cached table is never mutated).
	local adjusted: { [string]: number } = {}
	for rarity, w in pairs(weights) do
		local weight = tonumber(w) or 0
		if detectBonus > 0 then
			local rankOk, rank = pcall(function()
				return Characters.GetRarityRank(rarity)
			end)
			if rankOk and type(rank) == "number" and rank >= 4 then
				weight *= (1 + detectBonus)
			end
		end
		adjusted[rarity] = weight
	end
	local total = 0
	for _, w in pairs(adjusted) do
		total += tonumber(w) or 0
	end
	if total <= 0 then
		return "Common"
	end
	local roll = math.random() * total
	for rarity, w in pairs(adjusted) do
		roll -= tonumber(w) or 0
		if roll <= 0 then
			return rarity
		end
	end
	return "Common"
end

local function pickCharacter(rarity: string?): any
	local pool: { any } = {}
	if rarity ~= nil and rarity ~= "" then
		local ok, byRarity = pcall(function()
			return Characters.GetByRarity(rarity)
		end)
		if ok and type(byRarity) == "table" then
			pool = byRarity
		end
	end
	if #pool == 0 then
		pool = Characters.GetAll()
	end
	if #pool == 0 then
		return nil
	end
	return pool[math.random(1, #pool)]
end

-- -------------------------------------------------------------------------
-- Item lifecycle
-- -------------------------------------------------------------------------

local function itemSnapshot(item: { [string]: any }): { [string]: any }
	local def = Characters.GetById(item.CharacterId)
	return {
		InstanceId = item.InstanceId,
		CharacterId = item.CharacterId,
		Name = def and def.DisplayName or tostring(item.CharacterId),
		Rarity = def and def.Rarity or "Common",
		Glitched = item.Glitched,
		Price = item.Price,
		IncomePerSec = def and def.IncomePerSec or 0,
		Position = item.Position,
	}
end

local function broadcastItems(): ()
	local list: { { [string]: any } } = {}
	for _, item in pairs(_items) do
		table.insert(list, itemSnapshot(item))
	end
	local payload: { [string]: any } = { Items = list, GlitchMode = _glitchMode }
	if _announcement ~= nil then
		payload.Announcement = _announcement
		_announcement = nil
	end
	fireAll(Remotes.Names.ConveyorUpdate, payload)
end

-- Announce rare spawns (Epic and above, plus any glitched Brainrot) so
-- the market moment is visible: server log + Announcement field on the
-- next ConveyorUpdate broadcast for clients to display.
local function announceRare(def: any, glitched: boolean): ()
	local rank = RARITY_RANK[tostring(def.Rarity)] or 1
	if rank < 4 and not glitched then
		return
	end
	local text = string.format("RARE on the conveyor: %s (%s)%s",
		tostring(def.DisplayName or def.Id), tostring(def.Rarity),
		glitched and " [GLITCHED]" or "")
	_announcement = text
	print("[ConveyorService] " .. text)
end

local function positionToCFrame(t: number): CFrame
	if #_waypoints == 0 then
		return CFrame.new(0, 2.6, -60)
	end
	if #_waypoints == 1 or t <= 0 then
		return CFrame.new(_waypoints[1])
	end
	if t >= 1 then
		return CFrame.new(_waypoints[#_waypoints])
	end
	local target = t * _pathLength
	local travelled = 0
	for i = 1, #_waypoints - 1 do
		local segLen = _segmentLengths[i] or 0
		if travelled + segLen >= target then
			local localT = 0
			if segLen > 0 then
				localT = (target - travelled) / segLen
			end
			local pos = _waypoints[i]:Lerp(_waypoints[i + 1], localT)
			local dir = (_waypoints[i + 1] - _waypoints[i]).Unit
			return CFrame.lookAt(pos, pos + dir)
		end
		travelled += segLen
	end
	return CFrame.new(_waypoints[#_waypoints])
end

local function makeBillboard(def: any, price: number, glitched: boolean): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "PriceDisplay"
	gui.Size = UDim2.new(0, 170, 0, 78)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	gui.AlwaysOnTop = true
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0.3, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = tostring(def.DisplayName or def.Id) .. (glitched and " [GLITCHED]" or "")
	nameLabel.TextColor3 = glitched and Color3.fromRGB(255, 90, 220) or Color3.fromRGB(255, 255, 255)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.Parent = frame
	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Position = UDim2.new(0, 0, 0.3, 0)
	rarityLabel.Size = UDim2.new(1, 0, 0.25, 0)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Text = tostring(def.Rarity)
	rarityLabel.TextColor3 = Color3.fromRGB(255, 220, 90)
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.TextScaled = true
	rarityLabel.Parent = frame
	local statsLabel = Instance.new("TextLabel")
	statsLabel.Position = UDim2.new(0, 0, 0.55, 0)
	statsLabel.Size = UDim2.new(1, 0, 0.45, 0)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Text = string.format("Cost: %d coins | +%d/s", price, def.IncomePerSec)
	statsLabel.TextColor3 = Color3.fromRGB(140, 255, 170)
	statsLabel.Font = Enum.Font.Gotham
	statsLabel.TextScaled = true
	statsLabel.Parent = frame
	return gui
end

local function removeItem(instanceId: string, reason: string): ()
	local item = _items[instanceId]
	if item == nil then
		return
	end
	_items[instanceId] = nil
	local model = item.Model
	if typeof(model) == "Instance" then
		pcall(function()
			(model :: Instance):Destroy()
		end)
	end
	print(string.format("[ConveyorService] Item %s removed (%s)", tostring(instanceId), reason))
	broadcastItems()
end

function ConveyorService.ForceSpawn(rarity: string?): { [string]: any }?
	local count = 0
	for _ in pairs(_items) do
		count += 1
	end
	if count >= (tonumber(Config.ConveyorMaxItems) or 8) then
		return nil
	end
	local chosenRarity = rarity
	if chosenRarity == nil or chosenRarity == "" then
		chosenRarity = pickRarity()
	end
	local def = pickCharacter(chosenRarity)
	if def == nil then
		return nil
	end
	-- If the rolled rarity has no characters, fall back to any character.
	if def.Rarity ~= chosenRarity and (rarity ~= nil and rarity ~= "") then
		def = pickCharacter(nil) or def
	end

	local luck = 0
	if _luckProvider ~= nil then
		local ok, value = pcall(_luckProvider)
		if ok and type(value) == "number" then
			luck = math.clamp(math.floor(value), 0, 10)
		end
	end
	local glitchChance = 0.02 + luck * 0.02
	if _glitchMode then
		glitchChance = tonumber(Config.GlitchTideGlitchChance) or 0.35
	end
	local glitched = def.Rarity == "Glitch" or math.random() < glitchChance
	local price = priceFor(def.Id, glitched)

	local model = buildModelFor(def, tonumber(def.Scale) or 1)
	model.Name = "Conveyor_" .. tostring(def.Id)
	if _characterModels ~= nil and type(_characterModels.SetDisplayMode) == "function" then
		pcall(_characterModels.SetDisplayMode, model, true)
	end
	local platform = Instance.new("Part")
	platform.Name = "Platform"
	platform.Size = Vector3.new(3.4, 0.5, 3.4)
	platform.Color = Color3.fromRGB(45, 45, 60)
	platform.Material = Enum.Material.SmoothPlastic
	platform.Anchored = true
	platform.Parent = model
	-- PivotTo places the whole model (platform at local origin, character
	-- standing on it) at the first waypoint.
	pcall(function()
		model:PivotTo(CFrame.new(_waypoints[1] or Vector3.new(-30, 2.6, -60)))
	end)
	makeBillboard(def, price, glitched).Parent = model
	model.Parent = Workspace

	local instanceId = HttpService:GenerateGUID(false)
	local item: { [string]: any } = {
		InstanceId = instanceId,
		CharacterId = def.Id,
		Glitched = glitched,
		Price = price,
		Position = 0,
		Model = model,
		SpawnedAt = os.time(),
		DespawnAt = glitched and (os.time() + GLITCHED_DESPAWN_SECONDS) or nil,
	}
	_items[instanceId] = item
	announceRare(def, glitched)
	broadcastItems()
	return itemSnapshot(item)
end

function ConveyorService.GetItems(): { { [string]: any } }
	local list: { { [string]: any } } = {}
	for _, item in pairs(_items) do
		table.insert(list, itemSnapshot(item))
	end
	return list
end

function ConveyorService.GetItem(instanceId: string): { [string]: any }?
	local item = _items[instanceId]
	if item == nil then
		return nil
	end
	return itemSnapshot(item)
end

function ConveyorService.SetGlitchMode(enabled: boolean): ()
	_glitchMode = enabled == true
	print("[ConveyorService] Glitch mode: " .. tostring(_glitchMode))
	broadcastItems()
end

function ConveyorService.IsGlitchMode(): boolean
	return _glitchMode
end

function ConveyorService.SetCarryService(carryService: any): ()
	_carryService = carryService
end

function ConveyorService.SetMutationService(mutationService: any): ()
	_mutationService = mutationService
end

function ConveyorService.SetLuckProvider(provider: (() -> number)?): ()
	_luckProvider = provider
end

-- Server-side purchase. Returns (true, ownedRecord) or (false, reason).
-- Atomic: the item is claimed out of the shared stock BEFORE any coins
-- move, so two players racing the same Brainrot cannot both buy it —
-- the loser finds no item and is charged nothing. Any failure after
-- the deduction refunds the exact price.
function ConveyorService.BuyItem(player: Player, instanceId: string): (boolean, any)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid item"
	end
	local item = _items[instanceId]
	if item == nil then
		return false, "item no longer for sale"
	end
	local def = Characters.GetById(item.CharacterId)
	if def == nil then
		-- Unknown character: pull the broken listing, charge nothing.
		removeItem(instanceId, "unknown character removed")
		return false, "item no longer for sale"
	end
	local model = item.Model
	local itemPos: Vector3? = nil
	if typeof(model) == "Instance" and (model :: Instance):FindFirstChild("Platform") then
		local platform = (model :: Instance):FindFirstChild("Platform")
		if platform and platform:IsA("BasePart") then
			itemPos = (platform :: BasePart).Position
		end
	elseif typeof(model) == "Instance" then
		local ok, pivot = pcall(function()
			return (model :: Model):GetPivot().Position
		end)
		if ok then
			itemPos = pivot
		end
	end
	local rootPos = rootPosition(player)
	if rootPos == nil or itemPos == nil or (rootPos - itemPos).Magnitude > BUY_DISTANCE then
		return false, "too far from the conveyor item"
	end
	local data = _dataService.GetOrLoad(player)
	local coins = tonumber(data.Coins) or 0
	local price = tonumber(item.Price) or 0
	-- R4-3: affordability is judged on spendable coins (balance
	-- above any reservation held for a pending reward commit).
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, spendable = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(spendable) == "number" then
			coins = spendable
		end
	end
	if coins < price then
		return false, "not enough coins"
	end

	-- Claim the item: it leaves the shared stock now, before the
	-- deduction, so it can never be sold twice or bought after it
	-- despawns. The world model is destroyed with the claim.
	_items[instanceId] = nil
	if typeof(model) == "Instance" then
		pcall(function()
			(model :: Instance):Destroy()
		end)
	end

	_dataService.AddCoins(player, -price)
	-- The owned-instance registry is data.OwnedInstances (shared with
	-- MutationService). Create through it when wired so mutations and
	-- fusion see the same record; otherwise insert the same shape here.
	local owned: OwnedRecord? = nil
	if _mutationService ~= nil and type(_mutationService.CreateInstance) == "function" then
		local ok, record = pcall(function()
			return _mutationService.CreateInstance(player, item.CharacterId, 1, nil)
		end)
		if ok and type(record) == "table" and type(record.InstanceId) == "string" then
			record.Glitched = item.Glitched == true
			record.Mutation = item.Glitched == true and "glitched" or nil
			record.PurchasedAt = os.time()
			owned = record
		end
	end
	if owned == nil then
		local ok, record = pcall(function()
			local data2 = _dataService.GetOrLoad(player)
			if type(data2.OwnedInstances) ~= "table" then
				data2.OwnedInstances = {}
			end
			local fresh: OwnedRecord = {
				InstanceId = HttpService:GenerateGUID(false),
				CharacterId = item.CharacterId,
				Level = 1,
				Glitched = item.Glitched == true,
				Mutation = item.Glitched == true and "glitched" or nil,
				Placed = false,
				Slot = 0,
				PurchasedAt = os.time(),
			}
			table.insert(data2.OwnedInstances, fresh)
			return fresh
		end)
		if ok and type(record) == "table" then
			owned = record
		end
	end
	if owned == nil then
		-- Charged but no record: refund in full, the item is gone but
		-- the player loses nothing.
		_dataService.AddCoins(player, price)
		if _economyService ~= nil and _economyService.NotifyBalance ~= nil then
			pcall(_economyService.NotifyBalance, player)
		end
		broadcastItems()
		return false, "purchase failed"
	end
	broadcastItems()
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	if _economyService ~= nil and _economyService.NotifyBalance ~= nil then
		pcall(_economyService.NotifyBalance, player)
	end

	-- Auto-pickup into carry. If the player is already carrying, the
	-- Brainrot stays in their inventory list — the purchase itself
	-- still stands.
	if _carryService ~= nil and type(_carryService.PickupOwned) == "function" then
		local ok, carried, reason = pcall(function()
			return _carryService.PickupOwned(player, owned)
		end)
		if not ok or not carried then
			warn("[ConveyorService] Auto-pickup failed for " .. player.Name .. ": " .. tostring(reason))
		end
	end
	print(string.format("[ConveyorService] %s bought %s for %d coins",
		player.Name, tostring(item.CharacterId), price))
	return true, owned
end

local function onBuyConveyor(player: Player, instanceId: any): ()
	if rateLimited(player) then
		fireClient(Remotes.Names.ConveyorUpdate, player, {
			Items = ConveyorService.GetItems(),
			Success = false,
			Message = "slow down",
		})
		return
	end
	local ok, success, result = pcall(function()
		return ConveyorService.BuyItem(player, tostring(instanceId))
	end)
	if not ok then
		warn("[ConveyorService] BuyItem error for " .. player.Name .. ": " .. tostring(success))
		fireClient(Remotes.Names.ConveyorUpdate, player, {
			Items = ConveyorService.GetItems(),
			Success = false,
			Message = "purchase failed",
		})
		return
	end
	-- Reply to the buyer with the outcome (the client clears its
	-- pending-buy state on any ConveyorUpdate; Success/Message carry
	-- the reason when the purchase was refused — nothing was charged).
	fireClient(Remotes.Names.ConveyorUpdate, player, {
		Items = ConveyorService.GetItems(),
		Success = success == true,
		Message = success == true and "purchase complete" or tostring(result),
	})
	if not success then
		warn("[ConveyorService] Buy denied for " .. player.Name .. ": " .. tostring(result))
	end
end

function ConveyorService.OnPlayerLeaving(player: Player): ()
	-- Conveyor stock is shared world stock; a leaver's items stay.
	_lastCall[player] = nil
end

function ConveyorService.Init(dataService: any, economyService: any, map: Model?): ()
	assert(dataService ~= nil, "[ConveyorService] Init requires DataService")
	_dataService = dataService
	_economyService = economyService
	_waypoints = MapBuilder.GetConveyorPath()
	_pathLength = 0
	_segmentLengths = {}
	for i = 1, #_waypoints - 1 do
		local len = (_waypoints[i + 1] - _waypoints[i]).Magnitude
		table.insert(_segmentLengths, len)
		_pathLength += len
	end
	if _pathLength <= 0 then
		_pathLength = tonumber(Config.ConveyorLength) or 60
	end

	-- Wire the BuyConveyor remote (retry briefly: Main creates remotes first,
	-- but this service may init a frame earlier in some load orders).
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getEvent(Remotes.Names.BuyConveyor)
			if remote ~= nil then
				break
			end
			task.wait(0.2)
		end
		if remote ~= nil then
			remote.OnServerEvent:Connect(onBuyConveyor)
		else
			warn("[ConveyorService] BuyConveyor remote not available")
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		ConveyorService.OnPlayerLeaving(player)
	end)

	if _running then
		return
	end
	_running = true

	-- Spawn loop.
	task.spawn(function()
		task.wait(1)
		pcall(function()
			ConveyorService.ForceSpawn(nil)
			ConveyorService.ForceSpawn(nil)
		end)
		while true do
			task.wait(tonumber(Config.ConveyorSpawnInterval) or 8)
			pcall(function()
				ConveyorService.ForceSpawn(nil)
			end)
		end
	end)

	-- Movement loop: advance every item ~1 stud/sec, animate the belt
	-- chevrons, despawn at the end gate (and glitched items early).
	task.spawn(function()
		local beltParts = MapBuilder.GetBeltParts()
		local minX, maxX, beltY = MapBuilder.GetBeltBounds()
		while true do
			local dt = task.wait(0.1)
			dt = dt or 0.1
			-- Belt chevrons slide +X and wrap.
			for _, chevron in ipairs(beltParts) do
				if chevron.Parent ~= nil then
					local x = chevron.Position.X + MOVE_SPEED * dt
					if x > maxX then
						x = minX + (x - maxX)
					end
					chevron.CFrame = CFrame.new(x, beltY, chevron.Position.Z)
				end
			end
			-- Items ride the waypoints.
			local now = os.time()
			local toRemove: { [string]: string } = {}
			for id, item in pairs(_items) do
				local model = item.Model
				if typeof(model) ~= "Instance" or (model :: Instance).Parent == nil then
					toRemove[id] = "model gone"
				else
					local pos = (tonumber(item.Position) or 0) + (MOVE_SPEED * dt) / _pathLength
					item.Position = pos
					if pos >= 1 then
						toRemove[id] = "reached end of conveyor"
					elseif item.DespawnAt ~= nil and now >= (tonumber(item.DespawnAt) or 0) then
						toRemove[id] = "glitched item expired"
					else
						pcall(function()
							(model :: Model):PivotTo(positionToCFrame(pos))
						end)
					end
				end
			end
			for id, reason in pairs(toRemove) do
				removeItem(id, reason)
			end
		end
	end)
end

return ConveyorService
