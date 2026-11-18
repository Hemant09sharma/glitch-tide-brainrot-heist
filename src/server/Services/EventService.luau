--!strict
-- EventService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Modular rotating world-event scheduler. Every event is a data entry
-- {Id, Name, Duration, Cooldown, Start(), End()} and every Start()
-- applies a REAL effect — an income multiplier, a mutation-cost
-- multiplier, spawned meteors / NPCs, a merchant flag, or a tracked KO
-- challenge — never just an announcement.
--
-- Events (all 6 fully working):
--   Golden Hour      2x income for 120s (GetIncomeMultiplier).
--   Mutation Storm   mutation costs halved + glitch chance up, 120s.
--   Meteor Shower    Meteor tide via TideService (or own meteor drops
--                    when TideService is absent) + Chaos Shards, 120s.
--   Secret Merchant  rare-stock market boost flag for 120s (no NPC
--                    model while NPCService is absent — see report).
--   Glitch Invasion  NPC wave in the Chaos Arena, 180s.
--   Chaos Arena      timed KO challenge, 120s; most KOs wins, every
--                    participant with >= 1 KO is paid.
--
-- OPTIONAL DEPENDENCIES: TideService (Init arg, may be nil),
-- NPCService (optional 3rd Init arg or SetNPCService), QuestService
-- (optional 4th Init arg, for challenge / invasion quest events).
-- Without NPCService, Glitch Invasion spawns its own minimal enemy
-- models (parts + Humanoid) instead of doing nothing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local EventService = {}

local _dataService: any = nil
local _tideService: any = nil
local _npcService: any = nil
local _questService: any = nil
local _progressionService: any = nil

local _activeEvent: string? = nil
local _activeUntil: number = 0
local _incomeMultiplier: number = 1
local _mutationCostMultiplier: number = 1
local _glitchChanceBonus: number = 0
local _merchantActive: boolean = false
-- [player] = KOs scored during the active Chaos Arena challenge.
local _challengeKOs: { [Player]: number } = {}
local _lastEventId: string? = nil
local _running: boolean = false

local function getRemote(name: string): RemoteEvent?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

