-- persistence_env.luau — loads the REAL DataService (copy under
-- persistence/services/, refreshed from src/ by refresh.sh) with a
-- stubbed DataStoreService, for the R3 persistence suite.
--
-- The stub store is shared by every test in one file (one Lune process
-- per test file, so module state never leaks between files). Tests use
-- distinct userIds per case; the store exposes failure injection and
-- race-window hooks (see datastore_stub.luau).
--
-- Usage in a test file:
--   local P = require("./persistence_env")
--   local H = P.H
--   local DS = P.loadDataService()          -- real DataService
--   -- mutant controls pass "./mutant/DataServiceOld" instead
--   local store = P.store
local H = require("../harness")
local Stub = require("./datastore_stub")

local P = {}
P.H = H

local store = Stub.newStore()
P.store = store

-- Route DataStoreService at the stub store; every other service keeps
-- the harness implementation.
local origGetService = game.GetService
game.GetService = function(_self, name)
	if name == "DataStoreService" then
		return {
			GetDataStore = function(_self, _storeName)
				return store
			end,
		}
	end
	return origGetService(_self, name)
end

-- DataService.Init guards BindToClose on RunService:IsStudio(); the
-- harness RunService stub does not define it. (Most tests do not call
-- Init, but the method must exist if they do.)
local runService = game:GetService("RunService")
runService.IsStudio = function()
	return true
end

-- Load the real DataService copy. `path` is relative to THIS file;
-- mutant controls pass "./mutant/DataServiceOld".
function P.loadDataService(path)
	return require(path or "./services/DataService")
end

-- Key names, mirroring DataService's escrowKeyFor / pendingKeyFor /
-- keyFor (kept here so tests can seed and peek the raw store).
function P.escrowKey(userId)
	return "Brainrot_Escrow_" .. tostring(userId)
end

function P.pendingKey(userId)
	return "Brainrot_Pending_" .. tostring(userId)
end

function P.mainKey(userId)
	return "Brainrot_Player_" .. tostring(userId)
end

-- Fixture: a full owned record as RaidService would escrow it.
function P.escrowRecord(instanceId, overrides)
	local record = {
		InstanceId = instanceId,
		CharacterId = "wobble_waffleton",
		Level = 5,
		Mutation = "golden",
		Glitched = true,
		Evolved = true,
		EvolutionId = "evolved_wobble_waffleton",
		EvolvedTrait = "Electric",
		EvolvedFormName = "Wobble Waffleton (Evolved)",
		TraitLevels = { Food = 2 },
		Placed = true,
		Slot = 2,
		PlacedAt = 1000000,
		BankedIncome = 500,
	}
	if overrides ~= nil then
		for k, v in pairs(overrides) do
			record[k] = v
		end
	end
	return record
end

-- Fixture: a pending steal-reward entry as RaidService records it.
function P.pendingEntry(instanceId, amount, overrides)
	local entry = {
		InstanceId = instanceId,
		CharacterId = "wobble_waffleton",
		Amount = amount or 300,
		Reason = "session cannot persist (DataStore load failed)",
		CreatedAt = 1000000,
	}
	if overrides ~= nil then
		for k, v in pairs(overrides) do
			entry[k] = v
		end
	end
	return entry
end

-- Find an entry with this InstanceId in a stored sidecar list.
function P.findInList(list, instanceId)
	if type(list) ~= "table" then
		return nil
	end
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.InstanceId == instanceId then
			return entry
		end
	end
	return nil
end

-- Fixture: a pending steal-reward entry for one transaction.
function P.pendingEntryTx(instanceId, amount, txId)
	return P.pendingEntry(instanceId, amount, { TxId = txId })
end

