-- 10_r4_3_spending_routes.luau — R4-3 (P2, Test C routes):
-- Every debit route must respect the coin reservation, not just
-- the tested one. Each route gets the same window: balance 2000
-- coins, a 1500-coin reservation held (spendable 500). A purchase
-- priced in (500, 2000] is affordable against the raw balance but
-- NOT against spendable coins, so it must be refused while the
-- reservation holds — and must succeed once the reservation is
-- released (proving the refusal was the reservation, not the
-- route). A purchase priced at or below spendable must succeed
-- while the reservation holds. The reservation is held through
-- the public ReserveCoins API — the same API the pending-reward
-- commit uses. FusionService.FuseBrainrot is covered below (R4-3
-- follow-up: it was the last direct-assignment debit route; it now
-- judges affordability on spendable coins and charges through
-- DataService.AddCoins).
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local env = R.newEnv()
local DS = env.dataService
local EconomyService = require("./services/EconomyService")
EconomyService.Init(DS)
local AbilityService = require("./services/AbilityService")
AbilityService.Init(DS, nil)
local MutationService = require("../theft/services/MutationService")
local FusionService = require("../theft/services/FusionService")
local LaboratoryService = require("./services/LaboratoryService")
LaboratoryService.Init(DS, MutationService, FusionService)
local ConveyorService = require("./services/ConveyorService")
ConveyorService.Init(DS, EconomyService, nil)
FusionService.Init(DS, MutationService, nil)
local BaseService = H.newBaseEnv(env)

-- Lune's stdlib has no UDim2 (ConveyorService.makeBillboard calls
-- UDim2.new at spawn time); stub the global the same way the
-- harness stubs Color3/Enum. UDim2 is not a Luau fastcall builtin,
-- so the assignment is visible to required modules.
if UDim2 == nil then
	UDim2 = {
		new = function(...)
			return { __udim2 = true }
		end,
	}
end

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function coins(player)
	return tonumber(DS.GetData(player).Coins) or 0
end

local function hold(player, amount)
	assert(DS.ReserveCoins(player, "r4-route-test", amount) == true, "setup: reserve must succeed")
	assert(DS.GetSpendableCoins(player) == coins(player) - amount, "setup: spendable must be balance minus reserve")
end

-- --- Primitive: the reservation floor itself ----------------------
local pPrim = R.newLoadedPlayer(env, 9501, 2000)
hold(pPrim, 1500)
check("primitive: spendable is balance minus the reservation", DS.GetSpendableCoins(pPrim) == 500)
DS.AddCoins(pPrim, -2000)
check("primitive: a debit cannot take the balance below the reserved floor (1500, not 0)",
	coins(pPrim) == 1500, "coins=" .. tostring(coins(pPrim)))
check("primitive: the reservation is still held after the clamped debit",
	DS.GetReservedCoins(pPrim) == 1500)
assert(DS.ReleaseReservation(pPrim, "r4-route-test") == 1500, "setup: release must return the reserved amount")
check("primitive: after release the floor is gone", DS.GetSpendableCoins(pPrim) == 1500)
DS.AddCoins(pPrim, -1500)
check("primitive: after release the remaining balance can be spent", coins(pPrim) == 0)

-- --- EconomyService.BuyCharacter -----------------------------------
local pEco = R.newLoadedPlayer(env, 9502, 2000)
hold(pEco, 1500)
local okExp, errExp = EconomyService.BuyCharacter(pEco, "toast_ghost")
check("economy: a 1800-coin character is refused while 1500 is reserved (spendable 500)",
	okExp == false, "err=" .. tostring(errExp))
check("economy: the refused purchase charged nothing", coins(pEco) == 2000
	and DS.HasCharacter(pEco, "toast_ghost") == false)
local okCheap, errCheap = EconomyService.BuyCharacter(pEco, "bloop_bloomington")
check("economy: a 400-coin character succeeds while the reservation holds",
	okCheap == true, "err=" .. tostring(errCheap))
