--!strict
-- Characters.luau
-- The 18 collectible Brainrots of Glitch Tide — Brainrot Heist: The
-- Memeverse. All 18 are ORIGINAL characters created for this game: each
-- one has a distinct silhouette, body shape, signature prop and colour
-- palette — never a recolour of another entry. CharacterModels.luau
-- reads BuildSpec to build the procedural models.
--
-- Rarity ladder (10 tiers): Common, Uncommon, Rare, Epic, Legendary,
-- Mythic, Divine, Celestial, Secret, Impossible.

export type BuildSpec = {
	BodyColor: Color3,
	HeadColor: Color3,
	BodyShape: string, -- "Waffle" | "Turnip" | "Jelly" | "Comet" | "Noodle" | "ToastGhost" | "Dumpling" | "PicklePirate" | "Mochi" | "Gumball" | "SoupShip" | "Puddle" | "Spaghetti" | "Zucchini" | "Cupcake" | "Goose" | "Crab" | "WobbleKing"
	Prop: string,
	PropColor: Color3,
}

export type CharacterDef = {
	Id: string,
	Name: string,
	DisplayName: string,
	Rarity: string, -- "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Divine" | "Celestial" | "Secret" | "Impossible"
	Cost: number,
	IncomePerSec: number,
	Description: string,
	Health: number,
	Speed: number,
	Damage: number,
	AbilityId: string,
	DefenseTrait: string,
	Traits: { string }, -- 2-3 of: "Electric" | "Cosmic" | "Food" | "Royal" | "Mechanical" | "Water" | "Glitch" | "Ancient"
	Color: Color3,
	AccentColor: Color3,
	Scale: number,
	MutationCompatibility: { string }, -- mutation Ids this character can receive
	Personality: string,
	UnlockCondition: string,
	BuildSpec: BuildSpec,
}

local Characters = {}

