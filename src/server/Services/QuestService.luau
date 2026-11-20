--!strict
-- QuestService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- 54 quests across tutorial / daily / weekly / story / collection /
-- exploration / secret / raid / mutation / combat / event / expedition /
-- territory / dimension. Progress is auto-tracked three ways:
-- RecordEvent(player, eventName, amount) called by other services,
-- ReportProgress(player, kind, id, amount) — the v1.1 canonical hook
-- (maps a progress kind to quest events AND forwards to
-- AchievementService.CheckProgress / ProgressionService.CheckChallenge)
-- — and a lightweight 5s poll that derives earn-coins / own-distinct /
-- discover-rarity progress straight from the player's data, plus a
-- zone poll (Forbidden Rift / Mutation Lab / Abyssal / Skyfall).
-- Rewards are granted exactly once, only through ClaimQuest, after
-- the server re-checks the goal. Daily quests reset by calendar day
-- (data.QuestDay); weekly quests reset by ISO week (data.QuestWeek).
-- Story quests chain via the optional Requires field (the prerequisite
-- must be CLAIMED before the next quest can progress).
--
-- REMOTE: ClaimQuest binds directly to the ClaimQuest RemoteEvent
-- (the old header claiming it reused CollectIncome was wrong).
-- Quest progress fires on QuestUpdate when present, else PlayerStats. (PlayerStats IS a RemoteEvent in Remotes.luau — the
-- v1.0.0 comment claiming it was a RemoteFunction was wrong.)
--
-- v1.0.1 QA: the "Epic Discovery" quest fired for Rare Brainrots
-- (rank >= 3); it now correctly requires Epic+ (rank >= 4). Zone
-- quests (visit_rift / visit_lab) had NO caller anywhere, so a
-- position poll in Init now records visits to the Forbidden Rift and
-- Mutation Lab map zones.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Economy = require(ReplicatedStorage:WaitForChild("Economy"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local QuestService = {}

local _dataService: any = nil
local _progressionService: any = nil
local _achievementService: any = nil

export type QuestDef = {
	Id: string,
	Name: string,
	Description: string,
	Category: string, -- "Tutorial" | "Daily" | "Weekly" | "Story" | "Collection" | "Exploration" | "Secret" | "Raid" | "Mutation" | "Combat" | "Event" | "Expedition" | "Territory" | "Dimension" | "Survival"
	Event: string,
	Goal: number,
	Reward: { Coins: number, Gems: number, XP: number, EventTokens: number },
	Requires: string?, -- quest Id that must be CLAIMED before this quest can progress (story chains)
}

local QUESTS: { QuestDef } = {
	-- Tutorial ------------------------------------------------------------
	{ Id = "q_buy_first", Name = "First Purchase", Description = "Buy your first Brainrot.", Category = "Tutorial", Event = "buy_brainrot", Goal = 1, Reward = { Coins = 100, Gems = 0, XP = 25, EventTokens = 0 } },
	{ Id = "q_place_first", Name = "Home Sweet Home", Description = "Place your first Brainrot in your base.", Category = "Tutorial", Event = "place_brainrot", Goal = 1, Reward = { Coins = 100, Gems = 0, XP = 25, EventTokens = 0 } },
	{ Id = "q_earn_1000", Name = "Coin Starter", Description = "Earn 1,000 coins in total.", Category = "Tutorial", Event = "earn_coins", Goal = 1000, Reward = { Coins = 150, Gems = 5, XP = 50, EventTokens = 0 } },
	-- Daily ---------------------------------------------------------------
	{ Id = "q_survive_tide", Name = "Tide Survivor", Description = "Survive 1 Glitch Tide.", Category = "Daily", Event = "survive_tide", Goal = 1, Reward = { Coins = 200, Gems = 5, XP = 50, EventTokens = 5 } },
	{ Id = "q_earn_5000", Name = "Daily Grind", Description = "Earn 5,000 coins today.", Category = "Daily", Event = "earn_coins", Goal = 5000, Reward = { Coins = 300, Gems = 10, XP = 75, EventTokens = 5 } },
	-- Collection ----------------------------------------------------------
	{ Id = "q_own_5", Name = "Growing Collection", Description = "Own 5 distinct Brainrots.", Category = "Collection", Event = "own_distinct", Goal = 5, Reward = { Coins = 250, Gems = 10, XP = 75, EventTokens = 0 } },
	{ Id = "q_discover_epic", Name = "Epic Discovery", Description = "Discover an Epic (or rarer) Brainrot.", Category = "Collection", Event = "discover_epic", Goal = 1, Reward = { Coins = 400, Gems = 15, XP = 100, EventTokens = 5 } },
	-- Exploration ---------------------------------------------------------
	{ Id = "q_visit_rift", Name = "Into the Rift", Description = "Visit the Forbidden Rift.", Category = "Exploration", Event = "visit_rift", Goal = 1, Reward = { Coins = 200, Gems = 5, XP = 50, EventTokens = 0 } },
	{ Id = "q_visit_lab", Name = "Lab Rat", Description = "Visit the Mutation Lab.", Category = "Exploration", Event = "visit_lab", Goal = 1, Reward = { Coins = 200, Gems = 5, XP = 50, EventTokens = 0 } },
	-- Raid ----------------------------------------------------------------
	{ Id = "q_steal_1", Name = "Sticky Fingers", Description = "Successfully steal 1 Brainrot.", Category = "Raid", Event = "steal_success", Goal = 1, Reward = { Coins = 300, Gems = 10, XP = 75, EventTokens = 5 } },
	{ Id = "q_defend_1", Name = "Home Defender", Description = "Stop 1 theft attempt against your base.", Category = "Raid", Event = "defend_success", Goal = 1, Reward = { Coins = 300, Gems = 10, XP = 75, EventTokens = 5 } },
	-- Mutation ------------------------------------------------------------
	{ Id = "q_mutate_1", Name = "Mad Scientist", Description = "Mutate 1 Brainrot.", Category = "Mutation", Event = "mutate", Goal = 1, Reward = { Coins = 250, Gems = 5, XP = 75, EventTokens = 5 } },
	{ Id = "q_fuse_1", Name = "Fusion Chef", Description = "Fuse 2 Brainrots into 1.", Category = "Mutation", Event = "fuse", Goal = 1, Reward = { Coins = 250, Gems = 5, XP = 75, EventTokens = 5 } },
	-- Combat --------------------------------------------------------------
	{ Id = "q_defeat_5", Name = "NPC Hunter", Description = "Defeat 5 NPC Brainrots.", Category = "Combat", Event = "defeat_npc", Goal = 5, Reward = { Coins = 300, Gems = 10, XP = 100, EventTokens = 5 } },
	{ Id = "q_defeat_boss", Name = "Algorithm Breaker", Description = "Defeat THE ALGORITHM boss.", Category = "Combat", Event = "defeat_boss", Goal = 1, Reward = { Coins = 1000, Gems = 50, XP = 250, EventTokens = 20 } },
	-- Event ---------------------------------------------------------------
	{ Id = "q_survive_meteor", Name = "Meteor Dodger", Description = "Survive a Meteor tide.", Category = "Event", Event = "survive_meteor_tide", Goal = 1, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 10 } },
	-- Main story chain (v1.1, Workstream C) ---------------------------
	-- Five stages, chained: each stage only progresses once the
	-- previous stage is CLAIMED (Requires).
	{ Id = "q_story_1", Name = "A Glitch in the Tale", Description = "Buy your first Brainrot and begin the story.", Category = "Story", Event = "buy_brainrot", Goal = 1, Reward = { Coins = 100, Gems = 0, XP = 25, EventTokens = 0 } },
	{ Id = "q_story_2", Name = "Settle In", Description = "Place a Brainrot in your base.", Category = "Story", Event = "place_brainrot", Goal = 1, Reward = { Coins = 150, Gems = 5, XP = 50, EventTokens = 0 }, Requires = "q_story_1" },
	{ Id = "q_story_3", Name = "The Merchant's Whisper", Description = "Discover a hidden secret of the Memeverse.", Category = "Story", Event = "discover_secret", Goal = 1, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 5 }, Requires = "q_story_2" },
	{ Id = "q_story_4", Name = "Lab Rat Supreme", Description = "Evolve a Brainrot in the Laboratory.", Category = "Story", Event = "evolve", Goal = 1, Reward = { Coins = 500, Gems = 10, XP = 150, EventTokens = 5 }, Requires = "q_story_3" },
	{ Id = "q_story_5", Name = "Tidecaller", Description = "Survive 3 Glitch Tides.", Category = "Story", Event = "survive_tide", Goal = 3, Reward = { Coins = 1000, Gems = 25, XP = 250, EventTokens = 10 }, Requires = "q_story_4" },
	-- Daily, extra (v1.1) ------------------------------------------------
	{ Id = "q_daily_earn_10k", Name = "Big Earner", Description = "Earn 10,000 coins today.", Category = "Daily", Event = "earn_coins", Goal = 10000, Reward = { Coins = 400, Gems = 10, XP = 100, EventTokens = 5 } },
	{ Id = "q_daily_tides_2", Name = "Double Survivor", Description = "Survive 2 Glitch Tides today.", Category = "Daily", Event = "survive_tide", Goal = 2, Reward = { Coins = 300, Gems = 10, XP = 75, EventTokens = 5 } },
	{ Id = "q_daily_expedition", Name = "Field Trip", Description = "Complete 1 expedition today.", Category = "Daily", Event = "complete_expedition", Goal = 1, Reward = { Coins = 300, Gems = 10, XP = 100, EventTokens = 5 } },
	-- Weekly (v1.1; reset by ISO week, see ensureQuests) --------------
	{ Id = "q_weekly_earn_50k", Name = "Tycoon Week", Description = "Earn 50,000 coins this week.", Category = "Weekly", Event = "earn_coins", Goal = 50000, Reward = { Coins = 1500, Gems = 25, XP = 250, EventTokens = 10 } },
	{ Id = "q_weekly_tides_10", Name = "Tideproof", Description = "Survive 10 Glitch Tides this week.", Category = "Weekly", Event = "survive_tide", Goal = 10, Reward = { Coins = 1500, Gems = 25, XP = 250, EventTokens = 15 } },
	{ Id = "q_weekly_bosses_3", Name = "Boss Bounty", Description = "Defeat 3 world bosses this week.", Category = "Weekly", Event = "defeat_boss", Goal = 3, Reward = { Coins = 2000, Gems = 50, XP = 400, EventTokens = 20 } },
	-- Exploration, extra (v1.1) ------------------------------------------
	{ Id = "q_visit_abyssal", Name = "Into the Deep", Description = "Visit the Abyssal Kingdom.", Category = "Exploration", Event = "visit_abyssal", Goal = 1, Reward = { Coins = 250, Gems = 5, XP = 75, EventTokens = 0 } },
	{ Id = "q_visit_skyfall", Name = "Into the Sky", Description = "Visit the Skyfall Kingdom.", Category = "Exploration", Event = "visit_skyfall", Goal = 1, Reward = { Coins = 250, Gems = 5, XP = 75, EventTokens = 0 } },
	-- Secrets (v1.1) ------------------------------------------------------
	{ Id = "q_secret_1", Name = "Secret Seeker", Description = "Discover 1 hidden secret.", Category = "Secret", Event = "discover_secret", Goal = 1, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 0 } },
	{ Id = "q_secret_3", Name = "Secret Hunter", Description = "Discover 3 hidden secrets.", Category = "Secret", Event = "discover_secret", Goal = 3, Reward = { Coins = 1500, Gems = 50, XP = 400, EventTokens = 0 } },
	-- Collection, extra (v1.1) --------------------------------------------
	{ Id = "q_own_10", Name = "Established Collection", Description = "Own 10 distinct Brainrots.", Category = "Collection", Event = "own_distinct", Goal = 10, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 0 } },
	{ Id = "q_own_20", Name = "Grand Collection", Description = "Own 20 distinct Brainrots.", Category = "Collection", Event = "own_distinct", Goal = 20, Reward = { Coins = 1000, Gems = 25, XP = 300, EventTokens = 0 } },
	{ Id = "q_own_27", Name = "Complete Collection", Description = "Own all 27 Brainrots.", Category = "Collection", Event = "own_distinct", Goal = 27, Reward = { Coins = 5000, Gems = 100, XP = 1000, EventTokens = 50 } },
	-- Mutation / Laboratory, extra (v1.1) ----------------------------------
	{ Id = "q_mutate_5", Name = "Serial Mutator", Description = "Mutate 5 Brainrots.", Category = "Mutation", Event = "mutate", Goal = 5, Reward = { Coins = 750, Gems = 15, XP = 200, EventTokens = 10 } },
	{ Id = "q_evolve_1", Name = "Evolutionist", Description = "Evolve 1 Brainrot in the Laboratory.", Category = "Mutation", Event = "evolve", Goal = 1, Reward = { Coins = 500, Gems = 10, XP = 150, EventTokens = 5 } },
	{ Id = "q_evolve_3", Name = "Evolution Master", Description = "Evolve 3 Brainrots in the Laboratory.", Category = "Mutation", Event = "evolve", Goal = 3, Reward = { Coins = 1500, Gems = 25, XP = 400, EventTokens = 10 } },
	{ Id = "q_fuse_5", Name = "Fusion Expert", Description = "Fuse 5 pairs of Brainrots.", Category = "Mutation", Event = "fuse", Goal = 5, Reward = { Coins = 750, Gems = 15, XP = 200, EventTokens = 10 } },
	{ Id = "q_trait_5", Name = "Trait Master", Description = "Upgrade Brainrot traits 5 times in the Laboratory.", Category = "Mutation", Event = "trait_upgrade", Goal = 5, Reward = { Coins = 750, Gems = 15, XP = 200, EventTokens = 10 } },
	-- Survival, extra (v1.1) ----------------------------------------------
	{ Id = "q_survive_10", Name = "Tide Veteran", Description = "Survive 10 Glitch Tides.", Category = "Survival", Event = "survive_tide", Goal = 10, Reward = { Coins = 1000, Gems = 20, XP = 300, EventTokens = 10 } },
	{ Id = "q_survive_flawless", Name = "Flawless", Description = "Survive a Glitch Tide without being hit once.", Category = "Event", Event = "survive_flawless", Goal = 1, Reward = { Coins = 750, Gems = 15, XP = 200, EventTokens = 10 } },
	{ Id = "q_survive_boss_tide", Name = "Boss Tide Survivor", Description = "Survive a Giant Boss tide.", Category = "Event", Event = "survive_boss_tide", Goal = 1, Reward = { Coins = 1000, Gems = 25, XP = 300, EventTokens = 10 } },
	-- Boss, extra (v1.1) ----------------------------------------------------
	{ Id = "q_defeat_colossus", Name = "Colossus Crusher", Description = "Defeat THE GLITCH COLOSSUS.", Category = "Combat", Event = "defeat_boss_colossus", Goal = 1, Reward = { Coins = 1500, Gems = 50, XP = 400, EventTokens = 20 } },
	{ Id = "q_defeat_void", Name = "Void Vanquisher", Description = "Defeat THE VOID EMPEROR.", Category = "Combat", Event = "defeat_boss_void_emperor", Goal = 1, Reward = { Coins = 2000, Gems = 75, XP = 500, EventTokens = 25 } },
	{ Id = "q_boss_fights_5", Name = "Boss Regular", Description = "Take part in 5 boss fights.", Category = "Combat", Event = "boss_participate", Goal = 5, Reward = { Coins = 1000, Gems = 25, XP = 300, EventTokens = 15 } },
	-- Combat / Raid, extra (v1.1) -------------------------------------------
	{ Id = "q_defeat_25", Name = "NPC Exterminator", Description = "Defeat 25 NPC Brainrots.", Category = "Combat", Event = "defeat_npc", Goal = 25, Reward = { Coins = 750, Gems = 20, XP = 250, EventTokens = 10 } },
	{ Id = "q_defend_3", Name = "Fortress", Description = "Stop 3 theft attempts against your base.", Category = "Raid", Event = "defend_success", Goal = 3, Reward = { Coins = 750, Gems = 15, XP = 200, EventTokens = 10 } },
	-- Expedition (v1.1) -------------------------------------------------------
	{ Id = "q_expedition_1", Name = "First Expedition", Description = "Complete 1 expedition.", Category = "Expedition", Event = "complete_expedition", Goal = 1, Reward = { Coins = 300, Gems = 10, XP = 100, EventTokens = 5 } },
	{ Id = "q_expedition_5", Name = "Expedition Veteran", Description = "Complete 5 expeditions.", Category = "Expedition", Event = "complete_expedition", Goal = 5, Reward = { Coins = 1000, Gems = 25, XP = 300, EventTokens = 10 } },
	-- Territory (v1.1) ---------------------------------------------------------
	{ Id = "q_territory_1", Name = "Land Grabber", Description = "Capture 1 territory.", Category = "Territory", Event = "capture_territory", Goal = 1, Reward = { Coins = 300, Gems = 10, XP = 100, EventTokens = 5 } },
	{ Id = "q_territory_5", Name = "Territory Lord", Description = "Capture 5 territories.", Category = "Territory", Event = "capture_territory", Goal = 5, Reward = { Coins = 1000, Gems = 25, XP = 300, EventTokens = 10 } },
	-- Dimension (v1.1) -----------------------------------------------------------
	{ Id = "q_chest_3", Name = "Treasure Hunter", Description = "Open 3 dimension treasure chests.", Category = "Dimension", Event = "open_chest", Goal = 3, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 5 } },
	{ Id = "q_checkpoint_1", Name = "Sky Runner", Description = "Complete the Skyfall checkpoint run.", Category = "Dimension", Event = "complete_checkpoint", Goal = 1, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 5 } },
	-- Event, extra (v1.1) ---------------------------------------------------------
	{ Id = "q_event_3", Name = "Event Regular", Description = "Take part in 3 events.", Category = "Event", Event = "participate_event", Goal = 3, Reward = { Coins = 500, Gems = 15, XP = 150, EventTokens = 10 } },
}

