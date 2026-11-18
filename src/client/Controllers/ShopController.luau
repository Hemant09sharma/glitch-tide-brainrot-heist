--!strict
-- ShopController.luau
-- Market / shop panel for GLITCH TIDE. Five tabs, all display-only
-- pricing (the server owns every price and validates every purchase):
--   UPGRADES  — base upgrades via UpgradeBase (kind: BaseSlot,
--               IncomeMultiplier, Lock, Turret, ConveyorLuck)
--   BRAINROTS — level up a placed Brainrot via UpgradeBrainrot
--   MUTATIONS — the Mutation Lab: pick a placed Brainrot, apply a
--               mutation for Mutation Crystals via MutateBrainrot
--               ({Action="Mutate", InstanceId, MutationId})
--   FUSION    — the Fusion Lab: pick two UNPLACED Brainrots from your
--               inventory and fuse them via FuseBrainrot
--               ({InstanceIdA, InstanceIdB}) into the character their
--               shared Mutations.FusionRecipes recipe produces.
--               Placed Brainrots cannot fuse (the server rejects them).
--   POWERS    — every power; a power unlocks by owning its Brainrot,
--               so the button buys that Brainrot (BuyCharacter) when
--               locked and shows "OWNED" when unlocked. Wave 3 (v1.1 E)
--               added the mastery display: the formula (+10 XP/use,
--               max Lv 5, +5% damage / −2% cooldown per level) plus
--               this-session use counts (labelled session-only — the
--               server pushes no mastery state).
-- The Shop also has a 🧪 MUTATION LAB shortcut button that opens the
-- full LaboratoryController panel (evolve / traits / recipes /
-- alternate forms). On-expedition Brainrots are filtered out of the
-- fuse list (QA_V11_C §9.3). The dead FireServer("GetBase") branch
-- was removed in Wave 3 E — RequestBase is a function.
-- Every purchase button fires its server remote and shows "Sent —
-- waiting for server…". It NEVER claims success on its own: the result
-- is shown only when the server pushes back (PlayerStats / BaseUpdate)
-- or when a fresh RequestBase / RequestShop reply confirms the change.
-- If the server stays silent for 5s the button reports "No reply from
-- the server — check your coins / base panel". Toggle: B key, or the
-- "SHOP" button on the HUD menu bar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local ShopController = {}

local RarityColors = require(script.Parent.RarityColors)

local Characters: any = nil
local Powers: any = nil
local Config: any = nil
local Economy: any = nil
local Mutations: any = nil
pcall(function()
	Characters = require(ReplicatedStorage:WaitForChild("Characters", 10))
end)
pcall(function()
	Powers = require(ReplicatedStorage:WaitForChild("Powers", 10))
end)
pcall(function()
	Config = require(ReplicatedStorage:WaitForChild("Config", 10))
end)
pcall(function()
	Economy = require(ReplicatedStorage:WaitForChild("Economy", 10))
end)
pcall(function()
	Mutations = require(ReplicatedStorage:WaitForChild("Mutations", 10))
end)

local RemotesModule: any = nil
pcall(function()
	RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes", 10))
end)

local gui: ScreenGui? = nil
local contentFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local coinsLabel: TextLabel? = nil
local isOpen = false
local activeTab: string = "Upgrades"
local baseState: any = nil
local placedList: { any } = {}
local unplacedList: { any } = {}
local owned: { [string]: boolean } = {}
local knownCoins: number = 0
local pending: { [string]: number } = {}
-- Mutations tab: InstanceId of the placed Brainrot being mutated.
local mutateTarget: string? = nil
-- Fusion tab: InstanceIds of the two unplaced Brainrots being fused.
local fuseA: string? = nil
local fuseB: string? = nil

