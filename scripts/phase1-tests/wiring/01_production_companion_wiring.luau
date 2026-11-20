-- 01_production_companion_wiring.luau — R2-6 (P1-3): the companion
-- CarrySpeed bonus must reach CarryService through the PRODUCTION
-- init path, not a manual SetCompanionService call inside the test.
--
-- Bug: GameManager.wireCrossLinks builds a shared setter table that
-- includes SetCompanionService = _optional["CompanionService"], but
-- it only applies wireAll to services in _optional. CarryService is
-- a required CORE service (GameManager top-level require), never in
-- _optional, so it never received the wiring — the companion bonus
-- (up to 0.75 total) never applied in production, and carrying always
-- used the Config 0.6 fallback (16 * 0.6 = 9.6). The theft 08 test
-- only proved the setter works when called by hand.
--
-- This test drives the REAL GameManager.Init with the real
-- GameManager / BaseService / CarryService / ConveyorService copies
-- (wiring/services/, refreshed from src/ by refresh.sh) and a stub
-- CompanionService present in the service registry. It asserts the
-- stub is untouched before Init, then that carrying AFTER Init uses
-- the stub's 0.75 multiplier (16 * 0.75 = 12) — the 12 can only
-- happen if production wiring called CarryService.SetCompanionService
-- with the registry's companion. The test never calls
-- SetCompanionService itself. (The 0.6 fallback with no companion —
-- 16 * 0.6 = 9.6 — is covered by theft test 08 checks 1-2.)
--
-- Harness notes: `script` is nil under Lune, but the real GameManager
-- requires its core services via script.Parent, so the test defines
-- a `script` global whose Parent IS the module registry (exactly
-- what script.Parent is in Roblox): WaitForChild returns the Lune
-- require path of the sibling module, FindFirstChild returns the
-- stub CompanionService's path and nil for every other optional
-- service (production behaviour when a module is absent: warn +
-- skip). RunService:IsStudio is stubbed true so the BindToClose
-- branch (never reachable under Lune) is skipped.
-- Run: bash scripts/phase1-tests/wiring/run.sh
local H = require("../harness")

-- Module registry: script.Parent in production.
script = {
	Parent = {
		WaitForChild = function(_self, name)
			return "./" .. name
		end,
		FindFirstChild = function(_self, name)
			if name == "CompanionService" then
				return "./CompanionService"
			end
			return nil
		end,
	},
}

-- Skip BindToClose (GameManager.Init checks RunService:IsStudio()).
local runService = game:GetService("RunService")
runService.IsStudio = function()
	return true
end

local GameManager = require("./services/GameManager")
local CarryService = require("./services/CarryService")
local CompanionStub = require("./services/CompanionService")

local dataService = H.newDataService()
local economyStub = {}
local env = { dataService = dataService }
local pair = H.newPair(env, 181, 281)
local thief = pair.thief

-- 1. Before GameManager.Init: the registry's companion has not been
-- touched (no Init, no speed queries). (The 0.6 fallback itself —
-- 16 * 0.6 = 9.6 with no companion wired — is covered by theft test
-- 08 checks 1-2; this test cannot pick up before Init because
-- CarryService.Init only runs inside GameManager.Init.)
H.check(1, "wiring: companion stub not Init'd before GameManager.Init",
	CompanionStub.GetInitArgs() == nil)
H.check(2, "wiring: companion stub not consulted before GameManager.Init",
	CompanionStub.GetCallCount() == 0, "calls=" .. tostring(CompanionStub.GetCallCount()))

-- 2. Drive the REAL production init path.
GameManager.Init(dataService, economyStub, nil)

-- 3. The registry's companion was loaded and Init'd by loadOptional
-- (generic fallback Init(dataService, economyService, map)).
local initArgs = CompanionStub.GetInitArgs()
H.check(3, "wiring: CompanionService.Init ran via loadOptional",
	initArgs ~= nil, "initArgs=" .. tostring(initArgs))
H.check(4, "wiring: CompanionService.Init got the production data/economy services",
	initArgs ~= nil and initArgs.DataService == dataService and initArgs.EconomyService == economyStub)
local optional = GameManager.GetOptionalServices()
H.check(5, "wiring: CompanionService is in GameManager's optional registry",
	optional["CompanionService"] ~= nil and optional["CompanionService"] == CompanionStub)
H.check(6, "wiring: GameManager.GetService returns the same CarryService under test",
	GameManager.GetService("CarryService") == CarryService)

-- 4. The companion bonus now applies with NO manual injection:
-- carrying must use the stub's 0.75 multiplier (16 * 0.75 = 12).
local carryRec = H.findOwned(pair.thiefData, pair.prefix .. "carry_1")
local okPick2, _id2 = CarryService.PickupOwned(thief, carryRec)
H.check(7, "wiring: pickup succeeds after GameManager.Init", okPick2 == true, "ok=" .. tostring(okPick2))
H.check(8, "wiring: production wiring applies the companion bonus (16 * 0.75 = 12)",
	math.abs(thief._Humanoid.WalkSpeed - 12) < 1e-9,
	"walkSpeed=" .. tostring(thief._Humanoid.WalkSpeed))
H.check(9, "wiring: the companion stub was actually consulted for the speed",
	CompanionStub.GetCallCount() >= 1, "calls=" .. tostring(CompanionStub.GetCallCount()))
CarryService.ClearCarried(thief, true)
H.check(10, "wiring: clearing the carry restores base walk speed 16",
	math.abs(thief._Humanoid.WalkSpeed - 16) < 1e-9,
	"walkSpeed=" .. tostring(thief._Humanoid.WalkSpeed))

H.finish()
