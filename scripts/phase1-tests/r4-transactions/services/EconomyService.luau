-- EconomyService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse — server-authoritative economy.
-- All coin / XP awards and purchases are validated here; the client can
-- only request, never grant. Balance changes are pushed to the client via
-- the PlayerStats remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require("../shared/Config")
local Characters = require("../shared/Characters")
local Economy = require("../shared/Economy")
local Remotes = require("../shared/Remotes")

local EconomyService = {}

local _dataService = nil
-- v1.1 (Workstream B) INCOME HOOK ONLY: CompanionService registers
-- itself here via SetCompanionService (called from
-- CompanionService.Init, or by GameManager). GetCompanionIncomeMultiplier
-- below delegates to it. The REAL income flow is
-- BaseService.GetIncomePerSec (audit §4f: this service has no
-- AddCoins/AddGems API; coins move via DataService.AddCoins and
-- income is computed only in BaseService). BaseService must multiply
-- its total by GetCompanionIncomeMultiplier(player) — one new setter
-- + one line inside BaseService, owned by the BaseService workstream
-- (BaseService has no SetEconomyService setter today). Until that
-- lands the hook is computed + exposed but not applied to banked
-- income. No other method in this file is changed.
local _companionService: any = nil
local _lastBuy: { [Player]: number } = {}

-- Burst-limit state lives in SecurityService (BurstLimit); require it
-- lazily so a missing SecurityService module never breaks purchases.
local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

-- Remotes has no GetRemotes() (it exposes GetRemote / GetFunction per
-- name). Look each remote up by its Names entry instead.
local function getEventRemote(name: string): RemoteEvent?
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

local function getFunctionRemote(name: string): RemoteFunction?
	local ok, remote = pcall(function()
		return Remotes.GetFunction(name)
	end)
	if ok and typeof(remote) == "Instance" and remote:IsA("RemoteFunction") then
		return remote
	end
	return nil
end

