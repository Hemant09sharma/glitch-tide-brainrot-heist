-- 05_r4_6_txid_guid.luau — R4-6 (P2, Test F):
-- The R3 TxId (sr-<user>-<instance>-<unix>-<clockMs>-<counter>)
-- was probabilistic: two servers minting in the same millisecond
-- with the same counter could collide. The R4-6 fix mints
-- sr-<guid>-<user>-<instance>-<counter> /
-- rt-<guid>-<victim>-<instance>-<counter> with
-- HttpService:GenerateGUID(false) (128-bit random, server
-- independent); the per-server counter is belt-and-braces only.
-- A retry of the same transaction keeps the same id (proven by the
-- same-TxId restore in test 02; here the ledger-level property is
-- asserted again: a second mint is always a NEW transaction).
-- Two module instances (RaidService + RaidServiceB) stand in for
-- two servers: each has its own counter starting at 0, so any
-- distinctness across them must come from the GUID, not the
-- counter. The harness stub's GenerateGUID returns
-- "guid-<os.clock digits>"; production Roblox returns a real GUID.
-- Run: bash scripts/phase1-tests/r4-transactions/run.sh
local R = require("./r4_env")
local P = R.P
local H = R.H
local env = R.newEnv()
local envB = R.newEnv({ raidPath = "./services/RaidServiceB" })
local DS = env.dataService

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local thief = H.newPlayer(9451, "Thief9451", 30, Vector3.new(0, 0, 0))
local victimId = 9452
local instanceId = "t9451v9452_target"

-- Extract the GUID segment (between the "sr-"/"rt-" prefix and the
-- "-<userId>-" that follows it).
local function guidSegment(id, prefix, userId)
	local rest = string.sub(id, #prefix + 2)
	local marker = "-" .. tostring(userId) .. "-"
	local cut = string.find(rest, marker, 1, true)
	if not cut then
		return nil
	end
	return string.sub(rest, 1, cut - 1)
end

-- 200 reward ids from server A, same player + instance.
local rewardIds = {}
local rewardGuids = {}
for _ = 1, 200 do
	local id = env.raid.DebugRewardTxId(thief, instanceId)
	table.insert(rewardIds, id)
	local guid = guidSegment(id, "sr", thief.UserId)
	if guid ~= nil then
		rewardGuids[guid] = true
	end
end
local distinctReward = {}
for _, id in ipairs(rewardIds) do
	distinctReward[id] = true
end
local distinctRewardCount = 0
for _ in pairs(distinctReward) do
	distinctRewardCount += 1
end
local distinctGuidCount = 0
for _ in pairs(rewardGuids) do
	distinctGuidCount += 1
end
check("200 reward TxIds for the same Brainrot are all distinct", distinctRewardCount == 200, "distinct=" .. tostring(distinctRewardCount))
check("distinctness comes from the GUID, not the counter (200 distinct GUID segments)",
	distinctGuidCount == 200, "distinctGuids=" .. tostring(distinctGuidCount))
check("reward TxIds keep the sr- prefix, user id and instance id",
	string.sub(rewardIds[1], 1, 3) == "sr-"
		and string.find(rewardIds[1], "-" .. tostring(thief.UserId) .. "-", 1, true) ~= nil
		and string.find(rewardIds[1], instanceId, 1, true) ~= nil,
	"sample=" .. tostring(rewardIds[1]))
check("reward TxIds carry a GUID/fallback segment (not the old all-numeric shape)",
	guidSegment(rewardIds[1], "sr", thief.UserId) ~= nil
		and (string.find(rewardIds[1], "guid-", 1, true) ~= nil or string.find(rewardIds[1], "fb-", 1, true) ~= nil))

-- 200 return ids from server A, same victim + instance.
local returnIds = {}
for _ = 1, 200 do
	table.insert(returnIds, env.raid.DebugReturnTxId(victimId, instanceId))
end
local distinctReturn = {}
for _, id in ipairs(returnIds) do
	distinctReturn[id] = true
end
local distinctReturnCount = 0
for _ in pairs(distinctReturn) do
	distinctReturnCount += 1
end
check("200 return TxIds for the same Brainrot are all distinct", distinctReturnCount == 200, "distinct=" .. tostring(distinctReturnCount))
check("return TxIds keep the rt- prefix, victim id and instance id",
	string.sub(returnIds[1], 1, 3) == "rt-"
		and string.find(returnIds[1], "-" .. tostring(victimId) .. "-", 1, true) ~= nil
		and string.find(returnIds[1], instanceId, 1, true) ~= nil,
	"sample=" .. tostring(returnIds[1]))

-- Reward and return ids for the same instance never collide.
local overlap = false
for _, id in ipairs(returnIds) do
	if distinctReward[id] then
		overlap = true
	end
end
check("reward and return TxId sets are disjoint", overlap == false)

-- Two servers (two module instances, each counter starting at 0):
-- 100 ids each, same player + instance — all 200 distinct.
local crossIds = {}
for _, id in ipairs(rewardIds) do
	crossIds[id] = true
end
local crossCount = distinctRewardCount
for _ = 1, 100 do
	local id = envB.raid.DebugRewardTxId(thief, instanceId)
	if crossIds[id] == nil then
		crossIds[id] = true
		crossCount += 1
	end
end
check("two servers minting for the same Brainrot never collide (200 distinct across both)",
	crossCount == 300, "distinct=" .. tostring(crossCount))
-- Two different players, same instance: distinct.
local thief2 = H.newPlayer(9453, "Thief9453", 30, Vector3.new(0, 0, 0))
local otherId = env.raid.DebugRewardTxId(thief2, instanceId)
check("different players minting for the same Brainrot get distinct ids",
	crossIds[otherId] == nil and string.find(otherId, "-" .. tostring(thief2.UserId) .. "-", 1, true) ~= nil)

-- A retry keeps the same id: the ledger property (test 02 proves
-- the end-to-end restore). Here, the minted id for a delivery is
-- the one stored in the pending entry — minting again is a NEW
-- transaction, never a silent reuse of the stored id.
local pair = P.newLoadedPair(env, 9454, 9455)
H.steal(env, pair)
local okDel, statusDel = env.raid.ConfirmDelivery(pair.thief, pair.targetId)
assert(okDel == true and statusDel == nil, "setup: delivery must pay (status=" .. tostring(statusDel) .. ")")
local storedTxId = nil
for id in pairs(DS.GetData(pair.thief).ProcessedRewardTxns or {}) do
	storedTxId = id
end
local freshMint = env.raid.DebugRewardTxId(pair.thief, pair.targetId)
check("a fresh mint is a new transaction, not a reuse of the stored id",
	storedTxId ~= nil and freshMint ~= storedTxId)
check("the stored id is still the one the delivery paid with",
	DS.GetData(pair.thief).ProcessedRewardTxns[storedTxId] ~= nil)

H.finish()