local function getFunction(name: string): RemoteFunction?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetFunction(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteFunction") then
		return remote :: RemoteFunction
	end
	return nil
end

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

-- XP through ProgressionService when linked (level-up rewards), else
-- the raw DataService add. DataService.AddXP alone never levels up.
local function addXP(player: Player, amount: number)
	if _progressionService and type(_progressionService.AddXP) == "function" then
		pcall(function()
			_progressionService.AddXP(player, amount)
		end)
	else
		pcall(function()
			_dataService.AddXP(player, amount)
		end)
	end
end

local function getData(player: Player): any
	if not _dataService then
		return nil
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

local function announce(eventId: string, name: string, phase: string, duration: number)
	local eventName = _names.EventUpdate or _names.RoundUpdate
	fireAll(eventName, {
		EventId = eventId,
		Name = name,
		Phase = phase, -- "Started" | "Ended"
		Duration = duration,
		IncomeMultiplier = _incomeMultiplier,
	})
end

local function arenaCenter(): Vector3
	local arena = workspace:FindFirstChild("ChaosArena") or workspace:FindFirstChild("Arena")
	if arena and arena:IsA("BasePart") then
		return arena.Position
	end
	return Vector3.new(0, 5, 0)
end

-- Minimal fallback enemy (used only when NPCService is absent): a
-- coloured block body + Humanoid that wanders the arena and damages on
-- touch. Kept deliberately simple; NPCService is the real spawner.
local function spawnFallbackEnemy(position: Vector3): Model?
	local defs = Characters.GetAll()
	local def = defs[math.random(1, #defs)]
	local model = Instance.new("Model")
	model.Name = "Invasion_" .. def.DisplayName
	model:SetAttribute("NPCType", "Enemy")
	model:SetAttribute("Damage", def.Damage or 10)
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = false
	root.CanCollide = true
	root.Position = position
	root.Parent = model
	model.PrimaryPart = root
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(3, 3, 2)
	body.Color = def.Color
	body.Material = Enum.Material.SmoothPlastic
	body.Parent = model
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = body
	weld.Parent = root
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = 80
	humanoid.MaxHealth = 80
	humanoid.WalkSpeed = def.Speed or 14
	humanoid.Parent = model
	local tag = Instance.new("BoolValue")
	tag.Name = "IsNPC"
	tag.Parent = model
	model.Parent = workspace
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "NPCs"
		folder.Parent = workspace
	end
	model.Parent = folder
	-- Death reward: same as NPCService.HandleNPCDeath (25 coins + 20 XP
	-- + defeat_npc quest event) for the killer (Creator tag, stamped by
	-- CombatService). v1.0.0 had no Died handler here at all, so killing
	-- a fallback invasion enemy paid nothing and advanced no quest.
	humanoid.Died:Connect(function()
		local creator = model:FindFirstChild("Creator")
		local killer: Player? = nil
		if creator and creator:IsA("ObjectValue") and creator.Value and creator.Value:IsA("Player") then
			killer = creator.Value
		end
		if killer then
			pcall(function()
				_dataService.AddCoins(killer, 25)
			end)
			addXP(killer, 20)
			if _questService and type(_questService.RecordEvent) == "function" then
				pcall(function()
					_questService.RecordEvent(killer, "defeat_npc", 1)
				end)
			end
		end
		task.delay(1.5, function()
			if model.Parent then
				model:Destroy()
			end
		end)
	end)
	-- Wander: pick random nearby points until the model dies.
	task.spawn(function()
		while model.Parent and humanoid.Health > 0 do
			local target = position + Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
			pcall(function()
				humanoid:MoveTo(target)
			end)
			task.wait(3)
		end
	end)
	Debris:AddItem(model, 200)
	return model
end

local function spawnMeteorAt(position: Vector3)
	local meteor = Instance.new("Part")
	meteor.Name = "EventMeteor"
	meteor.Shape = Enum.PartType.Ball
	meteor.Size = Vector3.new(3, 3, 3)
	meteor.Material = Enum.Material.Neon
	meteor.Color = Color3.fromRGB(255, 90, 40)
	meteor.Anchored = false
	meteor.CanCollide = true
	meteor.Position = position + Vector3.new(0, 60, 0)
	meteor.Parent = workspace
	Debris:AddItem(meteor, 10)
	local touched: { [Humanoid]: boolean } = {}
	meteor.Touched:Connect(function(hit)
		local model = hit:FindFirstAncestorOfClass("Model")
		if not model then
			return
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or touched[humanoid] then
			return
		end
		touched[humanoid] = true
		pcall(function()
			humanoid:TakeDamage(20)
		end)
	end)
end

-- ---------------------------------------------------------------------------
-- Event definitions. Each Start() applies a real effect; each End()
-- reverts it. No event is announcement-only.
-- ---------------------------------------------------------------------------

type EventDef = {
	Id: string,
	Name: string,
	Duration: number,
	Cooldown: number,
	Start: () -> (),
	End: () -> (),
}

local EVENTS: { EventDef } = {}

EVENTS = {
	{
		Id = "golden_hour",
		Name = "Golden Hour",
		Duration = 120,
		Cooldown = 300,
		Start = function()
			_incomeMultiplier = 2
		end,
		End = function()
			_incomeMultiplier = 1
		end,
	},
	{
		Id = "mutation_storm",
		Name = "Mutation Storm",
		Duration = 120,
		Cooldown = 300,
		Start = function()
			_mutationCostMultiplier = 0.5
			_glitchChanceBonus = 0.35
		end,
		End = function()
			_mutationCostMultiplier = 1
			_glitchChanceBonus = 0
		end,
	},
	{
		Id = "meteor_shower",
		Name = "Meteor Shower",
		Duration = 120,
		Cooldown = 420,
		Start = function()
			-- Prefer a real Meteor tide; without TideService — or when
			-- a tide is already running and ForceStart refuses — drop
			-- meteors directly over the arena for 60s instead. v1.0.0
			-- did nothing at all when ForceStart returned false.
			local startedTide = false
			if _tideService and type(_tideService.ForceStart) == "function" then
				pcall(function()
					startedTide = _tideService.ForceStart("Meteor") == true
				end)
			end
			if not startedTide then
				task.spawn(function()
					local center = arenaCenter()
					for _ = 1, 30 do
						spawnMeteorAt(center + Vector3.new(math.random(-40, 40), 0, math.random(-40, 40)))
						task.wait(2)
					end
				end)
			end
			-- Everyone online when the shower starts gets Chaos Shards.
			for _, player in ipairs(Players:GetPlayers()) do
				local data = getData(player)
				if data then
					data.ChaosShards = (tonumber(data.ChaosShards) or 0) + 2
				end
			end
		end,
		End = function() end,
	},
	{
		Id = "secret_merchant",
		Name = "Secret Merchant",
		Duration = 120,
		Cooldown = 420,
		Start = function()
			-- Real effect: the merchant flag doubles conveyor luck /
			-- rare stock while active. ConveyorService reads
			-- IsMerchantActive(); when NPCService is linked, it also
			-- spawns a vendor NPC (see SetNPCService note in report).
			_merchantActive = true
			if _npcService and type(_npcService.SpawnVendor) == "function" then
				pcall(function()
					_npcService.SpawnVendor(arenaCenter() + Vector3.new(10, 0, 0))
				end)
			end
		end,
		End = function()
			_merchantActive = false
		end,
	},
	{
		Id = "glitch_invasion",
		Name = "Glitch Invasion",
		Duration = 180,
		Cooldown = 420,
		Start = function()
			-- A real NPC wave in the Chaos Arena: 4 wild Brainrots.
			local center = arenaCenter()
			for i = 1, 4 do
				local pos = center + Vector3.new(math.random(-15, 15), 3, math.random(-15, 15))
				local spawned = false
				if _npcService and type(_npcService.SpawnEnemy) == "function" then
					pcall(function()
						spawned = _npcService.SpawnEnemy(nil, pos, { Health = 120, Damage = 12 }) ~= nil
					end)
				end
				-- NPCService caps AI NPCs at 6: when it refuses (or is
				-- absent), the fallback spawner keeps the invasion real
				-- instead of silently spawning fewer enemies.
				if not spawned then
					spawnFallbackEnemy(pos)
				end
				task.wait(0.5)
			end
		end,
		End = function() end,
	},
	{
		Id = "chaos_arena",
		Name = "Chaos Arena Challenge",
		Duration = 120,
		Cooldown = 300,
		Start = function()
			_challengeKOs = {}
		end,
		End = function()
			-- Most KOs wins 200 coins + 10 gems; every participant
			-- with >= 1 KO gets 5 Event Tokens.
			local best: Player? = nil
			local bestKOs = 0
			for player, kos in pairs(_challengeKOs) do
				if kos > bestKOs then
					best = player
					bestKOs = kos
				end
			end
			for player, kos in pairs(_challengeKOs) do
				if kos >= 1 and player.Parent then
					local data = getData(player)
					if data then
						data.EventTokens = (tonumber(data.EventTokens) or 0) + 5
						if player == best then
							pcall(function()
								_dataService.AddCoins(player, 200)
							end)
							data.Gems = (tonumber(data.Gems) or 0) + 10
						end
						fireClient(_names.PlayerStats, player, {
							Coins = data.Coins,
							Gems = data.Gems,
							EventTokens = data.EventTokens,
							ChallengeKOs = kos,
							ChallengeWinner = player == best,
						})
					end
				end
			end
			if best then
				print(string.format(
					"[EventService] Chaos Arena winner: %s (%d KOs)",
					best.Name, bestKOs
				))
			end
			_challengeKOs = {}
		end,
	},
}

local _byId: { [string]: EventDef } = {}
for _, event in ipairs(EVENTS) do
	_byId[event.Id] = event
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function EventService.GetActiveEvent(): { Id: string?, Name: string?, EndsIn: number }
	if not _activeEvent then
		return { Id = nil, Name = nil, EndsIn = 0 }
	end
	local def = _byId[_activeEvent]
	return {
		Id = _activeEvent,
		Name = def and def.Name or _activeEvent,
		EndsIn = math.max(0, math.floor(_activeUntil - os.clock())),
	}
end

function EventService.GetIncomeMultiplier(): number
	return _incomeMultiplier
end

function EventService.IsMutationStormActive(): boolean
	return _mutationCostMultiplier < 1
end

function EventService.GetMutationCostMultiplier(): number
	return _mutationCostMultiplier
end

function EventService.GetGlitchChanceBonus(): number
	return _glitchChanceBonus
end

function EventService.IsMerchantActive(): boolean
	return _merchantActive
end

-- RecordKO(player): CombatService / GameManager call this on every KO so
-- the Chaos Arena challenge can be scored.
function EventService.RecordKO(player: Player)
	if not player or not player:IsA("Player") then
		return
	end
	if _activeEvent ~= "chaos_arena" then
		return
	end
	_challengeKOs[player] = (_challengeKOs[player] or 0) + 1
end

function EventService.SetNPCService(npcService: any)
	if npcService and type(npcService.SpawnEnemy) == "function" then
		_npcService = npcService
	end
end

-- SetTideService(tideService): setter injection so Meteor Shower can
-- trigger a real Meteor tide (GameManager's tryWire does not call this
-- today; without it the event falls back to its own meteor drops).
function EventService.SetTideService(tideService: any)
	if tideService and type(tideService.ForceStart) == "function" then
		_tideService = tideService
	end
end

function EventService.SetQuestService(questService: any)
	_questService = questService
end

function EventService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

-- ForceEvent(eventId): start an event immediately (testing / boss hooks).
-- Returns false when the id is unknown or an event is already active.
function EventService.ForceEvent(eventId: string): boolean
	local def = _byId[eventId]
	if not def then
		warn("[EventService] ForceEvent: unknown event " .. tostring(eventId))
		return false
	end
	if _activeEvent then
		warn("[EventService] ForceEvent ignored: " .. tostring(_activeEvent) .. " is active")
		return false
	end
	task.spawn(function()
		EventService.RunEvent(def)
	end)
	return true
end

function EventService.RunEvent(def: EventDef)
	_activeEvent = def.Id
	_activeUntil = os.clock() + def.Duration
	_lastEventId = def.Id
	print(string.format("[EventService] Event started: %s (%ds)", def.Name, def.Duration))
	announce(def.Id, def.Name, "Started", def.Duration)
	local ok, err = pcall(function()
		def.Start()
	end)
	if not ok then
		warn("[EventService] Event Start failed (" .. def.Id .. "): " .. tostring(err))
	end
	task.wait(def.Duration)
	local ok2, err2 = pcall(function()
		def.End()
	end)
	if not ok2 then
		warn("[EventService] Event End failed (" .. def.Id .. "): " .. tostring(err2))
	end
	_activeEvent = nil
	_incomeMultiplier = 1
	_mutationCostMultiplier = 1
	_glitchChanceBonus = 0
	_merchantActive = false
	announce(def.Id, def.Name, "Ended", 0)
	print(string.format("[EventService] Event ended: %s", def.Name))
end

function EventService.Init(dataService: any, tideService: any?, npcService: any?, questService: any?)
	assert(dataService ~= nil, "[EventService] Init requires DataService")
	_dataService = dataService
	-- GameManager's generic Init passes (dataService, economyService,
	-- map) positionally; only accept arguments that actually implement
	-- the expected interface, otherwise fall back to the built-in
	-- meteor drops / fallback enemy spawner.
	if tideService and type(tideService.ForceStart) == "function" then
		_tideService = tideService
	else
		_tideService = nil
	end
	if npcService and type(npcService.SpawnEnemy) == "function" then
		_npcService = npcService
	else
		_npcService = nil
	end
	_questService = questService
	_running = true

	-- RequestEvents (RemoteFunction): the active-event pull path.
	-- v1.0.1 integration QA — GetActiveEvent existed but no handler
	-- did, so InvokeServer errored. Returns {Id, Name, EndsIn}.
	local eventsFnName = _names.RequestEvents or "RequestEvents"
	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction(eventsFnName)
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(_player: Player)
				return EventService.GetActiveEvent()
			end
		else
			warn("[EventService] RemoteFunction not found, RequestEvents not wired: " .. tostring(eventsFnName))
		end
	end)

	-- Scheduler: rotate events with a 150-240s gap between them, never
	-- repeating the event that just ran.
	task.spawn(function()
		task.wait(60) -- let the server settle before the first event
		while _running do
			local pool: { EventDef } = {}
			for _, event in ipairs(EVENTS) do
				if event.Id ~= _lastEventId then
					table.insert(pool, event)
				end
			end
			local def = pool[math.random(1, #pool)]
			local ok, err = pcall(function()
				EventService.RunEvent(def)
			end)
			if not ok then
				warn("[EventService] Event run failed: " .. tostring(err))
				_activeEvent = nil
			end
			task.wait(math.random(150, 240))
		end
	end)
end

return EventService
