--!strict
-- ExpeditionDefs.luau
-- Shared tunables for expeditions (v1.1, Workstream C). All durations,
-- risks, requirements and rewards live HERE, not in Config.luau.
--
-- RISK: the chance (0-1) that the expedition returns REDUCED rewards
-- (half coins, half crystals, no gems/shards, no rare discovery).
-- Risk NEVER loses the Brainrot — the instance always comes home.
-- REQUIREMENTS: MinLevel (instance level), MinRarityRank (1 Common ..
-- 10 Impossible, see Characters.GetRarityRank), MinTrait (one of the
-- instance character's Traits, or nil for no trait requirement).
-- REWARDS: paid in full on a successful claim. RareDiscovery is a
-- chance (0-1) to grant a random UNOWNED Brainrot of at least
-- DiscoveryMinRarity on a successful claim.

export type ExpeditionDef = {
	Id: string,
	Name: string,
	Description: string,
	DurationSeconds: number,
	Risk: number, -- 0..1, chance of reduced rewards
	MinLevel: number,
	MinRarityRank: number, -- 0 = any rarity
	MinTrait: string?,
	RewardCoins: number,
	RewardGems: number,
	RewardCrystals: number, -- Mutation Crystals ("mutation components")
	RewardShards: number, -- Chaos Shards ("rare materials")
	RewardXP: number,
	DiscoveryChance: number, -- 0..1, on a successful claim only
	DiscoveryMinRarity: string?, -- minimum rarity of the discovered Brainrot
	MasteryXP: number, -- mastery XP granted to the expedition Brainrot
}

local ExpeditionDefs = {}

local LIST: { ExpeditionDef } = {
	{
		Id = "exp_market_run",
		Name = "Market Run",
		Description = "A quick courier run through the Rift Market. Safe, short, and pays in pocket change.",
		DurationSeconds = 60,
		Risk = 0.05,
		MinLevel = 1,
		MinRarityRank = 0,
		MinTrait = nil,
		RewardCoins = 100,
		RewardGems = 0,
		RewardCrystals = 5,
		RewardShards = 0,
		RewardXP = 25,
		DiscoveryChance = 0,
		DiscoveryMinRarity = nil,
		MasteryXP = 10,
	},
	{
		Id = "exp_rift_scout",
		Name = "Rift Scouting",
		Description = "Scout the edges of the Forbidden Rift and bring back what the glitch left behind.",
		DurationSeconds = 300,
		Risk = 0.15,
		MinLevel = 2,
		MinRarityRank = 0,
		MinTrait = nil,
		RewardCoins = 500,
		RewardGems = 5,
		RewardCrystals = 10,
		RewardShards = 1,
		RewardXP = 75,
		DiscoveryChance = 0.10,
		DiscoveryMinRarity = "Rare",
		MasteryXP = 25,
	},
	{
		Id = "exp_tide_salvage",
		Name = "Tide Salvage",
		Description = "Pick through the debris the last Glitch Tide threw ashore. Something valuable always washes up.",
		DurationSeconds = 600,
		Risk = 0.20,
		MinLevel = 2,
		MinRarityRank = 0,
		MinTrait = nil,
		RewardCoins = 800,
		RewardGems = 5,
		RewardCrystals = 15,
		RewardShards = 3,
		RewardXP = 100,
		DiscoveryChance = 0.15,
		DiscoveryMinRarity = "Rare",
		MasteryXP = 40,
	},
	{
		Id = "exp_abyssal_dive",
		Name = "Abyssal Dive",
		Description = "Dive the sunken kingdom and pry treasure from the drowned ruins. The currents do not forgive the weak.",
		DurationSeconds = 900,
		Risk = 0.25,
		MinLevel = 3,
		MinRarityRank = 3, -- Rare+
		MinTrait = "Water",
		RewardCoins = 1500,
		RewardGems = 10,
		RewardCrystals = 25,
		RewardShards = 2,
		RewardXP = 150,
		DiscoveryChance = 0.25,
		DiscoveryMinRarity = "Epic",
		MasteryXP = 60,
	},
	{
		Id = "exp_skyfall_survey",
		Name = "Skyfall Survey",
		Description = "Chart the floating islands and catch what the crosswinds carry. Only the swift need apply.",
		DurationSeconds = 900,
		Risk = 0.25,
		MinLevel = 3,
		MinRarityRank = 4, -- Epic+
		MinTrait = "Cosmic",
		RewardCoins = 1500,
		RewardGems = 10,
		RewardCrystals = 25,
		RewardShards = 2,
		RewardXP = 150,
		DiscoveryChance = 0.25,
		DiscoveryMinRarity = "Epic",
		MasteryXP = 60,
	},
	{
		Id = "exp_void_expedition",
		Name = "Void Expedition",
		Description = "Into the dark between dimensions. Half the crews come back rich; the other half come back changed. The Brainrot always comes back.",
		DurationSeconds = 1800,
		Risk = 0.40,
		MinLevel = 5,
		MinRarityRank = 5, -- Legendary+
		MinTrait = "Glitch",
		RewardCoins = 5000,
		RewardGems = 25,
		RewardCrystals = 50,
		RewardShards = 5,
		RewardXP = 400,
		DiscoveryChance = 0.50,
		DiscoveryMinRarity = "Legendary",
		MasteryXP = 100,
	},
}

local _byId: { [string]: ExpeditionDef } = {}
for _, def in ipairs(LIST) do
	_byId[def.Id] = def
end

function ExpeditionDefs.GetAll(): { ExpeditionDef }
	local copy: { ExpeditionDef } = {}
	for _, def in ipairs(LIST) do
		table.insert(copy, def)
	end
	return copy
end

function ExpeditionDefs.GetById(id: string): ExpeditionDef?
	return _byId[id]
end

return ExpeditionDefs
