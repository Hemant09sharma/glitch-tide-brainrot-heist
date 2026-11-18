--!strict
-- NPCService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- NPCs, built entirely from Parts (no external asset ids):
--   vendor      market NPC; proximity prompt -> dialogue via the
--               NPCDialogue remote (falls back to RequestCharacter).
--   quest-giver plaza NPC; hands out quest hints from QuestService.
--   guard       patrols a base plot, chases non-owner players within
--               20 studs of the base, attacks in range. PathfindingService
--               with a direct-walk fallback.
--   enemy       wild Brainrots (Forbidden Rift / Chaos Arena) with a
--               Wander -> Chase -> Attack -> Flee (low HP) state machine.
--
-- PERFORMANCE: one RunService.Heartbeat loop drives all AI; each NPC
-- ticks once per second, staggered by index, so the per-frame cost is
-- ~1 NPC step. At most 6 AI-ticked NPCs are active at once (vendors and
-- the quest-giver are stationary interactives and do not consume the
-- AI budget). Damage goes through CombatService.NPCAttack when linked,
-- else direct Humanoid damage with a server-side damage value (never a
-- client-supplied one).
--
-- OPTIONAL DEPENDENCIES: Init(map, combatService?, questService?,
-- raidService?) — every extra argument is optional and nil-safe.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local NPCService = {}

local _map: Instance? = nil
local _dataService: any = nil
local _combatService: any = nil
local _questService: any = nil
local _raidService: any = nil
local _progressionService: any = nil
-- [ownerUserId .. ":" .. thiefUserId] = os.clock() of last counted defense.
local _defenseCooldowns: { [string]: number } = {}

local MAX_AI_NPCS = 6
local GUARD_CHASE_RANGE = 20
local GUARD_ATTACK_RANGE = 4
local ENEMY_CHASE_RANGE = 25
local ENEMY_ATTACK_RANGE = 5
local FLEE_HP_FRACTION = 0.25

type NPCRecord = {
	Model: Model,
	Kind: string, -- "Vendor" | "QuestGiver" | "Guard" | "Enemy"
	Humanoid: Humanoid,
	Home: Vector3,
	Owner: Player?,
	PatrolIndex: number,
	State: string,
	NextTick: number,
	LastAttackAt: number,
	Target: Model?,
	FleeUntil: number,
	FleeCooldown: number, -- os.clock() before which the enemy may not flee again
	PatrolPoints: { Vector3 },
	Path: { Vector3 }?,
	PathIndex: number,
	PathTarget: Vector3?,
	LastPathRequest: number,
}

local _npcs: { NPCRecord } = {}
local _folder: Folder? = nil

local function getFolder(): Folder
	if _folder and _folder.Parent then
		return _folder
	end
	local existing = workspace:FindFirstChild("NPCs")
	if existing and existing:IsA("Folder") then
		_folder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "NPCs"
	folder.Parent = workspace
	_folder = folder
	return folder
end

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

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

-- Build a simple humanoid-shaped NPC from parts: HumanoidRootPart +
-- welded Torso + Head + coloured body block. No assets, no rigs.
local function buildModel(name: string, bodyColor: Color3, position: Vector3, health: number, walkSpeed: number): (Model, Humanoid)
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Position = position
	root.CanCollide = true
	root.Parent = model
	model.PrimaryPart = root
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = bodyColor
	torso.Position = position
	torso.Parent = model
	local torsoWeld = Instance.new("Weld")
	torsoWeld.Part0 = root
	torsoWeld.Part1 = torso
	torsoWeld.Parent = root
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.4, 1.4, 1.4)
	head.Color = bodyColor
	head.Position = position + Vector3.new(0, 2, 0)
	head.Parent = model
	local headWeld = Instance.new("Weld")
	headWeld.Part0 = torso
	headWeld.Part1 = head
	headWeld.C0 = CFrame.new(0, 1.5, 0)
	headWeld.Parent = torso
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = health
	humanoid.MaxHealth = health
	humanoid.WalkSpeed = walkSpeed
	humanoid.Parent = model
	local tag = Instance.new("BoolValue")
	tag.Name = "IsNPC"
	tag.Parent = model
	return model, humanoid
end

local function addRecord(record: NPCRecord)
	table.insert(_npcs, record)
	record.Model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			for index, entry in ipairs(_npcs) do
				if entry == record then
					table.remove(_npcs, index)
					break
				end
			end
		end
	end)
	record.Humanoid.Died:Connect(function()
		NPCService.HandleNPCDeath(record)
	end)
end

