--!strict
-- LabDefs.luau
-- Shared tunables for the Laboratory (v1.1, Workstream C). All costs,
-- rewards and recipes live HERE, not in Config.luau (Config is frozen
-- for this workstream) and not hardcoded in LaboratoryService.
--
-- EVOLUTION: a max-level (5) Brainrot + coins + Mutation Crystals
-- becomes an EVOLVED form of the same character: same CharacterId,
-- level 5, Evolved flag + a new trait, and its mutation upgraded to
-- the best compatible mutation (the income boost flows through the
-- existing Economy.IncomePerSecond path — no income-math edit needed).
-- SECRET RECIPES: evolution variants gated by SecretService discovery
-- flags (see SecretService secrets); a discovered secret recipe gives
-- the evolution a named form, a fixed bonus mutation and extra gems.
-- ALTERNATE FORMS: same-rarity character swaps (both ids are real
-- roster characters; the instance keeps its level and mutation).
-- TRAIT UPGRADES: up to 3 levels per trait on one instance.

local Characters = require(script.Parent.Characters)
local Mutations = require(script.Parent.Mutations)

local LabDefs = {}

export type EvolveCost = {
	Coins: number,
	MutationCrystals: number,
	XP: number, -- XP granted on a successful evolution
	Gems: number, -- gems granted on a successful evolution
}

-- Evolution cost / reward by rarity of the Brainrot being evolved.
local EVOLVE_BY_RARITY: { [string]: EvolveCost } = {
	Common = { Coins = 500, MutationCrystals = 10, XP = 100, Gems = 5 },
	Uncommon = { Coins = 1000, MutationCrystals = 15, XP = 150, Gems = 5 },
	Rare = { Coins = 2500, MutationCrystals = 25, XP = 200, Gems = 10 },
	Epic = { Coins = 5000, MutationCrystals = 40, XP = 300, Gems = 10 },
	Legendary = { Coins = 10000, MutationCrystals = 60, XP = 400, Gems = 15 },
	Mythic = { Coins = 20000, MutationCrystals = 80, XP = 500, Gems = 15 },
	Divine = { Coins = 40000, MutationCrystals = 120, XP = 750, Gems = 20 },
	Celestial = { Coins = 80000, MutationCrystals = 180, XP = 1000, Gems = 25 },
	Secret = { Coins = 150000, MutationCrystals = 250, XP = 1500, Gems = 50 },
	Impossible = { Coins = 250000, MutationCrystals = 400, XP = 2000, Gems = 100 },
}

function LabDefs.GetEvolveCost(rarity: string): EvolveCost
	local cost = EVOLVE_BY_RARITY[rarity]
	if cost then
		return cost
	end
	return { Coins = 1000, MutationCrystals = 15, XP = 150, Gems = 5 }
end

-- The 8 valid traits (Characters.luau). An evolved Brainrot gains the
-- first trait in this order that its base character does not already
-- have, so the new trait is always a real, valid trait value.
local TRAIT_ORDER: { string } = {
	"Electric", "Cosmic", "Food", "Royal",
	"Mechanical", "Water", "Glitch", "Ancient",
}

function LabDefs.GetEvolvedTrait(characterId: string): string
	local def = Characters.GetById(characterId)
	local owned: { [string]: boolean } = {}
	if def and type(def.Traits) == "table" then
		for _, trait in ipairs(def.Traits) do
			owned[tostring(trait)] = true
		end
	end
	for _, trait in ipairs(TRAIT_ORDER) do
		if not owned[trait] then
			return trait
		end
	end
	return "Glitch"
end

-- Best (highest IncomeMultiplier) mutation this character can take.
-- Returns the canonical mutation Id, or nil when the character has no
-- compatible mutation (never happens for the current roster, but the
-- caller must handle nil — evolution never fails closed on this).
function LabDefs.GetBestMutationFor(characterId: string): string?
	local def = Characters.GetById(characterId)
	if not def or type(def.MutationCompatibility) ~= "table" then
		return nil
	end
	local bestId: string? = nil
	local bestMult = 0
	for _, mutationId in ipairs(def.MutationCompatibility) do
		local mult = Mutations.GetMultiplier(tostring(mutationId))
		if mult > bestMult then
			bestMult = mult
			bestId = tostring(mutationId)
		end
	end
	return bestId
end

-- Secret lab recipes: hidden evolution forms. `RequiresSecret` is a
-- SecretService secret id (see SecretService.SECRET_IDS); the recipe
-- only applies once the player has discovered that secret AND calls
-- DiscoverRecipe for this recipe id. `FormName` is the evolved form's
-- display name; `BonusMutation` is forced onto the evolved instance
-- (it must be compatible with the character — all three below are);
-- `BonusGems` are paid on top of the normal evolution reward.
export type SecretRecipe = {
	Id: string,
	CharacterId: string,
	RequiresSecret: string,
	FormName: string,
	BonusMutation: string,
	BonusGems: number,
	Description: string,
}

