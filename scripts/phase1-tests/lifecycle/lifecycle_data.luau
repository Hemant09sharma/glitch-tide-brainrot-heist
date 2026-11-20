-- lifecycle_data.luau — fake DataService implementing the NEW (R2-5)
-- DataService contract, for the lifecycle suite only.
--
-- It mirrors the real DataService.luau semantics that the lifecycle
-- fix depends on (the real module cannot load under Lune: it requires
-- ReplicatedStorage Config + a DataStore):
--   * PlayerRemoving: registered pre-save hooks run FIRST, then ONE
--     save, then the cache is cleared (connectLeaveHandler).
--   * BindToClose equivalent: shutdownAll runs the hooks for every
--     player, then saves each (runHooks, then saves — never save,
--     then recover).
--   * SaveData snapshots a deep copy into _saved (the stand-in for
--     the DataStore key), refuses when the session's load failed, and
--     deletes merged sidecar entries only after a successful save.
--   * EscrowReturnedInstance / RecordPendingRewardSidecar park
--     recovery payloads in per-UserId sidecar lists; simulateLoad
--     (the stand-in for LoadData) merges them idempotently.
--   * simulateCrash wipes every in-memory cache (and only that) so a
--     test can reload from the saved snapshots + sidecars, exactly as
--     a server restart would.
-- A "no escrow" variant is available via L.newNoEscrowDataService()
-- (same fake minus the escrow API) to prove the keep-in-transit
-- fallback when no sidecar exists.
local L: { [string]: any } = {}

