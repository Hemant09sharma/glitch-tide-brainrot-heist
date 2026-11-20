-- Minimal Characters stub for the quest tests. Only used by the 5s
-- auto-track poll (never run under test); provided so the real
-- QuestService.luau loads untouched.
return {
	GetById = function(_id)
		return nil
	end,
	GetRarityRank = function(_rarity)
		return 0
	end,
}
