-- 02_fusion_partials.luau — R4-5 defence in depth.
--
-- (1) Degraded server path: when FusionService has no BaseService
-- link it cannot build a full snapshot, so the result must fall back
-- to the PlayerStats remote — and must NOT appear on BaseUpdate as a
-- bare partial. The fusion itself still succeeds and still charges.
-- (2) Other partial payloads through the shop's OnBaseUpdate must
-- never overwrite canonical state either: a legacy MutationApplied
-- partial, an unknown Action, an empty table, and a non-table.
-- (3) Watchdog scoping: a partial FusionResult clears ONLY the
-- fusion watchdogs (it must not confirm unrelated pending
-- purchases); a full snapshot clears them all (preserved behaviour).
-- (4) The shop's PlayerStats listener routes a FusionResult to
-- OnBaseUpdate (notification only, no state touch) while a Coins
-- payload still updates the coin display (existing behaviour).
--
-- Same Lune limitation as 01: the real ShopController cannot load
-- here, so the client half uses faithful models transcribed from
-- the real source, tied to it by source-shape assertions. The
-- server half runs the real FusionService.
--
-- NOTE: this file deliberately NEVER calls FusionService
-- .SetBaseService. The module is process-fresh (each test file is
-- its own Lune process), so _baseService starts nil and the lazy
-- sibling require cannot resolve under Lune (`script` is nil) —
-- that is exactly the degraded path.
--
-- Run: bash scripts/phase1-tests/fusion-payload/run.sh
-- (from the package root; the fs reads below are cwd-relative).
local fs = require("@lune/fs")
local H = require("../harness")
local Remotes = require("../theft/shared/Remotes")

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function readSrc(rel)
	local ok, text = pcall(fs.readFile, "src/" .. rel)
	if ok and type(text) == "string" then
		return text
	end
	error("cannot read src/" .. rel .. " (run from the package root)")
end

-- ---------------------------------------------------------------------------
-- Faithful models of ShopController.OnBaseUpdate (NEW semantics) and of
-- the PlayerStats listener's FusionResult branch, transcribed from the
-- real source. See 01 for the OLD model and the negative control.
-- ---------------------------------------------------------------------------
local function newShopState()
	return {
		baseState = nil,
		placedList = {},
		unplacedList = {},
		pending = {},
		fuseA = nil,
		fuseB = nil,
		status = "",
		knownCoins = 0,
		rebuilds = 0,
	}
end

local function upgradeLevel(state, kind)
	if type(state.baseState) == "table" then
		local upgrades = state.baseState.Upgrades or state.baseState.upgrades
		if type(upgrades) == "table" and type(upgrades[kind]) == "number" then
			return upgrades[kind]
		end
		if type(state.baseState[kind]) == "number" then
			return state.baseState[kind]
		end
	end
	return 0
end

local function isFullSnapshot(data)
	if type(data) ~= "table" then
		return false
	end
	local placed = data.Placed or data.placed or data.Brainrots
	return type(placed) == "table"
end

local function onBaseUpdateNew(state, data)
	if type(data) ~= "table" then
		return
	end
	if isFullSnapshot(data) then
		state.baseState = data
		state.placedList = data.Placed or data.placed or data.Brainrots
		local unplaced = data.Unplaced or data.unplaced
		if type(unplaced) == "table" then
			state.unplacedList = unplaced
		end
		for key, _ in pairs(state.pending) do
			if string.sub(key, 1, 8) == "upgrade:" or string.sub(key, 1, 8) == "brainrot"
				or string.sub(key, 1, 7) == "mutate:" or string.sub(key, 1, 7) == "fusion:" then
				state.pending[key] = nil
			end
		end
	end
	if data.Action == "FusionResult" then
		for key, _ in pairs(state.pending) do
			if string.sub(key, 1, 7) == "fusion:" then
				state.pending[key] = nil
			end
		end
		state.fuseA = nil
		state.fuseB = nil
		state.status = "Fusion succeeded — " .. tostring(data.CharacterId or "?") .. " joined your inventory!"
	end
	state.rebuilds += 1
end

-- Faithful model of the PlayerStats OnClientEvent handler: a
-- FusionResult payload is routed to OnBaseUpdate; a Coins payload
-- updates the coin display. Anything else is ignored.
local function onPlayerStats(state, payload)
	if type(payload) == "table" and payload.Action == "FusionResult" then
		onBaseUpdateNew(state, payload)
		return
	end
	if type(payload) == "table" and type(payload.Coins) == "number" then
		state.knownCoins = payload.Coins
	end
end

