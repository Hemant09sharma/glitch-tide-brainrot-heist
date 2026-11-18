--!strict
-- Mutations.luau
-- The 12 mutations that can be applied to a Brainrot for Mutation
-- Crystals. A mutation multiplies the Brainrot's income and visibly
-- changes its model (see CharacterModels.ApplyMutation). Whether a
-- character accepts a mutation is decided by its
-- MutationCompatibility list in Characters.luau — check with CanMutate
-- before spending crystals. FusionRecipes pair two character Ids and
-- hint at the character their fusion produces.

export type MutationDef = {
	Id: string,
	Name: string,
	IncomeMultiplier: number,
	Cost: number, -- Mutation Crystals
	Color: Color3,
	Material: string, -- Enum.Material name, e.g. "Neon", "DiamondPlate", "Ice"
	ParticleColor: Color3,
	Description: string,
	RarityWeight: number, -- relative weight for random mutation rolls
	MinRebirths: number, -- rebirths required before this mutation can be applied (0 = available immediately)
}

export type FusionRecipe = {
	Characters: { string }, -- exactly two character Ids
	ResultId: string, -- character Id the fusion produces
	Hint: string,
}

local Mutations = {}

local LIST: { MutationDef } = {
	{
		Id = "Golden",
		Name = "Golden",
		IncomeMultiplier = 2.5,
		Cost = 50,
		Color = Color3.fromRGB(255, 210, 60),
		Material = "Foil",
		ParticleColor = Color3.fromRGB(255, 220, 90),
		Description = "Solid gold plating. Everything it touches turns to profit.",
		RarityWeight = 25,
		MinRebirths = 0,
	},
	{
		Id = "Diamond",
		Name = "Diamond",
		IncomeMultiplier = 4,
		Cost = 120,
		Color = Color3.fromRGB(190, 230, 255),
		Material = "DiamondPlate",
		ParticleColor = Color3.fromRGB(200, 235, 255),
		Description = "Hard as diamond and twice as shiny. A vault that walks.",
		RarityWeight = 15,
		MinRebirths = 0,
	},
	{
		Id = "Rainbow",
		Name = "Rainbow",
		IncomeMultiplier = 5,
		Cost = 200,
		Color = Color3.fromRGB(255, 120, 200),
		Material = "Neon",
		ParticleColor = Color3.fromRGB(255, 150, 220),
		Description = "Cycles through every colour of the Memeverse. Pure joy, pure income.",
		RarityWeight = 8,
		MinRebirths = 2,
	},
	{
		Id = "Electric",
		Name = "Electric",
		IncomeMultiplier = 2,
		Cost = 40,
		Color = Color3.fromRGB(255, 235, 60),
		Material = "Neon",
		ParticleColor = Color3.fromRGB(255, 240, 100),
		Description = "Crackling with stored storms. Sparks fly wherever it goes.",
		RarityWeight = 20,
		MinRebirths = 0,
	},
	{
		Id = "Frozen",
		Name = "Frozen",
		IncomeMultiplier = 1.8,
		Cost = 40,
		Color = Color3.fromRGB(170, 220, 255),
		Material = "Ice",
		ParticleColor = Color3.fromRGB(190, 230, 255),
		Description = "Frozen solid and cool under pressure. Thieves slip right off.",
		RarityWeight = 18,
		MinRebirths = 0,
	},
	{
		Id = "Toxic",
		Name = "Toxic",
		IncomeMultiplier = 2.2,
		Cost = 60,
		Color = Color3.fromRGB(120, 230, 60),
		Material = "Neon",
		ParticleColor = Color3.fromRGB(140, 255, 80),
		Description = "Oozing with glowing goo. Dangerous to touch, delightful to own.",
		RarityWeight = 15,
		MinRebirths = 0,
	},
	{
		Id = "Shadow",
		Name = "Shadow",
		IncomeMultiplier = 3,
		Cost = 100,
		Color = Color3.fromRGB(60, 50, 90),
		Material = "SmoothPlastic",
		ParticleColor = Color3.fromRGB(120, 90, 200),
		Description = "Half in this world, half in the dark. Hard to steal what you cannot see.",
		RarityWeight = 12,
		MinRebirths = 0,
	},
	{
		Id = "Glitched",
		Name = "Glitched",
		IncomeMultiplier = 3.5,
		Cost = 150,
		Color = Color3.fromRGB(255, 60, 200),
		Material = "Neon",
		ParticleColor = Color3.fromRGB(80, 240, 255),
		Description = "Reality glitches around it. Income flickers in from dimensions that do not exist.",
		RarityWeight = 10,
		MinRebirths = 0,
	},
	{
		Id = "Cosmic",
		Name = "Cosmic",
		IncomeMultiplier = 4.5,
		Cost = 180,
		Color = Color3.fromRGB(100, 80, 220),
		Material = "Neon",
		ParticleColor = Color3.fromRGB(160, 120, 255),
		Description = "Dusted with stardust from the far Memeverse. Its glow never fades.",
		RarityWeight = 8,
		MinRebirths = 0,
	},
	{
		Id = "Ancient",
		Name = "Ancient",
		IncomeMultiplier = 3,
		Cost = 120,
		Color = Color3.fromRGB(190, 160, 110),
		Material = "Granite",
		ParticleColor = Color3.fromRGB(220, 190, 130),
		Description = "Carved from the oldest stone of the Memeverse. Old, heavy, priceless.",
		RarityWeight = 10,
		MinRebirths = 0,
	},
	{
		Id = "Void",
		Name = "Void",
		IncomeMultiplier = 6,
		Cost = 300,
		Color = Color3.fromRGB(20, 10, 40),
		Material = "ForceField",
		ParticleColor = Color3.fromRGB(140, 60, 255),
		Description = "A hole in reality wearing a Brainrot's shape. It drinks light and pays in coins.",
		RarityWeight = 4,
		MinRebirths = 1,
	},
	{
		Id = "Celestial",
		Name = "Celestial",
		IncomeMultiplier = 8,
		Cost = 500,
		Color = Color3.fromRGB(255, 245, 200),
		Material = "Neon",
		ParticleColor = Color3.fromRGB(255, 250, 220),
		Description = "Blessed by the stars themselves. The rarest glow a Brainrot can carry.",
		RarityWeight = 2,
		MinRebirths = 1,
	},
}