local function deepCopy(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local copy: { [string]: any } = {}
	for k, v in pairs(t) do
		copy[k] = deepCopy(v)
	end
	return copy
end

function L.deepCopy(t: any): any
	return deepCopy(t)
end

local function mergeEscrowRecord(data: any, record: any): boolean
	if type(record) ~= "table" or type(record.InstanceId) ~= "string" then
		return false
	end
	if type(data.OwnedInstances) ~= "table" then
		data.OwnedInstances = {}
	end
	local owned: any = nil
	for _, inst in ipairs(data.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == record.InstanceId then
			owned = inst
			break
		end
	end
	local merged = false
	if owned == nil then
		owned = deepCopy(record)
		owned.InTransit = nil
		owned.StolenFromUserId = nil
		owned.StolenSlot = nil
		owned.StolenPlacedAt = nil
		owned.StolenBankedIncome = nil
		table.insert(data.OwnedInstances, owned)
		merged = true
	end
	if record.Placed == true then
		if type(data.Base) ~= "table" then
			data.Base = { Placed = {} }
		end
		if type(data.Base.Placed) ~= "table" then
			data.Base.Placed = {}
		end
		local placed: any = nil
		for _, entry in ipairs(data.Base.Placed) do
			if type(entry) == "table" and entry.InstanceId == record.InstanceId then
				placed = entry
				break
			end
		end
		if placed == nil then
			local occupied: { [number]: boolean } = {}
			for _, entry in ipairs(data.Base.Placed) do
				if type(entry) == "table" then
					occupied[math.floor(tonumber(entry.Slot) or 0)] = true
				end
			end
			local slot = math.floor(tonumber(record.Slot) or 0)
			if slot < 1 or occupied[slot] then
				slot = 0
				for candidate = 1, 24 do
					if not occupied[candidate] then
						slot = candidate
						break
					end
				end
				if slot == 0 then
					slot = math.floor(tonumber(record.Slot) or 1)
				end
			end
			table.insert(data.Base.Placed, {
				InstanceId = record.InstanceId,
				CharacterId = record.CharacterId,
				Slot = slot,
				Level = tonumber(record.Level) or 1,
				Glitched = record.Glitched == true,
				Mutation = record.Mutation,
				BankedIncome = tonumber(record.BankedIncome) or 0,
				PlacedAt = tonumber(record.PlacedAt) or os.time(),
				Evolved = record.Evolved,
				EvolutionId = record.EvolutionId,
				EvolvedTrait = record.EvolvedTrait,
				EvolvedFormName = record.EvolvedFormName,
				TraitLevels = deepCopy(record.TraitLevels),
			})
			owned.Placed = true
			owned.Slot = slot
			merged = true
		end
	end
	return merged
end

-- R3 merge helpers, mirroring DataService.pendingTxId /
-- pendingEntryTxns exactly: a sidecar entry is keyed by its TxId
-- (legacy entries without one fall back to
-- "legacy-<InstanceId>-<CreatedAt>"), and a pending entry that
-- predates the Txns table is backfilled from its own aggregate.
local function pendingTxId(entry: any): string
	if type(entry.TxId) == "string" and entry.TxId ~= "" then
		return entry.TxId
	end
	return "legacy-" .. tostring(entry.InstanceId) .. "-" .. tostring(entry.CreatedAt or 0)
end

local function pendingEntryTxns(existing: any, instanceId: string): { [string]: number }
	if type(existing.Txns) == "table" then
		return existing.Txns
	end
	local txns: { [string]: number } = {}
	txns[pendingTxId(existing)] = math.floor(tonumber(existing.Amount) or 0)
	existing.Txns = txns
	return txns
end

function L.new(opts: any?): any
	opts = opts or {}
	local datas: { [any]: any } = {}
	local saved: { [any]: any } = {}
	local saves: { [any]: number } = {}
	local hooks: { (any) -> () } = {}
	local escrow: { [number]: { any } } = {}
	local pendingSidecar: { [number]: { any } } = {}
	local merged: { [any]: boolean } = {}
	local loadFailed: { [any]: boolean } = {}
	local saveable = true
	local ds: { [string]: any } = {}
	ds._datas = datas
	ds._saved = saved
	ds._saves = saves
	ds._hooks = hooks
	ds._escrow = escrow
	ds._pendingSidecar = pendingSidecar
	ds._merged = merged
	ds._loadFailed = loadFailed

	function ds.Ensure(player, data)
		datas[player] = data
	end
	function ds.GetOrLoad(player)
		return datas[player]
	end
	function ds.GetData(player)
		return datas[player]
	end
	function ds.AddCoins(player, amount)
		local d = datas[player]
		if d then
			d.Coins = (tonumber(d.Coins) or 0) + amount
			return d.Coins
		end
		return nil
	end
	function ds.AddXP(player, amount)
		local d = datas[player]
		if d then
			d.XP = (tonumber(d.XP) or 0) + amount
		end
	end
	function ds.UnlockCharacter(player, characterId)
		local d = datas[player]
		if not d then
			return
		end
		if type(d.Unlocked) ~= "table" then
			d.Unlocked = {}
		end
		if table.find(d.Unlocked, characterId) == nil then
			table.insert(d.Unlocked, characterId)
		end
	end
	function ds.IsSaveable(player)
		if loadFailed[player] then
			return false
		end
		return saveable
	end
	function ds.setSaveable(value: boolean)
		saveable = value
	end
	function ds.setLoadFailed(player, value: boolean)
		if value then
			loadFailed[player] = true
		else
			loadFailed[player] = nil
		end
	end
	function ds.SaveData(player)
		local data = datas[player]
		if not data then
			return false
		end
		if loadFailed[player] then
			return false
		end
		-- The real DataService refuses saves exactly when the session
		-- cannot persist (load failed); the fake's setSaveable(false)
		-- models that same state, so it refuses too.
		if not saveable then
			return false
		end
		saved[player] = deepCopy(data)
		saves[player] = (saves[player] or 0) + 1
		if merged[player] then
			escrow[player.UserId] = nil
			pendingSidecar[player.UserId] = nil
			merged[player] = nil
		end
		return true
	end
	function ds.RegisterPreSaveHook(fn)
		if type(fn) ~= "function" then
			return false
		end
		for _, existing in ipairs(hooks) do
			if existing == fn then
				return true
			end
		end
		table.insert(hooks, fn)
		return true
	end
	-- Simulate DataService.Init's PlayerRemoving handler: hooks first,
	-- then the one save, then the cache is cleared. Must be connected
	-- BEFORE H.newEnv (production: DataService.Init runs before
	-- GameManager.Init, so this handler is connected first).
	function ds.connectLeaveHandler()
		local Players = game:GetService("Players")
		Players.PlayerRemoving:Connect(function(player)
			for _, fn in ipairs(hooks) do
				pcall(fn, player)
			end
			ds.SaveData(player)
			datas[player] = nil
			merged[player] = nil
			loadFailed[player] = nil
		end)
	end
	-- Simulate DataService's BindToClose: hooks for every player
	-- first, then the saves.
	function ds.shutdownAll(players)
		for _, player in ipairs(players) do
			for _, fn in ipairs(hooks) do
				pcall(fn, player)
			end
		end
		for _, player in ipairs(players) do
			ds.SaveData(player)
		end
	end
	if opts.noEscrow ~= true then
		function ds.EscrowReturnedInstance(victimUserId, record)
			local userId = tonumber(victimUserId)
			if not userId or type(record) ~= "table" or type(record.InstanceId) ~= "string" then
				return false
			end
			local list = escrow[userId] or {}
			escrow[userId] = list
			for _, entry in ipairs(list) do
				if type(entry) == "table" and entry.InstanceId == record.InstanceId then
					return true
				end
			end
			table.insert(list, deepCopy(record))
			return true
		end
	end
	function ds.RecordPendingRewardSidecar(player, entry)
		if not player or type(entry) ~= "table" or type(entry.InstanceId) ~= "string" then
			return false
		end
		local list = pendingSidecar[player.UserId] or {}
		pendingSidecar[player.UserId] = list
		for _, existing in ipairs(list) do
			if type(existing) == "table" and existing.InstanceId == entry.InstanceId then
				existing.Amount = (tonumber(existing.Amount) or 0) + (tonumber(entry.Amount) or 0)
				return true
			end
		end
		table.insert(list, deepCopy(entry))
		return true
	end
	-- Simulate LoadData from the saved snapshot + sidecar merge.
	function ds.simulateLoad(player)
		local snapshot = saved[player]
		if not snapshot then
			return nil
		end
		local data = deepCopy(snapshot)
		datas[player] = data
		local didMerge = false
		local escrowList = escrow[player.UserId]
		if type(escrowList) == "table" then
			for _, record in ipairs(escrowList) do
				if mergeEscrowRecord(data, record) then
					didMerge = true
				end
			end
		end
		local pendingList = pendingSidecar[player.UserId]
		if type(pendingList) == "table" then
			if type(data.PendingRewards) ~= "table" then
				data.PendingRewards = {}
			end
			if type(data.ProcessedRewardTxns) ~= "table" then
				data.ProcessedRewardTxns = {}
			end
			-- R3 merge (mirrors DataService.mergeSidecars pending
			-- loop): dedup by TxId, skip already-processed TxIds,
			-- and track each merged transaction in the entry's
			-- Txns table — a same-TxId re-merge is a no-op, never
			-- a second payment.
			for _, entry in ipairs(pendingList) do
				if type(entry) == "table" and type(entry.InstanceId) == "string" then
					local amount = math.floor(tonumber(entry.Amount) or 0)
					if amount > 0 then
						local txId = pendingTxId(entry)
						if data.ProcessedRewardTxns[txId] == nil then
							local existing = data.PendingRewards[entry.InstanceId]
							if type(existing) == "table" then
								local txns = pendingEntryTxns(existing, entry.InstanceId)
								if txns[txId] == nil then
									txns[txId] = amount
									existing.Amount = (tonumber(existing.Amount) or 0) + amount
									didMerge = true
								end
								-- Same TxId already pending: a
								-- re-merge of the same recording —
								-- no-op.
							else
								data.PendingRewards[entry.InstanceId] = {
									InstanceId = entry.InstanceId,
									CharacterId = entry.CharacterId,
									Amount = amount,
									Reason = entry.Reason,
									CreatedAt = entry.CreatedAt,
									Txns = { [txId] = amount },
								}
								didMerge = true
							end
						end
						-- Processed TxId: already paid (its coin
						-- change and marker were persisted together
						-- in the main profile) — skip, never pay
						-- again.
					end
				end
			end
		end
		if didMerge then
			merged[player] = true
		end
		return data
	end
	-- Simulate a server crash: every in-memory cache is gone; saved
	-- snapshots + sidecars (the DataStore stand-ins) survive.
	function ds.simulateCrash()
		for player in pairs(datas) do
			datas[player] = nil
		end
		for player in pairs(merged) do
			merged[player] = nil
		end
	end
	return ds
end

-- Same fake minus the escrow API (older DataService): the victim-offline
-- return must then keep the record in transit instead of escrowing.
function L.newNoEscrowDataService(): any
	return L.new({ noEscrow = true })
end

return L
