-- 01_expedition_in_transit.luau — R2-2 / P0-3: an in-transit (stolen)
-- Brainrot must never start an expedition, and a victim's record must
-- never be permanently locked by an expedition flag.
--
-- Loads the REAL ExpeditionService (see expedition/refresh.sh) with the
-- real RaidService / CarryService / MutationService / FusionService from
-- harness.newEnv() and the real BaseService via harness.newBaseEnv().
-- Run: bash scripts/phase1-tests/expedition/run.sh
local H = require("../harness")
local ExpeditionService = require("./services/ExpeditionService")

local env = H.newEnv()
local base = H.newBaseEnv(env)
ExpeditionService.Init(env.dataService)
ExpeditionService.SetMutationService(env.mutation)

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function wallet(data)
	return {
		Coins = tonumber(data.Coins) or 0,
		Gems = tonumber(data.Gems) or 0,
		Crystals = tonumber(data.MutationCrystals) or 0,
		Shards = tonumber(data.ChaosShards) or 0,
		XP = tonumber(data.XP) or 0,
	}
end
local function walletSame(a, b)
	return a.Coins == b.Coins and a.Gems == b.Gems and a.Crystals == b.Crystals
		and a.Shards == b.Shards and a.XP == b.XP
end
local function walletStr(w)
	return string.format("coins=%d gems=%d crystals=%d shards=%d xp=%d",
		w.Coins, w.Gems, w.Crystals, w.Shards, w.XP)
end

local function placeOwned(pair, plotIndex, owned, slot)
	local okCarry, carryErr = env.carry.PickupOwned(pair.thief, owned)
	assert(okCarry, "PickupOwned failed: " .. tostring(carryErr))
	H.setRootPosition(pair.thief, H.pedestalPosition(plotIndex, slot))
	local ok, placed = base.PlaceBrainrot(pair.thief, owned.InstanceId, slot)
	assert(ok, "PlaceBrainrot failed: " .. tostring(placed))
	return placed
end

-- Like placeOwned, but for the victim (whose plot / root differ).
local function placeOwnedVictim(pair, plotIndex, owned, slot)
	local okCarry, carryErr = env.carry.PickupOwned(pair.victim, owned)
	assert(okCarry, "victim PickupOwned failed: " .. tostring(carryErr))
	H.setRootPosition(pair.victim, H.pedestalPosition(plotIndex, slot))
	local ok, placed = base.PlaceBrainrot(pair.victim, owned.InstanceId, slot)
	assert(ok, "victim PlaceBrainrot failed: " .. tostring(placed))
	return placed
end

-- ---------------------------------------------------------------------------
-- Pair 1: steal, then the thief tries to expedition the stolen record.
-- ---------------------------------------------------------------------------
local pair1 = H.newPair(env, 501, 601)
H.steal(env, pair1)
local moved1 = H.findOwned(pair1.thiefData, pair1.targetId)
check("1: steal moved the record with InTransit set",
	moved1 ~= nil and moved1.InTransit == true)

-- Bypass mechanism, confirmed against the real code path:
-- MutationService.FindInstance resolves the in-transit record for the
-- thief (GetInstances mirrors OwnedInstances, no InTransit filter),
-- which is exactly how the old StartExpedition could reach it.
local found1 = env.mutation.FindInstance(pair1.thief, pair1.targetId)
check("1: FindInstance returns the in-transit record for the thief",
	found1 ~= nil and found1 == moved1 and found1.InTransit == true)

local state1 = ExpeditionService.GetExpeditions(pair1.thief)
local inAnyList = false
local ownEligible = false
if type(state1.Eligible) == "table" then
	for _, list in pairs(state1.Eligible) do
		if type(list) == "table" and table.find(list, pair1.targetId) ~= nil then
			inAnyList = true
		end
	end
	local market = state1.Eligible["exp_market_run"]
	if type(market) == "table" and table.find(market, pair1.prefix .. "evo_1") ~= nil then
		ownEligible = true
	end
end
check("1: in-transit Brainrot appears in NO expedition eligible list", inAnyList == false)
check("1: thief's own unplaced Brainrot IS still listed (filter is specific)",
	ownEligible == true)

local before1 = wallet(pair1.thiefData)
local okStart, startReason = ExpeditionService.StartExpedition(pair1.thief, pair1.targetId, "exp_market_run")
check("1: start with an in-transit Brainrot is rejected",
	okStart == false and type(startReason) == "string"
		and string.find(startReason, "transit") ~= nil,
	"reason=" .. tostring(startReason))
