-- m03_r5_3_old_logic.luau — R5-3 negative control.
-- Loads the PRE-R5 RaidService snapshot (mutant/RaidServiceR4.luau:
-- the void returns early when the cache holds no PendingRewards
-- entry, ignores the sidecar result, parks no instance tombstone,
-- and has no RetryPendingVoids) against the CURRENT DataService.
-- Each check asserts the OLD bad outcome: if this control passes,
-- the fixed test 03 genuinely detects the bug; if it fails, test 03
-- would pass even against broken code.
-- The two sections mirror test 03 §A (Qwen's reproduction) and §B
-- (unpersistable void reported as finished).
-- Run: bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh
local R5 = require("../r5_env")
local P = R5.P
local H = R5.H
local store = R5.store
local env = R5.newEnv({ raidPath = "./mutant/RaidServiceR4" })
local DS = env.dataService
local raid = env.raid

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local function failSetAsyncForKey(key)
	local orig = store.SetAsync
	store.SetAsync = function(self, k, value)
		if k == key then
			error("injected per-key SetAsync failure for " .. k)
		end
		return orig(self, k, value)
	end
	return function()
		store.SetAsync = orig
	end
end

local function setupPendingPair(thiefId, victimId)
	local pair = P.newLoadedPair(env, thiefId, victimId)
	H.steal(env, pair)
	assert(DS.SaveData(pair.victim) == true, "setup: victim steal-time save must land")
	assert(DS.SaveData(pair.thief) == true, "setup: thief mid-carry save must land")
	local restoreMain = failSetAsyncForKey(P.mainKey(pair.thief.UserId))
	local okDel, status = raid.ConfirmDelivery(pair.thief, pair.targetId)
	restoreMain()
	assert(okDel == true and status == "reward_pending",
		"setup: delivery must report reward_pending (status=" .. tostring(status) .. ")")
	local entry = DS.GetData(pair.thief).PendingRewards[pair.targetId]
	assert(type(entry) == "table" and type(entry.Txns) == "table",
		"setup: reward must be pending in cache")
	local txId = nil
	for id in pairs(entry.Txns) do
		txId = id
	end
	assert(txId ~= nil, "setup: pending reward must have a TxId")
	return pair, txId
end

-- --- (A) Qwen's reproduction under the OLD code --------------------
local pairA, txIdA = setupPendingPair(9631, 9632)
store:failGetAsyncForKey(P.pendingKey(pairA.thief.UserId), 2)
DS.LoadData(pairA.thief)
store:resetFailures()
local resA, remA, paidA, totalA = raid.RecoverOnRejoin(pairA.thief)
check("(A) OLD: rejoin resolves the stale transit with no void-durability signal",
	resA == 1 and remA == 0, "resolved=" .. tostring(resA) .. " remaining=" .. tostring(remA))
check("(A) OLD: no instance tombstone is parked (the void found no cache entry and returned)",
	(function()
		for _, e in ipairs(store:peek(P.pendingKey(pairA.thief.UserId)) or {}) do
			if type(e) == "table" and e.Voided == true and e.VoidInstance == true then
				return false
			end
		end
		return true
	end)())
check("(A) OLD: nothing is recorded voided in memory",
	type(DS.GetData(pairA.thief).VoidedRewardTxns) ~= "table"
		or DS.GetData(pairA.thief).VoidedRewardTxns[txIdA] == nil)
DS.LoadData(pairA.thief)
local pA, tA = raid.RecoverPendingRewards(pairA.thief)
check("(A) OLD: recovery after the sidecar becomes readable PAYS the voided reward",
	pA == 1 and tA == 300, "paid=" .. tostring(pA) .. " total=" .. tostring(tA))
check("(A) OLD: the thief farmed 300 coins from the voided delivery",
	(tonumber(DS.GetData(pairA.thief).Coins) or 0) == 100300,
	"coins=" .. tostring(DS.GetData(pairA.thief).Coins))

-- --- (B) The OLD code has no void retry and no durability signal --
check("(B) OLD: RetryPendingVoids does not exist",
	type(raid.RetryPendingVoids) ~= "function")

H.finish()
