--!strict
-- ProgressionService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- XP / levels, rebirth, the collection book and cosmetics.
--
-- XP CURVE: reuses shared Economy.XPForLevel (the same curve
-- EconomyService uses), so a level means the same thing everywhere.
-- Level-up rewards: coins (50 + 25/level), +5 gems every 5 levels,
-- +1 base slot every 10 levels (capped at Config.BaseSlotsMax).
--
-- REBIRTH (Rebirth remote): requires Level >= 25 AND 100,000 coins AND
-- 10 DISTINCT owned Brainrots — all three checked server-side, all read
-- from Config.RebirthRequirements (the single source of truth). It
-- resets Coins (to Config.StartingCoins), Level/XP (to 1/0) and placed
-- Brainrots (they return to the inventory), BUT KEEPS owned characters
-- and the rebirth count (data.Rebirths), wins/KOs, quests and
-- cosmetics. Each rebirth grants a permanent +10% income (Config),
-- +2 base slots, +25 gems, and unlocks the rebirth-only mutation tier
-- (MutationService reads data.Rebirths). Max 10 rebirths.
-- v1.0.1 QA: v1.0.0 enforced 8 PLACED (not 10 distinct), paid 0 gems
-- (Config promises 25), granted +25% income (Config says +10%), had no
-- rebirth cap, and WIPED the whole collection to the starter — directly
-- contradicting Config's "keeps owned characters". All fixed here.
--
-- COLLECTION BOOK: GetCollection(player) merges data.Unlocked,
-- data.Placed and data.CollectionDiscovered (other services call
-- RecordDiscovery when a character is found). Wired to the
-- RequestCollection RemoteFunction in Init (v1.0.1 integration QA:
-- the getter existed but no handler did, so InvokeServer errored).
--
-- COSMETICS: titles / auras / trails, unlocked by level, rebirth count
-- or collection size. Purely visual — no gameplay advantage. The
-- equipped cosmetic is stored in data.Cosmetics.Equipped; applying the
-- visual is the client's job.
--
-- REMOTE: Rebirth does not exist in Remotes.Names yet, so the existing
-- UpgradeBase remote is reused with an Action envelope
-- ({Action="Rebirth"}); EquipCosmetic likewise reuses SelectCharacter
-- with ({Action="EquipCosmetic", CosmeticId=...}). Both handlers ignore
-- any payload without their Action.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Economy = require(ReplicatedStorage:WaitForChild("Economy"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local ProgressionService = {}

local _dataService: any = nil

-- Rebirth tuning is read from Config.RebirthRequirements at call time
-- (see rebirthConfig()); the locals below are only the fallback if
-- Config is ever missing a field.
local function rebirthConfig()
	local req = Config.RebirthRequirements or {}
	return {
		MinLevel = tonumber(req.Level) or 25,
		MinCoins = tonumber(req.Coins) or 100000,
		MinDistinct = tonumber(req.Brainrots) or 10,
		RewardGems = tonumber(req.RewardGems) or 25,
		IncomePer = tonumber(req.IncomeBonusPerRebirth) or 0.10,
		SlotsPer = tonumber(req.SlotsPerRebirth) or 2,
		MaxRebirths = tonumber(req.MaxRebirths) or 10,
	}
end
export type CosmeticDef = {
	Id: string,
	Name: string,
	Kind: string, -- "Title" | "Aura" | "Trail"
	Requirement: { Level: number?, Rebirths: number?, Distinct: number? },
}

local COSMETICS: { CosmeticDef } = {
	{ Id = "title_rookie", Name = "Rookie", Kind = "Title", Requirement = { Level = 1 } },
	{ Id = "title_collector", Name = "Collector", Kind = "Title", Requirement = { Distinct = 10 } },
	{ Id = "title_tideborn", Name = "Tideborn", Kind = "Title", Requirement = { Level = 10 } },
	{ Id = "title_glitch_lord", Name = "Glitch Lord", Kind = "Title", Requirement = { Rebirths = 1 } },
	{ Id = "title_meme_king", Name = "Meme King", Kind = "Title", Requirement = { Level = 50 } },
	{ Id = "aura_gold", Name = "Golden Aura", Kind = "Aura", Requirement = { Level = 25 } },
	{ Id = "aura_void", Name = "Void Aura", Kind = "Aura", Requirement = { Rebirths = 2 } },
	{ Id = "aura_glitch", Name = "Glitch Aura", Kind = "Aura", Requirement = { Level = 40 } },
	{ Id = "trail_fire", Name = "Fire Trail", Kind = "Trail", Requirement = { Level = 15 } },
	{ Id = "trail_rainbow", Name = "Rainbow Trail", Kind = "Trail", Requirement = { Level = 30 } },
	{ Id = "trail_void", Name = "Void Trail", Kind = "Trail", Requirement = { Rebirths = 1 } },
}

local _cosmeticById: { [string]: CosmeticDef } = {}
for _, def in ipairs(COSMETICS) do
	_cosmeticById[def.Id] = def
end

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

local function ensureProgressionData(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.Rebirths) ~= "number" then
		data.Rebirths = 0
	end
	if type(data.BaseSlots) ~= "number" then
		data.BaseSlots = Config.BaseSlotsStart or 4
	end
	if type(data.Gems) ~= "number" then
		data.Gems = 0
	end
	if type(data.EventTokens) ~= "number" then
		data.EventTokens = 0
	end
	if type(data.CollectionDiscovered) ~= "table" then
		data.CollectionDiscovered = {}
	end
	if type(data.Cosmetics) ~= "table" then
		data.Cosmetics = { Unlocked = {}, Equipped = {} }
	end
	if type(data.Cosmetics.Unlocked) ~= "table" then
		data.Cosmetics.Unlocked = {}
	end
	if type(data.Cosmetics.Equipped) ~= "table" then
		data.Cosmetics.Equipped = {}
	end
	return data
end

local function distinctCount(data: any): number
	local seen: { [string]: boolean } = {}
	local count = 0
	local function add(id: any)
		if type(id) == "string" and not seen[id] and Characters.GetById(id) then
			seen[id] = true
			count += 1
		end
	end
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			add(id)
		end
	end
	if type(data.CollectionDiscovered) == "table" then
		for _, id in ipairs(data.CollectionDiscovered) do
			add(id)
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- XP / levels
-- ---------------------------------------------------------------------------

-- AddXP(player, amount): applies XP, handles level-ups (possibly
-- several), grants level-up rewards, and notifies the client. Other
-- services should call this instead of DataService.AddXP directly.
function ProgressionService.AddXP(player: Player, amount: number): (number, boolean)
	local data = ensureProgressionData(player)
	if not data then
		return 1, false
	end
	local gain = math.max(0, math.floor(tonumber(amount) or 0))
	if gain == 0 then
		return tonumber(data.Level) or 1, false
	end
	local newXP = (tonumber(data.XP) or 0) + gain
	local level = tonumber(data.Level) or 1
	local leveledUp = false
	while newXP >= Economy.XPForLevel(level) do
		newXP -= Economy.XPForLevel(level)
		level += 1
		leveledUp = true
		-- Level-up reward: coins scale with the new level.
		data.Coins = (tonumber(data.Coins) or 0) + 50 + 25 * level
		if level % 5 == 0 then
			data.Gems = (tonumber(data.Gems) or 0) + 5
		end
		if level % 10 == 0 then
			-- +1 base slot: BaseService reads data.Base.Slots, so bump
			-- that (and the legacy data.BaseSlots) together.
			local newSlots = math.min(Config.BaseSlotsMax or 10, (tonumber(data.BaseSlots) or 4) + 1)
			data.BaseSlots = newSlots
			if type(data.Base) == "table" then
				data.Base.Slots = newSlots
			end
		end
	end
	data.XP = newXP
	if leveledUp then
		_dataService.SetLevel(player, level)
		fireClient(_names.SpawnEffect, player, {
			type = "LevelUp",
			player = player.Name,
			level = level,
		})
		print(string.format("[ProgressionService] %s levelled up to %d", player.Name, level))
	end
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Gems = data.Gems,
	})
	return level, leveledUp