check("economy: balance after the affordable purchase is 1600", coins(pEco) == 1600)
local pEco2 = R.newLoadedPlayer(env, 9503, 2000)
hold(pEco2, 1500)
local okExp2 = EconomyService.BuyCharacter(pEco2, "toast_ghost")
check("economy: the expensive character is refused again on a fresh player", okExp2 == false)
assert(DS.ReleaseReservation(pEco2, "r4-route-test") == 1500, "setup: release must return the reserved amount")
local okExp3, errExp3 = EconomyService.BuyCharacter(pEco2, "toast_ghost")
check("economy: the same purchase succeeds once the reservation is released",
	okExp3 == true, "err=" .. tostring(errExp3))
check("economy: balance after the released purchase is 200", coins(pEco2) == 200)

-- --- BaseService: UpgradeBrainrot + UpgradeBase --------------------
local pBase = R.newLoadedPlayer(env, 9504, 2000)
local brainrotId = "route-brainrot-9504"
table.insert(DS.GetData(pBase).OwnedInstances, {
	InstanceId = brainrotId,
	CharacterId = "turbo_turnip",
	Level = 4,
	Glitched = false,
	Mutation = "None",
	Slot = 1,
	Placed = true,
})
-- UpgradeBrainrot only upgrades PLACED Brainrots.
table.insert(DS.GetData(pBase).Base.Placed, {
	InstanceId = brainrotId,
	CharacterId = "turbo_turnip",
	Slot = 1,
	Level = 4,
	PlacedAt = os.time() - 1000,
})
hold(pBase, 1500)
local okUp, errUp = BaseService.UpgradeBrainrot(pBase, brainrotId)
check("base: a 1000-coin Brainrot upgrade is refused while 1500 is reserved (spendable 500)",
	okUp == false, "err=" .. tostring(errUp))
check("base: the refused upgrade charged nothing and did not level up",
	coins(pBase) == 2000
		and (tonumber(H.findPlaced(DS.GetData(pBase), brainrotId).Level) or 0) == 4)
local okSlot, errSlot = BaseService.UpgradeBase(pBase, "BaseSlot")
check("base: a 150-coin BaseSlot upgrade succeeds while the reservation holds",
	okSlot == true, "err=" .. tostring(errSlot))
check("base: balance after the affordable upgrade is 1850", coins(pBase) == 1850)
local function setPlacedLevel(level)
	H.findPlaced(DS.GetData(pBase), brainrotId).Level = level
	H.findOwned(DS.GetData(pBase), brainrotId).Level = level
end
setPlacedLevel(1)
local okUpCheap, errUpCheap = BaseService.UpgradeBrainrot(pBase, brainrotId)
check("base: a 100-coin Brainrot upgrade succeeds while the reservation holds",
	okUpCheap == true, "err=" .. tostring(errUpCheap))
check("base: balance after the cheap upgrade is 1750", coins(pBase) == 1750)
assert(DS.ReleaseReservation(pBase, "r4-route-test") == 1500, "setup: release must return the reserved amount")
setPlacedLevel(4)
local okUpRel, errUpRel = BaseService.UpgradeBrainrot(pBase, brainrotId)
check("base: the 1000-coin upgrade succeeds once the reservation is released",
	okUpRel == true, "err=" .. tostring(errUpRel))
check("base: balance after the released upgrade is 750", coins(pBase) == 750)

-- --- ConveyorService.BuyItem ---------------------------------------
-- HARNESS LIMIT (not a product bug): BuyItem locates the item via
-- the world model, and Lune's typeof() returns "table" for the
-- harness's mock Instances (it ignores the __type metatable field),
-- so `typeof(model) == "Instance"` is never true and itemPos is
-- always nil — every buy is refused as "too far", before the
-- affordability check is ever reached. What Lune CAN prove here:
-- the refusal charges nothing and the item stays listed; the
-- affordability check itself (GetSpendableCoins in BuyItem, the
-- same pattern proven live in the Economy/Base/Lab/Ability routes
-- below) is asserted by the static anchor in run.sh.
local pConv = R.newLoadedPlayer(env, 9505, 2000)
hold(pConv, 1500)
local pricey = nil
for _ = 1, 8 do
	local snap = ConveyorService.ForceSpawn("Rare")
	if snap == nil then
		break
	end
	if snap.Price > 500 and snap.Price <= 2000 then
		pricey = snap
		break
	end
