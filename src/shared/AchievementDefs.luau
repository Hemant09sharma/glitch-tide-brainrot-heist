--!strict
-- AchievementDefs.luau
-- Shared achievement + title tables (v1.1, Workstream C). All
-- milestones and rewards live HERE, not in Config.luau.
--
-- HOW PROGRESS WORKS: AchievementService.CheckProgress(player, kind,
-- amount) is called by other services (directly, or forwarded through
-- QuestService.ReportProgress). Each achievement listens to ONE kind
-- and unlocks when its cumulative progress reaches Goal. Rewards are
-- paid exactly once, on unlock. Titles are granted into
-- data.Titles (equipping is a Wave 3 client concern; the server stores
-- the equipped title in data.EquippedTitle via
-- AchievementService.SetEquippedTitle).
--
-- KINDS: first_buy, first_place, tide_survived, tide_flawless,
-- boss_defeated, boss_top_damage, boss_participated, fusion, mutation,
-- evolution, expedition, secret, territory, rebirth, prestige,
-- collection, level, event.

local AchievementDefs = {}

export type AchievementReward = {
	Coins: number,
	Gems: number,
	XP: number,
	Crystals: number, -- Mutation Crystals
	Shards: number, -- Chaos Shards
	Tokens: number, -- Event Tokens
}

export type AchievementDef = {
	Id: string,
	Name: string,
	Description: string,
	Kind: string,
	Goal: number,
	Reward: AchievementReward,
	Title: string?, -- title id granted on unlock (nil = no title)
}

-- Player titles granted by achievements. Stored in data.Titles;
-- equipped title stored in data.EquippedTitle (server-side).
export type TitleDef = {
	Id: string,
	Name: string,
	Description: string,
}

local TITLES: { TitleDef } = {
	{ Id = "title_tide_survivor", Name = "Tide Survivor", Description = "Survived a Glitch Tide." },
	{ Id = "title_tide_legend", Name = "Tide Legend", Description = "Survived 25 Glitch Tides." },
	{ Id = "title_boss_slayer", Name = "Boss Slayer", Description = "Defeated a world boss." },
	{ Id = "title_master_fuser", Name = "Master Fuser", Description = "Completed 10 fusions." },
	{ Id = "title_evolutionist", Name = "Evolutionist", Description = "Evolved a Brainrot." },
	{ Id = "title_explorer", Name = "Expedition Leader", Description = "Completed 10 expeditions." },
	{ Id = "title_secret_keeper", Name = "Secret Keeper", Description = "Discovered a hidden secret." },
	{ Id = "title_territory_lord", Name = "Territory Lord", Description = "Captured 5 territories." },
	{ Id = "title_reborn", Name = "Reborn", Description = "Rebirthed for the first time." },
	{ Id = "title_prestiged", Name = "Prestiged", Description = "Reached Prestige." },
	{ Id = "title_collector", Name = "Collector", Description = "Discovered 10 distinct Brainrots." },
	{ Id = "title_completionist", Name = "Completionist", Description = "Discovered all 27 Brainrots." },
	{ Id = "title_legend", Name = "Living Legend", Description = "Reached level 50." },
}

local _titleById: { [string]: TitleDef } = {}
for _, title in ipairs(TITLES) do
	_titleById[title.Id] = title
end

function AchievementDefs.GetTitles(): { TitleDef }
	local copy: { TitleDef } = {}
	for _, title in ipairs(TITLES) do
		table.insert(copy, title)
	end
	return copy
end

function AchievementDefs.GetTitle(titleId: string): TitleDef?
	return _titleById[titleId]
end