-- Income bands by rarity (coins per second, before level/mutation):
-- Common 3-8, Uncommon 8-20, Rare 20-60, Epic 60-150,
-- Legendary 150-500, Mythic 500-1500, Divine 1500-4000,
-- Celestial 4000-8000, Secret 8000-15000, Impossible 15000+.
local LIST: { CharacterDef } = {
	-- Common --------------------------------------------------------------
	{
		Id = "wobble_waffleton",
		Name = "Wobble Waffleton",
		DisplayName = "Wobble Waffleton",
		Rarity = "Common",
		Cost = 0,
		IncomePerSec = 5,
		Description = "A cheerful waffle creature tottering around on tiny mechanical legs. Golden, crispy and free for every player — the first friend of every heist crew.",
		Health = 120,
		Speed = 15,
		Damage = 14,
		AbilityId = "waffle_wobble",
		DefenseTrait = "Sturdy",
		Traits = { "Food", "Mechanical" },
		Color = Color3.fromRGB(214, 164, 65),
		AccentColor = Color3.fromRGB(90, 60, 30),
		Scale = 0.95,
		MutationCompatibility = { "Golden", "Electric", "Frozen", "Toxic", "Rainbow", "Ancient", "Cosmic", "Glitched" },
		Personality = "Cheerful and wobbly; never stops jiggling, even when startled.",
		UnlockCondition = "Starter — given to every new player.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(214, 164, 65),
			HeadColor = Color3.fromRGB(235, 190, 90),
			BodyShape = "Waffle",
			Prop = "GearLegs",
			PropColor = Color3.fromRGB(120, 130, 140),
		},
	},
	{
		Id = "turbo_turnip",
		Name = "Turbo Turnip",
		DisplayName = "Turbo Turnip",
		Rarity = "Common",
		Cost = 120,
		IncomePerSec = 8,
		Description = "A plucky purple turnip in oversized red racing boots. It revs, it zooms, it trips over its own feet — and it always gets back up faster.",
		Health = 110,
		Speed = 22,
		Damage = 15,
		AbilityId = "turbo_boost",
		DefenseTrait = "Swift",
		Traits = { "Food", "Mechanical" },
		Color = Color3.fromRGB(200, 120, 220),
		AccentColor = Color3.fromRGB(220, 40, 40),
		Scale = 0.95,
		MutationCompatibility = { "Golden", "Electric", "Frozen", "Toxic", "Rainbow", "Shadow", "Cosmic", "Glitched" },
		Personality = "Impatient speedster; treats every hallway like a racetrack.",
		UnlockCondition = "Buy from the conveyor for 120 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(200, 120, 220),
			HeadColor = Color3.fromRGB(225, 160, 240),
			BodyShape = "Turnip",
			Prop = "RacingBoots",
			PropColor = Color3.fromRGB(220, 40, 40),
		},
	},

	-- Uncommon ------------------------------------------------------------
	{
		Id = "bloop_bloomington",
		Name = "Bloop Bloomington",
		DisplayName = "Bloop Bloomington",
		Rarity = "Uncommon",
		Cost = 400,
		IncomePerSec = 15,
		Description = "A double-layered jelly creature with a glowing core wobbling inside it. Thieves bounce straight off — Bloop just jiggles and keeps glowing.",
		Health = 150,
		Speed = 13,
		Damage = 16,
		AbilityId = "jelly_splash",
		DefenseTrait = "Bouncy",
		Traits = { "Water", "Food" },
		Color = Color3.fromRGB(255, 150, 200),
		AccentColor = Color3.fromRGB(120, 220, 240),
		Scale = 1.0,
		MutationCompatibility = { "Golden", "Frozen", "Toxic", "Rainbow", "Shadow", "Cosmic", "Glitched", "Void" },
		Personality = "Calm and squishy; communicates entirely in gentle bloops.",
		UnlockCondition = "Buy from the conveyor for 400 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(255, 150, 200),
			HeadColor = Color3.fromRGB(255, 190, 220),
			BodyShape = "Jelly",
			Prop = "InnerCore",
			PropColor = Color3.fromRGB(120, 220, 240),
		},
	},
	{
		Id = "crumb_comet",
		Name = "Crumb Comet",
		DisplayName = "Crumb Comet",
		Rarity = "Uncommon",
		Cost = 650,
		IncomePerSec = 18,
		Description = "A flying pastry comet streaking through the Memeverse with a glowing golden trail. It never lands — it just orbits your base, dropping crumbs of luck.",
		Health = 110,
		Speed = 24,
		Damage = 20,
		AbilityId = "comet_crash",
		DefenseTrait = "Swift",
		Traits = { "Cosmic", "Food" },
		Color = Color3.fromRGB(255, 170, 60),
		AccentColor = Color3.fromRGB(255, 230, 120),
		Scale = 0.95,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Void" },
		Personality = "Dramatic show-off; announces every entrance with a sonic boom.",
		UnlockCondition = "Buy from the conveyor for 650 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(255, 170, 60),
			HeadColor = Color3.fromRGB(255, 205, 100),
			BodyShape = "Comet",
			Prop = "GlowTrail",
			PropColor = Color3.fromRGB(255, 230, 120),
		},
	},

	-- Rare ----------------------------------------------------------------
	{
		Id = "noodle_nebula",
		Name = "Noodle Nebula",
		DisplayName = "Noodle Nebula",
		Rarity = "Rare",
		Cost = 1200,
		IncomePerSec = 35,
		Description = "A floating noodle monster tangled in its own strands, with tiny stars orbiting its head. Its whips crack like lightning across the arena.",
		Health = 140,
		Speed = 17,
		Damage = 22,
		AbilityId = "noodle_whip",
		DefenseTrait = "Tricky",
		Traits = { "Cosmic", "Food" },
		Color = Color3.fromRGB(245, 220, 160),
		AccentColor = Color3.fromRGB(150, 100, 255),
		Scale = 1.0,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Ancient" },
		Personality = "Dreamy and tangled; forgets where its own arms end.",
		UnlockCondition = "Buy from the conveyor for 1200 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(245, 220, 160),
			HeadColor = Color3.fromRGB(250, 235, 190),
			BodyShape = "Noodle",
			Prop = "StarSprinkles",
			PropColor = Color3.fromRGB(150, 100, 255),
		},
	},
	{
		Id = "toast_ghost",
		Name = "Toast Ghost",
		DisplayName = "Toast Ghost",
		Rarity = "Rare",
		Cost = 1800,
		IncomePerSec = 45,
		Description = "A haunted slice of toast that drifts through walls and moans softly about being under-buttered. Thieves swing at it and hit nothing but cold air.",
		Health = 100,
		Speed = 20,
		Damage = 24,
		AbilityId = "toast_haunt",
		DefenseTrait = "PhaseShift",
		Traits = { "Food", "Glitch" },
		Color = Color3.fromRGB(230, 190, 130),
		AccentColor = Color3.fromRGB(200, 220, 255),
		Scale = 1.0,
		MutationCompatibility = { "Golden", "Frozen", "Shadow", "Glitched", "Cosmic", "Void", "Celestial", "Ancient" },
		Personality = "Spooky but polite; apologises after every haunting.",
		UnlockCondition = "Buy from the conveyor for 1800 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(230, 190, 130),
			HeadColor = Color3.fromRGB(245, 215, 160),
			BodyShape = "ToastGhost",
			Prop = "GhostSheet",
			PropColor = Color3.fromRGB(200, 220, 255),
		},
	},
	{
		Id = "disco_dumpling",
		Name = "Disco Dumpling",
		DisplayName = "Disco Dumpling",
		Rarity = "Rare",
		Cost = 2500,
		IncomePerSec = 55,
		Description = "A dancing dumpling with a tiny disco ball and lights that pulse to a beat only it can hear. Enemies stop to watch — then regret it.",
		Health = 135,
		Speed = 18,
		Damage = 21,
		AbilityId = "disco_fever",
		DefenseTrait = "Dazzle",
		Traits = { "Food", "Electric" },
		Color = Color3.fromRGB(255, 120, 180),
		AccentColor = Color3.fromRGB(80, 255, 220),
		Scale = 0.95,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Glitched", "Cosmic", "Celestial", "Diamond" },
		Personality = "Pure party energy; cannot stand still for more than two seconds.",
		UnlockCondition = "Buy from the conveyor for 2500 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(255, 120, 180),
			HeadColor = Color3.fromRGB(255, 160, 205),
			BodyShape = "Dumpling",
			Prop = "DiscoBall",
			PropColor = Color3.fromRGB(200, 220, 255),
		},
	},

	-- Epic ----------------------------------------------------------------
	{
		Id = "captain_picklebyte",
		Name = "Captain Picklebyte",
		DisplayName = "Captain Picklebyte",
		Rarity = "Epic",
		Cost = 4500,
		IncomePerSec = 90,
		Description = "A robotic pickle pirate with a brass hat, a steel jaw and a laser cutlass. It sails the conveyor seas plundering coins for its captain's crew.",
		Health = 200,
		Speed = 15,
		Damage = 28,
		AbilityId = "pickle_blast",
		DefenseTrait = "Armored",
		Traits = { "Mechanical", "Food" },
		Color = Color3.fromRGB(80, 180, 70),
		AccentColor = Color3.fromRGB(220, 180, 60),
		Scale = 1.05,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Glitched", "Cosmic", "Diamond", "Ancient" },
		Personality = "Gruff sea captain; shouts orders at the other Brainrots.",
		UnlockCondition = "Buy from the conveyor for 4500 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(80, 180, 70),
			HeadColor = Color3.fromRGB(110, 205, 90),
			BodyShape = "PicklePirate",
			Prop = "PirateHat",
			PropColor = Color3.fromRGB(220, 180, 60),
		},
	},
	{
		Id = "moon_mochi",
		Name = "Moon Mochi",
		DisplayName = "Moon Mochi",
		Rarity = "Epic",
		Cost = 6000,
		IncomePerSec = 120,
		Description = "A floating lunar dessert, soft as a cloud and glowing with moonlight. It bounces thieves away with a gentle boing and a smile.",
		Health = 130,
		Speed = 19,
		Damage = 26,
		AbilityId = "mochi_bounce",
		DefenseTrait = "Bouncy",
		Traits = { "Cosmic", "Food" },
		Color = Color3.fromRGB(245, 245, 255),
		AccentColor = Color3.fromRGB(180, 160, 255),
		Scale = 1.0,
		MutationCompatibility = { "Golden", "Frozen", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Diamond" },
		Personality = "Serene and soft; hums lullabies while guarding the base.",
		UnlockCondition = "Buy from the conveyor for 6000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(245, 245, 255),
			HeadColor = Color3.fromRGB(255, 255, 255),
			BodyShape = "Mochi",
			Prop = "MoonCrest",
			PropColor = Color3.fromRGB(180, 160, 255),
		},
	},
	{
		Id = "giga_gumball",
		Name = "Giga Gumball",
		DisplayName = "Giga Gumball",
		Rarity = "Epic",
		Cost = 8000,
		IncomePerSec = 145,
		Description = "An enormous rolling candy beast the size of a boulder, swirled with every flavour at once. It flattens thieves by simply rolling over them.",
		Health = 260,
		Speed = 16,
		Damage = 32,
		AbilityId = "gumball_roll",
		DefenseTrait = "Sturdy",
		Traits = { "Food", "Ancient" },
		Color = Color3.fromRGB(230, 60, 90),
		AccentColor = Color3.fromRGB(90, 200, 255),
		Scale = 1.25,
		MutationCompatibility = { "Golden", "Rainbow", "Shadow", "Glitched", "Cosmic", "Diamond", "Ancient", "Void" },
		Personality = "Slow, sweet and unstoppable; thinks in flavours, not words.",
		UnlockCondition = "Buy from the conveyor for 8000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(230, 60, 90),
			HeadColor = Color3.fromRGB(240, 100, 120),
			BodyShape = "Gumball",
			Prop = "CandySwirl",
			PropColor = Color3.fromRGB(90, 200, 255),
		},
	},

	-- Legendary -----------------------------------------------------------
	{
		Id = "miso_mothership",
		Name = "Miso Mothership",
		DisplayName = "Miso Mothership",
		Rarity = "Legendary",
		Cost = 15000,
		IncomePerSec = 250,
		Description = "A flying soup-bowl spaceship with steaming broth engines and a crew of tiny tofu pilots. It beams coins down from orbit straight into your base.",
		Health = 190,
		Speed = 17,
		Damage = 30,
		AbilityId = "miso_beam",
		DefenseTrait = "Shielded",
		Traits = { "Cosmic", "Mechanical" },
		Color = Color3.fromRGB(70, 120, 220),
		AccentColor = Color3.fromRGB(255, 160, 60),
		Scale = 1.15,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Diamond", "Ancient" },
		Personality = "Commanding and warm; runs the base like a starship bridge.",
		UnlockCondition = "Buy from the conveyor for 15000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(70, 120, 220),
			HeadColor = Color3.fromRGB(100, 150, 235),
			BodyShape = "SoupShip",
			Prop = "SoupAntenna",
			PropColor = Color3.fromRGB(255, 160, 60),
		},
	},
	{
		Id = "puddle_professor",
		Name = "Puddle Professor",
		DisplayName = "Puddle Professor",
		Rarity = "Legendary",
		Cost = 22000,
		IncomePerSec = 380,
		Description = "An intelligent liquid creature in tiny gold glasses who lectures thieves on fluid dynamics while dissolving their escape plans.",
		Health = 160,
		Speed = 16,
		Damage = 28,
		AbilityId = "puddle_splash",
		DefenseTrait = "LiquidForm",
		Traits = { "Water", "Ancient" },
		Color = Color3.fromRGB(60, 140, 255),
		AccentColor = Color3.fromRGB(220, 180, 60),
		Scale = 1.0,
		MutationCompatibility = { "Golden", "Frozen", "Toxic", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Diamond", "Ancient" },
		Personality = "Brilliant and drippy; corrects everyone's grammar mid-battle.",
		UnlockCondition = "Buy from the conveyor for 22000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(60, 140, 255),
			HeadColor = Color3.fromRGB(100, 170, 255),
			BodyShape = "Puddle",
			Prop = "TinyGlasses",
			PropColor = Color3.fromRGB(220, 180, 60),
		},
	},

	-- Mythic --------------------------------------------------------------
	{
		Id = "springy_spaghetti",
		Name = "Springy Spaghetti",
		DisplayName = "Springy Spaghetti",
		Rarity = "Mythic",
		Cost = 40000,
		IncomePerSec = 700,
		Description = "A spring-legged pasta creature that boings across the arena at impossible speed, trailing tomato-sauce sparks. Nobody has ever seen it stand still.",
		Health = 170,
		Speed = 23,
		Damage = 34,
		AbilityId = "spaghetti_spring",
		DefenseTrait = "Swift",
		Traits = { "Food", "Electric" },
		Color = Color3.fromRGB(250, 210, 80),
		AccentColor = Color3.fromRGB(220, 60, 40),
		Scale = 1.1,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Diamond", "Ancient", "Void" },
		Personality = "Hyperactive and springy; boings first, thinks later.",
		UnlockCondition = "Buy from the conveyor for 40000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(250, 210, 80),
			HeadColor = Color3.fromRGB(255, 225, 120),
			BodyShape = "Spaghetti",
			Prop = "SpringLegs",
			PropColor = Color3.fromRGB(220, 60, 40),
		},
	},
	{
		Id = "zap_zucchini",
		Name = "Zap Zucchini",
		DisplayName = "Zap Zucchini",
		Rarity = "Mythic",
		Cost = 60000,
		IncomePerSec = 1100,
		Description = "An electrical vegetable crackling with stored storms. Its tesla coil hums day and night, and its bolts fry any thief dumb enough to touch it.",
		Health = 180,
		Speed = 21,
		Damage = 38,
		AbilityId = "zap_bolt",
		DefenseTrait = "ShockAura",
		Traits = { "Electric", "Food" },
		Color = Color3.fromRGB(90, 200, 80),
		AccentColor = Color3.fromRGB(255, 230, 60),
		Scale = 1.1,
		MutationCompatibility = { "Golden", "Electric", "Rainbow", "Shadow", "Glitched", "Cosmic", "Celestial", "Diamond", "Ancient", "Void" },
		Personality = "Buzzing with energy; finishes other people's sentences with static.",
		UnlockCondition = "Buy from the conveyor for 60000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(90, 200, 80),
			HeadColor = Color3.fromRGB(120, 220, 100),
			BodyShape = "Zucchini",
			Prop = "TeslaCoil",
			PropColor = Color3.fromRGB(255, 230, 60),
		},
	},

	-- Divine --------------------------------------------------------------
	{
		Id = "cosmic_cupcake",
		Name = "Cosmic Cupcake",
		DisplayName = "Cosmic Cupcake",
		Rarity = "Divine",
		Cost = 120000,
		IncomePerSec = 2200,
		Description = "A dessert crowned with frosting and wrapped in glowing planetary rings. Entire tiny moons orbit its cherry — and its income orbits your vault.",
		Health = 220,
		Speed = 18,
		Damage = 40,
		AbilityId = "cosmic_ring",
		DefenseTrait = "RingGuard",
		Traits = { "Cosmic", "Food", "Royal" },
		Color = Color3.fromRGB(255, 170, 210),
		AccentColor = Color3.fromRGB(60, 40, 120),
		Scale = 1.15,
		MutationCompatibility = { "Golden", "Rainbow", "Shadow", "Cosmic", "Glitched", "Celestial", "Diamond", "Ancient", "Void" },
		Personality = "Regal and sweet; expects to be addressed as 'Your Deliciousness'.",
		UnlockCondition = "Buy from the conveyor for 120000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(255, 170, 210),
			HeadColor = Color3.fromRGB(255, 200, 225),
			BodyShape = "Cupcake",
			Prop = "PlanetRings",
			PropColor = Color3.fromRGB(60, 40, 120),
		},
	},

	-- Celestial -----------------------------------------------------------
	{
		Id = "glitchy_goose",
		Name = "Glitchy Goose",
		DisplayName = "Glitchy Goose",
		Rarity = "Celestial",
		Cost = 250000,
		IncomePerSec = 4500,
		Description = "An unstable pixelated bird that flickers in and out of reality, honking in corrupted audio. It steals from thieves before they can steal from you.",
		Health = 240,
		Speed = 25,
		Damage = 44,
		AbilityId = "glitch_flicker",
		DefenseTrait = "GlitchField",
		Traits = { "Glitch", "Cosmic" },
		Color = Color3.fromRGB(240, 240, 245),
		AccentColor = Color3.fromRGB(255, 60, 200),
		Scale = 1.1,
		MutationCompatibility = { "Golden", "Rainbow", "Shadow", "Glitched", "Cosmic", "Celestial", "Diamond", "Void", "Ancient" },
		Personality = "Chaotic and honking; exists in three places at once, none of them helpful.",
		UnlockCondition = "Buy from the conveyor for 250000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(240, 240, 245),
			HeadColor = Color3.fromRGB(255, 255, 255),
			BodyShape = "Goose",
			Prop = "PixelWings",
			PropColor = Color3.fromRGB(255, 60, 200),
		},
	},

	-- Secret --------------------------------------------------------------
	{
		Id = "caramel_crab",
		Name = "Caramel Crab",
		DisplayName = "Caramel Crab",
		Rarity = "Secret",
		Cost = 500000,
		IncomePerSec = 9000,
		Description = "A caramel-coated crab with oversized golden claws that snap shut on thieves like a vault door. It side-steps through your base, dripping liquid gold.",
		Health = 300,
		Speed = 14,
		Damage = 48,
		AbilityId = "caramel_claw",
		DefenseTrait = "Armored",
		Traits = { "Food", "Royal" },
		Color = Color3.fromRGB(200, 130, 50),
		AccentColor = Color3.fromRGB(230, 190, 90),
		Scale = 1.2,
		MutationCompatibility = { "Golden", "Rainbow", "Shadow", "Cosmic", "Celestial", "Diamond", "Ancient", "Void" },
		Personality = "Slow, rich and menacing; clicks its claws when it is pleased.",
		UnlockCondition = "Buy from the conveyor for 500000 coins.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(200, 130, 50),
			HeadColor = Color3.fromRGB(220, 155, 70),
			BodyShape = "Crab",
			Prop = "GiantClaws",
			PropColor = Color3.fromRGB(230, 190, 90),
		},
	},

	-- Impossible ----------------------------------------------------------
	{
		Id = "wobble_king",
		Name = "The Wobble King",
		DisplayName = "The Wobble King",
		Rarity = "Impossible",
		Cost = 1000000,
		IncomePerSec = 18000,
		Description = "The legendary ruler of the Memeverse: a colossal golden waffle wearing a crown, a cape and a sceptre that wobbles with the weight of a thousand heists. Only one crew in a thousand ever sees him.",
		Health = 400,
		Speed = 16,
		Damage = 60,
		AbilityId = "royal_wobble",
		DefenseTrait = "RoyalGuard",
		Traits = { "Royal", "Ancient", "Glitch" },
		Color = Color3.fromRGB(230, 190, 60),
		AccentColor = Color3.fromRGB(120, 60, 200),
		Scale = 1.4,
		MutationCompatibility = { "Golden", "Diamond", "Rainbow", "Electric", "Frozen", "Toxic", "Shadow", "Glitched", "Cosmic", "Ancient", "Void", "Celestial" },
		Personality = "Majestic and wobbly; every step is a royal decree.",
		UnlockCondition = "Buy from the conveyor for 1000000 coins — if he ever appears.",
		BuildSpec = {
			BodyColor = Color3.fromRGB(230, 190, 60),
			HeadColor = Color3.fromRGB(245, 210, 90),
			BodyShape = "WobbleKing",
			Prop = "RoyalCrown",
			PropColor = Color3.fromRGB(120, 60, 200),
		},
	},
}