local function notifyBalance(player)
	local data = _dataService and _dataService.GetData(player)
	if not data then
		return
	end
	local remote = getEventRemote(Remotes.Names.PlayerStats)
	if remote then
		local ok, err = pcall(function()
			remote:FireClient(player, {
				Coins = data.Coins,
				XP = data.XP,
				Level = data.Level,
				Wins = data.Wins,
				KOs = data.KOs,
				LoginStreak = data.LoginStreak,
			})
		end)
		if not ok then
			warn("[EconomyService] PlayerStats notify failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
end

-- Apply an XP gain and handle level-ups (possibly several at once).
local function grantXP(player, amount)
	local data = _dataService.GetOrLoad(player)
	local newXP = _dataService.AddXP(player, amount)
	local level = tonumber(data.Level) or 1
	local maxLevel = tonumber(Config.MaxLevel) or 100
	local levelsGained = 0
	while level < maxLevel and newXP >= Economy.XPForLevel(level) do
		newXP = newXP - Economy.XPForLevel(level)
		level = level + 1
		levelsGained += 1
	end
	-- At the cap, banked XP cannot buy further levels; keep the
	-- remainder instead of discarding the gain.
	if levelsGained > 0 then
		data.XP = newXP
		_dataService.SetLevel(player, level)
		-- Level-up bonus: 25 coins per level gained.
		_dataService.AddCoins(player, 25 * levelsGained)
		print(string.format("[EconomyService] %s levelled up to %d", player.Name, level))
		return level, true
	end
	return level, false
end

function EconomyService.Init(dataService)
	assert(dataService ~= nil, "[EconomyService] Init requires DataService")
	_dataService = dataService

	Players.PlayerRemoving:Connect(function(player)
		_lastBuy[player] = nil
	end)

	-- Wire the BuyCharacter / RequestShop remotes once they exist.
	task.spawn(function()
		local buyRemote: RemoteEvent? = nil
		local shopFn: RemoteFunction? = nil
		for _ = 1, 50 do
			buyRemote = buyRemote or getEventRemote(Remotes.Names.BuyCharacter)
			shopFn = shopFn or getFunctionRemote(Remotes.Names.RequestShop)
			if buyRemote ~= nil and shopFn ~= nil then
				break
			end
			task.wait(0.2)
		end
		if buyRemote ~= nil then
			buyRemote.OnServerEvent:Connect(function(player, characterId)
				-- Burst limit (v1.0.1 integration QA): at most 5
				-- BuyCharacter attempts per 5s per player. The purchase
				-- itself is still server-validated; this only stops a
				-- scripted client from costing the server a DataStore
				-- read + balance check per attempt, hundreds per second.
				if Security and Security.BurstLimit then
					local allowed = false
					pcall(function()
						allowed = Security.BurstLimit(player, "BuyCharacter", 5, 5)
					end)
					if not allowed then
						warn("[EconomyService] BuyCharacter burst limit for " .. player.Name .. " — too many purchase attempts, slow down")
						return
					end
				end
				local now = os.clock()
				local last = _lastBuy[player] or 0
				if now - last < 0.25 then
					return
				end
				_lastBuy[player] = now
				local ok, result = EconomyService.BuyCharacter(player, characterId)
				-- Reply through PlayerStats so the client refreshes its shop UI.
				notifyBalance(player)
				if not ok then
					warn("[EconomyService] Buy failed for " .. player.Name .. ": " .. tostring(result))
				end
			end)
		else
			warn("[EconomyService] BuyCharacter remote not available")
		end
		if shopFn ~= nil then
			shopFn.OnServerInvoke = function(player)
				local data = _dataService.GetOrLoad(player)
				local shop = {}
				for _, character in ipairs(Characters.GetAll()) do
					table.insert(shop, {
						Id = character.Id,
						Name = character.DisplayName,
						Rarity = character.Rarity,
						Cost = character.Cost,
						Owned = _dataService.HasCharacter(player, character.Id),
					})
				end
				return {
					Coins = data.Coins,
					Characters = shop,
				}
			end
		else
			warn("[EconomyService] RequestShop function not available")
		end
	end)
end

-- KO reward: streak-scaled coins (Economy.CalculateKOReward) + flat XP.
-- Returns coins awarded, or nil if the player/data is invalid.
function EconomyService.AwardKO(player, streak)
	if not player or not player.Parent then
		return nil
	end
	streak = math.max(1, tonumber(streak) or 1)
	local coins = Economy.CalculateKOReward(streak)
	-- Fall back to the flat config value if the shared helper misbehaves.
	if type(coins) ~= "number" or coins < 0 then
		coins = Config.CoinPerKO
	end
	_dataService.AddCoins(player, coins)
	_dataService.AddKO(player)
	grantXP(player, Config.XPPerKO)
	notifyBalance(player)
	return coins
end

function EconomyService.AwardWin(player)
	if not player or not player.Parent then
		return nil
	end
	-- Win bonus scales mildly with lifetime wins (shared helper);
	-- the old flat Config.CoinPerWin ignored it.
	local data = _dataService.GetOrLoad(player)
	local coins = Economy.CalculateWinBonus(tonumber(data.Wins) or 0)
	if type(coins) ~= "number" or coins < 0 then
		coins = Config.CoinPerWin
	end
	_dataService.AddCoins(player, coins)
	_dataService.AddWin(player)
	grantXP(player, Config.XPPerWin)
	notifyBalance(player)
	print(string.format("[EconomyService] %s won the round: +%d coins", player.Name, coins))
	return coins
end

-- Wave-clear reward: the shared CoinsForWave table (boss waves pay
-- double); the old hardcoded 10 + (wave-1)*2 ignored it.
function EconomyService.AwardWave(player, wave)
	if not player or not player.Parent then
		return nil
	end
	wave = math.max(1, tonumber(wave) or 1)
	local coins = Economy.CoinsForWave(wave)
	if type(coins) ~= "number" or coins < 0 then
		coins = 10 + (wave - 1) * 2
	end
	_dataService.AddCoins(player, coins)
	grantXP(player, Config.XPPerWave)
	notifyBalance(player)
	return coins
end

-- Server-side purchase validation. Returns (true, characterId) on success,
-- (false, reasonString) on failure. Never trusts the client's coin count.
function EconomyService.BuyCharacter(player, characterId)
	if not player or not player.Parent then
		return false, "invalid player"
	end
	if type(characterId) ~= "string" or characterId == "" then
		return false, "invalid character id"
	end
	local character = nil
	local ok, err = pcall(function()
		character = Characters.GetById(characterId)
	end)
	if not ok or not character then
		return false, "unknown character: " .. tostring(err or characterId)
	end
	local data = _dataService.GetOrLoad(player)
	if _dataService.HasCharacter(player, characterId) then
		return false, "already owned"
	end
	local cost = tonumber(character.Cost) or 0
	local coins = tonumber(data.Coins) or 0
	-- R4-3: affordability is judged on spendable coins (balance
	-- above any reservation held for a pending reward commit).
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, spendable = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(spendable) == "number" then
			coins = spendable
		end
	end
	if coins < cost then
		return false, "not enough coins"
	end
	_dataService.AddCoins(player, -cost)
	-- UnlockCharacter returns false when already owned: a second
	-- concurrent buy racing this one lost, so refund in full instead
	-- of charging twice for one unlock.
	if not _dataService.UnlockCharacter(player, characterId) then
		_dataService.AddCoins(player, cost)
		notifyBalance(player)
		return false, "already owned"
	end
	-- Persist immediately: a purchase must survive a crash / leave.
	task.spawn(function()
		_dataService.SaveData(player)
	end)
	notifyBalance(player)
	print(string.format(
		"[EconomyService] %s bought %s for %d coins",
		player.Name, characterId, cost
	))
	return true, characterId
end

-- SetCompanionService(companionService): register the companion
-- service so the income hook below can delegate to it. Accepts nil
-- (unregisters). Called by CompanionService.Init.
function EconomyService.SetCompanionService(companionService: any)
	_companionService = companionService
end

-- GetCompanionIncomeMultiplier(player): 1 + the player's companion
-- IncomeBonus (max 1.25), or 1 when no companion service is linked.
-- BaseService.GetIncomePerSec should multiply its total by this value.
-- Safe to call before any wiring: it never errors, it just returns 1.
function EconomyService.GetCompanionIncomeMultiplier(player: Player): number
	if _companionService ~= nil and type(_companionService.GetIncomeMultiplier) == "function" then
		local ok, value = pcall(function()
			return _companionService.GetIncomeMultiplier(player)
		end)
		if ok and type(value) == "number" and value >= 1 then
			return math.min(value, 1.25)
		end
	end
	return 1
end

function EconomyService.GetBalance(player)
	local data = _dataService and _dataService.GetData(player)
	if not data then
		return 0
	end
	return tonumber(data.Coins) or 0
end

function EconomyService.NotifyBalance(player)
	notifyBalance(player)
end

return EconomyService
