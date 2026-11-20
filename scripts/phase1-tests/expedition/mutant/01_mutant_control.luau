-- 01_mutant_control.luau — R2-7 negative control (P3): the SAME
-- rejection assertions as expedition/01_expedition_in_transit.luau,
-- run against the MUTANT ExpeditionService (InTransit guards removed
-- by mutant/make_mutant.sh). This file is EXPECTED TO FAIL: the mutant
-- must NOT reject the in-transit start, which proves the test detects
-- the missing guard. Never run under expedition/run.sh — run via
-- mutant/run_mutant.sh, which inverts the exit code.
local H = require("../../harness")
local ExpeditionService = require("./ExpeditionService")

local env = H.newEnv()
ExpeditionService.Init(env.dataService)
ExpeditionService.SetMutationService(env.mutation)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 511, 611)
H.steal(env, pair)
local moved = H.findOwned(pair.thiefData, pair.targetId)
check("M: steal moved the record with InTransit set",
	moved ~= nil and moved.InTransit == true)

local state = ExpeditionService.GetExpeditions(pair.thief)
local inAnyList = false
if type(state.Eligible) == "table" then
	for _, list in pairs(state.Eligible) do
		if type(list) == "table" and table.find(list, pair.targetId) ~= nil then
			inAnyList = true
		end
	end
end
check("M: in-transit Brainrot appears in NO expedition eligible list", inAnyList == false)

local coinsBefore = tonumber(pair.thiefData.Coins) or 0
local okStart, startReason = ExpeditionService.StartExpedition(pair.thief, pair.targetId, "exp_market_run")
check("M: start with an in-transit Brainrot is rejected",
	okStart == false and type(startReason) == "string"
		and string.find(startReason, "transit") ~= nil,
	"reason=" .. tostring(startReason))
check("M: rejected start creates NO Active entry",
	pair.thiefData.Expeditions == nil or pair.thiefData.Expeditions.Active == nil)
check("M: rejected start changes NO flags",
	moved.InTransit == true and moved.OnExpedition ~= true)
check("M: rejected start awards nothing",
	(tonumber(pair.thiefData.Coins) or 0) == coinsBefore)

H.finish()
