-- Minimal Economy stub for the quest tests. XPForLevel is only used
-- by the fallback (no-ProgressionService) XP path in ClaimQuest;
-- the tests link a recording ProgressionService fake instead, so this
-- is load-time cover only.
return {
	XPForLevel = function(level)
		return 100 * (level or 1)
	end,
}
