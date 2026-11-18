--!strict
-- BossService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- World bosses. Every boss follows the same pattern:
--   * 3 PHASES by HP thresholds (speed / damage / attack pattern change)
--   * telegraphs (SpawnEffect broadcasts before every special attack)
--   * movement (chase nearest player, melee slam in range)
--   * health presentation (BossUpdate broadcasts: spawn / phase / death
--     + a health broadcast every 2s while the fight runs)
--   * arena effects (SpawnEffect on spawn / phase / death)
--   * phase transitions (speed + damage restat, broadcast)
--   * special attacks per phase, rewards on death, difficulty scaling
--     (new bosses scale MaxHealth with player count), co-op rewards
--     (2+ participants = 1.5x participant coins/tokens), Creator-tag
--     damage credit, optional NPCService / quest hooks.
--
-- BOSSES:
--   THE ALGORITHM (Chaos Arena) — the v1.0.2 world boss, UNCHANGED:
--     5,000 HP (never scaled), 3 phases, 30-min auto-spawn, top damager
--     +50 Gems + guaranteed Epic+ grant, participants +10 Event Tokens
--     +200 coins, "defeat_boss" quest event.
--   THE GLITCH COLOSSUS (Chaos Arena) — v1.1 NEW. 7,500 HP base.
--     Phase 1: slow ground slams + glitch-barrier walls.
--     Phase 2: + shockwave, + teleports next to a random player.
--     Phase 3: + meteor rain, + minion summons, + glitch nova (randomly
--     teleports every nearby player). Top damager +75 Gems +
--     guaranteed Legendary+ grant; participants +15 tokens +300 coins.
--   THE VOID EMPEROR (Forbidden Rift) — v1.1 NEW. 9,000 HP base.
--     Phase 1: fast chaser, void bolts (ranged, telegraphed).
--     Phase 2: + void zones (damage-over-time fields), + summons.
--     Phase 3: + starfall/meteor rain, + void nova shockwave.
--     Top damager +100 Gems + guaranteed Mythic+ grant; participants
--     +20 tokens +400 coins.
--
-- DAMAGE CREDIT: CombatService stamps the Creator tag on every hit, so
-- HealthChanged deltas are attributed to the current Creator player —
-- no client-supplied damage is ever trusted.
--
-- SPAWN PATHS: SpawnBoss() / SpawnBoss("Algorithm") (EventService
-- trigger, 30-min timer, every-5th-tide boss tide), SpawnBoss(id) for
-- the new bosses (GiantBoss tide calls SpawnBoss("GlitchColossus");
-- WaveService boss waves rotate the new bosses). Only one boss is
-- active at a time — SpawnBoss returns false while one lives.
--
-- PERFORMANCE: one Heartbeat loop, 0.5s boss tick.
--
-- OPTIONAL DEPENDENCIES: Init(map, dataService?, npcService?,
-- questService?) — all after `map` are optional and nil-safe. Without
-- NPCService, summons are skipped (warned). Without DataService,
-- rewards cannot be paid (warned).

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

type BossDef = {
	Id: string,
	Name: string,
	MaxHealth: number,
	Arena: string, -- "ChaosArena" | "ForbiddenRift"
	ScaleWithPlayers: boolean,
	TorsoSize: Vector3,
	TorsoColor: Color3,
	RingColor: Color3,
	AccentColor: Color3,
	SpikeCount: number,
	HasOrb: boolean,
	PhaseSpeeds: { number },
	PhaseDamage: { number },
	ShockwaveInterval: number?, -- seconds, nil = no shockwave
	MeteorInterval: number?, -- seconds, nil = no meteor rain
	SummonInterval: number?, -- seconds, nil = no summons
	SummonFromPhase: number,
	TeleportInterval: number?, -- boss teleports to a player
	VoidBoltInterval: number?, -- ranged bolt (Void Emperor)
	VoidZoneInterval: number?, -- DoT zone spawn (Void Emperor)
	NovaInterval: number?, -- glitch/void nova (phase 3)
	TopGems: number,
	GrantRarities: { string },
	ParticipantTokens: number,
	ParticipantCoins: number,
	ParticipantShards: number,
	QuestEvent: string,
}

