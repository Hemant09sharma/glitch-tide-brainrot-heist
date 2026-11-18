--!strict
-- PanelKit.luau
-- Shared client-side helpers for the Wave 3 (v1.1 E) panels. This is a
-- LIBRARY module, not a controller: it has no Init(), so Main.client's
-- extra-module loader skips it. Existing controllers keep their own
-- (duplicated) helpers — PanelKit is only used by the new Wave 3
-- controllers, to keep them consistent and to make the "every button
-- has a handler" check mechanical: PanelKit.MakeButton always connects
-- MouseButton1Click, so a button built through it can never be dead.
--
-- Conventions (same as the existing controllers):
--   * Remotes are looked up by name through Remotes.Names with a
--     literal fallback; a missing remote is a status message, never
--     a crash.
--   * Every server fire goes through FireServerChecked / InvokeChecked
--     with a per-key client debounce (server rate limits are 1/s on
--     the new remotes; the client debounces at the same or a longer
--     interval so a double-click can never double-fire a purchase or
--     a claim).
--   * The server is the only source of truth for outcomes: a fire
--     shows "Sent — waiting for the server…" and only a server push
--     (or a fresh RemoteFunction reply) confirms it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local PanelKit = {}

local RemotesModule: any = nil
pcall(function()
	RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes", 10))
end)

local RarityColors: any = nil
pcall(function()
	RarityColors = require(script.Parent.RarityColors)
end)

-- Per-key last-fire timestamps (client-side debounce guards).
local _lastFire: { [string]: number } = {}

function PanelKit.GetPlayer(): Player
	return LocalPlayer
end

function PanelKit.GetRemotesFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder then
		return folder :: Folder
	end
	local ok, found = pcall(function()
		return ReplicatedStorage:WaitForChild("Remotes", 5)
	end)
	if ok and found then
		return found :: Folder
	end
	return nil
end

function PanelKit.GetRemote(name: string): Instance?
	local folder = PanelKit.GetRemotesFolder()
	if not folder then
		return nil
	end
	return folder:FindFirstChild(name)
end

function PanelKit.RemoteName(key: string, fallback: string): string
	if RemotesModule and RemotesModule.Names and RemotesModule.Names[key] then
		return RemotesModule.Names[key]
	end
	return fallback
end

function PanelKit.Corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