check("1: rejected start creates NO Active entry",
	pair1.thiefData.Expeditions == nil or pair1.thiefData.Expeditions.Active == nil)
check("1: rejected start changes NO flags (InTransit kept, OnExpedition never set)",
	moved1.InTransit == true and moved1.OnExpedition ~= true)
check("1: rejected start awards nothing", walletSame(before1, wallet(pair1.thiefData)),
	"before " .. walletStr(before1) .. " / after " .. walletStr(wallet(pair1.thiefData)))

local okClaim, claimReason = ExpeditionService.ClaimExpedition(pair1.thief, "exp_market_run")
check("1: claim after a rejected start is rejected",
	okClaim == false and type(claimReason) == "string",
	"reason=" .. tostring(claimReason))
check("1: claim after a rejected start awards nothing",
	walletSame(before1, wallet(pair1.thiefData)))

-- Positive control: the thief's OWN unplaced Brainrot still works.
local own1 = H.findOwned(pair1.thiefData, pair1.prefix .. "evo_1")
local okOwn, activeOwn = ExpeditionService.StartExpedition(pair1.thief, pair1.prefix .. "evo_1", "exp_market_run")
check("1: own unplaced Brainrot CAN start an expedition",
	okOwn == true and type(activeOwn) == "table",
	"err=" .. tostring(activeOwn))
check("1: live expedition sets Active + OnExpedition flag",
	pair1.thiefData.Expeditions ~= nil and pair1.thiefData.Expeditions.Active ~= nil
		and own1.OnExpedition == true)
check("1: helper is a no-op on a LIVE expedition (flag must stay)",
	ExpeditionService.ClearOrphanedExpeditionFlag(pair1.thief, pair1.prefix .. "evo_1") == false
		and own1.OnExpedition == true)
check("1: HasActiveExpedition true for the live trip, false for another instance",
	ExpeditionService.HasActiveExpedition(pair1.thief, pair1.prefix .. "evo_1") == true
		and ExpeditionService.HasActiveExpedition(pair1.thief, pair1.prefix .. "fuse_a") == false)
local beforeEarly = wallet(pair1.thiefData)
local okEarly, earlyReason = ExpeditionService.ClaimExpedition(pair1.thief, "exp_market_run")
check("1: early claim is rejected and pays nothing",
	okEarly == false and type(earlyReason) == "string"
		and string.find(earlyReason, "not finished") ~= nil
		and walletSame(beforeEarly, wallet(pair1.thiefData)),
	"reason=" .. tostring(earlyReason))
pair1.thiefData.Expeditions.Active.EndsAt = os.time() - 1
local coinsBeforeClaim = tonumber(pair1.thiefData.Coins) or 0
local xpBeforeClaim = tonumber(pair1.thiefData.XP) or 0
local okClaimOwn, rewardsOwn = ExpeditionService.ClaimExpedition(pair1.thief, "exp_market_run")
check("1: finished own expedition claims successfully",
	okClaimOwn == true and type(rewardsOwn) == "table",
	"err=" .. tostring(rewardsOwn))
check("1: claim pays coins + XP and clears flag / Active, Completed=1",
	(tonumber(pair1.thiefData.Coins) or 0) >= coinsBeforeClaim + 50
		and (tonumber(pair1.thiefData.XP) or 0) > xpBeforeClaim
		and own1.OnExpedition ~= true
		and pair1.thiefData.Expeditions.Active == nil
		and tonumber(pair1.thiefData.Expeditions.Completed) == 1,
	"coins=" .. tostring(pair1.thiefData.Coins) .. " xp=" .. tostring(pair1.thiefData.XP))

-- ---------------------------------------------------------------------------
-- Pair 2: real ReturnStolen, then the victim recovers fully; plus the
-- defensive claim path (Active entry + in-transit instance).
-- ---------------------------------------------------------------------------
local pair2 = H.newPair(env, 502, 602)
local plot2t = base.AssignBase(pair2.thief)
local plot2v = base.AssignBase(pair2.victim)
assert(plot2t ~= nil and plot2v ~= nil, "pair2 plots not assigned")
H.steal(env, pair2)
local okReturn2 = env.raid.ReturnStolen(pair2.targetId)
check("2: ReturnStolen restores the stolen Brainrot", okReturn2 == true)
local back2 = H.findOwned(pair2.victimData, pair2.targetId)
check("2: returned record is back with the victim, flags clear",
	back2 ~= nil and back2.InTransit ~= true and back2.OnExpedition ~= true
		and H.findOwned(pair2.thiefData, pair2.targetId) == nil
		and H.countOwned(env, { pair2.thief, pair2.victim }, pair2.targetId) == 1)
