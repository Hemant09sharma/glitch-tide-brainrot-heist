-- 07_r5_7_bounded_shutdown_hooks.luau — R5-7 (P2):
-- Bound the shutdown recovery hooks.
--
-- Qwen measured the sequential pre-save hook phase at ~42 simulated
-- seconds for six players in a degraded-store scenario, BEFORE the
-- parallel save phase — the old BindToClose ran every player's
-- HandlePlayerLeaving inline, one after another, so the hook cost
-- grew with the headcount and blew the ~30 s shutdown budget. The
-- fix: DataService runs the hook phase in parallel (one spawned task
-- per player, bounded wait) and serialises hooks per player (a hook
-- for a player never runs twice concurrently — e.g. PlayerRemoving +
-- BindToClose for the same player). The save phase
-- (SaveAllForShutdown) was already parallel since R4-8.
--
-- Lune honesty note (same as r4 test 07): task.spawn is discarded by
-- the harness stub (it only counts spawns) and task.wait returns at
-- once, so wall-clock shutdown timing cannot be measured here, and
-- no Studio shutdown timing is claimed. What this test proves:
--   * the per-player hook work is bounded and measured in real
--     DataStore calls (the code under test, not a model);
--   * the old sequential shape's cost (SUM of per-player costs)
--     exceeds the 30 s budget at 6 players (42 s, reproducing
--     Qwen's measurement) and doubles at 12;
--   * the new parallel shape's cost (MAX per-player hook cost +
--     slowest single save) stays under 30 s for 1, 6 and 12 players;
--   * the parallel hook phase spawns exactly one task per player and
--     returns bounded (structure, like r4 test 07);
--   * per-player serialisation: a re-entrant hook run for the same
--     player is refused, and a later sequential run works again;
--   * one-owner guarantees: after the hooks run, every carried
--     Brainrot is back with its victim, exactly one owner each.
--
-- Degraded-store model (stated, not hidden): one DataStore operation
-- in the hook path costs DEGRADED_SECONDS_PER_CALL = 7 simulated
-- seconds under degradation (calibrated to Qwen's measurement: 6
-- players x 1 sidecar op each x 7 s = 42 s). A degraded single save
-- costs SAVE_SECONDS_PER_PLAYER = 9 s (the R4-8 model: 3 retries x
-- 1 s sleeps + waits). The test measures the CALL COUNTS from the
-- real code and applies the model; the discrimination (sum vs max)
-- is the property under test, not the constant.
-- Run: bash scripts/phase1-tests/r5-transactions/run.sh
local R5 = require("./r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv()
local DS = env.dataService
local raid = env.raid

local DEGRADED_SECONDS_PER_CALL = 7
local SAVE_SECONDS_PER_PLAYER = 9
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

-- Fixtures: 6 steal pairs (thief carries 1 Brainrot each) + 6 loaded
-- players with exactly 1 unparked pending reward each. The 1-player
-- case is the first thief; the 6-player case is the first 3 thieves +
-- the first 3 pending players; the 12-player case is all of them.
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

-- --- Measure the per-player hook cost (sync unit) -------------------
-- Each player's HandlePlayerLeaving is run exactly once; the
-- DataStore calls it makes are the hook's real work. (The run also
-- consumes the transit / parks the reward, so these are one-shot
-- measurements — the same population is reused for the 1/6/12-player
-- totals below.)
local hookCalls = {}
for idx, player in ipairs(allHookPlayers) do
	local before = totalCalls()
	local returned = raid.HandlePlayerLeaving(player)
	local after = totalCalls()
	hookCalls[idx] = after - before
	check("hook cost measured for player " .. tostring(idx)
		.. " (returned=" .. tostring(returned) .. ")",
		hookCalls[idx] >= 0)
end
local maxHookCalls = 0
for _, c in ipairs(hookCalls) do
	if c > maxHookCalls then
		maxHookCalls = c
	end
end
check("per-player hook work is bounded (at most 2 DataStore calls each)",
	maxHookCalls <= 2, "max=" .. tostring(maxHookCalls))

local function sumCosts(idxs)
	local total = 0
	for _, idx in ipairs(idxs) do
		total += hookCalls[idx] or 0
	end
	return total
end
-- 1 player = first thief; 6 players = first 6 recorded; 12 = all.
local seq1 = sumCosts({ 1 }) * DEGRADED_SECONDS_PER_CALL
local seq6 = sumCosts({ 1, 2, 3, 4, 5, 6 }) * DEGRADED_SECONDS_PER_CALL
local seq12 = sumCosts({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }) * DEGRADED_SECONDS_PER_CALL
local parHook = maxHookCalls * DEGRADED_SECONDS_PER_CALL
local parTotal = parHook + SAVE_SECONDS_PER_PLAYER
check("OLD sequential hook phase, 1 player: " .. tostring(seq1) .. "s (one player's work)",
	seq1 <= SHUTDOWN_BUDGET_SECONDS, "seq1=" .. tostring(seq1) .. "s")
check("OLD sequential hook phase, 6 players: " .. tostring(seq6) .. "s — BLOWS the 30s budget (Qwen: ~42s)",
	seq6 > SHUTDOWN_BUDGET_SECONDS, "seq6=" .. tostring(seq6) .. "s")
check("OLD sequential hook phase, 12 players: " .. tostring(seq12) .. "s — far over budget",
	seq12 > SHUTDOWN_BUDGET_SECONDS, "seq12=" .. tostring(seq12) .. "s")