end

function ProgressionService.GetLevel(player: Player): number
	local data = getData(player)
	return data and (tonumber(data.Level) or 1) or 1
end

function ProgressionService.GetRebirths(player: Player): number
	local data = getData(player)
	return data and (tonumber(data.Rebirths) or 0) or 0
end

-- GetIncomeMultiplier(player): 1 + IncomeBonusPerRebirth per rebirth
-- (permanent). v1.0.0 hardcoded +25% here while Config says +10%.
function ProgressionService.GetIncomeMultiplier(player: Player): number
	return 1 + ProgressionService.GetRebirths(player) * rebirthConfig().IncomePer
end

function ProgressionService.GetBaseSlots(player: Player): number
	local data = getData(player)
	if not data then
		return Config.BaseSlotsStart or 4
	end
	-- BaseService reads data.Base.Slots; data.BaseSlots is the legacy
	-- field. Prefer the live one.
	local base = Config.BaseSlotsStart or 4
	if type(data.Base) == "table" and tonumber(data.Base.Slots) then
		base = tonumber(data.Base.Slots) :: number
	elseif tonumber(data.BaseSlots) then
		base = tonumber(data.BaseSlots) :: number
	end
	-- v1.0.0 never clamped: rebirth slots could push the total past
	-- every cap. Clamp to MaxBasePlots (12 = MaxPlayers).
	return math.min(
		Config.MaxBasePlots or 12,
		base + ProgressionService.GetRebirths(player) * rebirthConfig().SlotsPer
	)
