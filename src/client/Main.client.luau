-- Main.client.luau
-- Glitch Tide — Brainrot Heist: The Memeverse — client entry point.
-- Waits for the shared Remotes folder, then loads every controller in
-- script.Parent.Controllers in a fixed order and calls Init() on each.
-- Controllers are loaded in dependency order: HUD first (other controllers
-- may look for HUD state / the menu-bar buttons), then Interaction,
-- Market, CharacterSelect, Shop, Base, Ability, Quest, Collection, and
-- Camera last (it only reacts to events the others produce).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- Ordered list of controllers. Keep this order: HUD -> Interaction ->
-- Market -> CharacterSelect -> Shop -> Base -> AbilityController ->
-- Quest -> Collection -> Camera. If a parallel builder adds another
-- controller module to the Controllers folder, add its name here in the
-- position it should initialise.
local CONTROLLER_ORDER = {
	"HUDController",
	"InteractionController",
	"MarketController",
	"CharacterSelectController",
	"ShopController",
	"BaseController",
	"AbilityController",
	"QuestController",
	"CollectionController",
	"CameraController",
}

local function waitForRemotes()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	-- Wait briefly for every remote named in the shared contract so no
	-- controller ever fires/listens on a nil RemoteEvent. Each wait is
	-- capped at 5 seconds and only warns: controllers degrade gracefully
	-- when a remote is absent, so a missing remote must never stall the
	-- client forever.
	local names = {
		"Attack",
		"UseAbility",
		"RequestCharacter",
		"SelectCharacter",
		"BuyCharacter",
		"RequestShop",
		"PlayerStats",
		"WaveUpdate",
		"RoundUpdate",
		"SpawnEffect",
		"DamageNumber",
		"BuyConveyor",
		"PickupBrainrot",
		"DropBrainrot",
		"PlaceBrainrot",
		"StealBrainrot",
		"RequestBase",
		"UpgradeBase",
		"UpgradeBrainrot",
		"CollectIncome",
		"ConveyorUpdate",
		"BaseUpdate",
		"CarryUpdate",
		"StealAlert",
		"GlitchTideUpdate",
	}
	for _, name in ipairs(names) do
		local ok, result = pcall(function()
			return remotes:WaitForChild(name, 5)
		end)
		if not ok or result == nil then
			warn("[GlitchTide] Main: remote '" .. name .. "' not present yet (controllers will degrade gracefully)")
		end
	end
	return remotes
end

local function main()
	-- Block until the character exists so controllers that read the
	-- Humanoid / PlayerGui on Init do not race the spawn. This waits
	-- ONCE only: CameraController (below, plus its own listeners) owns
	-- rebinding on every later CharacterAdded / morph / respawn, so
	-- this single wait must never be mistaken for camera setup.
	if not LocalPlayer.Character then
		LocalPlayer.CharacterAdded:Wait()
	end

	waitForRemotes()

	local controllersFolder = script.Parent:WaitForChild("Controllers")

	local loaded = {}
	for _, moduleName in ipairs(CONTROLLER_ORDER) do
		local moduleScript = controllersFolder:FindFirstChild(moduleName)
		if not moduleScript then
			warn("[GlitchTide] Main: controller module missing: " .. moduleName)
			continue
		end

		local ok, controller = pcall(require, moduleScript)
		if not ok then
			warn("[GlitchTide] Main: failed to require " .. moduleName .. ": " .. tostring(controller))
			continue
		end

		if typeof(controller) ~= "table" or typeof(controller.Init) ~= "function" then
			warn("[GlitchTide] Main: controller " .. moduleName .. " has no Init() function")
			continue
		end

		-- Init each controller on its own thread so one slow Init (e.g. a
		-- controller waiting on a remote reply) cannot stall the rest.
		-- Order is still honoured because Init calls are issued in order
		-- and each controller's own setup is synchronous up to its first
		-- yield; controllers must not depend on another controller having
		-- finished an async step.
		local initOk, initErr = pcall(controller.Init)
		if not initOk then
			warn("[GlitchTide] Main: Init() failed for " .. moduleName .. ": " .. tostring(initErr))
		else
			table.insert(loaded, moduleName)
		end
	end

	-- Also pick up any extra controller modules dropped into the folder by
	-- a later builder that were not in CONTROLLER_ORDER, so nothing is
	-- silently skipped. They initialise after the ordered ones.
	-- Library modules (e.g. RarityColors) expose Init() too and load
	-- harmlessly; a module with no Init() is a library, not a controller,
	-- and is skipped silently.
	for _, child in ipairs(controllersFolder:GetChildren()) do
		if child:IsA("ModuleScript") and not table.find(CONTROLLER_ORDER, child.Name) then
			local ok, controller = pcall(require, child)
			if ok and typeof(controller) == "table" and typeof(controller.Init) == "function" then
				local initOk, initErr = pcall(controller.Init)
				if initOk then
					table.insert(loaded, child.Name)
				else
					warn("[GlitchTide] Main: Init() failed for " .. child.Name .. ": " .. tostring(initErr))
				end
			elseif not ok then
				warn("[GlitchTide] Main: could not load extra controller " .. child.Name)
			end
		end
	end

	print("[GlitchTide] Client ready. Controllers loaded: " .. table.concat(loaded, ", "))

	-- CAMERA REBIND WIRING (camera-bug fix): Main used to wait for
	-- CharacterAdded exactly ONCE, before loading controllers, and never
	-- listened again — so a respawn, a morph (server assigns
	-- player.Character, which does NOT fire CharacterAdded) or a
	-- teleport left the camera bound to a destroyed Humanoid. The
	-- CameraController itself now owns the same listeners + a 0.5s
	-- watchdog; this wiring in Main is a redundant safety net so a
	-- rebind also happens from the entry point if the controller's own
	-- listeners ever miss an event. Rebind is idempotent (a second bind
	-- to the same live Humanoid is a no-op), so double-binding is safe.
	task.spawn(function()
		local cameraModule = controllersFolder:FindFirstChild("CameraController")
		if not cameraModule then
			return
		end
		local ok, cameraController = pcall(require, cameraModule)
		if not ok or typeof(cameraController) ~= "table" or typeof(cameraController.Rebind) ~= "function" then
			return
		end
		-- Respawn (fresh default avatar, before the 0.2s morph).
		LocalPlayer.CharacterAdded:Connect(function()
			pcall(cameraController.Rebind, true)
		end)
		-- Morph / character swap / teleport recovery: Character property
		-- changes fire for server-side `player.Character = newModel`
		-- assignments that CharacterAdded never sees.
		LocalPlayer:GetPropertyChangedSignal("Character"):Connect(function()
			pcall(cameraController.Rebind, true)
		end)
		-- Force an immediate rebind for the character already in game.
		pcall(cameraController.Rebind, true)
	end)

	-- Show the main menu. MainMenu is a ModuleScript in StarterGui (cloned
	-- into PlayerGui); nothing auto-runs it, so require it here.
	task.spawn(function()
		local ok, playerGui = pcall(function()
			return LocalPlayer:WaitForChild("PlayerGui", 10)
		end)
		if not ok or not playerGui then
			return
		end
		local menuMod = playerGui:FindFirstChild("MainMenu")
		if not menuMod then
			return
		end
		local ok2, menu = pcall(require, menuMod)
		if ok2 and typeof(menu) == "table" and typeof(menu.Init) == "function" then
			pcall(menu.Init)
		end
	end)
end

task.spawn(main)