local BOSS_DEFS: { [string]: BossDef } = {
	Algorithm = {
		Id = "Algorithm",
		Name = "THE ALGORITHM",
		MaxHealth = 5000,
		Arena = "ChaosArena",
		ScaleWithPlayers = false, -- v1.0.2 behaviour preserved exactly
		TorsoSize = Vector3.new(6, 9, 4),
		TorsoColor = Color3.fromRGB(25, 25, 40),
		RingColor = Color3.fromRGB(150, 80, 255),
		AccentColor = Color3.fromRGB(150, 80, 255),
		SpikeCount = 5,
		HasOrb = false,
		PhaseSpeeds = { 10, 14, 18 },
		PhaseDamage = { 15, 25, 35 },
		ShockwaveInterval = 8,
		MeteorInterval = 5,
		SummonInterval = 20,
		SummonFromPhase = 3,
		TeleportInterval = nil,
		VoidBoltInterval = nil,
		VoidZoneInterval = nil,
		NovaInterval = nil,
		TopGems = 50,
		GrantRarities = { "Epic", "Legendary", "Mythic" },
		ParticipantTokens = 10,
		ParticipantCoins = 200,
		ParticipantShards = 0,
		QuestEvent = "defeat_boss",
	},
	GlitchColossus = {
		Id = "GlitchColossus",
		Name = "THE GLITCH COLOSSUS",
		MaxHealth = 7500,
		Arena = "ChaosArena",
		ScaleWithPlayers = true,
		TorsoSize = Vector3.new(9, 11, 6),
		TorsoColor = Color3.fromRGB(20, 20, 35),
		RingColor = Color3.fromRGB(255, 40, 220),
		AccentColor = Color3.fromRGB(40, 220, 255),
		SpikeCount = 7,
		HasOrb = false,
		PhaseSpeeds = { 8, 12, 16 },
		PhaseDamage = { 20, 30, 40 },
		ShockwaveInterval = 10,
		MeteorInterval = 6,
		SummonInterval = 18,
		SummonFromPhase = 3,
		TeleportInterval = 12,
		VoidBoltInterval = nil,
		VoidZoneInterval = nil,
		NovaInterval = 15,
		TopGems = 75,
		GrantRarities = { "Legendary", "Mythic", "Divine" },
		ParticipantTokens = 15,
		ParticipantCoins = 300,
		ParticipantShards = 3,
		QuestEvent = "defeat_boss_colossus",
	},
	VoidEmperor = {
		Id = "VoidEmperor",
		Name = "THE VOID EMPEROR",
		MaxHealth = 9000,
		Arena = "ForbiddenRift",
		ScaleWithPlayers = true,
		TorsoSize = Vector3.new(5, 12, 3),
		TorsoColor = Color3.fromRGB(15, 10, 30),
		RingColor = Color3.fromRGB(120, 40, 255),
		AccentColor = Color3.fromRGB(255, 60, 200),
		SpikeCount = 3,
		HasOrb = true,
		PhaseSpeeds = { 12, 15, 20 },
		PhaseDamage = { 25, 35, 45 },
		ShockwaveInterval = 12,
		MeteorInterval = 5,
		SummonInterval = 15,
		SummonFromPhase = 2,
		TeleportInterval = nil,
		VoidBoltInterval = 4,
		VoidZoneInterval = 9,
		NovaInterval = 15,
		TopGems = 100,
		GrantRarities = { "Mythic", "Divine", "Celestial", "Secret" },
		ParticipantTokens = 20,
		ParticipantCoins = 400,
		ParticipantShards = 5,
		QuestEvent = "defeat_boss_void_emperor",
	},
}

local RESPAWN_INTERVAL = 30 * 60 -- 30 minutes
local PHASE2_THRESHOLD = 0.66
local PHASE3_THRESHOLD = 0.33

local _boss: Model? = nil
local _bossHumanoid: Humanoid? = nil
local _bossDef: BossDef? = nil
local _bossMaxHealth: number = 5000
local _phase: number = 1
local _damageDealt: { [Player]: number } = {}
local _prevHealth: number = 5000
local _lastTick: number = 0
local _lastShockwave: number = 0
local _lastMeteor: number = 0
local _lastSummon: number = 0
local _lastAttackAt: number = 0
local _lastTeleport: number = 0
local _lastBolt: number = 0
local _lastVoidZone: number = 0
local _lastNova: number = 0
local _lastBossUpdate: number = 0
local _voidZones: { BasePart } = {}

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

