--!strict
-- Types.luau
-- Shared Luau type definitions for Glitch Tide — Brainrot Heist: The Memeverse.

export type CharacterDef = {
	Id: string,
	Name: string,
	DisplayName: string,
	Rarity: string,
	Cost: number,
	IncomePerSec: number,
	Description: string,
	Health: number,
	Speed: number,
	Damage: number,
	AbilityId: string,
	DefenseTrait: string,
	Traits: { string },
	Color: Color3,
	AccentColor: Color3,
	Scale: number,
	MutationCompatibility: { string },
	Personality: string,
	UnlockCondition: string,
	BuildSpec: {
		BodyColor: Color3,
		HeadColor: Color3,
		BodyShape: string,
		Prop: string,
		PropColor: Color3,
	},
}

export type PowerDef = {
	Id: string,
	Name: string,
	Key: string,
	Cooldown: number,
	Damage: number,
	Range: number,
	Radius: number,
	Effect: string,
	Description: string,
	Color: Color3,
}

export type PlayerData = {
	UserId: number,
	CharacterId: string,
	Coins: number,
	XP: number,
	Level: number,
	Wins: number,
	KOs: number,
	Deaths: number,
	BestStreak: number,
	CurrentStreak: number,
	OwnedCharacters: { string },
	LastDailyClaim: number,
	DailyStreak: number,
	TotalMatches: number,
	TotalEarned: number,
	TotalStolen: number,
	TotalSteals: number,
	HeistsCompleted: number,
	-- Extended balances / registries. DataService.DEFAULT_DATA only
	-- seeds Coins/XP/Level/Unlocked/Selected/Wins/KOs; the other
	-- services create these fields on first use (always read them via
	-- `tonumber(data.X) or 0` / `type(data.X) == "table"` guards, never
	-- bare). Gems etc. are NOT in DEFAULT_DATA — do not assume a fresh
	-- save has them.
	Gems: number?,
	ChaosShards: number?,
	MutationCrystals: number?,
	EventTokens: number?,
	BankedIncome: number?,
	Rebirths: number?,
	OwnedInstances: { OwnedBrainrot }?,
	Unlocked: { string }?,
	Selected: string?,
}

-- One quest as QuestService.GetQuests returns it (QuestUpdate push and
-- the RequestQuests reply share this shape). Title/Name and
-- Description/Desc spellings both occur across services; readers
-- should accept either.
export type QuestDef = {
	Id: string,
	Title: string?,
	Name: string?,
	Description: string?,
	Desc: string?,
	Progress: number,
	Goal: number,
	Reward: string?,
	Claimed: boolean?,
	CanClaim: boolean?,
	Completed: boolean?,
}

-- NPCDialogue payload, fired by NPCService when a vendor / quest-giver
-- ProximityPrompt triggers: { NPC = "Vendor" | "QuestGiver",
-- Lines = { ... }, Hint = string? }.
export type NPCDialoguePayload = {
	NPC: string,
	Lines: { string },
	Hint: string?,
}

-- CarryUpdate payload, fired by CarryService: the carried Brainrot's
-- server InstanceId (NOT its CharacterId — PlaceBrainrot matches on
-- InstanceId; sending a CharacterId is always rejected).
export type CarryUpdatePayload = {
	Carrying: boolean,
	InstanceId: string?,
	CharacterId: string?,
	Glitched: boolean,
	Stolen: boolean?,
	CarryStartedAt: number?,
}

-- One Brainrot placed on a slot inside a player's base.
export type PlacedBrainrot = {
	InstanceId: string,
	CharacterId: string,
	Slot: number,
	Level: number,
	Glitched: boolean,
	Mutation: string?,
	BankedIncome: number,
	PlacedAt: number,
}

-- One Brainrot owned by a player, whether placed or in storage.
export type OwnedBrainrot = {
	InstanceId: string,
	CharacterId: string,
	Level: number,
	Mutation: string?,
	PlacedSlot: number?,
	AcquiredAt: number,
}

-- A player's currency balances.
export type PlayerCurrencies = {
	Coins: number,
	Gems: number,
	ChaosShards: number,
	MutationCrystals: number,
	EventTokens: number,
}

-- One mutation definition (see Mutations.luau).
export type MutationDef = {
	Id: string,
	Name: string,
	IncomeMultiplier: number,
	Cost: number,
	Color: Color3,
	Material: string,
	ParticleColor: Color3,
	Description: string,
	RarityWeight: number,
}

-- One trait synergy rule (see Synergies.luau).
export type SynergyDef = {
	Name: string,
	Traits: { string },
	MinCount: number,
	IncomeBonus: number,
	Description: string,
}

-- One playable power definition (see Powers.luau).
export type PlayablePowerDef = {
	Id: string,
	Name: string,
	Cooldown: number,
	Duration: number,
	Cost: number,
	Damage: number,
	Range: number,
	Radius: number,
	Effect: string,
	Description: string,
	Color: Color3,
}

-- A player's personal base: slots, upgrades, lock state, stored income.
export type BaseData = {
	OwnerUserId: number,
	Slots: number,
	IncomeMultiplier: number,
	IncomeMultiplierLevel: number,
	LockLevel: number,
	TurretLevel: number,
	ConveyorLuckLevel: number,
	LockedUntil: number,
	Placed: { PlacedBrainrot },
	StoredCoins: number,
	TotalEarned: number,
}

-- One Brainrot currently riding the shared conveyor.
export type ConveyorItem = {
	InstanceId: string,
	CharacterId: string,
	Glitched: boolean,
	Price: number,
	Position: number, -- 0..1 along the conveyor
	SpawnedAt: number,
}

-- What a player is currently carrying (at most one Brainrot at a time).
export type CarryState = {
	Carrying: boolean,
	InstanceId: string?,
	CharacterId: string?,
	Glitched: boolean,
	CarryStartedAt: number,
}

-- Glitch Tide event phase broadcast to all clients.
export type GlitchTidePhase = {
	Phase: string, -- "Idle" | "Warning" | "Active"
	TimeLeft: number,
	NextTideIn: number,
	IncomeMultiplier: number,
	GlitchChance: number,
}

export type MatchState = {
	Phase: string, -- "Lobby" | "Intermission" | "Round" | "Ended"
	RoundNumber: number,
	TimeLeft: number,
	RedScore: number,
	BlueScore: number,
	Wave: number,
	Winner: string?,
}

export type WaveState = {
	Wave: number,
	IsBossWave: boolean,
	RemainingNPCs: number,
	TotalNPCs: number,
	NextWaveIn: number,
}

export type ShopItem = {
	Id: string,
	Kind: string, -- "Character" | "Power" | "Cosmetic"
	Name: string,
	Description: string,
	Cost: number,
	CharacterId: string?,
	PowerId: string?,
	Owned: boolean,
}

export type RemotePayload = {
	Action: string,
	Player: Player?,
	Data: { [string]: any }?,
	Success: boolean,
	Message: string?,
}

return {}
