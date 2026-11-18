--!strict
-- WaveService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Secondary PvE waves in the Chaos Arena (kept from the old arena
-- design). Wave N spawns N+2 wild NPC Brainrots; clearing the wave pays
-- coins + XP to every player still in the game; every 5th wave spawns a
-- mini-boss (5x health, 2x damage, double reward).
--
-- PRIORITY LOW by design: this file is compact on purpose. It reuses
-- NPCService.SpawnEnemy when linked (optional 3rd Init arg or
-- SetNPCService) and otherwise runs its own minimal spawn loop (parts +
-- Humanoid that wander and damage on touch).
--
-- v1.1: boss tides and wave bosses cohere. Every 10th wave also
-- summons a real boss via BossService (rotating THE GLITCH COLOSSUS /
-- THE VOID EMPEROR) when linked and no boss is live — in addition to
-- the wave's own mini-boss, never instead of it. And no NEW wave
-- starts while a Glitch Tide is Warning/Active: the tide owns the
-- arena while it runs (a wave already in progress keeps running and
-- can still be cleared for its reward). WaveNPC caps are unchanged
-- (count = min(wave+2, Config.MaxWaveNPCs)).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Economy = require(ReplicatedStorage:WaitForChild("Economy"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local WaveService = {}

local _dataService: any = nil
local _map: Instance? = nil
local _npcService: any = nil
local _questService: any = nil
local _progressionService: any = nil
-- v1.1: BossService + TideService links (GameManager's wireCrossLinks
-- calls SetBossService / SetTideService on every optional service, so
-- both are wired automatically when the services exist).
local _bossService: any = nil
local _tideService: any = nil

local _wave: number = 0
local _running: boolean = false
local _waveNPCs: { Model } = {}
local _runToken: number = 0

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

-- Minimal fallback enemy (only when NPCService is absent): coloured
-- block body + Humanoid, wanders, damages on touch (8, 1s per target).
local function spawnFallbackEnemy(position: Vector3, isMiniBoss: boolean): Model?
	local all = Characters.GetAll()
	local def = all[math.random(1, #all)]
	local model = Instance.new("Model")
	model.Name = (isMiniBoss and "MiniBoss_" or "Wave_") .. def.DisplayName
	model:SetAttribute("NPCType", "Enemy")
	model:SetAttribute("WaveId", _wave)
	local health = (Config.WaveNPCHealthBase or 60) + _wave * (Config.WaveNPCHealthPerWave or 18)
	if isMiniBoss then
		health *= 5
	end
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Position = position
	root.Parent = model
	model.PrimaryPart = root
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = isMiniBoss and Vector3.new(4.5, 4.5, 3) or Vector3.new(3, 3, 2)
	body.Color = def.Color
	body.Parent = model
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = body
	weld.Parent = root
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = health
	humanoid.MaxHealth = health
	humanoid.WalkSpeed = def.Speed or 14
	humanoid.Parent = model
	local tag = Instance.new("BoolValue")
	tag.Name = "IsNPC"
	tag.Parent = model
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
	-- a fallback wave NPC paid nothing and advanced no quest.
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
	-- Touch damage (server-side flat value, 1s per-target cooldown).
	local damage = (Config.WaveNPCDamageBase or 8) * (isMiniBoss and 2 or 1)
	local lastHit: { [Humanoid]: number } = {}
	body.Touched:Connect(function(hit)
		local hitModel = hit:FindFirstAncestorOfClass("Model")
		if not hitModel then
			return
		end
		local target = hitModel:FindFirstChildOfClass("Humanoid")
		if not target or target.Health <= 0 then
			return
		end
		local now = os.clock()
		if now - (lastHit[target] or -math.huge) >= 1 then
			lastHit[target] = now
			pcall(function()
				target:TakeDamage(damage)
			end)
		end
	end)
	task.spawn(function()
		while model.Parent and humanoid.Health > 0 do
			pcall(function()
				humanoid:MoveTo(position + Vector3.new(math.random(-15, 15), 0, math.random(-15, 15)))
			end)
			task.wait(3)
		end
	end)
	Debris:AddItem(model, 300)
	return model
end

local function spawnWaveNPC(position: Vector3, isMiniBoss: boolean): Model?
	if _npcService and type(_npcService.SpawnEnemy) == "function" then
		local health = (Config.WaveNPCHealthBase or 60) + _wave * (Config.WaveNPCHealthPerWave or 18)
		local damage = Config.WaveNPCDamageBase or 8
		if isMiniBoss then
			health *= 5
			damage *= 2
		end
		local model: Model? = nil
		pcall(function()
			model = _npcService.SpawnEnemy(nil, position, { Health = health, Damage = damage })
		end)
		if model then
			model:SetAttribute("WaveId", _wave)
			if isMiniBoss then
				model:SetAttribute("MiniBoss", true)
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.WalkSpeed = humanoid.WalkSpeed * 0.8
				end
			end
			return model
		end
		-- NPCService caps AI NPCs at 6: when it refuses, the fallback
		-- spawner keeps the wave at full strength instead of silently
		-- spawning a 6-NPC wave and calling it wave 24. v1.0.0 returned
		-- nil here, so every wave past the cap was short.
	end
	return spawnFallbackEnemy(position, isMiniBoss)
end

local function aliveCount(): number
	local count = 0
	local survivors: { Model } = {}
	for _, model in ipairs(_waveNPCs) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if model.Parent and humanoid and humanoid.Health > 0 then
			count += 1
			table.insert(survivors, model)
		end
	end
	_waveNPCs = survivors
	return count
end

local function broadcast()
	local bossActive = false
	local bossName: string? = nil
	if _bossService and type(_bossService.IsBossActive) == "function" then
		pcall(function()
			bossActive = _bossService.IsBossActive() == true
		end)
	end
	if bossActive and _bossService and type(_bossService.GetBossName) == "function" then
		pcall(function()
			bossName = _bossService.GetBossName()
		end)
	end
	fireAll(_names.WaveUpdate, {
		Wave = _wave,
		IsBossWave = _wave > 0 and _wave % (Config.BossEvery or 5) == 0,
		RemainingNPCs = aliveCount(),
		TotalNPCs = #_waveNPCs,
		NextWaveIn = 0,
		BossActive = bossActive,
		BossName = bossName,
	})
end

local function rewardWaveClear()
	local coins = Economy.CoinsForWave(_wave)
	local xp = Config.XPPerWave or 15
	for _, player in ipairs(Players:GetPlayers()) do
		if _dataService then
			pcall(function()
				_dataService.AddCoins(player, coins)
			end)
			addXP(player, xp)
		end
	end
	print(string.format("[WaveService] Wave %d cleared: +%d coins, +%d XP to all players", _wave, coins, xp))
end

local function tideActiveNow(): boolean
	if not _tideService or type(_tideService.IsTideActive) ~= "function" then
		return false
	end
	local ok, active = pcall(function()
		return _tideService.IsTideActive()
	end)
	return ok and active == true
end

local function runWaves(token: number)
	-- Grace period before wave 1 so players can join, buy and place.
	task.wait(30)
	while _running and token == _runToken do
		-- v1.1: never start a new wave mid-tide (see header).
		while _running and token == _runToken and tideActiveNow() do
			task.wait(2)
		end
		if not _running or token ~= _runToken then
			return
		end
		_wave += 1
		local isBossWave = _wave % (Config.BossEvery or 5) == 0
		local count = math.min(_wave + 2, Config.MaxWaveNPCs or 24)
		local center = arenaCenter()
		_waveNPCs = {}
		for i = 1, count do
			local pos = center + Vector3.new(math.random(-20, 20), 3, math.random(-20, 20))
			local model = spawnWaveNPC(pos, false)
			if model then
				table.insert(_waveNPCs, model)
			end
			task.wait(Config.WaveSpawnDelay or 1.5)
		end
		-- Boss waves add ONE mini-boss on top of the normal count.
		-- v1.0.0 ALSO made the first wave NPC a mini-boss (i == 1),
		-- so boss waves spawned two mini-bosses.
		if isBossWave then
			local bossModel = spawnWaveNPC(center, true)
			if bossModel then
				table.insert(_waveNPCs, bossModel)
			end
		end
		-- v1.1: every 10th wave ALSO summons a real boss (rotating the
		-- v1.1 bosses) when BossService is linked. SpawnBoss returns
		-- false when a boss is already live, so a boss tide and a
		-- boss wave can never double-spawn. Wave 20/40/... get THE
		-- VOID EMPEROR; other 10th waves get THE GLITCH COLOSSUS.
		if isBossWave and _wave % 10 == 0 and _bossService
			and type(_bossService.SpawnBoss) == "function" then
			local bossId = (_wave % 20 == 0) and "VoidEmperor" or "GlitchColossus"
			local ok, spawned = pcall(function()
				return _bossService.SpawnBoss(bossId)
			end)
			if ok and spawned then
				print(string.format("[WaveService] Wave %d summoned %s", _wave, bossId))
			end
		end
		broadcast()
		print(string.format("[WaveService] Wave %d started (%d NPCs%s)", _wave, #_waveNPCs, isBossWave and ", MINI-BOSS" or ""))
		-- Wait until the wave is cleared (poll every 2s).
		while _running and token == _runToken and aliveCount() > 0 do
			task.wait(2)
		end
		if not _running or token ~= _runToken then
			return
		end
		rewardWaveClear()
		broadcast()
		task.wait(Config.WaveInterval or 90)
	end
end

function WaveService.GetWave(): number
	return _wave
end

function WaveService.IsRunning(): boolean
	return _running
end

function WaveService.Start(): boolean
	if _running then
		return false
	end
	_running = true
	_runToken += 1
	local token = _runToken
	task.spawn(function()
		local ok, err = pcall(function()
			runWaves(token)
		end)
		if not ok then
			warn("[WaveService] Wave loop failed: " .. tostring(err))
			_running = false
		end
	end)
	return true
end

function WaveService.Stop()
	_running = false
	_runToken += 1
	for _, model in ipairs(_waveNPCs) do
		if model.Parent then
			model:Destroy()
		end
	end
	_waveNPCs = {}
end

function WaveService.SetNPCService(npcService: any)
	_npcService = npcService
end

-- SetBossService / SetTideService (v1.1): GameManager's wireCrossLinks
-- calls both automatically (shared setter table). Each validates the
-- interface before accepting, so an unlinked service is nil-safe.
function WaveService.SetBossService(bossService: any)
	if bossService and type(bossService.SpawnBoss) == "function" then
		_bossService = bossService
	end
end

function WaveService.SetTideService(tideService: any)
	if tideService and type(tideService.IsTideActive) == "function" then
		_tideService = tideService
	end
end

function WaveService.SetQuestService(questService: any)
	if questService and type(questService.RecordEvent) == "function" then
		_questService = questService
	end
end

function WaveService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function WaveService.Init(dataService: any, map: Instance?, npcService: any?)
	assert(dataService ~= nil, "[WaveService] Init requires DataService")
	_dataService = dataService
	_map = map
	_npcService = npcService
	-- Auto-start: v1.0.0 never called WaveService.Start() from anywhere,
	-- so no wave ever ran. Waves start 30s after Init (grace period in
	-- runWaves) and then loop on their own.
	WaveService.Start()
end

return WaveService
