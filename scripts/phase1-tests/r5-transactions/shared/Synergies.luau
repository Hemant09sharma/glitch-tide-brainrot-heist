--!strict
-- Synergies.luau
-- Trait synergy rules for Brainrots placed in a base. When the traits
-- of the placed Brainrots satisfy a synergy's requirements, every
-- Brainrot in the base earns that synergy's IncomeBonus (a fraction,
-- e.g. 0.15 = +15% income). Bonuses from all active synergies stack
-- additively. Pass the flat list of traits of all placed Brainrots
-- (each Brainrot contributes its 2-3 traits) to GetSynergyBonus.

local Characters = require("./Characters")

export type SynergyDef = {
	Name: string,
	Traits: { string }, -- every listed trait must be present
	MinCount: number, -- each listed trait must appear at least this many times
	IncomeBonus: number, -- fraction, e.g. 0.15 = +15%
	Description: string,
}

local Synergies = {}

local LIST: { SynergyDef } = {
	{
		Name = "Volt Squad",
		Traits = { "Electric" },
		MinCount = 2,
		IncomeBonus = 0.15,
		Description = "Two or more Electric Brainrots chain their sparks together, supercharging the whole base.",
	},
	{
		Name = "Snack Attack",
		Traits = { "Food" },
		MinCount = 3,
		IncomeBonus = 0.20,
		Description = "Three or more Food Brainrots turn the base into a feast that draws crowds — and coins.",
	},
	{
		Name = "Cosmic Constellation",
		Traits = { "Cosmic" },
		MinCount = 2,
		IncomeBonus = 0.25,
		Description = "Two or more Cosmic Brainrots align like stars and pull income in from orbit.",
	},
	{
		Name = "Glitch Pair",
		Traits = { "Glitch" },
		MinCount = 2,
		IncomeBonus = 0.30,
		Description = "Two or more Glitch Brainrots corrupt the base's ledger in your favour — and boost mutation luck.",
	},
	{
		Name = "Machine Works",
		Traits = { "Mechanical" },
		MinCount = 2,
		IncomeBonus = 0.15,
		Description = "Two or more Mechanical Brainrots keep the base running like clockwork and harden its defences.",
	},
	{
		Name = "Royal Court",
		Traits = { "Royal" },
		MinCount = 2,
		IncomeBonus = 0.35,
		Description = "Two or more Royal Brainrots hold court in your base, and the Memeverse pays tribute.",
	},
	{
		Name = "Deep Blue",
		Traits = { "Water" },
		MinCount = 2,
		IncomeBonus = 0.15,
		Description = "Two or more Water Brainrots flood the base with a steady, rising tide of income.",
	},
	{
		Name = "Ancient Guard",
		Traits = { "Ancient" },
		MinCount = 2,
		IncomeBonus = 0.20,
		Description = "Two or more Ancient Brainrots wake old magic that guards the base and grows its wealth.",
	},
	{
		Name = "Feast of the Cosmos",
		Traits = { "Food", "Cosmic" },
		MinCount = 1,
		IncomeBonus = 0.25,
		Description = "At least one Food and one Cosmic Brainrot together serve a feast under the stars.",
	},
	{
		Name = "Chrome and Crumbs",
		Traits = { "Mechanical", "Food" },
		MinCount = 1,
		IncomeBonus = 0.15,
		Description = "At least one Mechanical and one Food Brainrot together automate the kitchen and the profits.",
	},
	-- v1.1 (Workstream B): three new synergies the expanded roster can
	-- actually trigger (Storm Front needs the new Electric heavies,
	-- Void Court needs Void Vulture / Gravity Goblin, Rainbow Reef
	-- needs Neon Narwhal / Prism Penguin).
	{
		Name = "Storm Front",
		Traits = { "Electric" },
		MinCount = 3,
		IncomeBonus = 0.20,
		Description = "Three or more Electric Brainrots call a permanent storm over the base — and the storm pays rent.",
	},
	{
		Name = "Void Court",
		Traits = { "Glitch", "Ancient" },
		MinCount = 1,
		IncomeBonus = 0.25,
		Description = "At least one Glitch and one Ancient Brainrot together open a court in the void that taxes reality itself.",
	},
	{
		Name = "Rainbow Reef",
		Traits = { "Water", "Cosmic" },
		MinCount = 1,
		IncomeBonus = 0.20,
		Description = "At least one Water and one Cosmic Brainrot together flood the base with prismatic, profitable light.",
	},
}

function Synergies.GetAll(): { SynergyDef }
	local copy: { SynergyDef } = {}
	for _, def in LIST do
		table.insert(copy, def)
	end
	return copy
end

function Synergies.GetByName(name: string): SynergyDef?
	for _, def in LIST do
		if def.Name == name then
			return def
		end
	end
	return nil
end

local function countTraits(placedTraits: { string }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, trait in placedTraits do
		counts[trait] = (counts[trait] or 0) + 1
	end
	return counts
end

local function isActive(def: SynergyDef, counts: { [string]: number }): boolean
	for _, trait in def.Traits do
		if (counts[trait] or 0) < def.MinCount then
			return false
		end
	end
	return true
end

-- All synergies currently active for a flat list of placed traits.
function Synergies.GetActiveSynergies(placedTraits: { string }): { SynergyDef }
	local counts = countTraits(placedTraits)
	local out: { SynergyDef } = {}
	for _, def in LIST do
		if isActive(def, counts) then
			table.insert(out, def)
		end
	end
	return out
end

-- Total income bonus fraction (e.g. 0.35 = +35%) for a flat list of
-- placed traits. Returns 0 when no synergy is active.
function Synergies.GetSynergyBonus(placedTraits: { string }): number
	local total = 0
	for _, def in Synergies.GetActiveSynergies(placedTraits) do
		total += def.IncomeBonus
	end
	return total
end

-- Convenience: same as GetSynergyBonus, but takes character Ids and
-- gathers their traits from Characters.luau. Unknown Ids are skipped.
function Synergies.GetSynergyBonusForCharacters(characterIds: { string }): number
	local traits: { string } = {}
	for _, id in characterIds do
		local def = Characters.GetById(id)
		if def ~= nil then
			for _, trait in def.Traits do
				table.insert(traits, trait)
			end
		end
	end
	return Synergies.GetSynergyBonus(traits)
end

-- Convenience: active synergies for a list of character Ids.
function Synergies.GetActiveSynergiesForCharacters(characterIds: { string }): { SynergyDef }
	local traits: { string } = {}
	for _, id in characterIds do
		local def = Characters.GetById(id)
		if def ~= nil then
			for _, trait in def.Traits do
				table.insert(traits, trait)
			end
		end
	end
	return Synergies.GetActiveSynergies(traits)
end

return Synergies
