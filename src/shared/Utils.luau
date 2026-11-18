--!strict
-- Utils.luau
-- Small shared helpers used by server and client alike.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Utils = {}

-- Lazily-loaded Config (never required at module load: shared modules
-- are required before ReplicatedStorage is guaranteed to hold it).
local _config: any = nil
local function getConfig(): any
	if _config ~= nil then
		return _config
	end
	-- FindFirstChild never errors, so no pcall is needed here.
	local mod = ReplicatedStorage:FindFirstChild("Config")
	if mod == nil then
		return nil
	end
	local ok2, cfg = pcall(require, mod)
	if ok2 then
		_config = cfg
	end
	return _config
end

-- GetAbilityKey(abilityId): the input key Config binds to a generic
-- ability ("dash" | "slam" | "heal" | "primary"). Reads
-- Config.GenericAbilities / Config.AbilitySlots dynamically, so a
-- rebalance in Config moves every label with it — no key is ever
-- hardcoded in a UI file. Returns nil when Config has no binding.
--
-- NOTE (v1.0.1 QA, fixed): Config used to bind slam to "E" and dash
-- and primary both to "Q". Since v1.0.1 Config is canonical Q/F/R
-- (Q = primary, F = slam, R = heal, E = Interact), and the labels
-- derived here read Config dynamically, so a rebalance in Config
-- moves every label with it — no key is ever hardcoded in a UI file.
function Utils.GetAbilityKey(abilityId: string): string?
	local cfg = getConfig()
	if cfg == nil or type(abilityId) ~= "string" then
		return nil
	end
	if abilityId == "primary" and type(cfg.AbilitySlots) == "table" then
		local key = cfg.AbilitySlots.Primary
		if type(key) == "string" then
			return key
		end
	end
	if type(cfg.GenericAbilities) == "table" then
		for key, id in pairs(cfg.GenericAbilities) do
			if id == abilityId then
				return key
			end
		end
	end
	return nil
end

-- GetKeybinds(): the full key map every UI label and InputBegan handler
-- reads from. Ability keys come from Config (see GetAbilityKey);
-- Interact / Drop / Mute / panel keys have no Config entry (Config is
-- the balance file, not the input file), so they live here — this table
-- is the ONE place to change them, and every controller reads it
-- instead of keeping its own literals.
function Utils.GetKeybinds(): { [string]: string }
	local binds: { [string]: string } = {
		Interact = "E",
		Drop = "G",
		Mute = "M",
		Market = "N",
		Shop = "B",
		Brainrots = "C",
		Base = "V",
		Quests = "J",
		Collection = "L",
	}
	binds.Primary = Utils.GetAbilityKey("primary") or "Q"
	binds.Slam = Utils.GetAbilityKey("slam") or "F"
	binds.Heal = Utils.GetAbilityKey("heal") or "R"
	binds.Dash = Utils.GetAbilityKey("dash") or binds.Primary
	return binds
end

-- KeyCodeFor(keyName): Enum.KeyCode["E"] etc., nil for unknown names.
-- Lets handlers compare input.KeyCode against the dynamic bind table.
function Utils.KeyCodeFor(keyName: string): Enum.KeyCode?
	if type(keyName) ~= "string" or keyName == "" then
		return nil
	end
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[keyName]
	end)
	if ok and code ~= nil then
		return code :: Enum.KeyCode
	end
	return nil
end

function Utils.Clamp(value: number, minValue: number, maxValue: number): number
	return math.clamp(value, minValue, maxValue)
end

function Utils.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * math.clamp(t, 0, 1)
end

function Utils.Round(value: number): number
	return math.floor(value + 0.5)
end

-- 1234567 -> "1,234,567"; negative numbers keep their sign.
function Utils.FormatNumber(value: number): string
	local negative = value < 0
	local whole = tostring(math.floor(math.abs(value)))
	local out = ""
	while #whole > 3 do
		out = "," .. string.sub(whole, -3) .. out
		whole = string.sub(whole, 1, #whole - 3)
	end
	out = whole .. out
	if negative then
		out = "-" .. out
	end
	return out
end

-- 125 -> "02:05"; 45 -> "00:45"; hours roll into minutes.
function Utils.FormatTime(totalSeconds: number): string
	local seconds = math.max(0, math.floor(totalSeconds))
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%02d:%02d", minutes, remainder)
end

-- Deep copy of tables (values only; does not preserve metatables or
-- copy userdata / Instances — those are returned as-is).
function Utils.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value :: any) do
		(copy :: any)[Utils.DeepCopy(key)] = Utils.DeepCopy(item)
	end
	return copy :: T
end

function Utils.RandomChoice<T>(list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[math.random(1, #list)]
end

-- Fisher-Yates shuffle; returns a new table, input is untouched.
function Utils.Shuffle<T>(list: { T }): { T }
	local copy: { T } = {}
	for _, item in list do
		table.insert(copy, item)
	end
	for i = #copy, 2, -1 do
		local j = math.random(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

function Utils.GetDistance(a: Vector3, b: Vector3): number
	return (a - b).Magnitude
end

-- Player display names: 3-20 chars, letters/digits/underscore only,
-- must start with a letter.
function Utils.IsValidName(name: string): boolean
	if #name < 3 or #name > 20 then
		return false
	end
	if not string.match(string.sub(name, 1, 1), "%a") then
		return false
	end
	return string.match(name, "^%a[%w_]*$") ~= nil
end

function Utils.TableContains<T>(list: { T }, value: T): boolean
	for _, item in list do
		if item == value then
			return true
		end
	end
	return false
end

return Utils
