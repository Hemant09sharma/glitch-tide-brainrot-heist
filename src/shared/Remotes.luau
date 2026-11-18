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
}

-- Events the server fires to clients.
--
-- CONTRACT (QA 2026-11-18, verified by grep over src/server + src/client):
-- every name here is CREATED, but not every name is WIRED. Names with
-- no server handler and no client listener are orphans — firing them
-- is a silent no-op and invoking them errors. Do NOT wire a handler
-- that moves items/currency to a name listed as unwired until its
-- owning service validates it.
--   WIRED (server handler + client use): Attack, UseAbility,
--     SelectCharacter, BuyCharacter, RequestShop, RequestBase,
--     RequestQuests (QuestService.GetQuests, v1.0.1 integration QA),
--     RequestCollection (ProgressionService.GetCollection, v1.0.1),
--     RequestEvents (EventService.GetActiveEvent, v1.0.1), BuyConveyor,
--     PickupBrainrot, DropBrainrot, PlaceBrainrot, StealBrainrot,
--     UpgradeBase, UpgradeBrainrot, CollectIncome,
--     MutateBrainrot, FuseBrainrot, ClaimQuest, Rebirth, EquipCosmetic
--     (ProgressionService, Action="EquipCosmetic" envelope),
--     NPCDialogue (server fires; InteractionController listens).
--   SERVER-FIRED BROADCASTS (no client-to-server handler, by design):
--     PlayerStats, WaveUpdate, RoundUpdate, SpawnEffect, DamageNumber,
--     ConveyorUpdate, BaseUpdate, CarryUpdate, StealAlert,
--     GlitchTideUpdate, QuestUpdate, PowerUpdate (AbilityService fires,
--     AbilityController listens), EventUpdate + TideSurvivor (fired by
--     EventService / TideService; HUDController listens since v1.0.1
--     integration QA and shows them via ShowEventBanner).
--   FIRED BY NO SERVICE YET (client degrades gracefully; reserved for
--     their owning services to fire): BossUpdate, SynergyUpdate.
--   UNWIRED — no server handler AND no client caller/listener:
--     RequestCharacter (legacy; Main.client still waits for it),
--     UsePower (AbilityService uses UseAbility; nothing fires
--     UsePower), SettingsUpdate (no settings sync exists; mute/volume
--     are client-local).
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
}

-- RemoteFunctions (request/response): stats, shop, base state.
local FUNCTION_NAMES: { string } = {
	"RequestShop",
	"RequestBase",
	"RequestQuests",
	"RequestCollection",
	"RequestEvents",
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