-- The instance currently away on an expedition (nil when none). Only
-- one trip can be active, so excluding this one id is the whole
-- on-expedition rule (QA_V11_C §9.3): the server enforces
-- OnExpedition only at the expedition API, so the client must not
-- offer that instance for fuse / mutate / level-up lists.
local function expeditionInstanceId(): string?
	local ok, id = pcall(function()
		local mod = script.Parent:FindFirstChild("ExpeditionController")
		if not mod then
			return nil
		end
		local exp = require(mod)
		if exp.GetActiveInstanceId then
			return exp.GetActiveInstanceId()
		end
		return nil
	end)
	if ok and typeof(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

local UPGRADE_KINDS: { { kind: string, name: string, desc: string } } = {
	{ kind = "BaseSlot", name = "Base Slot", desc = "Adds one slot to your base so you can place another Brainrot." },
	{ kind = "IncomeMultiplier", name = "Income Boost", desc = "Multiplies all income from Brainrots placed in your base." },
	{ kind = "Lock", name = "Base Lock", desc = "Locks your base longer, blocking thieves for a while." },
	{ kind = "Turret", name = "Turret", desc = "A defensive turret that scares off thieves near your base." },
	{ kind = "ConveyorLuck", name = "Conveyor Luck", desc = "Better odds of rare Brainrots spawning on the conveyor." },
}

local function getRemotesFolder(): Folder?
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

local function getRemote(name: string): Instance?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end
	return folder:FindFirstChild(name)
end

local function remoteName(key: string, fallback: string): string
	if RemotesModule and RemotesModule.Names and RemotesModule.Names[key] then
		return RemotesModule.Names[key]
	end
	return fallback
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function makeLabel(parent: Instance, text: string, size: number, color: Color3, bold: boolean?): TextLabel
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

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function upgradeLevel(kind: string): number
	if typeof(baseState) == "table" then
		local upgrades = baseState.Upgrades or baseState.upgrades
		if typeof(upgrades) == "table" and typeof(upgrades[kind]) == "number" then
			return upgrades[kind]
		end
		if typeof(baseState[kind]) == "number" then
			return baseState[kind]
		end
	end
	return 0
end

-- Display-only cost from the shared Economy table (the server re-checks
-- the real price; this number is never trusted for the purchase itself).
local function displayCost(kind: string, level: number): number?
	if Economy and Economy.UpgradeCost then
		local ok, cost = pcall(function()
			return Economy.UpgradeCost(kind, level)
		end)
		if ok then
			return cost
		end
	end
	return nil
end

-- Arm a 5-second "no reply" watchdog for a fire-and-forget purchase.
local function armWatchdog(key: string, what: string)
	pending[key] = os.clock()
	task.delay(5, function()
		if pending[key] and os.clock() - (pending[key] or 0) >= 4.9 then
			pending[key] = nil
			setStatus("No reply from the server for " .. what .. " — check your coins / base panel.", true)
		end
	end)
end

local function clearPending(key: string, what: string)
	if pending[key] then
		pending[key] = nil
		setStatus(what .. " confirmed by the server.")
	end
end

local function clearContent()
	if not contentFrame then
		return
	end
	for _, child in contentFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function buildRow(title: string, desc: string, priceText: string, buttonText: string, onClick: () -> ()): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 64)
	row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	row.BorderSizePixel = 0
	corner(row, 10)

	local titleLabel = makeLabel(row, title, 14, Color3.fromRGB(255, 255, 255), true)
	titleLabel.Size = UDim2.new(1, -180, 0, 22)
	titleLabel.Position = UDim2.new(0, 12, 0, 6)
	local descLabel = makeLabel(row, desc, 11, Color3.fromRGB(190, 200, 220), false)
	descLabel.Size = UDim2.new(1, -180, 0, 30)
	descLabel.Position = UDim2.new(0, 12, 0, 28)

	local priceLabel = makeLabel(row, priceText, 13, Color3.fromRGB(255, 215, 0), true)
	priceLabel.Size = UDim2.new(0, 90, 0, 22)
	priceLabel.Position = UDim2.new(1, -178, 0, 8)
	priceLabel.TextXAlignment = Enum.TextXAlignment.Right

	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 84, 0, 30)
	button.Position = UDim2.new(1, -96, 0, 28)
	button.Text = buttonText
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.BackgroundColor3 = Color3.fromRGB(60, 160, 90)
	button.BorderSizePixel = 0
	corner(button, 8)
	button.Parent = row
	button.MouseButton1Click:Connect(function()
		onClick()
	end)
	return row
end