-- Sum of pending Amounts for one InstanceId across the aggregate
-- entry (data.PendingRewards[InstanceId].Amount).
function P.pendingTotal(data, instanceId)
	if type(data) ~= "table" or type(data.PendingRewards) ~= "table" then
		return 0
	end
	local entry = data.PendingRewards[instanceId]
	if type(entry) ~= "table" then
		return 0
	end
	return math.floor(tonumber(entry.Amount) or 0)
end

-- Number of distinct transactions (TxIds) recorded for one instance
-- in the aggregate entry's Txns sub-ledger (0 for a legacy entry
-- with no Txns — its Amount is one implicit transaction).
function P.pendingTxnCount(data, instanceId)
	if type(data) ~= "table" or type(data.PendingRewards) ~= "table" then
		return 0
	end
	local entry = data.PendingRewards[instanceId]
	if type(entry) ~= "table" or type(entry.Txns) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(entry.Txns) do
		n += 1
	end
	return n
end

-- Total Amount across a stored sidecar list for one InstanceId.
function P.sidecarTotal(list, instanceId)
	if type(list) ~= "table" then
		return 0
	end
	local total = 0
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.InstanceId == instanceId then
			total += math.floor(tonumber(entry.Amount) or 0)
		end
	end
	return total
end

-- P.newRaidEnv(dsPath): load the REAL RaidService (theft/services
-- copy, require-patched by theft/refresh.sh) wired to the REAL
-- DataService under test (persistence/services copy, or a mutant
-- path such as "./mutant/DataServiceOld"), with the harness stub
-- base / carry / mutation services. The real DataService is the
-- persistence layer, so sidecar parks, merges, saves and deletions
-- all run through the code under test — no fake answers.
-- ORDERING: create the env BEFORE creating test players.
-- RaidService.Init runs its PlayerAdded backstop over players
-- already in game, which would LoadData them before the test seeds
-- their store keys. (DataService.Init is deliberately NOT called:
-- no autosave loop; tests drive SaveData explicitly.)
function P.newRaidEnv(dsPath)
	local DS = P.loadDataService(dsPath)
	local base = H.newBaseService(DS)
	local MutationService = require("../theft/services/MutationService")
	local CarryService = require("../theft/services/CarryService")
	local RaidService = require("../theft/services/RaidService")
	MutationService.Init(DS)
	CarryService.Init(DS, base)
	RaidService.Init(DS, base, CarryService, { MutationService = MutationService })
	RaidService.SetBaseService(base)
	RaidService.SetCarryService(CarryService)
	RaidService.SetMutationService(MutationService)
	CarryService.SetRaidService(RaidService)
	return {
		dataService = DS,
		base = base,
		mutation = MutationService,
		carry = CarryService,
		raid = RaidService,
	}
end

-- P.newLoadedPair(env, thiefId, victimId): a steal-fixture pair
-- (H.newPair) whose data lives in the REAL DataService. The fixture
-- tables are built against a throwaway env (H.newPair only needs
-- dataService.Ensure), seeded into the stub store's main keys, and
-- then loaded through the real LoadData. LastLogin is set to now so
-- no daily bonus fires on load. Returns the H.newPair pair table; the
-- LIVE data is DS.GetData(player) — the fixture tables themselves
-- are pre-load copies, so never read coins / ownership off them
-- after load.
function P.newLoadedPair(env, thiefId, victimId)
	local DS = env.dataService
	local captured = {}
	local fakeEnv = {
		dataService = {
			Ensure = function(player, data)
				captured[player] = data
			end,
		},
	}
	local pair = H.newPair(fakeEnv, thiefId, victimId)
	local now = os.time()
	pair.thiefData.LastLogin = now
	pair.victimData.LastLogin = now
	store:seed(P.mainKey(thiefId), pair.thiefData)
	store:seed(P.mainKey(victimId), pair.victimData)
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	return pair
end

function P.countInList(list, instanceId)
	if type(list) ~= "table" then
		return 0
	end
	local n = 0
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.InstanceId == instanceId then
			n += 1
		end
	end
	return n
end

return P
