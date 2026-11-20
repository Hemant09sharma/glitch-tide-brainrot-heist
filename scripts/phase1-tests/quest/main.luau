-- GLITCH TIDE v1.1.0 Phase 1 — quest tests (P0-1, P0-2, duplicate claims).
--
-- SELF-CONTAINED: does NOT depend on scripts/phase1-tests/harness.luau
-- (built in parallel by another agent). Own minimal stubs, own runner.
--
-- Loads the REAL src/server/Services/QuestService.luau untouched via
-- require, with stubbed Roblox globals. The trick: Lune require paths
-- resolve relative to the requiring file, so the ReplicatedStorage
-- stub's WaitForChild returns a path relative to QuestService's own
-- directory (src/server/Services/ -> ../../../scripts/...).
-- If QuestService moves, this require breaks loudly instead of
-- silently testing a stale copy.
--
-- Run from the package root:
--   lune run scripts/phase1-tests/quest/main.luau
-- Exit 0 iff every check passes (first failure raises).
--
-- Covers (task §Tests):
--  1. Real client payload {Action="ClaimQuest", QuestId=...} accepted
--     by the server onClaim handler; legacy bare-string form accepted.
--  2. A completed quest grants its reward exactly once (direct double
--     ClaimQuest AND double onClaim across the rate-limit window).
--  3. RecordEvent does not throw and quest progress actually advances.
--  4. Quest progress is pushed after an event, exactly once.
--  5. Achievement/challenge forwarding happens exactly once for a
--     mapped event and zero times for an unmapped event.

local fs = require("@lune/fs")

local state = require("./stubs/state")

-- --- Roblox globals -------------------------------------------------------
-- task.spawn / task.delay are captured BEFORE the module under test is
-- initialised: QuestService.Init spawns 3 threads (1) the 5s
-- auto-track poll, (2) the ClaimQuest remote wiring, (3) the
-- RequestQuests wiring. The poll must never run under test (it loops
-- forever); the test invokes spawns [2] and [3] by hand and asserts
-- spawn [1] is the poll by never invoking it.
local luneTask = require("@lune/task")
local realWait = luneTask.wait
local spawned = {}
-- Roblox's task library does not exist as a Lune global, so define it:
-- spawn captures (never runs) the thread, delay is a no-op, wait is a
-- no-op. Real sleeping (rate-limit test) uses realWait, saved above.
task = {
	spawn = function(f, ...)
		table.insert(spawned, f)
	end,
	delay = function() end,
	wait = function()
		return 0
	end,
	defer = luneTask.defer,
	cancel = luneTask.cancel,
}

-- warn is used by onClaim on a failed claim; define it so a missing
-- Lune global can never turn a rejected claim into a test error.
warn = function(...)
	print("[warn]", ...)
end

local playersList = {}
local Players = {
	LocalPlayer = nil,
	GetPlayers = function()
		return playersList
	end,
	PlayerAdded = {
		Connect = function(_self, _fn)
			return { Disconnect = function() end }
		end,
	},
	PlayerRemoving = {
		Connect = function(_self, _fn)
			return { Disconnect = function() end }
		end,
	},
}

local ReplicatedStorage = {
	WaitForChild = function(_self, name)
		-- Relative to src/server/Services/QuestService.luau (the file
		-- that calls require on this value), NOT to this test file.
		return "../../../scripts/phase1-tests/quest/stubs/" .. name
	end,
}

game = {
	GetService = function(_self, name)
		if name == "Players" then
			return Players
		elseif name == "ReplicatedStorage" then
			return ReplicatedStorage
		end
		error("unexpected service: " .. tostring(name))
	end,
}

-- --- Fake DataService / cross-service fakes -------------------------------
local dataByPlayer = {}

local function freshData()
	return {
		Coins = 0,
		Gems = 0,
		XP = 0,
		Level = 1,
		EventTokens = 0,
		BaseSlots = 4,
		Base = { Slots = 4 },
		Unlocked = {},
	}
end