check("2: placed copy restored for the victim",
	H.findPlaced(pair2.victimData, pair2.targetId) ~= nil)
check("2: helper is a no-op when there is no flag to clear",
	ExpeditionService.ClearOrphanedExpeditionFlag(pair2.victim, pair2.targetId) == false)
local okStore2, storeErr2 = base.StoreBrainrot(pair2.victim, pair2.targetId)
check("2: returned Brainrot can be stored", okStore2 == true, "err=" .. tostring(storeErr2))
local placed2 = placeOwnedVictim(pair2, plot2v, back2, 2)
check("2: returned Brainrot can be carried + re-placed",
	placed2 ~= nil and placed2.Slot == 2)
check("2: returned Brainrot can be stored again", base.StoreBrainrot(pair2.victim, pair2.targetId) == true)
check("2: filler can be stored too", base.StoreBrainrot(pair2.victim, pair2.fillerId) == true)
local okFuse2, fuseOut2, fuseErr2 = env.fusion.FuseBrainrot(pair2.victim, pair2.targetId, pair2.fillerId)
check("2: returned Brainrot can be fused normally",
	okFuse2 == true and fuseOut2 ~= nil, "err=" .. tostring(fuseErr2))

-- Defensive claim: thief starts a legit expedition, the instance then
-- goes in transit (simulated mid-theft state) before claim time.
local own2 = H.findOwned(pair2.thiefData, pair2.prefix .. "evo_1")
local okStart2 = ExpeditionService.StartExpedition(pair2.thief, pair2.prefix .. "evo_1", "exp_market_run")
assert(okStart2, "pair2 own start failed")
own2.InTransit = true
pair2.thiefData.Expeditions.Active.EndsAt = os.time() - 1
local beforeClaim2 = wallet(pair2.thiefData)
local okClaim2, claimReason2 = ExpeditionService.ClaimExpedition(pair2.thief, "exp_market_run")
check("2: claim while the expedition Brainrot is in transit is rejected",
	okClaim2 == false and type(claimReason2) == "string"
		and string.find(claimReason2, "transit") ~= nil,
	"reason=" .. tostring(claimReason2))
check("2: in-transit claim pays nothing and leaves Active + flag untouched",
	walletSame(beforeClaim2, wallet(pair2.thiefData))
		and pair2.thiefData.Expeditions.Active ~= nil
		and own2.OnExpedition == true)
own2.InTransit = nil
local okClaim2b = ExpeditionService.ClaimExpedition(pair2.thief, "exp_market_run")
check("2: claim succeeds once transit clears",
	okClaim2b == true and own2.OnExpedition ~= true
		and pair2.thiefData.Expeditions.Active == nil)

-- ---------------------------------------------------------------------------
-- Pair 3: the PRE-FIX orphan, simulated exactly: thief started an
-- expedition with the stolen record (Active in the thief's data,
-- OnExpedition on the instance), then ReturnStolen moves it back.
-- R2: ReturnStolen now auto-clears the orphaned flag itself (inline
-- fallback here — ExpeditionService is NOT wired into RaidService yet
-- in this file, so the helper-call path is untested until Pair 4).
-- The victim must NOT be locked out anymore; the helper is a no-op
-- afterwards because there is nothing left to clear.
-- ---------------------------------------------------------------------------
local pair3 = H.newPair(env, 503, 603)
local plot3t = base.AssignBase(pair3.thief)
local plot3v = base.AssignBase(pair3.victim)
assert(plot3t ~= nil and plot3v ~= nil, "pair3 plots not assigned")
H.steal(env, pair3)
local moved3 = H.findOwned(pair3.thiefData, pair3.targetId)
-- Pre-fix state, as the old StartExpedition produced it:
moved3.OnExpedition = true
pair3.thiefData.Expeditions = {
	Active = {
		InstanceId = pair3.targetId,
		CharacterId = "wobble_waffleton",
		ExpeditionId = "exp_market_run",
		StartedAt = os.time() - 10,
		EndsAt = os.time() - 1,
	},
	Completed = 0,
}
local okReturn3 = env.raid.ReturnStolen(pair3.targetId)
check("3: ReturnStolen still returns the orphaned record", okReturn3 == true)
local back3 = H.findOwned(pair3.victimData, pair3.targetId)
check("3: ReturnStolen auto-clears the orphaned OnExpedition flag (fallback path)",
	back3 ~= nil and back3.OnExpedition ~= true and back3.InTransit ~= true
		and H.findPlaced(pair3.victimData, pair3.targetId) ~= nil)
