-- 08_merge_on_load_failure.luau — R3-1 (merge paths): when a sidecar
-- read fails at load, that sidecar must NOT merge and must NOT be
-- deleted by the later save, while the other sidecar still merges and
-- is deleted normally. A later load with the outage cleared then
-- merges the held-back sidecar and deletes it.
--
-- Failure injection is per-key here: the MAIN key's GetAsync must keep
-- working (a failed main load would skip the merge entirely for a
-- different, pre-existing reason), while the escrow key's GetAsync
-- fails on both readSidecar attempts.
-- Run: bash scripts/phase1-tests/persistence/run.sh
local P = require("./persistence_env")
local H = P.H
local store = P.store
local DS = P.loadDataService()

local n = 0
local function check(name, ok, detail)
	n += 1
	H.check(n, name, ok, detail)
end

local userId = 7081
local player = H.newPlayer(userId, "MergePlayer")

-- Last good save for this player (no escrow / pending entries in it).
store:seed(P.mainKey(userId), {
	Coins = 500,
	OwnedInstances = {},
	Base = { Placed = {} },
	LastLogin = 0,
})
-- Both sidecars hold entries.
local escrowRecord = P.escrowRecord("merge_esc")
store:seed(P.escrowKey(userId), { escrowRecord })
store:seed(P.pendingKey(userId), { P.pendingEntry("merge_p1", 300) })

-- Only the escrow key's reads fail (both readSidecar attempts).
store:failGetAsyncForKey(P.escrowKey(userId), 2)
local data = DS.LoadData(player)
check("main load still succeeds while the escrow read fails",
	type(data) == "table" and data.Coins >= 500)
check("pending sidecar still merges when the escrow read fails",
	type(data.PendingRewards) == "table"
		and data.PendingRewards["merge_p1"] ~= nil
		and data.PendingRewards["merge_p1"].Amount == 300)
check("failed escrow read merges nothing into OwnedInstances",
	H.findOwned(data, "merge_esc") == nil)
check("failed escrow read leaves the sidecar entries in place",
	P.findInList(store:peek(P.escrowKey(userId)), "merge_esc") ~= nil)
store:resetFailures()

local okSave = DS.SaveData(player)
check("save after the partial merge succeeds",
	okSave == true)
check("merged pending key is deleted after the successful save",
	store:peek(P.pendingKey(userId)) == nil)
check("unmerged escrow key is NOT deleted by that save",
	P.findInList(store:peek(P.escrowKey(userId)), "merge_esc") ~= nil)

-- Outage cleared: a fresh load merges the held-back escrow entry.
local data2 = DS.LoadData(player)
check("second load merges the held-back escrow entry",
	H.findOwned(data2, "merge_esc") ~= nil)
check("escrow merge restores the placed copy too",
	H.findPlaced(data2, "merge_esc") ~= nil
		and H.findPlaced(data2, "merge_esc").Slot == 2
		and H.findPlaced(data2, "merge_esc").BankedIncome == 500)
local function countOwned(data, instanceId)
	local c = 0
	for _, inst in ipairs(data.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == instanceId then
			c += 1
		end
	end
	return c
end
check("escrow record is owned exactly once after the delayed merge",
	countOwned(data2, "merge_esc") == 1)
check("pending reward is still present exactly once (no double merge)",
	type(data2.PendingRewards) == "table"
		and data2.PendingRewards["merge_p1"] ~= nil
		and data2.PendingRewards["merge_p1"].Amount == 300)
local okSave2 = DS.SaveData(player)
check("second save succeeds",
	okSave2 == true)
check("escrow key is deleted after the save of the merged data",
	store:peek(P.escrowKey(userId)) == nil)

H.finish()
