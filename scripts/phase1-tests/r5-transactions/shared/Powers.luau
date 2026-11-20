--!strict
-- Powers.luau
-- All abilities (v1.1, Workstream B): 27 character primaries (one
-- signature ability per character, keyed by the character's AbilityId
-- in Characters.luau), 2 generic slot abilities (slam on F, heal on R
-- — see Config.Keybinds) usable by every character, and 17 playable
-- powers — unlockable powers any player can equip, each with a real
-- cooldown, duration and cost.
-- Total: 29 entries in Powers plus 17 entries in PlayablePowers.
-- Every power has a numeric cooldown of at least 3 seconds; there are
-- no zero-cooldown powers.
--
-- KEYBINDS (canonical, Config.Keybinds — v1.0.1 QA): Q = character
-- primary, F = Slam, R = Heal, E = Interact (never an ability), G =
-- Drop. Dash is a loadout power, not a slot ability: it has no fixed
-- key (Key = "") and is fired from the loadout bar (keys 1/2/3). In
-- v1.0.0 Dash sat on Q in this file AND the primary sat on Q, and Slam
-- sat on E while E was Interact — none of that could ever work.

local Characters = require("./Characters")

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

-- Playable powers add Duration (seconds the effect lasts) and Cost
-- (coins to unlock) on top of the standard power fields.
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

local Powers = {}

