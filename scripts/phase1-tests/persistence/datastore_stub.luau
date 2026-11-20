-- datastore_stub.luau — stubbed DataStore API for the persistence suite.
--
-- Models the Roblox DataStore contract faithfully enough to test R3:
--   * GetAsync / SetAsync / UpdateAsync / RemoveAsync, with deep-copy
--     (serialisation) semantics on every read and write, so the code
--     under test can never alias the stored value.
--   * Injectable failures: fail the next N calls of one operation
--     (globally, or for one key only), to model DataStore outages.
--   * Optimistic-retry UpdateAsync: a per-key version counter. The
--     transform runs against a snapshot; if the key changed before the
--     commit (a concurrent writer), the transform is RE-RUN against
--     the fresh value — exactly how Roblox retries an UpdateAsync
--     transform on contention.
--   * One-shot `_beforeCommit` hook, fired inside SetAsync and
--     UpdateAsync between the transform/read and the commit: the test
--     arms it to run a second server's append in the race window.
--     A SetAsync has no retry, so a write interleaved there is a lost
--     update; an UpdateAsync retries its transform and survives.
--   * Callback purity + determinism checks: the transform receives a
--     deep copy of the old value; the stub errors if the transform
--     mutates its input, or if the same input ever produces a
--     different output (a retried callback must be deterministic).
--     An error here fails the test loudly — it is a bug in the code
--     under test, not in the stub.
--   * Call counters, so tests can assert the append path uses no
--     GetAsync / SetAsync at all (R3-2: no separate read-modify-write).
--
-- Usage:
--   local Stub = require("./datastore_stub")
--   local store = Stub.newStore()
--   store:seed(key, value)              -- put a value in directly
--   store:peek(key)                     -- raw stored value (deep copy)
--   store:failGetAsync(n)               -- next n GetAsync calls error
--   store:failGetAsyncForKey(key, n)    -- same, for one key only
--   store:failSetAsync(n) / store:failUpdateAsync(n)
--   store:failRemoveAsync(n)
--   store:armBeforeCommit(fn)           -- one-shot race-window hook
--   store:resetFailures()               -- clear all injected failures
local Stub = {}

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function deepEqual(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k, _ in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function Stub.newStore()
	local store = {
		_data = {},
		_versions = {},
		_getFail = 0,
		_getFailKeys = {},
		_setFail = 0,
		_updateFail = 0,
		_updateFailKeys = {},
		_removeFail = 0,
		_beforeCommit = nil,
		calls = { GetAsync = 0, SetAsync = 0, UpdateAsync = 0, RemoveAsync = 0 },
		transformCalls = 0,
		updateRetries = 0,
	}

	function store:seed(key, value)
		self._data[key] = deepCopy(value)
		self._versions[key] = (self._versions[key] or 0) + 1
	end

	function store:peek(key)
		return deepCopy(self._data[key])
	end

	function store:failGetAsync(n)
		self._getFail += n
	end

	function store:failGetAsyncForKey(key, n)
		self._getFailKeys[key] = (self._getFailKeys[key] or 0) + n
	end

	-- R4: fail the next n UpdateAsync calls for ONE key only (the
	-- global failUpdateAsync would also break unrelated sidecar
	-- parks in the same flow — e.g. failing only the victim's
	-- escrow key while the thief's pending park must still land).
	function store:failUpdateAsyncForKey(key, n)
		self._updateFailKeys[key] = (self._updateFailKeys[key] or 0) + n
	end

	function store:failSetAsync(n)
		self._setFail += n
	end

	function store:failUpdateAsync(n)
		self._updateFail += n
	end

	function store:failRemoveAsync(n)
		self._removeFail += n
	end

	function store:armBeforeCommit(fn)
		self._beforeCommit = fn
	end

	function store:resetFailures()
		self._getFail = 0
		self._getFailKeys = {}
		self._setFail = 0
		self._updateFail = 0
		self._updateFailKeys = {}
		self._removeFail = 0
		self._beforeCommit = nil
	end

	function store:resetCounts()
		self.calls = { GetAsync = 0, SetAsync = 0, UpdateAsync = 0, RemoveAsync = 0 }
		self.transformCalls = 0
		self.updateRetries = 0
	end

	local function fireBeforeCommit(self)
		if self._beforeCommit ~= nil then
			local hook = self._beforeCommit
			self._beforeCommit = nil
			hook()
		end
	end

	function store:GetAsync(key)
		self.calls.GetAsync += 1
		local keyFail = self._getFailKeys[key] or 0
		if keyFail > 0 then
			self._getFailKeys[key] = keyFail - 1
			error("StubStore: injected GetAsync failure for " .. key)
		end
		if self._getFail > 0 then
			self._getFail -= 1
			error("StubStore: injected GetAsync failure")
		end
		return deepCopy(self._data[key])
	end

	function store:SetAsync(key, value)
		self.calls.SetAsync += 1
		if self._setFail > 0 then
			self._setFail -= 1
			error("StubStore: injected SetAsync failure")
		end
		-- Race window: a second writer may commit first. SetAsync has
		-- no retry — whatever commits last wins whole-key.
		fireBeforeCommit(self)
		self._data[key] = deepCopy(value)
		self._versions[key] = (self._versions[key] or 0) + 1
	end

	function store:UpdateAsync(key, transformFn)
		self.calls.UpdateAsync += 1
		local keyFail = self._updateFailKeys[key] or 0
		if keyFail > 0 then
			self._updateFailKeys[key] = keyFail - 1
			error("StubStore: injected UpdateAsync failure for " .. key)
		end
		if self._updateFail > 0 then
			self._updateFail -= 1
			error("StubStore: injected UpdateAsync failure")
		end
		local attempts = 0
		-- Determinism is scoped to THIS UpdateAsync call: a retried
		-- callback must return the same output for the same input.
		-- (Different appends legitimately map the same empty input to
		-- different lists — each carries its own entry — so history
		-- must not leak across calls.)
		local attemptHistory = {}
		while true do
			attempts += 1
			if attempts > 10 then
				error("StubStore: UpdateAsync exceeded max transform retries")
			end
			local old = deepCopy(self._data[key])
			local version = self._versions[key] or 0
			-- Hand the transform a copy and snapshot it: the callback
			-- must not mutate its input (purity).
			local input = deepCopy(old)
			local inputSnapshot = deepCopy(old)
			self.transformCalls += 1
			local newValue = transformFn(input)
			if not deepEqual(input, inputSnapshot) then
				error("StubStore: UpdateAsync transform mutated its input (not a pure function)")
			end
			for _, prior in ipairs(attemptHistory) do
				if deepEqual(input, prior.input) and not deepEqual(newValue, prior.output) then
					error("StubStore: UpdateAsync transform is non-deterministic for the same input")
				end
			end
			table.insert(attemptHistory, { input = deepCopy(input), output = deepCopy(newValue) })
			-- Race window: a second writer may commit first.
			fireBeforeCommit(self)
			if (self._versions[key] or 0) == version then
				if newValue == nil then
					self._data[key] = nil
				else
					self._data[key] = deepCopy(newValue)
				end
				self._versions[key] = version + 1
				return deepCopy(newValue)
			end
			-- Key changed under us: retry the transform on the fresh
			-- value, exactly as Roblox does on contention.
			self.updateRetries += 1
		end
	end

	function store:RemoveAsync(key)
		self.calls.RemoveAsync += 1
		if self._removeFail > 0 then
			self._removeFail -= 1
			error("StubStore: injected RemoveAsync failure")
		end
		self._data[key] = nil
		self._versions[key] = (self._versions[key] or 0) + 1
	end

	return store
end

return Stub
