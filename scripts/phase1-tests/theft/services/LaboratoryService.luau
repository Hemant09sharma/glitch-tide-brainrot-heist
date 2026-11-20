--!strict
-- LaboratoryService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse (v1.1, Workstream C).
-- The Mutation Lab, Part 6A: mutate / fuse (delegated to the existing
-- MutationService / FusionService — this file never re-implements
-- their validation), EVOLVE (new), trait upgrades, secret recipes
-- (gated by SecretService discovery flags) and alternate forms.
--
-- EVOLUTION (the new system): a MAX-LEVEL (5) unplaced Brainrot +
-- coins + Mutation Crystals becomes an EVOLVED form of the same
-- character: same CharacterId, level 5, Evolved flag, a new trait
-- (first valid trait the base character lacks), and its mutation
-- upgraded to the best compatible mutation — the income boost flows
-- through the existing Economy.IncomePerSecond path, so no income
-- math was touched. A discovered secret recipe (see LabDefs) gives
-- the evolution a named form, a fixed bonus mutation and extra gems.
-- Visual feedback: a temporary model is built at the player's
-- position, CharacterModels.PlayTransformEffect plays the burst +
-- flash, plus a positional SpawnEffect ring/flash and an EventUpdate
-- banner (the positional SpawnEffect form is the one
-- EffectsController handles).
--
-- REMOTES (fired by STRING name; Remotes.luau is frozen for this
-- workstream — see docs/REMOTES_NEEDED_C.md):
--   RequestLab (RemoteFunction): returns GetLabState.
--   EvolveBrainrot (RemoteEvent): Action envelope —
--     {Action="Evolve", InstanceId}, {Action="UpgradeTrait",
--     InstanceId, TraitId}, {Action="DiscoverRecipe", RecipeId},
--     {Action="AlternateForm", InstanceId}.
--   LabUpdate (RemoteEvent broadcast): state push after any change.
-- Existing broadcasts reused: SpawnEffect (positional), EventUpdate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Characters = require("../shared/Characters")
local LabDefs = require("../shared/LabDefs")
local Remotes = require("../shared/Remotes")

local _names: any = Remotes.Names

local LaboratoryService = {}

local _dataService: any = nil
local _mutationService: any = nil
local _fusionService: any = nil
local _questService: any = nil
local _achievementService: any = nil
local _progressionService: any = nil
local _secretService: any = nil

local _rate: { [Player]: number } = {}

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

local function ensureLabData(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.LabDiscoveries) ~= "table" then
		data.LabDiscoveries = {}
	end
	return data
end


-- R4-3: spendable balance — the raw balance minus any reservation
-- held for a pending reward commit (DataService.ReserveCoins).
-- Falls back to the raw balance when the DataService has no
-- reservation API (older stub). Debits below go through
-- DataService.AddCoins, which enforces the same floor as a
-- backstop, so a reserved reward credit can never be spent here
-- while its commit's save is in flight.
local function spendableCoins(player: Player, data: any): number
	local coins = tonumber(data.Coins) or 0
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, value = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(value) == "number" then
			return value
		end
	end
	return coins
end

-- resolveMutationService: prefer the injected service, else require
-- the sibling module (same pattern as FusionService — GameManager's
-- generic Init can pass the wrong positional argument).
local function resolveMutationService(): any
	if _mutationService and type(_mutationService.FindInstance) == "function"
		and type(_mutationService.GetInstances) == "function" then
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

local function resolveSecretService(): any
	if _secretService and type(_secretService.IsDiscovered) == "function" then
		return _secretService
	end
	_secretService = nil
	pcall(function()
		local mod = script.Parent:FindFirstChild("SecretService")
		if mod then
			local candidate = require(mod)
			if type(candidate.IsDiscovered) == "function" then
				_secretService = candidate
			end
		end
	end)
	return _secretService
end