local LIST: { PowerDef } = {
	-- Character primaries -------------------------------------------------
	{
		Id = "waffle_wobble",
		Name = "Waffle Wobble",
		Key = "Q",
		Cooldown = 6,
		Damage = 28,
		Range = 5,
		Radius = 4,
		Effect = "GroundSlam",
		Description = "Wobble Waffleton wobbles violently and slams the ground, damaging and knocking back every enemy nearby.",
		Color = Color3.fromRGB(214, 164, 65),
	},
	{
		Id = "turbo_boost",
		Name = "Turbo Boost",
		Key = "Q",
		Cooldown = 5,
		Damage = 18,
		Range = 10,
		Radius = 2,
		Effect = "SpeedBoost",
		Description = "Turbo Turnip revs its racing boots for a burst of speed and a flurry of quick kicks.",
		Color = Color3.fromRGB(220, 40, 40),
	},
	{
		Id = "jelly_splash",
		Name = "Jelly Splash",
		Key = "Q",
		Cooldown = 6,
		Damage = 22,
		Range = 8,
		Radius = 4,
		Effect = "Splash",
		Description = "Bloop Bloomington splashes a wave of jelly that soaks enemies and slows them down.",
		Color = Color3.fromRGB(255, 150, 200),
	},
	{
		Id = "comet_crash",
		Name = "Comet Crash",
		Key = "Q",
		Cooldown = 8,
		Damage = 36,
		Range = 12,
		Radius = 6,
		Effect = "Explosion",
		Description = "Crumb Comet dives from the sky in a blazing pastry crash, blasting everything in a wide radius.",
		Color = Color3.fromRGB(255, 170, 60),
	},
	{
		Id = "noodle_whip",
		Name = "Noodle Whip",
		Key = "Q",
		Cooldown = 5,
		Damage = 26,
		Range = 9,
		Radius = 3,
		Effect = "Whip",
		Description = "Noodle Nebula cracks its starlit noodle strands like whips, lashing every enemy in front of it.",
		Color = Color3.fromRGB(150, 100, 255),
	},
	{
		Id = "toast_haunt",
		Name = "Toast Haunt",
		Key = "Q",
		Cooldown = 7,
		Damage = 24,
		Range = 9,
		Radius = 4,
		Effect = "Haunt",
		Description = "Toast Ghost phases through the floor and haunts a target, chilling and damaging it from beyond the butter.",
		Color = Color3.fromRGB(200, 220, 255),
	},
	{
		Id = "disco_fever",
		Name = "Disco Fever",
		Key = "Q",
		Cooldown = 8,
		Damage = 26,
		Range = 6,
		Radius = 6,
		Effect = "Dazzle",
		Description = "Disco Dumpling drops the beat and flashes its disco lights, dazzling and damaging every enemy nearby.",
		Color = Color3.fromRGB(255, 120, 180),
	},
	{
		Id = "pickle_blast",
		Name = "Pickle Blast",
		Key = "Q",
		Cooldown = 7,
		Damage = 30,
		Range = 10,
		Radius = 4,
		Effect = "Blast",
		Description = "Captain Picklebyte fires its laser cutlass in a briny blast that sears enemies at range.",
		Color = Color3.fromRGB(80, 180, 70),
	},
	{
		Id = "mochi_bounce",
		Name = "Mochi Bounce",
		Key = "Q",
		Cooldown = 6,
		Damage = 24,
		Range = 8,
		Radius = 4,
		Effect = "Bounce",
		Description = "Moon Mochi bounces high and lands with a soft, moonlit thud that knocks enemies flying.",
		Color = Color3.fromRGB(180, 160, 255),
	},
	{
		Id = "gumball_roll",
		Name = "Gumball Roll",
		Key = "Q",
		Cooldown = 8,
		Damage = 34,
		Range = 8,
		Radius = 5,
		Effect = "Roll",
		Description = "Giga Gumball tucks in and rolls through the arena, flattening everything in its path.",
		Color = Color3.fromRGB(230, 60, 90),
	},
	{
		Id = "miso_beam",
		Name = "Miso Beam",
		Key = "Q",
		Cooldown = 9,
		Damage = 38,
		Range = 12,
		Radius = 4,
		Effect = "Beam",
		Description = "Miso Mothership fires a steaming beam of hot broth from orbit, scalding a line of enemies.",
		Color = Color3.fromRGB(255, 160, 60),
	},
	{
		Id = "puddle_splash",
		Name = "Puddle Splash",
		Key = "Q",
		Cooldown = 6,
		Damage = 22,
		Range = 8,
		Radius = 5,
		Effect = "Splash",
		Description = "Puddle Professor splashes a wave of lecture-grade water that soaks and slows nearby enemies.",
		Color = Color3.fromRGB(60, 140, 255),
	},
	{
		Id = "spaghetti_spring",
		Name = "Spaghetti Spring",
		Key = "Q",
		Cooldown = 6,
		Damage = 28,
		Range = 9,
		Radius = 4,
		Effect = "SpringSlam",
		Description = "Springy Spaghetti boings sky-high on its spring legs and crashes down in a saucy slam.",
		Color = Color3.fromRGB(250, 210, 80),
	},
	{
		Id = "zap_bolt",
		Name = "Zap Bolt",
		Key = "Q",
		Cooldown = 5,
		Damage = 32,
		Range = 12,
		Radius = 3,
		Effect = "Shock",
		Description = "Zap Zucchini hurls a crackling bolt from its tesla coil, shocking and briefly stunning its target.",
		Color = Color3.fromRGB(255, 230, 60),
	},
	{
		Id = "cosmic_ring",
		Name = "Cosmic Ring",
		Key = "Q",
		Cooldown = 9,
		Damage = 40,
		Range = 10,
		Radius = 6,
		Effect = "RingBlast",
		Description = "Cosmic Cupcake hurls a spinning planetary ring that slices through enemies and returns to its frosting.",
		Color = Color3.fromRGB(255, 170, 210),
	},
	{
		Id = "glitch_flicker",
		Name = "Glitch Flicker",
		Key = "Q",
		Cooldown = 7,
		Damage = 30,
		Range = 9,
		Radius = 5,
		Effect = "GlitchTeleport",
		Description = "Glitchy Goose flickers out of reality and reappears behind its target in a burst of corrupted pixels.",
		Color = Color3.fromRGB(255, 60, 200),
	},
	{
		Id = "caramel_claw",
		Name = "Caramel Claw",
		Key = "Q",
		Cooldown = 8,
		Damage = 42,
		Range = 6,
		Radius = 3,
		Effect = "ClawSlash",
		Description = "Caramel Crab snaps its oversized golden claws shut on the nearest enemy for crushing damage.",
		Color = Color3.fromRGB(230, 190, 90),
	},
	{
		Id = "phantom_flip",
		Name = "Phantom Flip",
		Key = "Q",
		Cooldown = 6,
		Damage = 20,
		Range = 6,
		Radius = 4,
		Effect = "Bounce",
		Description = "Phantom Pancake flips clean through its target and lands behind it, knocking enemies flying.",
		Color = Color3.fromRGB(200, 120, 220),
	},
	{
		Id = "prism_shatter",
		Name = "Prism Shatter",
		Key = "Q",
		Cooldown = 7,
		Damage = 30,
		Range = 10,
		Radius = 5,
		Effect = "RingBlast",
		Description = "Prism Penguin shatters a rainbow prism overhead; the shards slice every enemy in a wide ring.",
		Color = Color3.fromRGB(255, 120, 220),
	},
	{
		Id = "neon_sonar",
		Name = "Neon Sonar",
		Key = "Q",
		Cooldown = 6,
		Damage = 24,
		Range = 11,
		Radius = 5,
		Effect = "Splash",
		Description = "Neon Narwhal sings a sonar pulse that soaks and slows every enemy it washes over.",
		Color = Color3.fromRGB(60, 220, 255),
	},
	{
		Id = "reactor_overload",
		Name = "Reactor Overload",
		Key = "Q",
		Cooldown = 8,
		Damage = 36,
		Range = 9,
		Radius = 6,
		Effect = "Explosion",
		Description = "Reactor Raccoon overloads its core and detonates a green blast that flattens everything nearby.",
		Color = Color3.fromRGB(120, 255, 90),
	},
	{
		Id = "gravity_well",
		Name = "Gravity Well",
		Key = "Q",
		Cooldown = 9,
		Damage = 32,
		Range = 8,
		Radius = 6,
		Effect = "Shock",
		Description = "Gravity Goblin opens a crushing gravity well: enemies are dragged in and stunned by their own weight.",
		Color = Color3.fromRGB(140, 90, 220),
	},
	{
		Id = "thunder_shell",
		Name = "Thunder Shell",
		Key = "Q",
		Cooldown = 8,
		Damage = 40,
		Range = 7,
		Radius = 5,
		Effect = "Shock",
		Description = "Thunder Tortoise slams its storm shell down and calls lightning that stuns every enemy it touches.",
		Color = Color3.fromRGB(255, 230, 60),
	},
	{
		Id = "quantum_leap",
		Name = "Quantum Leap",
		Key = "Q",
		Cooldown = 7,
		Damage = 34,
		Range = 10,
		Radius = 5,
		Effect = "GlitchTeleport",
		Description = "Quantum Quokka leaps between universes and reappears behind its target in a burst of happy static.",
		Color = Color3.fromRGB(120, 220, 255),
	},
	{
		Id = "solar_flare",
		Name = "Solar Flare",
		Key = "Q",
		Cooldown = 9,
		Damage = 44,
		Range = 11,
		Radius = 6,
		Effect = "Dazzle",
		Description = "Solar Sloth unleashes a blinding flare from its halo, dazzling and searing every enemy in front of it.",
		Color = Color3.fromRGB(255, 120, 40),
	},
	{
		Id = "void_screech",
		Name = "Void Screech",
		Key = "Q",
		Cooldown = 8,
		Damage = 48,
		Range = 9,
		Radius = 6,
		Effect = "Haunt",
		Description = "Void Vulture screeches from the void, chilling and slowing every enemy that hears it.",
		Color = Color3.fromRGB(170, 60, 255),
	},
	{
		Id = "royal_wobble",
		Name = "Royal Wobble",
		Key = "Q",
		Cooldown = 10,
		Damage = 55,
		Range = 7,
		Radius = 7,
		Effect = "RoyalSlam",
		Description = "The Wobble King decrees a royal wobble: the whole arena shakes and every nearby enemy is crushed by majesty.",
		Color = Color3.fromRGB(230, 190, 60),
	},

	-- Generic slot abilities (every character). Dash is NOT here: it
	-- is a loadout power in PLAYABLE_LIST (Key "" = no fixed key).
	{
		Id = "slam",
		Name = "Slam",
		Key = "F",
		Cooldown = 4,
		Damage = 15,
		Range = 4,
		Radius = 3,
		Effect = "GroundSlam",
		Description = "Slam the ground in front of you, damaging and knocking back close enemies.",
		Color = Color3.fromRGB(255, 150, 60),
	},
	{
		Id = "heal",
		Name = "Heal",
		Key = "R",
		Cooldown = 12,
		Damage = -25,
		Range = 0,
		Radius = 0,
		Effect = "Heal",
		Description = "Recover 25 health over a short moment. A negative Damage value means healing.",
		Color = Color3.fromRGB(90, 220, 120),
	},
}