local BY_ID: { [string]: MutationDef } = {}
for _, def in LIST do
	BY_ID[def.Id] = def
end

-- Mutation ids are stored lowercase in player data ("glitched") but
-- defined capitalised here ("Glitched"). v1.0.0 looked ids up exactly,
-- so GetById("glitched") returned nil: mutation income multipliers
-- were silently 1x (Economy.GetMultiplier), mutation visuals never
-- rendered (CharacterModels.ApplyMutation warns "unknown mutation"),
-- and CanMutate rejected every lowercase id. All lookups below
-- normalise case so either form resolves.
local function normaliseId(id: string?): string?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local lower = string.lower(id)
	for _, def in LIST do
		if string.lower(def.Id) == lower then
			return def.Id
		end
	end
	return nil
end

-- Fusion recipes: two character Ids fuse into a stronger character.
-- Order of the pair does not matter. ResultId is always a real
-- character Id from Characters.luau.
local FUSION_RECIPES: { FusionRecipe } = {
	{
		Characters = { "wobble_waffleton", "turbo_turnip" },
		ResultId = "bloop_bloomington",
		Hint = "A wobbling waffle strapped to racing boots melts into a bouncing jelly.",
	},
	{
		Characters = { "bloop_bloomington", "crumb_comet" },
		ResultId = "noodle_nebula",
		Hint = "Jelly and comet crumbs tangle together into a starry noodle storm.",
	},
	{
		Characters = { "noodle_nebula", "toast_ghost" },
		ResultId = "disco_dumpling",
		Hint = "A haunted noodle learns to dance and folds itself into a dumpling.",
	},
	{
		Characters = { "crumb_comet", "moon_mochi" },
		ResultId = "giga_gumball",
		Hint = "A comet crashes into the moon and rolls away as one giant candy.",
	},
	{
		Characters = { "disco_dumpling", "captain_picklebyte" },
		ResultId = "moon_mochi",
		Hint = "The captain dances with the dumpling under moonlight and a mochi is born.",
	},
	{
		Characters = { "moon_mochi", "giga_gumball" },
		ResultId = "miso_mothership",
		Hint = "Moon dessert and giant candy merge into a soup-bowl spaceship.",
	},
	{
		Characters = { "miso_mothership", "puddle_professor" },
		ResultId = "springy_spaghetti",
		Hint = "Soup and puddle science explodes into spring-legged pasta.",
	},
	{
		Characters = { "springy_spaghetti", "zap_zucchini" },
		ResultId = "cosmic_cupcake",
		Hint = "Lightning pasta bakes itself into a dessert with planetary rings.",
	},
	{
		Characters = { "cosmic_cupcake", "glitchy_goose" },
		ResultId = "caramel_crab",
		Hint = "A glitched goose honks a cupcake into a golden caramel crab.",
	},
	{
		Characters = { "caramel_crab", "wobble_king" },
		ResultId = "wobble_king",
		Hint = "The King absorbs the crab and wobbles on, more royal than ever. (Capstone recipe: the result is the King himself, at level 1 — fusing into the top of the ladder.)",
	},
}