local BY_ID: { [string]: CharacterDef } = {}
for _, def in LIST do
	BY_ID[def.Id] = def
end

local RARITY_ORDER: { [string]: number } = {
	Common = 1,
	Uncommon = 2,
	Rare = 3,
	Epic = 4,
	Legendary = 5,
	Mythic = 6,
	Divine = 7,
	Celestial = 8,
	Secret = 9,
	Impossible = 10,
}

local RARITY_LIST: { string } = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Divine",
	"Celestial",
	"Secret",
	"Impossible",
}

-- Income band (min, max) per rarity, used by the conveyor to sanity
-- check any new income value before it is assigned.
local RARITY_INCOME: { [string]: { number } } = {
	Common = { 3, 8 },
	Uncommon = { 8, 20 },
	Rare = { 20, 60 },
	Epic = { 60, 150 },
	Legendary = { 150, 500 },
	Mythic = { 500, 1500 },
	Divine = { 1500, 4000 },
	Celestial = { 4000, 8000 },
	Secret = { 8000, 15000 },
	Impossible = { 15000, 30000 },
}

function Characters.GetAll(): { CharacterDef }
	local copy: { CharacterDef } = {}
	for _, def in LIST do
		table.insert(copy, def)
	end
	return copy
end

function Characters.GetCount(): number
	return #LIST
