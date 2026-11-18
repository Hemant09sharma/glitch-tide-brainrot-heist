--!strict
-- CompanionService.luau
-- Glitch Tide v1.1 (Workstream B) — companion passives.
--
-- A companion is any Brainrot the player OWNS whose CharacterDef
-- carries a CompanionAbility {Kind, Value} (see shared/Companions.luau
-- for the kind table and the per-kind total caps). Owning it is enough;
-- it does not need to be placed in the base.
--
-- What this service really does (all server-side, all derived from
-- live player data on every call — no stale cache):
--   IncomeBonus     -> GetIncomeMultiplier(player): 1 + bonus.
--                      Applied by the ECONOMY hook: EconomyService.
--                      GetCompanionIncomeMultiplier(player) delegates
--                      here. BaseService must multiply its income by
--                      that hook (ONE integration line, owned by the
--                      BaseService workstream — see docs/QA_V11_B.md).
--   TideProtection  -> IsTideProtected(player): per-hit roll, chance
--                      = the player's TideProtection bonus. TideService
--                      (another workstream) calls this once per tide
--                      damage tick; a true result means "take no damage
--                      from this hit". Documented API, TideService is
--                      NOT edited here.
--   RareDetection   -> GetRareWeightMultiplier(player, rarity): 1 +
--                      bonus for Epic+ rarities, 1 otherwise.
--                      ConveyorService (another workstream) can
--                      multiply its effective rarity weights by this
--                      when rolling for a player who owns the
--                      conveyor item. Documented callback, Conveyor
--                      Service is NOT edited here.
--   CarrySpeed      -> GetCarrySpeedMultiplier(player): the carry
--                      speed multiplier (Config 0.6 base + bonus,
--                      capped at 0.75). CarryService can read this
--                      instead of the flat Config value.
--   RaidDetection   -> GetRaidWarningSeconds(player): bonus * 30s of
--                      extra raid warning (max 7.5s). RaidService can
--                      add this to its steal-alert lead time.
--   MutationBonus   -> GetMutationIncomeBonus(player): fraction added
--                      to mutation income multipliers. MutationService
--                      can add this to Mutations.GetMultiplier when
--                      computing income for this player's Brainrots.
--
-- Rare presentation: AnnounceRareAcquisition(player, characterId,
-- position) fires the rarity spawn effects + banner for a rare
-- acquisition (Epic+), using ONLY remotes that already exist
-- (SpawnEffect positional form + EventUpdate, both already listened
-- to by EffectsController / HUDController). Secret / Impossible get
-- a bigger ring, a longer banner and a distinct sound hook name in
-- the EventUpdate payload ("rare" / "secret") for the sound
-- workstream to play.
--
-- Registration (GameManager / Main.server are NOT edited here):
--   1. Add "CompanionService" to GameManager.OPTIONAL_SERVICES (after
--      "AbilityService" — it only needs DataService + EconomyService,
--      both of which exist before the optional pass runs).
--   2. Add a per-name branch in GameManager.loadOptional (audit §4c:
--      a new service needs a branch when its Init differs from the
--      generic one):
--        elseif name == "CompanionService" then
--            initOk, initErr = pcall(function()
--                service.Init(_dataService, _economyService)
--            end)
--      (The generic fallback branch would ALSO work — it calls
--      Init(dataService, economyService, map) and this Init accepts
--      exactly (dataService, economyService) — but the explicit branch
--      is the documented pattern, so ask for it, don't rely on the
--      fallback + no-arg retry.)
--   3. Add "CompanionService" to GameManager.wireCrossLinks' shared
--      setter table? NOT needed: this service pulls DataService /
--      EconomyService from Init, and EconomyService.SetCompanionService
--      is called from Init itself (see below).
--   Init signature: Init(dataService: any?, economyService: any?).
--   Both arguments are optional: with no DataService the service
--   still answers with zero bonuses instead of erroring.
--
-- INCOME INTEGRATION (audit §4f correction — read before wiring):
--   EconomyService has NO AddCoins/AddGems API; coins move only via
--   DataService.AddCoins and income is computed ONLY in
--   BaseService.GetIncomePerSec. This service therefore does NOT pay
--   income itself. The live path is:
--     BaseService.GetIncomePerSec: total *= EconomyService
--       .GetCompanionIncomeMultiplier(player)
--   That needs ONE new setter + ONE line inside BaseService (it has
--   no SetEconomyService setter today, so the EconomyService hook
--   cannot reach its income math without a BaseService edit):
--     function BaseService.SetCompanionService(svc) ... end
--     -- inside GetIncomePerSec, beside the synergy/event lines:
--     --   total *= EconomyService.GetCompanionIncomeMultiplier(player)
--   The BaseService workstream owns that edit. Until it lands, the
--   companion IncomeBonus is computed and exposed (and unit-verified
--   in the harness) but is NOT applied to banked income — see
--   docs/QA_V11_B.md §"Partially implemented".
--
-- Persistence: in-memory only plus GetStateForSave(player) /
-- LoadState(player, data). Bonuses are re-derived from owned
-- characters on every call, so a save is a snapshot for debugging /
-- the audit trail, not the source of truth — DataService is NOT
-- edited, and no new DataStore key is introduced.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Companions = require(ReplicatedStorage:WaitForChild("Companions"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local CompanionService = {}

local _dataService: any = nil
local _economyService: any = nil
-- Last saved snapshot per player (LoadState restores this cache only;
-- bonuses themselves always re-derive from owned characters).
local _saved: { [Player]: { [string]: any } } = {}

local BASE_CARRY_MULTIPLIER = 0.6
local MAX_CARRY_MULTIPLIER = 0.75

local function getRemote(name: string): RemoteEvent?
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

-- Owned character Ids for a player: data.Unlocked (character Ids) plus
-- any OwnedInstances character Ids (covers instances whose Id is not
-- in Unlocked). Returns {} when there is no data service / no data.
local function getOwnedIds(player: Player): { string }
	local ids: { string } = {}
	if _dataService == nil then
		return ids
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if not ok or type(data) ~= "table" then
		return ids
	end
	local seen: { [string]: boolean } = {}
	if type(data.Unlocked) == "table" then
		for _, id in ipairs(data.Unlocked) do
			if type(id) == "string" and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end
	if type(data.OwnedInstances) == "table" then
		for _, inst in ipairs(data.OwnedInstances) do
			if type(inst) == "table" and type(inst.CharacterId) == "string" and not seen[inst.CharacterId] then
				seen[inst.CharacterId] = true
				table.insert(ids, inst.CharacterId)
			end
		end
	end
	return ids
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Total companion bonuses for a player, derived live from owned
-- characters. Always safe to call: returns zero bonuses with no data.
function CompanionService.GetBonuses(player: Player): any
	if not player or not player:IsA("Player") then
		return Companions.ZeroBonuses()
	end
	return Companions.ComputeBonuses(getOwnedIds(player))
end

-- Income multiplier from companions (1 + IncomeBonus, max 1.25).
-- This is the value EconomyService.GetCompanionIncomeMultiplier
-- returns; BaseService multiplies base income by it.
function CompanionService.GetIncomeMultiplier(player: Player): number
	local bonuses = CompanionService.GetBonuses(player)
	return 1 + (tonumber(bonuses.IncomeBonus) or 0)
end

-- Per-tide-hit protection roll: true with probability equal to the
-- player's TideProtection bonus (max 0.20). TideService calls this
-- once per damage tick; it is a chance, not a permanent shield, so a
-- 20% companion never makes a player untouchable.
function CompanionService.IsTideProtected(player: Player): boolean
	local bonuses = CompanionService.GetBonuses(player)
	local chance = math.clamp(tonumber(bonuses.TideProtection) or 0, 0, 0.20)
	if chance <= 0 then
		return false
	end
	return math.random() < chance
end

-- Conveyor hook: weight multiplier for a rarity roll. Epic and above
-- get 1 + RareDetection (max 1.20); lower rarities are untouched so a
-- companion never makes Commons rarer — it only makes rares likelier.
function CompanionService.GetRareWeightMultiplier(player: Player, rarity: string): number
	local rank = Characters.GetRarityRank(rarity)
	if rank < 4 then
		return 1
	end
	local bonuses = CompanionService.GetBonuses(player)
	return 1 + math.clamp(tonumber(bonuses.RareDetection) or 0, 0, 0.20)
end

-- Carry speed multiplier while carrying (Config base 0.6 + bonus,
-- capped at 0.75). CarryService can use this in place of the flat
-- Config.CarrySpeedMultiplier.
function CompanionService.GetCarrySpeedMultiplier(player: Player): number
	local bonuses = CompanionService.GetBonuses(player)
	local bonus = math.clamp(tonumber(bonuses.CarrySpeed) or 0, 0, 0.15)
	return math.min(BASE_CARRY_MULTIPLIER + bonus, MAX_CARRY_MULTIPLIER)
end

-- Extra raid-warning lead time in seconds (bonus * 30, max 7.5s).
-- RaidService can add this to its steal-alert lead time.
function CompanionService.GetRaidWarningSeconds(player: Player): number
	local bonuses = CompanionService.GetBonuses(player)
	return math.clamp(tonumber(bonuses.RaidDetection) or 0, 0, 0.25) * 30
end

-- Extra fraction added to mutation income multipliers for this
-- player's Brainrots (max +0.15). MutationService can add this to
-- Mutations.GetMultiplier when computing income.
function CompanionService.GetMutationIncomeBonus(player: Player): number
	local bonuses = CompanionService.GetBonuses(player)
	return math.clamp(tonumber(bonuses.MutationBonus) or 0, 0, 0.15)
end

-- ---------------------------------------------------------------------------
-- Rare presentation
-- ---------------------------------------------------------------------------

-- Rarity presentation table (shared with CharacterModels): ring size,
-- banner length and sound-hook name per rarity rank. Secret (9) and
-- Impossible (10) are deliberately outsized.
local RARE_PRESENTATION: { [number]: { RingRadius: number, BannerSeconds: number, SoundHook: string } } = {
	[4] = { RingRadius = 8, BannerSeconds = 6, SoundHook = "rare" },
	[5] = { RingRadius = 10, BannerSeconds = 7, SoundHook = "rare" },
	[6] = { RingRadius = 12, BannerSeconds = 8, SoundHook = "rare" },
	[7] = { RingRadius = 14, BannerSeconds = 9, SoundHook = "rare" },
	[8] = { RingRadius = 16, BannerSeconds = 10, SoundHook = "rare" },
	[9] = { RingRadius = 20, BannerSeconds = 12, SoundHook = "secret" },
	[10] = { RingRadius = 26, BannerSeconds = 15, SoundHook = "secret" },
}

function CompanionService.GetRarePresentation(rarity: string): { RingRadius: number, BannerSeconds: number, SoundHook: string }?
	local rank = Characters.GetRarityRank(rarity)
	return RARE_PRESENTATION[rank]
end

-- Announce a rare acquisition: positional SpawnEffect fires (the form
-- EffectsController actually handles: "ring" / "flash" / "poof" /
-- "glitchAura") plus an EventUpdate banner the HUD already shows.
-- position defaults to the player's character root. Epic+ only;
-- lower rarities return false (nothing to announce).
function CompanionService.AnnounceRareAcquisition(player: Player, characterId: string, position: Vector3?): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	local def = Characters.GetById(characterId)
	if def == nil then
		return false
	end
	local rank = Characters.GetRarityRank(def.Rarity)
	local pres = RARE_PRESENTATION[rank]
	if pres == nil then
		return false
	end
	local pos = position
	if pos == nil then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			pos = root.Position
		else
			pos = Vector3.new(0, 5, 0)
		end
	end
	local spawnRemote = getRemote("SpawnEffect")
	if spawnRemote ~= nil then
		-- Positional form: (effectType, position, extra). Ring + flash
		-- in the rarity colour, a poof, and a glitch aura for the top
		-- two tiers. Secret / Impossible fire the ring twice (a second,
		-- larger ring a beat later) for the outsized feel.
		local color = def.Color
		pcall(function()
			spawnRemote:FireAllClients("ring", pos, { radius = pres.RingRadius, color = color });
			(spawnRemote :: RemoteEvent):FireAllClients("flash", pos, color);
			(spawnRemote :: RemoteEvent):FireAllClients("poof", pos, nil)
		end)
		if rank >= 9 then
			task.delay(0.35, function()
				pcall(function()
					(spawnRemote :: RemoteEvent):FireAllClients("ring", pos, { radius = pres.RingRadius + 6, color = color });
					(spawnRemote :: RemoteEvent):FireAllClients("glitchAura", pos, 3)
				end)
			end)
		end
	end
	local eventRemote = getRemote("EventUpdate")
	if eventRemote ~= nil then
		pcall(function()
			(eventRemote :: RemoteEvent):FireAllClients({
				EventId = "RareAcquisition",
				Name = string.format("%s acquired %s (%s)!", player.Name, def.DisplayName, def.Rarity),
				Phase = "Started",
				Duration = pres.BannerSeconds,
				SoundHook = pres.SoundHook,
			})
		end)
	end
	print(string.format("[CompanionService] RARE acquisition: %s got %s (%s)", player.Name, def.DisplayName, def.Rarity))
	return true
end

-- ---------------------------------------------------------------------------
-- Persistence (snapshot only — bonuses re-derive from owned characters)
-- ---------------------------------------------------------------------------

function CompanionService.GetStateForSave(player: Player): { [string]: any }
	local bonuses = CompanionService.GetBonuses(player)
	local state: { [string]: any } = {
		OwnedCompanionIds = getOwnedIds(player),
		Bonuses = bonuses,
	}
	_saved[player] = state
	return state
end

function CompanionService.LoadState(player: Player, data: any): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	if type(data) ~= "table" then
		return false
	end
	-- The save is a snapshot, not the source of truth: bonuses are
	-- re-derived from owned characters on every call, so loading only
	-- restores the in-memory snapshot cache for the audit trail.
	_saved[player] = data :: { [string]: any }
	return true
end

function CompanionService.GetSavedState(player: Player): { [string]: any }?
	return _saved[player]
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

-- Init(dataService?, economyService?): both optional. With no
-- DataService every query returns zero bonuses; with no
-- EconomyService the income hook simply has no consumer yet.
-- Wire the economy hook back: if the economy service exposes
-- SetCompanionService, register this service so
-- EconomyService.GetCompanionIncomeMultiplier(player) delegates here.
function CompanionService.Init(dataService: any?, economyService: any?)
	_dataService = dataService
	_economyService = economyService
	if economyService ~= nil and type(economyService.SetCompanionService) == "function" then
		pcall(function()
			economyService.SetCompanionService(CompanionService)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		_saved[player] = nil
	end)
end

return CompanionService