local _byId: { [string]: QuestDef } = {}
for _, quest in ipairs(QUESTS) do
	_byId[quest.Id] = quest
end

local _rate: { [Player]: number } = {}
-- Last-seen coin total per player, for the earn-coins poll.
local _coinBaseline: { [Player]: number } = {}
-- Last-seen distinct-owned count per player, for the own-distinct poll.
local _distinctBaseline: { [Player]: number } = {}

local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function rateOk(player: Player, key: string, interval: number): boolean
	if Security and Security.RateLimit then
		local ok, allowed = pcall(function()
			return Security.RateLimit(player, key, interval)
		end)
		if ok then
			return allowed
		end
	end
	local now = os.clock()
	local last = _rate[player] or -math.huge
	if now - last < interval then
		return false
	end
	_rate[player] = now
	return true
end

local function sanitize(id: any): string?
	if Security and Security.SanitizeId then
		local ok, clean = pcall(function()
			return Security.SanitizeId(id)
		end)
		if ok then
			return clean
		end
	end
	if type(id) ~= "string" or #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
end

local function getRemote(name: string): RemoteEvent?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

local function getFunction(name: string): RemoteFunction?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetFunction(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteFunction") then
		return remote :: RemoteFunction
	end
	return nil
end

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

local function getData(player: Player): any
	if not _dataService then
		return nil
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

local function todayString(): string
	return os.date("%Y-%m-%d") :: string
end

-- ISO week string ("2026-W47"): weekly quests reset when it rolls.
local function weekString(): string
	return os.date("%Y-W%W") :: string
end

-- ensureQuests(player): create data.Quests when missing and reset Daily
-- quests when the calendar day rolled over, Weekly quests when the ISO
-- week rolled over.
local function ensureQuests(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.Quests) ~= "table" then
		data.Quests = {}
	end
	if data.QuestDay ~= todayString() then
		data.QuestDay = todayString()
		for _, quest in ipairs(QUESTS) do
			if quest.Category == "Daily" then
				data.Quests[quest.Id] = { Progress = 0, Claimed = false }
			end
		end
	end
	if data.QuestWeek ~= weekString() then
		data.QuestWeek = weekString()
		for _, quest in ipairs(QUESTS) do
			if quest.Category == "Weekly" then
				data.Quests[quest.Id] = { Progress = 0, Claimed = false }
			end
		end
	end
	for _, quest in ipairs(QUESTS) do
		if type(data.Quests[quest.Id]) ~= "table" then
			data.Quests[quest.Id] = { Progress = 0, Claimed = false }
		end
	end
	return data
end

local function pushProgress(player: Player)
	local data = getData(player)
	if not data then
		return
	end
	local questName = _names.QuestUpdate or _names.PlayerStats
	fireClient(questName, player, {
		Action = "QuestProgress",
		Quests = QuestService.GetQuests(player),
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
	})
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- GetQuests(player): every quest with live Progress / Claimed flags.
function QuestService.GetQuests(player: Player): { any }
	local data = ensureQuests(player)
	if not data then
		return {}
	end
	local out: { any } = {}
	for _, quest in ipairs(QUESTS) do
		local state = data.Quests[quest.Id]
		table.insert(out, {
			Id = quest.Id,
			Name = quest.Name,
			Description = quest.Description,
			Category = quest.Category,
			Goal = quest.Goal,
			Progress = math.min(tonumber(state.Progress) or 0, quest.Goal),
			Claimed = state.Claimed == true,
			Reward = quest.Reward,
		})
	end
	return out
end

-- EVENT_KIND_MAP: which achievement / challenge kind a quest event
-- also advances. This is the SINGLE funnel: RecordEvent is the only
-- place that forwards to achievements / challenges, so a tide that
-- fires both survive_tide AND survive_meteor_tide still counts ONCE
-- toward tide_survived (only survive_tide maps to it; the variant
-- events are quest-only). ReportProgress maps kind/id -> events and
-- calls RecordEvent, so it can never double-count either.
-- (Defined above RecordEvent: RecordEvent calls forwardProgress, and
-- under --!strict a local must be declared before first use.)
local EVENT_KIND_MAP: { [string]: string } = {
	survive_tide = "tide_survived",
	survive_flawless = "tide_flawless",
	defeat_boss = "boss_defeated",
	boss_participate = "boss_participated",
	fuse = "fusion",
	mutate = "mutation",
	evolve = "evolution",
	trait_upgrade = "trait",
	complete_expedition = "expedition",
	discover_secret = "secret",
	capture_territory = "territory",
	participate_event = "event",
	buy_brainrot = "first_buy",
	place_brainrot = "first_place",
}

local function forwardProgress(player: Player, eventName: string, delta: number)
	local kind = EVENT_KIND_MAP[eventName]
	if kind == nil then
		return
	end
	if _achievementService and type(_achievementService.CheckProgress) == "function" then
		pcall(function()
			_achievementService.CheckProgress(player, kind, delta)
		end)
	end
	if _progressionService and type(_progressionService.CheckChallenge) == "function" then
		pcall(function()
			_progressionService.CheckChallenge(player, kind, delta)
		end)
	end
end

-- RecordEvent(player, eventName, amount): advance every quest listening
-- to `eventName`. GameManager / other services call this on buy, place,
-- steal, defend, mutate, fuse, NPC defeat, boss defeat, tide survival
-- and zone visits. Amount defaults to 1; progress clamps at the goal.
-- A quest with Requires only progresses once its prerequisite quest
-- has been CLAIMED (story chains).
function QuestService.RecordEvent(player: Player, eventName: any, amount: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(eventName) ~= "string" or eventName == "" then
		return
	end
	local data = ensureQuests(player)
	if not data then
		return
	end
	local delta = math.max(0, math.floor(tonumber(amount) or 1))
	local changed = false
	for _, quest in ipairs(QUESTS) do
		if quest.Event == eventName then
			if quest.Requires ~= nil then
				local prereq = data.Quests[quest.Requires]
				if type(prereq) ~= "table" or prereq.Claimed ~= true then
					continue
				end
			end
			local state = data.Quests[quest.Id]
			local before = tonumber(state.Progress) or 0
			local after = math.min(quest.Goal, before + delta)
			if after ~= before then
				state.Progress = after
				changed = true
				if after >= quest.Goal then
					print(string.format(
						"[QuestService] %s completed quest %s (%s)",
						player.Name, quest.Id, quest.Name
					))
				end
			end
		end
	end
	-- Forward to achievements / challenges exactly once per event
	-- (not per quest — several quests can share one event). Runs even
	-- when no quest progressed: achievements have their own goals.
	forwardProgress(player, eventName, delta)
	if changed then
		pushProgress(player)
	end
end

-- REPORT_PROGRESS_MAP: the v1.1 canonical hook taxonomy. ReportProgress
-- (player, kind, id, amount) maps a progress kind + detail id to the
-- quest Event names it advances, then calls RecordEvent for each —
-- RecordEvent is the funnel that also forwards to achievements and
-- challenges (see EVENT_KIND_MAP). `kind` uses the SAME strings as
-- AchievementService.CheckProgress and ProgressionService.CheckChallenge
-- (tide_survived, boss_defeated, fusion, ...) so one call updates
-- quests, achievements and challenges together. Kinds with no quest
-- event (collection, level) map to an empty list; for those two, the
-- `amount` is an ABSOLUTE value (total distinct / current level) and
-- is sent to AchievementService.SetProgress instead.
local REPORT_PROGRESS_MAP: { [string]: { [string]: { string } } } = {
	tide_survived = {
		survive = { "survive_tide" },
		Meteor = { "survive_meteor_tide" },
		GiantBoss = { "survive_boss_tide" },
	},
	tide_flawless = {
		flawless = { "survive_flawless" },
	},
	boss_defeated = {
		defeat_boss = { "defeat_boss" },
		defeat_boss_colossus = { "defeat_boss", "defeat_boss_colossus" },
		defeat_boss_void_emperor = { "defeat_boss", "defeat_boss_void_emperor" },
	},
	boss_participated = {
		participate = { "boss_participate" },
	},
	boss_top_damage = {},
	fusion = {
		fuse = { "fuse" },
	},
	mutation = {
		mutate = { "mutate" },
	},
	evolution = {
		evolve = { "evolve" },
	},
	trait = {
		upgrade = { "trait_upgrade" },
		alternate_form = { "trait_upgrade" },
	},
	expedition = {
		complete = { "complete_expedition" },
	},
	secret = {
		discover = { "discover_secret" },
		recipe = { "discover_secret" },
	},
	territory = {
		capture = { "capture_territory" },
	},
	dimension = {
		visit_abyssal = { "visit_abyssal" },
		visit_skyfall = { "visit_skyfall" },
		chest = { "open_chest" },
		checkpoint = { "complete_checkpoint" },
	},
	event = {
		participate = { "participate_event" },
	},
	collection = {},
	level = {},
	rebirth = {},
	prestige = {},
	first_buy = {},
	first_place = {},
}

-- ReportProgress(player, kind, id, amount): the v1.1 canonical
-- progress hook. Called by TideService / BossService /
-- DimensionsService / EventService (1-3 line hook calls) and by the
-- Wave 2 services (Laboratory / Expedition / Territory / Secret).
-- Advances the mapped quest events via RecordEvent (which also
-- forwards to achievements / challenges exactly once). Unknown kinds
-- / ids are harmless no-ops for quests. For the absolute kinds
-- "level" / "collection", `amount` is the absolute value and is sent
-- to AchievementService.SetProgress.
function QuestService.ReportProgress(player: Player, kind: any, id: any, amount: any)
	if not player or not player:IsA("Player") then
		return
	end
	if type(kind) ~= "string" or kind == "" then
		return
	end
	local detail = type(id) == "string" and id or "default"
	local delta = math.max(0, math.floor(tonumber(amount) or 1))
	if kind == "level" or kind == "collection" then
		if _achievementService and type(_achievementService.SetProgress) == "function" then
			pcall(function()
				_achievementService.SetProgress(player, kind, delta)
			end)
		end
		return
	end
	local byId = REPORT_PROGRESS_MAP[kind]
	if byId ~= nil then
		local events = byId[detail]
		if events ~= nil then
			for _, eventName in ipairs(events) do
				QuestService.RecordEvent(player, eventName, delta)
			end
		end
	end
end

-- ClaimQuest(player, questId): validate the goal is met and the quest
-- was never claimed, then grant the reward exactly once.
-- Returns (true, reward) or (false, reason).
function QuestService.ClaimQuest(player: Player, questId: any): (boolean, any)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(questId)
	if not clean then
		return false, "invalid quest id"
	end
	local def = _byId[clean]
	if not def then
		return false, "unknown quest"
	end
	local data = ensureQuests(player)
	if not data then
		return false, "no data"
	end
	local state = data.Quests[clean]
	if state.Claimed == true then
		return false, "already claimed"
	end
	if (tonumber(state.Progress) or 0) < def.Goal then
		return false, "goal not met"
	end
	state.Claimed = true
	local reward = def.Reward
	-- Coins + gems + event tokens are direct. XP goes through
	-- ProgressionService.AddXP when linked — the one level-up path
	-- that pays the documented rewards (50+25/level coins, +5 gems
	-- every 5 levels, +1 base slot every 10). v1.0.0 ran its own
	-- inline loop paying a flat 25 coins per level and no gems/slots,
	-- so the same level-up paid differently depending on which
	-- service granted the XP. The inline loop below is only the
	-- fallback when ProgressionService is not linked, and it now
	-- matches ProgressionService's rewards exactly.
	pcall(function()
		_dataService.AddCoins(player, reward.Coins)
	end)
	data.Gems = (tonumber(data.Gems) or 0) + reward.Gems
	data.EventTokens = (tonumber(data.EventTokens) or 0) + reward.EventTokens
	if _progressionService and type(_progressionService.AddXP) == "function" then
		pcall(function()
			_progressionService.AddXP(player, reward.XP)
		end)
	else
		local newXP = (tonumber(data.XP) or 0) + reward.XP
		local level = tonumber(data.Level) or 1
		while newXP >= Economy.XPForLevel(level) do
			newXP -= Economy.XPForLevel(level)
			level += 1
			data.Coins = (tonumber(data.Coins) or 0) + 50 + 25 * level
			if level % 5 == 0 then
				data.Gems = (tonumber(data.Gems) or 0) + 5
			end
			if level % 10 == 0 then
				local newSlots = math.min(10, (tonumber(data.BaseSlots) or 4) + 1)
				data.BaseSlots = newSlots
				if type(data.Base) == "table" then
					data.Base.Slots = newSlots
				end
			end
		end
		data.XP = newXP
		if level ~= (tonumber(data.Level) or 1) then
			_dataService.SetLevel(player, level)
			print(string.format("[QuestService] %s levelled up to %d (quest reward)", player.Name, level))
		end
	end
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	pushProgress(player)
	print(string.format(
		"[QuestService] %s claimed %s: +%d coins, +%d gems, +%d XP, +%d tokens",
		player.Name, clean, reward.Coins, reward.Gems, reward.XP, reward.EventTokens
	))
	return true, reward
end

function QuestService.SetProgressionService(progressionService: any)
	if progressionService and type(progressionService.AddXP) == "function" then
		_progressionService = progressionService
	end
end

-- SetAchievementService: AchievementService.Init calls this itself
-- (it takes QuestService as its 2nd Init argument), and
-- GameManager.wireCrossLinks calls it when the setter name is added
-- to its shared table. Until then, achievement forwarding is skipped
-- (quests still work).
function QuestService.SetAchievementService(achievementService: any)
	if achievementService and type(achievementService.CheckProgress) == "function" then
		_achievementService = achievementService
	end
end

local function onClaim(player: Player, payload: any)
	if not player or not player:IsA("Player") then
		return
	end
	-- ClaimQuest is a dedicated RemoteEvent (not shared with the
	-- core-loop income handler). Two payload shapes are accepted:
	--   { Action = "ClaimQuest", QuestId = <id> }  (current client)
	--   "<questId>"                                 (legacy bare string)
	-- Anything else is ignored. QuestId validation (non-empty string,
	-- known quest) happens inside ClaimQuest via sanitize + _byId.
	local questId: any = nil
	if type(payload) == "table" and payload.Action == "ClaimQuest" then
		questId = payload.QuestId
	elseif type(payload) == "string" then
		questId = payload
	else
		return
	end
	if not rateOk(player, "ClaimQuest", 1) then
		return
	end
	local ok, err = QuestService.ClaimQuest(player, questId)
	if not ok then
		warn("[QuestService] Claim failed for " .. player.Name .. ": " .. tostring(err))
	end
end

function QuestService.Init(dataService: any)
	assert(dataService ~= nil, "[QuestService] Init requires DataService")
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player)
		_rate[player] = nil
		_coinBaseline[player] = nil
		_distinctBaseline[player] = nil
	end)

	-- Push the live quest list shortly after join, so a fresh client
	-- learns its quests without waiting for progress to change.
	-- (v1.0.1 integration QA: RequestQuests below covers the pull path;
	-- this push covers the join path.)
	local function pushOnJoin(player: Player)
		task.delay(2, function()
			if player.Parent then
				pushProgress(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(pushOnJoin)
	for _, player in ipairs(Players:GetPlayers()) do
		pushOnJoin(player)
	end

	-- Zone lookup (built lazily): the ForbiddenRift / MutationLab
	-- folders live under the built map model in Workspace, so a
	-- recursive search finds them wherever MapBuilder parented them.
	local zoneCenters: { [string]: Vector3? } = {}
	local function zoneCenter(zoneName: string): Vector3?
		if zoneCenters[zoneName] ~= nil then
			return zoneCenters[zoneName]
		end
		local folder = workspace:FindFirstChild(zoneName, true)
		local center: Vector3? = nil
		if folder then
			for _, descendant in ipairs(folder:GetDescendants()) do
				if descendant:IsA("BasePart") then
					center = descendant.Position
					break
				end
			end
		end
		zoneCenters[zoneName] = center
		return center
	end
	local function checkZoneVisits(player: Player)
		local character = player.Character
		if not character then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end
		local pos = root.Position
		local rift = zoneCenter("ForbiddenRift")
		if rift and (pos - rift).Magnitude <= 20 then
			QuestService.RecordEvent(player, "visit_rift", 1)
		end
		local lab = zoneCenter("MutationLab")
		if lab and (pos - lab).Magnitude <= 20 then
			QuestService.RecordEvent(player, "visit_lab", 1)
		end
		-- v1.1 dimensions (fixed coordinates from Dimensions.luau —
		-- Abyssal spawn (-150, 3, 136), Skyfall main island
		-- (150, 46, -140)). Position-based, same pattern as rift/lab.
		if (pos - Vector3.new(-150, 3, 136)).Magnitude <= 20 then
			QuestService.RecordEvent(player, "visit_abyssal", 1)
		end
		if (pos - Vector3.new(150, 46, -140)).Magnitude <= 20 then
			QuestService.RecordEvent(player, "visit_skyfall", 1)
		end
	end

	-- Auto-track poll: earn-coins (from the coin balance delta),
	-- own-distinct and discover-rarity (from data.Unlocked), every 5s.
	-- This is what makes the tutorial / daily / collection quests move
	-- without every other service remembering to call RecordEvent.
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in ipairs(Players:GetPlayers()) do
				pcall(function()
					checkZoneVisits(player)
				end)
				local ok = pcall(function()
					local data = getData(player)
					if not data then
						return
					end
					local coins = tonumber(data.Coins) or 0
					local baseline = _coinBaseline[player]
					if baseline == nil then
						_coinBaseline[player] = coins
					elseif coins > baseline then
						QuestService.RecordEvent(player, "earn_coins", coins - baseline)
						_coinBaseline[player] = coins
					elseif coins < baseline then
						_coinBaseline[player] = coins
					end
					if type(data.Unlocked) == "table" then
						local distinct = #data.Unlocked
						if (_distinctBaseline[player] or 0) < distinct then
							QuestService.RecordEvent(player, "own_distinct", distinct - (_distinctBaseline[player] or 0))
						end
						_distinctBaseline[player] = distinct
						-- Discover Epic+: any unlocked character of Epic
						-- rarity or above completes the discovery quest.
						for _, id in ipairs(data.Unlocked) do
							local def = Characters.GetById(id)
							if def and Characters.GetRarityRank(def.Rarity) >= 4 then
								QuestService.RecordEvent(player, "discover_epic", 1)
								break
							end
						end
					end
				end)
				if not ok then
					-- One player's poll error must never stop the loop.
				end
			end
		end
	end)

	local remoteName = _names.ClaimQuest or _names.CollectIncome
	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(remoteName)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onClaim)
		else
			warn("[QuestService] Remote not found, claim handler not wired: " .. tostring(remoteName))
		end
	end)

	-- RequestQuests (RemoteFunction): the client's pull path.
	-- v1.0.1 integration QA — this handler did not exist, so
	-- InvokeServer on RequestQuests errored and a fresh client only
	-- learned its quests when progress changed. Now returns the same
	-- live list pushProgress sends (QuestService.GetQuests).
	local questFnName = _names.RequestQuests or "RequestQuests"
	task.spawn(function()
		local fn: RemoteFunction? = nil
		for _ = 1, 50 do
			fn = getFunction(questFnName)
			if fn then
				break
			end
			task.wait(0.2)
		end
		if fn then
			fn.OnServerInvoke = function(player: Player)
				return QuestService.GetQuests(player)
			end
		else
			warn("[QuestService] RemoteFunction not found, RequestQuests not wired: " .. tostring(questFnName))
		end
	end)
end

return QuestService
