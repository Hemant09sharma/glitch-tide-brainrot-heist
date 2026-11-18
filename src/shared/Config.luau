--!strict
-- Config.luau
-- Central game constants for Glitch Tide — Brainrot Heist: The Memeverse.
-- Every other module reads tuning values from here so balance changes
-- happen in exactly one place.

local Config = {}

Config.GameName = "Glitch Tide — Brainrot Heist: The Memeverse"
Config.GameShortName = "Glitch Tide"
Config.GameVersion = "1.0.2"

-- Round / match flow (seconds)
Config.RoundDuration = 180
Config.IntermissionDuration = 15
Config.LobbyDuration = 20
Config.MinPlayersToStart = 2
Config.MaxPlayers = 12
Config.RespawnTime = 3
Config.RoundEndDelay = 5

-- Movement
Config.BaseWalkSpeed = 16
Config.BaseJumpPower = 50
Config.SprintMultiplier = 1.25

-- Teams
Config.UseTeams = true
Config.Teams = {
	Red = {
		Name = "Red",
		DisplayName = "Red Rotters",
		Color = Color3.fromRGB(220, 60, 60),
		BrickColor = BrickColor.new("Bright red"),
	},
	Blue = {
		Name = "Blue",
		DisplayName = "Blue Brainrots",
		Color = Color3.fromRGB(60, 120, 235),
		BrickColor = BrickColor.new("Bright blue"),
	},
}
Config.FFA_TEAM_NAME = "FreeForAll"

-- Combat
Config.BaseAttackDamage = 12
Config.AttackRange = 6
Config.AttackCooldown = 0.45
Config.KnockbackForce = 18
Config.MaxHealthRegenPerSecond = 2

-- Economy (coins / XP)
Config.CoinPerKO = 25
Config.CoinPerWin = 100
Config.CoinPerAssist = 10
Config.XPPerKO = 20
Config.XPPerWave = 15
Config.XPPerWin = 50
Config.DailyBonus = 50
Config.MaxDailyStreak = 7
Config.StartingCoins = 100

-- Waves (PvE NPC waves that run alongside the arena fight)
Config.WaveInterval = 90
Config.BossEvery = 5
Config.MaxWaveNPCs = 24
Config.WaveNPCHealthBase = 60
Config.WaveNPCHealthPerWave = 18
Config.WaveNPCDamageBase = 8
Config.WaveSpawnDelay = 1.5

-- Canonical keybinds (v1.0.1 — ONE source of truth; fixed 2026-11-18 QA).
-- Before v1.0.1 three different mappings shipped at once: AbilitySlots
-- had Primary/Dash both on Q and Slam on E, GenericAbilities had
-- Q=dash/E=slam/R=heal, and the client actually shipped Q=primary /
-- F=Slam / R=Heal / E=Interact. Q cannot be both the character primary
-- AND Dash, and E is Interact (InteractionController), so Slam moved
-- to F. Dash has no fixed key: it is a loadout power, fired from the
-- loadout bar (keys 1/2/3). AbilityService, CombatService and
-- AbilityController all read these tables; nothing hardcodes a key.
--   Q = character primary ability
--   F = Slam (generic ground slam)
--   R = Heal (generic heal)
--   E = Interact / pickup (NOT an ability key)
--   G = Drop carried Brainrot (NOT an ability key)
--   1/2/3 = equipped loadout powers (see AbilityController)
Config.Keybinds = {
	Primary = "Q",
	Slam = "F",
	Heal = "R",
	Interact = "E",
	Drop = "G",
	Loadout1 = "1",
	Loadout2 = "2",
	Loadout3 = "3",
}

-- Ability slots, keyed by slot name. Values MUST match Config.Keybinds.
Config.AbilitySlots = {
	Primary = "Q",
	Slam = "F",
	Heal = "R",
}
-- The generic abilities every character can use, keyed by input key.
-- Values MUST match Config.Keybinds. Dash is a loadout power, not a
-- generic slot ability, so it has no entry here (it used to sit on Q,
-- colliding with the character primary).
Config.GenericAbilities = {
	F = "slam",
	R = "heal",
}

-- Shop
Config.ShopRefreshSeconds = 30

-- DataStore / persistence keys
Config.DataStoreName = "GlitchTide_Data_v1"
Config.LeaderboardStoreName = "GlitchTide_Leaderboard_v1"
Config.AutosaveInterval = 120

-- Anti-cheat / sanity limits
Config.MaxCoinsPerMatch = 5000
Config.MaxLevel = 100
Config.MaxNameLength = 20

-- -------------------------------------------------------------------------
-- Glitch Tide heist loop: conveyor / bases / carrying / stealing
-- -------------------------------------------------------------------------

