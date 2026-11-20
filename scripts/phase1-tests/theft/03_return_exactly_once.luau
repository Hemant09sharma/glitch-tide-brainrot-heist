-- 03_return_exactly_once.luau — steal -> return restores exactly one
-- original instance to the victim and zero copies remain with the thief.
-- Three return triggers: manual drop (CarryService.DropCarried),
-- direct ReturnStolen, and the 5s watchdog (PollInTransit after the
-- carry is silently cleared, past the 2s grace period). ReturnStolen is
-- also idempotent: a second call is a no-op, not a duplicate.
-- Run: lune run scripts/phase1-tests/theft/03_return_exactly_once.luau
local H = require("../harness")

local env = H.newEnv()

local function assertReturned(n, pair, label)
	local thiefData = pair.thiefData
	local victimData = pair.victimData
	H.check(n, label .. ": exactly one owned copy, back with the victim",
		H.countOwned(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findOwned(thiefData, pair.targetId) == nil
			and H.findOwned(victimData, pair.targetId) ~= nil,
		"thief=" .. tostring(H.countOwned(env, { pair.thief }, pair.targetId))
			.. " victim=" .. tostring(H.countOwned(env, { pair.victim }, pair.targetId)))
	H.check(n + 1, label .. ": exactly one placed copy, back on the victim's slot",
		H.countPlaced(env, { pair.thief, pair.victim }, pair.targetId) == 1
			and H.findPlaced(victimData, pair.targetId) ~= nil
			and H.findPlaced(thiefData, pair.targetId) == nil)
	local owned = H.findOwned(victimData, pair.targetId)
	H.check(n + 2, label .. ": InTransit flag cleared on the returned record",
		owned ~= nil and owned.InTransit ~= true)
	H.check(n + 3, label .. ": thief no longer carrying, attribute cleared",
		env.carry.IsCarrying(pair.thief) == false
			and pair.thief:GetAttribute("CarryingStolen") == "")
end

-- A: manual drop via CarryService (the real death/drop path).
local pairA = H.newPair(env, 121, 221)
H.steal(env, pairA)
local okDrop = env.carry.DropCarried(pairA.thief, "manual")
H.check(1, "A: manual drop succeeds", okDrop == true, "ok=" .. tostring(okDrop))
assertReturned(2, pairA, "A: manual drop")
local again = env.raid.ReturnStolen(pairA.targetId)
H.check(6, "A: second ReturnStolen is a no-op (no transit left)", again == false)
H.check(7, "A: still exactly one placed copy after the no-op return",
	H.countPlaced(env, { pairA.thief, pairA.victim }, pairA.targetId) == 1)

-- B: direct ReturnStolen. On every real trigger the carry is already
-- cleared (DropCarried clears it before calling DropStolen; the
-- watchdog only returns when the thief is no longer carrying), so the
-- carry is cleared first here too.
local pairB = H.newPair(env, 123, 223)
H.steal(env, pairB)
env.carry.ClearCarried(pairB.thief, true)
local okRet = env.raid.ReturnStolen(pairB.targetId)
H.check(8, "B: ReturnStolen succeeds", okRet == true, "ok=" .. tostring(okRet))
assertReturned(9, pairB, "B: direct return")

-- C: watchdog — carry silently cleared (missed death hook), 2s grace
-- passes, PollInTransit returns the Brainrot.
local pairC = H.newPair(env, 125, 225)
H.steal(env, pairC)
env.carry.ClearCarried(pairC.thief, true)
H.spinSeconds(2.2)
env.raid.PollInTransit()
assertReturned(13, pairC, "C: watchdog return")

H.finish()
