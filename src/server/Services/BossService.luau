--!strict
-- BossService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- THE ALGORITHM: the world boss. A large model built entirely from
-- Parts (tall dark obelisk torso, glowing ring, crown spikes — a
-- silhouette nothing else in the game shares), spawned in the Chaos
-- Arena on EventService trigger or every 30 minutes.
--
-- 3 PHASES (HP thresholds change speed / damage / attack pattern):
--   Phase 1 (> 66% HP): speed 10, damage 15, melee slam only.
--   Phase 2 (33-66% HP): speed 14, damage 25, + radial shockwave
--                        (knockback + 20 damage, 15 studs) every 8s.
--   Phase 3 (< 33% HP):  speed 18, damage 35, + meteor rain every 5s
--                        and 2 minion summons every 20s.
--
-- DAMAGE CREDIT: CombatService stamps the Creator tag on every hit, so
-- HealthChanged deltas are attributed to the current Creator player —
-- no client-supplied damage is ever trusted.
--
-- REWARDS on death: top damager gets +50 Gems and a guaranteed Epic+
-- Brainrot grant (Epic / Legendary / Mythic, preferring one they do
-- not own); every participant (damage > 0) gets +10 Event Tokens and
-- +200 coins. Boss defeat also fires the "defeat_boss" quest event.
--
-- PERFORMANCE: one Heartbeat loop, 0.5s boss tick.
--
-- OPTIONAL DEPENDENCIES: Init(map, dataService?, npcService?,
-- questService?) — all after `map` are optional and nil-safe. Without
-- NPCService, Phase 3 summons are skipped (warned). Without
-- DataService, rewards cannot be paid (warned).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local BossService = {}

local _map: Instance? = nil
local _dataService: any = nil
local _npcService: any = nil
local _questService: any = nil

local BOSS_NAME = "THE ALGORITHM"
local BOSS_MAX_HEALTH = 5000
local RESPAWN_INTERVAL = 30 * 60 -- 30 minutes
local PHASE2_THRESHOLD = 0.66
local PHASE3_THRESHOLD = 0.33

local _boss: Model? = nil
local _bossHumanoid: Humanoid? = nil
local _phase: number = 1
local _damageDealt: { [Player]: number } = {}
local _prevHealth: number = BOSS_MAX_HEALTH
local _lastTick: number = 0
local _lastShockwave: number = 0
local _lastMeteor: number = 0
local _lastSummon: number = 0
local _lastAttackAt: number = 0

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

local function arenaCenter(): Vector3
	local arena = workspace:FindFirstChild("ChaosArena") or workspace:FindFirstChild("Arena")
	if arena and arena:IsA("BasePart") then
		return arena.Position + Vector3.new(0, 3, 0)
	end
	if _map then
		local part = _map:FindFirstChild("ChaosArena")
		if part and part:IsA("BasePart") then
			return part.Position + Vector3.new(0, 3, 0)
		end
	end
	return Vector3.new(0, 5, 0)
end