end

-- ---------------------------------------------------------------------------
-- Rebirth
-- ---------------------------------------------------------------------------

-- Rebirth(player): validates all requirements from
-- Config.RebirthRequirements, then resets coins / level / XP / placed
-- slots while KEEPING owned characters (Unlocked + OwnedInstances),
-- wins/KOs, quests and cosmetics. Returns (true, rebirths) or
-- (false, reason).
function ProgressionService.Rebirth(player: Player): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	local cfg = rebirthConfig()
	local level = tonumber(data.Level) or 1
	local coins = tonumber(data.Coins) or 0
	local distinct = distinctCount(data)
	local rebirths = tonumber(data.Rebirths) or 0
	if rebirths >= cfg.MaxRebirths then
		return false, "max rebirths reached (" .. tostring(cfg.MaxRebirths) .. ")"
	end
	if level < cfg.MinLevel then
		return false, "requires level " .. tostring(cfg.MinLevel)
	end
	if coins < cfg.MinCoins then
		return false, "requires " .. tostring(cfg.MinCoins) .. " coins"
	end
	if distinct < cfg.MinDistinct then
		return false, "requires " .. tostring(cfg.MinDistinct) .. " distinct Brainrots owned"
	end
	rebirths += 1
	-- Reset economy + placed state only. Owned characters stay owned:
	-- Unlocked is untouched, and OwnedInstances keeps every instance
	-- with Placed cleared (placed Brainrots return to the inventory).
	-- v1.0.0 wiped Unlocked to the starter and nilled OwnedInstances,
	-- destroying the whole collection on every rebirth.
	data.Coins = Config.StartingCoins or 100
	data.XP = 0
	data.Level = 1
	data.Gems = (tonumber(data.Gems) or 0) + cfg.RewardGems
	data.Selected = "wobble_waffleton"
	data.Placed = {}
	if type(data.Base) == "table" then
		-- Placed Brainrots live in data.Base.Placed (BaseService) —
		-- clear that too or the rebirth would keep the old base.
		data.Base.Placed = {}
	end
	if type(data.OwnedInstances) == "table" then
		for _, inst in ipairs(data.OwnedInstances) do
			if type(inst) == "table" then
				inst.Placed = false
				inst.Slot = 0
			end
		end
	end
	local newSlots = math.min(
		Config.MaxBasePlots or 12,
		(Config.BaseSlotsStart or 4) + rebirths * cfg.SlotsPer
	)
	if type(data.Base) == "table" then
		data.Base.Slots = newSlots
	end
	data.BaseSlots = newSlots
	data.Rebirths = rebirths
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient(_names.SpawnEffect, player, {
		type = "Rebirth",
		player = player.Name,
		rebirths = rebirths,
	})
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Rebirths = rebirths,
		Gems = data.Gems,
		BaseSlots = data.BaseSlots,
	})
	print(string.format(
		"[ProgressionService] %s rebirthed (count %d): +%.0f%% income, +%d base slots, +%d gems",
		player.Name, rebirths, cfg.IncomePer * 100, cfg.SlotsPer, cfg.RewardGems
	))
	return true, rebirths
