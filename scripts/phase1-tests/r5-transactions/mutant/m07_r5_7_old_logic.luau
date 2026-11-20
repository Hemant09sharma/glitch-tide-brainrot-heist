-- m07_r5_7_old_logic.luau — NEGATIVE CONTROL for R5-7 (P2):
-- The test-07 degraded-store scenario run against the PRE-R5-7
-- DataService (mutant/DataServiceR5Pre7.luau: BindToClose runs
-- every player's pre-save hooks inline, one after another, and
-- there is no RunShutdownHooks / RunPreSaveHooks /
-- GetShutdownHookStats). The control PASSES when the OLD bad
-- outcomes are observed: the bounded hook-phase API does not
-- exist, and the sequential hook phase — measured in real
-- DataStore calls from the code under test, at 7 simulated seconds
-- per call — costs 42 s for 6 players and 84 s for 12, blowing
-- the ~30 s shutdown budget before the save phase even starts
-- (Qwen's measurement). If this control failed, test 07 would
-- pass even against the broken code.
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_2_7.sh
local R5 = require("../r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv({ dsPath = "./mutant/DataServiceR5Pre7" })
local DS = env.dataService
local raid = env.raid

local DEGRADED_SECONDS_PER_CALL = 7
local SHUTDOWN_BUDGET_SECONDS = 30

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function totalCalls()
	return (store.calls.GetAsync or 0) + (store.calls.SetAsync or 0)
		+ (store.calls.UpdateAsync or 0) + (store.calls.RemoveAsync or 0)
end

local function findTxId(list, txId)
	if type(list) ~= "table" then
		return nil
	end
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.TxId == txId then
			return entry
		end
	end
	return nil
end

-- Fixtures (same as test 07): 6 steal pairs (thief carries 1
-- Brainrot each) + 6 loaded players with exactly 1 unparked
-- pending reward each.
local thieves = {}
local victims = {}
local targets = {}
for i = 1, 6 do
	local pair = P.newLoadedPair(env, 9800 + i, 9810 + i)
	H.steal(env, pair)
	thieves[i] = pair.thief
	victims[i] = pair.victim
	targets[i] = pair.targetId
end
local pendingPlayers = {}
local pendingTxIds = {}
for i = 1, 6 do
	local player = R5.newLoadedPlayer(env, 9820 + i, 100000)
	local txId = "sr-r5-7-" .. tostring(9820 + i)
	local data = DS.GetData(player)
	data.PendingRewards = {
		["r5-7-inst-" .. tostring(i)] = {
			InstanceId = "r5-7-inst-" .. tostring(i),
			CharacterId = "wobble_waffleton",
			Amount = 300,
			Reason = "steal reward",
			CreatedAt = os.time(),
			Txns = { [txId] = 300 },
			ParkedTxns = {},
		},
	}
	pendingPlayers[i] = player
	pendingTxIds[i] = txId
end
local allHookPlayers = {}
for i = 1, 3 do
	table.insert(allHookPlayers, thieves[i])
end
for i = 1, 3 do
	table.insert(allHookPlayers, pendingPlayers[i])
end
for i = 4, 6 do
	table.insert(allHookPlayers, thieves[i])
end
for i = 4, 6 do
	table.insert(allHookPlayers, pendingPlayers[i])
end

-- --- The bounded hook-phase API does not exist -----------------------
check("old: DataService.RunShutdownHooks does NOT exist",
	type(DS.RunShutdownHooks) ~= "function",
	"type=" .. type(DS.RunShutdownHooks))
check("old: DataService.RunPreSaveHooks does NOT exist",
	type(DS.RunPreSaveHooks) ~= "function",
	"type=" .. type(DS.RunPreSaveHooks))
check("old: DataService.GetShutdownHookStats does NOT exist",
	type(DS.GetShutdownHookStats) ~= "function",
	"type=" .. type(DS.GetShutdownHookStats))

-- --- Measure the per-player hook cost (sync unit) -------------------
local hookCalls = {}
for idx, player in ipairs(allHookPlayers) do
	local before = totalCalls()
	local returned = raid.HandlePlayerLeaving(player)
	local after = totalCalls()
	hookCalls[idx] = after - before
	check("old: hook cost measured for player " .. tostring(idx)
		.. " (returned=" .. tostring(returned) .. ")",
		hookCalls[idx] >= 0)
end
local maxHookCalls = 0
for _, c in ipairs(hookCalls) do
	if c > maxHookCalls then
		maxHookCalls = c
	end
end
check("old: per-player hook work is bounded (at most 2 DataStore calls each)",
	maxHookCalls <= 2, "max=" .. tostring(maxHookCalls))

local function sumCosts(idxs)
	local total = 0
	for _, idx in ipairs(idxs) do
		total += hookCalls[idx] or 0
	end
	return total
end
local seq1 = sumCosts({ 1 }) * DEGRADED_SECONDS_PER_CALL
local seq6 = sumCosts({ 1, 2, 3, 4, 5, 6 }) * DEGRADED_SECONDS_PER_CALL
local seq12 = sumCosts({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }) * DEGRADED_SECONDS_PER_CALL
check("old: sequential hook phase, 1 player: " .. tostring(seq1) .. "s (fits alone)",
	seq1 <= SHUTDOWN_BUDGET_SECONDS, "seq1=" .. tostring(seq1) .. "s")
check("old: sequential hook phase, 6 players: " .. tostring(seq6) .. "s — BLOWS the 30s budget (Qwen: ~42s)",
	seq6 > SHUTDOWN_BUDGET_SECONDS, "seq6=" .. tostring(seq6) .. "s")
check("old: sequential hook phase, 12 players: " .. tostring(seq12) .. "s — far over budget",
	seq12 > SHUTDOWN_BUDGET_SECONDS, "seq12=" .. tostring(seq12) .. "s")

-- --- Setup validation: the old hooks still return Brainrots --------
-- (Not a discriminating check — the R5-7 defect is the unbounded
-- TIME, not ownership. Included so a fixture failure cannot
-- masquerade as a passing control.)
local oneOwner = true
for i = 1, 6 do
	if H.countOwned(env, { thieves[i], victims[i] }, targets[i]) ~= 1
		or H.findOwned(DS.GetData(victims[i]), targets[i]) == nil
		or H.findPlaced(DS.GetData(victims[i]), targets[i]) == nil
	then
		oneOwner = false
	end
end
check("old: after the hooks, every carried Brainrot is back with its victim (exactly 1 owner each)",
	oneOwner == true)
local parksLanded = true
for i = 1, 6 do
	if findTxId(store:peek(P.pendingKey(pendingPlayers[i].UserId)), pendingTxIds[i]) == nil then
		parksLanded = false
	end
end
check("old: the hooks durably parked every pending reward (sidecar holds each TxId)",
	parksLanded == true)

H.finish()