local okStore3, storeErr3 = base.StoreBrainrot(pair3.victim, pair3.targetId)
check("3: victim is NOT locked out of storing after ReturnStolen",
	okStore3 == true, "err=" .. tostring(storeErr3))
check("3: victim has NO Active expedition for it (nothing to claim)",
	ExpeditionService.HasActiveExpedition(pair3.victim, pair3.targetId) == false)
local cleared3 = ExpeditionService.ClearOrphanedExpeditionFlag(pair3.victim, pair3.targetId)
check("3: helper is a no-op after the auto-clear (flag already gone)",
	cleared3 == false and back3.OnExpedition ~= true)
check("3: helper is a no-op the second time (flag already gone)",
	ExpeditionService.ClearOrphanedExpeditionFlag(pair3.victim, pair3.targetId) == false)
local placed3 = placeOwnedVictim(pair3, plot3v, back3, 2)
check("3: recovered Brainrot can be carried + re-placed",
	placed3 ~= nil and placed3.Slot == 2)
check("3: recovered Brainrot can be stored again",
	base.StoreBrainrot(pair3.victim, pair3.targetId) == true)
check("3: filler can be stored too", base.StoreBrainrot(pair3.victim, pair3.fillerId) == true)
local okFuse3, fuseOut3, fuseErr3 = env.fusion.FuseBrainrot(pair3.victim, pair3.targetId, pair3.fillerId)
check("3: recovered Brainrot can be fused normally",
	okFuse3 == true and fuseOut3 ~= nil, "err=" .. tostring(fuseErr3))

-- The thief's stale Active entry must mint NOTHING: the Brainrot is
-- gone from the thief's data, so the defensive claim path drops the
-- entry without paying.
local beforeThief3 = wallet(pair3.thiefData)
local completed3 = tonumber(pair3.thiefData.Expeditions.Completed) or 0
local okClaim3, claimReason3 = ExpeditionService.ClaimExpedition(pair3.thief, "exp_market_run")
check("3: thief's stale claim is rejected and pays nothing",
	okClaim3 == false and type(claimReason3) == "string"
		and string.find(claimReason3, "no longer owned") ~= nil
		and walletSame(beforeThief3, wallet(pair3.thiefData)),
	"reason=" .. tostring(claimReason3))
check("3: stale Active entry is dropped, Completed NOT incremented",
	pair3.thiefData.Expeditions.Active == nil
		and (tonumber(pair3.thiefData.Expeditions.Completed) or 0) == completed3)

-- ---------------------------------------------------------------------------
-- Pair 4: same pre-fix orphan, but with ExpeditionService wired into
-- RaidService via SetExpeditionService (the production wiring —
-- GameManager's cross-link pass calls the setter automatically).
-- ReturnStolen must clear the flag through the helper this time, with
-- the same observable outcome as the Pair 3 fallback path.
-- ---------------------------------------------------------------------------
env.raid.SetExpeditionService(ExpeditionService)
local pair4 = H.newPair(env, 504, 604)
local plot4t = base.AssignBase(pair4.thief)
local plot4v = base.AssignBase(pair4.victim)
assert(plot4t ~= nil and plot4v ~= nil, "pair4 plots not assigned")
H.steal(env, pair4)
local moved4 = H.findOwned(pair4.thiefData, pair4.targetId)
moved4.OnExpedition = true
pair4.thiefData.Expeditions = {
	Active = {
		InstanceId = pair4.targetId,
		CharacterId = "wobble_waffleton",
		ExpeditionId = "exp_market_run",
		StartedAt = os.time() - 10,
		EndsAt = os.time() - 1,
	},
	Completed = 0,
}
local okReturn4 = env.raid.ReturnStolen(pair4.targetId)
check("4: ReturnStolen returns the orphaned record (wired helper path)", okReturn4 == true)
local back4 = H.findOwned(pair4.victimData, pair4.targetId)
check("4: orphaned flag auto-cleared via the wired helper",
	back4 ~= nil and back4.OnExpedition ~= true and back4.InTransit ~= true
		and H.findPlaced(pair4.victimData, pair4.targetId) ~= nil)
check("4: victim is NOT locked out of storing (wired helper path)",
	base.StoreBrainrot(pair4.victim, pair4.targetId) == true)
local placed4 = placeOwnedVictim(pair4, plot4v, back4, 2)
check("4: recovered Brainrot can be carried + re-placed",
	placed4 ~= nil and placed4.Slot == 2)
check("4: recovered Brainrot can be stored again",
	base.StoreBrainrot(pair4.victim, pair4.targetId) == true)

H.finish()
