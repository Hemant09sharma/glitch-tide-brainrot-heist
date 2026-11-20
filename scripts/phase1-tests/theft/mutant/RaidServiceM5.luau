--!strict
-- RaidService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Stealing + base defenses, all validated server-side.
--
-- STEAL FLOW (StealBrainrot remote, victim must be online):
--   request -> protection checks -> 3s channel (thief must stay within
--   8 studs of the channel anchor; moving / dying cancels) -> success:
--   the Brainrot leaves the victim's base and becomes "stolen, in
--   transit" (tracked in _inTransit, thief's character carries a
--   CarryingStolen attribute, and the OwnedInstances record moves to
--   the thief as an in-transit hold so BaseService.PlaceBrainrot can
--   accept it in the thief's base). The moved record itself carries
--   InTransit = true while the theft is unresolved, so no other
--   system (fusion, mutation, lab, carry) can consume or mutate it;
--   the flag clears only when ConfirmDelivery / ReturnStolen commits. Ownership is confirmed when the
--   thief places it in their own base — detected by a 5s watchdog
--   poll (PollInTransit; BaseService/CarryService never call back),
--   or directly via ConfirmDelivery. If the thief dies or drops it
--   first, the record moves back and it returns to the victim's
--   original base slot (ReturnStolen).
--
-- PROTECTIONS (IsProtected): victim level < 3, victim account age < 7
-- days, victim would be left with 0 placed Brainrots, target placed
-- < 120s ago, base shield active, or lockdown active.
--
-- BASE DEFENSES: shield (timed, blocks steal), gate (must be open for
-- a non-owner to enter), guard NPCs (RegisterGuard hook for NPCService),
-- lockdown (owner-triggered, 30s, costs coins, blocks entry).
--
-- OPTIONAL DEPENDENCIES: BaseService and CarryService are optional Init
-- args and are never hard-required. Without BaseService, placed targets
-- are read from the victim's data.Base.Placed (Types.PlacedBrainrot
-- shape; data.Placed is the legacy fallback)
-- and base positions fall back to the map "Bases" folder, then to the
-- victim's character position. Without CarryService, carrying is tracked
-- in _inTransit + the CarryingStolen attribute only. MutationService /
-- QuestService may be passed via the optional `opts` table
-- ({MutationService=..., QuestService=...}) for instance-accurate
-- ownership transfer and quest events. ExpeditionService is wired via
-- SetExpeditionService (GameManager's cross-link pass calls it); it is
-- only used for the orphaned-expedition-flag clear in ReturnStolen, and
-- the inline fallback covers the unwired case.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")

local Config = require("../shared/Config")
local Economy = require("../shared/Economy")
local Remotes = require("../shared/Remotes")

local _names: any = Remotes.Names

local RaidService = {}

local _dataService: any = nil
local _baseService: any = nil
local _carryService: any = nil
local _mutationService: any = nil
local _questService: any = nil
-- Optional: ExpeditionService (SetExpeditionService). Only used for the
-- R2 orphaned-flag clear in ReturnStolen; the inline fallback in this
-- file covers the unwired case.
local _expeditionService: any = nil

local STEAL_CHANNEL = Config.StealChannelSeconds or 3
local STEAL_COOLDOWN = Config.StealCooldownSeconds or 60
local CHANNEL_RADIUS = 8
local NEW_PLAYER_LEVEL = 3
local NEW_ACCOUNT_DAYS = 7
local RECENT_PLACE_SECONDS = 120
local LOCKDOWN_DURATION = Config.BaseLockDuration or 30
local LOCKDOWN_COST = Config.LockdownCost or 250
local LOCKDOWN_COOLDOWN = Config.LockdownCooldownSeconds or 120
local SHIELD_DURATION = Config.ShieldDurationSeconds or 60
local SHIELD_COST = Config.ShieldCost or 100

-- [thiefUserId .. ":" .. victimUserId] = os.clock() of last attempt.
local _pairCooldowns: { [string]: number } = {}
-- [instanceId] = full steal snapshot: Thief, Victim, CharacterId,
-- Level, Mutation, Glitched, Evolved, EvolutionId, EvolvedTrait,
-- EvolvedFormName, TraitLevels (copied), Slot, PlacedAt, BankedIncome,
-- StolenAt. Every field the return path needs to restore the victim's
-- placed copy exactly — nothing is re-derived at return time.
local _inTransit: { [string]: any } = {}
-- [ownerUserId] = os.clock() until which the shield / lockdown is active.
local _shields: { [number]: number } = {}
local _lockdowns: { [number]: number } = {}
local _lockdownCooldowns: { [number]: number } = {}
-- [ownerUserId] = open? (default open).
local _gates: { [number]: boolean } = {}
-- [ownerUserId] = { npcModel, ... } (registered via RegisterGuard).
local _guards: { [number]: { Model } } = {}
-- [thief] = active channel record (cancelled by movement / death).
local _channels: { [Player]: any } = {}
local _stunned: { [Humanoid]: boolean } = {}
local _rate: { [Player]: number } = {}
-- R3-6: pre-save-hook depth. While > 0, ReturnStolen is running
-- inside HandlePlayerLeaving — i.e. inside DataService's pre-save
-- hook (leave) or the shutdown recovery — and the coordinated
-- leave / shutdown save that follows is the single save owner, so
-- ReturnStolen must not save anyone (see the save-ownership note in
-- ReturnStolen). The escrow park above is still the crash backstop
-- on that path. A counter, not a boolean, so interleaved leaves
-- nest correctly; HandlePlayerLeaving decrements it on both paths.
local _preSaveHookDepth = 0
-- R5-3: [Player] = {[InstanceId] = {txIds = {...}}} — reward voids
-- whose tombstone AND fallback main-profile save both failed (see
-- voidPendingRewardsForInstance). They stay pending for retry
-- (RetryPendingVoids) instead of silently leaving a payable reward
-- behind. In-memory only: a void that lands on neither leg before a
-- crash is the documented W4-analog window (see the R5 report).
local _pendingVoids: { [Player]: { [string]: any } } = {}

local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function rateOk(player: Player, key: string, interval: number): boolean
	if Security and Security.RateLimit then
		local ok, allowed = pcall(function()
			return Security.RateLimit(player, key, interval)
		end)
		if ok then
			return allowed
		end
	end
	local now = os.clock()
	local last = _rate[player] or -math.huge
	if now - last < interval then
		return false
	end
	_rate[player] = now
	return true
end

local function sanitize(id: any): string?
	if Security and Security.SanitizeId then
		local ok, clean = pcall(function()
			return Security.SanitizeId(id)
		end)
		if ok then
			return clean
		end
	end
	if type(id) ~= "string" or #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
end

local function getRemote(name: string): RemoteEvent?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function getData(player: Player): any
	if not _dataService then
		return nil
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Base / placed lookups (BaseService first, data.Placed / map fallback).
-- ---------------------------------------------------------------------------

local function getPlacedList(victim: Player): { any }
	if _baseService and type(_baseService.GetPlaced) == "function" then
		local ok, list = pcall(function()
			return _baseService.GetPlaced(victim)
		end)
		if ok and type(list) == "table" then
			return list
		end
	end
	local data = getData(victim)
	if data then
		-- Placed Brainrots live in data.Base.Placed (BaseService's
		-- shape); data.Placed is the legacy fallback.
		if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
			return data.Base.Placed
		end
		if type(data.Placed) == "table" then
			return data.Placed
		end
	end
	return {}
end

local function findPlaced(victim: Player, instanceId: string): any
	for _, placed in ipairs(getPlacedList(victim)) do
		if type(placed) == "table" and placed.InstanceId == instanceId then
			return placed
		end
	end
	return nil
end

local function removeFromPlacedList(data: any, instanceId: string): boolean
	local lists: { { any } } = {}
	if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
		table.insert(lists, data.Base.Placed)
	end
	if type(data.Placed) == "table" then
		table.insert(lists, data.Placed)
	end
	for _, list in ipairs(lists) do
		for index, placed in ipairs(list) do
			if type(placed) == "table" and placed.InstanceId == instanceId then
				table.remove(list, index)
				return true
			end
		end
	end
	return false
end

local function removePlaced(victim: Player, instanceId: string): boolean
	if _baseService and type(_baseService.RemovePlaced) == "function" then
		local ok, result = pcall(function()
			return _baseService.RemovePlaced(victim, instanceId)
		end)
		if ok and result then
			return true
		end
	end
	local data = getData(victim)
	if data then
		return removeFromPlacedList(data, instanceId)
	end
	return false
end

-- Find the OwnedInstances record for `instanceId` in `player`'s data.
local function findOwnedRecord(player: Player, instanceId: string): any
	local data = getData(player)
	if not data or type(data.OwnedInstances) ~= "table" then
		return nil
	end
	for _, inst in ipairs(data.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == instanceId then
			return inst
		end
	end
	return nil
end

-- Remove the OwnedInstances record for `instanceId` from `player`'s
-- data (used only for the victim-left destroy branch of ReturnStolen).
local function destroyOwnedRecord(player: Player, instanceId: string)
	if _mutationService and type(_mutationService.RemoveInstance) == "function" then
		pcall(function()
			_mutationService.RemoveInstance(player, instanceId)
		end)
		return
	end
	local data = getData(player)
	if data and type(data.OwnedInstances) == "table" then
		for index, inst in ipairs(data.OwnedInstances) do
			if type(inst) == "table" and inst.InstanceId == instanceId then
				table.remove(data.OwnedInstances, index)
				break
			end
		end
	end
end

-- Keep an owned record's Placed flag in sync with a (re)inserted
-- placed copy. Uses MutationService.SetPlaced when linked (its
-- documented contract), and always writes the flag directly too.
local function syncOwnedPlaced(player: Player, instanceId: string, placed: boolean, slot: number)
	if _mutationService and type(_mutationService.SetPlaced) == "function" then
		pcall(function()
			_mutationService.SetPlaced(player, instanceId, placed, slot)
		end)
	end
	local owned = findOwnedRecord(player, instanceId)
	if owned then
		owned.Placed = placed == true
		owned.Slot = placed == true and slot or 0
	end
end

-- Find a placed copy of `instanceId` in `data` (Base.Placed first,
-- legacy data.Placed second). Returns the live table or nil.
local function findPlacedInData(data: any, instanceId: string): any
	local lists: { { any } } = {}
	if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
		table.insert(lists, data.Base.Placed)
	end
	if type(data.Placed) == "table" then
		table.insert(lists, data.Placed)
	end
	for _, list in ipairs(lists) do
		for _, placed in ipairs(list) do
			if type(placed) == "table" and placed.InstanceId == instanceId then
				return placed
			end
		end
	end
	return nil
end

-- R2-3: reconcile an already-existing placed copy of a delivered
-- Brainrot FROM the updated owned record. Used by ConfirmDelivery,
-- and only when such a copy already exists — the watchdog path
-- (PollInTransit saw the instance placed in the thief's base). In the
-- normal PlaceBrainrot path no placed copy exists yet at
-- ConfirmDelivery time (PlaceBrainrot rejects "already placed" before
-- calling ConfirmDelivery, and builds the copy afterwards from the
-- updated owned record), so this is a strict no-op there. Updates in
-- place — never inserts, so a repeat run can never duplicate the copy
-- — then syncs owned.Placed / Slot, clears the thief's carry state
-- (the delivery is confirmed; the stolen carry must not survive it)
-- and rebuilds the base models so the displayed model matches the
-- corrected fields. Returns true iff a placed copy was found and
-- reconciled.
local function reconcilePlacedCopy(thief: Player, instanceId: string, owned: any): boolean
	local data = getData(thief)
	if not data then
		return false
	end
	local placed = findPlacedInData(data, instanceId)
	if not placed then
		return false
	end
	placed.Level = tonumber(owned.Level) or tonumber(placed.Level) or 1
	placed.Glitched = owned.Glitched == true
	-- R3-6 (Worker B residual): prefer the owned Mutation, but keep
	-- the placed copy's own Mutation when the owned record has none
	-- (a legacy seeded instance whose Mutation was never mirrored
	-- onto the owned record) — unconditionally overwriting it with
	-- nil would wipe a mutation the placed copy legitimately holds.
	-- The same owned-wins-with-placed-fallback rule the steal
	-- snapshot already uses (R2-1). The other fields need no
	-- fallback: ConfirmDelivery writes them onto the owned record
	-- from the snapshot first, and the placed copy never carries
	-- evolution fields of its own.
	placed.Mutation = owned.Mutation or placed.Mutation
	placed.Evolved = owned.Evolved
	placed.EvolutionId = owned.EvolutionId
	placed.EvolvedTrait = owned.EvolvedTrait
	placed.EvolvedFormName = owned.EvolvedFormName
	if type(owned.TraitLevels) == "table" then
		local traitLevels: { [string]: number } = {}
		for traitId, level in pairs(owned.TraitLevels) do
			traitLevels[traitId] = level
		end
		placed.TraitLevels = traitLevels
	end
	placed.BankedIncome = tonumber(owned.BankedIncome) or 0
	placed.PlacedAt = tonumber(owned.PlacedAt) or placed.PlacedAt
	syncOwnedPlaced(thief, instanceId, true, tonumber(placed.Slot) or 0)
	if _carryService and type(_carryService.ClearCarried) == "function" then
		pcall(function()
			_carryService.ClearCarried(thief, true)
		end)
	end
	if _baseService and type(_baseService.RebuildBase) == "function" then
		pcall(function()
			_baseService.RebuildBase(thief)
		end)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- R2-4 (R13) + R3-3 / R3-4 / R3-5: a steal-reward failure must not
-- silently lose the reward, and a recovered reward must never pay twice.
-- ---------------------------------------------------------------------------
-- What can actually fail (verified against DataService, not assumed):
--   * DataService.AddCoins itself essentially never throws: it mutates
--     the in-memory cache and returns the new balance; its load path
--     pcalls the DataStore read. A pcall around it therefore catches
--     only a defensive / mocked failure — but the ledger covers that
--     too, so a future AddCoins change cannot silently drop a reward.
--   * What REALLY fails is persistence: when the DataStore load failed
--     at join, DataService sets _loadFailed and SaveData REFUSES to
--     persist for the whole session, so coins "paid" into that phantom
--     cache vanish on leave. DataService.IsSaveable (added for R13)
--     exposes that state; when it is false the grant is NOT minted
--     into the phantom cache at all — it is recorded pending instead.
--   * R3-5: a saveable session whose saves ALL fail. The old code paid
--     into the cache, trusted the autosave, and reported success — so
--     a reward whose save never landed was "paid" and then lost on
--     leave. A transient failure is still recovered by the next
--     autosave, but a reward must not be CONSIDERED durably paid on
--     AddCoins alone: the commit below verifies the save and rolls the
--     payment back to pending when the save fails.
--
-- LEDGER (R3-3 transaction identity). Every reward recording is one
-- transaction with a unique, stable TxId (newRewardTxId: one per
-- delivery/reward event — a Brainrot stolen and delivered twice in its
-- lifetime gets two TxIds, so the two rewards are never confused with
-- a duplicate attempt of one transaction).
--   * data.PendingRewards[InstanceId] = one AGGREGATE entry per stolen
--     instance: {InstanceId, CharacterId, Amount, Reason, CreatedAt,
--     Txns = {[TxId] = deltaAmount}}. Amount is the sum of the
--     entry's not-yet-paid recordings; Txns is the dedupe set.
--   * data.ProcessedRewardTxns[TxId] = {TxId, InstanceId, Amount,
--     PaidAt} — the durable proof that transaction was paid. It is
--     written into the SAME data table as the coin change and the
--     pending-entry removal, so one SaveData persists all three
--     together (atomic within the main profile key).
--   * The pending sidecar holds one entry per recording:
--     {TxId, InstanceId, CharacterId, Amount = delta, Reason,
--     CreatedAt}. DataService merges it by TxId and skips any TxId
--     already processed or already pending, so a failed sidecar
--     deletion can never re-pay a reward on rejoin.
-- R3-4 semantics (DELTA model): recordPendingReward adds ONE
-- recording's delta once to the cache aggregate AND once to the
-- sidecar under the same TxId. It never passes an accumulated total
-- to the sidecar (the old bug: 100 then +150 was passed as 250 and
-- the sidecar accumulated it to 350). Re-recording the SAME TxId is
-- a replay and is a no-op in both places; a NEW TxId for the same
-- instance is a new transaction and adds its delta.
-- Recovery is RaidService.RecoverPendingRewards, called on rejoin
-- (see Init) and retryable at any time; it pays each aggregate entry
-- once through commitPendingPayment (pay + mark every TxId processed
-- + remove the entry + verify the save, with rollback on failure).
--
-- R3-5 CRASH WINDOWS (see also grantStealReward / commitPendingPayment).
-- The commit is: (1) park the pending entry in the sidecar FIRST
-- (durable leg 1), (2) pay in memory + mark TxIds processed + remove
-- the pending entry (one data table), (3) verify with a synchronous
-- SaveData (durable leg 2). The windows:
--   W1 — crash after (1), before (2)/(3): the sidecar holds the
--     entry, the stored profile has no Processed marker, so the next
--     load merges it and recovery pays it exactly once. CLOSED.
--   W2 — crash after (2) in memory, before (3) completes: same as
--     W1 — the stored profile never saw the payment, the sidecar
--     entry survives, rejoin pays once. CLOSED. (Note the delivery
--     itself is equally unpersisted in this window, so a voided
--     delivery and a recovered reward can coincide — see the report.)
--   W3 — (3) fails (every save fails): the commit rolls the payment
--     back in memory (un-pay, un-mark, restore the pending entry)
--     and returns "reward_pending"; the sidecar entry parked in (1)
--     is the durable backstop, so a later recovery / rejoin pays it
--     exactly once. CLOSED (for the save-failure case).
--   W4 — the sidecar park in (1) itself fails (UpdateAsync outage)
--     AND the server then crashes before any main save succeeds: the
--     reward exists only in the in-memory cache and is lost. OPEN —
--     durability needs at least one of the two keys to accept a
--     write; when both are unwritable nothing can persist it. The
--     commit still degrades safely: the pay proceeds, the sync save
--     is verified, and on save failure the entry stays pending in
--     cache for retry (it is lost only on a crash, not on a save
--     failure alone).
--   W5 — CROSS-KEY LIMIT (honest): the coin change + Processed
--     marker are atomic ONLY within the main profile key (one
--     SetAsync). The sidecar is a separate key; there is no moment
--     when both keys change atomically. A stale sidecar entry left
--     behind after a durable pay is therefore possible (it is
--     neutralised by the Processed check on re-merge and deleted on
--     the next load + save), and two servers writing the same
--     player's main key concurrently can still last-write-win (the
--     pre-existing DataStore limitation, unchanged by R3).
-- The Processed ledger is never pruned: one small entry per paid
-- reward, bounded in practice (a stale sidecar entry is deleted on
-- the next load + save, so the ledger only grows by genuinely paid
-- rewards). The steal-reward AMOUNT itself is unchanged: it is still
-- computed exactly once per delivery by Economy.StealReward in
-- ConfirmDelivery (StealRewardShare + rarity bonus); the commit only
-- moves that already-computed amount.

local _rewardTxCounter = 0
local _returnTxCounter = 0
-- Forward declaration: newReturnTxId is defined with the R3-6
-- return-transaction block below, but DebugReturnTxId (next to
-- DebugRewardTxId) needs the name in scope here. Assigned below —
-- never redeclared there, or this closure would capture nil.
local newReturnTxId: (number, string) -> string

-- R4-6: collision-resistant transaction ids. Both generators use
-- HttpService:GenerateGUID(false) — a 128-bit random GUID minted by
-- the server, independent of wall-clock time, per-server counters
-- and server identity, so two servers can never mint the same id for
-- different transactions by sharing a timestamp. The user id,
-- instance id and a per-server counter are appended as belt and
-- braces (they make ids traceable and keep ids distinct even if a
-- GUID source ever repeated). No cryptographic guarantee is claimed
-- beyond what GenerateGUID provides. Fallback (GenerateGUID
-- unavailable): the old timestamp/counter shape plus a random
-- suffix — probabilistic only, and warned about when used.
local function newGuid(): string
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and type(guid) == "string" and guid ~= "" then
		return guid
	end
	warn("[RaidService] GenerateGUID unavailable; using probabilistic fallback TxId")
	return string.format("fb-%d-%d-%d-%d",
		os.time(), math.floor(os.clock() * 1000),
		_rewardTxCounter, math.random(1, 2147483647))
end

-- newRewardTxId(player, instanceId): a UNIQUE, STABLE id for one
-- delivery/reward event. Format "sr-<guid>-<thiefUserId>-
-- <instanceId>-<perServerCounter>". The id is created once per
-- grantStealReward call (or once per ConfirmDelivery, which passes
-- it to the grant — see ConfirmDelivery) and then stored in the
-- cache entry, the sidecar entry and the Processed ledger, so every
-- leg of the transaction can recognise the same event. A retry of
-- the same transaction reuses this id; a new delivery mints a new
-- one, even for the same Brainrot in the same second.
local function newRewardTxId(player: Player, instanceId: string): string
	_rewardTxCounter += 1
	return string.format("sr-%s-%d-%s-%d",
		newGuid(), player.UserId, tostring(instanceId), _rewardTxCounter)
end

-- DebugRewardTxId / DebugReturnTxId: test accessors for the
-- generators (the r4-transactions suite asserts distinctness across
-- repeated creation and controlled server identities). Production
-- code never calls these.
function RaidService.DebugRewardTxId(player: Player, instanceId: string): string
	return newRewardTxId(player, instanceId)
end

function RaidService.DebugReturnTxId(victimUserId: number, instanceId: string): string
	return newReturnTxId(victimUserId, instanceId)
end

-- legacyRewardTxId(instanceId, createdAt): the id of a pre-R3 pending
-- entry, which carries no TxId. MUST match DataService.pendingTxId
-- exactly ("legacy-<InstanceId>-<CreatedAt>"), so a legacy reward
-- merged by DataService and recovered here is recognised as the same
-- transaction.
local function legacyRewardTxId(instanceId: string, createdAt: any): string
	return "legacy-" .. tostring(instanceId) .. "-" .. tostring(tonumber(createdAt) or 0)
end

local function ensureProcessedLedger(data: any): { [string]: any }
	if type(data.ProcessedRewardTxns) ~= "table" then
		data.ProcessedRewardTxns = {}
	end
	return data.ProcessedRewardTxns
end

-- pendingTxns(entry, instanceId): the entry's per-transaction
-- sub-ledger (TxId -> delta amount). A legacy entry (no Txns) is
-- normalised to one implicit transaction — its legacy id, for its
-- full Amount — so recovery treats it exactly like a TxId entry.
local function pendingTxns(entry: any, instanceId: string): { [string]: number }
	if type(entry.Txns) == "table" then
		return entry.Txns
	end
	local txns: { [string]: number } = {}
	txns[legacyRewardTxId(instanceId, entry.CreatedAt)] =
		math.floor(tonumber(entry.Amount) or 0)
	entry.Txns = txns
	return txns
end

-- saveVerified(player): synchronous durability check for a reward
-- commit. Returns true iff DataService.SaveData reports success. The
-- real DataService returns an explicit boolean; a stub / older
-- DataService whose SaveData returns nil (no boolean at all) is
-- treated as success — it models an in-memory store that cannot fail,
-- and the pre-R3 behaviour (trust the save) is preserved for it. An
-- explicit false, or a thrown error, is a failure, and the caller
-- must roll the payment back. No SaveData method at all (no
-- persistence layer) is also success — there is nothing to verify
-- against and paying in memory is the only option.
local function saveVerified(player: Player): boolean
	if not _dataService or type(_dataService.SaveData) ~= "function" then
		return true
	end
	local ok, result = pcall(function()
		return _dataService.SaveData(player)
	end)
	if not ok then
		return false
	end
	if result == nil then
		return true
	end
	return result == true
end

-- commitPendingPayment(player, instanceId, entry): pay one pending
-- aggregate entry DURABLY, exactly once. Steps (all in the one data
-- table, then one verified save): pay the sum of the entry's
-- not-yet-processed, not-voided transactions, mark exactly those
-- TxIds processed, remove the pending entry. Returns (true,
-- amountPaid) iff the payment is durable — amountPaid is the coins
-- actually paid now — or (true, 0) when every transaction in the
-- entry was already processed or voided (a stale entry alongside
-- its markers is dropped without paying; callers must use
-- amountPaid, not the entry's Amount, for their totals). Returns
-- (false, 0) when AddCoins fails, and when the save fails — in the
-- save-failure case the in-memory changes are rolled back first
-- (un-pay, un-mark, restore the entry), so a later recovery or a
-- rejoin pays it exactly once; the sidecar entry parked before the
-- pay is the durable backstop.
-- R4-4: a TxId in data.VoidedRewardTxns is never paid — its delivery
-- was voided on recovery (see voidPendingRewardsForInstance), so
-- paying it would farm a reward for a Brainrot the thief does not
-- own. A voided TxId is dropped with the entry, never re-queued.
-- R4-3: the rollback-clamp hole. The old code credited the reward,
-- then SaveData yielded while retrying a failed save, during which a
-- concurrent purchase could spend the credited coins; the rollback
-- AddCoins(-payable) then clamped at zero and the pending entry was
-- restored — so recovery paid the same reward again on top of the
-- value already spent. The fix is a coin reservation
-- (DataService.ReserveCoins): the credited amount is reserved BEFORE
-- the save runs, so every debit through AddCoins can spend only the
-- balance above the reservation and the credited coins are provably
-- still there when the rollback releases the reservation and
-- subtracts exactly. Reserve failure is fail-closed: the credit is
-- un-paid at once and the commit returns false with the entry
-- pending. Rollback order is fail-safe: the reservation is released
-- FIRST (dropping the debit floor), then the exact subtraction —
-- if even that throws, the markers stay and the entry stays deleted
-- (state: "paid in memory, awaiting a save"), which cannot
-- double-pay in session and still recovers exactly once on rejoin
-- through the sidecar, instead of restoring the entry on top of
-- paid coins.
local function commitPendingPayment(player: Player, instanceId: string, entry: any): (boolean, number)
	local data = getData(player)
	if not data then
		return false, 0
	end
	local processed = ensureProcessedLedger(data)
	local voided = data.VoidedRewardTxns
	local txns = pendingTxns(entry, instanceId)
	local payable = 0
	local toMark: { [string]: number } = {}
	for txId, delta in pairs(txns) do
		if processed[txId] == nil
			and (type(voided) ~= "table" or voided[txId] == nil)
			-- R5-3: a TxId of a voided INSTANCE is never paid
			-- either, even when the void never named this TxId
			-- (its sidecar read failed when the void was recorded).
			and (type(data.VoidedRewardInstances) ~= "table"
				or data.VoidedRewardInstances[instanceId] == nil)
		then
			local amount = math.floor(tonumber(delta) or 0)
			if amount > 0 then
				payable += amount
				toMark[txId] = amount
			end
		end
	end
	if payable <= 0 then
		-- Every transaction in this entry is already processed or
		-- voided (or amounts to nothing): drop the stale entry
		-- without paying.
		data.PendingRewards[instanceId] = nil
		saveVerified(player)
		return true, 0
	end
	local ok, result = pcall(function()
		return _dataService.AddCoins(player, payable)
	end)
	if not ok or type(result) ~= "number" then
		return false, 0
	end
	-- R4-3: reserve the credited amount before the save can yield.
	local reserveKey = "reward:" .. instanceId
	local reserved = false
	if _dataService and type(_dataService.ReserveCoins) == "function" then
		local okRes, resOk = pcall(function()
			return _dataService.ReserveCoins(player, reserveKey, payable)
		end)
		reserved = okRes and resOk == true
		if not reserved then
			-- Fail closed: un-pay at once (no save has run, so the
			-- subtraction is exact) and leave the entry pending.
			pcall(function()
				_dataService.AddCoins(player, -payable)
			end)
			warn("[RaidService] Reward commit refused for " .. player.Name
				.. " (" .. tostring(instanceId)
				.. "): could not reserve " .. tostring(payable) .. " coins; entry stays pending")
			return false, 0
		end
	end
	for txId, delta in pairs(toMark) do
		processed[txId] = {
			TxId = txId,
			InstanceId = instanceId,
			Amount = delta,
			PaidAt = os.time(),
		}
	end
	data.PendingRewards[instanceId] = nil
	if saveVerified(player) then
		if reserved then
			pcall(function()
				_dataService.ReleaseReservation(player, reserveKey)
			end)
		end
		return true, payable
	end
	-- The save failed: roll the in-memory payment back. Release the
	-- reservation FIRST, so the debit floor drops and the exact
	-- subtraction cannot clamp (the reserved coins are provably
	-- still in the balance: no debit could spend them while the
	-- reservation held).
	if reserved then
		pcall(function()
			_dataService.ReleaseReservation(player, reserveKey)
		end)
	end
	local rollbackOk = pcall(function()
		_dataService.AddCoins(player, -payable)
	end)
	if rollbackOk then
		for txId in pairs(toMark) do
			processed[txId] = nil
		end
		data.PendingRewards[instanceId] = entry
	else
		warn("[RaidService] Reward rollback failed for " .. player.Name
			.. " (" .. tostring(instanceId)
			.. "); markers kept, entry not restored — the sidecar copy is the rejoin backstop")
	end
	return false, 0
end
local function isSaveable(player: Player): boolean
	if _dataService and type(_dataService.IsSaveable) == "function" then
		local ok, saveable = pcall(function()
			return _dataService.IsSaveable(player)
		end)
		if ok then
			return saveable == true
		end
	end
	-- Unknown (older DataService / test stub without the accessor):
	-- assume saveable; the pcall around AddCoins below is the backstop.
	return true
end

-- ---------------------------------------------------------------------------
-- R5-2 (P0): session-health gate for ownership-changing operations.
-- ---------------------------------------------------------------------------
-- A session is UNHEALTHY when DataService says it cannot save — the
-- R5-4 machinery: GetSaveBlockedReason names the reason
-- ("load_failed" | "session_contested" | "session_lost"). That
-- local state is checked first (no DataStore traffic): it catches
-- every session that was already unhealthy at load, and every
-- session a previous save already flagged as lost. The check reads
-- GetSaveBlockedReason ONLY, not the IsSaveable boolean: for the
-- real DataService the two are exactly equivalent (same three
-- flags — see sessionBlockedReason), and a bare-IsSaveable
-- DataService (theft/lifecycle stubs) keeps the established
-- healthy fallback, preserving their R2-4/R3-5 reward-pending
-- behaviour.
--
-- The local state alone is NOT enough at a commit point: a lease can
-- be taken over since the last check (another server acquiring it
-- while this theft is in flight) without any flag being set here
-- yet. So the gate ALSO proves ownership against the STORED lease
-- via the existing R5-4 acquire path (DataService.AcquireSessionLease
-- — a conditional UpdateAsync that keeps a live foreign lease and
-- returns false for it; it re-acquires / heartbeats our own lease,
-- it never overwrites another server's). The probe is fail-closed:
-- an errored or refused probe refuses the operation. It is used at
-- the steal/delivery commit points only — the two places where an
-- unverified lease can lose or duplicate an instance — not on every
-- read. One UpdateAsync per party per check; steals are already
-- rate-limited and cooldown-gated, so the extra write is bounded.
--
-- The gate applies to StealBrainrot (both parties, before the
-- channel AND again after it, before anything moves) and to
-- ConfirmDelivery (both parties, before the escrow invalidation —
-- a refused delivery parks no tombstone). It deliberately does NOT
-- apply to the recovery paths: ReturnStolen, RecoverStaleTransit,
-- RecoverOnRejoin and RecoverPendingRewards must still run in
-- unhealthy sessions, because they RESTORE ownership — blocking
-- them would strand or destroy the Brainrot the gate exists to
-- protect (see the R5-2 report section). PlaceBrainrot's
-- whole-record reinsert shape (the recovery restore) is likewise
-- exempt in BaseService; only its player-driven paths are gated.
--
-- When the DataService has no lease API at all (older DataService /
-- test stub), the probe is skipped and the local check is the gate —
-- the same fallback isSaveable above already uses.
local function sessionBlockedReason(player: Player): string?
	-- The R5-4 reason API is the ONLY local signal the gate
	-- consults. For the real DataService it is exactly equivalent
	-- to IsSaveable (GetSaveBlockedReason, DataService.luau:721,
	-- returns non-nil iff one of _loadFailed / _sessionContested /
	-- _sessionLost is set; IsSaveable, :2240, is false iff one of
	-- the same three flags is set), so nothing is lost by reading
	-- the reason instead of the boolean. The distinction matters
	-- only for a DataService WITHOUT the reason API — an older /
	-- stub DataService that reports unsaveability through a bare
	-- IsSaveable flag (theft test 11 §B monkey-patches exactly
	-- that; lifecycle test 06's stub has IsSaveable + setSaveable
	-- and no reason API). Those suites model the R2-4/R3-5
	-- reward-pending behaviour (delivery succeeds, reward recorded
	-- pending, recovery pays exactly once on rejoin), which R5-2
	-- does not ask to change; the established fallback for a
	-- missing accessor is healthy (the same fallback isSaveable
	-- above and the lease probe below already use), so the gate
	-- passes there and the production gate — real DataService,
	-- reason API present — stays broad: every unsaveable delivery
	-- is refused.
	if _dataService and type(_dataService.GetSaveBlockedReason) == "function" then
		local ok, reason = pcall(function()
			return _dataService.GetSaveBlockedReason(player)
		end)
		if ok and type(reason) == "string" and reason ~= "" then
			return reason
		end
	end
	return nil
end

local function verifySessionLease(player: Player): (boolean, string?)
	if not _dataService or type(_dataService.AcquireSessionLease) ~= "function" then
		return true
	end
	local ok, acquired = pcall(function()
		return _dataService.AcquireSessionLease(player)
	end)
	if not ok then
		return false, "session lease unverified"
	end
	if acquired ~= true then
		return false, "session lease lost"
	end
	return true
end

-- checkSessionHealth(player, role): (true) iff this player's
-- session may take part in an ownership change right now. Returns
-- (false, reason) otherwise; the reason names the role ("thief" /
-- "victim") and the R5-4 blocker, so a refused steal / delivery
-- explains itself instead of looking like a gameplay rejection.
local function checkSessionHealth(player: Player, role: string): (boolean, string?)
	local blocked = sessionBlockedReason(player)
	if blocked ~= nil then
		return false, role .. " session cannot save: " .. blocked
	end
	local leaseOk, leaseReason = verifySessionLease(player)
	if not leaseOk then
		return false, role .. " " .. tostring(leaseReason)
	end
	return true
end

-- R5-2 test-only hook for the steal channel (same pattern as
-- DataService._TestSetWaitHook): when set, it is called once per
-- channel iteration, pcall-guarded. The r5-transactions suite uses
-- it to take the thief's lease mid-channel and prove the
-- post-channel gate refuses the steal. Never set in production.
local _testStealChannelHook: ((Player, string) -> ())? = nil

function RaidService._TestSetStealChannelHook(fn: ((Player, string) -> ())?)
	_testStealChannelHook = fn
end

local function ensurePendingRewards(data: any): { [string]: any }
	if type(data.PendingRewards) ~= "table" then
		data.PendingRewards = {}
	end
	return data.PendingRewards
end

-- Record one reward recording as pending (R3-4 DELTA model). `amount`
-- is this recording's delta, under `txId` (generated by
-- grantStealReward, one per delivery event; a fresh id is minted when
-- the caller passes none). The delta is added ONCE to the in-cache
-- aggregate for the instance, and the SAME delta under the SAME TxId
-- is parked in the DataStore sidecar — never the accumulated total.
-- Re-recording the same TxId is a replay and is a no-op in both
-- places; a new TxId for the same instance is a new transaction and
-- adds its delta to the aggregate. The sidecar park is best-effort
-- and pcall-guarded (R3-5 park-first: it runs for saveable sessions
-- too, not only unsaveable ones — it is the durable backstop if the
-- main-profile save then fails).
-- R4-2: the park result is CHECKED and PRESERVED, not ignored. The
-- entry's ParkedTxns sub-ledger records, per TxId, whether the
-- sidecar append actually landed; a failed park leaves the TxId
-- explicitly unparked so RetryPendingParks (recovery, rejoin, leave)
-- retries exactly that TxId — same id, same delta, idempotent
-- (appendSidecar dedupes by TxId, so a re-park of an already-parked
-- TxId is a no-op). A new TxId is NEVER minted merely because a
-- write failed. Returns false only when there is no data to record
-- into or the amount is not positive.
local function recordPendingReward(player: Player, instanceId: string, characterId: string, amount: number, reason: string, txId: string?): boolean
	local data = getData(player)
	if not data then
		return false
	end
	local delta = math.floor(tonumber(amount) or 0)
	if delta <= 0 then
		return false
	end
	local id = txId
	if type(id) ~= "string" or id == "" then
		id = newRewardTxId(player, instanceId)
	end
	local pending = ensurePendingRewards(data)
	local existing = pending[instanceId]
	if type(existing) == "table" then
		local txns = pendingTxns(existing, instanceId)
		if txns[id] ~= nil then
			-- Same TxId already recorded: a replay, not a new
			-- reward — no-op (do not add the delta again, do not
			-- re-park; the sidecar already holds this TxId).
			return true
		end
		txns[id] = delta
		existing.Amount = (tonumber(existing.Amount) or 0) + delta
		existing.Reason = reason
	else
		pending[instanceId] = {
			InstanceId = instanceId,
			CharacterId = characterId,
			Amount = delta,
			Reason = reason,
			CreatedAt = os.time(),
			Txns = { [id] = delta },
		}
	end
	-- Park the DELTA (not the aggregate) under the same TxId, so a
	-- re-merge can recognise it and a second recording for the same
	-- instance lands as its own transaction. The RESULT is recorded
	-- (R4-2): a failed append leaves ParkedTxns[id] false, and
	-- RetryPendingParks retries it later with the same TxId.
	local parked = false
	if _dataService and type(_dataService.RecordPendingRewardSidecar) == "function" then
		local deltaEntry = {
			TxId = id,
			InstanceId = instanceId,
			CharacterId = characterId,
			Amount = delta,
			Reason = reason,
			CreatedAt = os.time(),
		}
		local okCall, stored = pcall(function()
			return _dataService.RecordPendingRewardSidecar(player, deltaEntry)
		end)
		parked = okCall and stored == true
		if not parked then
			warn("[RaidService] Pending-reward sidecar park FAILED for " .. player.Name
				.. " (" .. tostring(instanceId) .. ", TxId " .. tostring(id)
				.. "); the reward stays pending in cache and the park will be retried on recovery")
		end
	end
	local aggregate = pending[instanceId]
	if type(aggregate) == "table" then
		if type(aggregate.ParkedTxns) ~= "table" then
			aggregate.ParkedTxns = {}
		end
		aggregate.ParkedTxns[id] = parked
	end
	return true
end

-- RetryPendingParks(player): R4-2 retry the sidecar park for every
-- pending TxId whose park has not landed. Same TxId, same delta,
-- idempotent re-park. Returns (parkedNow, stillUnparked). Safe to
-- call at any time (rejoin, leave/shutdown pre-save hook, manual
-- retry); a no-op when every pending TxId is already parked or
-- there is no sidecar API (older DataService / test stub).
function RaidService.RetryPendingParks(player: Player): (number, number)
	if not player or not player:IsA("Player") then
		return 0, 0
	end
	local data = getData(player)
	if not data or type(data.PendingRewards) ~= "table" then
		return 0, 0
	end
	if not _dataService or type(_dataService.RecordPendingRewardSidecar) ~= "function" then
		return 0, 0
	end
	local parkedNow = 0
	local stillUnparked = 0
	for instanceId, entry in pairs(data.PendingRewards) do
		if type(entry) == "table" then
			local txns = pendingTxns(entry, instanceId)
			if type(entry.ParkedTxns) ~= "table" then
				entry.ParkedTxns = {}
			end
			for txId, delta in pairs(txns) do
				if entry.ParkedTxns[txId] ~= true then
					local okCall, stored = pcall(function()
						return _dataService.RecordPendingRewardSidecar(player, {
							TxId = txId,
							InstanceId = instanceId,
							CharacterId = entry.CharacterId,
							Amount = math.floor(tonumber(delta) or 0),
							Reason = entry.Reason,
							CreatedAt = entry.CreatedAt,
						})
					end)
					if okCall and stored == true then
						entry.ParkedTxns[txId] = true
						parkedNow += 1
					else
						stillUnparked += 1
					end
				end
			end
		end
	end
	return parkedNow, stillUnparked
end

-- Grant the steal reward, or record it pending when the grant cannot
-- durably succeed. Returns (true, nil) when paid, (false,
-- "reward_pending") when recorded pending. Never reports "paid" for an
-- unpaid reward: the caller (ConfirmDelivery) surfaces the status.
-- R3-5: "paid" means DURABLY paid, not merely AddCoins in memory.
-- One TxId is minted for this delivery event (or supplied by the
-- caller — ConfirmDelivery mints it first so the same id can also
-- name the R4-1 delivery tombstone), then: (1) the reward is
-- recorded pending — cache aggregate + sidecar park, so the
-- transaction exists durably before any coin moves (crash window W1);
-- (2) the pending entry is committed through commitPendingPayment
-- (pay + mark the TxId processed + remove the entry + verify the
-- save). If the session cannot persist, step (1) is the whole grant
-- and the reward waits for rejoin. If AddCoins throws, the entry
-- stays pending (cache + sidecar). If the save fails, the commit
-- rolls the payment back to pending. The amount is NOT recomputed
-- here: `reward` is Economy.StealReward from ConfirmDelivery.
local function grantStealReward(thief: Player, instanceId: string, characterId: string, reward: number, givenTxId: string?): (boolean, string?)
	if reward <= 0 then
		return true, nil
	end
	local txId = givenTxId
	if type(txId) ~= "string" or txId == "" then
		txId = newRewardTxId(thief, instanceId)
	end
	if not isSaveable(thief) then
		recordPendingReward(thief, instanceId, characterId, reward,
			"session cannot persist (DataStore load failed)", txId)
		warn("[RaidService] Steal reward for " .. thief.Name
			.. " recorded pending (session unsaveable): " .. tostring(reward) .. " coins")
		return false, "reward_pending"
	end
	if not recordPendingReward(thief, instanceId, characterId, reward, "steal reward", txId) then
		-- No data to record into (essentially unreachable from
		-- ConfirmDelivery, which already read the thief's cache):
		-- fall back to a direct AddCoins attempt, as before R3.
		local ok, result = pcall(function()
			return _dataService.AddCoins(thief, reward)
		end)
		if ok and type(result) == "number" then
			return true, nil
		end
		warn("[RaidService] Steal reward payment failed for " .. thief.Name
			.. "; no ledger to record it in: " .. tostring(reward) .. " coins")
		return false, "reward_pending"
	end
	local data = getData(thief)
	local entry = data and data.PendingRewards and data.PendingRewards[instanceId] or nil
	if type(entry) ~= "table" then
		return true, nil
	end
	if commitPendingPayment(thief, instanceId, entry) then
		return true, nil
	end
	warn("[RaidService] Steal reward for " .. thief.Name
		.. " recorded pending (payment or save failed): " .. tostring(reward) .. " coins")
	return false, "reward_pending"
end

-- R2: clear a stale OnExpedition flag on a Brainrot returned to its
-- victim. Preferred path is ExpeditionService.ClearOrphanedExpeditionFlag
-- (wired via SetExpeditionService; GameManager's cross-link pass calls
-- that setter automatically) — it is a no-op when the victim has a
-- legitimate Active expedition for the instance. The inline fallback
-- below does the same check directly against the victim's data, so the
-- recovery works even when ExpeditionService is not wired. Must run
-- only after the return has committed (owned record back, InTransit
-- cleared); never touches a live expedition.
local function clearOrphanedExpeditionFlag(victim: Player, instanceId: string, owned: any)
	if _expeditionService and type(_expeditionService.ClearOrphanedExpeditionFlag) == "function" then
		pcall(function()
			_expeditionService.ClearOrphanedExpeditionFlag(victim, instanceId)
		end)
	end
	-- Fallback (no ExpeditionService): clear only when the victim has
	-- NO Active expedition entry for this instance.
	local data = getData(victim)
	if data and type(data.Expeditions) == "table" then
		local active = data.Expeditions.Active
		if type(active) == "table" and tostring(active.InstanceId) == instanceId then
			return
		end
	end
	if owned then
		owned.OnExpedition = nil
	end
end

local function reinsertPlaced(victim: Player, placed: any, enforceOwnership: boolean?)
	-- Insert into the REAL placed table (data.Base.Placed) and rebuild
	-- the base models. BaseService.PlaceBrainrot cannot be used here:
	-- it requires the victim to be carrying the Brainrot and standing
	-- at the pedestal, which is false for a return.
	-- (That applies to the player-action shapes; the whole-record
	-- shape is preferred via reinsertPlacedFull below. This is the
	-- fallback when BaseService is unlinked or its reinsert fails.)
	local data = getData(victim)
	if not data then
		return false
	end
	-- R3-6 (Worker B residual): mirror BaseService.reinsertPlacedRecord's
	-- ownership guard (R3-8) here — but ONLY for the return fallback
	-- (reinsertPlacedFull calls this with enforceOwnership ~= false).
	-- A whole-record reinsert must never plant a Brainrot the player
	-- does not own. A legitimate return always passes: the owned
	-- record was moved back to the victim and the theft markers cleared
	-- BEFORE reinserting. Anything else is refused instead of risking
	-- a duplicated Brainrot in a stranger's base; the owned record
	-- itself stays safe in inventory.
	-- The steal-rollback caller passes enforceOwnership == false on
	-- purpose: it restores a placed copy that was removed from this
	-- very base moments ago (the pre-steal state), and the owned
	-- record may be missing precisely because the transfer just
	-- failed and lost it — refusing there would strand the victim
	-- with neither copy (see theft test 07 scenario D). The guard
	-- belongs to the return path, where the record must be back
	-- with the victim before anything is planted.
	if enforceOwnership ~= false then
		local owned = findOwnedRecord(victim, placed.InstanceId)
		if owned == nil then
			warn("[RaidService] Reinsert refused for " .. victim.Name
				.. ": " .. tostring(placed.InstanceId) .. " is not in their owned instances")
			return false
		end
		if owned.InTransit == true then
			warn("[RaidService] Reinsert refused for " .. victim.Name
				.. ": " .. tostring(placed.InstanceId) .. " is in transit (stolen)")
			return false
		end
		local stolenFrom = tonumber(owned.StolenFromUserId)
		if stolenFrom ~= nil and stolenFrom ~= victim.UserId then
			warn("[RaidService] Reinsert refused for " .. victim.Name
				.. ": " .. tostring(placed.InstanceId) .. " is stolen from another player")
			return false
		end
		if owned.CharacterId ~= nil and placed.CharacterId ~= nil
			and owned.CharacterId ~= placed.CharacterId then
			warn("[RaidService] Reinsert refused for " .. victim.Name
				.. ": " .. tostring(placed.InstanceId) .. " character does not match owned record")
			return false
		end
	end
	local list: { any }
	if type(data.Base) == "table" then
		if type(data.Base.Placed) ~= "table" then
			data.Base.Placed = {}
		end
		list = data.Base.Placed
	else
		if type(data.Placed) ~= "table" then
			data.Placed = {}
		end
		list = data.Placed
	end
	-- Never insert a second placed copy of the same instance:
	-- a retried return must be a no-op, not a duplicate.
	for _, existing in ipairs(list) do
		if type(existing) == "table" and existing.InstanceId == placed.InstanceId then
			return true
		end
	end
	-- Slot freedom: the original slot may be occupied by now
	-- (the victim placed something else there mid-theft). Fall
	-- back to the first free slot; if none is free in the
	-- scanned range, keep the original slot number so the
	-- record is preserved in data even with no pedestal.
	local occupied: { [number]: boolean } = {}
	for _, existing in ipairs(list) do
		if type(existing) == "table" then
			occupied[math.floor(tonumber(existing.Slot) or 0)] = true
		end
	end
	local slot = math.floor(tonumber(placed.Slot) or 0)
	if slot < 1 or occupied[slot] then
		slot = 0
		for candidate = 1, 24 do
			if not occupied[candidate] then
				slot = candidate
				break
			end
		end
		if slot == 0 then
			slot = math.floor(tonumber(placed.Slot) or 1)
		end
	end
	-- Full-fidelity restore: every field captured at steal time,
	-- including mutation, evolution / trait fields, banked income
	-- and the ORIGINAL PlacedAt (resetting it would re-arm the
	-- 120s recently-placed protection on a Brainrot the victim
	-- has owned all along).
	table.insert(list, {
		InstanceId = placed.InstanceId,
		CharacterId = placed.CharacterId,
		Slot = slot,
		Level = tonumber(placed.Level) or 1,
		Glitched = placed.Glitched == true,
		Mutation = placed.Mutation,
		BankedIncome = tonumber(placed.BankedIncome) or 0,
		PlacedAt = tonumber(placed.PlacedAt) or os.time(),
		Evolved = placed.Evolved,
		EvolutionId = placed.EvolutionId,
		EvolvedTrait = placed.EvolvedTrait,
		EvolvedFormName = placed.EvolvedFormName,
		TraitLevels = placed.TraitLevels,
	})
	syncOwnedPlaced(victim, placed.InstanceId, true, slot)
	if _baseService and type(_baseService.RebuildBase) == "function" then
		pcall(function()
			_baseService.RebuildBase(victim)
		end)
	end
	return true
end

-- Restore a stolen Brainrot's placed copy, preferring
-- BaseService.PlaceBrainrot's whole-record shape (it handles slot
-- fallback, syncs the owned Placed flag and rebuilds the base
-- models). That path builds a fixed-field placed table, so the
-- evolution / trait fields it drops are topped up afterwards on the
-- returned (inserted) record. Falls back to the local reinsert
-- above when BaseService is unlinked or its reinsert fails. Never
-- throws; returns false only when no path restored the copy — the
-- owned record itself is already safe with the victim in that case.
local function reinsertPlacedFull(victim: Player, placed: any): boolean
	if _baseService and type(_baseService.PlaceBrainrot) == "function" then
		local ok, success, returned = pcall(function()
			return _baseService.PlaceBrainrot(victim, placed)
		end)
		if ok and success and type(returned) == "table" then
			returned.Evolved = placed.Evolved
			returned.EvolutionId = placed.EvolutionId
			returned.EvolvedTrait = placed.EvolvedTrait
			returned.EvolvedFormName = placed.EvolvedFormName
			returned.TraitLevels = placed.TraitLevels
			return true
		end
		warn("[RaidService] BaseService.PlaceBrainrot reinsert failed for "
			.. tostring(placed.InstanceId) .. "; using local reinsert")
	end
	local ok2, restored = pcall(function()
		return reinsertPlaced(victim, placed)
	end)
	return ok2 and restored == true
end

-- ---------------------------------------------------------------------------
-- R3-6: durable return transaction (ReturnStolen).
-- ---------------------------------------------------------------------------
-- THE HOLE (verified against the code before this fix): the normal
-- online return moved the owned record back to the victim, cleared the
-- transit state and reinserted the placed copy — all in memory — and
-- persisted NOTHING. The autosave interval is 120 seconds
-- (Config.AutosaveInterval). A server crash in that window lost the
-- returned Brainrot whenever the earlier steal-time save had already
-- persisted the victim's removal while the thief's hold save had not
-- landed: after the crash NEITHER stored profile held the instance,
-- and the rejoin reconciler had nothing to recover (reproduced in the
-- R3-6 tests: 0 owned copies after crash + rejoin).
--
-- THE TRANSACTION (park-first, then commit, then verify — mirroring
-- the R3-5 reward commit's shape, but WITHOUT its rollback: rolling
-- an ownership change back would hand the thief a live InTransit
-- record alongside a parked return, and a delivery after that would
-- duplicate the instance on the victim's rejoin):
--   (1) PARK: immediately after the in-memory move succeeds, the
--       full-fidelity return is parked in the victim's escrow sidecar
--       (DataService.ParkReturnEscrow) under a fresh ReturnTxId. The
--       park is AFTER the move on purpose: parking before it would
--       leave a return claim parked for a record the thief still
--       holds if the move then failed. The escrow entry is the
--       durable backstop — it also heals the steal's own loss window
--       (a return parks a durable copy even when the steal-time
--       saves lost the record from both keys).
--   (2) COMMIT (in memory): clear the theft markers, record the TxId
--       in the victim's ReturnedTxns ledger (same data table as the
--       returned record, so the verifying save persists both in one
--       SetAsync), clear transit / carry, restore the placed copy.
--   (3) VERIFY: on the live paths (drop / death / watchdog /
--       rejoin) SaveData(victim) is the proof the return landed — it
--       persists the returned record, the restored placed copy and
--       the marker together. SaveData(thief) is best-effort (a stale
--       InTransit copy left in the thief's key is deleted by rejoin
--       rule (b) — the victim holds the clean copy — or by the
--       thief's next autosave). When the victim's save FAILS the
--       transit entry is KEPT so the 5s watchdog retries the return
--       (re-park + re-verify; the in-memory return stands), the
--       thief's save is SKIPPED so the thief's stored InTransit copy
--       survives as the rejoin backstop (rule (d)), and retries are
--       bounded (3) — after that the escrow park and the victim's
--       autosave / leave save are the backstops. On the leave /
--       shutdown hook path NO save is attempted here at all: the
--       coordinated leave / shutdown save that follows the hook is
--       the single save owner (R2-5), and the park (leg 1) is the
--       crash backstop until the victim's next save.
-- THE MARKER: DataService.mergeEscrowRecord skips an escrow entry
-- whose ReturnTxId is already in the victim's ReturnedTxns, and
-- records the TxId there when it applies or dedupes an entry. That
-- is what stops a STALE escrow entry from voiding a legitimate
-- re-steal: after a completed return the victim's key carries the
-- marker, so a later rejoin merge recognises the parked entry as
-- already applied even though the record itself has since been
-- stolen away again. A legacy escrow entry (no ReturnTxId) merges
-- exactly as before.
-- CRASH WINDOWS (see the R3-6 report for the full analysis):
--   CLOSED — crash after the park, before any main-key save: the
--     victim's rejoin merges the escrow entry; the thief's rejoin
--     rule (b) deletes the stale copy. One owner.
--   CLOSED — crash after the victim's save, before the thief's save:
--     the victim holds the clean copy; rule (b) deletes the thief's
--     stale copy on rejoin. One owner.
--   CLOSED — crash after the in-memory commit with the victim's save
--     failed and the thief's save skipped: the stored state is the
--     pre-return state, and the thief's stored InTransit copy (or
--     the escrow park) drives rule (d) on rejoin. One owner.
--   OPEN (residual, needs a partial DataStore outage): the escrow
--     park fails AND the victim's save fails AND the thief-side
--     deletion persists (thief save / autosave / leave save) AND a
--     crash lands before any retry or victim save. Durability needs
--     at least one of the victim's two keys (main, escrow) to accept
--     the return — when both refuse it, nothing can persist it.
--   OPEN (residual, needs a sustained victim-key outage): the
--     victim's save fails, the Brainrot is re-stolen and delivered,
--     and the victim leaves / crashes before ANY victim save lands
--     the marker — the next rejoin merge then applies the stale
--     escrow entry (no marker in the key to invalidate it) and the
--     delivered copy duplicates. Narrow (five conditions); the
--     proposed follow-up is invalidating the victim's escrow entry
--     at delivery time (see the report).
--
-- R2-5: escrow a stolen Brainrot for an OFFLINE victim. The victim's
-- data is unreachable (no cache, and a move into a reloaded cache
-- would never be saved), and destroying the record would delete the
-- victim's Brainrot outright — the old victim-left behaviour. Instead
-- the full record is parked in the victim's DataStore sidecar
-- (DataService.ParkReturnEscrow, R3-6); the victim's next successful
-- load merges it back into OwnedInstances + its placed copy. On a
-- successful escrow the thief-held record is removed, the transit
-- entry is cleared and the carry attribute is reset. Returns false
-- when no escrow API exists or the write fails — the caller must then
-- KEEP the record in transit (flagged, owner recorded) for a later
-- rejoin retry, never drop it.
-- newReturnTxId(victimUserId, instanceId): a UNIQUE, STABLE id for one
-- return event. Format "rt-<guid>-<victimUserId>-<instanceId>-
-- <perServerCounter>", mirroring newRewardTxId (R4-6: the GUID is
-- what makes it collision-resistant across servers). The id is
-- created once per ReturnStolen call and stored in the escrow entry
-- and in the victim's ReturnedTxns ledger, so every leg of the
-- transaction can recognise the same event. A Brainrot stolen and
-- returned twice in its lifetime gets two TxIds.
-- Assigned (not redeclared): the forward declaration above is
-- the local this closes over.
newReturnTxId = function(victimUserId: number, instanceId: string): string
	_returnTxCounter += 1
	return string.format("rt-%s-%d-%s-%d",
		newGuid(), victimUserId, tostring(instanceId), _returnTxCounter)
end

local function ensureReturnedLedger(data: any): { [string]: any }
	if type(data.ReturnedTxns) ~= "table" then
		data.ReturnedTxns = {}
	end
	return data.ReturnedTxns
end

-- buildReturnEscrowRecord(instanceId, owned, snapshot, txId): the
-- full-fidelity escrow table for one return — the same shape
-- tryEscrowReturn built inline before R3-6, plus the ReturnTxId that
-- ties this parked entry to its transaction. Slot / PlacedAt /
-- BankedIncome prefer the steal snapshot (the restore values), then
-- the moved record's Stolen* fields, then the record's live fields;
-- TraitLevels is copied, not aliased.
local function buildReturnEscrowRecord(instanceId: string, owned: any, snapshot: any?, txId: string): { [string]: any }
	local traitLevels: { [string]: number }? = nil
	local sourceTraits = owned.TraitLevels or (snapshot and snapshot.TraitLevels)
	if type(sourceTraits) == "table" then
		local copied: { [string]: number } = {}
		for traitId, level in pairs(sourceTraits) do
			copied[traitId] = level
		end
		traitLevels = copied
	end
	return {
		InstanceId = instanceId,
		CharacterId = owned.CharacterId or (snapshot and snapshot.CharacterId),
		Level = owned.Level,
		Mutation = owned.Mutation,
		Glitched = owned.Glitched == true,
		Evolved = owned.Evolved,
		EvolutionId = owned.EvolutionId,
		EvolvedTrait = owned.EvolvedTrait,
		EvolvedFormName = owned.EvolvedFormName,
		TraitLevels = traitLevels,
		Placed = true,
		Slot = (snapshot and tonumber(snapshot.Slot))
			or tonumber(owned.StolenSlot) or tonumber(owned.Slot) or 0,
		PlacedAt = (snapshot and tonumber(snapshot.PlacedAt))
			or tonumber(owned.StolenPlacedAt) or tonumber(owned.PlacedAt) or os.time(),
		BankedIncome = (snapshot and tonumber(snapshot.BankedIncome))
			or tonumber(owned.StolenBankedIncome) or tonumber(owned.BankedIncome) or 0,
		ReturnTxId = txId,
	}
end

-- parkReturnEscrow(victimUserId, escrow): durably park one return in
-- the victim's escrow sidecar. Prefers DataService.ParkReturnEscrow
-- (R3-6: a re-park for the same InstanceId REPLACES the existing
-- entry, so the sidecar always holds the latest return); an older
-- DataService without it falls back to EscrowReturnedInstance
-- (keep-first per InstanceId — the entry still merges, it is just
-- not refreshed by a later return). Returns true iff the write
-- landed. Never throws.
local function parkReturnEscrow(victimUserId: number, escrow: { [string]: any }): boolean
	if _dataService == nil then
		return false
	end
	if type(_dataService.ParkReturnEscrow) == "function" then
		local ok, stored = pcall(function()
			return _dataService.ParkReturnEscrow(victimUserId, escrow)
		end)
		return ok and stored == true
	end
	if type(_dataService.EscrowReturnedInstance) == "function" then
		local ok, stored = pcall(function()
			return _dataService.EscrowReturnedInstance(victimUserId, escrow)
		end)
		return ok and stored == true
	end
	return false
end

local function tryEscrowReturn(thief: Player, victimUserId: number, instanceId: string, owned: any, snapshot: any?): boolean
	local txId = newReturnTxId(victimUserId, instanceId)
	local escrow = buildReturnEscrowRecord(instanceId, owned, snapshot, txId)
	if not parkReturnEscrow(victimUserId, escrow) then
		return false
	end
	destroyOwnedRecord(thief, instanceId)
	_inTransit[instanceId] = nil
	if thief and thief.Character then
		thief.Character:SetAttribute("CarryingStolen", "")
	end
	print(string.format(
		"[RaidService] Stolen %s escrowed for offline victim %d",
		instanceId, victimUserId))
	return true
end

-- R2-5: delete a stale duplicate copy of an instance from `player`'s
-- data (owned record + any placed copy). Used only by the rejoin
-- reconciler when another online player already holds a clean copy —
-- the stale copy is a leftover of the old double-save race, never a
-- live ownership. Direct table edits (no service calls): this is
-- cleanup of a known-duplicate, not a player action.
local function deleteStaleCopy(player: Player, instanceId: string)
	local data = getData(player)
	if not data then
		return
	end
	if type(data.OwnedInstances) == "table" then
		for index, inst in ipairs(data.OwnedInstances) do
			if type(inst) == "table" and inst.InstanceId == instanceId then
				table.remove(data.OwnedInstances, index)
				break
			end
		end
	end
	if type(data.Base) == "table" and type(data.Base.Placed) == "table" then
		for index, placed in ipairs(data.Base.Placed) do
			if type(placed) == "table" and placed.InstanceId == instanceId then
				table.remove(data.Base.Placed, index)
				break
			end
		end
	end
	if type(data.Placed) == "table" then
		for index, placed in ipairs(data.Placed) do
			if type(placed) == "table" and placed.InstanceId == instanceId then
				table.remove(data.Placed, index)
				break
			end
		end
	end
end

-- Move the OwnedInstances record for `instanceId` between two players.
-- Uses MutationService.MoveInstance when linked, else edits the data
-- tables directly (same shape). Returns the moved record on success
-- (truthy, so existing `if moved then` call sites keep working), or
-- nil when the source does not own it / the transfer failed. Callers
-- that need the record object (StealBrainrot, to set InTransit on the
-- exact record that moved) use the return value.
local function moveOwnedRecord(fromPlayer: Player, toPlayer: Player, instanceId: string): any
	if not fromPlayer or not toPlayer then
		return nil
	end
	if _mutationService and type(_mutationService.MoveInstance) == "function" then
		local ok, moved = pcall(function()
			return _mutationService.MoveInstance(fromPlayer, toPlayer, instanceId)
		end)
		if ok and moved then
			return moved
		end
	end
	local fromData = getData(fromPlayer)
	local toData = getData(toPlayer)
	if not fromData or not toData then
		return nil
	end
	if type(fromData.OwnedInstances) ~= "table" then
		return nil
	end
	local record: any = nil
	for index, inst in ipairs(fromData.OwnedInstances) do
		if type(inst) == "table" and inst.InstanceId == instanceId then
			record = inst
			table.remove(fromData.OwnedInstances, index)
			break
		end
	end
	if not record then
		return nil
	end
	record.Placed = false
	record.Slot = 0
	if type(toData.OwnedInstances) ~= "table" then
		toData.OwnedInstances = {}
	end
	table.insert(toData.OwnedInstances, record)
	return record
end

-- Placed pedestal positions for `owner` (via BaseService when linked).
-- Used for the "thief is inside the victim's base" check and the steal
-- channel anchor: pedestals are the ground truth for base location.
local function getPlacedPositions(owner: Player): { Vector3 }
	local positions: { Vector3 } = {}
	if _baseService and type(_baseService.GetPlacedPosition) == "function" then
		for _, placed in ipairs(getPlacedList(owner)) do
			if type(placed) == "table" and type(placed.InstanceId) == "string" then
				local ok, pos = pcall(function()
					return _baseService.GetPlacedPosition(owner, placed.InstanceId)
				end)
				if ok and typeof(pos) == "Vector3" then
					table.insert(positions, pos)
				end
			end
		end
	end
	return positions
end

-- Base plot position for `owner`: map Bases folder fallback (child
-- named by UserId or Name, first BasePart inside), else nil.
local function getBasePosition(owner: Player): Vector3?
	if _baseService and type(_baseService.GetBasePosition) == "function" then
		local ok, pos = pcall(function()
			return _baseService.GetBasePosition(owner)
		end)
		if ok and typeof(pos) == "Vector3" then
			return pos
		end
	end
	local bases = workspace:FindFirstChild("Bases")
	if bases then
		local plot = bases:FindFirstChild(tostring(owner.UserId)) or bases:FindFirstChild(owner.Name)
		if plot then
			for _, descendant in ipairs(plot:GetDescendants()) do
				if descendant:IsA("BasePart") then
					return descendant.Position
				end
			end
		end
	end
	return nil
end

local function getCharacterPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function isShieldActive(ownerUserId: number): boolean
	local untilTime = _shields[ownerUserId]
	return untilTime ~= nil and os.clock() < untilTime
end

local function isLockdownActive(ownerUserId: number): boolean
	local untilTime = _lockdowns[ownerUserId]
	return untilTime ~= nil and os.clock() < untilTime
end

local function applyStun(player: Player, duration: number)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or _stunned[humanoid] then
		return
	end
	_stunned[humanoid] = true
	local originalSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = 0
	character:SetAttribute("RaidStunned", true)
	task.delay(duration, function()
		_stunned[humanoid] = nil
		if humanoid.Parent then
			character:SetAttribute("RaidStunned", false)
			humanoid.WalkSpeed = originalSpeed
		end
	end)
end

local function alertSteal(victim: Player, thief: Player, characterId: string, phase: string)
	local payload = {
		Thief = thief.Name,
		ThiefUserId = thief.UserId,
		Victim = victim.Name,
		CharacterId = characterId,
		Phase = phase, -- "Started" | "Success" | "Failed" | "Returned" | "Delivered"
	}
	fireClient(_names.StealAlert, victim, payload)
	-- Nearby players (within 40 studs of the victim) hear the alarm too.
	local victimPos = getCharacterPosition(victim)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= victim and player ~= thief then
			local pos = getCharacterPosition(player)
			if victimPos and pos and (pos - victimPos).Magnitude <= 40 then
				fireClient(_names.StealAlert, player, payload)
			end
		end
	end
end

local function recordQuest(player: Player, eventName: string, amount: number)
	if _questService and type(_questService.RecordEvent) == "function" then
		pcall(function()
			_questService.RecordEvent(player, eventName, amount)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Public queries
-- ---------------------------------------------------------------------------

-- IsProtected(victim, targetPlaced): (true, reason) when any protection
-- applies. `targetPlaced` may be a placed record or an instance id.
function RaidService.IsProtected(victim: Player, target: any): (boolean, string)
	if not victim or not victim:IsA("Player") then
		return true, "invalid victim"
	end
	local data = getData(victim)
	if not data then
		return true, "no victim data"
	end
	if (tonumber(data.Level) or 1) < NEW_PLAYER_LEVEL then
		return true, "new-player protection (level < 3)"
	end
	if victim.AccountAge < NEW_ACCOUNT_DAYS then
		return true, "new-player protection (account age < 7 days)"
	end
	if isShieldActive(victim.UserId) then
		return true, "base shield active"
	end
	if isLockdownActive(victim.UserId) then
		return true, "base lockdown active"
	end
	if _baseService and type(_baseService.IsLocked) == "function" then
		local ok, locked = pcall(function()
			return _baseService.IsLocked(victim)
		end)
		if ok and locked then
			return true, "base lock active"
		end
	end
	local placedList = getPlacedList(victim)
	if #placedList <= 1 then
		return true, "starter/last-creature protection (victim would be left with 0 placed)"
	end
	local placed: any = nil
	if type(target) == "string" then
		placed = findPlaced(victim, target)
	elseif type(target) == "table" then
		placed = target
	end
	if not placed then
		return true, "target not placed in victim base"
	end
	local placedAt = tonumber(placed.PlacedAt) or 0
	if placedAt > 0 and os.time() - placedAt < RECENT_PLACE_SECONDS then
		return true, "recently-purchased protection (placed < 120s ago)"
	end
	return false, ""
end

-- GetCooldown(thief): seconds remaining on the thief's longest active
-- steal cooldown across all victims (0 when free to steal).
function RaidService.GetCooldown(thief: Player): number
	if not thief or not thief:IsA("Player") then
		return 0
	end
	local now = os.clock()
	local remaining = 0
	for key, at in pairs(_pairCooldowns) do
		if string.match(key, "^" .. tostring(thief.UserId) .. ":") then
			remaining = math.max(remaining, STEAL_COOLDOWN - (now - at))
		end
	end
	return math.max(0, remaining)
end

-- CanEnter(visitor, owner): gate + lockdown gatekeeping for base entry.
function RaidService.CanEnter(visitor: Player, owner: Player): (boolean, string)
	if not visitor or not owner then
		return false, "invalid player"
	end
	if visitor == owner then
		return true, ""
	end
	if isLockdownActive(owner.UserId) then
		return false, "base is in lockdown"
	end
	if _gates[owner.UserId] == false then
		return false, "base gate is closed"
	end
	return true, ""
end

function RaidService.GetGuards(ownerUserId: number): { Model }
	return _guards[ownerUserId] or {}
end

-- ---------------------------------------------------------------------------
-- Defenses
-- ---------------------------------------------------------------------------

-- RegisterGuard(base, npc): NPCService calls this after spawning a guard
-- so raids can see it. `base` is the owner Player or a UserId.
function RaidService.RegisterGuard(base: any, npc: Model): boolean
	local ownerUserId: number? = nil
	if type(base) == "number" then
		ownerUserId = base
	elseif typeof(base) == "Instance" and base:IsA("Player") then
		ownerUserId = base.UserId
	end
	if not ownerUserId or not npc or not npc:IsA("Model") then
		return false
	end
	_guards[ownerUserId] = _guards[ownerUserId] or {}
	table.insert(_guards[ownerUserId], npc)
	return true
end

-- ActivateShield(player, durationSeconds?): 100 coins, blocks steals
-- while active (default 60s). Returns (true) or (false, reason).
function RaidService.ActivateShield(player: Player, durationSeconds: number?): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = getData(player)
	if not data then
		return false, "no data"
	end
	if isShieldActive(player.UserId) then
		return false, "shield already active"
	end
	-- R4-3: affordability is judged on SPENDABLE coins (balance
	-- above any reservation), not the raw balance — a pending reward
	-- commit's reserved coins are not spendable here.
	local spendable = tonumber(data.Coins) or 0
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, value = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(value) == "number" then
			spendable = value
		end
	end
	if spendable < SHIELD_COST then
		return false, "not enough coins"
	end
	pcall(function()
		_dataService.AddCoins(player, -SHIELD_COST)
	end)
	_shields[player.UserId] = os.clock() + (tonumber(durationSeconds) or SHIELD_DURATION)
	return true, nil
end

-- SetGate(player, open): owner opens / closes their base gate.
function RaidService.SetGate(player: Player, open: boolean): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	_gates[player.UserId] = open == true
	return true
end

-- TriggerLockdown(player): 30s lockdown, 250 coins, 120s owner cooldown.
-- Blocks entry (CanEnter) and steals (IsProtected) while active.
function RaidService.TriggerLockdown(player: Player): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local data = getData(player)
	if not data then
		return false, "no data"
	end
	if isLockdownActive(player.UserId) then
		return false, "lockdown already active"
	end
	local last = _lockdownCooldowns[player.UserId] or -math.huge
	if os.clock() - last < LOCKDOWN_COOLDOWN then
		return false, "lockdown on cooldown"
	end
	-- R4-3: see ActivateShield — affordability is judged on
	-- spendable coins (balance above any reservation), not the raw
	-- balance.
	local spendable = tonumber(data.Coins) or 0
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, value = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(value) == "number" then
			spendable = value
		end
	end
	if spendable < LOCKDOWN_COST then
		return false, "not enough coins"
	end
	pcall(function()
		_dataService.AddCoins(player, -LOCKDOWN_COST)
	end)
	_lockdowns[player.UserId] = os.clock() + LOCKDOWN_DURATION
	_lockdownCooldowns[player.UserId] = os.clock()
	fireAll(_names.StealAlert, {
		Victim = player.Name,
		Phase = "Lockdown",
		Duration = LOCKDOWN_DURATION,
	})
	return true, nil
end

-- RecordDefense(victim): called when a guard / protection stops a thief.
function RaidService.RecordDefense(victim: Player)
	if not victim then
		return
	end
	recordQuest(victim, "defend_success", 1)
end

-- PollInTransit(): watchdog over stolen Brainrots. BaseService and
-- CarryService never call back into RaidService, so delivery and drops
-- are detected by polling: delivered when the instance is placed in
-- the thief's own base; dropped when the thief is no longer carrying
-- it (manual drop, or a death the Died hook missed). A 2s grace period
-- after the steal covers ForceCarry timing.
function RaidService.PollInTransit()
	local ids: { string } = {}
	for instanceId in pairs(_inTransit) do
		table.insert(ids, instanceId)
	end
	for _, instanceId in ipairs(ids) do
		local record = _inTransit[instanceId]
		if record then
			local thief = record.Thief
			if not thief or not thief.Parent then
				RaidService.ReturnStolen(instanceId)
			else
				local delivered = false
				if _baseService and type(_baseService.GetPlaced) == "function" then
					local ok, placedList = pcall(function()
						return _baseService.GetPlaced(thief)
					end)
					if ok and type(placedList) == "table" then
						for _, placed in ipairs(placedList) do
							if type(placed) == "table" and placed.InstanceId == instanceId then
								delivered = true
								break
							end
						end
					end
				end
				-- Fallback: read the thief's data directly. v1.0.0 only
				-- checked BaseService, so with BaseService unlinked a
				-- stolen Brainrot could never be delivered at all.
				if not delivered then
					local thiefData = getData(thief)
					if thiefData then
						local lists: { { any } } = {}
						if type(thiefData.Base) == "table" and type(thiefData.Base.Placed) == "table" then
							table.insert(lists, thiefData.Base.Placed)
						end
						if type(thiefData.Placed) == "table" then
							table.insert(lists, thiefData.Placed)
						end
						for _, list in ipairs(lists) do
							for _, placed in ipairs(list) do
								if type(placed) == "table" and placed.InstanceId == instanceId then
									delivered = true
									break
								end
							end
							if delivered then
								break
							end
						end
					end
				end
				if delivered then
					RaidService.ConfirmDelivery(thief, instanceId)
				elseif _carryService and os.clock() - (tonumber(record.StolenAt) or 0) > 2 then
					local carrying = false
					if type(_carryService.IsCarrying) == "function" then
						local ok, result = pcall(function()
							return _carryService.IsCarrying(thief)
						end)
						carrying = ok and result == true
					end
					if carrying and type(_carryService.GetCarried) == "function" then
						local ok, carried = pcall(function()
							return _carryService.GetCarried(thief)
						end)
						if not ok or type(carried) ~= "table" or carried.InstanceId ~= instanceId then
							carrying = false
						end
					end
					if not carrying then
						RaidService.ReturnStolen(instanceId)
					end
				end
			end
		end
	end
end

-- Setters for GameManager's tryWire injection (its generic Init passes
-- EconomyService / the map positionally, so the real services arrive
-- here instead). Each validates the interface before accepting.
function RaidService.SetBaseService(baseService: any)
	if baseService and type(baseService.GetPlaced) == "function" then
		_baseService = baseService
	end
end

function RaidService.SetCarryService(carryService: any)
	if carryService
		and (type(carryService.ForceCarry) == "function" or type(carryService.DropCarried) == "function")
	then
		_carryService = carryService
	end
end

function RaidService.SetMutationService(mutationService: any)
	if mutationService and type(mutationService.MoveInstance) == "function" then
		_mutationService = mutationService
	end
end

function RaidService.SetQuestService(questService: any)
	if questService and type(questService.RecordEvent) == "function" then
		_questService = questService
	end
end

-- R2: ExpeditionService is optional; only its orphaned-flag helper is
-- used (ReturnStolen). GameManager's cross-link pass calls this setter
-- automatically when ExpeditionService is loaded; without it the
-- inline fallback in clearOrphanedExpeditionFlag covers the same case.
function RaidService.SetExpeditionService(expeditionService: any)
	if expeditionService and type(expeditionService.ClearOrphanedExpeditionFlag) == "function" then
		_expeditionService = expeditionService
	end
end

-- ---------------------------------------------------------------------------
-- Steal flow
-- ---------------------------------------------------------------------------

-- ReturnStolen(instanceId): a stolen Brainrot in transit goes back to
-- the victim's original base slot (thief died / dropped it).
-- ReturnStolen(instanceId): a stolen Brainrot in transit goes back to
-- the victim's original base slot (thief died / dropped it).
--
-- Exactly-once rules (theft integrity):
--   * The placed copy is restored ONLY when the owned record actually
--     made it back to the victim. If the record was consumed while in
--     transit (e.g. fused), the move-back fails and NO placed copy is
--     recreated — recreating it would duplicate the instance.
--   * The InTransit flag is cleared only after the return has
--     committed (the owned record is back with the victim).
--   * R3-6: the return is a DURABLE transaction, not an in-memory
--     one — the return is parked in the victim's escrow sidecar
--     (under a ReturnTxId) right after the move, the TxId is
--     recorded in the victim's ReturnedTxns ledger, and the
--     victim's save is verified before the transit entry clears
--     (see the R3-6 header above tryEscrowReturn). A failed victim
--     save keeps the transit entry for the watchdog retry instead
--     of rolling the ownership back.
--   * The restore is idempotent: if a previous return already moved
--     the record back but died before clearing transit, the retry
--     finds the record with the victim, skips the move, and the
--     reinsert refuses to create a second placed copy.
function RaidService.ReturnStolen(instanceId: string): boolean
	local record = _inTransit[instanceId]
	if not record then
		return false
	end
	local victim = record.Victim
	local thief = record.Thief
	local victimOnline = victim ~= nil and victim.Parent ~= nil
	-- Resolve where the owned record actually is. Normally it is with
	-- the thief (moved there at steal time); on a retry it may already
	-- be back with the victim.
	local owned: any = nil
	local holder: Player? = nil
	if thief then
		owned = findOwnedRecord(thief, instanceId)
		if owned then
			holder = thief
		end
	end
	if not owned and victim then
		owned = findOwnedRecord(victim, instanceId)
		if owned then
			holder = victim
		end
	end
	if owned == nil then
		-- The record no longer exists anywhere: it was consumed while
		-- in transit. Clear the transit entry WITHOUT recreating a
		-- victim copy — a recreated copy alongside the fusion output
		-- would be a duplication (fuse-then-return vector).
		_inTransit[instanceId] = nil
		if thief and thief.Character then
			thief.Character:SetAttribute("CarryingStolen", "")
		end
		warn("[RaidService] ReturnStolen: owned record for "
			.. tostring(instanceId)
			.. " no longer exists; no placed copy recreated")
		return false
	end
	-- Move the OwnedInstances record back to the victim (it was moved
	-- to the thief as an in-transit hold at steal time). This is what
	-- closes the duplication hole: CarryService drops the carried
	-- Brainrot as a world pickup on death, but its pickup path requires
	-- the picker to own the record — after this move the thief no
	-- longer does, so the stale drop just expires.
	if holder == thief then
		if not victimOnline then
			-- R2-5: the victim is offline. NEVER move the record into
			-- the victim's (unreachable / reload-only) cache — that
			-- write would never persist — and NEVER destroy it (the
			-- old victim-left behaviour deleted the victim's Brainrot
			-- outright). Escrow it durably for the victim's rejoin;
			-- when no escrow exists (older DataService / write
			-- failure) keep the transit entry AND the InTransit flag
			-- so a later rejoin can still retry the return.
			if tryEscrowReturn(thief, victim.UserId, instanceId, owned, record) then
				return true
			end
			warn("[RaidService] ReturnStolen: victim offline and escrow unavailable for "
				.. tostring(instanceId) .. "; transit kept for retry")
			return false
		end
		local movedBack = moveOwnedRecord(thief, victim, instanceId)
		if not movedBack then
			-- Victim online but the move failed: the record is still
			-- with the thief (the move is the only writer), so keep
			-- the transit entry AND the InTransit flag — the watchdog
			-- can retry — and do NOT reinsert a placed copy.
			warn("[RaidService] ReturnStolen: move back failed for "
				.. tostring(instanceId) .. "; transit kept for retry")
			return false
		end
		owned = findOwnedRecord(victim, instanceId)
	end
	-- R3-6 (leg 1): the record is back with the victim (moved above,
	-- or already there on a retry) — park the return in the victim's
	-- escrow sidecar NOW, before any save, so a crash from here on
	-- still has a durable copy to recover from. The park is after
	-- the move on purpose (see the R3-6 header): a failed move must
	-- not leave a return claim parked for a record the thief still
	-- holds. No park when the victim is offline — that path escrows
	-- inside tryEscrowReturn above instead.
	local txId: string? = nil
	if victimOnline and owned ~= nil then
		txId = newReturnTxId(victim.UserId, instanceId)
		if not parkReturnEscrow(victim.UserId,
			buildReturnEscrowRecord(instanceId, owned, record, txId))
		then
			warn("[RaidService] ReturnStolen: escrow park failed for "
				.. tostring(instanceId)
				.. "; the main-key saves are the only durability")
		end
	end
	-- The return has committed: the owned record is back with the
	-- victim. Only now clear the InTransit flag (the transit entry
	-- itself is cleared below, once the victim's save has verified —
	-- a failed save keeps it for the watchdog retry).
	if owned then
		owned.InTransit = nil
		owned.StolenFromUserId = nil
		owned.StolenSlot = nil
		owned.StolenPlacedAt = nil
		owned.StolenBankedIncome = nil
		-- R3-6 (leg 2): the durable proof this return transaction is
		-- reflected in the victim's profile. Written into the same
		-- data table as the returned record, so the verifying save
		-- persists both together (one SetAsync); the merge then
		-- recognises the parked escrow entry for this TxId as
		-- already applied and never re-applies it.
		if txId ~= nil then
			local victimData = getData(victim)
			if victimData then
				ensureReturnedLedger(victimData)[txId] = {
					TxId = txId,
					InstanceId = instanceId,
					ReturnedAt = os.time(),
				}
			end
		end
	end
	if thief and thief.Character then
		thief.Character:SetAttribute("CarryingStolen", "")
	end
	-- R2: a pre-fix expedition started with this stolen record left
	-- OnExpedition = true on it while the Active entry lived in the
	-- thief's data. The victim has no Active expedition to claim, so
	-- without this clear the Brainrot would stay locked (unplaceable /
	-- unstoreable / unfusable) forever. Clears only when the victim has
	-- no Active expedition for the instance (a live trip is untouched).
	clearOrphanedExpeditionFlag(victim, instanceId, owned)
	-- Restore the placed copy with EVERY field captured at steal time
	-- (mutation, evolution / trait fields, banked income, original
	-- PlacedAt and slot — see the snapshot comment on _inTransit).
	-- If the restore itself fails, the owned record is already safe
	-- with the victim in inventory: no loss, no duplication.
	local placed = {
		InstanceId = instanceId,
		CharacterId = record.CharacterId,
		Slot = record.Slot,
		Level = record.Level,
		Glitched = record.Glitched,
		Mutation = record.Mutation,
		BankedIncome = record.BankedIncome,
		PlacedAt = record.PlacedAt,
		Evolved = record.Evolved,
		EvolutionId = record.EvolutionId,
		EvolvedTrait = record.EvolvedTrait,
		EvolvedFormName = record.EvolvedFormName,
		TraitLevels = record.TraitLevels,
	}
	-- R3-6: the return value is the DURABILITY of the return, not
	-- just whether the in-memory move happened. true = the return
	-- committed AND its durability is covered — the victim's
	-- verified save landed, or the coordinated leave / shutdown save
	-- owns it (the hook path, where no save is attempted here), or
	-- the escrow park covers it (victim-offline retry branch).
	-- false = the return did not durably commit: the victim's
	-- verified save failed and the watchdog retry is pending (the
	-- transit entry is kept) or exhausted (the escrow park is the
	-- only backstop). Callers that count resolved / remaining
	-- (RecoverStaleTransit) treat false as "not resolved", which is
	-- the accurate accounting.
	local durable = true
	if victimOnline then
		if not reinsertPlacedFull(victim, placed) then
			warn("[RaidService] ReturnStolen: placed copy for "
				.. tostring(instanceId)
				.. " could not be restored; instance kept in victim inventory")
		end
		-- R3-6 (leg 3): verify the return is durable. The victim's
		-- save is the proof: it persists the returned record, the
		-- restored placed copy and the marker together. Only then is
		-- the transit entry cleared. The thief's save is best-effort
		-- — a stale InTransit copy left in the thief's key is
		-- deleted by rejoin rule (b) (the victim holds the clean
		-- copy) or by the thief's next autosave.
		-- SAVE OWNERSHIP (R2-5 single-saver rule): while this return
		-- runs inside HandlePlayerLeaving (the pre-save hook — the
		-- coordinated leave save, or the shutdown loop, saves right
		-- after the hook), no save is attempted here at all: the
		-- hook's save is the single save owner for leave / shutdown,
		-- and the escrow park (leg 1) is the crash backstop on that
		-- path. The live return paths (drop / death / watchdog /
		-- rejoin) do not go through the hook, so their verified
		-- saves run. The thief's own save is also skipped while the
		-- thief is leaving (Parent == nil — their leave handler
		-- saves them right after this hook). When the victim's save
		-- FAILS the transit entry is KEPT so the 5s watchdog retries
		-- the return (re-park + re-verify; the in-memory return
		-- stands, so there is no rollback and no delivery hazard),
		-- and the thief's save is SKIPPED so the thief's stored
		-- InTransit copy survives as the rejoin backstop (rule (d)).
		-- Retries are bounded (3): after that the escrow park and
		-- the victim's autosave / leave save are the backstops.
		if _preSaveHookDepth > 0 then
			_inTransit[instanceId] = nil
		else
			local victimSaved = saveVerified(victim)
			if victimSaved then
				_inTransit[instanceId] = nil
				if thief and thief.Parent ~= nil then
					if not saveVerified(thief) then
						warn(string.format(
							"[RaidService] ReturnStolen: thief save failed for %s (thief %s); rejoin rule (b) clears the stale copy",
							tostring(instanceId), thief and thief.Name or "?"))
					end
				end
			else
				-- R3-6: the victim's verified save FAILED, so the
				-- return is not durable — report false (see the
				-- durability contract above). The transit entry is
				-- kept (or, past 3 retries, the escrow park is the
				-- only backstop) so the watchdog / rejoin can still
				-- recover it; the in-memory return stands either way.
				durable = false
				record.ReturnSaveRetries = (tonumber(record.ReturnSaveRetries) or 0) + 1
				if (tonumber(record.ReturnSaveRetries) or 0) > 3 then
					_inTransit[instanceId] = nil
					warn("[RaidService] ReturnStolen: victim save failed 3+ times for "
						.. tostring(instanceId)
						.. "; watchdog retry exhausted — the escrow park is the backstop")
				else
					warn(string.format(
						"[RaidService] ReturnStolen: victim save failed for %s (victim %s); transit kept for watchdog retry, thief save skipped",
						tostring(instanceId), victim and victim.Name or "?"))
				end
			end
		end
		alertSteal(victim, thief, record.CharacterId, "Returned")
	else
		-- Victim offline with the record already in their data (a
		-- retry after a leave): nothing can be saved or reinserted
		-- for them now — the old behaviour. The parked escrow entry
		-- from the first attempt is the rejoin backstop.
		_inTransit[instanceId] = nil
	end
	print(string.format("[RaidService] Stolen %s returned to %s", instanceId, victim and victim.Name or "?"))
	return durable
end

-- DropStolen(thief): CarryService calls this when the thief drops what
-- they carry; every in-transit item of that thief returns home.
function RaidService.DropStolen(thief: Player)
	if not thief then
		return
	end
	local toReturn: { string } = {}
	for instanceId, record in pairs(_inTransit) do
		if record.Thief == thief then
			table.insert(toReturn, instanceId)
		end
	end
	for _, instanceId in ipairs(toReturn) do
		RaidService.ReturnStolen(instanceId)
	end
end

-- R4-1: invalidate stale return escrow before a delivery commits.
-- Returns (true) when there is nothing stale to invalidate, or the
-- tombstone landed (durably, and — when the victim is online in
-- this server — in the victim's live ReturnedTxns ledger too, so
-- their next save persists the marker even before any rejoin
-- merge). Returns (false, reason) when the invalidation could NOT
-- be proven (escrow read failed, or tombstone append failed): the
-- caller must fail the delivery closed — committing it anyway could
-- leave two owners of one InstanceId. When DataService has no
-- InvalidateReturnEscrow (older DataService / test stub with no
-- durable escrow), there is nothing to invalidate and this is a
-- no-op true — the tombstone only has meaning where a durable
-- escrow exists.
local function invalidateStaleReturnEscrow(victim: Player?, victimUserId: number?, instanceId: string, deliveryTxId: string): (boolean, string?)
	if not _dataService or type(_dataService.InvalidateReturnEscrow) ~= "function" then
		return true
	end
	local okCall, okInv, hadStale, invErr, staleTxIds = pcall(function()
		return _dataService.InvalidateReturnEscrow(victimUserId, instanceId, deliveryTxId)
	end)
	if not okCall then
		return false, "escrow invalidation errored: " .. tostring(okInv)
	end
	if not okInv then
		return false, "escrow invalidation unavailable: " .. tostring(invErr)
	end
	if hadStale == true and victim ~= nil and victim.Parent ~= nil then
		local victimData = getData(victim)
		if victimData then
			local ledger = ensureReturnedLedger(victimData)
			if type(staleTxIds) == "table" then
				for _, txId in ipairs(staleTxIds) do
					local existing = ledger[txId]
					if existing == nil then
						ledger[txId] = {
							TxId = txId,
							InstanceId = instanceId,
							ReturnedAt = os.time(),
							Superseded = true,
						}
					else
						-- The victim's live ledger already holds this
						-- return (parked when the return ran): mark
						-- the EXISTING entry superseded — creating a
						-- second entry would not suppress the first.
						existing.Superseded = true
					end
				end
			end
		end
	end
	return true
end

-- ConfirmDelivery(thief, instanceId): the thief placed the stolen
-- Brainrot in their OWN base — ownership transfers now, and only now.
--
-- Commit order (theft integrity): the transit entry and the reward
-- are released ONLY after the delivery has committed. The commit
-- precondition is that the owned record is actually with the thief —
-- if it was consumed mid-transit, delivery fails WITHOUT clearing
-- transit or paying, so the return / watchdog path can still resolve
-- the theft exactly once.
function RaidService.ConfirmDelivery(thief: Player, instanceId: string): (boolean, string?)
	local record = _inTransit[instanceId]
	if not record then -- MUTANT (M5 control): thief identity check removed.
		return false, "not carrying that Brainrot"
	end
	local victim = record.Victim
	local owned = findOwnedRecord(thief, instanceId)
	if not owned then
		return false, "instance record missing"
	end
	-- R5-2 (P0): session-health gate, BEFORE the escrow invalidation
	-- below. The delivery is the ownership-transfer commit point:
	-- a thief who cannot save can never persist it, yet the R4-1
	-- tombstone the invalidation parks would permanently supersede
	-- the victim's escrow backstop — if both players then rejoin,
	-- the instance has 0 owners (Worker-A decision item, test 02
	-- §C as it stood). Refusing here keeps the transit live, pays
	-- no reward and parks NO tombstone, so the victim recovers via
	-- the escrow and the thief can retry after recovery (RetryLoad /
	-- rejoin) or return the Brainrot. The gate covers every
	-- unsaveable thief, not only the stale-escrow case: without a
	-- stale escrow the same loss happens (the victim's removal
	-- saved, the thief's delivery never persists). The victim is
	-- gated too when online — an offline victim has no session here
	-- and the tombstone is their backstop instead.
	local thiefHealthy, thiefReason = checkSessionHealth(thief, "thief")
	if not thiefHealthy then
		warn("[RaidService] Delivery refused for " .. tostring(instanceId)
			.. ": " .. tostring(thiefReason) .. "; transit kept for retry")
		return false, thiefReason
	end
	if victim ~= nil and victim.Parent ~= nil then
		local victimHealthy, victimReason = checkSessionHealth(victim, "victim")
		if not victimHealthy then
			warn("[RaidService] Delivery refused for " .. tostring(instanceId)
				.. ": " .. tostring(victimReason) .. "; transit kept for retry")
			return false, victimReason
		end
	end
	-- R4-1: invalidate any stale return escrow for this instance
	-- BEFORE the delivery commits. A return parked earlier (victim's
	-- save failed, marker never landed) would otherwise resurrect
	-- the Brainrot for the victim on their rejoin, duplicating the
	-- copy this delivery is about to confirm. The delivery's TxId
	-- is minted here so the tombstone and the reward grant name the
	-- same transaction. A failed invalidation FAILS THE DELIVERY
	-- CLOSED: transit stays live, no reward is paid, and
	-- PlaceBrainrot aborts the placement with no state change — the
	-- thief keeps carrying and can retry when the store recovers.
	-- The invalidation yields on DataStore calls, so the theft is
	-- re-verified afterwards: a return that landed during the yield
	-- (drop / death) must win over this delivery, not race it.
	local deliveryTxId = newRewardTxId(thief, instanceId)
	local victimUserId = tonumber(record.VictimUserId) or (victim and victim.UserId)
	local invOk, invReason = invalidateStaleReturnEscrow(victim, victimUserId, instanceId, deliveryTxId)
	if not invOk then
		warn("[RaidService] Delivery refused for " .. tostring(instanceId)
			.. ": " .. tostring(invReason) .. "; transit kept for retry")
		return false, "delivery escrow invalidation unavailable"
	end
	if _inTransit[instanceId] ~= record or findOwnedRecord(thief, instanceId) ~= owned then
		return false, "theft resolved during delivery"
	end
	-- R1: transfer the stolen snapshot onto the thief's owned record
	-- BEFORE clearing InTransit / committing delivery. The owned
	-- record moved to the thief at steal time carries the victim's
	-- old fields (and no BankedIncome / PlacedAt at all); the
	-- snapshot taken at steal time is the authority for what the
	-- delivered instance keeps. Level, Mutation, Glitched, Evolved
	-- fields and TraitLevels come verbatim from the snapshot
	-- (TraitLevels copied, not aliased, so later trait upgrades on
	-- the delivered instance cannot rewrite the snapshot).
	-- BankedIncome: the immediate steal reward already pays the
	-- configured share of the banked income (Economy.StealReward:
	-- floor(banked * StealRewardMultiplier) + IncomePerSec * 10),
	-- so only the REMAINDER may be written onto the delivered
	-- record — writing the full banked amount would let the thief
	-- collect it twice. The share comes from
	-- Economy.StealRewardShare, the same single computation
	-- StealReward uses; there is no second formula. (Fixture: 500
	-- banked -> 250 paid immediately, 250 retained on the
	-- delivered copy.) The banked amount is floored first to match
	-- StealReward's own floor; when the character is unknown the
	-- share is 0 and the full banked amount is retained, matching
	-- the 0 reward paid in that case.
	-- PlacedAt: set to the successful delivery time, NOT the
	-- snapshot time. This is a NEW placement in the thief's base,
	-- so the 120-second recently-placed protection window restarts
	-- here. That is intentional behaviour, not data loss.
	-- These writes happen only after every failure path above has
	-- returned, so a failed delivery changes nothing: the transit
	-- state stays live and no reward is paid.
	local banked = math.max(0, math.floor(tonumber(record.BankedIncome) or 0))
	local paidShare = Economy.StealRewardShare(record.CharacterId, banked)
	owned.Level = record.Level
	owned.Mutation = record.Mutation
	owned.Glitched = record.Glitched == true
	owned.Evolved = record.Evolved
	owned.EvolutionId = record.EvolutionId
	owned.EvolvedTrait = record.EvolvedTrait
	owned.EvolvedFormName = record.EvolvedFormName
	if type(record.TraitLevels) == "table" then
		local traitLevels: { [string]: number } = {}
		for traitId, level in pairs(record.TraitLevels) do
			traitLevels[traitId] = level
		end
		owned.TraitLevels = traitLevels
	end
	owned.BankedIncome = banked - paidShare
	owned.PlacedAt = os.time()
	-- R2-3: if a placed copy of this instance already exists in the
	-- thief's base (watchdog path — PollInTransit saw it placed),
	-- reconcile it from the just-updated owned record: it was built
	-- from pre-delivery fields and would otherwise keep stale values
	-- (level / mutation / banked income) while the owned record moved
	-- on. In the normal PlaceBrainrot path no placed copy exists yet
	-- here, so this is a no-op and the copy is built afterwards from
	-- the owned record as before.
	reconcilePlacedCopy(thief, instanceId, owned)
	-- Commit: clear the InTransit flag on the owned record, then
	-- release the transit entry. Only then pay the reward / unlock.
	-- R2-5: the durable theft-identity fields go with the flag — a
	-- delivered Brainrot must carry no trace of the theft.
	owned.InTransit = nil
	owned.StolenFromUserId = nil
	owned.StolenSlot = nil
	owned.StolenPlacedAt = nil
	owned.StolenBankedIncome = nil
	_inTransit[instanceId] = nil
	if thief.Character then
		thief.Character:SetAttribute("CarryingStolen", "")
	end
	-- Transfer ownership: the OwnedInstances record already moved to
	-- the thief at steal time (in-transit hold); delivery only confirms
	-- it. The thief also gains the character in their Unlocked set so
	-- the shop / character systems agree they own it.
	-- Steal reward (v1.0.0 never paid it, even though Config promises
	-- "thief keeps half the victim's stored income"): half the banked
	-- income of that Brainrot + a rarity-scaled bonus, paid on delivery
	-- only — failed thefts pay nothing.
	-- R2-4 (R13): the grant goes through grantStealReward. When the
	-- grant cannot durably succeed (session unsaveable, or AddCoins
	-- failed) the reward is recorded in data.PendingRewards and the
	-- delivery reports "reward_pending" — it must never claim a
	-- rewarded success for coins that were never paid. Recovery is
	-- RecoverPendingRewards (rejoin + manual retry); see the R2-4
	-- comment on grantStealReward for what can actually fail.
	local reward = Economy.StealReward(record.CharacterId, tonumber(record.BankedIncome) or 0)
	local rewardStatus: string? = nil
	if reward > 0 then
		-- R4-1: the grant reuses the delivery TxId minted above, so
		-- the tombstone and the reward name the same transaction.
		local paid, status = grantStealReward(thief, instanceId, record.CharacterId, reward, deliveryTxId)
		if not paid then
			rewardStatus = status
		end
	end
	pcall(function()
		_dataService.UnlockCharacter(thief, record.CharacterId)
	end)
	-- R2-5 (R6 review): the delivery saves stay asynchronous (a
	-- synchronous DataStore write on the PlaceBrainrot path would stall
	-- the remote), but their completion is now OBSERVED instead of
	-- fire-and-forget: a failed save warns with both accounts named,
	-- so a crash window that strands the delivery is visible in the
	-- logs instead of silent. The autosave loop, the leave save and
	-- the shutdown save are the backstops; a crash before ANY of them
	-- persists the delivery is still possible (see the rejoin rule in
	-- RecoverStaleTransit: an unpersisted delivery is voided, never
	-- granted). Save reliability is NOT claimed fixed.
	task.spawn(function()
		local savedVictim = false
		local savedThief = false
		pcall(function()
			savedVictim = _dataService.SaveData(victim) == true
		end)
		pcall(function()
			savedThief = _dataService.SaveData(thief) == true
		end)
		if not savedVictim or not savedThief then
			warn(string.format(
				"[RaidService] Delivery save incomplete for %s (victim %s: %s, thief %s: %s); autosave / leave save is the backstop",
				tostring(instanceId),
				victim and victim.Name or "?", tostring(savedVictim),
				thief.Name, tostring(savedThief)))
		end
	end)
	if victim and victim.Parent then
		alertSteal(victim, thief, record.CharacterId, "Delivered")
	end
	recordQuest(thief, "steal_success", 1)
	print(string.format(
		"[RaidService] Theft complete: %s stole %s from %s",
		thief.Name, record.CharacterId, victim and victim.Name or "?"
	))
	-- Success, but the reward status is part of it: nil when the
	-- reward was paid, "reward_pending" when the grant could not
	-- durably succeed and the amount is recorded in
	-- data.PendingRewards for RecoverPendingRewards. Callers that only
	-- check the boolean (BaseService.PlaceBrainrot) are unaffected.
	return true, rewardStatus
end

-- RecoverPendingRewards(player): retry every unpaid steal reward
-- recorded in data.PendingRewards for this player. Returns
-- (paidCount, totalCoinsPaid), where paidCount counts aggregate
-- entries (one per instance) and totalCoinsPaid is the coin sum.
-- Exactly-once (R3-3): each entry is paid through
-- commitPendingPayment, which pays the aggregate, marks every TxId
-- in the entry processed, removes the entry, and verifies the save —
-- all in the one data table. A repeated call pays nothing more (no
-- entries left, and any stale entry whose TxIds are already processed
-- is dropped without paying). Entries are kept — never deleted unpaid
-- — when the session cannot persist (paying into a phantom cache
-- would lose the reward), when an individual AddCoins fails, or when
-- the verifying save fails (the commit rolls the payment back, so the
-- entry stays pending for the next retry). Safe to call on every
-- rejoin and on manual retry; a no-op when nothing is pending.
-- (Intended rejoin wiring: GameManager.onPlayerAdded after GetOrLoad;
-- RaidService.Init also calls this on PlayerAdded as a backstop, so
-- the recovery does not depend on the lifecycle worker landing it.)
function RaidService.RecoverPendingRewards(player: Player): (number, number)
	if not player or not player:IsA("Player") then
		return 0, 0
	end
	local data = getData(player)
	if not data or type(data.PendingRewards) ~= "table" then
		return 0, 0
	end
	-- R5-3: retry pending reward VOIDS before any payment — and
	-- before the park retry below. A void that could not be
	-- persisted must land before a reward for the same instance
	-- could be paid (a sidecar entry merged after the void failed
	-- is refused only once the tombstone exists).
	RaidService.RetryPendingVoids(player)
	-- R4-2: retry the sidecar park BEFORE attempting any payment —
	-- and before the saveable check below. An unsaveable session
	-- cannot pay (its cache never persists), but its sidecar writes
	-- still work, and the sidecar is the ONLY durable leg for such a
	-- session: a park that failed at grant time must be retried here
	-- even though no payment follows. A reward must never be paid
	-- while its only recoverable record was discarded.
	RaidService.RetryPendingParks(player)
	if not isSaveable(player) then
		return 0, 0
	end
	local ids: { string } = {}
	for instanceId in pairs(data.PendingRewards) do
		table.insert(ids, instanceId)
	end
	local paidCount = 0
	local totalPaid = 0
	for _, instanceId in ipairs(ids) do
		local entry = data.PendingRewards[instanceId]
		if type(entry) ~= "table" then
			data.PendingRewards[instanceId] = nil
		else
			local amount = math.floor(tonumber(entry.Amount) or 0)
			if amount <= 0 then
				data.PendingRewards[instanceId] = nil
			else
				-- Count only coins actually paid now (commit returns
				-- the paid amount): an already-processed entry is
				-- dropped with (true, 0) and must not inflate the
				-- totals.
				local okPay, paidNow = commitPendingPayment(player, instanceId, entry)
				if okPay and paidNow > 0 then
					paidCount += 1
					totalPaid += paidNow
				elseif not okPay then
					warn("[RaidService] Pending reward recovery failed for "
						.. player.Name .. " (" .. tostring(instanceId)
						.. "); entry kept for retry")
				end
			end
		end
	end
	return paidCount, totalPaid
end

-- ---------------------------------------------------------------------------
-- R2-5: lifecycle recovery — leave / shutdown / rejoin.
-- ---------------------------------------------------------------------------
-- The leave path is owned by DataService (see its RegisterPreSaveHook):
-- DataService's PlayerRemoving handler runs the registered hooks BEFORE
-- its save, so HandlePlayerLeaving below is the recovery that makes
-- the saved state consistent. HandleShutdown is the same recovery for
-- every connected player (DataService's BindToClose runs the hooks per
-- player, so the shutdown save also lands after recovery).
-- RecoverStaleTransit / RecoverOnRejoin run on rejoin (GameManager.
-- onPlayerAdded is the canonical caller; the RaidService.Init
-- PlayerAdded backstop calls the same entry point) and resolve any
-- InTransit record a crash or a pre-fix leave persisted.
local function clearTheftMarkers(owned: any)
	if not owned then
		return
	end
	owned.InTransit = nil
	owned.StolenFromUserId = nil
	owned.StolenSlot = nil
	owned.StolenPlacedAt = nil
	owned.StolenBankedIncome = nil
end

-- ---------------------------------------------------------------------------
-- R4-4: a steal reward is payable ONLY while its delivery stands.
-- ---------------------------------------------------------------------------
-- POLICY (changed by R4-4; the R3 policy paid a pending reward even
-- when its delivery was voided on rejoin — that was repeatable reward
-- farming under a sustained save outage): reward eligibility follows
-- the delivery transaction's durable fate. A delivery that is voided
-- during recovery — the persisted state contradicts it, so the
-- Brainrot goes back to the victim — voids its reward. A delivery
-- that is durably committed keeps exactly-once reward recovery.
-- voidPendingRewardsForInstance(player, instanceId): void every
-- NOT-YET-PAID reward transaction pending for this instance. The
-- void is recorded in data.VoidedRewardTxns (so commitPendingPayment
-- and the merge both refuse those TxIds) and parked in the pending
-- sidecar (so a later rejoin that re-merges the sidecar entry still
-- refuses it). Already-PROCESSED TxIds are never voided: a paid
-- reward implies its delivery's commit saved the marker, coins and
-- flag-clear together, so a voided delivery cannot have a paid
-- reward for the same transaction. Returns (voidedTxIds, durable):
-- the TxIds voided, and whether the void is DURABLE (tombstone
-- parked, or the main-profile save of the void ledgers landed).
-- R5-3: the void is durable INDEPENDENT of the in-memory cache —
-- it parks an instance tombstone in the pending sidecar even when
-- no PendingRewards entry exists (e.g. the sidecar read failed at
-- rejoin), so a later-readable sidecar can never pay the voided
-- reward. The old code ignored the sidecar result and returned
-- with no tombstone whenever the cache held no entry.
-- Called only when a recovery actually resolves the theft back to
-- the victim (RecoverStaleTransit rules (b) and (d)); never when
-- the delivery is confirmed (rule (a)) or when the return merely
-- failed and stays queued for retry.
-- persistVoid(player, instanceId, txIds): make a reward void
-- DURABLE, by either leg. Leg 1 (primary): the instance tombstone
-- (+ per-TxId voids) in the pending sidecar, via
-- DataService.RecordRewardVoidForInstance — it survives even when
-- the main-profile save never lands. Leg 2: a main-profile save
-- persisting the in-cache VoidedRewardTxns /
-- VoidedRewardInstances ledgers + the removed pending entry (also
-- run after a successful park, as a second leg: it closes the
-- crash window between ReturnStolen's thief save — which persists
-- the still-pending entry — and the void). Returns true iff EITHER
-- leg landed. The save leg is skipped inside the pre-save hook
-- (_preSaveHookDepth > 0): the coordinated leave / shutdown save
-- that follows the hook is the single save owner there, and the
-- tombstone park is the crash backstop on that path.
local function persistVoid(player: Player, instanceId: string, txIds: { string }): boolean
	local parked = false
	if _dataService and type(_dataService.RecordRewardVoidForInstance) == "function" then
		local okCall, okPark = pcall(function()
			return _dataService.RecordRewardVoidForInstance(player, instanceId, txIds)
		end)
		parked = okCall and okPark == true
		if not parked then
			warn("[RaidService] Reward-void sidecar park failed for " .. player.Name
				.. " (" .. tostring(instanceId) .. "); trying the main-profile save as the fallback leg")
		end
	elseif _dataService and type(_dataService.RecordRewardVoidSidecar) == "function" then
		-- Older DataService without the instance tombstone: park
		-- per-TxId voids only (no tombstone — a void for TxIds
		-- this server never knew cannot be persisted there).
		local allOk = true
		for _, txId in ipairs(txIds) do
			local okCall, okOne = pcall(function()
				return _dataService.RecordRewardVoidSidecar(player, txId, instanceId)
			end)
			if not (okCall and okOne == true) then
				allOk = false
			end
		end
		parked = allOk and #txIds > 0
	end
	local saved = false
	if _preSaveHookDepth == 0
		and _dataService and type(_dataService.SaveData) == "function"
	then
		saved = saveVerified(player)
	end
	return parked or saved
end

local function voidPendingRewardsForInstance(player: Player, instanceId: string): ({ string }, boolean)
	local data = getData(player)
	if not data then
		return {}, false
	end
	-- R5-3: the void does NOT depend on the reward being present in
	-- the in-memory PendingRewards table. The TxIds below are
	-- collected when known (cache, plus a best-effort sidecar read
	-- inside RecordRewardVoidForInstance), but the void's durable
	-- record is the INSTANCE tombstone: it voids every reward for
	-- this instance, including TxIds this server never saw because
	-- the sidecar read failed when the void was recorded. The old
	-- code returned here with no entry in the cache — and no
	-- tombstone — so a later-readable sidecar paid the voided
	-- reward (r5-transactions test 03 §A reproduces it).
	local txns: { [string]: number } = {}
	if type(data.PendingRewards) == "table" then
		local entry = data.PendingRewards[instanceId]
		if type(entry) == "table" then
			txns = pendingTxns(entry, instanceId)
		end
	end
	local voided: { string } = {}
	if type(data.VoidedRewardTxns) ~= "table" then
		data.VoidedRewardTxns = {}
	end
	if type(data.VoidedRewardInstances) ~= "table" then
		data.VoidedRewardInstances = {}
	end
	local processed = data.ProcessedRewardTxns
	for txId in pairs(txns) do
		if type(processed) ~= "table" or processed[txId] == nil then
			if data.VoidedRewardTxns[txId] == nil then
				data.VoidedRewardTxns[txId] = {
					TxId = txId,
					InstanceId = instanceId,
					VoidedAt = os.time(),
				}
			end
			table.insert(voided, txId)
		end
	end
	-- The instance itself is voided, whatever TxIds it carries.
	data.VoidedRewardInstances[instanceId] = {
		InstanceId = instanceId,
		VoidedAt = os.time(),
	}
	-- The pending entry is removed from the cache: voided, never
	-- payable in-session. (Its sidecar copy is refused at merge by
	-- the tombstone / ledgers.)
	if type(data.PendingRewards) == "table" then
		data.PendingRewards[instanceId] = nil
	end
	-- Durability: tombstone (primary) or main-profile save
	-- (fallback). The return result is CHECKED — a void that lands
	-- on neither leg is kept pending for retry, and the caller must
	-- not report the recovery as finished.
	local durable = persistVoid(player, instanceId, voided)
	if durable then
		if type(_pendingVoids[player]) == "table" then
			_pendingVoids[player][instanceId] = nil
		end
	else
		if type(_pendingVoids[player]) ~= "table" then
			_pendingVoids[player] = {}
		end
		_pendingVoids[player][instanceId] = { txIds = voided }
		warn("[RaidService] Reward void for " .. player.Name
			.. " (" .. tostring(instanceId)
			.. ") could NOT be persisted (sidecar tombstone AND main-profile save failed);"
			.. " the void stays pending for retry — the recovery is NOT finished")
	end
	return voided, durable
end

-- RetryPendingVoids(player): R5-3 retry the durable park for every
-- reward void whose tombstone AND fallback save both failed (see
-- voidPendingRewardsForInstance). Same stable identifiers
-- ("void-inst-<instanceId>", "void-<txId>"), idempotent re-park.
-- Returns (parkedNow, stillPending). Safe to call at any time
-- (rejoin, recovery, leave); a no-op when nothing is pending.
-- Called BEFORE any payment in RecoverPendingRewards and at the
-- start of RecoverOnRejoin, so a void always gets its retry before
-- a reward for the same instance could be paid.
function RaidService.RetryPendingVoids(player: Player): (number, number)
	if not player or not player:IsA("Player") then
		return 0, 0
	end
	local pending = _pendingVoids[player]
	if type(pending) ~= "table" then
		return 0, 0
	end
	local parkedNow = 0
	local stillPending = 0
	for instanceId, record in pairs(pending) do
		local txIds: { string } = {}
		if type(record) == "table" and type(record.txIds) == "table" then
			txIds = record.txIds
		end
		if persistVoid(player, instanceId, txIds) then
			pending[instanceId] = nil
			parkedNow += 1
		else
			stillPending += 1
		end
	end
	return parkedNow, stillPending
end

-- HandlePlayerLeaving(player): the pre-save hook. Clears this
-- player's steal channel / rate state and returns every Brainrot they
-- are carrying stolen (ReturnStolen) BEFORE DataService saves — so
-- the saved thief state never holds an orphaned in-transit record and
-- the victim's restored copy is in the victim's live data for the
-- victim's own later save. Idempotent: a second call finds no transit
-- entries and returns 0. Returns the number of Brainrots returned.
function RaidService.HandlePlayerLeaving(player: Player): number
	if not player then
		return 0
	end
	_channels[player] = nil
	_rate[player] = nil
	-- R4-2: the leave path is a park-retry point too. A pending
	-- reward whose sidecar park failed at grant time gets one more
	-- chance to land durably before this session's cache is saved
	-- and cleared; the coordinated leave save that follows persists
	-- the updated ParkedTxns state with it.
	pcall(function()
		RaidService.RetryPendingParks(player)
	end)
	local toReturn: { string } = {}
	for instanceId, record in pairs(_inTransit) do
		if record.Thief == player then
			table.insert(toReturn, instanceId)
		end
	end
	-- R3-6: this is the pre-save hook — DataService's leave handler
	-- saves this player right after the hook returns, and the
	-- shutdown loop saves every player right after the hooks — so
	-- ReturnStolen must not save anyone from inside here (the
	-- single save owner for leave / shutdown is that save, not this
	-- hook). _preSaveHookDepth marks the region; ReturnStolen skips
	-- its save-verify block while it is > 0 and relies on the escrow
	-- park (leg 1) plus the coordinated save as the durability.
	-- The live return paths (drop / death / watchdog / rejoin) do
	-- not go through here, so their verified saves are unaffected.
	_preSaveHookDepth += 1
	-- R5-3: the leave path is a void-retry point too, run INSIDE
	-- the hook region on purpose: a void whose tombstone could not
	-- be parked gets one more chance to land durably before this
	-- session's cache is saved and cleared, and persistVoid's save
	-- leg is skipped while the depth is > 0 (see persistVoid), so
	-- the hook itself never saves — the coordinated leave save that
	-- follows persists the void ledgers with it.
	pcall(function()
		RaidService.RetryPendingVoids(player)
	end)
	local ok, returned = pcall(function()
		local count = 0
		for _, instanceId in ipairs(toReturn) do
			if RaidService.ReturnStolen(instanceId) then
				count += 1
			end
		end
		return count
	end)
	_preSaveHookDepth -= 1
	if not ok then
		error(returned, 0)
	end
	return returned
end

-- HandleShutdown(players?): run the leave recovery for every player
-- in `players` (all connected players when omitted), before the
-- shutdown save. Returns the total number of Brainrots returned.
function RaidService.HandleShutdown(players: { Player }?): number
	local list: { Player } = players or Players:GetPlayers()
	local total = 0
	for _, player in ipairs(list) do
		total += RaidService.HandlePlayerLeaving(player)
	end
	return total
end

-- RecoverStaleTransit(player): resolve every InTransit record in
-- this player's LOADED data (a crash / pre-fix leave persisted it).
-- Deterministic order — exactly one owner afterwards:
--   (b) another online player already holds a CLEAN copy of the same
--       InstanceId: this stale copy is a leftover of the old
--       double-save race; delete it.
--   (a) a placed copy of the instance exists in THIS player's own
--       base: delivery committed in memory (PlaceBrainrot builds the
--       placed copy only via the delivery path) but the flag-clear
--       never persisted — treat as delivered, clear the markers, keep
--       the Brainrot. (The reverse — an unpersisted delivery with no
--       placed copy in the SAVED data — is voided by rule (d) below:
--       ownership is never granted without durable proof.)
--   (c) the recorded owner IS this player (StolenFromUserId == own
--       UserId: a victim-side stale record): clear the markers and
--       restore the placed copy from the record's Stolen* fields.
--   (d) the recorded owner is someone else: victim online -> rebuild
--       the transit snapshot and ReturnStolen; victim offline ->
--       escrow for the victim's rejoin, or keep flagged when no
--       escrow exists (a later rejoin retries — never frozen without
--       a path, never destroyed, never granted to the thief).
--   (e) no owner recorded (legacy pre-R2-5 record): keep flagged and
--       warn — never delete (that loses the instance) and never grant
--       (that gives stolen goods away).
-- Idempotent: a second call finds no stale records (or only the
-- unresolvable ones) and changes nothing. Returns (resolved, still
-- flagged). No reward is paid here: a stale record is by definition
-- an UNDELIVERED theft, and the steal reward is only paid by
-- ConfirmDelivery (or its PendingRewards ledger on rejoin).
function RaidService.RecoverStaleTransit(player: Player): (number, number)
	if not player or not player:IsA("Player") then
		return 0, 0
	end
	local data = getData(player)
	if not data or type(data.OwnedInstances) ~= "table" then
		return 0, 0
	end
	local staleIds: { string } = {}
	for _, inst in ipairs(data.OwnedInstances) do
		if type(inst) == "table" and type(inst.InstanceId) == "string" and inst.InTransit == true then
			table.insert(staleIds, inst.InstanceId)
		end
	end
	local resolved = 0
	local remaining = 0
	for _, instanceId in ipairs(staleIds) do
		local owned = findOwnedRecord(player, instanceId)
		if owned == nil then
			-- Already resolved by an earlier entry in this pass.
			resolved += 1
		else
			-- (b) Duplicate: another online player holds a clean copy.
			local dupe = false
			for _, other in ipairs(Players:GetPlayers()) do
				if other ~= player then
					local otherOwned = findOwnedRecord(other, instanceId)
					if otherOwned and otherOwned.InTransit ~= true then
						dupe = true
						break
					end
				end
			end
			if dupe then
				deleteStaleCopy(player, instanceId)
				-- R4-4: this stale copy's delivery is void (another
				-- player holds the clean copy); its pending reward
				-- must not remain payable. R5-3: the void's
				-- durability is CHECKED — when it cannot be
				-- persisted, the recovery is NOT finished (the
				-- instance stays remaining so the void is retried
				-- instead of silently leaving a payable reward).
				local _voidedB, voidDurableB = voidPendingRewardsForInstance(player, instanceId)
				_inTransit[instanceId] = nil
				if player.Character then
					player.Character:SetAttribute("CarryingStolen", "")
				end
				if voidDurableB then
					resolved += 1
				else
					remaining += 1
				end
			elseif findPlacedInData(data, instanceId) ~= nil then
				-- (a) Delivered: placed copy in the player's own base
				-- proves the delivery committed; clear the markers.
				local placedHere = findPlacedInData(data, instanceId)
				clearTheftMarkers(owned)
				syncOwnedPlaced(player, instanceId, true, tonumber(placedHere.Slot) or 0)
				_inTransit[instanceId] = nil
				if player.Character then
					player.Character:SetAttribute("CarryingStolen", "")
				end
				resolved += 1
			else
				local ownerUserId = tonumber(owned.StolenFromUserId) or 0
				if ownerUserId == player.UserId then
					-- (c) This player IS the recorded owner. Capture
					-- the Stolen* restore values BEFORE clearing the
					-- markers (clearing first would wipe them).
					local restoreSlot = tonumber(owned.StolenSlot) or tonumber(owned.Slot) or 0
					local restoreBanked = tonumber(owned.StolenBankedIncome)
						or tonumber(owned.BankedIncome) or 0
					local restorePlacedAt = tonumber(owned.StolenPlacedAt)
						or tonumber(owned.PlacedAt) or os.time()
					clearTheftMarkers(owned)
					_inTransit[instanceId] = nil
					clearOrphanedExpeditionFlag(player, instanceId, owned)
					local traitLevels: { [string]: number }? = nil
					if type(owned.TraitLevels) == "table" then
						local copied: { [string]: number } = {}
						for traitId, level in pairs(owned.TraitLevels) do
							copied[traitId] = level
						end
						traitLevels = copied
					end
					reinsertPlacedFull(player, {
						InstanceId = instanceId,
						CharacterId = owned.CharacterId,
						Slot = restoreSlot,
						Level = owned.Level,
						Glitched = owned.Glitched,
						Mutation = owned.Mutation,
						BankedIncome = restoreBanked,
						PlacedAt = restorePlacedAt,
						Evolved = owned.Evolved,
						EvolutionId = owned.EvolutionId,
						EvolvedTrait = owned.EvolvedTrait,
						EvolvedFormName = owned.EvolvedFormName,
						TraitLevels = traitLevels,
					})
					resolved += 1
				elseif ownerUserId > 0 then
					-- (d) The recorded owner is someone else.
					local victim = Players:GetPlayerByUserId(ownerUserId)
					if victim and victim.Parent then
						-- Rebuild the (memory-only) transit snapshot
						-- from the durable record and return it.
						local traitLevels: { [string]: number }? = nil
						if type(owned.TraitLevels) == "table" then
							local copied: { [string]: number } = {}
							for traitId, level in pairs(owned.TraitLevels) do
								copied[traitId] = level
							end
							traitLevels = copied
						end
						_inTransit[instanceId] = {
							Thief = player,
							Victim = victim,
							CharacterId = owned.CharacterId,
							Level = owned.Level,
							Mutation = owned.Mutation,
							Glitched = owned.Glitched == true,
							Evolved = owned.Evolved,
							EvolutionId = owned.EvolutionId,
							EvolvedTrait = owned.EvolvedTrait,
							EvolvedFormName = owned.EvolvedFormName,
							TraitLevels = traitLevels,
							Slot = tonumber(owned.StolenSlot) or 0,
							PlacedAt = tonumber(owned.StolenPlacedAt) or os.time(),
							BankedIncome = tonumber(owned.StolenBankedIncome) or 0,
							StolenAt = os.clock(),
							VictimUserId = ownerUserId,
						}
						if RaidService.ReturnStolen(instanceId) then
							-- R4-4: the persisted state voids this
							-- delivery — the Brainrot goes back to
							-- the victim, so a pending reward for
							-- it must not remain payable. R5-3:
							-- the void's durability is CHECKED (see
							-- rule (b) above).
							local _voidedD, voidDurableD = voidPendingRewardsForInstance(player, instanceId)
							if voidDurableD then
								resolved += 1
							else
								remaining += 1
							end
						else
							remaining += 1
						end
					else
						if tryEscrowReturn(player, ownerUserId, instanceId, owned, nil) then
							-- R4-4: escrowed back to the offline
							-- victim — this delivery is void, so a
							-- pending reward for it must not remain
							-- payable. R5-3: the void's durability
							-- is CHECKED (see rule (b) above).
							local _voidedE, voidDurableE = voidPendingRewardsForInstance(player, instanceId)
							if voidDurableE then
								resolved += 1
							else
								remaining += 1
							end
						else
							remaining += 1
							warn("[RaidService] Stale in-transit " .. tostring(instanceId)
								.. " kept: victim " .. tostring(ownerUserId)
								.. " offline and escrow unavailable; retries on a later rejoin")
						end
					end
				else
					-- (e) Legacy record with no recorded owner.
					remaining += 1
					warn("[RaidService] Stale in-transit " .. tostring(instanceId)
						.. " has no recorded owner; kept flagged for manual recovery")
				end
			end
		end
	end
	return resolved, remaining
end

-- RecoverOnRejoin(player): the canonical rejoin entry point — stale
-- transit reconciliation + pending-reward recovery, both idempotent.
-- Called from GameManager.onPlayerAdded (canonical) and from the
-- RaidService.Init PlayerAdded backstop (same call, so a missed
-- wiring in one place cannot strand a recovery). Returns
-- (transitResolved, transitRemaining, rewardsPaid, rewardsTotalCoins).
function RaidService.RecoverOnRejoin(player: Player): (number, number, number, number)
	-- R5-3: retry any void left pending by an earlier recovery
	-- before reconciling transit or paying rewards.
	RaidService.RetryPendingVoids(player)
	local resolved, remaining = RaidService.RecoverStaleTransit(player)
	local paid, total = RaidService.RecoverPendingRewards(player)
	return resolved, remaining, paid, total
end

-- ---------------------------------------------------------------------------
-- R4-10 (legacy §10): controlled administrative recovery of legacy
-- InTransit records with no recorded owner.
-- ---------------------------------------------------------------------------
-- Rule (e) records — InTransit with no StolenFromUserId — can never
-- be resolved automatically: there is no evidence of the rightful
-- owner, and guessing would grant stolen goods to the wrong player.
-- This mechanism is the ONLY way to resolve one, and it is
-- deliberately narrow:
--   * NO remote is wired to it. It is a server-side function only;
--     a normal client cannot invoke it (there is no remote name for
--     it and no OnServerEvent connects to it).
--   * The operator must be explicitly authorised: their UserId must
--     be in the set installed by SetLegacyRecoveryOperators (default:
--     empty — nobody is authorised until a server operator installs
--     the set from the server console / Main.server.luau). An
--     unauthorised caller is refused without touching any data.
--   * The caller supplies the rightful owner EXPLICITLY
--     (ownerUserId) — the function never guesses. Both the holder
--     (targetUserId, whose key holds the flagged record) and the
--     owner must be online with loaded data.
--   * Exactly-one-owner is enforced before anything moves: if any
--     OTHER online player already holds a clean copy of the same
--     InstanceId, the recovery is refused (that copy is the owner;
--     the flagged record is a stale duplicate and must be handled
--     by the normal reconciler, not granted again).
--   * The record is restored to the owner (moved there when the
--     owner differs from the holder), theft markers cleared, the
--     placed copy restored from the Stolen* fields (rule (c)
--     restore), and both saves verified.
-- MANUAL PROCEDURE (when no operator is configured or a party is
-- offline): 1) identify the flagged record's key (the holder's
-- Brainrot_Player_<UserId>) and confirm from server logs / the
-- victim's report who the rightful owner is — never guess from the
-- CharacterId alone; 2) wait until both holder and owner are online
-- (or restore from a DataStore backup in the Creator Dashboard);
-- 3) from the server console, install the operator set and call
-- RecoverLegacyRecord with the explicit owner; 4) verify exactly
-- one owned copy exists afterwards (count across both players'
-- keys). If ownership cannot be established, leave the record
-- flagged — a lost Brainrot is recoverable later; a wrongly granted
-- one is a duplication.
local _legacyOperators: { [number]: boolean } = {}