local BY_ID: { [string]: PowerDef } = {}
for _, def in LIST do
	BY_ID[def.Id] = def
end

-- Playable powers (v1.1: 17, was 12): unlockable with coins, usable
-- by any player regardless of character. All cooldowns are at least 4
-- seconds (the 5 new powers are 10-25s) and
-- all durations are positive, so no power can be spammed or held
-- permanently.
local PLAYABLE_LIST: { PlayablePowerDef } = {
	{
		Id = "dash",
		Name = "Dash",
		Cooldown = 4,
		Duration = 0.6,
		Cost = 0,
		Damage = 0,
		Range = 8,
		Radius = 0,
		Effect = "Dash",
		Description = "A quick burst of movement in the direction you are facing. No damage, pure mobility.",
		Color = Color3.fromRGB(120, 200, 255),
	},
	{
		Id = "energy_shield",
		Name = "Energy Shield",
		Cooldown = 14,
		Duration = 5,
		Cost = 500,
		Damage = 0,
		Range = 0,
		Radius = 0,
		Effect = "Shield",
		Description = "Wrap yourself in an energy shield that absorbs incoming damage for 5 seconds.",
		Color = Color3.fromRGB(90, 180, 255),
	},
	{
		Id = "magnet_pull",
		Name = "Magnet Pull",
		Cooldown = 10,
		Duration = 4,
		Cost = 750,
		Damage = 0,
		Range = 12,
		Radius = 0,
		Effect = "Magnet",
		Description = "Pull nearby coins, pickups and loose Brainrots toward you for 4 seconds.",
		Color = Color3.fromRGB(255, 100, 100),
	},
	{
		Id = "teleport",
		Name = "Teleport",
		Cooldown = 12,
		Duration = 0.5,
		Cost = 1000,
		Damage = 0,
		Range = 20,
		Radius = 0,
		Effect = "Teleport",
		Description = "Blink a short distance forward through the glitch, vanishing and reappearing instantly.",
		Color = Color3.fromRGB(180, 120, 255),
	},
	{
		Id = "gravity_shift",
		Name = "Gravity Shift",
		Cooldown = 16,
		Duration = 6,
		Cost = 1500,
		Damage = 0,
		Range = 0,
		Radius = 8,
		Effect = "LowGravity",
		Description = "Flip local gravity for 6 seconds: you jump higher and fall slower, and nearby enemies float.",
		Color = Color3.fromRGB(120, 220, 255),
	},
	{
		Id = "freeze_blast",
		Name = "Freeze Blast",
		Cooldown = 11,
		Duration = 3,
		Cost = 1200,
		Damage = 15,
		Range = 8,
		Radius = 5,
		Effect = "Freeze",
		Description = "Blast freezing air in a cone, damaging enemies and freezing them in place for 3 seconds.",
		Color = Color3.fromRGB(170, 220, 255),
	},
	{
		Id = "shadow_walk",
		Name = "Shadow Walk",
		Cooldown = 15,
		Duration = 4,
		Cost = 1500,
		Damage = 0,
		Range = 0,
		Radius = 0,
		Effect = "Stealth",
		Description = "Fade into shadow for 4 seconds: enemies cannot target you and your footsteps go silent.",
		Color = Color3.fromRGB(90, 70, 140),
	},
	{
		Id = "clone_decoy",
		Name = "Clone Decoy",
		Cooldown = 18,
		Duration = 8,
		Cost = 2000,
		Damage = 0,
		Range = 0,
		Radius = 0,
		Effect = "Decoy",
		Description = "Summon a glitchy decoy of yourself for 8 seconds that draws enemy attacks away from you.",
		Color = Color3.fromRGB(80, 240, 200),
	},
	{
		Id = "tide_surfer",
		Name = "Tide Surfer",
		Cooldown = 60,
		Duration = 30,
		Cost = 1000,
		Damage = 0,
		Range = 0,
		Radius = 0,
		Effect = "SpeedBoost",
		Description = "Ride the Glitch Tide for 30 seconds: a big speed boost that ignores carry slowdown, and immunity to tide damage for the duration. Cooldown (60s) is longer than the duration, so immunity can never be permanent.",
		Color = Color3.fromRGB(60, 200, 255),
	},
	{
		Id = "time_distortion",
		Name = "Time Distortion",
		Cooldown = 25,
		Duration = 4,
		Cost = 3000,
		Damage = 0,
		Range = 0,
		Radius = 10,
		Effect = "SlowTime",
		Description = "Distort time for 4 seconds: enemies within 10 studs move at half speed while you move normally.",
		Color = Color3.fromRGB(255, 220, 90),
	},
	{
		Id = "rift_hook",
		Name = "Rift Hook",
		Cooldown = 13,
		Duration = 2,
		Cost = 2500,
		Damage = 10,
		Range = 18,
		Radius = 0,
		Effect = "Hook",
		Description = "Fire a rift hook up to 18 studs: it yanks a distant Brainrot — or an enemy — straight toward you.",
		Color = Color3.fromRGB(255, 120, 60),
	},
	{
		Id = "chaos_burst",
		Name = "Chaos Burst",
		Cooldown = 30,
		Duration = 3,
		Cost = 4000,
		Damage = 50,
		Range = 0,
		Radius = 8,
		Effect = "ChaosExplosion",
		Description = "Unleash raw chaos for 3 seconds: a massive burst that damages every enemy within 8 studs.",
		Color = Color3.fromRGB(255, 60, 120),
	},
	{
		Id = "time_rewind",
		Name = "Time Rewind",
		Cooldown = 20,
		Duration = 3,
		Cost = 5000,
		Damage = 0,
		Range = 0,
		Radius = 0,
		Effect = "TimeRewind",
		Description = "Rewind yourself 3 seconds: restore the health and position you had 3 seconds ago. Cannot rewind death.",
		Color = Color3.fromRGB(90, 220, 255),
	},
	{
		Id = "meteor_shower",
		Name = "Meteor Shower",
		Cooldown = 18,
		Duration = 3,
		Cost = 4500,
		Damage = 45,
		Range = 12,
		Radius = 10,
		Effect = "MeteorShower",
		Description = "Call down 5 pastry meteors over 3 seconds around you, each blasting enemies near its impact.",
		Color = Color3.fromRGB(255, 140, 40),
	},
	{
		Id = "void_dash",
		Name = "Void Dash",
		Cooldown = 10,
		Duration = 0.5,
		Cost = 3500,
		Damage = 15,
		Range = 14,
		Radius = 3,
		Effect = "VoidDash",
		Description = "Dash through the void: blink forward up to 14 studs, briefly untouchable, slicing enemies you pass through.",
		Color = Color3.fromRGB(170, 60, 255),
	},
	{
		Id = "gravity_crush",
		Name = "Gravity Crush",
		Cooldown = 22,
		Duration = 2,
		Cost = 5500,
		Damage = 40,
		Range = 0,
		Radius = 7,
		Effect = "GravityCrush",
		Description = "Crush gravity in a 7-stud radius for 2 seconds: enemies take heavy damage, are dragged toward you and cannot move.",
		Color = Color3.fromRGB(140, 90, 220),
	},
	{
		Id = "dimensional_prison",
		Name = "Dimensional Prison",
		Cooldown = 25,
		Duration = 5,
		Cost = 6000,
		Damage = 10,
		Range = 12,
		Radius = 6,
		Effect = "DimensionalPrison",
		Description = "Trap the nearest enemy within 12 studs in a dimensional prison for 5 seconds: it cannot move or jump.",
		Color = Color3.fromRGB(80, 200, 255),
	},
}

