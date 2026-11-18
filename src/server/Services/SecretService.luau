--!strict
-- SecretService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse (v1.1, Workstream C).
-- Hidden secrets, Part 6E: hidden combinations, a hidden merchant,
-- a puzzle room, rare world events and secret creature appearances.
--
-- SECRECY RULE: secrets are NEVER listed in any UI-facing state.
-- There is no GetSecrets / RequestSecrets listing — only
-- DiscoverSecret (validates the condition server-side at call time),
-- IsDiscovered (one id at a time, for the lab / quest wiring) and the
-- GetSecretEncounter passthrough. Discovery broadcasts say only that
-- *a* secret was found, never which one. The secret ids, positions
-- and conditions below are server-only knowledge.
--
-- THE FIVE SECRETS:
--   rift_whisper    — stand in the Forbidden Rift while a Glitch
--                     Tide is Active. (Unlocks lab recipe
--                     recipe_void_heart.)
--   hidden_merchant — the Mysterious Merchant appears at the Rift
--                     when a tide rolls a HiddenMerchant secret
--                     encounter (TideService.GetSecretEncounter);
--                     stand near him to discover him. Spawned via
--                     NPCService.SpawnQuestGiver (the audit found it
--                     has no callers; this is its first).
--   puzzle_room     — touch all three hidden runes around the
--                     Forbidden Rift. (Unlocks lab recipe
--                     recipe_drowned_king.)
--   secret_sighting — be in the Forbidden Rift when a tide rolls a
--                     SecretSighting encounter.
--   skyfall_summit  — stand on the Skyfall summit island.
--                     (Unlocks lab recipe recipe_starfall_quokka.)
--
-- REMOTES (fired by STRING name; Remotes.luau is frozen for this
-- workstream — see docs/REMOTES_NEEDED_C.md):
--   SecretDiscovered (RemoteEvent broadcast to the discovering
--     player): {Action="SecretDiscovered"} — no secret id or name.
-- Existing broadcasts reused: EventUpdate (anonymous announcement),
-- SpawnEffect (positional).
-- No RequestSecrets remote is fired or requested: listing secrets
-- would defeat the point (see docs/REMOTES_NEEDED_C.md).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local SecretService = {}

local _dataService: any = nil
local _npcService: any = nil
local _tideService: any = nil
local _questService: any = nil
local _achievementService: any = nil
local _progressionService: any = nil

-- Server-only secret positions (never sent to clients).
local RIFT_CENTER = Vector3.new(-150, 3, -150)
local RIFT_RADIUS = 15
local SUMMIT_POSITION = Vector3.new(150, 57, -176)
local SUMMIT_RADIUS = 6
local MERCHANT_POSITION = Vector3.new(-150, 3, -138)
local MERCHANT_RADIUS = 12
local RUNE_POSITIONS: { { Name: string, Position: Vector3 } } = {
	{ Name = "SecretRune1", Position = Vector3.new(-158, 1, -142) },
	{ Name = "SecretRune2", Position = Vector3.new(-142, 1, -142) },
	{ Name = "SecretRune3", Position = Vector3.new(-150, 1, -158) },
}

export type SecretDef = {
	Id: string,
	RewardCoins: number,
	RewardGems: number,
	RewardXP: number,
	RewardCrystals: number,
	RewardShards: number,
}

-- Rewards only — names / hints are deliberately NOT stored here in a
-- listable form; the ids above are the only keys.
local SECRETS: { [string]: SecretDef } = {
	rift_whisper = { Id = "rift_whisper", RewardCoins = 500, RewardGems = 15, RewardXP = 150, RewardCrystals = 0, RewardShards = 1 },
	hidden_merchant = { Id = "hidden_merchant", RewardCoins = 1000, RewardGems = 25, RewardXP = 250, RewardCrystals = 25, RewardShards = 0 },
	puzzle_room = { Id = "puzzle_room", RewardCoins = 1000, RewardGems = 25, RewardXP = 250, RewardCrystals = 0, RewardShards = 2 },
	secret_sighting = { Id = "secret_sighting", RewardCoins = 500, RewardGems = 10, RewardXP = 150, RewardCrystals = 0, RewardShards = 1 },
	skyfall_summit = { Id = "skyfall_summit", RewardCoins = 750, RewardGems = 15, RewardXP = 200, RewardCrystals = 0, RewardShards = 1 },
}

-- SECRET_IDS: the only public list — ids, no names, no hints, no
-- positions. The lab reads RequiresSecret ids from LabDefs against
-- this set; nothing listable is ever sent to a client.
SecretService.SECRET_IDS = { "rift_whisper", "hidden_merchant", "puzzle_room", "secret_sighting", "skyfall_summit" }

local _merchantModel: Model? = nil
local _merchantExpiresAt = 0
local _merchantEncounterKey: string? = nil
local _runeTouchedAt: { [Player]: { [string]: number } } = {}
local _running = false

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

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
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