end

function Characters.GetById(id: string): CharacterDef?
	return BY_ID[id]
end

function Characters.GetDefault(): CharacterDef
	return BY_ID["wobble_waffleton"]
end

function Characters.GetStarterId(): string
	return "wobble_waffleton"
end

function Characters.GetByRarity(rarity: string): { CharacterDef }
	local out: { CharacterDef } = {}
	for _, def in LIST do
		if def.Rarity == rarity then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return a.Cost < b.Cost
	end)
	return out
end

function Characters.GetByTrait(trait: string): { CharacterDef }
	local out: { CharacterDef } = {}
	for _, def in LIST do
		for _, t in def.Traits do
			if t == trait then
				table.insert(out, def)
				break
			end
		end
	end
	return out
end

function Characters.GetRarityList(): { string }
	local copy: { string } = {}
	for _, rarity in RARITY_LIST do
		table.insert(copy, rarity)
	end
	return copy
end

function Characters.IsUnlockedByDefault(characterId: string): boolean
	local def = BY_ID[characterId]
	if def == nil then
		return false
	end
	return def.Cost == 0
end

function Characters.GetRarityRank(rarity: string): number
	return RARITY_ORDER[rarity] or 0
end

function Characters.GetRarityIncomeBand(rarity: string): { number }
	return RARITY_INCOME[rarity] or { 3, 8 }
end

function Characters.GetSortedByCost(): { CharacterDef }
	local copy = Characters.GetAll()
	table.sort(copy, function(a, b)
		if a.Cost == b.Cost then
			return a.Id < b.Id
		end
		return a.Cost < b.Cost
	end)
	return copy
end

function Characters.GetSortedByIncome(): { CharacterDef }
	local copy = Characters.GetAll()
	table.sort(copy, function(a, b)
		return a.IncomePerSec > b.IncomePerSec
	end)
	return copy
end

return Characters
