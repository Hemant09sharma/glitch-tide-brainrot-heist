-- 01_fusion_payload.luau — R4-5: no FusionResult payload may ever
-- overwrite the shop's full base state.
--
-- Before the fix, FusionService.FuseBrainrot fired a bare partial
-- payload {Action = "FusionResult", Outcome, RecipeHint, InstanceId,
-- CharacterId, Level, MutationId, Consumed, Cost} through the
-- BaseUpdate remote, and ShopController.OnBaseUpdate assigned
-- baseState = data unconditionally — so the partial overwrote the
-- shop's full snapshot: upgrade levels read 0 (no Upgrades table in
-- the partial) and the placed list vanished until the next full
-- snapshot. BaseController already guarded its own state (R3-7) but
-- forwarded the partial to the shop, which had no guard.
--
-- The fix (R4-5): the result rides ON a full BaseService.GetBase
-- snapshot fired through BaseUpdate (same pattern as R3-7's
-- MutationApplied fix), so every BaseUpdate fire is a valid
-- snapshot; ShopController.OnBaseUpdate additionally accepts state
-- only from full snapshots (Placed table present) and handles a
-- partial as a notification only — the fuse watchdog still clears
-- and the result is still reported. If no snapshot can be built,
-- the server falls back to the PlayerStats remote (02 covers that
-- degraded path); a bare partial never goes through BaseUpdate.
--
-- LIMITATION (stated honestly): ShopController and BaseController
-- cannot be loaded under Lune — their top levels require
-- (script.Parent...) and `script` is nil here — so the client half
-- is tested with faithful models of ShopController.OnBaseUpdate +
-- upgradeLevel (old semantics vs new guarded semantics),
-- transcribed from the real source, PLUS source-shape assertions
-- that the real ShopController.luau contains the guard and the real
-- FusionService.luau builds the snapshot. The server half (payloads
-- actually fired by the real FusionService + real BaseService) runs
-- against the real modules.
--
-- NOTE on upgrade levels: BaseService.GetBase carries the flat level
-- fields (IncomeMultiplierLevel, LockLevel, ...) and no Upgrades
-- table; ShopController.upgradeLevel reads baseState.Upgrades[kind]
-- (or a bare baseState[kind]). The canonical shop state below is a
-- real GetBase snapshot PLUS the Upgrades table upgradeLevel reads
-- — i.e. the shop's state as the finding's premise has it (nonzero
-- upgrade levels before the partial, zero after). The corruption
-- assertion is about the partial replacing that canonical state,
-- whatever fields it carries.
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
-- Faithful models of ShopController.OnBaseUpdate + upgradeLevel,
-- transcribed from the real source. OLD = pre-R4-5 (baseState = data
-- unconditionally; any BaseUpdate clears every pending watchdog).
-- NEW = post-R4-5 (only full snapshots replace state; a partial is a
-- notification only and clears just the fusion watchdogs).
-- ---------------------------------------------------------------------------
local UPGRADE_KINDS = { "BaseSlot", "IncomeMultiplier", "Lock", "Turret", "ConveyorLuck" }