-- resolveQuestService / resolveAchievementService: lazy sibling
-- requires (same pattern as resolveMutationService). GameManager
-- cannot be edited by this workstream, so the lab wires its own
-- progress funnel: QuestService.ReportProgress is the single funnel
-- to quests + achievements + challenges.
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

local function pushLabUpdate(player: Player)
	fireClient("LabUpdate", player, {
		Action = "LabUpdate",
		State = LaboratoryService.GetLabState(player),
	})
end

local function playEvolveEffect(player: Player, characterId: string)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position: Vector3? = nil
	if root and root:IsA("BasePart") then
		position = root.Position
	end
	if position == nil then
		return
	end
	-- Temporary display model at the player's feet: the real
	-- transform burst + flash, then it cleans itself up.
	if _characterModels and type(_characterModels.Build) == "function" then
		pcall(function()
			local def = Characters.GetById(characterId)
			if not def then
				return
			end
			local model = _characterModels.Build(def, workspace)
			if typeof(model) == "Instance" and model:IsA("Model") then
				pcall(function()
					model:PivotTo(CFrame.new(position + Vector3.new(0, 2, 0)))
				end)
				if type(_characterModels.PlayTransformEffect) == "function" then
					pcall(function()
						_characterModels.PlayTransformEffect(model, "Evolution")
					end)
				end
				local Debris = game:GetService("Debris")
				Debris:AddItem(model, 5)
			end
		end)
	end
	local effectRemote = getRemote(_names.SpawnEffect)
	if effectRemote then
		pcall(function()
			effectRemote:FireClient(player, "ring", position, { radius = 8, color = Color3.fromRGB(255, 120, 220) })
			effectRemote:FireClient(player, "flash", position, Color3.fromRGB(255, 120, 220))
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- GetLabState(player): evolvable instances, evolved instances, trait
-- levels, discovered recipes and the lab cost tables (for the UI).
function LaboratoryService.GetLabState(player: Player): { [string]: any }
	local data = ensureLabData(player)
	if not data then
		return { Evolvable = {}, Evolved = {}, DiscoveredRecipes = {}, EvolveCosts = {} }
	end
	local ms = resolveMutationService()
	local instances: { any } = {}
	if ms then
		local ok, list = pcall(function()
			return ms.GetInstances(player)
		end)
		if ok and type(list) == "table" then
			instances = list
		end
	end
	local maxLevel = LabDefs.GetMaxLevel()
	local evolvable: { { [string]: any } } = {}
	local evolved: { { [string]: any } } = {}
	for _, inst in ipairs(instances) do
		if type(inst) == "table" then
			local def = Characters.GetById(inst.CharacterId)
			-- Annotated as {[string]: any} (not a sealed literal):
			-- the entry is inserted into the {[string]: any} lists
			-- below, and strict-mode table inference rejects the
			-- sealed literal there.
			local entry: { [string]: any } = {
				InstanceId = inst.InstanceId,
				CharacterId = inst.CharacterId,
				Name = def and def.DisplayName or tostring(inst.CharacterId),
				Rarity = def and def.Rarity or "Common",
				Level = tonumber(inst.Level) or 1,
				Mutation = inst.Mutation,
				Placed = inst.Placed == true,
				Evolved = inst.Evolved == true,
				EvolvedTrait = inst.EvolvedTrait,
				EvolvedFormName = inst.EvolvedFormName,
				TraitLevels = inst.TraitLevels,
				AlternateForm = LabDefs.GetAlternateForm(inst.CharacterId),
			}
			if inst.Evolved == true then
				table.insert(evolved, entry)
			elseif (tonumber(inst.Level) or 1) >= maxLevel and inst.Placed ~= true then
				table.insert(evolvable, entry)
			end
		end
	end
	local discovered: { string } = {}
	for recipeId, found in pairs(data.LabDiscoveries) do
		if found == true then
			table.insert(discovered, recipeId)
		end
	end
	table.sort(discovered)
	return {
		Evolvable = evolvable,
		Evolved = evolved,
		DiscoveredRecipes = discovered,
		MaxLevel = maxLevel,
	}
end

-- EvolveBrainrot(player, instanceId): max-level unplaced instance +
-- coins + crystals -> evolved form. Returns (true, instance) or
-- (false, reason).
function LaboratoryService.EvolveBrainrot(player: Player, instanceId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(instanceId)
	if not clean then
		return false, "invalid instance id"
	end
	local ms = resolveMutationService()
	if not ms then
		return false, "mutation service unavailable"
	end
	local inst = ms.FindInstance(player, clean)
	if not inst then
		return false, "instance not owned"
	end
	if inst.Placed == true then
		return false, "instance must be unplaced (evolve from inventory)"
	end
	-- Theft / expedition integrity: a stolen in-transit instance or
	-- an instance away on an expedition must not be evolved.
	if inst.InTransit == true then
		return false, "instance is in transit (stolen)"
	end
	if inst.OnExpedition == true then
		return false, "instance is on an expedition"
	end
	if inst.Evolved == true then
		return false, "already evolved"
	end
	local level = tonumber(inst.Level) or 1
	local maxLevel = LabDefs.GetMaxLevel()
	if level < maxLevel then
		return false, "requires max level " .. tostring(maxLevel) .. " (currently " .. tostring(level) .. ")"
	end
	local def = Characters.GetById(inst.CharacterId)
	if not def then
		return false, "unknown character"
	end
	local data = ensureLabData(player)
	if not data then
		return false, "no data"
	end
	local cost = LabDefs.GetEvolveCost(def.Rarity)
	local coins = spendableCoins(player, data)
	local crystals = tonumber(data.MutationCrystals) or 0
	if coins < cost.Coins then
		return false, "not enough coins (" .. tostring(cost.Coins) .. " needed)"
	end
	if crystals < cost.MutationCrystals then
		return false, "not enough Mutation Crystals (" .. tostring(cost.MutationCrystals) .. " needed)"
	end

	-- Secret recipe: a discovered recipe for this character replaces
	-- the generic evolved form with a named form + fixed bonus
	-- mutation + extra gems.
	local secretRecipe = LabDefs.GetSecretRecipeForCharacter(inst.CharacterId)
	local useRecipe: any = nil
	if secretRecipe and data.LabDiscoveries[secretRecipe.Id] == true then
		useRecipe = secretRecipe
	end

	_dataService.AddCoins(player, -cost.Coins)
	data.MutationCrystals = crystals - cost.MutationCrystals
	inst.Evolved = true
	inst.EvolutionId = useRecipe and useRecipe.Id or ("evolved_" .. tostring(inst.CharacterId))
	inst.EvolvedTrait = LabDefs.GetEvolvedTrait(inst.CharacterId)
	inst.EvolvedFormName = useRecipe and useRecipe.FormName or (def.DisplayName .. " (Evolved)")
	-- Income boost: upgrade the mutation to the best compatible one
	-- (or the recipe's fixed bonus mutation). The multiplier flows
	-- through Economy.IncomePerSecond with no income-math edit.
	local Mutations = require("../shared/Mutations")
	local currentMult = Mutations.GetMultiplier(inst.Mutation)
	local bestId = useRecipe and useRecipe.BonusMutation or LabDefs.GetBestMutationFor(inst.CharacterId)
	if bestId then
		local bestMult = Mutations.GetMultiplier(bestId)
		if bestMult > currentMult and ms.CanMutate(inst.CharacterId, bestId) then
			inst.Mutation = string.lower(bestId)
		end
	end
	local gems = cost.Gems + (useRecipe and useRecipe.BonusGems or 0)
	data.Gems = (tonumber(data.Gems) or 0) + gems
	grantXP(player, cost.XP)
	if _progressionService and type(_progressionService.AwardMastery) == "function" then
		pcall(function()
			_progressionService.AwardMastery(player, inst.CharacterId, 100)
		end)
	end
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	playEvolveEffect(player, inst.CharacterId)
	fireClient("EventUpdate", player, {
		EventId = "Evolution",
		Name = player.Name .. " evolved " .. tostring(inst.EvolvedFormName) .. "!",
		Phase = "Started",
		Duration = 6,
	})
	reportProgress(player, "evolution", "evolve", 1)
	pushLabUpdate(player)
	print(string.format(
		"[LaboratoryService] %s evolved %s (%s) -> %s",
		player.Name, clean, tostring(inst.CharacterId), tostring(inst.EvolvedFormName)
	))
	return true, inst
end

-- UpgradeTrait(player, instanceId, traitId): raise one of the
-- character's own traits by one level (max 3). Level 3 also
-- glitch-infuses the instance (Glitched = true, x2 income through
-- the existing Economy path). Returns (true, level) or (false, reason).
function LaboratoryService.UpgradeTrait(player: Player, instanceId: any, traitId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local cleanInst = sanitize(instanceId)
	local cleanTrait = sanitize(traitId)
	if not cleanInst or not cleanTrait then
		return false, "invalid id"
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
		return false, "instance must be unplaced (upgrade from inventory)"
	end
	-- Theft / expedition integrity: a stolen in-transit instance or
	-- an instance away on an expedition must not gain trait levels.
	if inst.InTransit == true then
		return false, "instance is in transit (stolen)"
	end
	if inst.OnExpedition == true then
		return false, "instance is on an expedition"
	end
	local def = Characters.GetById(inst.CharacterId)
	if not def then
		return false, "unknown character"
	end
	local hasTrait = false
	if type(def.Traits) == "table" then
		for _, trait in ipairs(def.Traits) do
			if tostring(trait) == cleanTrait then
				hasTrait = true
				break
			end
		end
	end
	if not hasTrait then
		return false, "character does not have the trait " .. cleanTrait
	end
	if type(inst.TraitLevels) ~= "table" then
		inst.TraitLevels = {}
	end
	local current = math.floor(tonumber(inst.TraitLevels[cleanTrait]) or 0)
	if current >= LabDefs.TRAIT_MAX_LEVEL then
		return false, "trait already at max level " .. tostring(LabDefs.TRAIT_MAX_LEVEL)
	end
	local nextLevel = current + 1
	local cost = LabDefs.GetTraitUpgradeCost(nextLevel)
	if not cost then
		return false, "invalid trait level"
	end
	local data = ensureLabData(player)
	if not data then
		return false, "no data"
	end
	local coins = spendableCoins(player, data)
	local crystals = tonumber(data.MutationCrystals) or 0
	if coins < cost.Coins then
		return false, "not enough coins (" .. tostring(cost.Coins) .. " needed)"
	end
	if crystals < cost.MutationCrystals then
		return false, "not enough Mutation Crystals (" .. tostring(cost.MutationCrystals) .. " needed)"
	end
	_dataService.AddCoins(player, -cost.Coins)
	data.MutationCrystals = crystals - cost.MutationCrystals
	inst.TraitLevels[cleanTrait] = nextLevel
	if nextLevel >= LabDefs.TRAIT_MAX_LEVEL then
		inst.Glitched = true
	end
	data.Gems = (tonumber(data.Gems) or 0) + cost.Gems
	grantXP(player, cost.XP)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	reportProgress(player, "trait", "upgrade", 1)
	pushLabUpdate(player)
	print(string.format(
		"[LaboratoryService] %s upgraded trait %s on %s to level %d",
		player.Name, cleanTrait, cleanInst, nextLevel
	))
	return true, nextLevel
end

-- DiscoverRecipe(player, recipeId): reveal a secret lab recipe. The
-- recipe's required secret must already be discovered via
-- SecretService — undiscovered secrets can never unlock a recipe.
-- Returns (true, recipe) or (false, reason).
function LaboratoryService.DiscoverRecipe(player: Player, recipeId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(recipeId)
	if not clean then
		return false, "invalid recipe id"
	end
	local recipe = LabDefs.GetSecretRecipe(clean)
	if not recipe then
		return false, "unknown recipe"
	end
	local data = ensureLabData(player)
	if not data then
		return false, "no data"
	end
	if data.LabDiscoveries[clean] == true then
		return false, "recipe already discovered"
	end
	local secrets = resolveSecretService()
	if not secrets then
		return false, "secret service unavailable"
	end
	local ok, discovered = pcall(function()
		return secrets.IsDiscovered(player, recipe.RequiresSecret)
	end)
	if not ok or discovered ~= true then
		return false, "requires discovering the secret first: " .. recipe.RequiresSecret
	end
	data.LabDiscoveries[clean] = true
	grantXP(player, 50)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient("EventUpdate", player, {
		EventId = "RecipeDiscovered",
		Name = player.Name .. " discovered a secret recipe: " .. recipe.FormName .. "!",
		Phase = "Started",
		Duration = 6,
	})
	reportProgress(player, "secret", "recipe", 1)
	pushLabUpdate(player)
	print(string.format(
		"[LaboratoryService] %s discovered recipe %s (%s)",
		player.Name, clean, recipe.FormName
	))
	return true, recipe
end

-- SwitchAlternateForm(player, instanceId): swap the instance to its
-- same-rarity alternate form (LabDefs), keeping level and mutation.
-- Returns (true, newCharacterId) or (false, reason).
function LaboratoryService.SwitchAlternateForm(player: Player, instanceId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(instanceId)
	if not clean then
		return false, "invalid instance id"
	end
	local ms = resolveMutationService()
	if not ms then
		return false, "mutation service unavailable"
	end
	local inst = ms.FindInstance(player, clean)
	if not inst then
		return false, "instance not owned"
	end
	if inst.Placed == true then
		return false, "instance must be unplaced (swap from inventory)"
	end
	-- Theft / expedition integrity: a stolen in-transit instance or
	-- an instance away on an expedition must not change form.
	if inst.InTransit == true then
		return false, "instance is in transit (stolen)"
	end
	if inst.OnExpedition == true then
		return false, "instance is on an expedition"
	end
	if inst.Evolved == true then
		return false, "evolved Brainrots cannot change form"
	end
	local alternate = LabDefs.GetAlternateForm(inst.CharacterId)
	if not alternate or not Characters.GetById(alternate) then
		return false, "no alternate form for this Brainrot"
	end
	-- The new form must accept the instance's current mutation, or
	-- the mutation is dropped (never stored invalid — same rule as
	-- MutationService.CreateInstance).
	if inst.Mutation ~= nil and not ms.CanMutate(alternate, tostring(inst.Mutation)) then
		inst.Mutation = nil
	end
	local data = ensureLabData(player)
	if not data then
		return false, "no data"
	end
	local cost = LabDefs.AlternateFormCost
	local coins = spendableCoins(player, data)
	local crystals = tonumber(data.MutationCrystals) or 0
	if coins < cost.Coins then
		return false, "not enough coins (" .. tostring(cost.Coins) .. " needed)"
	end
	if crystals < cost.MutationCrystals then
		return false, "not enough Mutation Crystals (" .. tostring(cost.MutationCrystals) .. " needed)"
	end
	_dataService.AddCoins(player, -cost.Coins)
	data.MutationCrystals = crystals - cost.MutationCrystals
	local oldId = inst.CharacterId
	inst.CharacterId = alternate
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	playEvolveEffect(player, alternate)
	reportProgress(player, "trait", "alternate_form", 1)
	pushLabUpdate(player)
	print(string.format(
		"[LaboratoryService] %s switched %s (%s) to alternate form %s",
		player.Name, clean, oldId, alternate
	))
	return true, alternate
end

-- MutateBrainrot / FuseBrainrot: thin pass-throughs to the owning
-- services (the lab UI calls one remote; the validation and economy
-- stay in MutationService / FusionService).
function LaboratoryService.MutateBrainrot(player: Player, instanceId: any, mutationId: any): (boolean, any)
	local ms = resolveMutationService()
	if not ms or type(ms.MutateBrainrot) ~= "function" then
		return false, "mutation service unavailable"
	end
	return ms.MutateBrainrot(player, instanceId, mutationId)
end

function LaboratoryService.FuseBrainrot(player: Player, instanceIdA: any, instanceIdB: any): (boolean, any, string?)
	local fs = _fusionService
	if not (fs and type(fs.FuseBrainrot) == "function") then
		pcall(function()
			local mod = script.Parent:FindFirstChild("FusionService")
			if mod then
				local candidate = require(mod)
				if type(candidate.FuseBrainrot) == "function" then
					_fusionService = candidate
					fs = candidate
				end
			end
		end)
	end
	if not fs then
		return false, "fusion service unavailable", nil
	end
	return fs.FuseBrainrot(player, instanceIdA, instanceIdB)
end

-- ---------------------------------------------------------------------------
-- Setters
-- ---------------------------------------------------------------------------

function LaboratoryService.SetQuestService(questService: any)
	if questService and type(questService.ReportProgress) == "function" then
		_questService = questService
	end
end

function LaboratoryService.SetAchievementService(achievementService: any)
	if achievementService and type(achievementService.CheckProgress) == "function" then
		_achievementService = achievementService
	end
end

function LaboratoryService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

function LaboratoryService.SetSecretService(secretService: any)
	if secretService and type(secretService.IsDiscovered) == "function" then
		_secretService = secretService
	end
end

function LaboratoryService.SetMutationService(mutationService: any)
	if mutationService and type(mutationService.FindInstance) == "function" then
		_mutationService = mutationService
	end
end

function LaboratoryService.SetFusionService(fusionService: any)
	if fusionService and type(fusionService.FuseBrainrot) == "function" then
		_fusionService = fusionService
	end
end

local function onLabRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	if not rateOk(player, "EvolveBrainrot", 1) then
		return
	end
	local action = payload.Action
	if action == "Evolve" then
		local ok, err = LaboratoryService.EvolveBrainrot(player, payload.InstanceId)
		if not ok then
			warn("[LaboratoryService] Evolve failed for " .. player.Name .. ": " .. tostring(err))
		end
	elseif action == "UpgradeTrait" then
		local ok, err = LaboratoryService.UpgradeTrait(player, payload.InstanceId, payload.TraitId)
		if not ok then
			warn("[LaboratoryService] UpgradeTrait failed for " .. player.Name .. ": " .. tostring(err))
		end
	elseif action == "DiscoverRecipe" then
		local ok, err = LaboratoryService.DiscoverRecipe(player, payload.RecipeId)
		if not ok then
			warn("[LaboratoryService] DiscoverRecipe failed for " .. player.Name .. ": " .. tostring(err))
		end
	elseif action == "AlternateForm" then
		local ok, err = LaboratoryService.SwitchAlternateForm(player, payload.InstanceId)
		if not ok then
			warn("[LaboratoryService] AlternateForm failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
end

function LaboratoryService.Init(dataService: any?, mutationService: any?, fusionService: any?)
	assert(dataService ~= nil, "[LaboratoryService] Init requires DataService")
	_dataService = dataService
	if mutationService and type(mutationService.FindInstance) == "function" then
		_mutationService = mutationService
	end
	if fusionService and type(fusionService.FuseBrainrot) == "function" then
		_fusionService = fusionService
	end
	resolveMutationService()
	resolveQuestService()

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote("EvolveBrainrot")
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onLabRemote)
		else
			warn("[LaboratoryService] Remote not found, lab handler not wired: EvolveBrainrot")
		end
	end)

	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction("RequestLab")
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(player: Player)
				return LaboratoryService.GetLabState(player)
			end
		else
			warn("[LaboratoryService] RemoteFunction not found, RequestLab not wired")
		end
	end)
end

return LaboratoryService
