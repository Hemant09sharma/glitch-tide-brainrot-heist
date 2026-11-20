-- 01_mutation_payload.luau — R3-7: no partial MutationApplied payload
-- may ever overwrite the client's full base snapshot.
--
-- Before the fix, MutationService.MutateBrainrot rebuilt the base
-- (full BaseUpdate snapshot) and THEN fired a partial payload
-- {Action = "MutationApplied", InstanceId, CharacterId, MutationId,
-- MutationName, MutationCrystals} through the same BaseUpdate remote.
-- BaseController.ApplyBaseUpdate assigns baseState = data
-- unconditionally, so the partial overwrote the full snapshot:
-- banked income read 0 and slots read "N / 0" until the next full
-- update. No client code ever branched on MutationApplied.
--
-- The fix (option a): the partial send is deleted; the client learns
-- the mutation from RebuildBase's full snapshot (fired for placed AND
-- unplaced mutations). BaseController.ApplyBaseUpdate additionally
-- ignores non-snapshot payloads for state purposes (defence in depth
-- against FusionService's FusionResult partial, which still flows
-- through BaseUpdate) while still forwarding them to the shop.
--
-- LIMITATION (stated honestly): BaseController cannot be loaded under
-- Lune — its top level does require(script.Parent.RarityColors) and
-- `script` is nil here — so the client half is tested with a faithful
-- model of ApplyBaseUpdate (old semantics vs new guarded semantics),
-- transcribed from the real source, PLUS source-shape assertions that
-- the real BaseController.luau contains the guard and the real
-- MutationService.luau no longer sends the partial. The server half
-- (payloads actually fired by the real MutationService + real
-- BaseService) runs against the real modules.
--
-- Run: bash scripts/phase1-tests/mutation-payload/run.sh
-- (from the package root; the fs reads below are cwd-relative).
local fs = require("@lune/fs")
local H = require("../harness")
local Economy = require("../theft/shared/Economy")
local Characters = require("../theft/shared/Characters")
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
-- Faithful models of BaseController.ApplyBaseUpdate, transcribed from the
-- real source. OLD = pre-R3-7 (baseState = data unconditionally).
-- NEW = post-R3-7 (non-snapshot payloads are forwarded to the shop only
-- and never touch state). Label math is the real function's math.
-- ---------------------------------------------------------------------------
local function incomeOf(placed)
	if type(placed.IncomePerSec) == "number" then
		return placed.IncomePerSec
	end
	if type(placed.incomePerSec) == "number" then
		return placed.incomePerSec
	end
	if Characters and Characters.GetById and type(placed.CharacterId) == "string" then
		local def = Characters.GetById(placed.CharacterId)
		if def then
			return def.IncomePerSec or 0
		end
	end
	return 0
end

local function newClientState()
	return {
		baseState = nil,
		placedList = {},
		income = 0,
		banked = 0,
		slotsUsed = 0,
		slotsTotal = 0,
		forwardedToShop = 0,
	}
end

local function applyLabels(state, data)
	local income = data.IncomePerSec or data.incomePerSec
	if type(income) ~= "number" then
		local total = 0
		for _, p in ipairs(state.placedList) do
			total += incomeOf(p)
		end
		income = total
	end
	state.income = income
	state.banked = data.Banked or data.BankedIncome or data.bankedIncome or data.BankedCoins or 0
	state.slotsUsed = data.SlotsUsed or data.slotsUsed or #state.placedList
	state.slotsTotal = data.SlotsTotal or data.Slots or data.slotsTotal or data.MaxSlots or 0
end

local function applyBaseUpdateOld(state, data)
	if type(data) ~= "table" then
		return state
	end
	state.baseState = data
	local placed = data.Placed or data.placed or data.Brainrots
	if type(placed) == "table" then
		state.placedList = placed
	end
	applyLabels(state, data)
	return state
end

local function applyBaseUpdateNew(state, data)
	if type(data) ~= "table" then
		return state
	end
	local placed = data.Placed or data.placed or data.Brainrots
	if type(placed) ~= "table" then
		-- Partial event payload: forwarded to the shop only.
		state.forwardedToShop += 1
		return state
	end
	state.baseState = data
	state.placedList = placed
	applyLabels(state, data)
	return state
end

local function isFullSnapshot(payload)
	return type(payload) == "table"
		and type(payload.Placed) == "table"
		and type(payload.BankedIncome) == "number"
		and type(payload.Slots) == "number"
		and type(payload.IncomePerSec) == "number"
end

local function findPlacedIn(payload, instanceId)
	if type(payload) ~= "table" or type(payload.Placed) ~= "table" then
		return nil
	end
	for _, placed in ipairs(payload.Placed) do
		if type(placed) == "table" and placed.InstanceId == instanceId then
			return placed
		end
	end
	return nil
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
-- Env: real MutationService + real BaseService, production wiring.
-- ---------------------------------------------------------------------------
local env = H.newEnv()
local base = H.newBaseEnv(env)
env.mutation.SetBaseService(base)
base.SetMutationService(env.mutation)