end

-- ---------------------------------------------------------------------------
-- Collection book
-- ---------------------------------------------------------------------------

-- RecordDiscovery(player, characterId): remember a character was found
-- (called by ConveyorService / EconomyService / BossService on grant).
function ProgressionService.RecordDiscovery(player: Player, characterId: any): boolean
	local clean = sanitize(characterId)
	if not clean or not Characters.GetById(clean) then
		return false
	end
	local data = ensureProgressionData(player)
	if not data then
		return false
	end
	for _, id in ipairs(data.CollectionDiscovered) do
		if id == clean then
			return false
		end
	end
	table.insert(data.CollectionDiscovered, clean)
	return true
end

-- GetCollection(player): discovered ids + totals, for the client
-- Collection UI. Discovered = Unlocked ∪ Placed ∪ CollectionDiscovered.
function ProgressionService.GetCollection(player: Player): { Discovered: { string }, Total: number, Owned: number, ByRarity: { [string]: number } }
	local data = ensureProgressionData(player)
	local discovered: { [string]: boolean } = {}
	if data then
		local function add(id: any)
			if type(id) == "string" and Characters.GetById(id) then
				discovered[id] = true
			end
		end
		if type(data.Unlocked) == "table" then
			for _, id in ipairs(data.Unlocked) do
				add(id)
			end
		end
		if type(data.Placed) == "table" then
			for _, placed in ipairs(data.Placed) do
				if type(placed) == "table" then
					add(placed.CharacterId)
				end
			end
		end
		-- Placed Brainrots live in data.Base.Placed (BaseService's
		-- shape); v1.0.0 only read the legacy data.Placed, so placed
		-- Brainrots never counted as discovered in the collection book.
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			for _, placed in ipairs(data.Base.Placed) do
				if type(placed) == "table" then
					add(placed.CharacterId)
				end
			end
		end
		if type(data.CollectionDiscovered) == "table" then
			for _, id in ipairs(data.CollectionDiscovered) do
				add(id)
			end
		end
	end
	local ids: { string } = {}
	local byRarity: { [string]: number } = {}
	for id in pairs(discovered) do
		table.insert(ids, id)
		local def = Characters.GetById(id)
		if def then
			byRarity[def.Rarity] = (byRarity[def.Rarity] or 0) + 1
		end
	end
	table.sort(ids)
	return {
		Discovered = ids,
		Total = Characters.GetCount(),
		Owned = #ids,
		ByRarity = byRarity,
	}
end

-- ---------------------------------------------------------------------------
-- Cosmetics (visual only — no gameplay advantage).
-- ---------------------------------------------------------------------------