local function rebuildUpgrades()
	clearContent()
	for _, kindInfo in UPGRADE_KINDS do
		local level = upgradeLevel(kindInfo.kind)
		local cost = displayCost(kindInfo.kind, level)
		local priceText = if cost then "🪙 " .. tostring(cost) else "Cost: see server"
		local buttonText = if cost then "BUY" else "BUY"
		local maxed = cost == nil
		if maxed then
			priceText = "MAXED"
			buttonText = "MAX"
		end
		local row = buildRow(
			kindInfo.name .. "  •  Lv " .. tostring(level),
			kindInfo.desc,
			priceText,
			buttonText,
			function()
				if maxed then
					setStatus(kindInfo.name .. " is already maxed.", true)
					return
				end
				local remote = getRemote(remoteName("UpgradeBase", "UpgradeBase"))
				if not remote or not remote:IsA("RemoteEvent") then
					setStatus("UpgradeBase remote is not available yet.", true)
					return
				end
				setStatus("Sent " .. kindInfo.name .. " upgrade — waiting for the server…")
				armWatchdog("upgrade:" .. kindInfo.kind, kindInfo.name .. " upgrade")
				pcall(function()
					(remote :: RemoteEvent):FireServer(kindInfo.kind)
				end)
			end
		)
		row.Parent = contentFrame
	end
end

local function rebuildBrainrots()
	clearContent()
	if #placedList == 0 then
		local note = makeLabel(contentFrame, "No Brainrots placed in your base yet. Buy one on the conveyor and place it, then come back here to level it up (+25% income per level).", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 60)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	for _, placed in placedList do
		local charId = placed.CharacterId or placed.characterId or placed.Id
		local def: any = nil
		if Characters and Characters.GetById and typeof(charId) == "string" then
			def = Characters.GetById(charId)
		end
		local name = def and (def.DisplayName or def.Name) or tostring(placed.Name or charId or "?")
		local level = placed.Level or placed.level or 1
		local cost: number? = nil
		if Economy and Economy.UpgradeCost then
			local ok, c = pcall(function()
				return Economy.UpgradeCost("BrainrotLevel", level)
			end)
			if ok then
				cost = c
			end
		end
		local maxed = cost == nil
		local row = buildRow(
			name .. "  •  Lv " .. tostring(level),
			"Level up for +25% income. Currently earns about " .. tostring(placed.IncomePerSec or placed.incomePerSec or "?") .. "/s.",
			if maxed then "MAXED" else "🪙 " .. tostring(cost),
			if maxed then "MAX" else "LEVEL UP",
			function()
				if maxed then
					setStatus(name .. " is already max level.", true)
					return
				end
				local remote = getRemote(remoteName("UpgradeBrainrot", "UpgradeBrainrot"))
				if not remote or not remote:IsA("RemoteEvent") then
					setStatus("UpgradeBrainrot remote is not available yet.", true)
					return
				end
				-- The server matches placed records on InstanceId (a
				-- GUID), NOT CharacterId. The old code sent charId, so
				-- every level-up was rejected with "brainrot not
				-- placed" — even for a Brainrot visibly in the base.
				local instanceId = placed.InstanceId or placed.instanceId
				if typeof(instanceId) ~= "string" or instanceId == "" then
					setStatus("That Brainrot has no server id yet — reopen the Shop to refresh.", true)
					return
				end
				setStatus("Sent level-up for " .. name .. " — waiting for the server…")
				armWatchdog("brainrot:" .. instanceId, name .. " level-up")
				pcall(function()
					(remote :: RemoteEvent):FireServer(instanceId)
				end)
			end
		)
		row.Parent = contentFrame
	end
end