-- Boss health presentation: BossUpdate now fires (v1.0.2: declared but
-- fired by no service). Clients degrade gracefully if they do not
-- listen yet; see docs/REMOTES_NEEDED_D.md.
local function broadcastBossUpdate(event: string)
	local humanoid = _bossHumanoid
	local def = _bossDef
	if not def then
		return
	end
	-- Fire by string name: Remotes.luau must NOT be edited (other
	-- workstreams own it); BossUpdate already exists in Remotes.Names.
	fireAll("BossUpdate", {
		Event = event, -- "Spawned" | "Phase" | "Health" | "Defeated"
		BossId = def.Id,
		BossName = def.Name,
		Arena = def.Arena,
		Active = BossService.IsBossActive(),
		Health = humanoid and math.max(0, math.floor(humanoid.Health)) or 0,
		MaxHealth = _bossMaxHealth,
		Phase = _phase,
	})
end

-- Arena centre: the zone folder (ChaosArena / ForbiddenRift) under the
-- map model or Workspace, using a named platform/portal part when one
-- exists, else the folder's first BasePart, else the arena fallback.
local function zoneCenter(folderName: string, fallback: Vector3): Vector3
	local folder: Instance? = nil
	if _map then
		folder = _map:FindFirstChild(folderName)
	end
	if not folder then
		folder = workspace:FindFirstChild(folderName)
	end
	if folder then
		for _, name in ipairs({ "ArenaPlatform", "RiftPortal", "ArenaFloor", "RiftTop" }) do
			local part = folder:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				return part.Position + Vector3.new(0, 3, 0)
			end
		end
		for _, child in ipairs(folder:GetDescendants()) do
			if child:IsA("BasePart") then
				return child.Position + Vector3.new(0, 3, 0)
			end
		end
	end
	return fallback
end

local function arenaCenter(def: BossDef): Vector3
	if def.Arena == "ForbiddenRift" then
		return zoneCenter("ForbiddenRift", Vector3.new(-150, 5, -150))
	end
	return zoneCenter("ChaosArena", Vector3.new(75, 5, 55))
end

