-- m07_r4_8_old_logic.luau — NEGATIVE CONTROL for R4-8 (Tests H, I):
-- The same save/shutdown probes as test 07, run against the R3
-- mutant DataService (SaveData drops after ONE wait — no RetryOnce
-- second wait; SaveAllForShutdown saves sequentially — no spawned
-- fan-out). The control PASSES when the OLD behaviour is observed:
-- a held save is dropped after 25 wait iterations instead of 50,
-- and the shutdown fan-out spawns zero tasks.
-- Run: bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
local R = require("../r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv({ dsPath = "./mutant/DataServiceR3" })
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local player = R.newLoadedPlayer(env, 9670, 5000)
DS._TestSetSavingFlag(player, true) -- another save held forever
local base = DS.GetSaveWaitIterations()
local okDropped = DS.SaveData(player, { WaitSeconds = 5, RetryOnce = true })
local waited = DS.GetSaveWaitIterations() - base
check("OLD BUG REPRODUCED: the held save is dropped after ONE wait (25 iterations, no retry)",
	okDropped == false and waited == 25, "waited=" .. tostring(waited))
check("OLD BUG REPRODUCED: the dropped save wrote nothing",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 5000)
DS._TestSetSavingFlag(player, false)

local players12 = {}
for i = 1, 12 do
	local p = R.newLoadedPlayer(env, 9670 + i, 1000 + i)
	table.insert(players12, p)
end
local results = DS.SaveAllForShutdown(players12)
local stats = DS.GetShutdownStats()
check("OLD BUG REPRODUCED: the shutdown fan-out spawns zero tasks (sequential saves)",
	stats.spawned == 0, "spawned=" .. tostring(stats.spawned))
check("old logic: the sequential shutdown still saves all 12 (just not in parallel)",
	results.completed == 12 and results.saved == 12,
	"completed=" .. tostring(results.completed) .. " saved=" .. tostring(results.saved))

H.finish()
