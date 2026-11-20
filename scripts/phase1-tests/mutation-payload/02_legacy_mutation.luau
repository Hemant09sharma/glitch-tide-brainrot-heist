-- 02_legacy_mutation.luau — R3-8 fixes inside the three owned files:
--   (1) MutationService.GetInstances seed mirror heals a legacy placed
--       Mutation onto a freshly seeded owned record (owned nil +
--       placed "golden" diverged before R2-1, when placed copies were
--       never synced from the owned record).
--   (2) MutateBrainrot refuses to charge for a mutation the placed
--       copy already shows when the owned record has none (narrow
--       double-charge guard); it still allows re-buying the displayed
--       mutation when the owned record holds a DIFFERENT one (that
--       heals the divergence).
--   (3) BaseService.reinsertPlacedRecord refuses whole-record
--       reinserts the player does not own (missing owned record,
--       in-transit, or stolen from someone else), while still
--       allowing the legitimate RaidService return path (owned record
--       back with the victim, markers cleared) and staying idempotent
--       for an already-placed record. A legacy save with no
--       OwnedInstances registry fails CLOSED for arbitrary ids
--       (ensureBaseData creates an empty registry first); once
--       GetInstances seeds the registry, the seeded id reinserts.
--   (4) BaseService per-action throttle (source-shape only — see below).
--
-- LIMITATION (stated honestly): the throttle lives in the remote
-- handlers, which BaseService.Init wires inside a task.spawn that the
-- harness discards by design, so no Lune test can fire the remotes.
-- The throttle is therefore verified by source-shape assertions +
-- luau-compile, not by firing remotes; a Studio playtest must click
-- Collect then Store inside 250 ms to see both land.
--
-- Run: bash scripts/phase1-tests/mutation-payload/run.sh
-- (from the package root; the fs reads below are cwd-relative).
local fs = require("@lune/fs")
local H = require("../harness")

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

local env = H.newEnv()
local base = H.newBaseEnv(env)
env.mutation.SetBaseService(base)
base.SetMutationService(env.mutation)

-- ---------------------------------------------------------------------------
-- (1) Seed mirror: legacy save with NO OwnedInstances at all.
-- The seed builds "inst_<uid>_wobble_waffleton_1" for Unlocked[1];
-- the placed copy carries Mutation "golden" (pre-fix: the seeded
-- owned record kept Mutation = nil, diverging from display/income).
-- ---------------------------------------------------------------------------
local seedPlayer = H.newPlayer(921, "SeedVictim")
local seedData: { [string]: any } = {
	Level = 5,
	Coins = 10000,
	MutationCrystals = 1000,
	Rebirths = 0,
	Unlocked = { "wobble_waffleton", "turbo_turnip" },
	Base = {
		Placed = {
			{
				InstanceId = "inst_921_wobble_waffleton_1",
				CharacterId = "wobble_waffleton",
				Slot = 2,
				Level = 5,
				Glitched = true,
				Mutation = "golden",
				BankedIncome = 500,
				PlacedAt = os.time() - 1000,
			},
		},
	},
	LabDiscoveries = {},
}
env.dataService.Ensure(seedPlayer, seedData)
local seeded = env.mutation.GetInstances(seedPlayer)
local seededTarget: any = nil
for _, inst in ipairs(seeded) do
	if type(inst) == "table" and inst.InstanceId == "inst_921_wobble_waffleton_1" then
		seededTarget = inst
	end
end
check("SEED: legacy save without OwnedInstances seeds the owned record",
	seededTarget ~= nil)
check("SEED: seeded owned record heals Mutation from the placed copy (golden, not nil)",
	seededTarget ~= nil and seededTarget.Mutation == "golden",
	"mutation=" .. tostring(seededTarget and seededTarget.Mutation))
check("SEED: seeded owned record mirrors Placed / Slot / Level / Glitched too",
	seededTarget ~= nil and seededTarget.Placed == true and seededTarget.Slot == 2
		and seededTarget.Level == 5 and seededTarget.Glitched == true)

-- ---------------------------------------------------------------------------
-- (2) Placed-copy same-mutation guard (owned nil, placed golden).
-- ---------------------------------------------------------------------------
local pairC = H.newPair(env, 931, 932)
base.AssignBase(pairC.thief)
base.AssignBase(pairC.victim)
H.findOwned(pairC.victimData, pairC.targetId).Mutation = nil
local crystalsBeforeC = pairC.victimData.MutationCrystals
local okC1, errC1 = env.mutation.MutateBrainrot(pairC.victim, pairC.targetId, "golden")
check("GUARD: re-buying the mutation the placed copy already shows is refused",
	okC1 == false, "err=" .. tostring(errC1))
check("GUARD: refused re-buy charges no crystals",
	pairC.victimData.MutationCrystals == crystalsBeforeC,
	"crystals=" .. tostring(pairC.victimData.MutationCrystals))