-- Intercept every BaseUpdate / PlayerStats fire so the test sees the
-- exact payloads MutateBrainrot produces (mock remotes are no-ops
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
-- Pair A: mutate a PLACED Brainrot (golden wobble L5, glitched).
-- ---------------------------------------------------------------------------
local pairA = H.newPair(env, 911, 912)
pairA.victimData.BankedIncome = 500
base.AssignBase(pairA.thief)
base.AssignBase(pairA.victim)

local firesBeforeA = #baseUpdateFires
local okMutA, mutErrA = env.mutation.MutateBrainrot(pairA.victim, pairA.targetId, "electric")
check("A: mutate placed golden wobble to electric succeeds",
	okMutA == true, "err=" .. tostring(mutErrA))
check("A: Mutation Crystals deducted exactly once (100 -> 60)",
	pairA.victimData.MutationCrystals == 60,
	"crystals=" .. tostring(pairA.victimData.MutationCrystals))
check("A: owned record is electric",
	H.findOwned(pairA.victimData, pairA.targetId).Mutation == "electric")
check("A: placed copy synced to electric at once",
	H.findPlaced(pairA.victimData, pairA.targetId).Mutation == "electric")

local newFiresA: { any } = {}
for i = firesBeforeA + 1, #baseUpdateFires do
	table.insert(newFiresA, baseUpdateFires[i])
end
check("A: mutation produced at least one BaseUpdate fire",
	#newFiresA >= 1, "fires=" .. tostring(#newFiresA))
local partialCountA = 0
local allSnapshotsA = true
for _, fire in ipairs(newFiresA) do
	if type(fire.payload) == "table" and fire.payload.Action == "MutationApplied" then
		partialCountA += 1
	end
	if not isFullSnapshot(fire.payload) then
		allSnapshotsA = false
	end
end
check("A: NO BaseUpdate fire carries Action = MutationApplied",
	partialCountA == 0, "partial fires=" .. tostring(partialCountA))
check("A: EVERY BaseUpdate fire is a full snapshot (Placed + BankedIncome + Slots + IncomePerSec)",
	allSnapshotsA)
local statsPartialA = 0
for _, fire in ipairs(playerStatsFires) do
	if type(fire.payload) == "table" and fire.payload.Action == "MutationApplied" then
		statsPartialA += 1
	end
end
check("A: no MutationApplied payload leaked onto PlayerStats either",
	statsPartialA == 0, "leaks=" .. tostring(statsPartialA))

local lastA = newFiresA[#newFiresA].payload
check("A: last snapshot shows the placed target as electric",
	findPlacedIn(lastA, pairA.targetId) ~= nil
		and findPlacedIn(lastA, pairA.targetId).Mutation == "electric")
check("A: last snapshot carries BankedIncome 500",
	lastA.BankedIncome == 500, "banked=" .. tostring(lastA.BankedIncome))
local expectedIncomeA = base.GetIncomePerSec(pairA.victim)
check("A: last snapshot IncomePerSec matches the server total",
	lastA.IncomePerSec == expectedIncomeA,
	"snapshot=" .. tostring(lastA.IncomePerSec) .. " server=" .. tostring(expectedIncomeA))
local targetIncomeA = Economy.IncomePerSecond({
	CharacterId = "wobble_waffleton",
	Level = 5,
	Glitched = true,
	Mutation = "electric",
})
check("A: target income is electric (40/s, not golden 50/s)",
	targetIncomeA == 40, "income=" .. tostring(targetIncomeA))

-- Feed the last full snapshot through the NEW guarded client model:
-- placed list, banked income, slot counts, income and mutation display
-- must all survive intact.
local stateA = newClientState()
applyBaseUpdateNew(stateA, lastA)
check("A: client keeps both placed Brainrots after the snapshot",
	#stateA.placedList == 2, "placed=" .. tostring(#stateA.placedList))
check("A: client keeps banked income 500 after the snapshot",
	stateA.banked == 500, "banked=" .. tostring(stateA.banked))
check("A: client keeps slot counts (2 used / snapshot total)",
	stateA.slotsUsed == 2 and stateA.slotsTotal == lastA.Slots,
	"used=" .. tostring(stateA.slotsUsed) .. " total=" .. tostring(stateA.slotsTotal))
check("A: client keeps income per second from the snapshot",
	stateA.income == lastA.IncomePerSec, "income=" .. tostring(stateA.income))
local clientTargetA = nil
for _, placed in ipairs(stateA.placedList) do
	if type(placed) == "table" and placed.InstanceId == pairA.targetId then
		clientTargetA = placed
	end
end
check("A: client mutation display shows electric",
	clientTargetA ~= nil and clientTargetA.Mutation == "electric")

-- ---------------------------------------------------------------------------
-- Negative control: the OLD partial payload through the OLD client model.
-- The old payload shape is the exact table the pre-fix code sent.
-- ---------------------------------------------------------------------------
local oldPartial = {
	Action = "MutationApplied",
	InstanceId = pairA.targetId,
	CharacterId = "wobble_waffleton",
	MutationId = "electric",
	MutationName = "Electric",
	MutationCrystals = 60,
}
local stateOld = newClientState()
applyBaseUpdateNew(stateOld, lastA) -- start from the good snapshot
applyBaseUpdateOld(stateOld, oldPartial)
check("NEGATIVE CONTROL: OLD client model zeroes banked income on the partial",
	stateOld.banked == 0, "banked=" .. tostring(stateOld.banked))
check("NEGATIVE CONTROL: OLD client model zeroes slots total on the partial",
	stateOld.slotsTotal == 0, "slotsTotal=" .. tostring(stateOld.slotsTotal))
check("NEGATIVE CONTROL: OLD client model loses the Placed list from baseState",
	stateOld.baseState ~= nil and stateOld.baseState.Placed == nil)

-- Same partial through the NEW guarded model: state must be untouched.
local stateNew = newClientState()
applyBaseUpdateNew(stateNew, lastA)
applyBaseUpdateNew(stateNew, oldPartial)
check("GUARD: NEW client model keeps banked income 500 through the partial",
	stateNew.banked == 500, "banked=" .. tostring(stateNew.banked))
check("GUARD: NEW client model keeps slots total through the partial",
	stateNew.slotsTotal == lastA.Slots, "slotsTotal=" .. tostring(stateNew.slotsTotal))
check("GUARD: NEW client model keeps the placed list through the partial",
	#stateNew.placedList == 2, "placed=" .. tostring(#stateNew.placedList))
check("GUARD: NEW client model keeps baseState as the full snapshot",
	stateNew.baseState ~= nil and stateNew.baseState.Placed ~= nil)
check("GUARD: NEW client model forwarded the partial to the shop (FusionResult still works)",
	stateNew.forwardedToShop == 1, "forwarded=" .. tostring(stateNew.forwardedToShop))

-- ---------------------------------------------------------------------------
-- Pair B: mutate an UNPLACED Brainrot — the full snapshot's Unplaced
-- list is the only place the client learns it (the old partial never
-- carried Unplaced data, so nothing is lost by deleting it).
-- ---------------------------------------------------------------------------
local pairB = H.newPair(env, 913, 914)
pairB.victimData.MutationCrystals = 1000
base.AssignBase(pairB.thief)
base.AssignBase(pairB.victim)
-- Unplace the target: remove its placed copy, keep the owned record.
local placedB = pairB.victimData.Base.Placed
for i = #placedB, 1, -1 do
	if type(placedB[i]) == "table" and placedB[i].InstanceId == pairB.targetId then
		table.remove(placedB, i)
	end
end
local ownedB = H.findOwned(pairB.victimData, pairB.targetId)
ownedB.Placed = false
ownedB.Slot = 0
local firesBeforeB = #baseUpdateFires
local okMutB, mutErrB = env.mutation.MutateBrainrot(pairB.victim, pairB.targetId, "frozen")
check("B: mutate unplaced golden wobble to frozen succeeds",
	okMutB == true, "err=" .. tostring(mutErrB))
local newFiresB: { any } = {}
for i = firesBeforeB + 1, #baseUpdateFires do
	table.insert(newFiresB, baseUpdateFires[i])
end
check("B: unplaced mutation still produces a BaseUpdate fire (rebuild is unconditional)",
	#newFiresB >= 1, "fires=" .. tostring(#newFiresB))
local allSnapshotsB = true
local partialCountB = 0
for _, fire in ipairs(newFiresB) do
	if not isFullSnapshot(fire.payload) then
		allSnapshotsB = false
	end
	if type(fire.payload) == "table" and fire.payload.Action == "MutationApplied" then
		partialCountB += 1
	end
end
check("B: every fire is a full snapshot, none is MutationApplied",
	allSnapshotsB and partialCountB == 0)
local lastB = #newFiresB > 0 and newFiresB[#newFiresB].payload or nil
check("B: last snapshot Unplaced list shows the target as frozen",
	lastB ~= nil and findUnplacedIn(lastB, pairB.targetId) ~= nil
		and findUnplacedIn(lastB, pairB.targetId).Mutation == "frozen")

-- ---------------------------------------------------------------------------
-- Source-shape assertions: tie the models to the real sources.
-- ---------------------------------------------------------------------------
local mutSrc = readSrc("server/Services/MutationService.luau")
check("SRC: MutationService no longer fires any payload (no fireClient call remains)",
	string.find(mutSrc, "fireClient(", 1, true) == nil)
check("SRC: MutationService no longer builds the MutationApplied payload",
	string.find(mutSrc, "MutationName", 1, true) == nil)
check("SRC: MutationService still rebuilds the base after mutating",
	string.find(mutSrc, "RebuildBase(player)", 1, true) ~= nil)
local ctrlSrc = readSrc("client/Controllers/BaseController.luau")
check("SRC: BaseController guards non-snapshot payloads before assigning state",
	string.find(ctrlSrc, "if typeof(placed) ~= \"table\" then", 1, true) ~= nil)
check("SRC: BaseController still forwards payloads to the shop",
	string.find(ctrlSrc, "notifyShop(data)", 1, true) ~= nil)

H.finish()