function RaidService.SetLegacyRecoveryOperators(userIds: { number }): boolean
	if type(userIds) ~= "table" then
		return false
	end
	local nextSet: { [number]: boolean } = {}
	for _, id in ipairs(userIds) do
		local num = tonumber(id)
		if num ~= nil and num > 0 then
			nextSet[num] = true
		end
	end
	_legacyOperators = nextSet
	return true
end

function RaidService.RecoverLegacyRecord(operator: Player?, targetUserId: any, instanceId: any, ownerUserId: any): (boolean, string?)
	if not operator or not operator:IsA("Player") then
		return false, "operator required"
	end
	if _legacyOperators[operator.UserId] ~= true then
		warn("[RaidService] Legacy recovery refused: " .. operator.Name .. " is not an authorised operator")
		return false, "not authorised"
	end
	local targetId = tonumber(targetUserId)
	local ownerId = tonumber(ownerUserId)
	local cleanInstance = sanitize(instanceId)
	if not targetId or not ownerId or not cleanInstance then
		return false, "invalid target / owner / instance"
	end
	local target = Players:GetPlayerByUserId(targetId)
	local owner = Players:GetPlayerByUserId(ownerId)
	if not target or not target.Parent then
		return false, "target must be online"
	end
	if not owner or not owner.Parent then
		return false, "owner must be online"
	end
	local owned = findOwnedRecord(target, cleanInstance)
	if not owned then
		return false, "no such record with target"
	end
	if owned.InTransit ~= true then
		return false, "record is not flagged in transit"
	end
	if tonumber(owned.StolenFromUserId) ~= nil then
		return false, "record has a recorded owner; use the normal reconciler"
	end
	-- Exactly-one-owner: nobody else may hold a clean copy.
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= target and other ~= owner then
			local otherOwned = findOwnedRecord(other, cleanInstance)
			if otherOwned and otherOwned.InTransit ~= true then
				return false, "another player already holds a clean copy"
			end
		end
	end
	if owner ~= target then
		local ownerOwned = findOwnedRecord(owner, cleanInstance)
		if ownerOwned and ownerOwned.InTransit ~= true then
			return false, "owner already holds a clean copy"
		end
		if not moveOwnedRecord(target, owner, cleanInstance) then
			return false, "ownership transfer failed"
		end
		owned = findOwnedRecord(owner, cleanInstance)
		if not owned then
			return false, "record lost in transfer"
		end
	end
	local restoreSlot = tonumber(owned.StolenSlot) or tonumber(owned.Slot) or 0
	local restoreBanked = tonumber(owned.StolenBankedIncome) or tonumber(owned.BankedIncome) or 0
	local restorePlacedAt = tonumber(owned.StolenPlacedAt) or tonumber(owned.PlacedAt) or os.time()
	clearTheftMarkers(owned)
	_inTransit[cleanInstance] = nil
	clearOrphanedExpeditionFlag(owner, cleanInstance, owned)
	local traitLevels: { [string]: number }? = nil
	if type(owned.TraitLevels) == "table" then
		local copied: { [string]: number } = {}
		for traitId, level in pairs(owned.TraitLevels) do
			copied[traitId] = level
		end
		traitLevels = copied
	end
	reinsertPlacedFull(owner, {
		InstanceId = cleanInstance,
		CharacterId = owned.CharacterId,
		Slot = restoreSlot,
		Level = owned.Level,
		Glitched = owned.Glitched,
		Mutation = owned.Mutation,
		BankedIncome = restoreBanked,
		PlacedAt = restorePlacedAt,
		Evolved = owned.Evolved,
		EvolutionId = owned.EvolutionId,
		EvolvedTrait = owned.EvolvedTrait,
		EvolvedFormName = owned.EvolvedFormName,
		TraitLevels = traitLevels,
	})
	local ownerSaved = saveVerified(owner)
	local targetSaved = true
	if owner ~= target then
		targetSaved = saveVerified(target)
	end
	if not ownerSaved or not targetSaved then
		warn("[RaidService] Legacy recovery for " .. tostring(cleanInstance)
			.. " committed in memory but a save failed; the record stays flagged for retry on rejoin")
		return false, "save failed after restore"
	end
	print(string.format(
		"[RaidService] Legacy record %s recovered to %s by operator %s",
		cleanInstance, owner.Name, operator.Name))
	return true, nil