local function ensureSecretData(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.SecretDiscoveries) ~= "table" then
		data.SecretDiscoveries = {}
	end
	if type(data.SecretRunes) ~= "table" then
		data.SecretRunes = {}
	end
	return data
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getSecretEncounter(): { Kind: string, Variation: string }?
	if _tideService and type(_tideService.GetSecretEncounter) == "function" then
		local ok, encounter = pcall(function()
			return _tideService.GetSecretEncounter()
		end)
		if ok and type(encounter) == "table" then
			return encounter
		end
	end
	return nil
end

local function isTideActive(): boolean
	if _tideService and type(_tideService.IsTideActive) == "function" then
		local ok, active = pcall(function()
			return _tideService.IsTideActive()
		end)
		if ok then
			return active == true
		end
	end
	return false
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

-- checkCondition(player, secretId): is the secret's condition true
-- RIGHT NOW for this player (server-side re-check — a client firing
-- DiscoverSecret can never fake it).
local function checkCondition(player: Player, secretId: string): boolean
	local root = getRoot(player)
	if not root then
		return false
	end
	local pos = root.Position
	if secretId == "rift_whisper" then
		return isTideActive() and (pos - RIFT_CENTER).Magnitude <= RIFT_RADIUS
	elseif secretId == "skyfall_summit" then
		return (pos - SUMMIT_POSITION).Magnitude <= SUMMIT_RADIUS
	elseif secretId == "secret_sighting" then
		local encounter = getSecretEncounter()
		return encounter ~= nil and encounter.Kind == "SecretSighting"
			and (pos - RIFT_CENTER).Magnitude <= RIFT_RADIUS
	elseif secretId == "hidden_merchant" then
		if _merchantModel == nil or _merchantModel.Parent == nil then
			return false
		end
		local primary = _merchantModel.PrimaryPart
		if primary == nil then
			return false
		end
		return (pos - primary.Position).Magnitude <= MERCHANT_RADIUS
	elseif secretId == "puzzle_room" then
		local data = getData(player)
		if not data or type(data.SecretRunes) ~= "table" then
			return false
		end
		for _, rune in ipairs(RUNE_POSITIONS) do
			if data.SecretRunes[rune.Name] ~= true then
				return false
			end
		end
		return true
	end
	return false
end

-- discover(player, secretId): pay the reward + broadcast. Assumes the
-- condition was already checked. Returns true when newly discovered.
local function discover(player: Player, secretId: string): boolean
	local def = SECRETS[secretId]
	if not def then
		return false
	end
	local data = ensureSecretData(player)
	if not data then
		return false
	end
	if data.SecretDiscoveries[secretId] == true then
		return false
	end
	data.SecretDiscoveries[secretId] = true
	pcall(function()
		_dataService.AddCoins(player, def.RewardCoins)
	end)
	data.Gems = (tonumber(data.Gems) or 0) + def.RewardGems
	data.MutationCrystals = (tonumber(data.MutationCrystals) or 0) + def.RewardCrystals
	data.ChaosShards = (tonumber(data.ChaosShards) or 0) + def.RewardShards
	grantXP(player, def.RewardXP)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	-- Broadcasts never name the secret.
	fireClient("SecretDiscovered", player, { Action = "SecretDiscovered" })
	fireAll("EventUpdate", {
		EventId = "SecretDiscovered",
		Name = player.Name .. " discovered a hidden secret!",
		Phase = "Started",
		Duration = 6,
	})
	local effectRemote = getRemote(_names.SpawnEffect)
	if effectRemote then
		local root = getRoot(player)
		if root then
			pcall(function()
				effectRemote:FireClient(player, "ring", root.Position, { radius = 10, color = Color3.fromRGB(160, 120, 255) })
				effectRemote:FireClient(player, "flash", root.Position, Color3.fromRGB(160, 120, 255))
			end)
		end
	end
	if _questService and type(_questService.ReportProgress) == "function" then
		pcall(function()
			_questService.ReportProgress(player, "secret", "discover", 1)
		end)
	else
		-- Lazy sibling require: GameManager cannot be edited by this
		-- workstream, so secrets wire their own progress funnel.
		pcall(function()
			local mod = script.Parent:FindFirstChild("QuestService")
			if mod then
				local candidate = require(mod)
				if type(candidate.ReportProgress) == "function" then
					_questService = candidate
					candidate.ReportProgress(player, "secret", "discover", 1)
				end
			end
		end)
	end
	-- Note: no direct CheckProgress call here — ReportProgress is the
	-- funnel and forwards to achievements exactly once.
	print(string.format("[SecretService] %s discovered secret %s", player.Name, secretId))
	return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- DiscoverSecret(player, secretId): validate the condition server-side
-- and discover the secret. Returns (true) or (false, reason).
function SecretService.DiscoverSecret(player: Player, secretId: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	if type(secretId) ~= "string" or SECRETS[secretId] == nil then
		return false, "unknown secret"
	end
	local data = ensureSecretData(player)
	if not data then
		return false, "no data"
	end
	if data.SecretDiscoveries[secretId] == true then
		return false, "already discovered"
	end
	if not checkCondition(player, secretId) then
		return false, "condition not met"
	end
	if discover(player, secretId) then
		return true, nil
	end
	return false, "discovery failed"
end

-- IsDiscovered(player, secretId): one id at a time — never a list.
function SecretService.IsDiscovered(player: Player, secretId: string): boolean
	local data = getData(player)
	if not data or type(data.SecretDiscoveries) ~= "table" then
		return false
	end
	return data.SecretDiscoveries[secretId] == true
end

-- GetSecretEncounter(): passthrough to TideService's hook (the roll
-- Wave 1 D built for this workstream). Nil when no encounter is live.
function SecretService.GetSecretEncounter(): { Kind: string, Variation: string }?
	return getSecretEncounter()