function ProgressionService.IsCosmeticUnlocked(player: Player, cosmeticId: string): boolean
	local def = _cosmeticById[cosmeticId]
	if not def then
		return false
	end
	local data = ensureProgressionData(player)
	if not data then
		return false
	end
	local req = def.Requirement
	if req.Level and (tonumber(data.Level) or 1) < req.Level then
		return false
	end
	if req.Rebirths and (tonumber(data.Rebirths) or 0) < req.Rebirths then
		return false
	end
	if req.Distinct and distinctCount(data) < req.Distinct then
		return false
	end
	return true
end

function ProgressionService.GetCosmetics(player: Player): { any }
	local data = ensureProgressionData(player)
	if not data then
		return {}
	end
	local out: { any } = {}
	for _, def in ipairs(COSMETICS) do
		table.insert(out, {
			Id = def.Id,
			Name = def.Name,
			Kind = def.Kind,
			Unlocked = ProgressionService.IsCosmeticUnlocked(player, def.Id),
			Equipped = data.Cosmetics.Equipped[def.Kind] == def.Id,
		})
	end
	return out
end

-- EquipCosmetic(player, id): validated against unlocks; stores the
-- equipped cosmetic per Kind. Returns (true) or (false, reason).
function ProgressionService.EquipCosmetic(player: Player, cosmeticId: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(cosmeticId)
	if not clean or not _cosmeticById[clean] then
		return false, "unknown cosmetic"
	end
	if not ProgressionService.IsCosmeticUnlocked(player, clean) then
		return false, "cosmetic not unlocked"
	end
	local data = ensureProgressionData(player)
	if not data then
		return false, "no data"
	end
	local def = _cosmeticById[clean]
	data.Cosmetics.Equipped[def.Kind] = clean
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient(_names.PlayerStats, player, {
		Action = "CosmeticEquipped",
		CosmeticId = clean,
		Kind = def.Kind,
	})
	return true, nil
end

local function onRebirthRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" or payload.Action ~= "Rebirth" then
		return
	end
	if not rateOk(player, "Rebirth", 5) then
		return
	end
	local ok, err = ProgressionService.Rebirth(player)
	if not ok then
		warn("[ProgressionService] Rebirth failed for " .. player.Name .. ": " .. tostring(err))
	end
end

local function onSelectRemote(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(payload) ~= "table" or payload.Action ~= "EquipCosmetic" then
		return
	end
	if not rateOk(player, "EquipCosmetic", 1) then
		return
	end
	local ok, err = ProgressionService.EquipCosmetic(player, payload.CosmeticId)
	if not ok then
		warn("[ProgressionService] EquipCosmetic failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function ProgressionService.Init(dataService: any)
	assert(dataService ~= nil, "[ProgressionService] Init requires DataService")
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
	end)

	local rebirthRemote = _names.Rebirth or _names.UpgradeBase
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(rebirthRemote)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onRebirthRemote)
		else
			warn("[ProgressionService] Remote not found, rebirth handler not wired: " .. tostring(rebirthRemote))
		end
	end)

	local cosmeticRemote = _names.EquipCosmetic or _names.SelectCharacter
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(cosmeticRemote)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onSelectRemote)
		else
			warn("[ProgressionService] Remote not found, cosmetic handler not wired: " .. tostring(cosmeticRemote))
		end
	end)

	-- RequestCollection (RemoteFunction): the collection book's pull
	-- path. v1.0.1 integration QA — GetCollection existed but no
	-- handler did, so InvokeServer errored. Returns the same shape
	-- CollectionController reads from RequestShop (Discovered ids,
	-- totals, ByRarity).
	local collectionFnName = _names.RequestCollection or "RequestCollection"
	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction(collectionFnName)
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(player: Player)
				return ProgressionService.GetCollection(player)
			end
		else
			warn("[ProgressionService] RemoteFunction not found, RequestCollection not wired: " .. tostring(collectionFnName))
		end
	end)
end

return ProgressionService
