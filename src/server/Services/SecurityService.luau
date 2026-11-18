--!strict
-- SecurityService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Central, dependency-free anti-abuse helpers. Other server services
-- SHOULD use these (RateLimit / ValidateDistance / ValidateCooldown /
-- SanitizeId) instead of rolling their own tables, but every service also
-- keeps a local fallback so it still works if this module fails to load.
-- Only Players / RunService are used here; no DataService, no remotes,
-- no other service is ever required.

local Players = game:GetService("Players")

local SecurityService = {}

-- Per-player, per-key timestamp of the last allowed call (os.clock()).
local _lastCall: { [Player]: { [string]: number } } = {}
-- Per-player call log, newest last. Capped so a spammer cannot grow it.
local _callLog: { [Player]: { { Key: string, At: number, Allowed: boolean } } } = {}
local MAX_LOG_ENTRIES = 200
-- Burst windows: per-player, per-key list of recent call timestamps.
local _bursts: { [Player]: { [string]: { number } } } = {}
local MAX_BURST_ENTRIES = 64

local _cleanupHooked = false
-- Local state clear, shared by the PlayerRemoving hook and ClearPlayer
-- (defined below). A local avoids a forward reference to
-- SecurityService.ClearPlayer from the hook registered at require time.
local function clearPlayerState(player: Player)
	_lastCall[player] = nil
	_callLog[player] = nil
	_bursts[player] = nil
end
local function ensureCleanupHook()
	if _cleanupHooked then
		return
	end
	_cleanupHooked = true
	-- Self-register on first require: Init() was never called from
	-- Main.server / GameManager, so without this hook _lastCall /
	-- _callLog / _bursts grew by one entry per player forever. Init()
	-- below is now just an explicit alias for the same hook.
	Players.PlayerRemoving:Connect(function(player)
		clearPlayerState(player)
	end)
end
ensureCleanupHook()

local function pruneLog(player: Player)
	local log = _callLog[player]
	if not log then
		return
	end
	while #log > MAX_LOG_ENTRIES do
		table.remove(log, 1)
	end
end

-- LogCall(player, key, allowed): append one entry to the player's call
-- log. Pure bookkeeping; never blocks anything by itself.
function SecurityService.LogCall(player: Player, key: string, allowed: boolean)
	if not player or not player:IsA("Player") then
		return
	end
	_callLog[player] = _callLog[player] or {}
	table.insert(_callLog[player], {
		Key = tostring(key),
		At = os.clock(),
		Allowed = allowed == true,
	})
	pruneLog(player)
end

-- RateLimit(player, key, minInterval): true when the call is allowed
-- (at least minInterval seconds since the last allowed call for this
-- player+key), false when it must be dropped. Allowed calls update the
-- timestamp; denied calls do not (so a spammer cannot keep pushing the
-- window forward). Always logs the attempt.
function SecurityService.RateLimit(player: Player, key: string, minInterval: number): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	key = tostring(key)
	local interval = math.max(0, tonumber(minInterval) or 0)
	local now = os.clock()
	_lastCall[player] = _lastCall[player] or {}
	local last = _lastCall[player][key] or -math.huge
	if now - last < interval then
		SecurityService.LogCall(player, key, false)
		return false
	end
	_lastCall[player][key] = now
	SecurityService.LogCall(player, key, true)
	return true
end

-- ValidateCooldown(player, key, seconds): same as RateLimit but returns
-- (allowed, remainingSeconds) so the caller can tell the client how long
-- to wait. Does NOT consume the cooldown when denied.
function SecurityService.ValidateCooldown(player: Player, key: string, seconds: number): (boolean, number)
	if not player or not player:IsA("Player") then
		return false, 0
	end
	key = tostring(key)
	local duration = math.max(0, tonumber(seconds) or 0)
	local now = os.clock()
	_lastCall[player] = _lastCall[player] or {}
	local last = _lastCall[player][key]
	if last ~= nil and now - last < duration then
		return false, duration - (now - last)
	end
	_lastCall[player][key] = now
	return true, 0
end

-- BurstLimit(player, key, maxCalls, windowSeconds): true when the call
-- is allowed (fewer than maxCalls in the last windowSeconds), false
-- when the player has fired too fast. Unlike RateLimit (a fixed gap
-- between calls), this caps bursts: e.g. BurstLimit(p, "Buy", 3, 5)
-- allows three quick buys then blocks for the rest of the window.
-- Use it on remotes with no server-side rate limit today — notably
-- BuyCharacter / SelectCharacter (EconomyService / CharacterService
-- wire their remotes with no rate check at all, so a scripted client
-- can fire hundreds of purchase/equip attempts per second; the
-- purchase itself is still server-validated, but the spam costs the
-- server a DataStore read + balance check per attempt). Denied calls
-- are logged the same way RateLimit logs them.
function SecurityService.BurstLimit(player: Player, key: string, maxCalls: number, windowSeconds: number): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	key = tostring(key)
	local max = math.max(1, math.floor(tonumber(maxCalls) or 1))
	local window = math.max(0.1, tonumber(windowSeconds) or 1)
	local now = os.clock()
	_bursts[player] = _bursts[player] or {}
	local stamps = _bursts[player][key] or {}
	-- Drop timestamps outside the window (newest last).
	local kept: { number } = {}
	for _, at in ipairs(stamps) do
		if now - at < window then
			table.insert(kept, at)
		end
	end
	if #kept >= max then
		_bursts[player][key] = kept
		SecurityService.LogCall(player, key, false)
		return false
	end
	table.insert(kept, now)
	while #kept > MAX_BURST_ENTRIES do
		table.remove(kept, 1)
	end
	_bursts[player][key] = kept
	SecurityService.LogCall(player, key, true)
	return true
end

-- ValidateDistance(player, position, maxDist): true when the player's
-- character HumanoidRootPart is within maxDist studs of `position`.
-- False when there is no live character (a dead / not-yet-spawned player
-- cannot pass a proximity check).
function SecurityService.ValidateDistance(player: Player, position: Vector3, maxDist: number): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	if typeof(position) ~= "Vector3" then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	return (root.Position - position).Magnitude <= (tonumber(maxDist) or 0)
end

-- SanitizeId(id): returns the id unchanged when it is a safe identifier
-- (1-64 chars, letters / digits / underscore / hyphen only), otherwise
-- nil. Use on every client-supplied id before it touches data or a
-- lookup table.
function SecurityService.SanitizeId(id: any): string?
	if type(id) ~= "string" then
		return nil
	end
	if #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
end

-- GetCallLog(player): newest-last copy of the player's call log, for
-- debugging / abuse review. Returns an empty table for unknown players.
function SecurityService.GetCallLog(player: Player): { { Key: string, At: number, Allowed: boolean } }
	local log = _callLog[player]
	if not log then
		return {}
	end
	local copy = {}
	for _, entry in ipairs(log) do
		table.insert(copy, {
			Key = entry.Key,
			At = entry.At,
			Allowed = entry.Allowed,
		})
	end
	return copy
end

-- ClearPlayer(player): drop all rate-limit state and logs for a player.
-- Called automatically on PlayerRemoving.
function SecurityService.ClearPlayer(player: Player)
	clearPlayerState(player)
end

function SecurityService.Init()
	-- The cleanup hook self-registers at require time (see
	-- ensureCleanupHook above) because Main.server / GameManager never
	-- call Init(). Calling Init() explicitly is still safe: it is a
	-- no-op when the hook already exists.
	ensureCleanupHook()
end

return SecurityService