end

-- ---------------------------------------------------------------------------
-- Setters
-- ---------------------------------------------------------------------------

function SecretService.SetNPCService(npcService: any)
	if npcService and type(npcService.SpawnQuestGiver) == "function" then
		_npcService = npcService
	end
end

function SecretService.SetTideService(tideService: any)
	if tideService and type(tideService.GetSecretEncounter) == "function" then
		_tideService = tideService
	end
end

function SecretService.SetQuestService(questService: any)
	if questService and type(questService.ReportProgress) == "function" then
		_questService = questService
	end
end

function SecretService.SetAchievementService(achievementService: any)
	if achievementService and type(achievementService.CheckProgress) == "function" then
		_achievementService = achievementService
	end
end

function SecretService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

-- Build the three hidden rune parts around the Forbidden Rift. They
-- live in a workspace-root folder ("SecretRunes") — NOT under the
-- ForbiddenRift folder, so QuestService's first-BasePart zone centre
-- (RiftPostA) is untouched, and NOT under TideChannel, so the wave
-- waypoint contract is untouched.
local function buildRunes()
	local folder = workspace:FindFirstChild("SecretRunes")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "SecretRunes"
		folder.Parent = workspace
	end
	for _, rune in ipairs(RUNE_POSITIONS) do
		if folder:FindFirstChild(rune.Name) == nil then
			local part = Instance.new("Part")
			part.Name = rune.Name
			part.Size = Vector3.new(1.5, 1.5, 1.5)
			part.Position = rune.Position
			part.Color = Color3.fromRGB(160, 120, 255)
			part.Material = Enum.Material.Neon
			part.Transparency = 0.3
			part.Anchored = true
			part.CanCollide = false
			part.Parent = folder
			part.Touched:Connect(function(hit)
				local character = hit and hit.Parent
				local player = character and Players:GetPlayerFromCharacter(character)
				if not player then
					return
				end
				local now = os.clock()
				local touched = _runeTouchedAt[player]
				if touched == nil then
					touched = {}
					_runeTouchedAt[player] = touched
				end
				if (touched[rune.Name] or 0) + 2 > now then
					return
				end
				touched[rune.Name] = now
				local data = ensureSecretData(player)
				if not data then
					return
				end
				data.SecretRunes[rune.Name] = true
				if data.SecretDiscoveries["puzzle_room"] ~= true and checkCondition(player, "puzzle_room") then
					discover(player, "puzzle_room")
				end
			end)
		end
	end
end

function SecretService.Init(dataService: any?, npcService: any?)
	assert(dataService ~= nil, "[SecretService] Init requires DataService")
	_dataService = dataService
	if npcService and type(npcService.SpawnQuestGiver) == "function" then
		_npcService = npcService
	end
	if _running then
		return
	end
	_running = true

	buildRunes()

	Players.PlayerRemoving:Connect(function(player)
		_runeTouchedAt[player] = nil
	end)

	-- 2s poll: position-based secrets + the hidden merchant watch.
	task.spawn(function()
		while true do
			task.wait(2)
			-- Merchant watch: a HiddenMerchant tide encounter spawns
			-- the Mysterious Merchant at the Rift (once per encounter
			-- key); he leaves after 120s.
			local encounter = getSecretEncounter()
			if encounter ~= nil and encounter.Kind == "HiddenMerchant" then
				local key = tostring(encounter.Kind) .. "|" .. tostring(encounter.Variation)
				if _merchantEncounterKey ~= key then
					_merchantEncounterKey = key
					if _npcService and type(_npcService.SpawnQuestGiver) == "function" then
						pcall(function()
							local model = _npcService.SpawnQuestGiver(MERCHANT_POSITION)
							if typeof(model) == "Instance" and model:IsA("Model") then
								_merchantModel = model
								_merchantExpiresAt = os.clock() + 120
								print("[SecretService] The Mysterious Merchant appeared at the Forbidden Rift")
							end
						end)
					else
						warn("[SecretService] HiddenMerchant encounter rolled but no NPCService is linked")
					end
				end
			end
			if _merchantModel ~= nil and os.clock() > _merchantExpiresAt then
				pcall(function()
					(_merchantModel :: Model):Destroy()
				end)
				_merchantModel = nil
			end
			-- Position-based discovery checks.
			for _, player in ipairs(Players:GetPlayers()) do
				pcall(function()
					local data = ensureSecretData(player)
					if not data then
						return
					end
					for _, secretId in ipairs(SecretService.SECRET_IDS) do
						if data.SecretDiscoveries[secretId] ~= true and checkCondition(player, secretId) then
							discover(player, secretId)
						end
					end
				end)
			end
		end
	end)
end

return SecretService