-- Conveyor: a new Brainrot spawns on the shared conveyor this often.
Config.ConveyorSpawnInterval = 8
-- Weighted rarity chances for conveyor spawns (weights, not percents).
-- 10-tier weights matching Config.RarityWeights (weights, not percents).
Config.ConveyorRarityWeights = {
	Common = 40,
	Uncommon = 25,
	Rare = 16,
	Epic = 10,
	Legendary = 5,
	Mythic = 2.5,
	Divine = 0.8,
	Celestial = 0.4,
	Secret = 0.2,
	Impossible = 0.1,
}
Config.ConveyorMaxItems = 8
Config.ConveyorLength = 60

-- Personal bases
Config.BaseSlotsStart = 4
Config.BaseSlotsMax = 10
Config.IncomeTickSeconds = 1
Config.BaseIncomeMultiplierStart = 1.0

-- Carrying a Brainrot slows the carrier down.
Config.CarrySpeedMultiplier = 0.6
Config.CarryDropOnDeath = true

-- Stealing from another player's base
Config.StealChannelSeconds = 3
Config.StealCooldownSeconds = 60
Config.StealRewardMultiplier = 0.5 -- thief keeps half the victim's stored income from that Brainrot
Config.BaseLockDuration = 30
-- Raid defense prices (v1.0.1 QA: were hardcoded 100 / 250 in RaidService).
Config.ShieldCost = 100 -- coins for a 60s base shield
Config.ShieldDurationSeconds = 60
Config.LockdownCost = 250 -- coins for a 30s base lockdown
Config.LockdownCooldownSeconds = 120

-- Glitch Tide event: periodically floods the conveyor with glitched
-- Brainrots and doubles income for a short window.
Config.GlitchTideIntervalSeconds = 240
Config.GlitchTideWarningSeconds = 30
Config.GlitchTideDurationSeconds = 60
Config.GlitchTideIncomeMultiplier = 2
Config.GlitchTideGlitchChance = 0.35

-- Upgrade costs, indexed by current level (level 1 -> cost to reach 2, ...).
-- Each table is a flat list; the last entry repeats for higher levels.
Config.BaseSlotCost = { 150, 300, 600, 1200, 2400, 5000 }
Config.IncomeMultiplierCost = { 200, 450, 900, 1800, 3600 }
Config.LockCost = { 100, 250, 500 }
Config.TurretCost = { 400, 900, 2000 }
Config.ConveyorLuckCost = { 250, 600, 1200, 2500 }
Config.BrainrotLevelCost = { 100, 250, 500, 1000, 2000 }
Config.BrainrotLevelIncomeBonus = 0.25 -- +25% income per Brainrot level
Config.MaxBrainrotLevel = 5
Config.MaxUpgradeLevel = 5

-- -------------------------------------------------------------------------
-- Currencies, rarities, tides, mutations, fusion, rebirth, quests, events
-- -------------------------------------------------------------------------

-- The five currencies of the Memeverse and what each one is for.
Config.Currencies = {
	Coins = {
		Name = "Coins",
		Description = "Main currency. Earned from Brainrot income, KOs and wins; spent on the conveyor, upgrades and playable powers.",
	},
	Gems = {
		Name = "Gems",
		Description = "Premium currency. Earned from quests, events and daily bonuses; spent on rare shop offers and instant unlocks.",
	},
	ChaosShards = {
		Name = "Chaos Shards",
		Description = "Earned from Glitch Tide events and boss waves; spent on chaos-tier shop items and rebirth boosts.",
	},
	MutationCrystals = {
		Name = "Mutation Crystals",
		Description = "Earned from quests, events and fusing Brainrots; spent to apply mutations to a Brainrot.",
	},
	EventTokens = {
		Name = "Event Tokens",
		Description = "Earned only during live events; spent in the event shop before the event ends.",
	},
}

-- Weighted rarity chances for conveyor / weighted spawns. These are
-- probabilities and must sum to 1. (ConveyorRarityWeights above is the
-- older weight table kept for backwards compatibility.)
Config.RarityWeights = {
	Common = 0.40,
	Uncommon = 0.25,
	Rare = 0.16,
	Epic = 0.10,
	Legendary = 0.05,
	Mythic = 0.025,
	Divine = 0.008,
	Celestial = 0.004,
	Secret = 0.002,
	Impossible = 0.001,
}