-- Build a boss model from Parts, parameterised by its def so each boss
-- has a silhouette nothing else in the game shares.
local function buildBossModel(def: BossDef, position: Vector3): (Model, Humanoid)
	local model = Instance.new("Model")
	model.Name = def.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(4, 4, 2)
	root.Position = position
	root.Parent = model
	model.PrimaryPart = root
	-- Torso (obelisk / bulky / tall-slim per def).
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = def.TorsoSize
	torso.Color = def.TorsoColor
	torso.Material = Enum.Material.Metal
	torso.Position = position + Vector3.new(0, 2, 0)
	torso.Parent = model
	local torsoWeld = Instance.new("Weld")
	torsoWeld.Part0 = root
	torsoWeld.Part1 = torso
	torsoWeld.Parent = root
	-- Glowing ring around the waist.
	local ring = Instance.new("Part")
	ring.Name = "BossRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(1, def.TorsoSize.X + 3, def.TorsoSize.X + 3)
	ring.CFrame = CFrame.new(position + Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = def.RingColor
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
	head.Color = def.TorsoColor
	head.Material = Enum.Material.Metal
	head.Position = position + Vector3.new(0, def.TorsoSize.Y * 0.5 + 3.5, 0)
	head.Parent = model
	local headWeld = Instance.new("Weld")
	headWeld.Part0 = torso
	headWeld.Part1 = head
	headWeld.C0 = CFrame.new(0, def.TorsoSize.Y * 0.5 + 1.5, 0)
	headWeld.Parent = torso
	for i = 1, def.SpikeCount do
		local spike = Instance.new("Part")
		spike.Name = "CrownSpike" .. tostring(i)
		spike.Size = Vector3.new(0.8, 3, 0.8)
		spike.Color = def.AccentColor
		spike.Material = Enum.Material.Neon
		spike.Position = position + Vector3.new((i - (def.SpikeCount + 1) / 2) * 1.2, def.TorsoSize.Y * 0.5 + 6.5, 0)
		spike.Parent = model
		local spikeWeld = Instance.new("Weld")
		spikeWeld.Part0 = head
		spikeWeld.Part1 = spike
		spikeWeld.C0 = CFrame.new((i - (def.SpikeCount + 1) / 2) * 1.2, 3, 0)
		spikeWeld.Parent = head
	end
	-- Void Emperor only: a floating void orb above the crown.
	if def.HasOrb then
		local orb = Instance.new("Part")
		orb.Name = "VoidOrb"
		orb.Shape = Enum.PartType.Ball
		orb.Size = Vector3.new(3, 3, 3)
		orb.Color = def.AccentColor
		orb.Material = Enum.Material.Neon
		orb.CanCollide = false
		orb.Position = position + Vector3.new(0, def.TorsoSize.Y * 0.5 + 9, 0)
		orb.Parent = model
		local orbWeld = Instance.new("Weld")
		orbWeld.Part0 = head
		orbWeld.Part1 = orb
		orbWeld.C0 = CFrame.new(0, 5.5, 0)
		orbWeld.Parent = head
		local orbLight = Instance.new("PointLight")
		orbLight.Color = def.AccentColor
		orbLight.Range = 20
		orbLight.Brightness = 2
		orbLight.Parent = orb
	end
	-- Heavy arms.
	for _, side in ipairs({ -1, 1 }) do
		local arm = Instance.new("Part")
		arm.Name = "Arm" .. tostring(side)
		arm.Size = Vector3.new(2, 7, 2)
		arm.Color = def.TorsoColor
		arm.Material = Enum.Material.Metal
		arm.Position = position + Vector3.new(side * (def.TorsoSize.X * 0.5 + 1.5), 3, 0)
		arm.Parent = model
		local armWeld = Instance.new("Weld")
		armWeld.Part0 = torso
		armWeld.Part1 = arm
		armWeld.C0 = CFrame.new(side * (def.TorsoSize.X * 0.5 + 1.5), 1, 0)
		armWeld.Parent = torso
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = _bossMaxHealth
	humanoid.MaxHealth = _bossMaxHealth
	humanoid.WalkSpeed = def.PhaseSpeeds[1]
	humanoid.Parent = model
	local tag = Instance.new("BoolValue")
	tag.Name = "IsNPC"
	tag.Parent = model
	model:SetAttribute("NPCType", "Boss")
	model:SetAttribute("BossId", def.Id)
	model:SetAttribute("Damage", def.PhaseDamage[1])
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

local function phaseForHealth(def: BossDef, health: number): number
	local fraction = health / _bossMaxHealth
	if fraction <= PHASE3_THRESHOLD then
		return 3
	elseif fraction <= PHASE2_THRESHOLD then
		return 2
	end
	return 1
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

local function randomPlayer(maxDist: number?): Player?
	local pos = _boss and _boss:GetPivot().Position or Vector3.new(0, 5, 0)
	local candidates: { Player } = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				if not maxDist or (root.Position - pos).Magnitude <= maxDist then
					table.insert(candidates, player)
				end
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

-- Radial shockwave: telegraphed, then knockback + damage in radius.
local function shockwave(radius: number, damage: number)
	local model = _boss
	local humanoid = _bossHumanoid
	if not model or not humanoid or humanoid.Health <= 0 then
		return
	end
	local origin = model:GetPivot().Position
	fireAll(_names.SpawnEffect, { type = "BossShockwave", position = origin, radius = radius })
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			local targetHumanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and targetHumanoid and targetHumanoid.Health > 0 then
				local dist = (root.Position - origin).Magnitude
				if dist <= radius then
					pcall(function()
						targetHumanoid:TakeDamage(damage)
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

-- Meteor / starfall rain over the boss arena.
local function meteorRain(color: Color3)
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
		meteor.Color = color
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

local function summonMinions(count: number)
	if not _npcService or type(_npcService.SpawnEnemy) ~= "function" then
		return
	end
	local model = _boss
	if not model then
		return
	end
	local origin = model:GetPivot().Position
	for _ = 1, count do
		pcall(function()
			_npcService.SpawnEnemy(nil, origin + Vector3.new(math.random(-6, 6), 3, math.random(-6, 6)), { Health = 100, Damage = 10 })
		end)
	end
end

-- Void bolt (Void Emperor): telegraphed ranged hit on the nearest
-- player within 30 studs.
local function voidBolt(damage: number)
	local model = _boss
	if not model then
		return
	end
	local origin = model:GetPivot().Position
	local target = nearestPlayer(origin, 30)
	if not target or not target.Character then
		return
	end
	local root = target.Character:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = target.Character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not targetHumanoid or targetHumanoid.Health <= 0 then
		return
	end
	fireAll(_names.SpawnEffect, { type = "BossVoidBolt", position = root.Position, target = target.Name })
	pcall(function()
		targetHumanoid:TakeDamage(damage)
	end)
end

-- Void zone (Void Emperor): a DoT field that lives 10s.
local function spawnVoidZone()
	local model = _boss
	if not model then
		return
	end
	local origin = model:GetPivot().Position
	local pos = origin + Vector3.new(math.random(-12, 12), 1, math.random(-12, 12))
	local part = Instance.new("Part")
	part.Name = "VoidZone"
	part.Size = Vector3.new(10, 1, 10)
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 0.5
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(120, 40, 255)
	part.Position = pos
	part.Parent = workspace
	table.insert(_voidZones, part)
	Debris:AddItem(part, 10)
	fireAll(_names.SpawnEffect, { type = "BossVoidZone", position = pos })
	task.spawn(function()
		for _ = 1, 10 do
			task.wait(1)
			if not part.Parent then
				return
			end
			for _, player in ipairs(Players:GetPlayers()) do
				local character = player.Character
				if character then
					local root = character:FindFirstChild("HumanoidRootPart")
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
						if (root.Position - pos).Magnitude <= 6 then
							pcall(function()
								humanoid:TakeDamage(8)
							end)
						end
					end
				end
			end
		end
	end)
end

-- Nova (phase 3): the boss erupts — every player within 20 studs is
-- thrown to a random nearby spot (Colossus glitch nova / Void Emperor
-- void nova share the mechanic; the telegraph differs by boss).
local function nova()
	local model = _boss
	local def = _bossDef
	if not model or not def then
		return
	end
	local origin = model:GetPivot().Position
	fireAll(_names.SpawnEffect, {
		type = def.Id == "VoidEmperor" and "BossVoidNova" or "BossGlitchNova",
		position = origin,
	})
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				if (root.Position - origin).Magnitude <= 20 then
					pcall(function()
						root.CFrame = root.CFrame + Vector3.new(math.random(-12, 12), 0, math.random(-12, 12))
					end)
				end
			end
		end
	end
end

-- Boss teleport (Glitch Colossus phase 2+): the boss blinks next to a
-- random player, telegraphed.
local function bossTeleport()
	local model = _boss
	if not model then
		return
	end
	local target = randomPlayer(60)
	if not target or not target.Character then
		return
	end
	local root = target.Character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local from = model:GetPivot().Position
	fireAll(_names.SpawnEffect, { type = "BossTeleport", position = from })
	pcall(function()
		model:PivotTo(CFrame.new(root.Position + Vector3.new(math.random(-6, 6), 3, math.random(-6, 6))))
	end)
	fireAll(_names.SpawnEffect, { type = "BossTeleportArrive", position = model:GetPivot().Position })
end

local function grantRarityPlus(player: Player, rarities: { string }): string?
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
	-- Prefer a character the player does not own yet.
	local pool: { string } = {}
	local owned: { [string]: boolean } = {}
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			owned[id] = true
		end
	end
	for _, rarity in ipairs(rarities) do
		for _, def in ipairs(Characters.GetByRarity(rarity)) do
			if not owned[def.Id] then
				table.insert(pool, def.Id)
			end
		end
	end
	if #pool == 0 then
		for _, rarity in ipairs(rarities) do
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
	local def = _bossDef
	if not model or not def then
		return
	end
	local position = model:GetPivot().Position
	local bossName = def.Name
	-- Top damager.
	local top: Player? = nil
	local topDamage = 0
	for player, damage in pairs(_damageDealt) do
		if damage > topDamage then
			top = player
			topDamage = damage
		end
	end
	-- Co-op: 2+ participants pay 1.5x participant rewards.
	local participantCount = 0
	for player, damage in pairs(_damageDealt) do
		if damage > 0 then
			participantCount += 1
		end
	end
	local coopMult = participantCount >= 2 and 1.5 or 1
	if top and top.Parent and _dataService then
		local data: any = nil
		pcall(function()
			data = _dataService.GetOrLoad(top)
		end)
		if data then
			local gems = math.floor(def.TopGems * (participantCount >= 2 and 1.25 or 1) + 0.5)
			data.Gems = (tonumber(data.Gems) or 0) + gems
			local granted = grantRarityPlus(top, def.GrantRarities)
			fireClient(_names.PlayerStats, top, {
				Coins = data.Coins,
				Gems = data.Gems,
				EventTokens = data.EventTokens,
				BossReward = granted,
			})
			print(string.format(
				"[BossService] Top damager %s (+%d gems, %s grant: %s)",
				top.Name, gems, def.Id, tostring(granted)
			))
		end
	end
	-- Every participant: tokens + coins + shards, boss quest event.
	for player, damage in pairs(_damageDealt) do
		if damage > 0 and player.Parent and _dataService then
			local data: any = nil
			pcall(function()
				data = _dataService.GetOrLoad(player)
			end)
			if data then
				data.EventTokens = (tonumber(data.EventTokens) or 0) + math.floor(def.ParticipantTokens * coopMult + 0.5)
				data.ChaosShards = (tonumber(data.ChaosShards) or 0) + def.ParticipantShards
				pcall(function()
					_dataService.AddCoins(player, math.floor(def.ParticipantCoins * coopMult + 0.5))
				end)
			end
			if _questService and type(_questService.RecordEvent) == "function" then
				pcall(function()
					_questService.RecordEvent(player, "defeat_boss", 1)
				end)
				if def.QuestEvent ~= "defeat_boss" then
					pcall(function()
						_questService.RecordEvent(player, def.QuestEvent, 1)
					end)
				end
			end
		end
	end
	fireAll(_names.SpawnEffect, {
		type = "BossDefeated",
		position = position,
		bossId = def.Id,
		topDamager = top and top.Name or nil,
	})
	fireAll(_names.WaveUpdate, {
		BossDefeated = true,
		BossId = def.Id,
		TopDamager = top and top.Name or nil,
	})
	broadcastBossUpdate("Defeated")
	print(string.format("[BossService] %s defeated (%d participants%s)", bossName, participantCount, coopMult > 1 and ", co-op bonus paid" or ""))
	for _, part in ipairs(_voidZones) do
		pcall(function()
			part:Destroy()
		end)
	end
	_voidZones = {}
	task.delay(2, function()
		if model.Parent then
			model:Destroy()
		end
	end)
	_boss = nil
	_bossHumanoid = nil
	_bossDef = nil
	_bossMaxHealth = 5000
	_phase = 1
	_damageDealt = {}
	_prevHealth = 5000
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function BossService.IsBossActive(): boolean
	return _boss ~= nil and _boss.Parent ~= nil
end

function BossService.GetBossId(): string?
	return _bossDef and _bossDef.Id or nil
end

function BossService.GetBossName(): string?
	return _bossDef and _bossDef.Name or nil
end

function BossService.GetBossState(): { Active: boolean, Health: number, MaxHealth: number, Phase: number, BossId: string?, BossName: string? }
	local humanoid = _bossHumanoid
	return {
		Active = BossService.IsBossActive(),
		Health = humanoid and math.max(0, math.floor(humanoid.Health)) or 0,
		MaxHealth = _bossMaxHealth,
		Phase = _phase,
		BossId = BossService.GetBossId(),
		BossName = BossService.GetBossName(),
	}
end

-- SpawnBoss(bossId?): spawns in the boss's arena. No argument (or
-- "Algorithm") spawns THE ALGORITHM — the v1.0.2 behaviour every
-- existing caller relies on. "GlitchColossus" / "VoidEmperor" spawn
-- the v1.1 bosses. Returns false when a boss is already active or the
-- id is unknown.
function BossService.SpawnBoss(bossId: string?): boolean
	if BossService.IsBossActive() then
		return false
	end
	local id = bossId or "Algorithm"
	local def = BOSS_DEFS[id]
	if not def then
		warn("[BossService] SpawnBoss: unknown boss id " .. tostring(bossId))
		return false
	end
	-- Difficulty scaling (new bosses only): +10% MaxHealth per extra
	-- player online, capped at 2x. THE ALGORITHM is never scaled.
	local maxHealth = def.MaxHealth
	if def.ScaleWithPlayers then
		local players = #Players:GetPlayers()
		local mult = 1 + 0.1 * math.min(math.max(players - 1, 0), 10)
		maxHealth = math.floor(def.MaxHealth * mult + 0.5)
	end
	_bossMaxHealth = maxHealth
	_prevHealth = maxHealth
	local position = arenaCenter(def)
	local model, humanoid = buildBossModel(def, position)
	_boss = model
	_bossHumanoid = humanoid
	_bossDef = def
	_phase = 1
	_damageDealt = {}
	_lastTick = 0
	_lastShockwave = 0
	_lastMeteor = 0
	_lastSummon = 0
	_lastAttackAt = 0
	_lastTeleport = 0
	_lastBolt = 0
	_lastVoidZone = 0
	_lastNova = 0
	_lastBossUpdate = 0
	model:SetAttribute("Damage", def.PhaseDamage[1])
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
		local newPhase = phaseForHealth(def, health)
		if newPhase ~= _phase then
			_phase = newPhase
			humanoid.WalkSpeed = def.PhaseSpeeds[newPhase]
			model:SetAttribute("Damage", def.PhaseDamage[newPhase])
			fireAll(_names.SpawnEffect, {
				type = "BossPhase",
				bossId = def.Id,
				phase = newPhase,
				position = model:GetPivot().Position,
			})
			broadcastBossUpdate("Phase")
			print(string.format("[BossService] %s entered phase %d", def.Name, newPhase))
		end
	end)
	humanoid.Died:Connect(function()
		onBossDeath()
	end)
	fireAll(_names.SpawnEffect, {
		type = "BossSpawn",
		bossId = def.Id,
		position = position,
	})
	fireAll(_names.WaveUpdate, { BossSpawned = true, BossId = def.Id })
	broadcastBossUpdate("Spawned")
	print(string.format("[BossService] %s spawned in %s (%d HP)", def.Name, def.Arena, maxHealth))
	return true