local PLAYABLE_BY_ID: { [string]: PlayablePowerDef } = {}
for _, def in PLAYABLE_LIST do
	PLAYABLE_BY_ID[def.Id] = def
end

Powers.PlayablePowers = PLAYABLE_LIST

function Powers.GetAll(): { PowerDef }
	local copy: { PowerDef } = {}
	for _, def in LIST do
		table.insert(copy, def)
	end
	return copy
end

function Powers.GetById(id: string): PowerDef?
	-- Playable powers (e.g. dash) live in PLAYABLE_LIST, not LIST;
	-- fall back there so GetById resolves every power id in the game.
	return BY_ID[id] or (PLAYABLE_BY_ID[id] :: any)
end

function Powers.GetForCharacter(characterId: string): PowerDef?
	local character = Characters.GetById(characterId)
	if character == nil then
		return nil
	end
	return BY_ID[character.AbilityId]
end

function Powers.GetGenericAbilities(): { PowerDef }
	return {
		BY_ID["slam"],
		BY_ID["heal"],
	}
end

function Powers.GetByKey(key: string): { PowerDef }
	local out: { PowerDef } = {}
	for _, def in LIST do
		if def.Key == key then
			table.insert(out, def)
		end
	end
	return out
end

function Powers.GetPlayablePowers(): { PlayablePowerDef }
	local copy: { PlayablePowerDef } = {}
	for _, def in PLAYABLE_LIST do
		table.insert(copy, def)
	end
	return copy