-- Glitch Tide variations: each tide rolls one variation that scales
-- NPC speed, rewards and damage for the whole event window.
-- ONLY these five are playable (TideService rolls from this table).
-- Weight = relative roll weight. SpeedMultiplier scales the wave sweep
-- and NPC speed; RewardMultiplier scales survivor rewards;
-- Damage scales wave + Toxic damage.
Config.TideVariations = {
	Standard = {
		Weight = 40,
		SpeedMultiplier = 1.0,
		RewardMultiplier = 1.0,
		Damage = 1.0,
		Description = "A normal Glitch Tide: glitched Brainrots flood the conveyor and income doubles.",
	},
	Fast = {
		Weight = 20,
		SpeedMultiplier = 1.5,
		RewardMultiplier = 1.25,
		Damage = 1.0,
		Description = "Everything moves half as fast again — conveyor, NPCs and thieves alike.",
	},
	Toxic = {
		Weight = 15,
		SpeedMultiplier = 1.0,
		RewardMultiplier = 1.5,
		Damage = 1.25,
		Description = "Toxic tide: the air itself hurts, but the loot is richer.",
	},
	Frozen = {
		Weight = 15,
		SpeedMultiplier = 0.7,
		RewardMultiplier = 1.5,
		Damage = 1.0,
		Description = "Frozen tide: everything slows to a crawl while rewards stay fat.",
	},
	Meteor = {
		Weight = 10,
		SpeedMultiplier = 1.0,
		RewardMultiplier = 1.75,
		Damage = 1.5,
		Description = "Meteor tide: pastry meteors rain down — dodge them and collect the fallout.",
	},
}

-- Demoted tide variations (v1.0.1 QA): Double, Dark and GiantBoss were
-- listed here in v1.0.0 but TideService had NO behaviour for any of
-- them (no lighting change, no spawn, no damage model) and ForceStart
-- rejected them as unknown. They are NOT in the playable rotation and
-- must not be offered in any UI. Kept here only as a record so a future
-- implementation can promote one by moving it into TideVariations with
-- real behaviour in TideService.
Config.TideVariationsDisabled = {
	Double = {
		SpeedMultiplier = 1.0,
		RewardMultiplier = 2.0,
		Damage = 1.0,
		Description = "DEMOTED (no behaviour): double rewards. Not playable.",
	},
	Dark = {
		SpeedMultiplier = 1.25,
		RewardMultiplier = 1.75,
		Damage = 1.25,
		Description = "DEMOTED (no behaviour): visibility drops. Not playable.",
	},
	GiantBoss = {
		SpeedMultiplier = 0.8,
		RewardMultiplier = 3.0,
		Damage = 2.0,
		Description = "DEMOTED (no behaviour): a giant boss storms the arena. Bosses spawn via BossService instead. Not playable.",
	},
}

-- Mutation costs, in Mutation Crystals, keyed by mutation Id.
Config.MutationCosts = {
	Golden = 50,
	Diamond = 120,
	Rainbow = 200,
	Electric = 40,
	Frozen = 40,
	Toxic = 60,
	Shadow = 100,
	Glitched = 150,
	Cosmic = 180,
	Ancient = 120,
	Void = 300,
	Celestial = 500,
}

-- Fusion costs: coins plus Mutation Crystals per fusion.
Config.FusionCosts = {
	Coins = 1000,
	MutationCrystals = 25,
}

-- Rebirth: what a player must have to rebirth, and what it resets.
-- CANONICAL (v1.0.1 QA): ProgressionService reads every field here.
-- v1.0.0 shipped three contradictions — Config said 10 distinct
-- Brainrots / +10% income / 25 reward gems, ProgressionService
-- enforced 8 PLACED / +25% income / 0 gems and wiped the whole
-- collection. The Config values below win: rebirth requires 10
-- distinct owned Brainrots, pays 25 gems, grants +10% base income per
-- rebirth (stacking, max 10 rebirths), +2 base slots per rebirth, and
-- KEEPS owned characters (only coins / level / XP / placed slots reset;
-- placed Brainrots return to the inventory).
Config.RebirthRequirements = {
	Coins = 100000,
	Level = 25,
	Brainrots = 10, -- distinct Brainrots owned
	RewardGems = 25,
	IncomeBonusPerRebirth = 0.10, -- +10% base income per rebirth, stacking
	SlotsPerRebirth = 2, -- +2 base slots per rebirth
	MaxRebirths = 10,
}

-- Default quest rewards (coins / gems / Mutation Crystals).
Config.QuestRewards = {
	DailyCoins = 250,
	DailyGems = 5,
	DailyMutationCrystals = 10,
	WeeklyCoins = 1500,
	WeeklyGems = 25,
	WeeklyMutationCrystals = 50,
}

-- Default event schedule: Glitch Tide rolls every 4 minutes, a boss
-- tide every 5th tide, and a weekend bonus event.
Config.EventSchedule = {
	GlitchTideIntervalSeconds = 240,
	BossTideEvery = 5,
	WeekendBonusMultiplier = 1.5,
	DailyQuestResetHour = 0, -- midnight server time
}

-- Personal bases: at most 12 plots (Brainrot slots) per base, even
-- after upgrades; BaseSlotsMax above still caps the upgrade path.
-- v1.0.1 QA: was 8 while MaxPlayers is 12, so a full server could not
-- give every player a plot. Now 12 = MaxPlayers.
Config.MaxBasePlots = 12
-- Height (in studs) of the safe zone floor where players cannot be attacked.
Config.SafeZoneHeight = 60
-- First character every new player starts with.
Config.StarterCharacterId = "wobble_waffleton"
-- Gems granted to a brand-new player.
Config.StartingGems = 10

return Config
