-- r5_env.luau — environment builder for the R5-transactions suite.
--
-- Builds on the R3 persistence env (same stub DataStore, same failure
-- injection, same loaded-pair fixtures) and loads the REAL R5
-- services from the r5-transactions/services copies (refreshed from
-- src/ by refresh.sh): DataService, plus RaidService via the theft
-- copies (as the persistence env does).
--
-- R5 addition: GetDataStore outage injection. The persistence env
-- stubs DataStoreService:GetDataStore to always return the stub
-- store; this file re-wraps game.GetService so that while the outage
-- flag is set, GetDataStore ERRORS — modelling a DataStore API
-- outage (or Studio with API access off). The stub store itself
-- stays seedable/peekable throughout (seed/peek bypass GetDataStore,
-- exactly as the real DataStore keeps its data while the API handle
-- is unavailable). DataService captures its DataStoreService handle
-- at require time, so the wrapper MUST be installed before newEnv()
-- requires DataService — it is installed at this file's top level.
--
-- Mutant controls pass opts.raidPath / opts.dsPath to load the
-- reverted copies under mutant/ instead of the fixed ones.
--
-- ORDERING: require this file, set the outage flag if the test needs
-- it, THEN call R5.newEnv(). RaidService.Init runs its PlayerAdded
-- backstop over players already in game, which would LoadData them
-- before the test seeds their store keys. (DataService.Init is
-- deliberately NOT called: no autosave loop; tests drive SaveData
-- explicitly.)
local P = require("../persistence/persistence_env")
local H = P.H

local R5 = {}
R5.P = P
R5.H = H
R5.store = P.store

local _outage = false
local _outageCalls = 0

local _prevGetService = game.GetService
game.GetService = function(self, name)
	if name == "DataStoreService" then
		return {
			GetDataStore = function(_self, _storeName)
				if _outage then
					_outageCalls += 1
					error("StubDataStoreService: injected GetDataStore failure (outage)")
				end
				return P.store
			end,
		}
	end
	return _prevGetService(self, name)
end

-- R5.setDataStoreOutage(on): while on, every GetDataStore call
-- errors (the DataStore API is down). While off, it returns the stub
-- store as usual. DataService retries GetDataStore on every getStore()
-- call (a failed attempt is NOT cached), so flipping the flag off
-- models the store recovering mid-session.
function R5.setDataStoreOutage(on)
	_outage = on == true
end

function R5.isDataStoreOutage()
	return _outage
end

function R5.getDataStoreOutageCalls()
	return _outageCalls
end

-- R5.newEnv(opts): load the REAL RaidService + DataService under test.
-- opts.raidPath: require path for RaidService (default: the fixed
-- theft/services copy). opts.dsPath: require path for DataService
-- (default: the fixed r5/services copy). Paths are relative to THIS
-- file.
function R5.newEnv(opts)
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

-- R5.newPairFixture(thiefId, victimId, opts): build an H.newPair
-- steal fixture (players + data tables) WITHOUT loading it. The
-- caller seeds the durable store keys from pair.thiefData /
-- pair.victimData, then loads it with R5.loadUnloadedPair. LastLogin
-- is set to now on both fixtures so no daily bonus fires on either
-- load path.
function R5.newPairFixture(thiefId, victimId, opts)
	local fakeEnv = {
		dataService = {
			Ensure = function(_player, _data)
			end,
		},
	}
	local pair = H.newPair(fakeEnv, thiefId, victimId, opts)
	local now = os.time()
	pair.thiefData.LastLogin = now
	pair.victimData.LastLogin = now
	return pair
end

-- R5.loadUnloadedPair(env, pair): LoadData both players of a pair
-- built by R5.newPairFixture, then merge the fixture tables into the
-- LIVE caches field-by-field. When the DataStore API is down the
-- loads fail and the live state is exactly the fixture (the victim
-- owns the placed target, the thief does not) while the durable
-- store keys hold whatever the test seeded separately. When the
-- store is up the loads succeed first (lease + sidecar merge run),
-- and the fixture merge then overwrites the live state — the caller
-- must seed sidecars AFTER this call in that case if it wants them
-- unmerged. Returns the pair; the LIVE data is
-- env.dataService.GetData(player).
function R5.loadUnloadedPair(env, pair)
	local DS = env.dataService
	DS.LoadData(pair.thief)
	DS.LoadData(pair.victim)
	local liveThief = DS.GetData(pair.thief)
	local liveVictim = DS.GetData(pair.victim)
	assert(liveThief ~= nil, "loadUnloadedPair: no thief cache after load")
	assert(liveVictim ~= nil, "loadUnloadedPair: no victim cache after load")
	for k, v in pairs(pair.thiefData) do
		liveThief[k] = v
	end
	for k, v in pairs(pair.victimData) do
		liveVictim[k] = v
	end
	return pair
end

-- R5.newUnloadedPair(env, thiefId, victimId, opts): the
-- build + load combination for tests that run with the DataStore API
-- DOWN from the start (no seeding between build and load).
function R5.newUnloadedPair(env, thiefId, victimId, opts)
	return R5.loadUnloadedPair(env, R5.newPairFixture(thiefId, victimId, opts))
end

-- R5.newLoadedPlayer(env, userId, coins): a single extra player with
-- loaded data (mirrors r4_env.newLoadedPlayer; store must be UP).
function R5.newLoadedPlayer(env, userId, coins)
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

return R5
