-- r4_env.luau — environment builder for the R4-transactions suite.
--
-- Builds on the R3 persistence env (same stub DataStore, same failure
-- injection, same loaded-pair fixtures) and loads the REAL R4
-- services from the r4-transactions/services copies (refreshed from
-- src/ by refresh.sh): DataService, RaidService (via the theft
-- copies, as the persistence env does), BaseService (stub base from
-- the harness; H.newBaseEnv swaps in the real one), plus the
-- coin-spending services on demand.
--
-- Mutant controls pass opts.raidPath / opts.dsPath to load the
-- reverted copies under mutant/ instead of the fixed ones.
--
-- ORDERING: create the env BEFORE creating test players.
-- RaidService.Init runs its PlayerAdded backstop over players
-- already in game, which would LoadData them before the test seeds
-- their store keys. (DataService.Init is deliberately NOT called:
-- no autosave loop; tests drive SaveData explicitly.)
local P = require("../persistence/persistence_env")
local H = P.H

local R = {}
R.P = P
R.H = H
R.store = P.store

-- R.newEnv(opts): load the REAL RaidService + DataService under test.
-- opts.raidPath: require path for RaidService (default: the fixed
-- theft/services copy). opts.dsPath: require path for DataService
-- (default: the fixed r4/services copy). Paths are relative to THIS
-- file.
function R.newEnv(opts)
	opts = opts or {}
	local DS = require(opts.dsPath or "./services/DataService")
	local base = H.newBaseService(DS)
	local MutationService = require("../theft/services/MutationService")
	local CarryService = require("../theft/services/CarryService")
	local RaidService = require(opts.raidPath or "../theft/services/RaidService")
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

-- R.newLoadedPlayer(env, userId, coins): a single extra player with
-- loaded data (a second thief, an operator, ...). LastLogin is now
-- so no daily bonus fires on load. Returns the player; the LIVE data
-- is env.dataService.GetData(player).
function R.newLoadedPlayer(env, userId, coins)
	local player = H.newPlayer(userId, "Player" .. tostring(userId), 30, Vector3.new(0, 0, 0))
	local data = {
		Level = 5,
		Coins = coins or 100000,
		Gems = 0,
		MutationCrystals = 1000,
		Rebirths = 0,
		Unlocked = { "wobble_waffleton", "turbo_turnip", "glitchy_goose" },
		OwnedInstances = {},
		Base = { Placed = {} },
		LabDiscoveries = {},
		LastLogin = os.time(),
	}
	P.store:seed(P.mainKey(userId), data)
	env.dataService.LoadData(player)
	return player
end

-- R.failSetAsyncForKey(key): fail SetAsync only for one key (the
-- stub's failSetAsync is global). Returns a restore function.
-- (Same pattern as persistence test 15, local to this suite.)
function R.failSetAsyncForKey(key)
	local store = P.store
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

-- R.failGetAsyncForKey is the stub's own failGetAsyncForKey (see
-- datastore_stub.luau); R4-1's fail-closed delivery test arms it on
-- the victim's escrow key.

-- R.findTxIdInList(list, txId): the sidecar entry with this TxId.
function R.findTxIdInList(list, txId)
	if type(list) ~= "table" then
		return nil
	end
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.TxId == txId then
			return entry
		end
	end
	return nil
end

return R
