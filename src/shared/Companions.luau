--!strict
-- Companions.luau
-- Shared companion-passive data for Glitch Tide v1.1 (Workstream B).
--
-- A "companion" is any Brainrot the player OWNS (data.Unlocked /
-- OwnedInstances) whose CharacterDef carries a CompanionAbility
-- {Kind, Value}. Owning it is enough — it does not need to be placed
-- in the base, so collecting the roster is itself the progression.
-- CompanionService.luau (server) reads this module to turn a player's
-- owned character Ids into live bonuses.
--
-- BALANCE (the hard rule): no single companion grants more than 0.20
-- (20%) for any one bonus, and the TOTAL for any one kind is capped
-- below (0.15-0.25). Stacking many companions can reach the cap but
-- never exceed it, so companions are a meaningful boost, never a
-- replacement for placing, levelling and mutating Brainrots.
-- See docs/QA_V11_B.md for the full balance table.

local Characters = require(script.Parent.Characters)

export type CompanionKind = string -- "IncomeBonus" | "TideProtection" | "RareDetection" | "CarrySpeed" | "RaidDetection" | "MutationBonus"

export type CompanionBonuses = {
	IncomeBonus: number,
	TideProtection: number,
	RareDetection: number,
	CarrySpeed: number,
	RaidDetection: number,
	MutationBonus: number,
}

export type CompanionKindInfo = {
	Kind: CompanionKind,
	Description: string,
	-- Total cap across ALL owned companions for this kind (fraction).
	TotalCap: number,
	-- What the number means, for UI text.
	Unit: string,
}

local Companions = {}

local KIND_LIST: { CompanionKindInfo } = {
	{
		Kind = "IncomeBonus",
		Description = "Adds +% to all base income from placed Brainrots.",
		TotalCap = 0.25,
		Unit = "income",
	},
	{
		Kind = "TideProtection",
		Description = "Chance per tide hit to take no tide damage at all.",
		TotalCap = 0.20,
		Unit = "tide protection",
	},
	{
		Kind = "RareDetection",
		Description = "Boosts the weight of Epic+ rarities on the player's conveyor rolls.",
		TotalCap = 0.20,
		Unit = "rare detection",
	},
	{
		Kind = "CarrySpeed",
		Description = "Adds to the carry speed multiplier (base 0.6x while carrying).",
		TotalCap = 0.15,
		Unit = "carry speed",
	},
	{
		Kind = "RaidDetection",
		Description = "Extra seconds of warning before a raid / steal reaches the base.",
		TotalCap = 0.25,
		Unit = "raid warning",
	},
	{
		Kind = "MutationBonus",
		Description = "Adds +% to mutation income multipliers applied to owned Brainrots.",
		TotalCap = 0.15,
		Unit = "mutation income",
	},
}

local KIND_BY_NAME: { [string]: CompanionKindInfo } = {}
for _, info in KIND_LIST do
	KIND_BY_NAME[info.Kind] = info
end

-- The six valid companion kinds, in a fixed order.
local KIND_ORDER: { string } = {
	"IncomeBonus",
	"TideProtection",
	"RareDetection",
	"CarrySpeed",
	"RaidDetection",
	"MutationBonus",
}

function Companions.GetAllKinds(): { CompanionKindInfo }
	local copy: { CompanionKindInfo } = {}
	for _, info in KIND_LIST do
		table.insert(copy, info)
	end
	return copy
end

function Companions.GetKindInfo(kind: string): CompanionKindInfo?
	return KIND_BY_NAME[kind]
end

function Companions.IsValidKind(kind: string): boolean
	return KIND_BY_NAME[kind] ~= nil
end

-- Total cap for a kind (0 when the kind is unknown).
function Companions.GetTotalCap(kind: string): number
	local info = KIND_BY_NAME[kind]
	if info == nil then
		return 0
	end
	return info.TotalCap
end

-- Zero bonuses (a fresh player owns no companions yet).
function Companions.ZeroBonuses(): CompanionBonuses
	return {
		IncomeBonus = 0,
		TideProtection = 0,
		RareDetection = 0,
		CarrySpeed = 0,
		RaidDetection = 0,
		MutationBonus = 0,
	}
end

-- Pure function: total companion bonuses for a list of OWNED character
-- Ids. Each owned Brainrot contributes its CompanionAbility (if any);
-- per-kind totals are clamped to the kind's TotalCap. Unknown Ids and
-- characters without a CompanionAbility contribute nothing. Duplicate
-- Ids count once (a player owns a character once, however many
-- instances they hold).
function Companions.ComputeBonuses(ownedCharacterIds: { string }): CompanionBonuses
	local bonuses = Companions.ZeroBonuses()
	local seen: { [string]: boolean } = {}
	for _, id in ownedCharacterIds do
		if type(id) == "string" and not seen[id] then
			seen[id] = true
			local ability = Characters.GetCompanionAbility(id)
			if ability ~= nil and type(ability.Kind) == "string" and type(ability.Value) == "number" then
				local kind = ability.Kind
				local value = math.clamp(ability.Value, 0, 0.20)
				if kind == "IncomeBonus" then
					bonuses.IncomeBonus += value
				elseif kind == "TideProtection" then
					bonuses.TideProtection += value
				elseif kind == "RareDetection" then
					bonuses.RareDetection += value
				elseif kind == "CarrySpeed" then
					bonuses.CarrySpeed += value
				elseif kind == "RaidDetection" then
					bonuses.RaidDetection += value
				elseif kind == "MutationBonus" then
					bonuses.MutationBonus += value
				end
			end
		end
	end
	for _, kind in KIND_ORDER do
		local cap = Companions.GetTotalCap(kind);
		(bonuses :: any)[kind] = math.min((bonuses :: any)[kind], cap)
	end
	return bonuses
end

-- Convenience: bonuses for one character Id (its own CompanionAbility
-- only, uncapped — a single companion never exceeds 0.20 by data).
function Companions.BonusesForCharacter(characterId: string): CompanionBonuses
	return Companions.ComputeBonuses({ characterId })
end

return Companions