local DataService = {
	GetOrLoad = function(player)
		if dataByPlayer[player] == nil then
			dataByPlayer[player] = freshData()
		end
		return dataByPlayer[player]
	end,
	AddCoins = function(player, amount)
		local data = dataByPlayer[player]
		data.Coins = (data.Coins or 0) + amount
		table.insert(state.addCoinsCalls, { player = player, amount = amount })
	end,
	SetLevel = function(player, level)
		dataByPlayer[player].Level = level
		table.insert(state.setLevelCalls, { player = player, level = level })
	end,
	SaveData = function(_player)
		state.saveCalls += 1
	end,
}

local AchievementService = {
	CheckProgress = function(player, kind, delta)
		table.insert(state.achievementCalls, { player = player, kind = kind, delta = delta })
	end,
	SetProgress = function(_player, _kind, _value) end,
}

local ProgressionService = {
	AddXP = function(player, xp)
		local data = dataByPlayer[player]
		data.XP = (data.XP or 0) + xp
		table.insert(state.addXPCalls, { player = player, xp = xp })
	end,
	CheckChallenge = function(player, kind, delta)
		table.insert(state.challengeCalls, { player = player, kind = kind, delta = delta })
	end,
}

-- --- Load the REAL QuestService -------------------------------------------
local QuestService = require("../../../src/server/Services/QuestService")

QuestService.Init(DataService)
QuestService.SetAchievementService(AchievementService)
QuestService.SetProgressionService(ProgressionService)