function PanelKit.MakeLabel(parent: Instance, text: string, size: number, color: Color3, bold: boolean?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = true
	label.Parent = parent
	return label
end

-- MakeButton ALWAYS connects MouseButton1Click (onClick is required).
-- A display-only label must be a TextLabel, never a button built here.
function PanelKit.MakeButton(
	parent: Instance,
	text: string,
	size: UDim2,
	position: UDim2,
	bg: Color3,
	onClick: () -> ()
): TextButton
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position
	button.Text = text
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.BackgroundColor3 = bg
	button.BorderSizePixel = 0
	PanelKit.Corner(button, 8)
	button.Parent = parent
	button.MouseButton1Click:Connect(function()
		onClick()
	end)
	return button
end

-- Debounce guard: returns true when the caller may proceed (and records
-- the attempt), false when the same key fired within `seconds`.
function PanelKit.Debounce(key: string, seconds: number): boolean
	local now = os.clock()
	local last = _lastFire[key] or -math.huge
	if now - last < seconds then
		return false
	end
	_lastFire[key] = now
	return true
end

-- Fire a RemoteEvent by Remotes name. Returns false (and never fires)
-- when the remote is missing, not an event, or debounced out.
function PanelKit.FireServerChecked(key: string, debounceSeconds: number?, ...: any): boolean
	if debounceSeconds and debounceSeconds > 0 then
		if not PanelKit.Debounce("fire:" .. key, debounceSeconds) then
			return false
		end
	end
	local remote = PanelKit.GetRemote(PanelKit.RemoteName(key, key))
	if not remote or not remote:IsA("RemoteEvent") then
		return false
	end
	local args = { ... }
	local ok = pcall(function()
		(remote :: RemoteEvent):FireServer(unpack(args))
	end)
	return ok
end

-- Invoke a RemoteFunction by Remotes name. Returns (ok, result):
-- ok=false when the function is missing or the invoke errors.
function PanelKit.InvokeChecked(key: string): (boolean, any)
	local fn = PanelKit.GetRemote(PanelKit.RemoteName(key, key))
	if not fn or not fn:IsA("RemoteFunction") then
		return false, nil
	end
	local ok, result = pcall(function()
		return (fn :: RemoteFunction):InvokeServer()
	end)
	if not ok then
		return false, nil
	end
	return true, result
end

-- Connect a RemoteEvent listener in the background (never blocks Init).
-- onEvent receives the payload; missing remotes just never connect.
function PanelKit.Listen(key: string, onEvent: (any) -> ())
	task.spawn(function()
		local folder = PanelKit.GetRemotesFolder()
		if not folder then
			return
		end
		local ok, remote = pcall(function()
			return folder:WaitForChild(PanelKit.RemoteName(key, key), 30)
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			(remote :: RemoteEvent).OnClientEvent:Connect(onEvent)
		end
	end)
end

-- Best-effort sound play through SoundController (never errors when
-- the controller is absent). `method` is a SoundController function
-- name such as "PlayClick" / "PlayRare" / "PlayError".
function PanelKit.PlaySound(method: string)
	pcall(function()
		local mod = script.Parent:FindFirstChild("SoundController")
		if not mod then
			return
		end
		local sound = require(mod)
		local fn = sound[method]
		if type(fn) == "function" then
			fn(sound)
		end
	end)
end

-- Show a banner through the HUD (never errors when HUD is absent).
function PanelKit.ShowBanner(text: string, durationSeconds: number?)
	pcall(function()
		local mod = script.Parent:FindFirstChild("HUDController")
		if not mod then
			return
		end
		local hud = require(mod)
		if hud.ShowEventBanner then
			hud.ShowEventBanner(text, durationSeconds or 6)
		end
	end)
end

-- Open another controller's panel by module name (same lazy-require
-- pattern the HUD menu bar uses).
function PanelKit.OpenController(moduleName: string)
	pcall(function()
		local mod = script.Parent:FindFirstChild(moduleName)
		if not mod then
			return
		end
		local controller = require(mod)
		if type(controller) == "table" and type(controller.Toggle) == "function" then
			controller.Toggle()
		elseif type(controller) == "table" and type(controller.Open) == "function" then
			controller.Open()
		end
	end)
end

function PanelKit.RarityColor(rarity: string?): Color3
	if RarityColors and RarityColors.Get then
		local ok, color = pcall(function()
			return RarityColors.Get(rarity)
		end)
		if ok and typeof(color) == "Color3" then
			return color
		end
	end
	return Color3.fromRGB(170, 170, 170)
end

-- Character display name from the shared catalogue (never a raw id in UI).
function PanelKit.CharacterName(characterId: string?): string
	if typeof(characterId) ~= "string" or characterId == "" then
		return "?"
	end
	local ok, name = pcall(function()
		local chars = require(ReplicatedStorage:WaitForChild("Characters", 10))
		local def = chars.GetById(characterId)
		return def and (def.DisplayName or def.Name) or characterId
	end)
	if ok and typeof(name) == "string" then
		return name
	end
	return characterId
end

function PanelKit.FormatCoins(amount: any): string
	local n = tonumber(amount) or 0
	return "🪙 " .. tostring(math.floor(n + 0.5))
end

function PanelKit.FormatDuration(seconds: number?): string
	local s = math.max(0, math.floor(tonumber(seconds) or 0))
	local minutes = math.floor(s / 60)
	local secs = s % 60
	if minutes > 0 then
		return string.format("%dm %02ds", minutes, secs)
	end
	return tostring(s) .. "s"
end

return PanelKit