local okC2, errC2 = env.mutation.MutateBrainrot(pairC.victim, pairC.targetId, "electric")
check("GUARD: buying a DIFFERENT mutation is still allowed",
	okC2 == true, "err=" .. tostring(errC2))
check("GUARD: different mutation lands on owned and placed",
	H.findOwned(pairC.victimData, pairC.targetId).Mutation == "electric"
		and H.findPlaced(pairC.victimData, pairC.targetId).Mutation == "electric")

-- Narrowness: owned holds a different mutation than the stale placed
-- copy — re-buying the displayed mutation must stay allowed (it heals
-- the divergence by making owned match the display).
local pairD = H.newPair(env, 933, 934)
base.AssignBase(pairD.thief)
base.AssignBase(pairD.victim)
H.findOwned(pairD.victimData, pairD.targetId).Mutation = "electric"
local okD, errD = env.mutation.MutateBrainrot(pairD.victim, pairD.targetId, "golden")
check("GUARD-NARROW: owned=electric / placed=golden can still re-buy golden",
	okD == true, "err=" .. tostring(errD))
check("GUARD-NARROW: re-buy heals owned and placed to golden",
	H.findOwned(pairD.victimData, pairD.targetId).Mutation == "golden"
		and H.findPlaced(pairD.victimData, pairD.targetId).Mutation == "golden")

-- ---------------------------------------------------------------------------
-- (3) reinsertPlacedRecord ownership guard (real BaseService, table shape).
-- ---------------------------------------------------------------------------
local function placedCount(data)
	if type(data.Base) ~= "table" or type(data.Base.Placed) ~= "table" then
		return 0
	end
	return #data.Base.Placed
end

-- Legit return shape: owned record present, not in transit, no foreign
-- theft marker; no placed copy yet (it was removed at steal time).
local pairE = H.newPair(env, 935, 936)
base.AssignBase(pairE.thief)
base.AssignBase(pairE.victim)
local ownedE = H.findOwned(pairE.victimData, pairE.targetId)
ownedE.Placed = false
ownedE.Slot = 0
local placedE = pairE.victimData.Base.Placed
for i = #placedE, 1, -1 do
	if type(placedE[i]) == "table" and placedE[i].InstanceId == pairE.targetId then
		table.remove(placedE, i)
	end
end
local okE, retE = base.PlaceBrainrot(pairE.victim, {
	InstanceId = pairE.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 2,
	Level = 5,
	Glitched = true,
	Mutation = "golden",
	BankedIncome = 500,
	PlacedAt = os.time() - 1000,
})
check("REINSERT: legitimate return (owned, not in transit) is accepted",
	okE == true, "err=" .. tostring(retE))
check("REINSERT: legitimate return restores the placed copy",
	H.findPlaced(pairE.victimData, pairE.targetId) ~= nil)

-- Foreign record: InstanceId the player does not own at all.
-- (The target's own placed copy is removed first, so the guard is
-- actually reached — reinserting an already-placed record returns
-- the existing copy instead, by design; covered below.)
local pairF = H.newPair(env, 937, 938)
base.AssignBase(pairF.thief)
base.AssignBase(pairF.victim)
local placedF = pairF.victimData.Base.Placed
for i = #placedF, 1, -1 do
	if type(placedF[i]) == "table" and placedF[i].InstanceId == pairF.targetId then
		table.remove(placedF, i)
	end
end
local ownedF = H.findOwned(pairF.victimData, pairF.targetId)
ownedF.Placed = false
ownedF.Slot = 0
local beforeF = placedCount(pairF.victimData)
local okF, errF = base.PlaceBrainrot(pairF.victim, {
	InstanceId = "someone_elses_brainrot",
	CharacterId = "wobble_waffleton",
	Slot = 3,
	Level = 9,
	Glitched = false,
	Mutation = "rainbow",
	BankedIncome = 9999,
	PlacedAt = os.time(),
})
check("REINSERT: foreign record (not in owned instances) is refused",
	okF == false, "err=" .. tostring(errF))
check("REINSERT: refused foreign record inserts no placed copy",
	placedCount(pairF.victimData) == beforeF)

-- In-transit record: owned but stolen (flag still set).
local ownedG = ownedF
ownedG.InTransit = true
local beforeG = placedCount(pairF.victimData)
local okG, errG = base.PlaceBrainrot(pairF.victim, {
	InstanceId = pairF.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 2,
	Level = 5,
	Glitched = true,
	Mutation = "golden",
	BankedIncome = 500,
	PlacedAt = os.time() - 1000,
})
check("REINSERT: in-transit record is refused",
	okG == false, "err=" .. tostring(errG))
check("REINSERT: refused in-transit record inserts no placed copy",
	placedCount(pairF.victimData) == beforeG)
ownedG.InTransit = nil