-- Pathfinding is computed asynchronously (never inside the Heartbeat
-- tick): requestPath spawns the ComputeAsync and stores the waypoint
-- list; moveTo only ever issues a fire-and-forget Humanoid:MoveTo
-- toward the current waypoint (or straight at the target when there is
-- no path), so the single Heartbeat loop can never block on a wait.
local function requestPath(record: NPCRecord, target: Vector3)
	local now = os.clock()
	if now - record.LastPathRequest < 2 then
		return
	end
	if record.PathTarget and (record.PathTarget - target).Magnitude < 4 and record.Path then
		return -- current path still aims at (nearly) this target
	end
	record.LastPathRequest = now
	record.PathTarget = target
	task.spawn(function()
		local from = record.Model:GetPivot().Position
		local path: Path? = nil
		local ok = pcall(function()
			path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 4,
				AgentCanJump = true,
			})
			;(path :: Path):ComputeAsync(from, target)
		end)
		if ok and path and path.Status == Enum.PathStatus.Success then
			local points: { Vector3 } = {}
			for _, waypoint in ipairs(path:GetWaypoints()) do
				table.insert(points, waypoint.Position)
			end
			if record.Model.Parent then
				record.Path = points
				record.PathIndex = 1
			end
		else
			-- Fallback: no path, walk directly at the target.
			record.Path = nil
		end
	end)
end

local function moveTo(record: NPCRecord, target: Vector3)
	local humanoid = record.Humanoid
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	requestPath(record, target)
	local path = record.Path
	if path and record.PathIndex <= #path then
		local waypoint = path[record.PathIndex]
		local pos = record.Model:GetPivot().Position
		if (waypoint - pos).Magnitude < 3 then
			record.PathIndex += 1
			if record.PathIndex > #path then
				humanoid:MoveTo(target)
			end
		else
			humanoid:MoveTo(waypoint)
		end
	else
		humanoid:MoveTo(target)
	end
end

local function nearestPlayer(position: Vector3, maxDist: number, excludeOwner: Player?): (Player?, Vector3?)
	local best: Player? = nil
	local bestDist = maxDist + 1
	local bestPos: Vector3? = nil
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= excludeOwner and player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				local dist = (root.Position - position).Magnitude
				if dist < bestDist then
					best = player
					bestDist = dist
					bestPos = root.Position
				end
			end
		end
	end
	return best, bestPos
end

local function attackTarget(record: NPCRecord, targetModel: Model)
	local now = os.clock()
	if now - record.LastAttackAt < 1 then
		return
	end
	record.LastAttackAt = now
	if _combatService and type(_combatService.NPCAttack) == "function" then
		pcall(function()
			_combatService.NPCAttack(record.Model, targetModel)
		end)
	else
		local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
		if targetHumanoid and targetHumanoid.Health > 0 then
			local damage = record.Model:GetAttribute("Damage") or 10
			pcall(function()
				targetHumanoid:TakeDamage(tonumber(damage) or 10)
			end)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

-- SpawnVendor(position): stationary market NPC with a proximity prompt.
-- Triggered -> dialogue lines + shop hint via NPCDialogue (or the
-- closest existing remote, RequestCharacter, when it is absent).
function NPCService.SpawnVendor(position: Vector3): Model?
	local model, humanoid = buildModel("Vendor", Color3.fromRGB(255, 215, 90), position, 200, 0)
	model:SetAttribute("NPCType", "Vendor")
	humanoid.WalkSpeed = 0
	model.Parent = getFolder()
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Talk to Merchant"
	prompt.ObjectText = "Secret Merchant"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.Parent = model.PrimaryPart
	prompt.Triggered:Connect(function(player)
		local dialogueName = _names.NPCDialogue or _names.RequestCharacter
		fireClient(dialogueName, player, {
			NPC = "Vendor",
			Lines = {
				"Psst. Rare stock today — glitched Brainrots, half the usual fuss.",
				"Mutation Crystals? I take coins. The tide provides the rest.",
				"Come back when the next tide rolls in. I only sell to survivors.",
			},
			Hint = "Rare stock is boosted while the Secret Merchant event is active.",
		})
	end)
	addRecord({
		Model = model,
		Kind = "Vendor",
		Humanoid = humanoid,
		Home = position,
		Owner = nil,
		PatrolIndex = 1,
		State = "Idle",
		NextTick = math.huge, -- stationary: never AI-ticked
		LastAttackAt = 0,
		Target = nil,
		FleeUntil = 0,
		FleeCooldown = 0,
		PatrolPoints = {},
		Path = nil,
		PathIndex = 1,
		PathTarget = nil,
		LastPathRequest = 0,
	})
	return model
