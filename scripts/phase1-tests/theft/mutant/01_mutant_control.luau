-- 01_mutant_control.luau — R2 P4 negative control: the SAME stale-mutation
-- assertions as theft/10_stale_mutation.luau scenario B, run against the
-- MUTANT RaidService (placed-preferred snapshot restored by
-- mutant/make_mutant.sh). This file is EXPECTED TO FAIL: the mutant must
-- snapshot the stale placed (golden) mutation over the paid owned
-- (electric) one, which proves the test detects the missing fix.
-- Never run under theft/run_all.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")
local Economy = require("../shared/Economy")

local env = H.newEnv({ raidPath = "./theft/mutant/RaidServiceP4" })
local base = H.newBaseEnv(env)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function incomeOf(placed)
	return Economy.IncomePerSecond({
		CharacterId = placed.CharacterId,
		Level = placed.Level,
		Glitched = placed.Glitched,
		Mutation = placed.Mutation,
	})
end

local pair = H.newPair(env, 951, 952)
local plotT = base.AssignBase(pair.thief)
local plotV = base.AssignBase(pair.victim)
assert(plotT ~= nil and plotV ~= nil, "plots not assigned")
local okMut, mutErr = env.mutation.MutateBrainrot(pair.victim, pair.targetId, "electric")
check("M: mutate to electric succeeds", okMut == true, "err=" .. tostring(mutErr))
-- Simulate the stale placed copy: owned is electric, placed lags golden.
H.findPlaced(pair.victimData, pair.targetId).Mutation = "golden"
H.steal(env, pair)
local moved = H.findOwned(pair.thiefData, pair.targetId)
check("M: in-transit record carries the owned (electric) mutation",
	moved ~= nil and moved.Mutation == "electric",
	"Mutation=" .. tostring(moved and moved.Mutation))
H.setRootPosition(pair.thief, H.pedestalPosition(plotT, 1))
local okPlace, placed = base.PlaceBrainrot(pair.thief, pair.targetId, 1)
check("M: delivery succeeds", okPlace == true, "err=" .. tostring(placed))
check("M: delivered placed copy is electric (not the stale golden)",
	placed ~= nil and placed.Mutation == "electric",
	"Mutation=" .. tostring(placed and placed.Mutation))
check("M: delivered income is electric (40/s, not golden 50/s)",
	placed ~= nil and incomeOf(placed) == 40,
	"income=" .. tostring(placed and incomeOf(placed)))

H.finish()