end
check("conveyor: a Rare item priced in (500, 2000] was spawned for the test",
	pricey ~= nil, "price=" .. tostring(pricey and pricey.Price or nil))
if pricey ~= nil then
	local okBuy, errBuy = ConveyorService.BuyItem(pConv, pricey.InstanceId)
	check("conveyor: the buy is refused before any debit (harness: item position unresolvable)",
		okBuy == false, "err=" .. tostring(errBuy))
	check("conveyor: the refused purchase charged nothing and the item is still listed",
		coins(pConv) == 2000 and ConveyorService.GetItem(pricey.InstanceId) ~= nil)
end

-- --- LaboratoryService.EvolveBrainrot ------------------------------
local function labPlayer(id, reserveAmount)
	local p = R.newLoadedPlayer(env, id, 2000)
	table.insert(DS.GetData(p).OwnedInstances, {
		InstanceId = "route-lab-" .. tostring(id),
		CharacterId = "turbo_turnip",
		Level = 5,
		Glitched = false,
		Mutation = "None",
		Evolved = false,
		Slot = 0,
	})
	DS.GetData(p).MutationCrystals = 1000
	hold(p, reserveAmount)
	return p
end
local pLabRefuse = labPlayer(9506, 1600) -- spendable 400 < evolve cost 500
local okEvoRef, errEvoRef = LaboratoryService.EvolveBrainrot(pLabRefuse, "route-lab-9506")
check("lab: evolving (500 coins) is refused while spendable is 400",
	okEvoRef == false, "err=" .. tostring(errEvoRef))
check("lab: the refused evolve charged nothing and did not evolve",
	coins(pLabRefuse) == 2000
		and H.findOwned(DS.GetData(pLabRefuse), "route-lab-9506").Evolved ~= true)
local pLabOk = labPlayer(9507, 1500) -- spendable 500 == evolve cost 500
local okEvo, errEvo = LaboratoryService.EvolveBrainrot(pLabOk, "route-lab-9507")
check("lab: evolving succeeds when spendable exactly covers the cost",
	okEvo == true, "err=" .. tostring(errEvo))
check("lab: the evolve deducted exactly 500 coins",
	coins(pLabOk) == 1500, "coins=" .. tostring(coins(pLabOk)))
check("lab: the instance is evolved",
	H.findOwned(DS.GetData(pLabOk), "route-lab-9507").Evolved == true)

-- --- AbilityService.UnlockPower ------------------------------------
-- (The default loadout already unlocks dash, energy_shield and
-- magnet_pull, so this section uses a 1000-coin reservation window:
-- spendable 1000. gravity_shift costs 1500, teleport costs 1000.)
local pAb = R.newLoadedPlayer(env, 9508, 2000)
hold(pAb, 1000)
check("ability: spendable is 1000 in this window", DS.GetSpendableCoins(pAb) == 1000)
local okPow, errPow = AbilityService.UnlockPower(pAb, "gravity_shift", nil)
check("ability: a 1500-coin power is refused while 1000 is reserved (spendable 1000)",
	okPow == false, "err=" .. tostring(errPow))
check("ability: the refused unlock charged nothing", coins(pAb) == 2000)
local okPowCheap, errPowCheap = AbilityService.UnlockPower(pAb, "teleport", nil)
check("ability: a 1000-coin power succeeds when spendable exactly covers it",
	okPowCheap == true, "err=" .. tostring(errPowCheap))
check("ability: balance after the affordable unlock is 1000", coins(pAb) == 1000)
local pAb2 = R.newLoadedPlayer(env, 9509, 2000)
hold(pAb2, 1000)
local okPow2 = AbilityService.UnlockPower(pAb2, "gravity_shift", nil)
check("ability: the expensive power is refused again on a fresh player", okPow2 == false)
assert(DS.ReleaseReservation(pAb2, "r4-route-test") == 1000, "setup: release must return the reserved amount")
local okPowRel, errPowRel = AbilityService.UnlockPower(pAb2, "gravity_shift", nil)
check("ability: the 1500-coin power succeeds once the reservation is released",
	okPowRel == true, "err=" .. tostring(errPowRel))
