--!strict
-- Remotes.luau
-- Single source of truth for every RemoteEvent / RemoteFunction name in
-- Glitch Tide — Brainrot Heist: The Memeverse. Server and client both
-- require this module and look remotes up by the Names table, so a
-- renamed remote can never silently desync one side.
--
-- Safe to require from server and client: creation is guarded to the
-- server (RunService:IsServer()); clients only look remotes up.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

Remotes.Names = {
	-- Arena combat (original set, kept)
	Attack = "Attack",
	UseAbility = "UseAbility",
	RequestCharacter = "RequestCharacter",
	SelectCharacter = "SelectCharacter",
	BuyCharacter = "BuyCharacter",
	RequestShop = "RequestShop",
	PlayerStats = "PlayerStats",
	WaveUpdate = "WaveUpdate",
	RoundUpdate = "RoundUpdate",
	SpawnEffect = "SpawnEffect",
	DamageNumber = "DamageNumber",

	-- Glitch Tide heist loop
	BuyConveyor = "BuyConveyor",
	PickupBrainrot = "PickupBrainrot",
	DropBrainrot = "DropBrainrot",
	PlaceBrainrot = "PlaceBrainrot",
	StealBrainrot = "StealBrainrot",
	RequestBase = "RequestBase",
	UpgradeBase = "UpgradeBase",
	UpgradeBrainrot = "UpgradeBrainrot",
	CollectIncome = "CollectIncome",
	ConveyorUpdate = "ConveyorUpdate",
	BaseUpdate = "BaseUpdate",
	CarryUpdate = "CarryUpdate",
	StealAlert = "StealAlert",
	GlitchTideUpdate = "GlitchTideUpdate",

	-- Mutations / fusion / quests / collection / rebirth / events
	MutateBrainrot = "MutateBrainrot",
	FuseBrainrot = "FuseBrainrot",
	RequestQuests = "RequestQuests",
	ClaimQuest = "ClaimQuest",
	RequestCollection = "RequestCollection",
	Rebirth = "Rebirth",
	RequestEvents = "RequestEvents",

	-- Powers
	UsePower = "UsePower",
	PowerUpdate = "PowerUpdate",

	-- Tide / boss / event broadcasts
	TideSurvivor = "TideSurvivor",
	QuestUpdate = "QuestUpdate",
	BossUpdate = "BossUpdate",
	EventUpdate = "EventUpdate",
	SynergyUpdate = "SynergyUpdate",

	-- Trading (RESERVED — TradingService is intentionally not built.
	-- These names exist so a future trade system has stable remote
	-- names, but they must NOT be wired to any handler that moves
	-- items or currency between players until a server-validated
	-- trading service exists.)
	TradeRequest = "TradeRequest",
	TradeAccept = "TradeAccept",
	TradeCancel = "TradeCancel",

	-- Misc
	NPCDialogue = "NPCDialogue",
	SettingsUpdate = "SettingsUpdate",
	-- Reserved: no handler is wired to this remote. Cosmetics equip via
	-- the SelectCharacter envelope (ProgressionService); this name exists
	-- so the fallback lookup resolves to a real, inert RemoteEvent.
	EquipCosmetic = "EquipCosmetic",

	-- Dimensions (v1.1 Wave 1, Workstream A — added Wave 3, Workstream E)
	TeleportDimension = "TeleportDimension",
	RequestDimensions = "RequestDimensions",
	DimensionUpdate = "DimensionUpdate",

	-- Laboratory / Expeditions / Territories / Secrets / Achievements
	-- (v1.1 Wave 2, Workstream C — added Wave 3, Workstream E)
	RequestLab = "RequestLab",
	LabUpdate = "LabUpdate",
	EvolveBrainrot = "EvolveBrainrot",
	RequestExpeditions = "RequestExpeditions",
	ExpeditionUpdate = "ExpeditionUpdate",
	StartExpedition = "StartExpedition",
	ClaimExpedition = "ClaimExpedition",
	RequestTerritories = "RequestTerritories",
	TerritoryUpdate = "TerritoryUpdate",
	CaptureTerritory = "CaptureTerritory",
	SecretDiscovered = "SecretDiscovered",
	RequestAchievements = "RequestAchievements",
	AchievementUnlocked = "AchievementUnlocked",

	-- Titles (v1.1 Wave 3, Workstream E — added per docs/REMOTES_NEEDED_C.md:
	-- "If Wave 3 needs a dedicated equip remote it should add EquipTitle
	-- then, with payload {TitleId}". The NAME now exists, but NO server
	-- handler wires it yet: AchievementService.SetEquippedTitle is never
	-- called by any remote handler in this tree. See docs/REMOTES_WIRED_E.md
	-- for the one-line integrator step. Until then the client equip button
	-- fires this name and keeps the choice local-only.)
	EquipTitle = "EquipTitle",
}