local LIST: { AchievementDef } = {
	-- Firsts ------------------------------------------------------------
	{ Id = "ach_first_buy", Name = "First Purchase", Description = "Buy your first Brainrot.", Kind = "first_buy", Goal = 1, Reward = { Coins = 100, Gems = 0, XP = 25, Crystals = 0, Shards = 0, Tokens = 0 }, Title = nil },
	{ Id = "ach_first_place", Name = "Home Maker", Description = "Place your first Brainrot in your base.", Kind = "first_place", Goal = 1, Reward = { Coins = 100, Gems = 0, XP = 25, Crystals = 0, Shards = 0, Tokens = 0 }, Title = nil },
	{ Id = "ach_first_tide", Name = "Tide Survivor", Description = "Survive your first Glitch Tide.", Kind = "tide_survived", Goal = 1, Reward = { Coins = 200, Gems = 5, XP = 50, Crystals = 0, Shards = 0, Tokens = 5 }, Title = "title_tide_survivor" },
	{ Id = "ach_first_boss", Name = "Boss Breaker", Description = "Defeat your first world boss.", Kind = "boss_defeated", Goal = 1, Reward = { Coins = 1000, Gems = 25, XP = 250, Crystals = 0, Shards = 0, Tokens = 20 }, Title = "title_boss_slayer" },
	{ Id = "ach_first_fusion", Name = "Fusion Chef", Description = "Fuse two Brainrots into one.", Kind = "fusion", Goal = 1, Reward = { Coins = 250, Gems = 5, XP = 75, Crystals = 0, Shards = 0, Tokens = 5 }, Title = nil },
	{ Id = "ach_first_mutation", Name = "Mad Scientist", Description = "Mutate a Brainrot.", Kind = "mutation", Goal = 1, Reward = { Coins = 250, Gems = 5, XP = 75, Crystals = 0, Shards = 0, Tokens = 5 }, Title = nil },
	{ Id = "ach_first_evolution", Name = "Evolutionist", Description = "Evolve a max-level Brainrot in the Laboratory.", Kind = "evolution", Goal = 1, Reward = { Coins = 500, Gems = 10, XP = 150, Crystals = 10, Shards = 0, Tokens = 0 }, Title = "title_evolutionist" },
	{ Id = "ach_first_expedition", Name = "Trailblazer", Description = "Complete your first expedition.", Kind = "expedition", Goal = 1, Reward = { Coins = 300, Gems = 5, XP = 100, Crystals = 5, Shards = 0, Tokens = 0 }, Title = nil },
	{ Id = "ach_first_secret", Name = "Secret Keeper", Description = "Discover a hidden secret.", Kind = "secret", Goal = 1, Reward = { Coins = 500, Gems = 15, XP = 150, Crystals = 10, Shards = 1, Tokens = 0 }, Title = "title_secret_keeper" },
	{ Id = "ach_first_territory", Name = "Land Grabber", Description = "Capture your first territory.", Kind = "territory", Goal = 1, Reward = { Coins = 300, Gems = 5, XP = 100, Crystals = 0, Shards = 0, Tokens = 0 }, Title = nil },
	{ Id = "ach_first_rebirth", Name = "Reborn", Description = "Rebirth for the first time.", Kind = "rebirth", Goal = 1, Reward = { Coins = 1000, Gems = 25, XP = 250, Crystals = 25, Shards = 0, Tokens = 0 }, Title = "title_reborn" },
	{ Id = "ach_first_prestige", Name = "Prestiged", Description = "Reach Prestige rank 1.", Kind = "prestige", Goal = 1, Reward = { Coins = 5000, Gems = 100, XP = 1000, Crystals = 100, Shards = 5, Tokens = 0 }, Title = "title_prestiged" },
	-- Cumulative counts -------------------------------------------------
	{ Id = "ach_tides_10", Name = "Tide Veteran", Description = "Survive 10 Glitch Tides.", Kind = "tide_survived", Goal = 10, Reward = { Coins = 1000, Gems = 15, XP = 250, Crystals = 0, Shards = 2, Tokens = 10 }, Title = nil },
	{ Id = "ach_tides_25", Name = "Tide Legend", Description = "Survive 25 Glitch Tides.", Kind = "tide_survived", Goal = 25, Reward = { Coins = 2500, Gems = 25, XP = 500, Crystals = 0, Shards = 5, Tokens = 25 }, Title = "title_tide_legend" },
	{ Id = "ach_bosses_5", Name = "Boss Hunter", Description = "Defeat 5 world bosses.", Kind = "boss_defeated", Goal = 5, Reward = { Coins = 2500, Gems = 50, XP = 500, Crystals = 0, Shards = 5, Tokens = 50 }, Title = nil },
	{ Id = "ach_boss_top_3", Name = "Top Damage", Description = "Deal the most damage to a boss 3 times.", Kind = "boss_top_damage", Goal = 3, Reward = { Coins = 1500, Gems = 25, XP = 300, Crystals = 0, Shards = 3, Tokens = 15 }, Title = nil },
	{ Id = "ach_fusions_10", Name = "Fusion Master", Description = "Complete 10 fusions.", Kind = "fusion", Goal = 10, Reward = { Coins = 2000, Gems = 25, XP = 400, Crystals = 50, Shards = 0, Tokens = 0 }, Title = "title_master_fuser" },
	{ Id = "ach_expeditions_10", Name = "Expedition Leader", Description = "Complete 10 expeditions.", Kind = "expedition", Goal = 10, Reward = { Coins = 2000, Gems = 25, XP = 400, Crystals = 50, Shards = 0, Tokens = 0 }, Title = "title_explorer" },
	{ Id = "ach_secrets_3", Name = "Secret Hunter", Description = "Discover 3 hidden secrets.", Kind = "secret", Goal = 3, Reward = { Coins = 2000, Gems = 50, XP = 500, Crystals = 25, Shards = 3, Tokens = 0 }, Title = nil },
	{ Id = "ach_territories_5", Name = "Territory Lord", Description = "Capture 5 territories.", Kind = "territory", Goal = 5, Reward = { Coins = 1500, Gems = 25, XP = 300, Crystals = 0, Shards = 0, Tokens = 10 }, Title = "title_territory_lord" },
	{ Id = "ach_collection_10", Name = "Collector", Description = "Discover 10 distinct Brainrots.", Kind = "collection", Goal = 10, Reward = { Coins = 1000, Gems = 15, XP = 250, Crystals = 10, Shards = 0, Tokens = 0 }, Title = "title_collector" },
	{ Id = "ach_collection_20", Name = "Master Collector", Description = "Discover 20 distinct Brainrots.", Kind = "collection", Goal = 20, Reward = { Coins = 2500, Gems = 50, XP = 500, Crystals = 25, Shards = 2, Tokens = 0 }, Title = nil },
	{ Id = "ach_collection_27", Name = "Completionist", Description = "Discover all 27 Brainrots.", Kind = "collection", Goal = 27, Reward = { Coins = 10000, Gems = 100, XP = 1000, Crystals = 100, Shards = 10, Tokens = 50 }, Title = "title_completionist" },
	{ Id = "ach_level_50", Name = "Living Legend", Description = "Reach level 50.", Kind = "level", Goal = 50, Reward = { Coins = 5000, Gems = 50, XP = 500, Crystals = 50, Shards = 5, Tokens = 0 }, Title = "title_legend" },
}

local _byId: { [string]: AchievementDef } = {}
for _, def in ipairs(LIST) do
	_byId[def.Id] = def
end

function AchievementDefs.GetAll(): { AchievementDef }
	local copy: { AchievementDef } = {}
	for _, def in ipairs(LIST) do
		table.insert(copy, def)
	end
	return copy
end

function AchievementDefs.GetById(id: string): AchievementDef?
	return _byId[id]
end

function AchievementDefs.GetCount(): number
	return #LIST
end

return AchievementDefs
