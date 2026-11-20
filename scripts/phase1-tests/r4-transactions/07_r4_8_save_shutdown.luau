-- 07_r4_8_save_shutdown.luau — R4-8 (P2, Tests H and I):
-- (H) SaveData's _saving wait: the old code waited 5 s and then
-- DROPPED a leave save. The fix waits, retries the wait once on
-- the leave/shutdown path (PlayerRemoving passes WaitSeconds=10,
-- RetryOnce=true), and NEVER removes the _saving guard itself
-- (removing it would reintroduce concurrent-save races).
-- (I) BindToClose sequential saves could exceed the ~30 s shutdown
-- budget with 12 players under a degraded store (~9 s per player:
-- 3 retries x 1 s sleeps + waits). The fix fans out: one spawned
-- task per player, bounded ~25 s wait for all of them, so the cost
-- is roughly the slowest single save instead of the sum.
-- Lune honesty note: the harness stub DISCARDS task.spawn (it only
-- counts spawns) and task.wait returns at once, so wall-clock
-- shutdown timing cannot be measured here — and product modules'
-- `task.spawn` calls cannot be intercepted from a test (Luau
-- compiles them as builtin fastcalls that bypass the _G.task table
-- the harness replaces; verified by probe: a throwing override is
-- never reached from DataService, and a 1 s real-clock spin after
-- SaveAllForShutdown still leaves completed=0). The shutdown
-- section therefore proves what Lune CAN prove: the fan-out spawns
-- exactly one task per player, returns bounded (the ~25 s wait),
-- and the synchronous per-player unit (SaveForShutdown — the exact
-- body each spawned task runs) saves all 12 players correctly.
-- The parallel-vs-sequential bound itself (parallel cost ≈ slowest
-- single save, sequential cost ≈ the sum) is a code argument, in
-- the comment at the BindToClose site and in the R4 report; it
-- needs a Studio shutdown test to observe end-to-end.
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local store = R.store
local env = R.newEnv()
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

-- --- (H) The _saving wait: wait, then succeed when the in-flight save clears
local player = R.newLoadedPlayer(env, 9470, 5000)
local baseIterations = DS.GetSaveWaitIterations()
DS._TestSetSavingFlag(player, true) -- an autosave is in flight
local hookCalls = 0
DS._TestSetWaitHook(function(_p)
	hookCalls += 1
	if hookCalls == 1 then
		DS._TestSetSavingFlag(player, false) -- the autosave finishes
	end
end)
DS.AddCoins(player, 1000) -- cache 6000, stored key still 5000
local okSave = DS.SaveData(player, { WaitSeconds = 5, RetryOnce = false })
DS._TestSetWaitHook(nil)
check("(H) a save waits for the in-flight save instead of racing it", okSave == true)
check("(H) the wait ran exactly one iteration before the flag cleared",
	DS.GetSaveWaitIterations() - baseIterations == 1,
	"iterations=" .. tostring(DS.GetSaveWaitIterations() - baseIterations))
check("(H) the waited save landed (stored key 6000)",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 6000)

-- The guard is NOT removed: while a save is held, another save
-- waits and does NOT write concurrently.
DS.AddCoins(player, 1000) -- cache 7000
DS._TestSetSavingFlag(player, true)
local base2 = DS.GetSaveWaitIterations()
local okHeld = DS.SaveData(player, { WaitSeconds = 1, RetryOnce = false })
check("(H) a save refused while another save is held does not write",
	okHeld == false and (tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 6000)
check("(H) the held save waited the full window (5 iterations for 1 s)",
	DS.GetSaveWaitIterations() - base2 == 5,
	"iterations=" .. tostring(DS.GetSaveWaitIterations() - base2))

-- Held forever + RetryOnce (the leave path): two full waits, then
-- a loud drop (return false) — and the guard still stands.
local base3 = DS.GetSaveWaitIterations()
local okDropped = DS.SaveData(player, { WaitSeconds = 5, RetryOnce = true })
check("(H) a save held through both waits is dropped, not raced",
	okDropped == false)
check("(H) the retry-once path waited twice (50 iterations for 5 s + 5 s)",
	DS.GetSaveWaitIterations() - base3 == 50,
	"iterations=" .. tostring(DS.GetSaveWaitIterations() - base3))
check("(H) the dropped save wrote nothing (stored key still 6000)",
	(tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 6000)
DS._TestSetSavingFlag(player, false)
check("(H) once the in-flight save clears, saving works again",
	DS.SaveData(player) == true
		and (tonumber(store:peek(P.mainKey(player.UserId)).Coins) or 0) == 7000)

-- --- (I) Shutdown: the synchronous per-player unit, 12 players ----
local players12 = {}
for i = 1, 12 do
	local p = R.newLoadedPlayer(env, 9470 + i, 1000 + i)
	DS.AddCoins(p, 50) -- cache 1050+i, stored key still 1000+i
	table.insert(players12, p)
end
local savedUnits = 0
for _, p in ipairs(players12) do
	if DS.SaveForShutdown(p) == true then
		savedUnits += 1
	end
end
check("(I) the synchronous per-player shutdown unit saves all 12 players",
	savedUnits == 12, "savedUnits=" .. tostring(savedUnits))
local storedOk = true
for i, p in ipairs(players12) do
	if (tonumber(store:peek(P.mainKey(p.UserId)).Coins) or 0) ~= 1050 + i then
		storedOk = false
	end
end
check("(I) all 12 stored keys hold the shutdown save", storedOk == true)

-- The fan-out: one spawn per player, bounded return. (The spawned
-- saves themselves are discarded by the harness stub — see the
-- header note — so completed/saved stay 0 here; the per-player
-- unit above is the proof that each spawned task saves correctly.)
for _, p in ipairs(players12) do
	DS.AddCoins(p, 1) -- cache 1051+i, stored key still 1050+i
end
local resultsStub = DS.SaveAllForShutdown(players12)
local statsStub = DS.GetShutdownStats()
check("(I) shutdown fan-out attempts all 12 players", resultsStub.attempted == 12)
check("(I) shutdown fan-out spawns exactly one task per player",
	statsStub.spawned == 12, "spawned=" .. tostring(statsStub.spawned))
check("(I) shutdown fan-out returns bounded (did not hang on the wait loop)",
	resultsStub.completed ~= nil and resultsStub.saved ~= nil)

H.finish()
