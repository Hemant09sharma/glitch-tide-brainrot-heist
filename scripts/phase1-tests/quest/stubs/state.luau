-- Shared recorder state for the Phase 1 quest tests.
-- Required by both the test (main.luau) and the Remotes stub; Lune
-- caches required modules, so both sides see the same tables.
return {
	fires = {}, -- { { remote = string, player = Player, payload = any } }
	handlers = {}, -- [remoteName] = OnServerEvent handler (onClaim, ...)
	addCoinsCalls = {}, -- { { player = Player, amount = number } }
	addXPCalls = {}, -- { { player = Player, xp = number } }
	setLevelCalls = {}, -- { { player = Player, level = number } }
	saveCalls = 0,
	achievementCalls = {}, -- { { player = Player, kind = string, delta = number } }
	challengeCalls = {}, -- { { player = Player, kind = string, delta = number } }
}