end

-- StealBrainrot(thief, victimUserId, instanceId): full server-side flow.
function RaidService.StealBrainrot(thief: Player, victimUserId: any, instanceId: any): (boolean, string?)
	if not thief or not thief:IsA("Player") then
		return false, "invalid thief"
	end
	local cleanInstance = sanitize(instanceId)
	local victimId = tonumber(victimUserId)
	if not cleanInstance or not victimId then
		return false, "invalid target"
	end
	local victim = Players:GetPlayerByUserId(victimId)
	if not victim then
		return false, "victim must be online"
	end
	if victim == thief then
		return false, "cannot steal from yourself"
	end
	local thiefData = getData(thief)
	if not thiefData then
		return false, "no data"
	end
	local thiefCharacter = thief.Character
	local thiefHumanoid = thiefCharacter and thiefCharacter:FindFirstChildOfClass("Humanoid")
	if not thiefHumanoid or thiefHumanoid.Health <= 0 then
		return false, "not alive"
	end
	local thiefPos = getCharacterPosition(thief)
	if not thiefPos then
		return false, "no position"
	end
	-- Thief must be inside the victim's base: within 25 studs of any
	-- of the victim's placed pedestals (ground truth for base
	-- location), or the base plot / victim as fallback when no
	-- pedestals are known.
	local pedestals = getPlacedPositions(victim)
	local inBase = false
	if #pedestals > 0 then
		for _, pos in ipairs(pedestals) do
			if (thiefPos - pos).Magnitude <= 25 then
				inBase = true
				break
			end
		end
	else
		local basePos = getBasePosition(victim)
		if basePos then
			inBase = (thiefPos - basePos).Magnitude <= 25
		else
			local victimPos = getCharacterPosition(victim)
			inBase = victimPos ~= nil and (thiefPos - victimPos).Magnitude <= 20
		end
	end
	if not inBase then
		return false, "must be inside the victim's base"
	end
	-- Gate / lockdown entry check.
	local canEnter, enterReason = RaidService.CanEnter(thief, victim)
	if not canEnter then
		return false, enterReason
	end
	-- Per thief-victim cooldown (60s).
	local pairKey = tostring(thief.UserId) .. ":" .. tostring(victim.UserId)
	local lastAttempt = _pairCooldowns[pairKey] or -math.huge
	if os.clock() - lastAttempt < STEAL_COOLDOWN then
		return false, "steal on cooldown"
	end
	-- Protection checks.
	local placed = findPlaced(victim, cleanInstance)
	local protected, reason = RaidService.IsProtected(victim, placed)
	if protected then
		_pairCooldowns[pairKey] = os.clock()
		RaidService.RecordDefense(victim)
		return false, reason
	end
	-- Theft integrity (defense in depth): a target already in transit
	-- cannot be stolen again, and an instance away on an expedition
	-- cannot be a steal target even though its placed copy may still
	-- be listed. (A placed target is normally neither, but the owned
	-- record is the authority — check it, not the placed copy.)
	if _inTransit[cleanInstance] ~= nil then
		return false, "brainrot already in transit"
	end
	local victimOwned = findOwnedRecord(victim, cleanInstance)
	if victimOwned then
		if victimOwned.InTransit == true then
			return false, "brainrot already in transit"
		end
		if victimOwned.OnExpedition == true then
			return false, "brainrot is on an expedition"
		end
	end

	-- CarryService validation hook (placed + not locked + close to the
	-- pedestal + thief not already carrying). Pure validation.
	if _carryService and type(_carryService.TryPickupStolen) == "function" then
		local ok, valid, reason = pcall(function()
			return _carryService.TryPickupStolen(thief, cleanInstance, victim)
		end)
		if ok and not valid then
			return false, tostring(reason or "cannot pick up that Brainrot")
		end
	end

	-- R5-2 (P0): session-health gate, BEFORE the channel (and
	-- before the cooldown is burned — a refused steal costs the
	-- thief nothing but the attempt). BOTH parties must be saveable:
	-- a contested / load-failed thief cannot persist the theft (the
	-- victim's removal would save, the thief's never would — the
	-- instance disappears when the thief leaves), and a contested /
	-- load-failed victim cannot persist the removal either (their
	-- stored key keeps the placed copy while the thief's save lands
	-- the delivered copy — two owners). The gate runs after the
	-- cheap validations above, so an obviously invalid attempt
	-- never spends the lease probe.
	local thiefHealthy, thiefReason = checkSessionHealth(thief, "thief")
	if not thiefHealthy then
		return false, thiefReason
	end
	local victimHealthy, victimReason = checkSessionHealth(victim, "victim")
	if not victimHealthy then
		return false, victimReason
	end

	-- Channel: 3s, thief must stay within 8 studs of the anchor (the
	-- target's pedestal when known, else the base plot / victim).
	local anchor: Vector3? = nil
	if _baseService and type(_baseService.GetPlacedPosition) == "function" then
		local ok, pos = pcall(function()
			return _baseService.GetPlacedPosition(victim, cleanInstance)
		end)
		if ok and typeof(pos) == "Vector3" then
			anchor = pos
		end
	end
	local anchorPos = anchor or getBasePosition(victim) or getCharacterPosition(victim) or thiefPos
	_pairCooldowns[pairKey] = os.clock()
	alertSteal(victim, thief, placed.CharacterId, "Started")
	-- v1.1 companion RaidDetection: the victim's companions add lead
	-- time to the steal channel (GetRaidWarningSeconds, max +7.5s), so
	-- the victim has longer between the alert and the theft completing.
	local channelSeconds = STEAL_CHANNEL
	do
		local ok, extra = pcall(function()
			local mod = script.Parent:FindFirstChild("CompanionService")
			if not mod then
				return 0
			end
			local svc = require(mod)
			if type(svc.GetRaidWarningSeconds) ~= "function" then
				return 0
			end
			return svc.GetRaidWarningSeconds(victim)
		end)
		if ok and type(extra) == "number" then
			channelSeconds = STEAL_CHANNEL + math.clamp(extra, 0, 7.5)
		end
	end
	local channel = {
		Thief = thief,
		Victim = victim,
		InstanceId = cleanInstance,
		Placed = placed,
		Anchor = anchorPos,
		StartedAt = os.clock(),
		Cancelled = false,
	}
	_channels[thief] = channel
	local channelOk = true
	local waited = 0
	while waited < channelSeconds do
		task.wait(0.1)
		waited += 0.1
		-- R5-2 test-only hook (see _TestSetStealChannelHook): the
		-- suite takes the thief's lease here to prove the
		-- post-channel gate below refuses the steal.
		if _testStealChannelHook ~= nil then
			pcall(_testStealChannelHook, thief, cleanInstance)
		end
		if channel.Cancelled or _channels[thief] ~= channel then
			channelOk = false
			break
		end
		local current = thief.Character
		local currentHumanoid = current and current:FindFirstChildOfClass("Humanoid")
		local currentPos = getCharacterPosition(thief)
		if not currentHumanoid or currentHumanoid.Health <= 0 or not currentPos then
			channelOk = false
			break
		end
		if (currentPos - anchorPos).Magnitude > CHANNEL_RADIUS then
			channelOk = false -- moving cancels the channel
			break
		end
	end
	_channels[thief] = nil
	if not channelOk then
		-- Failed theft: thief stunned 3s + the 60s cooldown stands.
		applyStun(thief, 3)
		alertSteal(victim, thief, placed.CharacterId, "Failed")
		return false, "channel interrupted"
	end
	-- Re-check protections AFTER the channel: the victim may have
	-- raised a shield or triggered lockdown during the 3s. v1.0.0
	-- checked only before the channel, so a mid-channel lockdown was
	-- ignored and the steal succeeded anyway.
	local stillProtected, protectionReason = RaidService.IsProtected(victim, placed)
	if stillProtected then
		alertSteal(victim, thief, placed.CharacterId, "Failed")
		return false, protectionReason
	end
	-- R5-2 (P0): session-health gate, AFTER the channel. The 3 s
	-- channel yields: either party's lease can be taken over while
	-- it runs (the pre-channel check is stale by now), and the
	-- removal below is the point of no return for the victim's
	-- stored copy — refusing here leaves the victim untouched
	-- (placed copy intact, no transit, no carry) and the 60 s
	-- cooldown stands, exactly as for a failed channel.
	local thiefHealthy2, thiefReason2 = checkSessionHealth(thief, "thief")
	if not thiefHealthy2 then
		alertSteal(victim, thief, placed.CharacterId, "Failed")
		return false, thiefReason2
	end
	local victimHealthy2, victimReason2 = checkSessionHealth(victim, "victim")
	if not victimHealthy2 then
		alertSteal(victim, thief, placed.CharacterId, "Failed")
		return false, victimReason2
	end

	-- Success: remove from the victim's base, mark in transit. The
	-- Brainrot is NOT the thief's yet — see ConfirmDelivery.
	local removed = removePlaced(victim, cleanInstance)
	if not removed then
		return false, "target no longer placed"
	end
	-- Full steal snapshot: everything ReturnStolen needs to restore
	-- the victim's placed copy exactly. Evolution / trait fields live
	-- ONLY on the owned record, so they are captured from it here (the
	-- placed copy never carries them). TraitLevels is copied, not aliased.
	-- R2-1 (N1): the OWNED record is authoritative for Level /
	-- Mutation / Glitched. The placed copy is a snapshot that can lag
	-- the owned record — MutateBrainrot writes the owned record only
	-- (a paid mutation applied after placement never reaches the
	-- placed copy), so a stale placed value used to overwrite the paid
	-- mutation at delivery. Placed values survive only as the fallback
	-- when the owned record has none (e.g. a legacy seeded instance
	-- whose Mutation was never mirrored onto the owned record).
	--   Level: the only writer (BaseService.UpgradeBrainrot) updates
	--     both copies, so owned and placed agree in practice; owned
	--     still wins as the registry.
	--   Glitched: no live writer diverges them today (Lab trait
	--     upgrades require unplaced, Conveyor writes both), but the
	--     rule is the same — owned wins when an owned record exists.
	local stealOwned = findOwnedRecord(victim, cleanInstance)
	local traitLevels: { [string]: number }? = nil
	if stealOwned and type(stealOwned.TraitLevels) == "table" then
		local copy: { [string]: number } = {}
		for traitId, level in pairs(stealOwned.TraitLevels) do
			copy[traitId] = level
		end
		traitLevels = copy
	end
	local snapshot = {
		Thief = thief,
		Victim = victim,
		CharacterId = placed.CharacterId,
		Level = (stealOwned and tonumber(stealOwned.Level)) or tonumber(placed.Level) or 1,
		Mutation = (stealOwned and stealOwned.Mutation) or placed.Mutation,
		Glitched = (stealOwned ~= nil and stealOwned.Glitched == true) or (stealOwned == nil and placed.Glitched == true),
		Evolved = stealOwned and stealOwned.Evolved or nil,
		EvolutionId = stealOwned and stealOwned.EvolutionId or nil,
		EvolvedTrait = stealOwned and stealOwned.EvolvedTrait or nil,
		EvolvedFormName = stealOwned and stealOwned.EvolvedFormName or nil,
		TraitLevels = traitLevels,
		Slot = tonumber(placed.Slot) or 0,
		PlacedAt = tonumber(placed.PlacedAt) or os.time(),
		BankedIncome = tonumber(placed.BankedIncome) or 0,
		StolenAt = os.clock(),
		-- R2-5: durable owner identity. The snapshot itself is
		-- memory-only and dies with the server; VictimUserId is
		-- also stamped onto the moved owned record (below) so the
		-- recovery can find the victim after a crash / restart.
		VictimUserId = victim.UserId,
	}
	-- In-transit hold: move the OwnedInstances record to the thief so
	-- the instance can be placed in their base. ReturnStolen moves it
	-- back if the thief dies or drops it before delivering. The move
	-- MUST succeed before any transit state is created: if it fails,
	-- roll the placed copy back and fail the steal — otherwise the
	-- instance would sit unplaced with the victim while the transit
	-- record claims the thief has it.
	local movedRecord = moveOwnedRecord(victim, thief, cleanInstance)
	if not movedRecord then
		-- R3-6: the rollback restores the just-removed placed copy
		-- without the ownership guard (enforceOwnership == false):
		-- the owned record may be missing precisely because the
		-- transfer just failed and lost it, and refusing here would
		-- strand the victim with neither copy.
		if not reinsertPlaced(victim, placed, false) then
			warn("[RaidService] Steal rollback failed for " .. tostring(cleanInstance))
		end
		return false, "ownership transfer failed"
	end
	-- Persistent server-validated flag on the moved record itself:
	-- while true, no other system may consume, mutate, evolve, fuse,
	-- place or carry this instance (see the guards in FusionService,
	-- MutationService, LaboratoryService and CarryService). Cleared
	-- only by ConfirmDelivery / ReturnStolen, after the transfer
	-- commits.
	movedRecord.InTransit = true
	-- R2-5: durable theft identity on the record itself. The memory
	-- snapshot (_inTransit) dies with the server, but this record is
	-- persisted wholesale by SaveData, so a crash / leave / restart
	-- can still identify the victim and restore the return. The
	-- Stolen* fields are recovery-only (live logic reads the snapshot
	-- and the owned fields, never these); they are cleared on commit
	-- with InTransit by ConfirmDelivery / ReturnStolen.
	-- StolenSlot / StolenPlacedAt / StolenBankedIncome carry the
	-- return-restore values the moved record itself does not have
	-- (R1: it carries no BankedIncome / PlacedAt), so a rejoin
	-- reconciler can rebuild the victim's placed copy exactly.
	movedRecord.StolenFromUserId = victim.UserId
	movedRecord.StolenSlot = tonumber(placed.Slot) or 0
	movedRecord.StolenPlacedAt = tonumber(placed.PlacedAt) or os.time()
	movedRecord.StolenBankedIncome = tonumber(placed.BankedIncome) or 0
	_inTransit[cleanInstance] = snapshot
	if thief.Character then
		thief.Character:SetAttribute("CarryingStolen", cleanInstance)
	end
	-- Carry it for real (visual + slow) so BaseService.PlaceBrainrot
	-- accepts it in the thief's own base. Prefer SetCarried: unlike
	-- ForceCarry it marks the carry Stolen, so a manual drop or death
	-- routes the Brainrot back to the victim through
	-- RaidService.DropStolen instead of dropping it as a world pickup
	-- anyone could grab. v1.0.0 used ForceCarry, so the stolen-carry
	-- drop path was a world pickup until the 5s poll noticed.
	if _carryService and type(_carryService.SetCarried) == "function" then
		pcall(function()
			_carryService.SetCarried(thief, placed)
		end)
	elseif _carryService and type(_carryService.ForceCarry) == "function" then
		pcall(function()
			_carryService.ForceCarry(thief, placed)
		end)
	end
	-- R2-5 (R6 review): persist BOTH sides of the theft promptly. The
	-- victim's save captures the removal; the thief's save captures
	-- the InTransit record WITH its durable StolenFromUserId, so a
	-- crash after this point still has a recoverable record. The saves
	-- stay asynchronous (no remote-path stall); completion is not
	-- observed here — the leave / shutdown saves and the autosave are
	-- the backstops, and the rejoin reconciler covers a crash before
	-- any of them lands.
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(victim)
		end)
		pcall(function()
			_dataService.SaveData(thief)
		end)
	end)
	alertSteal(victim, thief, placed.CharacterId, "Success")
	print(string.format(
		"[RaidService] %s stole %s from %s (in transit)",
		thief.Name, placed.CharacterId, victim.Name
	))
	return true, cleanInstance