-- ---------------------------------------------------------------------------
-- (1) Degraded server path: real fusion, no BaseService link.
-- ---------------------------------------------------------------------------
local env = H.newEnv()
local baseRemote = Remotes.GetRemote("BaseUpdate")
local statsRemote = Remotes.GetRemote("PlayerStats")
assert(baseRemote ~= nil and statsRemote ~= nil, "mock remotes must resolve")
local baseUpdateFires: { any } = {}
local playerStatsFires: { any } = {}
baseRemote.FireClient = function(_self, player, payload)
	table.insert(baseUpdateFires, { player = player, payload = payload })
end
statsRemote.FireClient = function(_self, player, payload)
	table.insert(playerStatsFires, { player = player, payload = payload })
end

local pair = H.newPair(env, 921, 922)
local fuseAId = pair.prefix .. "fuse_a"
local fuseBId = pair.prefix .. "fuse_b"
local coinsBefore = pair.thiefData.Coins
local crystalsBefore = pair.thiefData.MutationCrystals
local okFuse, output, outcome = env.fusion.FuseBrainrot(pair.thief, fuseAId, fuseBId)
check("D: degraded-path fusion still succeeds without a BaseService link",
	okFuse == true and output ~= nil and output.CharacterId == "bloop_bloomington" and outcome == "Recipe",
	"ok=" .. tostring(okFuse))
check("D: degraded-path fusion still charges 1000 coins + 25 crystals",
	pair.thiefData.Coins == coinsBefore - 1000 and pair.thiefData.MutationCrystals == crystalsBefore - 25)