-- Stolen-from-someone-else: owned record marked with a foreign victim.
ownedG.StolenFromUserId = 123456
local beforeH = placedCount(pairF.victimData)
local okH, errH = base.PlaceBrainrot(pairF.victim, {
	InstanceId = pairF.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 2,
	Level = 5,
	Glitched = true,
	Mutation = "golden",
	BankedIncome = 500,
	PlacedAt = os.time() - 1000,
})
check("REINSERT: record stolen from another player is refused",
	okH == false, "err=" .. tostring(errH))
check("REINSERT: refused foreign-theft record inserts no placed copy",
	placedCount(pairF.victimData) == beforeH)
ownedG.StolenFromUserId = nil

-- Character mismatch: same InstanceId, different character.
local beforeI = placedCount(pairF.victimData)
local okI, errI = base.PlaceBrainrot(pairF.victim, {
	InstanceId = pairF.targetId,
	CharacterId = "turbo_turnip",
	Slot = 2,
	Level = 5,
	Glitched = true,
	Mutation = "golden",
	BankedIncome = 500,
	PlacedAt = os.time() - 1000,
})
check("REINSERT: character mismatch against the owned record is refused",
	okI == false, "err=" .. tostring(errI))
check("REINSERT: refused mismatch inserts no placed copy",
	placedCount(pairF.victimData) == beforeI)

-- Already-placed record: reinsert is idempotent — the existing copy
-- is returned, not a duplicate, and the guard is not consulted.
local okJ, retJ = base.PlaceBrainrot(pairE.victim, {
	InstanceId = pairE.targetId,
	CharacterId = "wobble_waffleton",
	Slot = 2,
	Level = 5,
	Glitched = true,
	Mutation = "golden",
	BankedIncome = 500,
	PlacedAt = os.time() - 1000,
})
check("REINSERT: already-placed record returns the existing copy (idempotent)",
	okJ == true and type(retJ) == "table" and retJ.InstanceId == pairE.targetId)
check("REINSERT: idempotent reinsert creates no duplicate placed copy",
	placedCount(pairE.victimData) == 2)

-- Legacy fail-closed: a save with no OwnedInstances registry gets an
-- empty registry from ensureBaseData, so an arbitrary legacy id is
-- refused (no loss: nothing is planted, nothing is deleted). Once
-- GetInstances seeds the registry from Unlocked, the seeded id
-- reinserts fine.
local legacyPlayer = H.newPlayer(939, "LegacyReturn")
local legacyData: { [string]: any } = {
	Level = 5,
	Coins = 10000,
	MutationCrystals = 100,
	Rebirths = 0,
	Unlocked = { "wobble_waffleton", "turbo_turnip" },
	Base = { Placed = {} },
	LabDiscoveries = {},
}
env.dataService.Ensure(legacyPlayer, legacyData)
-- NOTE: GetInstances must run BEFORE AssignBase — ensureBaseData
-- creates an empty OwnedInstances table, after which GetInstances
-- no longer seeds from Unlocked (pre-existing interaction, not
-- something this fix changes).
env.mutation.GetInstances(legacyPlayer)
base.AssignBase(legacyPlayer)
local beforeL = placedCount(legacyData)
local okL, errL = base.PlaceBrainrot(legacyPlayer, {
	InstanceId = "legacy_placed_1",
	CharacterId = "wobble_waffleton",
	Slot = 1,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = os.time(),
})
check("REINSERT: legacy save with no registry refuses an arbitrary id (fail-closed)",
	okL == false, "err=" .. tostring(errL))
check("REINSERT: refused legacy id inserts no placed copy",
	placedCount(legacyData) == beforeL)
local okL2, retL2 = base.PlaceBrainrot(legacyPlayer, {
	InstanceId = "inst_939_wobble_waffleton_1",
	CharacterId = "wobble_waffleton",
	Slot = 1,
	Level = 1,
	Glitched = false,
	Mutation = nil,
	BankedIncome = 0,
	PlacedAt = os.time(),
})
check("REINSERT: seeded legacy id reinserts once the registry exists",
	okL2 == true, "err=" .. tostring(retL2))

-- ---------------------------------------------------------------------------
-- (4) Throttle: source-shape assertions (see header limitation).
-- ---------------------------------------------------------------------------
local baseSrc = readSrc("server/Services/BaseService.luau")
check("SRC: throttle is per-action (definition takes an action key)",
	string.find(baseSrc, "local function rateLimited(player: Player, action: string)", 1, true) ~= nil)
for _, action in ipairs({ "place", "collect", "upgradeBase", "upgradeBrainrot", "store" }) do
	check("SRC: throttle has a per-action call site for " .. action,
		string.find(baseSrc, "rateLimited(player, \"" .. action .. "\")", 1, true) ~= nil)
end
check("SRC: no shared single-timestamp rateLimited(player) call remains",
	string.find(baseSrc, "rateLimited(player)") == nil)
check("SRC: Action envelopes return before the throttle in onUpgradeBase",
	string.find(baseSrc, "they return BEFORE the throttle", 1, true) ~= nil)

H.finish()
