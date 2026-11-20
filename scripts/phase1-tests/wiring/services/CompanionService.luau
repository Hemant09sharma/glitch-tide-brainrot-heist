-- CompanionService.luau — TEST STUB (hand-written, NOT a copy of
-- src/server/Services/CompanionService.luau, so no divergence check
-- applies to this file).
--
-- Minimal stand-in for the real CompanionService, present in the
-- wiring registry so GameManager.loadOptional picks it up through the
-- production path. It returns the 0.75 carry cap from
-- GetCarrySpeedMultiplier and records its Init arguments, so the test
-- can assert the production init/wiring ran — without the test ever
-- calling CarryService.SetCompanionService itself.
local CompanionService = {}

local _initArgs: { [string]: any }? = nil
local _calls = 0

function CompanionService.Init(dataService: any?, economyService: any?, map: any?)
	_initArgs = {
		DataService = dataService,
		EconomyService = economyService,
		Map = map,
	}
end

function CompanionService.GetInitArgs(): { [string]: any }?
	return _initArgs
end

function CompanionService.GetCarrySpeedMultiplier(_player: Player): number
	_calls += 1
	return 0.75
end

function CompanionService.GetCallCount(): number
	return _calls
end

return CompanionService