-- Build THE ALGORITHM from Parts: a tall dark obelisk torso, a glowing
-- ring around its waist, crown spikes on its head, and heavy arms.
local function buildBossModel(position: Vector3): (Model, Humanoid)
	local model = Instance.new("Model")
	model.Name = BOSS_NAME
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(4, 4, 2)
	root.Position = position
	root.Parent = model
	model.PrimaryPart = root
	-- Obelisk torso (tall, dark, tapered look via two stacked parts).
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(6, 9, 4)
	torso.Color = Color3.fromRGB(25, 25, 40)
	torso.Material = Enum.Material.Metal
	torso.Position = position + Vector3.new(0, 2, 0)
	torso.Parent = model
	local torsoWeld = Instance.new("Weld")
	torsoWeld.Part0 = root
	torsoWeld.Part1 = torso
	torsoWeld.Parent = root
	-- Glowing ring around the waist.
	local ring = Instance.new("Part")
	ring.Name = "AlgorithmRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(1, 9, 9)
	ring.CFrame = CFrame.new(position + Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = Color3.fromRGB(150, 80, 255)
	ring.Material = Enum.Material.Neon
	ring.CanCollide = false
	ring.Parent = model
	local ringWeld = Instance.new("Weld")
	ringWeld.Part0 = torso
	ringWeld.Part1 = ring
	ringWeld.C0 = CFrame.new(0, -1, 0) * CFrame.Angles(0, 0, math.rad(90))
	ringWeld.Parent = torso
	-- Head with crown spikes.
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(4, 4, 4)
	head.Color = Color3.fromRGB(40, 40, 70)
	head.Material = Enum.Material.Metal
	head.Position = position + Vector3.new(0, 8, 0)
	head.Parent = model
	local headWeld = Instance.new("Weld")
	headWeld.Part0 = torso
	headWeld.Part1 = head
	headWeld.C0 = CFrame.new(0, 6.5, 0)
	headWeld.Parent = torso
	for i = 1, 5 do
		local spike = Instance.new("Part")
		spike.Name = "CrownSpike" .. tostring(i)
		spike.Size = Vector3.new(0.8, 3, 0.8)
		spike.Color = Color3.fromRGB(150, 80, 255)
		spike.Material = Enum.Material.Neon
		spike.Position = position + Vector3.new((i - 3) * 1.2, 11, 0)
		spike.Parent = model
		local spikeWeld = Instance.new("Weld")
		spikeWeld.Part0 = head
		spikeWeld.Part1 = spike
		spikeWeld.C0 = CFrame.new((i - 3) * 1.2, 3, 0)
		spikeWeld.Parent = head
	end
	-- Heavy arms.
	for _, side in ipairs({ -1, 1 }) do
		local arm = Instance.new("Part")
		arm.Name = "Arm" .. tostring(side)
		arm.Size = Vector3.new(2, 7, 2)
		arm.Color = Color3.fromRGB(25, 25, 40)
		arm.Material = Enum.Material.Metal
		arm.Position = position + Vector3.new(side * 4.5, 3, 0)
		arm.Parent = model
		local armWeld = Instance.new("Weld")
		armWeld.Part0 = torso
		armWeld.Part1 = arm
		armWeld.C0 = CFrame.new(side * 4.5, 1, 0)
		armWeld.Parent = torso
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = BOSS_MAX_HEALTH
	humanoid.MaxHealth = BOSS_MAX_HEALTH
	humanoid.WalkSpeed = 10
	humanoid.Parent = model
	local tag = Instance.new("BoolValue")
	tag.Name = "IsNPC"
	tag.Parent = model
	model:SetAttribute("NPCType", "Boss")
	model:SetAttribute("Damage", 15)
	-- Parent into the NPCs folder, NOT workspace root: CombatService
	-- only scans Players' characters + workspace.NPCs for targets, so
	-- a boss parented to workspace could never be hit by melee or
	-- abilities at all. v1.0.0 parented it to workspace — the boss was
	-- undamageable by normal combat.
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "NPCs"
		folder.Parent = workspace
	end
	model.Parent = folder
	return model, humanoid
end

local function phaseForHealth(health: number): number
	local fraction = health / BOSS_MAX_HEALTH
	if fraction <= PHASE3_THRESHOLD then
		return 3
	elseif fraction <= PHASE2_THRESHOLD then
		return 2
	end
	return 1
end

local function phaseStats(phase: number): (number, number)
	if phase == 3 then
		return 18, 35
	elseif phase == 2 then
		return 14, 25
	end
	return 10, 15
end

local function nearestPlayer(position: Vector3, maxDist: number): Player?
	local best: Player? = nil
	local bestDist = maxDist + 1
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				local dist = (root.Position - position).Magnitude
				if dist < bestDist then
					best = player
					bestDist = dist
				end
			end
		end
	end
	return best
end

local function shockwave()
	local model = _boss
	local humanoid = _bossHumanoid
	if not model or not humanoid or humanoid.Health <= 0 then
		return
	end
	local origin = model:GetPivot().Position
	fireAll(_names.SpawnEffect, { type = "BossShockwave", position = origin })
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			local targetHumanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and targetHumanoid and targetHumanoid.Health > 0 then
				local dist = (root.Position - origin).Magnitude
				if dist <= 15 then
					pcall(function()
						targetHumanoid:TakeDamage(20)
					end)
					local away = root.Position - origin
					away = Vector3.new(away.X, 0, away.Z)
					if away.Magnitude < 0.01 then
						away = Vector3.new(0, 0, 1)
					end
					local bv = Instance.new("BodyVelocity")
					bv.MaxForce = Vector3.new(math.huge, 0, math.huge)
					bv.Velocity = away.Unit * 35 + Vector3.new(0, 6, 0)
					bv.Parent = root
					Debris:AddItem(bv, 0.3)
				end
			end
		end
	end
end

local function meteorRain()
	local model = _boss
	if not model then
		return
	end
	local origin = model:GetPivot().Position
	for _ = 1, 3 do
		local meteor = Instance.new("Part")
		meteor.Name = "BossMeteor"
		meteor.Shape = Enum.PartType.Ball
		meteor.Size = Vector3.new(3, 3, 3)
		meteor.Material = Enum.Material.Neon
		meteor.Color = Color3.fromRGB(255, 60, 60)
		meteor.Anchored = false
		meteor.CanCollide = true
		meteor.Position = origin + Vector3.new(math.random(-15, 15), 50, math.random(-15, 15))
		meteor.Parent = workspace
		Debris:AddItem(meteor, 8)
		local touched: { [Humanoid]: boolean } = {}
		meteor.Touched:Connect(function(hit)
			local hitModel = hit:FindFirstAncestorOfClass("Model")
			if not hitModel then
				return
			end
			local humanoid = hitModel:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and not touched[humanoid] then
				touched[humanoid] = true
				pcall(function()
					humanoid:TakeDamage(25)
				end)
			end
		end)
	end
end

local function summonMinions()
	if not _npcService or type(_npcService.SpawnEnemy) ~= "function" then
		return
	end
	local model = _boss
	if not model then
		return
	end
	local origin = model:GetPivot().Position
	for _ = 1, 2 do
		pcall(function()
			_npcService.SpawnEnemy(nil, origin + Vector3.new(math.random(-6, 6), 3, math.random(-6, 6)), { Health = 100, Damage = 10 })
		end)
	end
end

local function grantEpicPlus(player: Player): string?
	if not _dataService then
		return nil
	end
	local data: any = nil
	pcall(function()
		data = _dataService.GetOrLoad(player)
	end)
	if not data then
		return nil
	end
	-- Prefer an Epic+ character the player does not own yet.
	local pool: { string } = {}
	local owned: { [string]: boolean } = {}
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			owned[id] = true
		end
	end
	for _, rarity in ipairs({ "Epic", "Legendary", "Mythic" }) do
		for _, def in ipairs(Characters.GetByRarity(rarity)) do
			if not owned[def.Id] then
				table.insert(pool, def.Id)
			end
		end
	end
	if #pool == 0 then
		for _, rarity in ipairs({ "Epic", "Legendary", "Mythic" }) do
			for _, def in ipairs(Characters.GetByRarity(rarity)) do
				table.insert(pool, def.Id)
			end
		end
	end
	if #pool == 0 then
		return nil
	end
	local granted = pool[math.random(1, #pool)]
	pcall(function()
		_dataService.UnlockCharacter(player, granted)
	end)
	return granted
end

local function onBossDeath()
	local model = _boss
	if not model then
		return
	end
	local position = model:GetPivot().Position
	-- Top damager.
	local top: Player? = nil
	local topDamage = 0
	for player, damage in pairs(_damageDealt) do
		if damage > topDamage then
			top = player
			topDamage = damage
		end
	end
	if top and top.Parent and _dataService then
		local data: any = nil
		pcall(function()
			data = _dataService.GetOrLoad(top)
		end)
		if data then
			data.Gems = (tonumber(data.Gems) or 0) + 50
			local granted = grantEpicPlus(top)
			fireClient(_names.PlayerStats, top, {
				Coins = data.Coins,
				Gems = data.Gems,
				EventTokens = data.EventTokens,
				BossReward = granted,
			})
			print(string.format(
				"[BossService] Top damager %s (+50 gems, Epic+ grant: %s)",
				top.Name, tostring(granted)
			))
		end
	end
	-- Every participant: +10 Event Tokens, +200 coins, boss quest event.
	for player, damage in pairs(_damageDealt) do
		if damage > 0 and player.Parent and _dataService then
			local data: any = nil
			pcall(function()
				data = _dataService.GetOrLoad(player)
			end)
			if data then
				data.EventTokens = (tonumber(data.EventTokens) or 0) + 10
				pcall(function()
					_dataService.AddCoins(player, 200)
				end)
			end
			if _questService and type(_questService.RecordEvent) == "function" then
				pcall(function()
					_questService.RecordEvent(player, "defeat_boss", 1)
				end)
			end
		end
	end
	fireAll(_names.SpawnEffect, {
		type = "BossDefeated",
		position = position,
		topDamager = top and top.Name or nil,
	})
	fireAll(_names.WaveUpdate, {
		BossDefeated = true,
		TopDamager = top and top.Name or nil,
	})
	print("[BossService] THE ALGORITHM defeated")
	task.delay(2, function()
		if model.Parent then
			model:Destroy()
		end
	end)
	_boss = nil
	_bossHumanoid = nil
	_phase = 1
	_damageDealt = {}
	_prevHealth = BOSS_MAX_HEALTH
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function BossService.IsBossActive(): boolean
	return _boss ~= nil and _boss.Parent ~= nil
end

function BossService.GetBossState(): { Active: boolean, Health: number, MaxHealth: number, Phase: number }
	local humanoid = _bossHumanoid
	return {
		Active = BossService.IsBossActive(),
		Health = humanoid and math.max(0, math.floor(humanoid.Health)) or 0,
		MaxHealth = BOSS_MAX_HEALTH,
		Phase = _phase,
	}
end

-- SpawnBoss(): spawns in the Chaos Arena. Returns false when already active.
function BossService.SpawnBoss(): boolean
	if BossService.IsBossActive() then
		return false
	end
	local position = arenaCenter()
	local model, humanoid = buildBossModel(position)
	_boss = model
	_bossHumanoid = humanoid
	_phase = 1
	_damageDealt = {}
	_prevHealth = BOSS_MAX_HEALTH
	model:SetAttribute("Damage", 15)
	-- Damage attribution: CombatService stamps Creator on every hit;
	-- attribute each HealthChanged delta to that player.
	humanoid.HealthChanged:Connect(function(health)
		local delta = _prevHealth - health
		_prevHealth = health
		if delta > 0 then
			local creator = model:FindFirstChild("Creator")
			if creator and creator:IsA("ObjectValue") and creator.Value and creator.Value:IsA("Player") then
				local attacker = creator.Value :: Player
				_damageDealt[attacker] = (_damageDealt[attacker] or 0) + delta
			end
		end
		local newPhase = phaseForHealth(health)
		if newPhase ~= _phase then
			_phase = newPhase
			local speed, damage = phaseStats(newPhase)
			humanoid.WalkSpeed = speed
			model:SetAttribute("Damage", damage)
			fireAll(_names.SpawnEffect, {
				type = "BossPhase",
				phase = newPhase,
				position = model:GetPivot().Position,
			})
			print(string.format("[BossService] THE ALGORITHM entered phase %d", newPhase))
		end
	end)
	humanoid.Died:Connect(function()
		onBossDeath()
	end)
	fireAll(_names.SpawnEffect, {
		type = "BossSpawn",
		position = position,
	})
	fireAll(_names.WaveUpdate, { BossSpawned = true })
	print("[BossService] THE ALGORITHM spawned in the Chaos Arena")
	return true
end

-- OnEventTrigger(): EventService calls this to spawn the boss on demand.
function BossService.OnEventTrigger()
	BossService.SpawnBoss()
end

function BossService.SetNPCService(npcService: any)
	_npcService = npcService
end

function BossService.SetQuestService(questService: any)
	_questService = questService
end

local function heartbeat()
	if not BossService.IsBossActive() then
		return
	end
	local now = os.clock()
	if now - _lastTick < 0.5 then
		return
	end
	_lastTick = now
	local model = _boss
	local humanoid = _bossHumanoid
	if not model or not humanoid or humanoid.Health <= 0 then
		return
	end
	local ok, err = pcall(function()
		local pos = model:GetPivot().Position
		local target = nearestPlayer(pos, 60)
		if not target or not target.Character then
			return
		end
		local root = target.Character:FindFirstChild("HumanoidRootPart")
		local targetHumanoid = target.Character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") or not targetHumanoid or targetHumanoid.Health <= 0 then
			return
		end
		local dist = (root.Position - pos).Magnitude
		local _, damage = phaseStats(_phase)
		if dist <= 6 then
			-- Melee slam.
			if now - _lastAttackAt >= 1 then
				_lastAttackAt = now
				pcall(function()
					targetHumanoid:TakeDamage(damage)
				end)
				fireAll(_names.SpawnEffect, { type = "BossSlam", position = root.Position })
			end
		else
			humanoid:MoveTo(root.Position)
		end
		if _phase >= 2 and now - _lastShockwave >= 8 then
			_lastShockwave = now
			shockwave()
		end
		if _phase >= 3 then
			if now - _lastMeteor >= 5 then
				_lastMeteor = now
				meteorRain()
			end
			if now - _lastSummon >= 20 then
				_lastSummon = now
				summonMinions()
			end
		end
	end)
	if not ok then
		warn("[BossService] Boss tick failed: " .. tostring(err))
	end
end

function BossService.Init(map: Instance?, dataService: any?, npcService: any?, questService: any?)
	_map = map
	_dataService = dataService
	_npcService = npcService
	_questService = questService
	RunService.Heartbeat:Connect(heartbeat)
	-- Auto-spawn every 30 minutes.
	task.spawn(function()
		while true do
			task.wait(RESPAWN_INTERVAL)
			local ok, err = pcall(function()
				BossService.SpawnBoss()
			end)
			if not ok then
				warn("[BossService] Auto-spawn failed: " .. tostring(err))
			end
		end
	end)
end

return BossService