check("NEW parallel hook phase: slowest single player is " .. tostring(parHook) .. "s (headcount-independent)",
	parHook <= 10, "parHook=" .. tostring(parHook) .. "s")
check("NEW parallel total (hooks + slowest save): " .. tostring(parTotal) .. "s < 30s for 1 player",
	parTotal < SHUTDOWN_BUDGET_SECONDS, "total=" .. tostring(parTotal) .. "s")
check("NEW parallel total stays under 30s for 6 players (same max, not the sum)",
	parTotal < SHUTDOWN_BUDGET_SECONDS, "total=" .. tostring(parTotal) .. "s")
check("NEW parallel total stays under 30s for 12 players (same max, not the sum)",
	parTotal < SHUTDOWN_BUDGET_SECONDS, "total=" .. tostring(parTotal) .. "s")

-- --- One-owner guarantees after the hooks ---------------------------
local oneOwner = true
for i = 1, 6 do
	if H.countOwned(env, { thieves[i], victims[i] }, targets[i]) ~= 1
		or H.findOwned(DS.GetData(victims[i]), targets[i]) == nil
		or H.findPlaced(DS.GetData(victims[i]), targets[i]) == nil
	then
		oneOwner = false
	end
end
check("after the hooks, every carried Brainrot is back with its victim (exactly 1 owner each)",
	oneOwner == true)
local parksLanded = true
for i = 1, 6 do
	if findTxId(store:peek(P.pendingKey(pendingPlayers[i].UserId)), pendingTxIds[i]) == nil then
		parksLanded = false
	end
end
check("the hooks durably parked every pending reward (sidecar holds each TxId)",
	parksLanded == true)

-- --- Save phase (sync unit): all 12 shutdown saves land -----------
local saveCalls = {}
local savedCount = 0
for idx, player in ipairs(allHookPlayers) do
	DS.AddCoins(player, 10)
	local before = totalCalls()
	if DS.SaveForShutdown(player) == true then
		savedCount += 1
	end
	saveCalls[idx] = totalCalls() - before
end
local maxSaveCalls = 0
for _, c in ipairs(saveCalls) do
	if c > maxSaveCalls then
		maxSaveCalls = c
	end
end
check("the synchronous per-player shutdown save lands for all 12 players",
	savedCount == 12, "saved=" .. tostring(savedCount))
check("a single shutdown save is bounded work (at most 6 DataStore calls)",
	maxSaveCalls <= 6, "max=" .. tostring(maxSaveCalls))

-- --- The new parallel hook phase (structure) ------------------------
check("DataService.RunShutdownHooks exists (the bounded parallel hook phase)",
	type(DS.RunShutdownHooks) == "function")
check("DataService.RunPreSaveHooks exists (the synchronous per-player hook unit)",
	type(DS.RunPreSaveHooks) == "function")
check("DataService.GetShutdownHookStats exists",
	type(DS.GetShutdownHookStats) == "function")
if type(DS.RunShutdownHooks) == "function" then
	local six = {}
	for i = 1, 6 do
		table.insert(six, allHookPlayers[i])
	end
	local res6 = DS.RunShutdownHooks(six)
	check("RunShutdownHooks(6) attempts all 6 players",
		res6.attempted == 6, "attempted=" .. tostring(res6.attempted))
	check("RunShutdownHooks(6) spawns exactly one task per player",
		res6.spawned == 6, "spawned=" .. tostring(res6.spawned))
	check("RunShutdownHooks(6) returns bounded (did not hang on the wait)",
		res6.completed ~= nil)
	local res12 = DS.RunShutdownHooks(allHookPlayers)
	check("RunShutdownHooks(12) attempts all 12 players",
		res12.attempted == 12, "attempted=" .. tostring(res12.attempted))
	check("RunShutdownHooks(12) spawns exactly one task per player",
		res12.spawned == 12, "spawned=" .. tostring(res12.spawned))
	local stats = DS.GetShutdownHookStats()
	check("GetShutdownHookStats reports the 12-player run",
		stats.attempted == 12 and stats.spawned == 12,
		"attempted=" .. tostring(stats.attempted) .. " spawned=" .. tostring(stats.spawned))
end

-- --- Per-player serialisation (last: registers a hook) --------------
local hookRuns = 0
local innerResult = nil
local function countingHook(player)
	hookRuns += 1
	if type(DS.RunPreSaveHooks) == "function" then
		innerResult = DS.RunPreSaveHooks(player)
	end
end
DS.RegisterPreSaveHook(countingHook)
local idlePlayer = R5.newLoadedPlayer(env, 9830, 5000)
local hookRunsBefore = hookRuns
local ranOuter = nil
if type(DS.RunPreSaveHooks) == "function" then
	ranOuter = DS.RunPreSaveHooks(idlePlayer)
end
check("a hook run for an idle player runs the hooks",
	ranOuter == true, "ran=" .. tostring(ranOuter))
check("the counting hook ran exactly once (the re-entrant call did NOT re-run it)",
	hookRuns - hookRunsBefore == 1, "runs=" .. tostring(hookRuns - hookRunsBefore))
check("the re-entrant hook call for the same player was refused (serialisation)",
	innerResult == false, "inner=" .. tostring(innerResult))
local ranOuter2 = nil
if type(DS.RunPreSaveHooks) == "function" then
	ranOuter2 = DS.RunPreSaveHooks(idlePlayer)
end
check("a later sequential hook run works again (the guard resets)",
	ranOuter2 == true and hookRuns - hookRunsBefore == 2,
	"ran=" .. tostring(ranOuter2) .. " runs=" .. tostring(hookRuns - hookRunsBefore))

H.finish()