end

-- SpawnQuestGiver(position): plaza NPC; dialogue lists current quests.
function NPCService.SpawnQuestGiver(position: Vector3): Model?
	local model, humanoid = buildModel("QuestGiver", Color3.fromRGB(140, 200, 255), position, 200, 0)
	model:SetAttribute("NPCType", "QuestGiver")
	humanoid.WalkSpeed = 0
	model.Parent = getFolder()
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Ask about quests"
	prompt.ObjectText = "Quest Giver"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.Parent = model.PrimaryPart
	prompt.Triggered:Connect(function(player)
		local lines: { string } = {
			"The Memeverse rewards the bold. Check your quest list — I track them all.",
		}
		if _questService and type(_questService.GetQuests) == "function" then
			local ok, quests = pcall(function()
				return _questService.GetQuests(player)
			end)
			if ok and type(quests) == "table" then
				for _, quest in ipairs(quests) do
					if type(quest) == "table" and quest.Claimed ~= true then
						table.insert(lines, string.format(
							"%s: %d/%d — %s",
							tostring(quest.Name), tonumber(quest.Progress) or 0, tonumber(quest.Goal) or 0, tostring(quest.Description)
						))
					end
				end
			end
		else
			table.insert(lines, "Buy a Brainrot, place it in your base, and survive a tide. That is where every legend starts.")
		end
		local dialogueName = _names.NPCDialogue or _names.RequestCharacter
		fireClient(dialogueName, player, {
			NPC = "QuestGiver",
			Lines = lines,
		})
	end)
	addRecord({
		Model = model,
		Kind = "QuestGiver",
		Humanoid = humanoid,
		Home = position,
		Owner = nil,
		PatrolIndex = 1,
		State = "Idle",
		NextTick = math.huge,
		LastAttackAt = 0,
		Target = nil,
		FleeUntil = 0,
		FleeCooldown = 0,
		PatrolPoints = {},
		Path = nil,
		PathIndex = 1,
		PathTarget = nil,
		LastPathRequest = 0,
	})
	return model
end

-- SpawnGuard(owner, basePosition): patrols 4 points around the base,
-- chases non-owner players within 20 studs, attacks in range. Counts
-- toward the 6-NPC AI cap; returns nil when the cap is reached.
function NPCService.SpawnGuard(owner: Player, basePosition: Vector3): Model?
	local aiCount = 0
	for _, record in ipairs(_npcs) do
		if record.Kind == "Guard" or record.Kind == "Enemy" then
			aiCount += 1
		end
	end
	if aiCount >= MAX_AI_NPCS then
		warn("[NPCService] AI NPC cap reached (6); guard not spawned")
		return nil
	end
	local model, humanoid = buildModel("Guard_" .. owner.Name, Color3.fromRGB(90, 140, 230), basePosition, 250, 14)
	model:SetAttribute("NPCType", "Guard")
	model:SetAttribute("Damage", 12)
	model:SetAttribute("OwnerUserId", owner.UserId)
	model.Parent = getFolder()
	local patrol: { Vector3 } = {}
	for angle = 0, 270, 90 do
		local rad = math.rad(angle)
		table.insert(patrol, basePosition + Vector3.new(math.cos(rad) * 10, 0, math.sin(rad) * 10))
	end
	local record: NPCRecord = {
		Model = model,
		Kind = "Guard",
		Humanoid = humanoid,
		Home = basePosition,
		Owner = owner,
		PatrolIndex = 1,
		State = "Patrol",
		NextTick = os.clock() + math.random() * 0.5,
		LastAttackAt = 0,
		Target = nil,
		FleeUntil = 0,
		FleeCooldown = 0,
		PatrolPoints = patrol,
		Path = nil,
		PathIndex = 1,
		PathTarget = nil,
		LastPathRequest = 0,
	}
	addRecord(record)
	if _raidService and type(_raidService.RegisterGuard) == "function" then
		pcall(function()
			_raidService.RegisterGuard(owner, model)
		end)
	end
	return model
end