check("ability: balance after the released unlock is 500", coins(pAb2) == 500)

-- --- FusionService.FuseBrainrot ------------------------------------
-- (R4-3 follow-up: this was the last direct-assignment debit route
-- (data.Coins = coins - cost.Coins). It now judges affordability on
-- spendable coins and charges through DataService.AddCoins, which
-- clamps a debit at the reserved total. Fusion costs 1000 coins +
-- 25 crystals; recipe wobble_waffleton + turbo_turnip ->
-- bloop_bloomington. The 1 s rate limit lives only in the remote
-- handler (onUpgradeRemote), not in FuseBrainrot itself, so direct
-- calls below need no clock spin.)
local function fusionPlayer(id, reserveAmount)
	local p = R.newLoadedPlayer(env, id, 2000)
	DS.GetData(p).MutationCrystals = 1000
	table.insert(DS.GetData(p).OwnedInstances, {
		InstanceId = "route-fuse-a-" .. tostring(id),
		CharacterId = "wobble_waffleton",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	table.insert(DS.GetData(p).OwnedInstances, {
		InstanceId = "route-fuse-b-" .. tostring(id),
		CharacterId = "turbo_turnip",
		Level = 1,
		Mutation = nil,
		Placed = false,
		Slot = 0,
	})
	hold(p, reserveAmount)
	return p
end
local function hasOwned(p, instanceId)
	return H.findOwned(DS.GetData(p), instanceId) ~= nil
end
local function hasCharacter(p, characterId)
	for _, inst in ipairs(DS.GetData(p).OwnedInstances) do
		if inst.CharacterId == characterId then
			return true
		end
	end
	return false
end
local pFuseRef = fusionPlayer(9510, 1500) -- spendable 500 < fusion cost 1000
local okFuseRef, errFuseRef = FusionService.FuseBrainrot(pFuseRef, "route-fuse-a-9510", "route-fuse-b-9510")
check("fusion: a 1000-coin fusion is refused while 1500 is reserved (spendable 500)",
	okFuseRef == false, "err=" .. tostring(errFuseRef))
check("fusion: the refused fusion charged nothing and kept both inputs",
	coins(pFuseRef) == 2000
		and hasOwned(pFuseRef, "route-fuse-a-9510")
		and hasOwned(pFuseRef, "route-fuse-b-9510"))
local pFuseOk = fusionPlayer(9511, 1000) -- spendable 1000 == fusion cost 1000
local okFuse, errFuse = FusionService.FuseBrainrot(pFuseOk, "route-fuse-a-9511", "route-fuse-b-9511")
check("fusion: fusion succeeds when spendable exactly covers the cost",
	okFuse == true, "err=" .. tostring(errFuse))
check("fusion: balance after the fusion is 1000 (reservation still held)",
	coins(pFuseOk) == 1000, "coins=" .. tostring(coins(pFuseOk)))
check("fusion: inputs consumed and the bloop_bloomington output created",
	hasOwned(pFuseOk, "route-fuse-a-9511") == false
		and hasOwned(pFuseOk, "route-fuse-b-9511") == false
		and hasCharacter(pFuseOk, "bloop_bloomington") == true)
local pFuseRel = fusionPlayer(9512, 1500)
local okFuseRel1 = FusionService.FuseBrainrot(pFuseRel, "route-fuse-a-9512", "route-fuse-b-9512")
check("fusion: the fusion is refused again on a fresh player", okFuseRel1 == false)
assert(DS.ReleaseReservation(pFuseRel, "r4-route-test") == 1500, "setup: release must return the reserved amount")
local okFuseRel2, errFuseRel2 = FusionService.FuseBrainrot(pFuseRel, "route-fuse-a-9512", "route-fuse-b-9512")
check("fusion: the same fusion succeeds once the reservation is released",
	okFuseRel2 == true, "err=" .. tostring(errFuseRel2))
check("fusion: balance after the released fusion is 1000", coins(pFuseRel) == 1000)

H.finish()