end

function Powers.GetPlayablePower(id: string): PlayablePowerDef?
	return PLAYABLE_BY_ID[id]
end

-- ---------------------------------------------------------------------------
-- Power mastery (v1.1, Workstream B). Every successful UsePower awards
-- XP for that power (AbilityService awards 10 XP per use). Levels are
-- 0-5; each level adds +5% damage and -2% cooldown (cooldown never
-- drops below 3s — enforced in AbilityService, not here).
-- ---------------------------------------------------------------------------
Powers.MASTERY_MAX_LEVEL = 5
Powers.MASTERY_XP_PER_LEVEL = { 100, 250, 500, 1000, 2000 }

function Powers.GetMasteryLevel(xp: number): number
	local total = math.max(0, math.floor(tonumber(xp) or 0))
	local level = 0
	for i, needed in ipairs(Powers.MASTERY_XP_PER_LEVEL) do
		if total >= needed then
			level = i
		else
			break
		end
	end
	return math.min(level, Powers.MASTERY_MAX_LEVEL)
end

function Powers.GetMasteryDamageMultiplier(level: number): number
	return 1 + 0.05 * math.clamp(math.floor(tonumber(level) or 0), 0, Powers.MASTERY_MAX_LEVEL)
end

function Powers.GetMasteryCooldownMultiplier(level: number): number
	return 1 - 0.02 * math.clamp(math.floor(tonumber(level) or 0), 0, Powers.MASTERY_MAX_LEVEL)
end

return Powers
