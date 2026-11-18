--!strict
-- ExpeditionService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse (v1.1, Workstream C).
-- Timed expeditions, Part 6B: send an owned Brainrot away for a
-- fixed duration; claim real rewards on return. All expedition tunables
-- live in shared/ExpeditionDefs.luau.
--
-- RULES (server-authoritative): the instance must be owned, unplaced
-- and not already away; one active expedition per player. While away
-- the instance is flagged OnExpedition (the expedition API refuses to
-- start a second trip with it, and GetExpeditions reports it — the
-- Wave 3 UI must hide on-expedition instances from place / fuse /
-- mutate lists, because BaseService / MutationService / FusionService
-- were not edited by this workstream and do not read the flag; see
-- docs/QA_V11_C.md). RISK is a chance of REDUCED rewards on claim
-- (half coins / crystals, no gems / shards / discovery) — the
-- Brainrot NEVER gets lost. Rewards: coins (DataService.AddCoins),
-- gems / crystals / shards (direct field writes, audit §4f), XP
-- (ProgressionService.AddXP when linked, else DataService.AddXP),
-- and rare discoveries (a random UNOWNED Brainrot granted via
-- MutationService.CreateInstance + DataService.UnlockCharacter).
--
-- REMOTES (fired by STRING name; Remotes.luau is frozen for this
-- workstream — see docs/REMOTES_NEEDED_C.md):
--   RequestExpeditions (RemoteFunction): returns GetExpeditions.
--   StartExpedition (RemoteEvent): {InstanceId, ExpeditionId}.
--   ClaimExpedition (RemoteEvent): {ExpeditionId}.
--   ExpeditionUpdate (RemoteEvent broadcast): state push + claim result.
-- Existing broadcasts reused: SpawnEffect (positional), EventUpdate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local ExpeditionDefs = require(ReplicatedStorage:WaitForChild("ExpeditionDefs"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local ExpeditionService = {}

local _dataService: any = nil
local _mutationService: any = nil
local _questService: any = nil
local _achievementService: any = nil
local _progressionService: any = nil

local _rate: { [Player]: number } = {}

local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function rateOk(player: Player, key: string, interval: number): boolean
	if Security and Security.RateLimit then
		local ok, allowed = pcall(function()
			return Security.RateLimit(player, key, interval)
		end)
		if ok then
			return allowed
		end
	end
	local now = os.clock()
	local last = _rate[player] or -math.huge
	if now - last < interval then
		return false
	end
	_rate[player] = now
	return true
end

local function sanitize(id: any): string?
	if Security and Security.SanitizeId then
		local ok, clean = pcall(function()
			return Security.SanitizeId(id)
		end)
		if ok then
			return clean
		end
	end
	if type(id) ~= "string" or #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
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

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
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

local function ensureExpeditionData(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.Expeditions) ~= "table" then
		data.Expeditions = { Active = nil, Completed = 0 }
	end
	if type(data.Expeditions.Completed) ~= "number" then
		data.Expeditions.Completed = 0
	end
	return data
end

local function resolveMutationService(): any
	if _mutationService and type(_mutationService.FindInstance) == "function"
		and type(_mutationService.CreateInstance) == "function" then
		return _mutationService
	end
	_mutationService = nil
	pcall(function()
		local mod = script.Parent:FindFirstChild("MutationService")
		if mod then
			local candidate = require(mod)
			if type(candidate.FindInstance) == "function" then
				_mutationService = candidate
			end
		end
	end)
	return _mutationService
end

local function grantXP(player: Player, amount: number)
	if amount <= 0 then
		return
	end
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

-- resolveQuestService: lazy sibling require (same pattern as
-- resolveMutationService). GameManager cannot be edited by this
-- workstream, so expeditions wire their own progress funnel:
-- QuestService.ReportProgress is the single funnel to quests +
-- achievements + challenges.
local function resolveQuestService(): any
	if _questService and type(_questService.ReportProgress) == "function" then
		return _questService
	end
	_questService = nil
	pcall(function()
		local mod = script.Parent:FindFirstChild("QuestService")
		if mod then
			local candidate = require(mod)
			if type(candidate.ReportProgress) == "function" then
				_questService = candidate
			end
		end
	end)
	return _questService
end

local function reportProgress(player: Player, kind: string, id: string, amount: number)
	-- ReportProgress is the funnel: it advances quests AND forwards
	-- to achievements / challenges exactly once (QuestService
	-- EVENT_KIND_MAP). Do NOT also call CheckProgress here — that
	-- would double-count.
	local qs = _questService or resolveQuestService()
	if qs and type(qs.ReportProgress) == "function" then
		pcall(function()
			qs.ReportProgress(player, kind, id, amount)
		end)
	end
end

local function pushExpeditionUpdate(player: Player, extra: { [string]: any }?)
	local payload: { [string]: any } = {
		Action = "ExpeditionUpdate",
		State = ExpeditionService.GetExpeditions(player),
	}
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	fireClient("ExpeditionUpdate", player, payload)
end

-- Roll a random unowned Brainrot of at least `minRarity` (by rank).
-- Returns the character id, or nil when the player owns them all.
local function rollDiscovery(player: Player, minRarity: string?): string?
	local data = getData(player)
	if not data then
		return nil
	end
	local owned: { [string]: boolean } = {}
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			owned[tostring(id)] = true
		end
	end
	local minRank = 0
	if minRarity then
		minRank = Characters.GetRarityRank(minRarity)
	end
	local pool: { string } = {}
	for _, def in ipairs(Characters.GetAll()) do
		if not owned[def.Id] and Characters.GetRarityRank(def.Rarity) >= minRank then
			table.insert(pool, def.Id)
		end
	end
	if #pool == 0 then
		return nil
	end
	return pool[math.random(1, #pool)]
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- GetExpeditions(player): all expedition defs with eligibility, plus
-- the active expedition (with seconds remaining) and completed count.
function ExpeditionService.GetExpeditions(player: Player): { [string]: any }
	local data = ensureExpeditionData(player)
	if not data then
		return { Definitions = ExpeditionDefs.GetAll(), Active = nil, Completed = 0 }
	end
	local ms = resolveMutationService()
	local active = data.Expeditions.Active
	local activeOut: { [string]: any }? = nil
	if type(active) == "table" then
		local def = ExpeditionDefs.GetById(tostring(active.ExpeditionId))
		activeOut = {
			InstanceId = active.InstanceId,
			CharacterId = active.CharacterId,
			ExpeditionId = active.ExpeditionId,
			Name = def and def.Name or tostring(active.ExpeditionId),
			StartedAt = tonumber(active.StartedAt) or 0,
			EndsAt = tonumber(active.EndsAt) or 0,
			SecondsRemaining = math.max(0, (tonumber(active.EndsAt) or 0) - os.time()),
			Ready = os.time() >= (tonumber(active.EndsAt) or 0),
		}
	end
	-- Eligibility per def (for the UI): which owned instances qualify.
	local eligible: { [string]: { string } } = {}
	if ms then
		local ok, instances = pcall(function()
			return ms.GetInstances(player)
		end)
		if ok and type(instances) == "table" then
			for _, def in ipairs(ExpeditionDefs.GetAll()) do
				local list: { string } = {}
				for _, inst in ipairs(instances) do
					if type(inst) == "table" and inst.Placed ~= true and inst.OnExpedition ~= true then
						local charDef = Characters.GetById(inst.CharacterId)
						if charDef then
							local levelOk = (tonumber(inst.Level) or 1) >= def.MinLevel
							local rarityOk = Characters.GetRarityRank(charDef.Rarity) >= def.MinRarityRank
							local traitOk = true
							if def.MinTrait then
								traitOk = false
								if type(charDef.Traits) == "table" then
									for _, trait in ipairs(charDef.Traits) do
										if tostring(trait) == def.MinTrait then
											traitOk = true
											break
										end
									end
								end
							end
							if levelOk and rarityOk and traitOk then
								table.insert(list, inst.InstanceId)
							end
						end
					end
				end
				eligible[def.Id] = list
			end
		end
	end
	return {
		Definitions = ExpeditionDefs.GetAll(),
		Active = activeOut,
		Completed = tonumber(data.Expeditions.Completed) or 0,
		Eligible = eligible,
	}
end

-- StartExpedition(player, instanceId, expeditionId): send an owned,
-- unplaced Brainrot away. Returns (true, active) or (false, reason).
function ExpeditionService.StartExpedition(player: Player, instanceId: any, expeditionId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local cleanInst = sanitize(instanceId)
	local cleanExp = sanitize(expeditionId)
	if not cleanInst or not cleanExp then
		return false, "invalid id"
	end
	local def = ExpeditionDefs.GetById(cleanExp)
	if not def then
		return false, "unknown expedition"
	end
	local data = ensureExpeditionData(player)
	if not data then
		return false, "no data"
	end
	if type(data.Expeditions.Active) == "table" then
		return false, "an expedition is already underway"
	end
	local ms = resolveMutationService()
	if not ms then
		return false, "mutation service unavailable"
	end
	local inst = ms.FindInstance(player, cleanInst)
	if not inst then
		return false, "instance not owned"
	end
	if inst.Placed == true then
		return false, "instance must be unplaced (send from inventory)"
	end
	if inst.OnExpedition == true then
		return false, "instance is already on an expedition"
	end
	local charDef = Characters.GetById(inst.CharacterId)
	if not charDef then
		return false, "unknown character"
	end
	if (tonumber(inst.Level) or 1) < def.MinLevel then
		return false, "requires level " .. tostring(def.MinLevel)
	end
	if Characters.GetRarityRank(charDef.Rarity) < def.MinRarityRank then
		return false, "requires rarity rank " .. tostring(def.MinRarityRank)
	end
	if def.MinTrait then
		local hasTrait = false
		if type(charDef.Traits) == "table" then
			for _, trait in ipairs(charDef.Traits) do
				if tostring(trait) == def.MinTrait then
					hasTrait = true
					break
				end
			end
		end
		if not hasTrait then
			return false, "requires the " .. def.MinTrait .. " trait"
		end
	end
	local now = os.time()
	data.Expeditions.Active = {
		InstanceId = cleanInst,
		CharacterId = inst.CharacterId,
		ExpeditionId = cleanExp,
		StartedAt = now,
		EndsAt = now + def.DurationSeconds,
	}
	inst.OnExpedition = true
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	pushExpeditionUpdate(player, { Action = "ExpeditionStarted", ExpeditionId = cleanExp })
	print(string.format(
		"[ExpeditionService] %s sent %s (%s) on %s (%ds)",
		player.Name, cleanInst, tostring(inst.CharacterId), def.Name, def.DurationSeconds
	))
	return true, data.Expeditions.Active
end

-- ClaimExpedition(player, expeditionId): collect the rewards of a
-- finished expedition. Risk rolls reduced rewards; the Brainrot
-- always returns. Returns (true, rewards) or (false, reason).
function ExpeditionService.ClaimExpedition(player: Player, expeditionId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local cleanExp = sanitize(expeditionId)
	if not cleanExp then
		return false, "invalid id"
	end
	local data = ensureExpeditionData(player)
	if not data then
		return false, "no data"
	end
	local active = data.Expeditions.Active
	if type(active) ~= "table" or tostring(active.ExpeditionId) ~= cleanExp then
		return false, "no active expedition with that id"
	end
	local def = ExpeditionDefs.GetById(cleanExp)
	if not def then
		return false, "unknown expedition"
	end
	if os.time() < (tonumber(active.EndsAt) or 0) then
		return false, "expedition not finished yet"
	end
	local ms = resolveMutationService()
	local inst = ms and ms.FindInstance(player, tostring(active.InstanceId)) or nil

	-- Risk roll: reduced rewards, never loss of the Brainrot.
	local reduced = math.random() < def.Risk
	local coins = reduced and math.floor(def.RewardCoins / 2) or def.RewardCoins
	local crystals = reduced and math.floor(def.RewardCrystals / 2) or def.RewardCrystals
	local gems = reduced and 0 or def.RewardGems
	local shards = reduced and 0 or def.RewardShards
	local discoveryId: string? = nil
	if not reduced and def.DiscoveryChance > 0 and math.random() < def.DiscoveryChance then
		discoveryId = rollDiscovery(player, def.DiscoveryMinRarity)
	end

	pcall(function()
		_dataService.AddCoins(player, coins)
	end)
	data.Gems = (tonumber(data.Gems) or 0) + gems
	data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + crystals
	data.ChaosShards = (tonumber(data.ChaosShards) or 0) + shards
	grantXP(player, def.RewardXP)
	if discoveryId and ms then
		pcall(function()
			ms.CreateInstance(player, discoveryId, 1, nil)
		end)
		pcall(function()
			_dataService.UnlockCharacter(player, discoveryId)
		end)
		if _progressionService and type(_progressionService.RecordDiscovery) == "function" then
			pcall(function()
				_progressionService.RecordDiscovery(player, discoveryId)
			end)
		end
	end
	-- The Brainrot comes home, whatever happened out there.
	if inst then
		inst.OnExpedition = nil
		if _progressionService and type(_progressionService.AwardMastery) == "function" then
			pcall(function()
				_progressionService.AwardMastery(player, inst.CharacterId, def.MasteryXP)
			end)
		end
	end
	data.Expeditions.Active = nil
	data.Expeditions.Completed = (tonumber(data.Expeditions.Completed) or 0) + 1
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	local rewards = {
		Coins = coins,
		Gems = gems,
		MutationCrystals = crystals,
		ChaosShards = shards,
		XP = def.RewardXP,
		Reduced = reduced,
		DiscoveredCharacterId = discoveryId,
		CharacterId = active.CharacterId,
	}
	fireClient("EventUpdate", player, {
		EventId = "ExpeditionComplete",
		Name = player.Name .. "'s expedition returned"
			.. (reduced and " (reduced haul — the trip went sideways)" or " with a full haul!")
			.. (discoveryId and (" Discovered: " .. discoveryId) or ""),
		Phase = "Started",
		Duration = 6,
	})
	reportProgress(player, "expedition", "complete", 1)
	pushExpeditionUpdate(player, { Action = "ExpeditionClaimed", Rewards = rewards })
	print(string.format(
		"[ExpeditionService] %s claimed %s: +%d coins, +%d gems, +%d crystals, +%d shards%s%s",
		player.Name, cleanExp, coins, gems, crystals, shards,
		reduced and " (REDUCED)" or "",
		discoveryId and (" discovered " .. discoveryId) or ""
	))
	return true, rewards
end

-- ---------------------------------------------------------------------------
-- Setters
-- ---------------------------------------------------------------------------

function ExpeditionService.SetQuestService(questService: any)
	if questService and type(questService.ReportProgress) == "function" then
		_questService = questService
	end
end

function ExpeditionService.SetAchievementService(achievementService: any)
	if achievementService and type(achievementService.CheckProgress) == "function" then
		_achievementService = achievementService
	end
end

function ExpeditionService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function ExpeditionService.SetMutationService(mutationService: any)
	if mutationService and type(mutationService.FindInstance) == "function" then
		_mutationService = mutationService
	end
end

local function onStartRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	if not rateOk(player, "StartExpedition", 1) then
		return
	end
	local ok, err = ExpeditionService.StartExpedition(player, payload.InstanceId, payload.ExpeditionId)
	if not ok then
		warn("[ExpeditionService] Start failed for " .. player.Name .. ": " .. tostring(err))
	end
end

local function onClaimRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	if not rateOk(player, "ClaimExpedition", 1) then
		return
	end
	local ok, err = ExpeditionService.ClaimExpedition(player, payload.ExpeditionId)
	if not ok then
		warn("[ExpeditionService] Claim failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function ExpeditionService.Init(dataService: any?)
	assert(dataService ~= nil, "[ExpeditionService] Init requires DataService")
	_dataService = dataService
	resolveMutationService()
	resolveQuestService()

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote("StartExpedition")
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onStartRemote)
		else
			warn("[ExpeditionService] Remote not found, start handler not wired: StartExpedition")
		end
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote("ClaimExpedition")
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onClaimRemote)
		else
			warn("[ExpeditionService] Remote not found, claim handler not wired: ClaimExpedition")
		end
	end)

	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction("RequestExpeditions")
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(player: Player)
				return ExpeditionService.GetExpeditions(player)
			end
		else
			warn("[ExpeditionService] RemoteFunction not found, RequestExpeditions not wired")
		end
	end)
end

return ExpeditionService