-- SpawnEnemy(characterId?, position, opts?): wild Brainrot enemy.
-- opts: {Health, Damage, Scale}. Returns nil at the AI cap.
function NPCService.SpawnEnemy(characterId: any, position: Vector3, opts: any?): Model?
	local aiCount = 0
	for _, record in ipairs(_npcs) do
		if record.Kind == "Guard" or record.Kind == "Enemy" then
			aiCount += 1
		end
	end
	if aiCount >= MAX_AI_NPCS then
		warn("[NPCService] AI NPC cap reached (6); enemy not spawned")
		return nil
	end
	local def = nil
	if type(characterId) == "string" then
		def = Characters.GetById(characterId)
	end
	if not def then
		local all = Characters.GetAll()
		def = all[math.random(1, #all)]
	end
	local health = 80
	local damage = def.Damage or 10
	local speed = def.Speed or 14
	if type(opts) == "table" then
		health = tonumber(opts.Health) or health
		damage = tonumber(opts.Damage) or damage
		speed = tonumber(opts.Speed) or speed
	end
	local model, humanoid = buildModel("Wild_" .. def.DisplayName, def.Color, position, health, speed)
	model:SetAttribute("NPCType", "Enemy")
	model:SetAttribute("CharacterId", def.Id)
	model:SetAttribute("Damage", damage)
	model.Parent = getFolder()
	addRecord({
		Model = model,
		Kind = "Enemy",
		Humanoid = humanoid,
		Home = position,
		Owner = nil,
		PatrolIndex = 1,
		State = "Wander",
		NextTick = os.clock() + math.random() * 0.5,
		LastAttackAt = 0,
		Target = nil,
		FleeUntil = 0,
		FleeCooldown = 0,
		PatrolPoints = {},
		Path = nil,
		PathIndex = 1,
		PathTarget = nil,
		LastPathRequest = 0,
	})
	return model
end

-- ---------------------------------------------------------------------------
-- Death / rewards
-- ---------------------------------------------------------------------------

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

-- HandleNPCDeath(record): KO reward to the killer (Creator tag), quest
-- event, corpse cleanup. Guards / vendors do not pay rewards.
function NPCService.HandleNPCDeath(record: NPCRecord)
	local model = record.Model
	if record.Kind ~= "Enemy" then
		task.delay(2, function()
			if model.Parent then
				model:Destroy()
			end
		end)
		return
	end
	local creator = model:FindFirstChild("Creator")
	local killer: Player? = nil
	if creator and creator:IsA("ObjectValue") and creator.Value and creator.Value:IsA("Player") then
		killer = creator.Value
	end
	if killer then
		-- Coin + XP reward to the killer (server-side flat values).
		if _dataService then
			pcall(function()
				_dataService.AddCoins(killer, 25)
			end)
			addXP(killer, 20)
		end
		if _questService and type(_questService.RecordEvent) == "function" then
			pcall(function()
				_questService.RecordEvent(killer, "defeat_npc", 1)
			end)
		end
		local effectName = _names.SpawnEffect
		local remote = getRemote(effectName)
		if remote then
			pcall(function()
				remote:FireAllClients({
					type = "NPCDefeated",
					player = killer.Name,
					characterId = model:GetAttribute("CharacterId"),
					position = model:GetPivot().Position,
				})
			end)
		end
	end
	task.delay(1.5, function()
		if model.Parent then
			pcall(function()
				model:BreakJoints()
			end)
			task.delay(3, function()
				if model.Parent then
					model:Destroy()
				end
			end)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- AI tick (one Heartbeat loop, staggered 1s ticks per NPC).
-- ---------------------------------------------------------------------------

local function tickGuard(record: NPCRecord, now: number)
	local pos = record.Model:GetPivot().Position
	-- Chase: any non-owner player within 20 studs of the base home.
	local intruder, intruderPos = nearestPlayer(record.Home, GUARD_CHASE_RANGE, record.Owner)
	if intruder and intruderPos and intruder.Character then
		record.State = "Chase"
		local dist = (intruderPos - pos).Magnitude
		if dist <= GUARD_ATTACK_RANGE then
			record.State = "Attack"
			attackTarget(record, intruder.Character)
			-- A guard that hits a thief counts as a defense for the
			-- owner — but only once per intruder per 60s. v1.0.0
			-- recorded a defense on EVERY attack tick (~1/s), so one
			-- guard farming one thief completed the defense quest
			-- many times over and spammed quest progress.
			if record.Owner and _raidService and type(_raidService.RecordDefense) == "function" then
				local key = tostring(record.Owner.UserId) .. ":" .. tostring(intruder.UserId)
				local last = _defenseCooldowns[key] or -math.huge
				if now - last >= 60 then
					_defenseCooldowns[key] = now
					pcall(function()
						_raidService.RecordDefense(record.Owner)
					end)
				end
			end
		else
			moveTo(record, intruderPos)
		end
		return
	end
	-- Patrol: walk the 4 base waypoints in turn.
	record.State = "Patrol"
	local point = record.PatrolPoints[record.PatrolIndex]
	if point then
		if (point - pos).Magnitude < 3 then
			record.PatrolIndex = record.PatrolIndex % #record.PatrolPoints + 1
		else
			moveTo(record, point)
		end
	end
end

local function tickEnemy(record: NPCRecord, now: number)
	local humanoid = record.Humanoid
	local pos = record.Model:GetPivot().Position
	-- Flee at low HP: run away from the nearest player for 3s, at most
	-- once per 10s. v1.0.0 re-armed FleeUntil on every tick while HP
	-- stayed low, so a wounded enemy fled forever and never fought back.
	if humanoid.Health <= humanoid.MaxHealth * FLEE_HP_FRACTION and now < record.FleeUntil then
		record.State = "Flee"
		local player, playerPos = nearestPlayer(pos, ENEMY_CHASE_RANGE, nil)
		if player and playerPos then
			local away = pos - playerPos
			away = Vector3.new(away.X, 0, away.Z)
			if away.Magnitude < 0.01 then
				away = Vector3.new(0, 0, 1)
			end
			moveTo(record, pos + away.Unit * 15)
		end
		return
	end
	if humanoid.Health <= humanoid.MaxHealth * FLEE_HP_FRACTION and now >= record.FleeCooldown then
		record.FleeUntil = now + 3
		record.FleeCooldown = now + 10
	end
	-- Chase / Attack the nearest player in range.
	local player, playerPos = nearestPlayer(pos, ENEMY_CHASE_RANGE, nil)
	if player and playerPos and player.Character then
		local dist = (playerPos - pos).Magnitude
		if dist <= ENEMY_ATTACK_RANGE then
			record.State = "Attack"
			attackTarget(record, player.Character)
		else
			record.State = "Chase"
			moveTo(record, playerPos)
		end
		return
	end
	-- Wander: drift to a random point near home.
	record.State = "Wander"
	local target = record.Home + Vector3.new(math.random(-12, 12), 0, math.random(-12, 12))
	moveTo(record, target)
end

local function heartbeat()
	local now = os.clock()
	for _, record in ipairs(_npcs) do
		if record.NextTick ~= math.huge and now >= record.NextTick then
			-- Stagger: next tick 1s out, plus a small per-NPC offset so
			-- all NPCs never tick on the same frame.
			record.NextTick = now + 1
			if record.Humanoid.Health > 0 and record.Model.Parent then
				local ok, err = pcall(function()
					if record.Kind == "Guard" then
						tickGuard(record, now)
					elseif record.Kind == "Enemy" then
						tickEnemy(record, now)
					end
				end)
				if not ok then
					warn("[NPCService] AI tick failed (" .. record.Kind .. "): " .. tostring(err))
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function NPCService.GetNPCs(): { Model }
	local out: { Model } = {}
	for _, record in ipairs(_npcs) do
		if record.Model.Parent then
			table.insert(out, record.Model)
		end
	end
	return out
end

function NPCService.GetActiveCount(): number
	local count = 0
	for _, record in ipairs(_npcs) do
		if (record.Kind == "Guard" or record.Kind == "Enemy") and record.Model.Parent then
			count += 1
		end
	end
	return count
end

function NPCService.DespawnAll()
	for _, record in ipairs(_npcs) do
		if record.Model.Parent then
			record.Model:Destroy()
		end
	end
	_npcs = {}
end

function NPCService.SetDataService(dataService: any)
	_dataService = dataService
end

function NPCService.SetCombatService(combatService: any)
	_combatService = combatService
end

function NPCService.SetQuestService(questService: any)
	_questService = questService
end

function NPCService.SetRaidService(raidService: any)
	_raidService = raidService
end

function NPCService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function NPCService.Init(map: Instance?, combatService: any?, questService: any?, raidService: any?)
	-- GameManager's generic Init passes (dataService, economyService,
	-- map) positionally, so sniff each argument by capability instead
	-- of trusting its position.
	local args: { any } = { map, combatService, questService, raidService }
	for _, arg in ipairs(args) do
		if type(arg) == "table" then
			if _dataService == nil and type(arg.GetOrLoad) == "function" then
				_dataService = arg
			elseif _combatService == nil and type(arg.NPCAttack) == "function" then
				_combatService = arg
			elseif _questService == nil
				and (type(arg.RecordEvent) == "function" or type(arg.GetQuests) == "function")
			then
				_questService = arg
			elseif _raidService == nil and type(arg.RegisterGuard) == "function" then
				_raidService = arg
			end
		elseif typeof(arg) == "Instance" and (arg:IsA("Model") or arg:IsA("Folder")) then
			_map = arg
		end
	end
	getFolder()
	RunService.Heartbeat:Connect(heartbeat)
end

return NPCService