-- Mutations tab (the Mutation Lab): pick a placed Brainrot, then apply
-- a mutation for Mutation Crystals. The server re-validates everything
-- (ownership, compatibility with the character, crystal balance), so
-- the client only mirrors those checks for display: incompatible
-- mutations show NO FIT instead of a live button.
local function rebuildMutations()
	clearContent()
	if #placedList == 0 then
		local note = makeLabel(contentFrame, "No Brainrots placed in your base yet. Mutations apply to placed Brainrots — buy one on the conveyor, place it, then come back here.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 60)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	-- Target picker: one row per placed Brainrot.
	if mutateTarget == nil then
		local first = placedList[1]
		mutateTarget = first.InstanceId or first.instanceId
	end
	local target: any = nil
	for _, placed in placedList do
		local instanceId = placed.InstanceId or placed.instanceId
		if instanceId == mutateTarget then
			target = placed
			break
		end
	end
	if target == nil then
		target = placedList[1]
		mutateTarget = target.InstanceId or target.instanceId
	end
	for _, placed in placedList do
		local charId = placed.CharacterId or placed.characterId or placed.Id
		local def: any = nil
		if Characters and Characters.GetById and typeof(charId) == "string" then
			def = Characters.GetById(charId)
		end
		local name = def and (def.DisplayName or def.Name) or tostring(placed.Name or charId or "?")
		local instanceId = placed.InstanceId or placed.instanceId
		local selected = instanceId == mutateTarget
		local row = buildRow(
			name .. "  •  Lv " .. tostring(placed.Level or placed.level or 1)
				.. (if placed.Mutation then "  •  ✨ " .. tostring(placed.Mutation) else ""),
			"Mutate this Brainrot — pick a mutation below.",
			"",
			if selected then "✓ SELECTED" else "SELECT",
			function()
				mutateTarget = instanceId
				ShopController.Rebuild()
			end
		)
		row.Parent = contentFrame
	end
	-- Mutation options for the selected Brainrot.
	local list: { any } = {}
	if Mutations and Mutations.GetAll then
		local ok, all = pcall(function()
			return Mutations.GetAll()
		end)
		if ok and typeof(all) == "table" then
			list = all
		end
	end
	if #list == 0 then
		local note = makeLabel(contentFrame, "No mutations loaded yet.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	local targetCharId = target.CharacterId or target.characterId or target.Id
	local targetDef: any = nil
	if Characters and Characters.GetById and typeof(targetCharId) == "string" then
		targetDef = Characters.GetById(targetCharId)
	end
	local targetName = targetDef and (targetDef.DisplayName or targetDef.Name)
		or tostring(target.Name or targetCharId or "?")
	for _, mutation in list do
		local compatible = true
		if Mutations and Mutations.CanMutate and targetDef then
			local ok, result = pcall(function()
				return Mutations.CanMutate(targetDef, mutation.Id)
			end)
			if ok then
				compatible = result == true
			end
		end
		local alreadyApplied = target.Mutation ~= nil
			and string.lower(tostring(target.Mutation)) == string.lower(tostring(mutation.Id))
		local cost = mutation.Cost or mutation.Crystals
		local row = buildRow(
			tostring(mutation.Name or mutation.Id)
				.. "  •  ×" .. tostring(mutation.IncomeMultiplier or "?") .. " income",
			tostring(mutation.Description or "")
				.. (if alreadyApplied then " (already applied)" else ""),
			if typeof(cost) == "number" then "💠 " .. tostring(cost) else "Cost: see server",
			if alreadyApplied then "APPLIED" elseif not compatible then "NO FIT" else "APPLY",
			function()
				if alreadyApplied then
					setStatus(tostring(mutation.Name) .. " is already applied to " .. targetName .. ".")
					return
				end
				if not compatible then
					setStatus(targetName .. " cannot take " .. tostring(mutation.Name) .. " — check its compatibility.", true)
					return
				end
				local remote = getRemote(remoteName("MutateBrainrot", "MutateBrainrot"))
				if not remote or not remote:IsA("RemoteEvent") then
					setStatus("MutateBrainrot remote is not available yet.", true)
					return
				end
				setStatus("Applying " .. tostring(mutation.Name) .. " to " .. targetName .. " — waiting for the server…")
				armWatchdog("mutate:" .. tostring(mutateTarget), tostring(mutation.Name) .. " mutation")
				pcall(function()
					(remote :: RemoteEvent):FireServer({
						Action = "Mutate",
						InstanceId = mutateTarget,
						MutationId = mutation.Id,
					})
				end)
			end
		)
		row.Parent = contentFrame
	end
end

-- Fusion tab (the Fusion Lab, v1.0.1 integration QA — FusionService
-- had a server handler but NO client UI, so fusion was unreachable in
-- game): pick two UNPLACED Brainrots from your inventory and fuse them
-- into the character their recipe produces. Recipes come from shared
-- Mutations.FusionRecipes; the cost is the display-only
-- Economy.FusionCost for the pair (the server re-validates and charges
-- it). Placed Brainrots cannot fuse — the server rejects them with
-- "instance is placed" — so only the Unplaced list from the base
-- snapshot is shown here. Fires FuseBrainrot {InstanceIdA, InstanceIdB}
-- (the exact payload FusionService.onUpgradeRemote expects) with the
-- same 5s no-reply watchdog as the Mutations tab.
local function rebuildFusion()
	clearContent()
	local function instanceName(inst: any): string
		local charId = inst.CharacterId or inst.characterId or inst.Id
		local def: any = nil
		if Characters and Characters.GetById and typeof(charId) == "string" then
			def = Characters.GetById(charId)
		end
		return def and (def.DisplayName or def.Name) or tostring(inst.Name or charId or "?")
	end
	local function findUnplaced(instanceId: string?): any?
		if typeof(instanceId) ~= "string" then
			return nil
		end
		for _, inst in unplacedList do
			if (inst.InstanceId or inst.instanceId) == instanceId then
				return inst
			end
		end
		return nil
	end
	-- Keep the selection valid after a refresh (fused instances vanish).
	if fuseA ~= nil and findUnplaced(fuseA) == nil then
		fuseA = nil
	end
	if fuseB ~= nil and findUnplaced(fuseB) == nil then
		fuseB = nil
	end
	local aName = if fuseA then instanceName(findUnplaced(fuseA) or {}) else "— pick below —"
	local bName = if fuseB then instanceName(findUnplaced(fuseB) or {}) else "— pick below —"
	local fuseRow = buildRow(
		"Fuse:  " .. aName .. "  +  " .. bName,
		"Both inputs are consumed and the recipe result is granted at level 1. Cost is charged by the server (1000 coins + 25 Mutation Crystals).",
		"",
		"FUSE",
		function()
			if fuseA == nil or fuseB == nil or fuseA == fuseB then
				setStatus("Pick two different unplaced Brainrots first.", true)
				return
			end
			local remote = getRemote(remoteName("FuseBrainrot", "FuseBrainrot"))
			if not remote or not remote:IsA("RemoteEvent") then
				setStatus("FuseBrainrot remote is not available yet.", true)
				return
			end
			setStatus("Fusing " .. aName .. " + " .. bName .. " — waiting for the server…")
			armWatchdog("fusion:" .. tostring(fuseA), "fusion")
			pcall(function()
				(remote :: RemoteEvent):FireServer({
					InstanceIdA = fuseA,
					InstanceIdB = fuseB,
				})
			end)
		end
	)
	fuseRow.Parent = contentFrame
	if #unplacedList == 0 then
		local note = makeLabel(contentFrame, "No unplaced Brainrots in your inventory yet. Buy one on the conveyor and leave it unplaced — placed Brainrots cannot fuse. Recipes are listed below so you know what to hunt for.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 60)
		note.Position = UDim2.new(0, 8, 0, 8)
	else
		for _, inst in unplacedList do
			local instanceId = inst.InstanceId or inst.instanceId
			local slot = if instanceId == fuseA then "A" elseif instanceId == fuseB then "B" else nil
			local row = buildRow(
				instanceName(inst) .. "  •  Lv " .. tostring(inst.Level or inst.level or 1)
					.. (if inst.Mutation then "  •  ✨ " .. tostring(inst.Mutation) else ""),
				"Unplaced — in your inventory, ready to fuse.",
				"",
				if slot then "✓ SLOT " .. slot else "SELECT",
				function()
					if instanceId == fuseA then
						fuseA = nil
					elseif instanceId == fuseB then
						fuseB = nil
					elseif fuseA == nil then
						fuseA = instanceId
					elseif fuseB == nil then
						fuseB = instanceId
					else
						fuseB = instanceId
					end
					ShopController.Rebuild()
				end
			)
			row.Parent = contentFrame
		end
	end
	-- Recipe list (shared data — the same table FusionService reads).
	local recipes: { any } = {}
	if Mutations and typeof(Mutations.FusionRecipes) == "table" then
		recipes = Mutations.FusionRecipes
	end
	if #recipes == 0 then
		local note = makeLabel(contentFrame, "No fusion recipes loaded yet.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	for _, recipe in recipes do
		local pair = recipe.Characters or recipe.characters
		if typeof(pair) == "table" and #pair >= 2 then
			local nameA = instanceName({ CharacterId = pair[1] })
			local nameB = instanceName({ CharacterId = pair[2] })
			local resultName = instanceName({ CharacterId = recipe.ResultId })
			local costText = "Cost: see server"
			if Economy and Economy.FusionCost then
				local ok, cost = pcall(function()
					return Economy.FusionCost(pair[1], pair[2])
				end)
				if ok and typeof(cost) == "table" then
					costText = "🪙 " .. tostring(cost.Coins or "?") .. "  💠 " .. tostring(cost.MutationCrystals or "?")
				end
			end
			local row = buildRow(
				nameA .. "  +  " .. nameB .. "  →  " .. resultName,
				tostring(recipe.Hint or ""),
				costText,
				"SELECT",
				function()
					-- Pre-select matching unplaced instances, if owned.
					local foundA: string? = nil
					local foundB: string? = nil
					for _, inst in unplacedList do
						local charId = inst.CharacterId or inst.characterId
						local id = inst.InstanceId or inst.instanceId
						if charId == pair[1] and foundA == nil then
							foundA = id
						elseif charId == pair[2] and foundB == nil then
							foundB = id
						end
					end
					if foundA ~= nil and foundB ~= nil then
						fuseA = foundA
						fuseB = foundB
						setStatus("Selected " .. nameA .. " + " .. nameB .. " — press FUSE.")
						ShopController.Rebuild()
					else
						setStatus("You don't own both " .. nameA .. " and " .. nameB .. " unplaced yet.", true)
					end
				end
			)
			row.Parent = contentFrame
		end
	end
end

local function rebuildPowers()
	clearContent()
	local list: { any } = {}
	if Powers and Powers.GetAll then
		local ok, all = pcall(function()
			return Powers.GetAll()
		end)
		if ok and typeof(all) == "table" then
			list = all
		end
	end
	if #list == 0 then
		local note = makeLabel(contentFrame, "No powers loaded yet.", 13, Color3.fromRGB(200, 210, 230), false)
		note.Size = UDim2.new(1, -16, 0, 40)
		note.Position = UDim2.new(0, 8, 0, 8)
		return
	end
	-- Mastery display (v1.1 E, Workstream B): the server grants +10 XP
	-- per successful power use, max level 5, +5% damage / −2% cooldown
	-- per level (cooldown floor 3s) — but it pushes NO mastery state
	-- to the client (no PowerMasteryUpdate exists). So the tab shows
	-- the formula (true) plus this session's use counts from
	-- AbilityController (labelled session-only, never the server level).
	local sessionUses: { [string]: number } = {}
	pcall(function()
		local mod = script.Parent:FindFirstChild("AbilityController")
		if mod then
			local ability = require(mod)
			if ability.GetSessionPowerUses then
				sessionUses = ability.GetSessionPowerUses()
			end
		end
	end)
	local masteryNote = makeLabel(contentFrame, "Mastery: +10 XP per use • max Lv 5 • +5% damage / −2% cooldown per level (cooldown floor 3s). Use counts below are THIS SESSION only — the server keeps the real mastery level.", 12, Color3.fromRGB(120, 220, 255), true)
	masteryNote.Size = UDim2.new(1, -16, 0, 36)
	masteryNote.Position = UDim2.new(0, 8, 0, 8)
	for _, power in list do
		-- Which Brainrot owns this power? Primaries map via Characters.
		local ownerId: string? = nil
		local ownerName = "Everyone"
		if Characters and Characters.GetAll then
			local ok, allChars = pcall(function()
				return Characters.GetAll()
			end)
			if ok and typeof(allChars) == "table" then
				for _, def in allChars do
					if def.AbilityId == power.Id then
						ownerId = def.Id
						ownerName = def.DisplayName or def.Name
						break
					end
				end
			end
		end
		local isGeneric = ownerId == nil
		local isOwned = isGeneric or (ownerId ~= nil and owned[ownerId] == true)
		local uses = sessionUses[tostring(power.Id)] or 0
		local masteryText = if uses > 0 then "  •  Used " .. tostring(uses) .. "× this session" else "  •  Not used this session"
		local row = buildRow(
			tostring(power.Name) .. "  •  " .. tostring(ownerName),
			tostring(power.Description or "") .. masteryText,
			if isGeneric then "FREE" else (if isOwned then "OWNED" else "Unlock via Brainrot"),
			if isOwned then "OWNED" else "UNLOCK",
			function()
				if isOwned then
					setStatus(tostring(power.Name) .. " is already yours.")
					return
				end
				local buyRemote = getRemote(remoteName("BuyCharacter", "BuyCharacter"))
				if not buyRemote or not buyRemote:IsA("RemoteEvent") then
					setStatus("BuyCharacter remote is not available yet.", true)
					return
				end
				setStatus("Buying " .. ownerName .. " to unlock " .. tostring(power.Name) .. " — waiting for the server…")
				armWatchdog("power:" .. tostring(ownerId), tostring(power.Name) .. " unlock")
				pcall(function()
					(buyRemote :: RemoteEvent):FireServer(ownerId)
				end)
				task.delay(1.5, function()
					ShopController.RefreshShopData()
				end)
			end
		)
		row.Parent = contentFrame
	end
end

function ShopController.Rebuild()
	if activeTab == "Upgrades" then
		rebuildUpgrades()
	elseif activeTab == "Brainrots" then
		rebuildBrainrots()
	elseif activeTab == "Mutations" then
		rebuildMutations()
	elseif activeTab == "Fusion" then
		rebuildFusion()
	else
		rebuildPowers()
	end
end

function ShopController.SetTab(tab: string)
	activeTab = tab
	ShopController.Rebuild()
end

function ShopController.RefreshShopData()
	local shopFn = getRemote(remoteName("RequestShop", "RequestShop"))
	if shopFn and shopFn:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (shopFn :: RemoteFunction):InvokeServer()
			end)
			if ok and typeof(result) == "table" then
				if typeof(result.Coins) == "number" then
					knownCoins = result.Coins
					if coinsLabel then
						coinsLabel.Text = "🪙 " .. tostring(math.floor(knownCoins + 0.5))
					end
				end
				local list = result.Characters or result.characters
				if typeof(list) == "table" then
					for _, entry in list do
						if typeof(entry) == "table" and typeof(entry.Id) == "string" then
							owned[entry.Id] = entry.Owned == true
						end
					end
				end
				ShopController.Rebuild()
			end
		end)
	end
	local baseFn = getRemote(remoteName("RequestBase", "RequestBase"))
	if baseFn and baseFn:IsA("RemoteFunction") then
		task.spawn(function()
			local ok, result = pcall(function()
				return (baseFn :: RemoteFunction):InvokeServer()
			end)
			if ok and typeof(result) == "table" then
				baseState = result
				local placed = result.Placed or result.placed or result.Brainrots
				if typeof(placed) == "table" then
					placedList = placed
				end
				local unplaced = result.Unplaced or result.unplaced
				if typeof(unplaced) == "table" then
					-- On-expedition filter (v1.1 E): never offer the
					-- instance away on an expedition for fuse/mutate.
					local away = expeditionInstanceId()
					if away then
						local filtered: { any } = {}
						for _, inst in unplaced do
							if typeof(inst) == "table" and inst.InstanceId ~= away then
								table.insert(filtered, inst)
							end
						end
						unplacedList = filtered
					else
						unplacedList = unplaced
					end
				end
				ShopController.Rebuild()
			end
		end)
	else
		-- WAVE 3 (v1.1 E) FIX: the old elseif branch fired "GetBase"
		-- on RequestBase as a RemoteEvent — RequestBase is a
		-- RemoteFunction and has no event handler, so the fire was
		-- dead (audit F1). Removed, not replaced.
	end
end

function ShopController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	ShopController.RefreshShopData()
	ShopController.Rebuild()
end

function ShopController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function ShopController.Toggle()
	if isOpen then
		ShopController.Close()
	else
		ShopController.Open()
	end
end

function ShopController.IsOpen(): boolean
	return isOpen
end

-- Called by BaseController / HUD when a server push arrives, so a
-- confirmed purchase clears its watchdog and refreshes the rows.
function ShopController.OnBaseUpdate(data: any)
	if typeof(data) == "table" then
		baseState = data
		local placed = data.Placed or data.placed or data.Brainrots
		if typeof(placed) == "table" then
			placedList = placed
		end
		local unplaced = data.Unplaced or data.unplaced
		if typeof(unplaced) == "table" then
			unplacedList = unplaced
		end
		-- A fusion result arrives as a BaseUpdate with Action =
		-- "FusionResult" (FusionService): clear the fuse watchdog and
		-- report the result instead of leaving "waiting for server…".
		if data.Action == "FusionResult" then
			for key, _ in pending do
				if string.sub(key, 1, 7) == "fusion:" then
					pending[key] = nil
				end
			end
			fuseA = nil
			fuseB = nil
			local resultName = tostring(data.CharacterId or "?")
			setStatus("Fusion succeeded — " .. resultName .. " joined your inventory!")
		end
	end
	for key, _ in pending do
		if string.sub(key, 1, 8) == "upgrade:" or string.sub(key, 1, 8) == "brainrot" or string.sub(key, 1, 7) == "mutate:" or string.sub(key, 1, 7) == "fusion:" then
			pending[key] = nil
		end
	end
	if isOpen then
		ShopController.Rebuild()
	end
end

function ShopController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Shop"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 620, 0, 480)
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 36)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(255, 200, 40)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = makeLabel(panel, "🛒  SHOP", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 160, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	coinsLabel = makeLabel(panel, "🪙 0", 16, Color3.fromRGB(255, 215, 0), true)
	coinsLabel.Size = UDim2.new(0, 110, 0, 24)
	coinsLabel.Position = UDim2.new(1, -170, 0, 12)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, 36, 0, 30)
	closeBtn.Position = UDim2.new(1, -48, 0, 10)
	closeBtn.Text = "✕"
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 16
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	closeBtn.BorderSizePixel = 0
	corner(closeBtn, 8)
	closeBtn.Parent = panel
	closeBtn.MouseButton1Click:Connect(function()
		ShopController.Close()
	end)

	-- Mutation Lab shortcut (v1.1 E): the full Lab (evolve / traits /
	-- recipes / alternate forms) lives in LaboratoryController; this
	-- button opens it from the Shop.
	local labBtn = Instance.new("TextButton")
	labBtn.Name = "LabButton"
	labBtn.Size = UDim2.new(0, 104, 0, 24)
	labBtn.Position = UDim2.new(1, -286, 0, 12)
	labBtn.Text = "🧪 MUTATION LAB"
	labBtn.Font = Enum.Font.GothamBold
	labBtn.TextSize = 11
	labBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	labBtn.BackgroundColor3 = Color3.fromRGB(90, 70, 160)
	labBtn.BorderSizePixel = 0
	corner(labBtn, 8)
	labBtn.Parent = panel
	labBtn.MouseButton1Click:Connect(function()
		pcall(function()
			local mod = script.Parent:FindFirstChild("LaboratoryController")
			if mod then
				local lab = require(mod)
				if lab.Open then
					lab.Open()
				end
			end
		end)
	end)

	statusLabel = makeLabel(panel, "Prices are shown for display only — the server validates every purchase.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	-- Tabs. Mutations is the Mutation Lab: pick a placed Brainrot, apply
	-- a mutation for Mutation Crystals (server-validated). Fusion is the
	-- Fusion Lab: pick two unplaced Brainrots and fuse them.
	local tabNames = { "Upgrades", "Brainrots", "Mutations", "Fusion", "Powers" }
	local tabButtons: { [string]: TextButton } = {}
	for i, tab in tabNames do
		local btn = Instance.new("TextButton")
		btn.Name = "Tab_" .. tab
		btn.Size = UDim2.new(0, 112, 0, 30)
		btn.Position = UDim2.new(0, 16 + (i - 1) * 118, 0, 66)
		btn.Text = string.upper(tab)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 13
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.BackgroundColor3 = if tab == activeTab then Color3.fromRGB(90, 70, 160) else Color3.fromRGB(50, 48, 80)
		btn.BorderSizePixel = 0
		corner(btn, 8)
		btn.Parent = panel
		tabButtons[tab] = btn
		btn.MouseButton1Click:Connect(function()
			for name, b in tabButtons do
				b.BackgroundColor3 = if name == tab then Color3.fromRGB(90, 70, 160) else Color3.fromRGB(50, 48, 80)
			end
			ShopController.SetTab(tab)
		end)
	end

	contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Name = "Content"
	contentFrame.Size = UDim2.new(1, -24, 1, -116)
	contentFrame.Position = UDim2.new(0, 12, 0, 106)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 6
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	contentFrame.Parent = panel
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = contentFrame

	if UserInputService.TouchEnabled then
		panel.Size = UDim2.new(0.94, 0, 0.86, 0)
	end

	-- Server pushes that confirm purchases.
	local folder = getRemotesFolder()
	if folder then
		local statsRemote = folder:FindFirstChild(remoteName("PlayerStats", "PlayerStats"))
		if statsRemote and statsRemote:IsA("RemoteEvent") then
			(statsRemote :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				if typeof(payload) == "table" and typeof(payload.Coins) == "number" then
					knownCoins = payload.Coins
					if coinsLabel then
						coinsLabel.Text = "🪙 " .. tostring(math.floor(knownCoins + 0.5))
					end
					for key, _ in pending do
						if string.sub(key, 1, 6) == "power:" then
							clearPending(key, "Purchase")
						end
					end
					if isOpen then
						ShopController.RefreshShopData()
					end
				end
			end)
		end
		local baseRemote = folder:FindFirstChild(remoteName("BaseUpdate", "BaseUpdate"))
		if baseRemote and baseRemote:IsA("RemoteEvent") then
			(baseRemote :: RemoteEvent).OnClientEvent:Connect(function(data: any)
				ShopController.OnBaseUpdate(data)
			end)
		end
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			ShopController.Toggle()
		end
	end)

	ShopController.Rebuild()
	print("[GlitchTide] ShopController ready")
end

return ShopController