local SECRET_RECIPES: { SecretRecipe } = {
	{
		Id = "recipe_void_heart",
		CharacterId = "void_vulture",
		RequiresSecret = "rift_whisper",
		FormName = "Voidheart Vulture",
		BonusMutation = "Void",
		BonusGems = 50,
		Description = "The rift whispered the vulture's true name. Evolve a Void Vulture after hearing the whisper.",
	},
	{
		Id = "recipe_starfall_quokka",
		CharacterId = "quantum_quokka",
		RequiresSecret = "skyfall_summit",
		FormName = "Starfall Quokka",
		BonusMutation = "Celestial",
		BonusGems = 25,
		Description = "A quokka that stood on the summit of the sky remembers the fall of stars.",
	},
	{
		Id = "recipe_drowned_king",
		CharacterId = "puddle_professor",
		RequiresSecret = "puzzle_room",
		FormName = "Drowned King Professor",
		BonusMutation = "Ancient",
		BonusGems = 25,
		Description = "The three runes of the Forbidden Rift crown the professor king of the drowned deep.",
	},
}

local _secretRecipeById: { [string]: SecretRecipe } = {}
for _, recipe in ipairs(SECRET_RECIPES) do
	_secretRecipeById[recipe.Id] = recipe
end

function LabDefs.GetSecretRecipes(): { SecretRecipe }
	local copy: { SecretRecipe } = {}
	for _, recipe in ipairs(SECRET_RECIPES) do
		table.insert(copy, recipe)
	end
	return copy
end

function LabDefs.GetSecretRecipe(recipeId: string): SecretRecipe?
	return _secretRecipeById[recipeId]
end

function LabDefs.GetSecretRecipeForCharacter(characterId: string): SecretRecipe?
	for _, recipe in ipairs(SECRET_RECIPES) do
		if recipe.CharacterId == characterId then
			return recipe
		end
	end
	return nil
end

-- Alternate forms: same-rarity swaps. Both ids in every pair are real
-- roster characters of the same rarity (verified against
-- Characters.luau, 27-character roster). The instance keeps its level
-- and mutation; the swap costs coins + crystals (see
-- ALTERNATE_FORM_COST). Not every character has an alternate form.
local ALTERNATE_FORMS: { [string]: string } = {
	wobble_waffleton = "phantom_pancake",
	phantom_pancake = "wobble_waffleton",
	bloop_bloomington = "prism_penguin",
	prism_penguin = "bloop_bloomington",
	noodle_nebula = "neon_narwhal",
	neon_narwhal = "noodle_nebula",
	toast_ghost = "disco_dumpling",
	disco_dumpling = "toast_ghost",
	captain_picklebyte = "reactor_raccoon",
	reactor_raccoon = "captain_picklebyte",
	moon_mochi = "giga_gumball",
	giga_gumball = "moon_mochi",
	miso_mothership = "gravity_goblin",
	gravity_goblin = "miso_mothership",
	springy_spaghetti = "thunder_tortoise",
	thunder_tortoise = "springy_spaghetti",
	cosmic_cupcake = "quantum_quokka",
	quantum_quokka = "cosmic_cupcake",
	glitchy_goose = "solar_sloth",
	solar_sloth = "glitchy_goose",
	caramel_crab = "void_vulture",
	void_vulture = "caramel_crab",
}

function LabDefs.GetAlternateForm(characterId: string): string?
	return ALTERNATE_FORMS[characterId]
end

LabDefs.AlternateFormCost = { Coins = 2000, MutationCrystals = 20 }

-- Trait upgrades: up to 3 levels per trait on one instance. Level 1-2
-- pay XP + gems; level 3 (mastered trait) also glitch-infuses the
-- instance (Glitched = true, x2 income through the existing
-- Economy.IncomePerSecond path). Costs scale per level.
export type TraitUpgradeCost = {
	Coins: number,
	MutationCrystals: number,
	XP: number,
	Gems: number,
}

LabDefs.TRAIT_MAX_LEVEL = 3

local TRAIT_UPGRADE_COSTS: { TraitUpgradeCost } = {
	{ Coins = 500, MutationCrystals = 10, XP = 100, Gems = 5 },
	{ Coins = 1500, MutationCrystals = 25, XP = 250, Gems = 10 },
	{ Coins = 4000, MutationCrystals = 50, XP = 500, Gems = 15 },
}

function LabDefs.GetTraitUpgradeCost(level: number): TraitUpgradeCost?
	if level < 1 or level > #TRAIT_UPGRADE_COSTS then
		return nil
	end
	return TRAIT_UPGRADE_COSTS[level]
end

-- Max Brainrot level an instance must reach before it can evolve
-- (Config.MaxBrainrotLevel = 5; read here so the lab follows Config).
function LabDefs.GetMaxLevel(): number
	local Config = require(script.Parent.Config)
	return tonumber(Config.MaxBrainrotLevel) or 5
end

return LabDefs