local function newShopState()
	return {
		baseState = nil,
		placedList = {},
		unplacedList = {},
		pending = {},
		fuseA = nil,
		fuseB = nil,
		status = "",
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

local function clearAllPending(state)
	for key, _ in pairs(state.pending) do
		if string.sub(key, 1, 8) == "upgrade:" or string.sub(key, 1, 8) == "brainrot"
			or string.sub(key, 1, 7) == "mutate:" or string.sub(key, 1, 7) == "fusion:" then
			state.pending[key] = nil
		end
	end
end

local function onBaseUpdateOld(state, data)
	if type(data) == "table" then
		state.baseState = data
		local placed = data.Placed or data.placed or data.Brainrots
		if type(placed) == "table" then
			state.placedList = placed
		end
		local unplaced = data.Unplaced or data.unplaced
		if type(unplaced) == "table" then
			state.unplacedList = unplaced
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
	end
	clearAllPending(state)
	state.rebuilds += 1
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
		clearAllPending(state)
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

local function isServerFullSnapshot(payload)
	return type(payload) == "table"
		and type(payload.Placed) == "table"
		and type(payload.BankedIncome) == "number"
		and type(payload.Slots) == "number"
		and type(payload.IncomePerSec) == "number"
end

local function findUnplacedIn(payload, instanceId)
	if type(payload) ~= "table" or type(payload.Unplaced) ~= "table" then
		return nil
	end
	for _, inst in ipairs(payload.Unplaced) do
		if type(inst) == "table" and inst.InstanceId == instanceId then
			return inst
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Env: real FusionService + real BaseService, production wiring.
-- ---------------------------------------------------------------------------
local env = H.newEnv()
local base = H.newBaseEnv(env)
env.mutation.SetBaseService(base)
base.SetMutationService(env.mutation)
env.fusion.SetBaseService(base)

-- Intercept every BaseUpdate / PlayerStats fire so the test sees the
-- exact payloads FuseBrainrot produces (mock remotes are no-ops
-- unless intercepted; all Remotes copies resolve to the same mock
-- remote instance through the harness ReplicatedStorage folder).
local baseUpdateFires: { any } = {}
local playerStatsFires: { any } = {}
local baseRemote = Remotes.GetRemote("BaseUpdate")
local statsRemote = Remotes.GetRemote("PlayerStats")
assert(baseRemote ~= nil and statsRemote ~= nil, "mock remotes must resolve")
baseRemote.FireClient = function(_self, player, payload)
	table.insert(baseUpdateFires, { player = player, payload = payload })
end
statsRemote.FireClient = function(_self, player, payload)
	table.insert(playerStatsFires, { player = player, payload = payload })
end

-- ---------------------------------------------------------------------------
-- Server half: a real fusion (wobble + turbo -> bloop_bloomington).
-- ---------------------------------------------------------------------------
local pair = H.newPair(env, 911, 912)
pair.thiefData.BankedIncome = 500
pair.victimData.BankedIncome = 500
base.AssignBase(pair.thief)
base.AssignBase(pair.victim)

local fuseAId = pair.prefix .. "fuse_a"
local fuseBId = pair.prefix .. "fuse_b"

local firesBefore = #baseUpdateFires
local statsBefore = #playerStatsFires
local coinsBefore = pair.thiefData.Coins
local crystalsBefore = pair.thiefData.MutationCrystals
local okFuse, output, outcome = env.fusion.FuseBrainrot(pair.thief, fuseAId, fuseBId)
check("S: real fusion of unplaced wobble + turbo succeeds",
	okFuse == true and output ~= nil and output.CharacterId == "bloop_bloomington" and outcome == "Recipe",
	"ok=" .. tostring(okFuse) .. " out=" .. tostring(output and output.CharacterId))
check("S: fusion consumes both inputs",
	H.countOwned(env, { pair.thief }, fuseAId) == 0 and H.countOwned(env, { pair.thief }, fuseBId) == 0)
check("S: fusion charges 1000 coins + 25 crystals",
	pair.thiefData.Coins == coinsBefore - 1000 and pair.thiefData.MutationCrystals == crystalsBefore - 25,
	"coins=" .. tostring(pair.thiefData.Coins) .. " crystals=" .. tostring(pair.thiefData.MutationCrystals))

local newFires: { any } = {}
for i = firesBefore + 1, #baseUpdateFires do
	table.insert(newFires, baseUpdateFires[i])
end
check("S: fusion produced at least one BaseUpdate fire",
	#newFires >= 1, "fires=" .. tostring(#newFires))
local allSnapshots = true
local fusionResultCount = 0
for _, fire in ipairs(newFires) do
	if not isServerFullSnapshot(fire.payload) then
		allSnapshots = false
	end
	if type(fire.payload) == "table" and fire.payload.Action == "FusionResult" then
		fusionResultCount += 1
	end
end
check("S: EVERY BaseUpdate fire from the fusion is a full snapshot (Placed + BankedIncome + Slots + IncomePerSec)",
	allSnapshots)
check("S: at least one fire carries Action = FusionResult",
	fusionResultCount >= 1, "fusionResult fires=" .. tostring(fusionResultCount))
local statsPartial = 0
for i = statsBefore + 1, #playerStatsFires do
	if type(playerStatsFires[i].payload) == "table" and playerStatsFires[i].payload.Action == "FusionResult" then
		statsPartial += 1
	end
end
check("S: no FusionResult leaked onto PlayerStats (snapshot path was available)",
	statsPartial == 0, "leaks=" .. tostring(statsPartial))

local last = newFires[#newFires].payload
check("S: last fire is the fusion snapshot (Action FusionResult + full snapshot fields)",
	last.Action == "FusionResult" and isServerFullSnapshot(last))
check("S: fusion snapshot carries the output instance id",
	last.InstanceId == output.InstanceId, "instance=" .. tostring(last.InstanceId))
check("S: fusion snapshot CharacterId is the recipe result",
	last.CharacterId == "bloop_bloomington")
check("S: fusion snapshot Consumed lists both inputs",
	type(last.Consumed) == "table" and #last.Consumed == 2
		and ((last.Consumed[1] == fuseAId and last.Consumed[2] == fuseBId)
			or (last.Consumed[1] == fuseBId and last.Consumed[2] == fuseAId)))
check("S: fusion snapshot Cost is 1000 coins + 25 crystals",
	type(last.Cost) == "table" and last.Cost.Coins == 1000 and last.Cost.MutationCrystals == 25)
check("S: fusion snapshot BankedIncome is the thief's 500",
	last.BankedIncome == 500, "banked=" .. tostring(last.BankedIncome))
check("S: fusion snapshot Unplaced lists the new output instance",
	findUnplacedIn(last, output.InstanceId) ~= nil
		and findUnplacedIn(last, output.InstanceId).CharacterId == "bloop_bloomington")
check("S: fusion snapshot Unplaced no longer lists the consumed inputs",
	findUnplacedIn(last, fuseAId) == nil and findUnplacedIn(last, fuseBId) == nil)

-- ---------------------------------------------------------------------------
-- Client half: canonical full snapshot, then the OLD bare partial.
-- ---------------------------------------------------------------------------
-- Canonical shop state: a REAL GetBase snapshot (victim: 2 placed,
-- BankedIncome 500) plus the Upgrades table upgradeLevel reads.
local canonical = base.GetBase(pair.victim)
canonical.Upgrades = { BaseSlot = 3, IncomeMultiplier = 2, Lock = 1, Turret = 4, ConveyorLuck = 2 }
check("SETUP: canonical snapshot has 2 placed and BankedIncome 500",
	type(canonical.Placed) == "table" and #canonical.Placed == 2 and canonical.BankedIncome == 500)

-- The exact bare partial the pre-fix server sent.
local oldPartial = {
	Action = "FusionResult",
	Outcome = "Recipe",
	RecipeHint = "test hint",
	InstanceId = output.InstanceId,
	CharacterId = "bloop_bloomington",
	Level = 1,
	MutationId = nil,
	Consumed = { fuseAId, fuseBId },
	Cost = { Coins = 1000, MutationCrystals = 25 },
}

local function armPending(state)
	state.pending["fusion:" .. fuseAId .. "+" .. fuseBId] = os.clock()
	state.pending["upgrade:BaseSlot"] = os.clock()
	state.fuseA = fuseAId
	state.fuseB = fuseBId
end

-- NEW model: partial must not touch state, but must clear the fuse
-- watchdog and report the result.
local shopNew = newShopState()
onBaseUpdateNew(shopNew, canonical)
check("C: NEW model keeps upgrade levels after the canonical snapshot",
	upgradeLevel(shopNew, "BaseSlot") == 3 and upgradeLevel(shopNew, "IncomeMultiplier") == 2
		and upgradeLevel(shopNew, "Lock") == 1 and upgradeLevel(shopNew, "Turret") == 4
		and upgradeLevel(shopNew, "ConveyorLuck") == 2)
check("C: NEW model keeps 2 placed + banked 500 after the canonical snapshot",
	#shopNew.placedList == 2 and shopNew.baseState.BankedIncome == 500)
armPending(shopNew)
onBaseUpdateNew(shopNew, oldPartial)
check("C: NEW model keeps baseState as the canonical snapshot through the partial",
	shopNew.baseState == canonical)
check("C: NEW model keeps ALL upgrade levels through the partial",
	upgradeLevel(shopNew, "BaseSlot") == 3 and upgradeLevel(shopNew, "IncomeMultiplier") == 2
		and upgradeLevel(shopNew, "Lock") == 1 and upgradeLevel(shopNew, "Turret") == 4
		and upgradeLevel(shopNew, "ConveyorLuck") == 2)
check("C: NEW model keeps the placed list (2) through the partial",
	#shopNew.placedList == 2, "placed=" .. tostring(#shopNew.placedList))
check("C: NEW model keeps banked income 500 through the partial",
	shopNew.baseState.BankedIncome == 500)
check("C: NEW model still receives the fusion result (watchdog cleared, status set)",
	shopNew.pending["fusion:" .. fuseAId .. "+" .. fuseBId] == nil
		and shopNew.fuseA == nil and shopNew.fuseB == nil
		and string.find(shopNew.status, "bloop_bloomington", 1, true) ~= nil,
	"status=" .. shopNew.status)
check("C: NEW model does NOT clear the unrelated upgrade watchdog on the partial",
	shopNew.pending["upgrade:BaseSlot"] ~= nil)

-- Next full snapshot updates the state normally.
pair.victimData.BankedIncome = 650
local canonical2 = base.GetBase(pair.victim)
canonical2.Upgrades = { BaseSlot = 4, IncomeMultiplier = 2, Lock = 1, Turret = 4, ConveyorLuck = 2 }
onBaseUpdateNew(shopNew, canonical2)
check("C: NEW model applies the next full snapshot (BaseSlot 3 -> 4, banked 500 -> 650)",
	shopNew.baseState == canonical2 and upgradeLevel(shopNew, "BaseSlot") == 4
		and shopNew.baseState.BankedIncome == 650)
check("C: NEW model clears the pending upgrade watchdog on the full snapshot",
	shopNew.pending["upgrade:BaseSlot"] == nil)

-- The REAL server payload (full snapshot + FusionResult fields)
-- through the NEW model: state becomes the snapshot AND the fusion
-- result is received.
local shopReal = newShopState()
onBaseUpdateNew(shopReal, canonical)
armPending(shopReal)
onBaseUpdateNew(shopReal, last)
check("C: NEW model accepts the real fusion snapshot as state (Action FusionResult on a full snapshot)",
	shopReal.baseState == last and shopReal.baseState.Action == "FusionResult")
check("C: NEW model shows the fusion output id from the real snapshot",
	shopReal.baseState.InstanceId == output.InstanceId)
check("C: NEW model clears the fuse watchdog on the real fusion snapshot",
	shopReal.pending["fusion:" .. fuseAId .. "+" .. fuseBId] == nil
		and string.find(shopReal.status, "bloop_bloomington", 1, true) ~= nil)
check("C: NEW model keeps the snapshot's BankedIncome 500 from the real fusion fire",
	shopReal.baseState.BankedIncome == 500)

-- ---------------------------------------------------------------------------
-- Negative control: the OLD partial through the OLD client model.
-- ---------------------------------------------------------------------------
local shopOld = newShopState()
onBaseUpdateOld(shopOld, canonical)
armPending(shopOld)
onBaseUpdateOld(shopOld, oldPartial)
check("NEGATIVE CONTROL: OLD model zeroes every upgrade level on the partial",
	upgradeLevel(shopOld, "BaseSlot") == 0 and upgradeLevel(shopOld, "IncomeMultiplier") == 0
		and upgradeLevel(shopOld, "Lock") == 0 and upgradeLevel(shopOld, "Turret") == 0
		and upgradeLevel(shopOld, "ConveyorLuck") == 0)
check("NEGATIVE CONTROL: OLD model loses the Placed list from baseState on the partial",
	shopOld.baseState ~= nil and shopOld.baseState.Placed == nil)
check("NEGATIVE CONTROL: OLD model loses banked income on the partial",
	shopOld.baseState.BankedIncome == nil)
check("NEGATIVE CONTROL: OLD model wrongly clears the unrelated upgrade watchdog on the partial",
	shopOld.pending["upgrade:BaseSlot"] == nil)

-- ---------------------------------------------------------------------------
-- Source-shape assertions: tie the models to the real sources.
-- ---------------------------------------------------------------------------
local fusSrc = readSrc("server/Services/FusionService.luau")
check("SRC: FusionService builds the result on a full snapshot (GetBase)",
	string.find(fusSrc, "GetBase(player)", 1, true) ~= nil)
check("SRC: FusionService exposes SetBaseService (GameManager tryWires it)",
	string.find(fusSrc, "function FusionService.SetBaseService", 1, true) ~= nil)
check("SRC: FusionService no longer fires the bare partial on BaseUpdate",
	string.find(fusSrc, "fireClient(_names.BaseUpdate, player, payload)", 1, true) == nil)
check("SRC: FusionService fires the snapshot through BaseUpdate",
	string.find(fusSrc, "fireClient(_names.BaseUpdate, player, snapshot)", 1, true) ~= nil)
check("SRC: FusionService falls back to PlayerStats with the result fields",
	string.find(fusSrc, "fireClient(_names.PlayerStats, player, resultFields)", 1, true) ~= nil)
local shopSrc = readSrc("client/Controllers/ShopController.luau")
check("SRC: ShopController defines the full-snapshot guard",
	string.find(shopSrc, "local function isFullSnapshot", 1, true) ~= nil)
check("SRC: ShopController.OnBaseUpdate only assigns state inside the snapshot branch",
	string.find(shopSrc, "if isFullSnapshot(data) then", 1, true) ~= nil)
check("SRC: ShopController still handles FusionResult (watchdog + status)",
	string.find(shopSrc, "if data.Action == \"FusionResult\" then", 1, true) ~= nil)
check("SRC: ShopController routes a PlayerStats FusionResult through OnBaseUpdate",
	string.find(shopSrc, "payload.Action == \"FusionResult\"", 1, true) ~= nil)
local ctrlSrc = readSrc("client/Controllers/BaseController.luau")
check("SRC: BaseController still forwards payloads to the shop",
	string.find(ctrlSrc, "notifyShop(data)", 1, true) ~= nil)

H.finish()
