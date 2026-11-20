-- harness.luau — reusable stub harness for Phase 1 Lune tests.
--
-- HOW TO REUSE (later test files):
--   local H = require("../harness")          -- from scripts/phase1-tests/<area>/*.luau
--   local env = H.newEnv()                  -- loads the REAL service modules
--                                            -- (copies under theft/services/)
--                                            -- with stubbed Roblox globals
--   local pair = H.newPair(env, 101, 202)    -- thief + victim fixture pair
--   H.check("name", condition, "detail")     -- record a PASS / FAIL
--   H.finish()                              -- print summary; errors if any failed
--
-- WHAT IT STUBS: `game` (Players / ReplicatedStorage / Debris / Workspace /
-- RunService / HttpService), `workspace`, `Color3`, `Enum`, `Vector3`,
-- `CFrame`, `Instance` (mock instances with IsA / FindFirstChild /
-- GetDescendants / SetAttribute / signals), and `task` — whose spawn/delay
-- are DISCARDED by design (never run): RaidService.Init spawns an infinite
-- watchdog loop, and the services' remote-wiring spawns loop 50x; running
-- them would hang the test process. Saves are best-effort fire-and-forget
-- in the services, so tests assert on data state directly instead.
-- `task.wait` returns 0 immediately, so StealBrainrot's 3s channel runs
-- instantly with no real sleep.
--
-- KNOWN HARNESS LIMITS (Lune, not game code): Lune 0.11.1's `typeof`
-- ignores the `__type` metamethod, so `typeof(x) == "Vector3"` /
-- `== "Instance"` checks in the services always fail here (they work
-- in Roblox). Every such check in the tested paths has a fallback the
-- tests exercise instead (pedestal positions -> base position;
-- CharacterModels visuals -> Instance.new fallback). Nothing under
-- test depends on `typeof` returning the Roblox type.
-- src/ apart from require lines — refresh.sh fails if they diverge).
-- Run `bash scripts/phase1-tests/theft/refresh.sh` after any src/ change.
-- Each `lune run` is a fresh process, so each test file gets fresh
-- module state; within one file, build ONE env and as many player pairs
-- as needed (pairs use distinct userIds / instance ids, so the services'
-- per-pair / per-instance state never collides).
--
-- DATA SERVICE STUB: GetOrLoad/GetData return the test's plain data
-- tables; AddCoins/UnlockCharacter mutate them; SaveData only counts
-- calls (the services never depend on its result).

-- ---------------------------------------------------------------------------
-- Roblox value types
-- ---------------------------------------------------------------------------

local Vector3MT = {}
Vector3MT.__type = "Vector3"
Vector3MT.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	end
	return nil
end
Vector3MT.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3MT.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3 = {
	new = function(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3MT)
	end,
}

CFrame = {
	new = function(x, y, z)
		local pos
		if type(x) == "table" and x.X ~= nil then
			pos = x
		else
			pos = Vector3.new(x or 0, y or 0, z or 0)
		end
		return setmetatable({ Position = pos }, {
			__type = "CFrame",
			__mul = function(_, _)
				return CFrame.new(0, 0, 0)
			end,
		})
	end,
	Angles = function(...)
		return CFrame.new(0, 0, 0)
	end,
}

Color3 = {
	fromRGB = function(r, g, b)
		return { R = r / 255, G = g / 255, B = b / 255 }
	end,
	new = function(r, g, b)
		return { R = r or 0, G = g or 0, B = b or 0 }
	end,
}

BrickColor = {
	new = function(name)
		return { Name = name }
	end,
}

local function anyEnum()
	return setmetatable({}, {
		__index = function(_, k)
			return k
		end,
	})
end
Enum = {
	PartType = anyEnum(),
	Material = anyEnum(),
	KeyCode = anyEnum(),
	Font = anyEnum(),
}

-- ---------------------------------------------------------------------------
-- Mock Instance
-- ---------------------------------------------------------------------------

local ISA: { [string]: { string } } = {
	Part = { "Part", "BasePart", "Instance" },
	Model = { "Model", "Instance" },
	Humanoid = { "Humanoid", "Instance" },
	Folder = { "Folder", "Instance" },
	RemoteEvent = { "RemoteEvent", "Instance" },
	RemoteFunction = { "RemoteFunction", "Instance" },
	Weld = { "Weld", "Instance" },
}

local function makeSignal()
	local sig = { _fns = {} }
	function sig:Connect(fn)
		table.insert(self._fns, fn)
		return { Disconnect = function() end }
	end
	function sig:Fire(...)
		for _, fn in ipairs(self._fns) do
			fn(...)
		end
	end
	return sig
end

local function makeInstance(className)
	local inst: { [string]: any } = {
		ClassName = className,
		Name = className,
		Parent = nil,
		Children = {},
		Attributes = {},
		Position = Vector3.new(0, 0, 0),
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(0, 0, 0),
		Anchored = false,
		CanCollide = true,
		Massless = false,
		Color = Color3.new(1, 1, 1),
		Material = "SmoothPlastic",
		Health = 100,
		WalkSpeed = 16,
		PrimaryPart = nil,
		Destroyed = false,
		_signals = {},
	}
	local function getSignal(name)
		if not inst._signals[name] then
			inst._signals[name] = makeSignal()
		end
		return inst._signals[name]
	end
	inst._getSignal = getSignal
	function inst:IsA(class)
		for _, c in ipairs(ISA[className] or { className, "Instance" }) do
			if c == class then
				return true
			end
		end
		return false
	end
	function inst:FindFirstChild(name)
		for _, child in ipairs(self.Children) do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	function inst:FindFirstChildOfClass(class)
		for _, child in ipairs(self.Children) do
			if child:IsA(class) then
				return child
			end
		end
		return nil
	end
	function inst:WaitForChild(name, _timeout)
		return self:FindFirstChild(name)
	end
	function inst:GetChildren()
		return self.Children
	end
	function inst:GetDescendants()
		local out = {}
		local function walk(node)
			for _, child in ipairs(node.Children) do
				table.insert(out, child)
				walk(child)
			end
		end
		walk(self)
		return out
	end
	function inst:GetPivot()
		return self.CFrame
	end
	function inst:PivotTo(cf)
		self.CFrame = cf
		if cf ~= nil and cf.Position ~= nil then
			self.Position = cf.Position
		end
	end
	function inst:Destroy()
		self.Destroyed = true
		self.Parent = nil
	end
	function inst:SetAttribute(name, value)
		self.Attributes[name] = value
	end
	function inst:GetAttribute(name)
		return self.Attributes[name]
	end
	function inst:FireClient(...) end
	function inst:FireAllClients(...) end
	inst.OnServerEvent = makeSignal()
	inst.OnServerInvoke = nil
	setmetatable(inst, { __type = "Instance" })
	return inst
end

Instance = {
	new = function(className)
		return makeInstance(className)
	end,
}

-- ---------------------------------------------------------------------------
-- task stub: spawn/delay are discarded (see header); wait returns at once.
-- ---------------------------------------------------------------------------

local spawnCount = 0
task = {
	spawn = function(_fn, ...)
		spawnCount += 1
	end,
	wait = function(_seconds)
		return 0
	end,
	delay = function(_seconds, _fn) end,
}

-- ---------------------------------------------------------------------------
-- Services: Players, ReplicatedStorage (+Remotes folder), misc
-- ---------------------------------------------------------------------------

local H: { [string]: any } = {}

local allPlayers: { any } = {}

local PlayersService: { [string]: any } = {}
PlayersService._playerAdded = makeSignal()
PlayersService._playerRemoving = makeSignal()
function PlayersService:GetPlayers()
	return allPlayers
end
function PlayersService:GetPlayerByUserId(userId)
	for _, p in ipairs(allPlayers) do
		if p.UserId == userId then
			return p
		end
	end
	return nil
end
PlayersService.PlayerAdded = PlayersService._playerAdded
PlayersService.PlayerRemoving = PlayersService._playerRemoving

local remotesFolder = makeInstance("Folder")
remotesFolder.Name = "Remotes"
local remoteCache: { [string]: any } = {}
function remotesFolder:FindFirstChild(name)
	for _, child in ipairs(self.Children) do
		if child.Name == name then
			return child
		end
	end
	-- Create-on-demand mock RemoteEvent (all names the services fire on
	-- resolve here; GetFunction is never invoked by the code under test
	-- because the Lab Init wiring spawn is discarded).
	local remote = makeInstance("RemoteEvent")
	remote.Name = name
	remote.Parent = self
	table.insert(self.Children, remote)
	remoteCache[name] = remote
	return remote
end

local ReplicatedStorage: { [string]: any } = {}
function ReplicatedStorage:FindFirstChild(name)
	if name == "Remotes" then
		return remotesFolder
	end
	return nil
end
function ReplicatedStorage:WaitForChild(name, _timeout)
	return self:FindFirstChild(name)
end

local RunService = {
	IsServer = function()
		return true
	end,
	IsClient = function()
		return false
	end,
}

local DebrisService = {
	AddItem = function(_self, _item, _lifetime) end,
}

local WorkspaceService = makeInstance("Folder")
WorkspaceService.Name = "Workspace"

local HttpService = {
	GenerateGUID = function(_self, _braces)
		return "guid-" .. tostring(os.clock()):gsub("%.", "")
	end,
}

local function stubService(name)
	return {
		Name = name,
		IsServer = function()
			return false
		end,
		IsClient = function()
			return true
		end,
		FindFirstChild = function()
			return nil
		end,
		WaitForChild = function()
			error("stub: WaitForChild must not run in the theft harness")
		end,
	}
end

game = {
	GetService = function(_self, name)
		if name == "Players" then
			return PlayersService
		elseif name == "ReplicatedStorage" then
			return ReplicatedStorage
		elseif name == "Debris" then
			return DebrisService
		elseif name == "Workspace" then
			return WorkspaceService
		elseif name == "RunService" then
			return RunService
		elseif name == "HttpService" then
			return HttpService
		end
		return stubService(name)
	end,
}

workspace = {
	FindFirstChild = function(_self, _name)
		return nil
	end,
}

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

function H.newPlayer(userId: number, name: string, accountAge: number?, position: any?): any
	local root = makeInstance("Part")
	root.Name = "HumanoidRootPart"
	root.Position = position or Vector3.new(0, 0, 0)
	root.CFrame = CFrame.new(0, 0, 0)
	local humanoid = makeInstance("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.Health = 100
	humanoid.WalkSpeed = 16
	humanoid.Died = makeSignal()
	local character = makeInstance("Model")
	character.Name = name
	character.Children = { humanoid, root }
	humanoid.Parent = character
	root.Parent = character
	character.PrimaryPart = root
	local player: { [string]: any } = {
		UserId = userId,
		Name = name,
		AccountAge = accountAge or 30,
		Parent = PlayersService,
		Character = character,
		_Humanoid = humanoid,
		_Root = root,
	}
	player.CharacterAdded = makeSignal()
	player.CharacterRemoving = makeSignal()
	function player:IsA(class)
		return class == "Player"
	end
	function player:SetAttribute(attrName, value)
		character:SetAttribute(attrName, value)
	end
	function player:GetAttribute(attrName)
		return character:GetAttribute(attrName)
	end
	table.insert(allPlayers, player)
	return player
end

-- ---------------------------------------------------------------------------
-- DataService stub
-- ---------------------------------------------------------------------------

function H.newDataService(): any
	local datas: { [any]: any } = {}
	local saves: { [any]: number } = {}
	local ds: { [string]: any } = {}
	ds._datas = datas
	ds._saves = saves
	function ds.GetOrLoad(player)
		return datas[player]
	end
	function ds.GetData(player)
		return datas[player]
	end
	function ds.Ensure(player, data)
		datas[player] = data
	end
	function ds.AddCoins(player, amount)
		local d = datas[player]
		if d then
			d.Coins = (tonumber(d.Coins) or 0) + amount
			return d.Coins
		end
		return nil
	end
	function ds.AddXP(player, amount)
		local d = datas[player]
		if d then
			d.XP = (tonumber(d.XP) or 0) + amount
		end
	end
	function ds.UnlockCharacter(player, characterId)
		local d = datas[player]
		if not d then
			return
		end
		if type(d.Unlocked) ~= "table" then
			d.Unlocked = {}
		end
		if table.find(d.Unlocked, characterId) == nil then
			table.insert(d.Unlocked, characterId)
		end
	end
	function ds.SaveData(player)
		saves[player] = (saves[player] or 0) + 1
	end
	return ds
end

-- ---------------------------------------------------------------------------
-- BaseService stub (faithful where RaidService depends on it)
-- ---------------------------------------------------------------------------

function H.newBaseService(dataService: any, opts: any?): any
	opts = opts or {}
	local base: { [string]: any } = {}
	local rebuilds: { [any]: number } = {}
	base._rebuilds = rebuilds
	function base.GetPlaced(player)
		local data = dataService.GetData(player)
		if not data or type(data.Base) ~= "table" or type(data.Base.Placed) ~= "table" then
			return {}
		end
		return data.Base.Placed
	end
	function base.RemovePlaced(player, instanceId)
		local data = dataService.GetData(player)
		if not data or type(data.Base) ~= "table" or type(data.Base.Placed) ~= "table" then
			return nil
		end
		local list = data.Base.Placed
		for index, placed in ipairs(list) do
			if type(placed) == "table" and placed.InstanceId == instanceId then
				table.remove(list, index)
				-- Mirror the real RemovePlaced: sync the owned flag.
				if type(data.OwnedInstances) == "table" then
					for _, inst in ipairs(data.OwnedInstances) do
						if type(inst) == "table" and inst.InstanceId == instanceId then
							inst.Placed = false
							inst.Slot = 0
							break
						end
					end
				end
				return placed
			end
		end
		return nil
	end
	function base.GetPlacedPosition(_player, _instanceId)
		return Vector3.new(0, 0, 0)
	end
	function base.IsLocked(_player)
		return false
	end
	function base.GetBasePosition(_player)
		return Vector3.new(0, 0, 0)
	end
	function base.IsSlotFree(player, slot)
		for _, placed in ipairs(base.GetPlaced(player)) do
			if type(placed) == "table" and placed.Slot == slot then
				return false
			end
		end
		return true
	end
	function base.RebuildBase(player)
		rebuilds[player] = (rebuilds[player] or 0) + 1
	end
	if opts.withPlace ~= false then
		-- Faithful mini-reinsert mirroring BaseService.reinsertPlacedRecord:
		-- fixed-field placed table (evolution fields dropped), original
		-- slot preferred, first-free fallback, existing copy returned.
		function base.PlaceBrainrot(player, record, _slot)
			if type(record) ~= "table" or type(record.InstanceId) ~= "string" then
				return false, "invalid record"
			end
			local data = dataService.GetData(player)
			if not data then
				return false, "no data"
			end
			if type(data.Base) ~= "table" then
				data.Base = { Placed = {} }
			end
			if type(data.Base.Placed) ~= "table" then
				data.Base.Placed = {}
			end
			local list = data.Base.Placed
			for _, existing in ipairs(list) do
				if type(existing) == "table" and existing.InstanceId == record.InstanceId then
					return true, existing
				end
			end
			local slotNum = math.floor(tonumber(record.Slot) or 0)
			if slotNum < 1 or not base.IsSlotFree(player, slotNum) then
				slotNum = 0
				for candidate = 1, 10 do
					if base.IsSlotFree(player, candidate) then
						slotNum = candidate
						break
					end
				end
				if slotNum == 0 then
					slotNum = math.floor(tonumber(record.Slot) or 1)
				end
			end
			local placed = {
				InstanceId = record.InstanceId,
				CharacterId = record.CharacterId,
				Slot = slotNum,
				Level = tonumber(record.Level) or 1,
				Glitched = record.Glitched == true,
				Mutation = record.Mutation,
				BankedIncome = tonumber(record.BankedIncome) or 0,
				PlacedAt = tonumber(record.PlacedAt) or os.time(),
			}
			table.insert(list, placed)
			if type(data.OwnedInstances) == "table" then
				for _, inst in ipairs(data.OwnedInstances) do
					if type(inst) == "table" and inst.InstanceId == record.InstanceId then
						inst.Placed = true
						inst.Slot = slotNum
						break
					end
				end
			end
			return true, placed
		end
	end
	return base
end

-- ---------------------------------------------------------------------------
-- Env: load the REAL service modules and wire them together
-- ---------------------------------------------------------------------------

function H.newEnv(opts: any?): any
	opts = opts or {}
	-- R2-5: a lifecycle test may inject its own DataService (one that
	-- implements the RegisterPreSaveHook / sidecar contract); default
	-- is the plain stub, so every existing suite is unaffected.
	local dataService = opts.dataService or H.newDataService()
	local base = H.newBaseService(dataService, opts.base)
	local MutationService = require("./theft/services/MutationService")
	local FusionService = require("./theft/services/FusionService")
	local LaboratoryService = require("./theft/services/LaboratoryService")
	local CarryService = require("./theft/services/CarryService")
	-- opts.raidPath: mutant controls (theft/mutant/) load a mutated
	-- RaidService copy instead of the fixed one; default is the real
	-- service. The path is relative to this file.
	local RaidService = require(opts.raidPath or "./theft/services/RaidService")
	MutationService.Init(dataService)
	FusionService.Init(dataService, MutationService, nil)
	LaboratoryService.Init(dataService, MutationService, FusionService)
	CarryService.Init(dataService, base)
	RaidService.Init(dataService, base, CarryService, { MutationService = MutationService })
	RaidService.SetBaseService(base)
	RaidService.SetCarryService(CarryService)
	RaidService.SetMutationService(MutationService)
	-- Production wiring (GameManager wireCrossLinks): CarryService must
	-- know RaidService, or a stolen drop falls back to a world pickup
	-- instead of routing home through DropStolen.
	CarryService.SetRaidService(RaidService)
	return {
		dataService = dataService,
		base = base,
		mutation = MutationService,
		fusion = FusionService,
		lab = LaboratoryService,
		carry = CarryService,
		raid = RaidService,
		spawnCount = spawnCount,
	}
end

-- ---------------------------------------------------------------------------
-- Phase 1 Priority C extension (store tests): load the REAL BaseService
-- ---------------------------------------------------------------------------
-- H.newBaseEnv(env): loads the REAL BaseService module (copy under
-- store/services/, require-patched by store/refresh.sh — same pattern
-- as the theft/services copies: ReplicatedStorage requires become
-- ../shared/*, and the `script.Parent` MapBuilder require becomes the
-- Lune-only ./MapBuilderStub) and wires it to the env's real
-- CarryService / RaidService, re-pointing RaidService at the real base
-- (its stub base is replaced; the stub's methods read the same data
-- tables, so nothing else in the env observes a difference).
-- BaseService.Init is safe under the harness: its task.spawn loops
-- (remote wiring, income tick, idle bob) are discarded by the task
-- stub, and PlayerRemoving:Connect uses the harness signal.
-- Returns the real BaseService module. One call per test file (fresh
-- Lune process per file, so module state never leaks between files).
function H.newBaseEnv(env: any): any
	local BaseService = require("./store/services/BaseService")
	BaseService.Init(env.dataService)
	BaseService.SetCarryService(env.carry)
	BaseService.SetRaidService(env.raid)
	env.raid.SetBaseService(BaseService)
	return BaseService
end

-- Move a harness player's HumanoidRootPart (position AND CFrame, so
-- both rootPosition readers agree) — used to walk the thief between
-- the victim's pedestal (steal) and their own pedestal (delivery).
function H.setRootPosition(player: any, position: any)
	player._Root.Position = position
	player._Root.CFrame = CFrame.new(position.X, position.Y, position.Z)
end

-- Pedestal position for a plot/slot in the MapBuilderStub geometry
-- (plot i centred at (i*100, 0, 0); slot s at centre + (s*4, 0, 0)).
-- Must match store/services/MapBuilderStub.luau exactly.
function H.pedestalPosition(plotIndex: number, slot: number): any
	return Vector3.new(plotIndex * 100 + slot * 4, 0, 0)
end

-- ---------------------------------------------------------------------------
-- Fixture pair: thief + victim with a stealable evolved target
-- ---------------------------------------------------------------------------

function H.newPair(env: any, thiefId: number, victimId: number, opts: any?): any
	opts = opts or {}
	local prefix = "t" .. tostring(thiefId) .. "v" .. tostring(victimId) .. "_"
	local thief = H.newPlayer(thiefId, "Thief" .. tostring(thiefId), 30, Vector3.new(0, 0, 0))
	local victim = H.newPlayer(victimId, "Victim" .. tostring(victimId), 30, Vector3.new(0, 0, 0))
	local oldTime = os.time() - 1000 -- older than the 120s protection
	local targetId = prefix .. "target"
	local targetOwned: { [string]: any } = {
		InstanceId = targetId,
		CharacterId = "wobble_waffleton",
		Level = 5,
		Mutation = "golden",
		Glitched = true,
		Evolved = true,
		EvolutionId = "evolved_wobble_waffleton",
		EvolvedTrait = "Electric",
		EvolvedFormName = "Wobble Waffleton (Evolved)",
		TraitLevels = { Food = 2 },
		Placed = true,
		Slot = 2,
	}
	if opts.targetOverrides ~= nil then
		for k, v in pairs(opts.targetOverrides) do
			targetOwned[k] = v
		end
	end
	local fillerId = prefix .. "filler"
	local fillerOwned: { [string]: any } = {
		InstanceId = fillerId,
		CharacterId = "turbo_turnip",
		Level = 1,
		Mutation = nil,
		Placed = true,
		Slot = 1,
	}
	local thiefData: { [string]: any } = {
		Level = 5,
		Coins = 100000,
		Gems = 0,
		MutationCrystals = 1000,
		Rebirths = 0,
		Unlocked = { "wobble_waffleton", "turbo_turnip", "glitchy_goose" },
		OwnedInstances = {},
		Base = { Placed = {} },
		LabDiscoveries = {},
	}
	-- Fusion pair (recipe: wobble + turbo -> bloop_bloomington).
	table.insert(thiefData.OwnedInstances, {
		InstanceId = prefix .. "fuse_a",
		CharacterId = "wobble_waffleton",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	table.insert(thiefData.OwnedInstances, {
		InstanceId = prefix .. "fuse_b",
		CharacterId = "turbo_turnip",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	-- Positive-control instances (unplaced, never in transit).
	table.insert(thiefData.OwnedInstances, {
		InstanceId = prefix .. "evo_1",
		CharacterId = "wobble_waffleton",
		Level = 5,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	table.insert(thiefData.OwnedInstances, {
		InstanceId = prefix .. "trait_1",
		CharacterId = "turbo_turnip",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	table.insert(thiefData.OwnedInstances, {
		InstanceId = prefix .. "alt_1",
		CharacterId = "glitchy_goose",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	table.insert(thiefData.OwnedInstances, {
		InstanceId = prefix .. "carry_1",
		CharacterId = "wobble_waffleton",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	if opts.thiefExtra ~= nil then
		for _, inst in ipairs(opts.thiefExtra) do
			table.insert(thiefData.OwnedInstances, inst)
		end
	end
	local victimData: { [string]: any } = {
		Level = 5,
		Coins = 10000,
		Gems = 0,
		MutationCrystals = 100,
		Rebirths = 0,
		Unlocked = { "wobble_waffleton", "turbo_turnip" },
		OwnedInstances = { targetOwned, fillerOwned },
		Base = {
			Placed = {
				{
					InstanceId = targetId,
					CharacterId = "wobble_waffleton",
					Slot = 2,
					Level = 5,
					Glitched = true,
					Mutation = "golden",
					BankedIncome = 500,
					PlacedAt = oldTime,
				},
				{
					InstanceId = fillerId,
					CharacterId = "turbo_turnip",
					Slot = 1,
					Level = 1,
					Glitched = false,
					Mutation = nil,
					BankedIncome = 0,
					PlacedAt = oldTime,
				},
			},
		},
		LabDiscoveries = {},
	}
	if opts.victimExtraPlaced ~= nil then
		for _, placed in ipairs(opts.victimExtraPlaced) do
			table.insert(victimData.Base.Placed, placed)
		end
	end
	env.dataService.Ensure(thief, thiefData)
	env.dataService.Ensure(victim, victimData)
	return {
		thief = thief,
		victim = victim,
		thiefData = thiefData,
		victimData = victimData,
		targetId = targetId,
		targetOwned = targetOwned,
		fillerId = fillerId,
		prefix = prefix,
		oldTime = oldTime,
	}
end

-- ---------------------------------------------------------------------------
-- Lookup + counting helpers (the ownership ledger is OwnedInstances;
-- Base.Placed copies are views, not second instances)
-- ---------------------------------------------------------------------------

function H.findOwned(data: any, instanceId: string): any
	if not data or type(data.OwnedInstances) ~= "table" then
		return nil
	end
	for _, inst in ipairs(data.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == instanceId then
			return inst
		end
	end
	return nil
end

function H.findPlaced(data: any, instanceId: string): any
	if not data or type(data.Base) ~= "table" or type(data.Base.Placed) ~= "table" then
		return nil
	end
	for _, placed in ipairs(data.Base.Placed) do
		if type(placed) == "table" and placed.InstanceId == instanceId then
			return placed
		end
	end
	return nil
end

-- Count owned records with this InstanceId across the given players' data.
function H.countOwned(env: any, players: { any }, instanceId: string): number
	local n = 0
	for _, player in ipairs(players) do
		local data = env.dataService.GetData(player)
		if data and type(data.OwnedInstances) == "table" then
			for _, inst in ipairs(data.OwnedInstances) do
				if type(inst) == "table" and inst.InstanceId == instanceId then
					n += 1
				end
			end
		end
	end
	return n
end

-- Count placed copies with this InstanceId across the given players' bases.
function H.countPlaced(env: any, players: { any }, instanceId: string): number
	local n = 0
	for _, player in ipairs(players) do
		local data = env.dataService.GetData(player)
		if data and type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			for _, placed in ipairs(data.Base.Placed) do
				if type(placed) == "table" and placed.InstanceId == instanceId then
					n += 1
				end
			end
		end
	end
	return n
end

-- Steal the pair's target; errors unless the steal succeeds.
function H.steal(env: any, pair: any): string
	local ok, result = env.raid.StealBrainrot(pair.thief, pair.victim.UserId, pair.targetId)
	if not ok then
		error("steal failed: " .. tostring(result))
	end
	return result
end

-- Busy-spin the real clock (task.wait is stubbed to return at once).
function H.spinSeconds(seconds: number)
	local start = os.clock()
	while os.clock() - start < seconds do
	end
end

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------

local passed = 0
local failed: { number } = {}
local total = 0

function H.check(n: number, name: string, ok: boolean, detail: string?)
	total += 1
	if ok then
		passed += 1
		print(`PASS {string.format("%02d", n)}  {name}` .. (detail and ` -- {detail}` or ""))
	else
		table.insert(failed, n)
		print(`FAIL {string.format("%02d", n)}  {name}` .. (detail and ` -- {detail}` or ""))
	end
end

function H.finish()
	print(`\n{passed} passed, {#failed} failed (of {total})`)
	if #failed > 0 then
		error(`FAILED checks: {table.concat(failed, ", ")}`)
	end
end

return H