end

-- OnEventTrigger(bossId?): EventService calls this to spawn the boss on
-- demand. No argument = THE ALGORITHM (v1.0.2 behaviour).
function BossService.OnEventTrigger(bossId: string?)
	BossService.SpawnBoss(bossId)
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
	local def = _bossDef
	if not model or not humanoid or humanoid.Health <= 0 or not def then
		return
	end
	-- Health presentation: BossUpdate every 2s while the fight runs.
	if now - _lastBossUpdate >= 2 then
		_lastBossUpdate = now
		broadcastBossUpdate("Health")
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
		local damage = def.PhaseDamage[_phase]
		if dist <= 6 then
			-- Melee slam.
			if now - _lastAttackAt >= 1 then
				_lastAttackAt = now
				pcall(function()
					targetHumanoid:TakeDamage(damage)
				end)
				fireAll(_names.SpawnEffect, { type = "BossSlam", bossId = def.Id, position = root.Position })
			end
		else
			humanoid:MoveTo(root.Position)
		end
		-- Phase-gated special attacks (intervals from the boss def).
		if _phase >= 2 and def.ShockwaveInterval and now - _lastShockwave >= def.ShockwaveInterval then
			_lastShockwave = now
			shockwave(15, 20)
		end
		if def.TeleportInterval and _phase >= 2 and now - _lastTeleport >= def.TeleportInterval then
			_lastTeleport = now
			bossTeleport()
		end
		if def.VoidBoltInterval and now - _lastBolt >= def.VoidBoltInterval then
			_lastBolt = now
			voidBolt(damage)
		end
		if def.VoidZoneInterval and _phase >= 2 and now - _lastVoidZone >= def.VoidZoneInterval then
			_lastVoidZone = now
			spawnVoidZone()
		end
		if _phase >= 3 then
			if def.MeteorInterval and now - _lastMeteor >= def.MeteorInterval then
				_lastMeteor = now
				meteorRain(def.Id == "VoidEmperor" and Color3.fromRGB(120, 40, 255) or Color3.fromRGB(255, 60, 60))
			end
			if def.SummonInterval and _phase >= def.SummonFromPhase and now - _lastSummon >= def.SummonInterval then
				_lastSummon = now
				summonMinions(2)
			end
			if def.NovaInterval and now - _lastNova >= def.NovaInterval then
				_lastNova = now
				nova()
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
	-- Auto-spawn every 30 minutes (THE ALGORITHM, as in v1.0.2).
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
