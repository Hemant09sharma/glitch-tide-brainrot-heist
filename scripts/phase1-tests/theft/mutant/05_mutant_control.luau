-- 05_mutant_control.luau — R2 M8 negative control: the SAME
-- missing-owned-record assertions as the ConfirmDelivery guard, run
-- against the MUTANT RaidService (missing-record guard removed by
-- mutant/make_mutant.sh). This file is EXPECTED TO FAIL: the mutant
-- must proceed past the guard onto a nil owned record (indexing it
-- errors), which proves the test detects the missing guard.
--
-- The owned record is removed from the thief's data mid-transit
-- (simulating consumption mid-transit). The fixed code rejects the
-- delivery with "instance record missing" and leaves the transit
-- entry live — no reward paid, and re-inserting the record lets the
-- real delivery succeed afterwards. The mutant falls through and
-- errors indexing nil.
-- Never run under theft/run_all.sh — run via mutant/run_mutant.sh,
-- which inverts the exit code.
local H = require("../../harness")

local env = H.newEnv({ raidPath = "./theft/mutant/RaidServiceM8" })

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local pair = H.newPair(env, 975, 976)
H.steal(env, pair)
-- Remove the thief's owned record mid-transit; keep the reference so
-- it can be restored to prove the transit entry stayed live.
local removed: any = nil
for i, inst in ipairs(pair.thiefData.OwnedInstances) do
	if type(inst) == "table" and inst.InstanceId == pair.targetId then
		removed = inst
		table.remove(pair.thiefData.OwnedInstances, i)
		break
	end
end
assert(removed ~= nil, "owned record not found to remove")
assert(H.findOwned(pair.thiefData, pair.targetId) == nil, "record still present")

local coinsBefore = pair.thiefData.Coins
local pcallOk, okDel, status = pcall(function()
	return env.raid.ConfirmDelivery(pair.thief, pair.targetId)
end)
check("M: delivery with a missing owned record is rejected cleanly",
	pcallOk == true and okDel == false and status == "instance record missing",
	"pcallOk=" .. tostring(pcallOk) .. " ok=" .. tostring(okDel)
		.. " status=" .. tostring(status))
check("M: no reward paid by the rejected delivery",
	pair.thiefData.Coins == coinsBefore,
	"coins=" .. tostring(pair.thiefData.Coins))
-- Restore the record: the transit entry must still be live, so the
-- real delivery now succeeds and pays exactly once.
table.insert(pair.thiefData.OwnedInstances, removed)
local okDel2, status2 = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
check("M: delivery succeeds once the record is restored (transit stayed live)",
	okDel2 == true, "status=" .. tostring(status2))
check("M: reward paid exactly once after the restore (300 coins)",
	pair.thiefData.Coins == coinsBefore + 300,
	"coins=" .. tostring(pair.thiefData.Coins))
local owned = H.findOwned(pair.thiefData, pair.targetId)
check("M: delivered record carries the remainder (250)",
	owned ~= nil and owned.BankedIncome == 250,
	"BankedIncome=" .. tostring(owned and owned.BankedIncome))

H.finish()
