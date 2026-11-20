-- 09_r4_10_legacy_recovery.luau — Legacy §10 (Test K):
-- A legacy InTransit record with NO StolenFromUserId can never be
-- resolved automatically (there is no evidence of the rightful
-- owner, and guessing would grant stolen goods to the wrong
-- player). The R4 fix is a controlled, server-authorised
-- administrative recovery: RaidService.RecoverLegacyRecord, with
-- NO remote wired to it (a normal client cannot invoke it — see
-- the static anchors in run.sh). It requires an explicitly
-- authorised operator (default: nobody), explicit target + owner
-- UserIds, both online, exactly-one-owner integrity, and verified
-- saves of both profiles. This file proves every refusal branch
-- and one successful recovery, and that the normal reconciler
-- leaves the legacy record flagged (rule (e)).
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

local function legacyRecord(instanceId, withOwner)
	local rec = {
		InstanceId = instanceId,
		CharacterId = "wobble_waffleton",
		Level = 5,
		Glitched = false,
		Mutation = "None",
		Slot = 2,
		StolenSlot = 2,
		StolenPlacedAt = os.time() - 1000,
		StolenBankedIncome = 500,
		InTransit = true,
	}
	if withOwner ~= nil then
		rec.StolenFromUserId = withOwner
	end
	return rec
end

local holder = R.newLoadedPlayer(env, 9491, 5000)
local owner = R.newLoadedPlayer(env, 9492, 5000)
local operator = R.newLoadedPlayer(env, 9493, 5000)
local legacyId = "legacy-inst-9491"
table.insert(DS.GetData(holder).OwnedInstances, legacyRecord(legacyId))
assert(DS.SaveData(holder) == true, "setup: holder save with the flagged record must land")

-- The normal reconciler never resolves a legacy record (rule (e)).
local resolvedE, remainingE = env.raid.RecoverStaleTransit(holder)
check("automatic recovery leaves the legacy record flagged (rule (e))",
	resolvedE == 0 and remainingE == 1)
check("the record is still flagged with the holder",
	H.findOwned(DS.GetData(holder), legacyId) ~= nil
		and H.findOwned(DS.GetData(holder), legacyId).InTransit == true)

-- No operators installed (the default): refused.
local ok0, err0 = env.raid.RecoverLegacyRecord(operator, holder.UserId, legacyId, owner.UserId)
check("recovery with no operators installed is refused",
	ok0 == false and err0 == "not authorised", "err=" .. tostring(err0))
check("nothing moved after the refused recovery",
	H.findOwned(DS.GetData(holder), legacyId) ~= nil
		and H.findOwned(DS.GetData(owner), legacyId) == nil)

-- An operator who is not in the authorised set: refused.
env.raid.SetLegacyRecoveryOperators({ 9499 })
local okU, errU = env.raid.RecoverLegacyRecord(operator, holder.UserId, legacyId, owner.UserId)
check("an unauthorised operator is refused",
	okU == false and errU == "not authorised", "err=" .. tostring(errU))

-- The authorised operator, explicit owner: succeeds.
env.raid.SetLegacyRecoveryOperators({ operator.UserId })
local ok, err = env.raid.RecoverLegacyRecord(operator, holder.UserId, legacyId, owner.UserId)
check("authorised recovery with an explicit owner succeeds", ok == true, "err=" .. tostring(err))
check("the holder no longer has the record",
	H.findOwned(DS.GetData(holder), legacyId) == nil)
local ownedRec = H.findOwned(DS.GetData(owner), legacyId)
check("the owner holds exactly one clean copy",
	ownedRec ~= nil and ownedRec.InTransit ~= true
		and ownedRec.StolenFromUserId == nil
		and H.countOwned(env, { holder, owner }, legacyId) == 1)
check("the owner's placed copy is restored from the Stolen* fields",
	H.findPlaced(DS.GetData(owner), legacyId) ~= nil)
check("both saves verified: holder's stored key has no record",
	H.findOwned(store:peek(P.mainKey(holder.UserId)), legacyId) == nil)
check("both saves verified: owner's stored key has the clean record",
	H.findOwned(store:peek(P.mainKey(owner.UserId)), legacyId) ~= nil
		and H.findOwned(store:peek(P.mainKey(owner.UserId)), legacyId).InTransit ~= true)

-- Repeating the recovery changes nothing (the record is gone).
local okAgain, errAgain = env.raid.RecoverLegacyRecord(operator, holder.UserId, legacyId, owner.UserId)
check("repeating the recovery is refused (no such record)",
	okAgain == false, "err=" .. tostring(errAgain))
check("exactly one owner still", H.countOwned(env, { holder, owner }, legacyId) == 1)

-- Refusal: another player already holds a clean copy.
local holder2 = R.newLoadedPlayer(env, 9494, 5000)
local owner2 = R.newLoadedPlayer(env, 9495, 5000)
local third = R.newLoadedPlayer(env, 9496, 5000)
local legacyId2 = "legacy-inst-9494"
table.insert(DS.GetData(holder2).OwnedInstances, legacyRecord(legacyId2))
local cleanCopy = legacyRecord(legacyId2)
cleanCopy.InTransit = nil
cleanCopy.StolenSlot = nil
cleanCopy.StolenPlacedAt = nil
cleanCopy.StolenBankedIncome = nil
table.insert(DS.GetData(third).OwnedInstances, cleanCopy)
local okDupe, errDupe = env.raid.RecoverLegacyRecord(operator, holder2.UserId, legacyId2, owner2.UserId)
check("recovery is refused when another player holds a clean copy",
	okDupe == false and errDupe == "another player already holds a clean copy",
	"err=" .. tostring(errDupe))
check("the flagged record stays flagged with its holder",
	H.findOwned(DS.GetData(holder2), legacyId2) ~= nil
		and H.findOwned(DS.GetData(holder2), legacyId2).InTransit == true)

-- Refusal: the record HAS a recorded owner (use the normal reconciler).
local holder3 = R.newLoadedPlayer(env, 9497, 5000)
local legacyId3 = "legacy-inst-9497"
table.insert(DS.GetData(holder3).OwnedInstances, legacyRecord(legacyId3, 9498))
local okOwned, errOwned = env.raid.RecoverLegacyRecord(operator, holder3.UserId, legacyId3, owner.UserId)
check("recovery is refused when the record has a recorded owner",
	okOwned == false and errOwned == "record has a recorded owner; use the normal reconciler",
	"err=" .. tostring(errOwned))

-- Refusal: the owner must be online (9999 was never created).
local okOff, errOff = env.raid.RecoverLegacyRecord(operator, holder2.UserId, legacyId2, 9999)
check("recovery is refused when the owner is offline",
	okOff == false and errOff == "owner must be online", "err=" .. tostring(errOff))

-- Refusal: no operator object at all.
local okNoOp, errNoOp = env.raid.RecoverLegacyRecord(nil, holder2.UserId, legacyId2, owner2.UserId)
check("recovery with no operator is refused",
	okNoOp == false and errNoOp == "operator required", "err=" .. tostring(errNoOp))

H.finish()