-- Events the server fires to clients.
--
-- CONTRACT (QA 2026-11-18, verified by grep over src/server + src/client;
-- updated 2026-11-19, Wave 3 Workstream E — see docs/REMOTES_WIRED_E.md
-- for the per-remote wiring table):
-- every name here is CREATED, but not every name is WIRED. Names with
-- no server handler and no client listener are orphans — firing them
-- is a silent no-op and invoking them errors. Do NOT wire a handler
-- that moves items/currency to a name listed as unwired until its
-- owning service validates it.
--   WIRED (server handler + client use): Attack (CombatService; client
--     firer added Wave 3 in AbilityController — left-click + touch
--     ATTACK button), UseAbility, SelectCharacter, BuyCharacter,
--     RequestShop, RequestBase, RequestQuests (QuestService.GetQuests,
--     v1.0.1 integration QA), RequestCollection (ProgressionService.
--     GetCollection — client caller added Wave 3 in
--     CollectionController), RequestEvents (EventService.GetActiveEvent
--     — client caller added Wave 3 in HUDController), BuyConveyor,
--     PickupBrainrot, DropBrainrot, PlaceBrainrot, StealBrainrot
--     (RaidService; client firer added Wave 3 in InteractionController
--     — steal scan of Placed_<InstanceId> models + owner-sign victim
--     resolution), UpgradeBase, UpgradeBrainrot, CollectIncome,
--     MutateBrainrot, FuseBrainrot, ClaimQuest, Rebirth, EquipCosmetic
--     (ProgressionService, Action="EquipCosmetic" envelope),
--     NPCDialogue (server fires; InteractionController listens),
--     TeleportDimension (DimensionsService), RequestDimensions
--     (DimensionsService.GetDimensions), EvolveBrainrot
--     (LaboratoryService Action envelope), RequestLab
--     (LaboratoryService.GetLabState), StartExpedition /
--     ClaimExpedition (ExpeditionService), RequestExpeditions
--     (ExpeditionService.GetExpeditions), CaptureTerritory
--     (TerritoryService), RequestTerritories
--     (TerritoryService.GetTerritories), RequestAchievements
--     (AchievementService.GetAchievements).
--   SERVER-FIRED BROADCASTS (no client-to-server handler, by design):
--     PlayerStats, WaveUpdate, RoundUpdate, SpawnEffect, DamageNumber,
--     ConveyorUpdate, BaseUpdate, CarryUpdate, StealAlert,
--     GlitchTideUpdate, QuestUpdate, PowerUpdate (AbilityService fires,
--     AbilityController listens), EventUpdate + TideSurvivor (fired by
--     EventService / TideService; HUDController listens since v1.0.1
--     integration QA and shows them via ShowEventBanner), BossUpdate
--     (BossService fires on spawn/phase/2s-health/death since v1.1 D;
--     HUDController listens since Wave 3 E — boss health banner),
--     DimensionUpdate (DimensionsService fires; DimensionController
--     listens since Wave 3 E), LabUpdate (LaboratoryService fires;
--     LaboratoryController listens), ExpeditionUpdate
--     (ExpeditionService fires; ExpeditionController listens),
--     TerritoryUpdate (TerritoryService fires to all;
--     TerritoryController listens), SecretDiscovered (SecretService
--     fires an id-less payload; AchievementController listens and
--     shows a GENERIC banner only — never a secret id/name),
--     AchievementUnlocked (AchievementService fires;
--     AchievementController listens).
--   FIRED BY NO SERVICE YET (client degrades gracefully; reserved for
--     their owning services to fire): SynergyUpdate (no service fires
--     it; synergy is folded silently into income — see
--     docs/REMOTES_WIRED_E.md).
--   UNWIRED — no server handler AND no client caller/listener:
--     RequestCharacter (legacy; Main.client still waits for it),
--     UsePower — DELIBERATE (Wave 3 E decision, see
--     docs/REMOTES_WIRED_E.md): AbilityService.UsePower is a Lua
--     method reached ONLY through the UseAbility handler (id-
--     partitioned); firing the UsePower remote would hit no handler
--     and duplicate the entry point. UseAbility is the single path.
--     SettingsUpdate — DELIBERATE (Wave 3 E decision): no settings
--     sync exists on the server and no DataService field stores
--     settings; mute/volume are client-local in SoundController.
--     Firing it would be a silent no-op dressed as a sync.
--     EquipTitle — DEFINED but handler PENDING (see Names comment):
--     the name exists so the client equip button has a stable
--     target; AchievementService must connect it before equips
--     persist. Until then the equip is local-only.
--   RESERVED, intentionally unwired: TradeRequest / TradeAccept /
--     TradeCancel (no trading service; see Names comment above).
local EVENT_NAMES: { string } = {
	"Attack",
	"UseAbility",
	"RequestCharacter",
	"SelectCharacter",
	"BuyCharacter",
	"WaveUpdate",
	"RoundUpdate",
	"SpawnEffect",
	"DamageNumber",
	"PlayerStats",
	"BuyConveyor",
	"PickupBrainrot",
	"DropBrainrot",
	"PlaceBrainrot",
	"StealBrainrot",
	"UpgradeBase",
	"UpgradeBrainrot",
	"CollectIncome",
	"ConveyorUpdate",
	"BaseUpdate",
	"CarryUpdate",
	"StealAlert",
	"GlitchTideUpdate",
	"QuestUpdate",
	"MutateBrainrot",
	"FuseBrainrot",
	"ClaimQuest",
	"Rebirth",
	"UsePower",
	"PowerUpdate",
	"TideSurvivor",
	"TradeRequest",
	"TradeAccept",
	"TradeCancel",
	"NPCDialogue",
	"BossUpdate",
	"EventUpdate",
	"SynergyUpdate",
	"SettingsUpdate",
	"EquipCosmetic",
	"TeleportDimension",
	"DimensionUpdate",
	"LabUpdate",
	"EvolveBrainrot",
	"ExpeditionUpdate",
	"StartExpedition",
	"ClaimExpedition",
	"TerritoryUpdate",
	"CaptureTerritory",
	"SecretDiscovered",
	"AchievementUnlocked",
	"EquipTitle",
}