end

local function onSteal(thief: Player, payload: any)
	if not thief or not thief:IsA("Player") then
		return
	end
	if not rateOk(thief, "StealBrainrot", 1) then
		return
	end
	local victimUserId: any = nil
	local instanceId: any = nil
	if type(payload) == "table" then
		victimUserId = payload.VictimUserId or payload.Victim
		instanceId = payload.InstanceId
	elseif type(payload) == "string" then
		instanceId = payload
	end
	local ok, err = RaidService.StealBrainrot(thief, victimUserId, instanceId)
	if not ok then
		warn("[RaidService] Steal failed for " .. thief.Name .. ": " .. tostring(err))
	end
end

function RaidService.Init(dataService: any, baseService: any?, carryService: any?, opts: any?)
	assert(dataService ~= nil, "[RaidService] Init requires DataService")
	_dataService = dataService
	-- GameManager's generic Init passes EconomyService / the map
	-- positionally; only accept arguments implementing the expected
	-- interface. The real services arrive via the setters above.
	if baseService and type(baseService.GetPlaced) == "function" then
		_baseService = baseService
	end
	if carryService
		and (type(carryService.ForceCarry) == "function" or type(carryService.DropCarried) == "function")
	then
		_carryService = carryService
	end
	if type(opts) == "table" then
		if opts.MutationService and type(opts.MutationService.MoveInstance) == "function" then
			_mutationService = opts.MutationService
		end
		if opts.QuestService and type(opts.QuestService.RecordEvent) == "function" then
			_questService = opts.QuestService
		end
	end

	-- A thief who dies while carrying a stolen Brainrot loses it: it
	-- returns to the victim's base slot.
	local function hookDeath(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid then
				humanoid.Died:Connect(function()
					RaidService.DropStolen(player)
				end)
			end
		end)
	end
	Players.PlayerAdded:Connect(hookDeath)
	-- R2-4 (R13) + R2-5: retry any unpaid steal reward and resolve any
	-- stale in-transit record on rejoin. Best-effort and idempotent
	-- (RecoverOnRejoin is a no-op when nothing is pending / stale), so
	-- it is safe to run here as well as from GameManager.onPlayerAdded
	-- (the canonical rejoin caller) if the lifecycle worker wires it
	-- there.
	Players.PlayerAdded:Connect(function(player)
		pcall(function()
			RaidService.RecoverOnRejoin(player)
		end)
	end)
	-- Players already in-game when this service initialises (server
	-- reload) never fire PlayerAdded: hook them too, or their deaths
	-- would only be caught by the 5s poll. v1.0.0 missed them.
	for _, player in ipairs(Players:GetPlayers()) do
		hookDeath(player)
		pcall(function()
			RaidService.RecoverOnRejoin(player)
		end)
	end
	-- R2-5 lifecycle: the leave-time return must run BEFORE DataService
	-- saves (DataService.Init runs first and its PlayerRemoving handler
	-- saves then clears the cache — a direct PlayerRemoving connection
	-- here would fire AFTER that save and persist the pre-return
	-- state). When DataService exposes the pre-save hook registry,
	-- register HandlePlayerLeaving there so the recovery is ordered
	-- inside the save handler itself; otherwise fall back to a direct
	-- PlayerRemoving connection (uncoordinated ordering — the save may
	-- land before the return — kept only so an older DataService still
	-- returns the Brainrot in memory).
	local hooked = false
	if _dataService and type(_dataService.RegisterPreSaveHook) == "function" then
		local okHook = pcall(function()
			hooked = _dataService.RegisterPreSaveHook(RaidService.HandlePlayerLeaving) == true
		end)
		hooked = okHook and hooked
	end
	if not hooked then
		warn("[RaidService] No DataService pre-save hook; using direct PlayerRemoving fallback (save ordering uncoordinated)")
		Players.PlayerRemoving:Connect(function(player)
			RaidService.HandlePlayerLeaving(player)
		end)
	end

	-- In-transit watchdog: delivery / drop detection (see PollInTransit).
	task.spawn(function()
		while true do
			task.wait(5)
			local ok, err = pcall(function()
				RaidService.PollInTransit()
			end)
			if not ok then
				warn("[RaidService] In-transit poll failed: " .. tostring(err))
			end
		end
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(_names.StealBrainrot)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onSteal)
		else
			warn("[RaidService] StealBrainrot remote not found, steal handler not wired")
		end
	end)
end

return RaidService