-- Init must have spawned exactly 3 threads; run the two wiring
-- spawns (ClaimQuest remote, RequestQuests function) and never the
-- poll loop (spawn [1]).
if #spawned ~= 3 then
	error("FAIL: QuestService.Init spawned " .. #spawned .. " threads, expected 3", 0)
end
spawned[2]()
spawned[3]()

local onClaim = state.handlers["ClaimQuest"]
if type(onClaim) ~= "function" then
	error("FAIL: ClaimQuest OnServerEvent handler was never connected by Init", 0)
end
print("PASS: setup — real QuestService loaded, Init wired ClaimQuest handler")

-- --- Helpers ---------------------------------------------------------------
local passed = 1 -- setup check above

local function check(name, cond, detail)
	if not cond then
		error("FAIL: " .. name .. (detail and (" — " .. tostring(detail)) or ""), 0)
	end
	passed += 1
	print("PASS: " .. name)
end

local playerCounter = 0
local function makePlayer()
	playerCounter += 1
	local p = { Name = "TestPlayer" .. playerCounter, Parent = true }
	function p:IsA(className)
		return className == "Player"
	end
	return p
end

local function questState(player, id)
	for _, q in ipairs(QuestService.GetQuests(player)) do
		if q.Id == id then
			return q
		end
	end
	return nil
end

local function countCalls(list, player)
	local n = 0
	for _, c in ipairs(list) do
		if c.player == player then
			n += 1
		end
	end
	return n
end

local function clearFakes()
	table.clear(state.achievementCalls)
	table.clear(state.challengeCalls)
end

-- --- 1. Client payload shape (source assertion + live handler) ----------
do
	local src = fs.readFile("src/client/Controllers/QuestController.luau")
	check(
		"client sends {Action=\"ClaimQuest\", QuestId=id} envelope",
		string.find(src, 'FireServer({ Action = "ClaimQuest", QuestId = id })', 1, true) ~= nil
	)
	check(
		"client no longer sends the bare-string FireServer(questId)",
		string.find(src, "FireServer(questId)", 1, true) == nil
	)
	check(
		"client keeps the 2s claim debounce",
		string.find(src, "claimCooldowns[id]", 1, true) ~= nil
			and string.find(src, "if now - (claimCooldowns[id] or 0) < 2 then", 1, true) ~= nil
	)
end

-- --- P0-1a. Envelope payload accepted ------------------------------------
do
	local player = makePlayer()
	QuestService.RecordEvent(player, "buy_brainrot", 1)
	check("setup: q_buy_first completes on buy_brainrot", (questState(player, "q_buy_first") or {}).Progress == 1)
	local coinsBefore = dataByPlayer[player].Coins
	onClaim(player, { Action = "ClaimQuest", QuestId = "q_buy_first" })
	check(
		"envelope claim pays the reward (coins +100)",
		dataByPlayer[player].Coins - coinsBefore == 100,
		"coins delta = " .. (dataByPlayer[player].Coins - coinsBefore)
	)
	check("envelope claim marks quest claimed", questState(player, "q_buy_first").Claimed == true)
	check("envelope claim grants XP via ProgressionService", countCalls(state.addXPCalls, player) == 1)
end

-- --- P0-1b. Legacy bare-string payload accepted --------------------------
do
	local player = makePlayer()
	QuestService.RecordEvent(player, "buy_brainrot", 1)
	local coinsBefore = dataByPlayer[player].Coins
	onClaim(player, "q_buy_first")
	check(
		"legacy bare-string claim pays the reward (coins +100)",
		dataByPlayer[player].Coins - coinsBefore == 100,
		"coins delta = " .. (dataByPlayer[player].Coins - coinsBefore)
	)
	check("legacy bare-string claim marks quest claimed", questState(player, "q_buy_first").Claimed == true)
end

-- --- P0-1c. Bad payloads rejected, no reward ------------------------------
do
	local badPayloads = {
		{ "wrong Action", { Action = "Steal", QuestId = "q_buy_first" } },
		{ "number payload", 123 },
		{ "nil payload", nil },
		{ "unknown quest id", { Action = "ClaimQuest", QuestId = "q_nope" } },
		{ "missing QuestId", { Action = "ClaimQuest" } },
		{ "empty QuestId", { Action = "ClaimQuest", QuestId = "" } },
		{ "non-string QuestId", { Action = "ClaimQuest", QuestId = 42 } },
	}
	for _, case in ipairs(badPayloads) do
		local label, payload = case[1], case[2]
		local player = makePlayer()
		QuestService.RecordEvent(player, "buy_brainrot", 1)
		local coinsBefore = dataByPlayer[player].Coins
		local ok = pcall(onClaim, player, payload)
		check("bad payload rejected without error (" .. label .. ")", ok)
		check(
			"bad payload pays nothing (" .. label .. ")",
			dataByPlayer[player].Coins == coinsBefore and questState(player, "q_buy_first").Claimed ~= true
		)
	end
	-- Unmet goal: envelope is well-formed but progress is 0.
	local player = makePlayer()
	onClaim(player, { Action = "ClaimQuest", QuestId = "q_buy_first" })
	check("claim with unmet goal pays nothing", dataByPlayer[player].Coins == 0)
	check("claim with unmet goal leaves quest unclaimed", questState(player, "q_buy_first").Claimed ~= true)
end

-- --- Duplicate claims: direct double ClaimQuest ---------------------------
do
	local player = makePlayer()
	QuestService.RecordEvent(player, "survive_tide", 1)
	check("setup: q_survive_tide completes", (questState(player, "q_survive_tide") or {}).Progress == 1)
	local ok1, _r1 = QuestService.ClaimQuest(player, "q_survive_tide")
	local ok2, reason2 = QuestService.ClaimQuest(player, "q_survive_tide")
	check("first ClaimQuest succeeds", ok1 == true)
	check("second ClaimQuest is rejected", ok2 == false, "returned " .. tostring(ok2))
	check("second ClaimQuest reason is already claimed", reason2 == "already claimed", "reason = " .. tostring(reason2))
	-- q_survive_tide reward: 200 coins, 5 gems, 50 XP, 5 tokens.
	check("reward paid exactly once (AddCoins calls)", countCalls(state.addCoinsCalls, player) == 1)
	check("coins delta is exactly the reward (200)", dataByPlayer[player].Coins == 200)
	check("gems delta is exactly the reward (5)", dataByPlayer[player].Gems == 5)
	check("event tokens delta is exactly the reward (5)", dataByPlayer[player].EventTokens == 5)
	check("XP granted exactly once", countCalls(state.addXPCalls, player) == 1)
end

-- --- Duplicate claims: double onClaim across the rate-limit window --------
do
	local player = makePlayer()
	QuestService.RecordEvent(player, "survive_tide", 1)
	onClaim(player, { Action = "ClaimQuest", QuestId = "q_survive_tide" })
	check("first onClaim pays", dataByPlayer[player].Coins == 200)
	-- Wait out the 1s server rate limit so the second call reaches
	-- ClaimQuest itself (and is NOT merely rate-limited away).
	realWait(1.2)
	onClaim(player, { Action = "ClaimQuest", QuestId = "q_survive_tide" })
	check(
		"second onClaim (after rate window) pays nothing more",
		dataByPlayer[player].Coins == 200 and countCalls(state.addCoinsCalls, player) == 1
	)
end

-- --- P0-2. RecordEvent does not throw; progress advances ------------------
do
	local player = makePlayer()
	local ok, err = pcall(function()
		QuestService.RecordEvent(player, "buy_brainrot", 1)
	end)
	check("RecordEvent does not throw", ok == true, "error: " .. tostring(err))
	check("RecordEvent advances q_buy_first to 1", (questState(player, "q_buy_first") or {}).Progress == 1)
	check("RecordEvent advances q_story_1 (same event) to 1", (questState(player, "q_story_1") or {}).Progress == 1)
	-- ReportProgress is the canonical hook and calls RecordEvent
	-- directly (no pcall) — the old forward-reference error used to
	-- propagate out of it.
	local ok2, err2 = pcall(function()
		QuestService.ReportProgress(player, "tide_survived", "survive", 1)
	end)
	check("ReportProgress does not throw", ok2 == true, "error: " .. tostring(err2))
	check("ReportProgress advances q_survive_tide to 1", (questState(player, "q_survive_tide") or {}).Progress == 1)
end

-- --- Push: exactly one QuestUpdate fire per event --------------------------
do
	local player = makePlayer()
	local firesBefore = #state.fires
	QuestService.RecordEvent(player, "buy_brainrot", 1)
	local newFires = {}
	for i = firesBefore + 1, #state.fires do
		table.insert(newFires, state.fires[i])
	end
	check("one push fire for the event (not one per quest)", #newFires == 1, "fires = " .. #newFires)
	local payload = newFires[1].payload
	check("push fires on QuestUpdate", newFires[1].remote == "QuestUpdate")
	check("push payload Action is QuestProgress", payload.Action == "QuestProgress")
	local found = nil
	for _, q in ipairs(payload.Quests) do
		if q.Id == "q_buy_first" then
			found = q
		end
	end
	check("push payload carries updated progress (q_buy_first 1/1)", found ~= nil and found.Progress == 1)
	-- Second identical event: already at goal, no change -> no push.
	local firesBefore2 = #state.fires
	QuestService.RecordEvent(player, "buy_brainrot", 1)
	check("no push when nothing changed", #state.fires == firesBefore2)
end

-- --- Forwarding: exactly once for mapped, zero for unmapped ---------------
do
	local player = makePlayer()
	clearFakes()
	QuestService.RecordEvent(player, "buy_brainrot", 1)
	check("mapped event forwards to achievements exactly once", countCalls(state.achievementCalls, player) == 1)
	check("mapped event forwards kind first_buy", state.achievementCalls[1].kind == "first_buy")
	check("mapped event forwards delta 1", state.achievementCalls[1].delta == 1)
	check("mapped event forwards to challenges exactly once", countCalls(state.challengeCalls, player) == 1)
	check("mapped event forwards challenge kind first_buy", state.challengeCalls[1].kind == "first_buy")
end

do
	local player = makePlayer()
	clearFakes()
	QuestService.RecordEvent(player, "earn_coins", 50)
	check("unmapped event forwards to achievements zero times", countCalls(state.achievementCalls, player) == 0)
	check("unmapped event forwards to challenges zero times", countCalls(state.challengeCalls, player) == 0)
	check("unmapped event still advances quest progress", (questState(player, "q_earn_1000") or {}).Progress == 50)
end

-- --- Funnel: one ReportProgress id mapping to two events forwards once ----
do
	local player = makePlayer()
	clearFakes()
	QuestService.ReportProgress(player, "boss_defeated", "defeat_boss_colossus", 1)
	check(
		"two-event ReportProgress forwards to achievements exactly once",
		countCalls(state.achievementCalls, player) == 1,
		"calls = " .. countCalls(state.achievementCalls, player)
	)
	check(
		"two-event ReportProgress forwards to challenges exactly once",
		countCalls(state.challengeCalls, player) == 1
	)
	check("two-event ReportProgress advances q_defeat_boss", (questState(player, "q_defeat_boss") or {}).Progress == 1)
	check(
		"two-event ReportProgress advances q_defeat_colossus",
		(questState(player, "q_defeat_colossus") or {}).Progress == 1
	)
end

print(string.format("ALL %d CHECKS PASSED", passed))