Mutations.FusionRecipes = FUSION_RECIPES

function Mutations.GetAll(): { MutationDef }
	local copy: { MutationDef } = {}
	for _, def in LIST do
		table.insert(copy, def)
	end
	return copy
end

function Mutations.GetCount(): number
	return #LIST
end

function Mutations.GetById(id: string): MutationDef?
	local canonical = normaliseId(id)
	if canonical == nil then
		return nil
	end
	return BY_ID[canonical]
end

-- A character can receive a mutation only when the mutation Id appears
-- in that character's MutationCompatibility list.
function Mutations.CanMutate(characterDef: any, mutationId: string): boolean
	if characterDef == nil or type(mutationId) ~= "string" then
		return false
	end
	local canonical = normaliseId(mutationId)
	if canonical == nil then
		return false
	end
	local compatibility = characterDef.MutationCompatibility
	if type(compatibility) ~= "table" then
		return false
	end
	for _, allowedId in compatibility do
		if normaliseId(allowedId) == canonical then
			return true
		end
	end
	return false
end

-- Income multiplier for a mutation Id, or 1 when the Id is unknown.
function Mutations.GetMultiplier(mutationId: string?): number
	if mutationId == nil or mutationId == "" then
		return 1
	end
	local def = Mutations.GetById(mutationId)
	if def == nil then
		return 1
	end
	return def.IncomeMultiplier
end

-- Rebirths required before a mutation can be applied (0 = immediately).
function Mutations.GetMinRebirths(mutationId: string?): number
	local def = mutationId ~= nil and Mutations.GetById(mutationId) or nil
	if def == nil then
		return 0
	end
	return tonumber(def.MinRebirths) or 0
end

-- Weighted random mutation Id, using RarityWeight. Returns nil only
-- when the list is empty (it never is).
function Mutations.RollRandom(): string?
	local total = 0
	for _, def in LIST do
		total += def.RarityWeight
	end
	if total <= 0 then
		return nil
	end
	local roll = math.random() * total
	for _, def in LIST do
		roll -= def.RarityWeight
		if roll <= 0 then
			return def.Id
		end
	end
	return LIST[#LIST].Id
end

-- Find the fusion recipe for a pair of character Ids (either order).
function Mutations.GetFusionRecipe(characterIdA: string, characterIdB: string): FusionRecipe?
	for _, recipe in FUSION_RECIPES do
		local first = recipe.Characters[1]
		local second = recipe.Characters[2]
		if (first == characterIdA and second == characterIdB)
			or (first == characterIdB and second == characterIdA) then
			return recipe
		end
	end
	return nil
end

return Mutations