-- RemoteFunctions (request/response): stats, shop, base state.
local FUNCTION_NAMES: { string } = {
	"RequestShop",
	"RequestBase",
	"RequestQuests",
	"RequestCollection",
	"RequestEvents",
	"RequestDimensions",
	"RequestLab",
	"RequestExpeditions",
	"RequestTerritories",
	"RequestAchievements",
}

local REMOTES_FOLDER_NAME = "Remotes"

local function getFolder(): Folder?
	return ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME) :: Folder?
end

-- Server only: creates the Remotes folder and every RemoteEvent /
-- RemoteFunction in it. Idempotent — safe to call more than once.
function Remotes.CreateRemotes(storage: Instance?): Folder
	assert(RunService:IsServer(), "Remotes.CreateRemotes may only run on the server")
	local parent = storage or ReplicatedStorage
	local folder = parent:FindFirstChild(REMOTES_FOLDER_NAME)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = REMOTES_FOLDER_NAME
		folder.Parent = parent
	end

	for _, name in EVENT_NAMES do
		if folder:FindFirstChild(name) == nil then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
	for _, name in FUNCTION_NAMES do
		if folder:FindFirstChild(name) == nil then
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
	return folder :: Folder
end

-- Wait for the folder to exist (client startup) and return it.
-- Returns nil when the timeout elapses without the folder appearing.
function Remotes.WaitForFolder(timeout: number?): Folder?
	local folder = getFolder()
	if folder ~= nil then
		return folder
	end
	local found = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, timeout or 10)
	return found :: Folder?
end

function Remotes.GetRemote(name: string): RemoteEvent?
	local folder = getFolder()
	if folder == nil then
		return nil
	end
	return folder:FindFirstChild(name) :: RemoteEvent?
end

function Remotes.GetFunction(name: string): RemoteFunction?
	local folder = getFolder()
	if folder == nil then
		return nil
	end
	return folder:FindFirstChild(name) :: RemoteFunction?
end

-- Fire an event to one client (server) — no-op on the client.
function Remotes.FireClient(name: string, player: Player, ...: any)
	if not RunService:IsServer() then
		return
	end
	local remote = Remotes.GetRemote(name)
	if remote ~= nil then
		remote:FireClient(player, ...)
	end
end

-- Fire an event to every client (server) — no-op on the client.
function Remotes.FireAllClients(name: string, ...: any)
	if not RunService:IsServer() then
		return
	end
	local remote = Remotes.GetRemote(name)
	if remote ~= nil then
		remote:FireAllClients(...)
	end
end

return Remotes