check("D: degraded-path fusion fires NOTHING on BaseUpdate (no bare partial)",
	#baseUpdateFires == 0, "baseUpdate fires=" .. tostring(#baseUpdateFires))
local statsFusion = 0
local statsPayload: any = nil
for _, fire in ipairs(playerStatsFires) do
	if type(fire.payload) == "table" and fire.payload.Action == "FusionResult" then
		statsFusion += 1
		statsPayload = fire.payload
	end
end
check("D: degraded-path fusion fires exactly one FusionResult on PlayerStats",
	statsFusion == 1, "playerStats FusionResult fires=" .. tostring(statsFusion))
check("D: degraded-path payload is the bare result (no Placed snapshot fields)",
	statsPayload ~= nil and statsPayload.Placed == nil and statsPayload.BankedIncome == nil
		and statsPayload.CharacterId == "bloop_bloomington"
		and statsPayload.InstanceId == output.InstanceId)
check("D: degraded-path payload Consumed lists both inputs",
	statsPayload ~= nil and type(statsPayload.Consumed) == "table" and #statsPayload.Consumed == 2)

-- The degraded payload through the PlayerStats listener model: the
-- result is received, state is untouched.
local shopDegraded = newShopState()
local canonical = {
	Placed = {
		{ InstanceId = "placed-1", CharacterId = "wobble_waffleton", Level = 5 },
		{ InstanceId = "placed-2", CharacterId = "turbo_turnip", Level = 1 },
	},
	Unplaced = {},
	Upgrades = { BaseSlot = 3, IncomeMultiplier = 2, Lock = 1, Turret = 4, ConveyorLuck = 2 },
	BankedIncome = 500,
	Slots = 4,
	IncomePerSec = 12,
}
onBaseUpdateNew(shopDegraded, canonical)
shopDegraded.pending["fusion:" .. fuseAId .. "+" .. fuseBId] = os.clock()
shopDegraded.fuseA = fuseAId
shopDegraded.fuseB = fuseBId
onPlayerStats(shopDegraded, statsPayload)
check("D: PlayerStats FusionResult keeps canonical state (no overwrite)",
	shopDegraded.baseState == canonical and upgradeLevel(shopDegraded, "BaseSlot") == 3
		and #shopDegraded.placedList == 2 and shopDegraded.baseState.BankedIncome == 500)
check("D: PlayerStats FusionResult clears the fuse watchdog and reports the result",
	shopDegraded.pending["fusion:" .. fuseAId .. "+" .. fuseBId] == nil
		and shopDegraded.fuseA == nil
		and string.find(shopDegraded.status, "bloop_bloomington", 1, true) ~= nil)
onPlayerStats(shopDegraded, { Coins = 12345 })
check("D: PlayerStats Coins payload still updates the coin display (existing behaviour)",
	shopDegraded.knownCoins == 12345 and shopDegraded.baseState == canonical)

-- ---------------------------------------------------------------------------
-- (2) Other partial payloads never overwrite canonical state.
-- ---------------------------------------------------------------------------
local shopOther = newShopState()
onBaseUpdateNew(shopOther, canonical)
shopOther.pending["upgrade:BaseSlot"] = os.clock()
shopOther.pending["brainrot:placed-1"] = os.clock()
shopOther.pending["mutate:placed-1"] = os.clock()
shopOther.pending["fusion:x+y"] = os.clock()

local legacyMutationPartial = {
	Action = "MutationApplied",
	InstanceId = "placed-1",
	CharacterId = "wobble_waffleton",
	MutationId = "electric",
	MutationName = "Electric",
	MutationCrystals = 60,
}
onBaseUpdateNew(shopOther, legacyMutationPartial)
check("P: legacy MutationApplied partial keeps canonical state",
	shopOther.baseState == canonical and upgradeLevel(shopOther, "BaseSlot") == 3
		and #shopOther.placedList == 2)
onBaseUpdateNew(shopOther, { Action = "MysteryEvent", Coins = 5 })
check("P: unknown-Action partial keeps canonical state",
	shopOther.baseState == canonical and upgradeLevel(shopOther, "IncomeMultiplier") == 2)
onBaseUpdateNew(shopOther, {})
check("P: empty-table payload keeps canonical state",
	shopOther.baseState == canonical and #shopOther.placedList == 2)
onBaseUpdateNew(shopOther, "not a table")
check("P: non-table payload keeps canonical state (and does not error)",
	shopOther.baseState == canonical and #shopOther.placedList == 2)
onBaseUpdateNew(shopOther, nil)
check("P: nil payload keeps canonical state (and does not error)",
	shopOther.baseState == canonical)

-- ---------------------------------------------------------------------------
-- (3) Watchdog scoping.
-- ---------------------------------------------------------------------------
check("W: no partial above cleared any unrelated watchdog",
	shopOther.pending["upgrade:BaseSlot"] ~= nil
		and shopOther.pending["brainrot:placed-1"] ~= nil
		and shopOther.pending["mutate:placed-1"] ~= nil
		and shopOther.pending["fusion:x+y"] ~= nil)
local fusionPartial = {
	Action = "FusionResult",
	CharacterId = "bloop_bloomington",
	InstanceId = "out-1",
	Consumed = { "a", "b" },
	Cost = { Coins = 1000, MutationCrystals = 25 },
}
onBaseUpdateNew(shopOther, fusionPartial)
check("W: partial FusionResult clears ONLY the fusion watchdog",
	shopOther.pending["fusion:x+y"] == nil
		and shopOther.pending["upgrade:BaseSlot"] ~= nil
		and shopOther.pending["brainrot:placed-1"] ~= nil
		and shopOther.pending["mutate:placed-1"] ~= nil)
check("W: partial FusionResult still reports the result",
	string.find(shopOther.status, "bloop_bloomington", 1, true) ~= nil)
local fullSnap = {
	Placed = { { InstanceId = "placed-1", CharacterId = "wobble_waffleton", Level = 5 } },
	Unplaced = {},
	Upgrades = { BaseSlot = 4, IncomeMultiplier = 2, Lock = 1, Turret = 4, ConveyorLuck = 2 },
	BankedIncome = 700,
	Slots = 5,
	IncomePerSec = 20,
}
onBaseUpdateNew(shopOther, fullSnap)
check("W: a full snapshot clears ALL pending watchdogs (preserved behaviour)",
	shopOther.pending["upgrade:BaseSlot"] == nil
		and shopOther.pending["brainrot:placed-1"] == nil
		and shopOther.pending["mutate:placed-1"] == nil)
check("W: a full snapshot updates state normally (BaseSlot 3 -> 4, banked 500 -> 700)",
	shopOther.baseState == fullSnap and upgradeLevel(shopOther, "BaseSlot") == 4
		and shopOther.baseState.BankedIncome == 700)

-- ---------------------------------------------------------------------------
-- Source-shape assertions: tie the models to the real sources.
-- ---------------------------------------------------------------------------
local fusSrc = readSrc("server/Services/FusionService.luau")
check("SRC: FusionService snapshot path is guarded by the BaseUpdate remote existing",
	string.find(fusSrc, "if snapshot ~= nil and getRemote(_names.BaseUpdate) then", 1, true) ~= nil)
local shopSrc = readSrc("client/Controllers/ShopController.luau")
check("SRC: ShopController assigns baseState only inside the snapshot branch",
	string.find(shopSrc, "if isFullSnapshot(data) then", 1, true) ~= nil)
check("SRC: ShopController PlayerStats listener branches on FusionResult first",
	string.find(shopSrc, "if typeof(payload) == \"table\" and payload.Action == \"FusionResult\" then", 1, true) ~= nil)

H.finish()
