--!strict
-- LaboratoryController.luau
-- Mutation Lab panel (v1.1 Wave 3, Workstream E): evolve, trait
-- upgrades, secret recipes, alternate forms, mutate + fuse — all
-- through the LaboratoryService / MutationService / FusionService
-- remotes. Server side is Workstream C (LaboratoryService).
--
-- Remotes:
--   RequestLab (RemoteFunction) -> GetLabState(player). NOTE: the live
--     return is {Evolvable, Evolved, DiscoveredRecipes, MaxLevel} —
--     the Recipes / TraitCosts tables REMOTES_NEEDED_C.md describes are
--     NOT in the return; costs/recipes come from the shared LabDefs
--     module (client-readable, same tables the server reads).
--   LabUpdate (RemoteEvent) -> {Action="LabUpdate", State=<GetLabState>}
--   EvolveBrainrot (RemoteEvent) <- Action envelope:
--     {Action="Evolve", InstanceId} | {Action="UpgradeTrait",
--     InstanceId, TraitId} | {Action="DiscoverRecipe", RecipeId} |
--     {Action="AlternateForm", InstanceId}
--   MutateBrainrot (RemoteEvent) <- {Action="Mutate", InstanceId,
--     MutationId} (same remote the Shop Mutations tab uses)
--   FuseBrainrot (RemoteEvent) <- {InstanceIdA, InstanceIdB}
-- ON-EXPEDITION RULE (QA_V11_C §9.3): the server enforces
-- OnExpedition only at the expedition API — Base/Mutation/Fusion do
-- not read the flag. This panel NEVER offers the active expedition's
-- instance for evolve / trait / mutate / fuse / alternate-form: the
-- active InstanceId comes from ExpeditionService (one active trip per
-- player, server-enforced), so excluding that one id is sufficient.
-- SECRET RULE: recipes never name their required secret — the panel
-- shows "requires a hidden discovery" and never prints a secret id.
-- The server validates discovery on DiscoverRecipe; an undiscovered
-- recipe fails server-side (warn only, no failure payload — the panel
-- uses the 5s no-reply watchdog pattern for feedback).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local LaboratoryController = {}

local PanelKit = require(script.Parent.PanelKit)

local Characters: any = nil
local LabDefs: any = nil
local Mutations: any = nil
pcall(function()
	Characters = require(ReplicatedStorage:WaitForChild("Characters", 10))
end)
pcall(function()
	LabDefs = require(ReplicatedStorage:WaitForChild("LabDefs", 10))
end)
pcall(function()
	Mutations = require(ReplicatedStorage:WaitForChild("Mutations", 10))
end)

local gui: ScreenGui? = nil
local contentFrame: ScrollingFrame? = nil
local statusLabel: TextLabel? = nil
local isOpen = false
local labState: any = nil
local baseState: any = nil
local activeTab: string = "Evolve"
local selectedInstanceId: string? = nil
local mutateTarget: string? = nil
local fuseA: string? = nil
local fuseB: string? = nil
local pending: { [string]: number } = {}

local function setStatus(text: string, isError: boolean?)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if isError then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(200, 220, 255)
	end
end

local function playSound(method: string)
	PanelKit.PlaySound(method)
end

local function armWatchdog(key: string, what: string)
	pending[key] = os.clock()
	task.delay(5, function()
		if pending[key] and os.clock() - (pending[key] or 0) >= 4.9 then
			pending[key] = nil
			setStatus("No reply from the server for " .. what .. " — check your coins / crystals.", true)
		end
	end)
end

local function clearPending(prefix: string)
	for key, _ in pending do
		if string.sub(key, 1, #prefix) == prefix then
			pending[key] = nil
		end
	end
end

-- The instance currently away on an expedition (nil when none). Only
-- one trip can be active, so excluding this one id is the whole rule.
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

-- Merged instance pool: rich lab entries first, then any RequestBase
-- instance the lab state did not list (placed / low-level unplaced).
local function allInstances(): { any }
	local out: { any } = {}
	local seen: { [string]: boolean } = {}
	local function add(inst: any)
		if typeof(inst) ~= "table" then
			return
		end
		local id = inst.InstanceId or inst.instanceId
		if typeof(id) ~= "string" or id == "" or seen[id] then
			return
		end
		seen[id] = true
		table.insert(out, inst)
	end
	if typeof(labState) == "table" then
		for _, inst in ipairs(labState.Evolvable or {}) do
			add(inst)
		end
		for _, inst in ipairs(labState.Evolved or {}) do
			add(inst)
		end
	end
	if typeof(baseState) == "table" then
		for _, inst in ipairs(baseState.Placed or {}) do
			add(inst)
		end
		for _, inst in ipairs(baseState.Unplaced or {}) do
			add(inst)
		end
	end
	return out
end

local function instanceName(inst: any): string
	local charId = inst.CharacterId or inst.characterId or inst.Id
	if Characters and Characters.GetById and typeof(charId) == "string" then
		local def = Characters.GetById(charId)
		if def then
			return tostring(def.DisplayName or def.Name)
		end
	end
	return tostring(inst.Name or charId or "?")
end

local function instanceRarity(inst: any): string
	local charId = inst.CharacterId or inst.characterId
	if Characters and Characters.GetById and typeof(charId) == "string" then
		local def = Characters.GetById(charId)
		if def and typeof(def.Rarity) == "string" then
			return def.Rarity
		end
	end
	return tostring(inst.Rarity or "Common")
end

local function isOnExpedition(inst: any): boolean
	local away = expeditionInstanceId()
	if not away then
		return false
	end
	return (inst.InstanceId or inst.instanceId) == away
end

local function evolveCostText(rarity: string): string
	if LabDefs and LabDefs.GetEvolveCost then
		local ok, cost = pcall(function()
			return LabDefs.GetEvolveCost(rarity)
		end)
		if ok and typeof(cost) == "table" then
			return "🪙 " .. tostring(cost.Coins or 0) .. "  💠 " .. tostring(cost.MutationCrystals or 0)
				.. "  →  +" .. tostring(cost.XP or 0) .. " XP, +" .. tostring(cost.Gems or 0) .. " 💎"
		end
	end
	return "Cost: see server"
end

local function fireLab(payload: { [string]: any }, what: string)
	if not PanelKit.Debounce("lab:" .. tostring(payload.Action), 1) then
		setStatus("Slow down — the lab answers once a second.", true)
		return
	end
	local fired = PanelKit.FireServerChecked("EvolveBrainrot", 0, payload)
	if fired then
		setStatus("Sent " .. what .. " — waiting for the server…")
		armWatchdog("lab:" .. tostring(payload.Action), what)
		playSound("click")
	else
		setStatus("EvolveBrainrot remote is not available yet.", true)
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

local function buildRow(title: string, desc: string, priceText: string, buttonText: string, bg: Color3, onClick: () -> ()): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -12, 0, 64)
	row.BackgroundColor3 = Color3.fromRGB(28, 26, 48)
	row.BorderSizePixel = 0
	PanelKit.Corner(row, 10)
	local titleLabel = PanelKit.MakeLabel(row, title, 14, Color3.fromRGB(255, 255, 255), true)
	titleLabel.Size = UDim2.new(1, -190, 0, 22)
	titleLabel.Position = UDim2.new(0, 12, 0, 6)
	local descLabel = PanelKit.MakeLabel(row, desc, 11, Color3.fromRGB(190, 200, 220), false)
	descLabel.Size = UDim2.new(1, -190, 0, 30)
	descLabel.Position = UDim2.new(0, 12, 0, 28)
	local priceLabel = PanelKit.MakeLabel(row, priceText, 12, Color3.fromRGB(255, 215, 0), true)
	priceLabel.Size = UDim2.new(0, 90, 0, 22)
	priceLabel.Position = UDim2.new(1, -188, 0, 8)
	priceLabel.TextXAlignment = Enum.TextXAlignment.Right
	PanelKit.MakeButton(row, buttonText, UDim2.new(0, 84, 0, 30), UDim2.new(1, -96, 0, 28), bg, onClick)
	return row
end

local function note(text: string)
	local label = PanelKit.MakeLabel(contentFrame, text, 13, Color3.fromRGB(200, 210, 230), false)
	label.Size = UDim2.new(1, -16, 0, 48)
	label.Position = UDim2.new(0, 8, 0, 8)
end

-- ---- Evolve tab -----------------------------------------------------------
local function rebuildEvolve()
	clearContent()
	local evolvable: { any } = {}
	if typeof(labState) == "table" then
		evolvable = labState.Evolvable or {}
	end
	if #evolvable == 0 then
		note("Nothing can evolve yet. Evolution needs a MAX-LEVEL (Lv 5) UNPLACED Brainrot — level one up in the Shop, then come back here.")
		return
	end
	for _, inst in evolvable do
		if isOnExpedition(inst) then
			-- Never offered: the instance is away on an expedition.
			continue
		end
		local rarity = instanceRarity(inst)
		local name = instanceName(inst)
		local evolvedTrait = "?"
		if LabDefs and LabDefs.GetEvolvedTrait then
			local ok, trait = pcall(function()
				return LabDefs.GetEvolvedTrait(inst.CharacterId)
			end)
			if ok and typeof(trait) == "string" then
				evolvedTrait = trait
			end
		end
		local bestMutation = ""
		if LabDefs and LabDefs.GetBestMutationFor then
			local ok, mut = pcall(function()
				return LabDefs.GetBestMutationFor(inst.CharacterId)
			end)
			if ok and typeof(mut) == "string" then
				bestMutation = "  •  mutation → " .. mut
			end
		end
		local row = buildRow(
			name .. "  •  Lv " .. tostring(inst.Level or 5) .. "  •  " .. rarity,
			"Evolves into an evolved form: gains the " .. evolvedTrait .. " trait" .. bestMutation .. ". Same Brainrot, stronger.",
			evolveCostText(rarity),
			"EVOLVE",
			Color3.fromRGB(150, 60, 200),
			function()
				fireLab({ Action = "Evolve", InstanceId = inst.InstanceId }, "evolution of " .. name)
			end
		)
		row.Parent = contentFrame
	end
	-- Already-evolved list (display only — the count is real progress).
	local evolved: { any } = {}
	if typeof(labState) == "table" then
		evolved = labState.Evolved or {}
	end
	if #evolved > 0 then
		local head = PanelKit.MakeLabel(contentFrame, "Evolved (" .. tostring(#evolved) .. "):", 13, Color3.fromRGB(255, 215, 0), true)
		head.Size = UDim2.new(1, -16, 0, 20)
		head.Position = UDim2.new(0, 8, 0, 8)
		for _, inst in evolved do
			local row = buildRow(
				instanceName(inst) .. (if inst.EvolvedFormName then " — " .. tostring(inst.EvolvedFormName) else " — Evolved"),
				"Trait: " .. tostring(inst.EvolvedTrait or "?") .. (if inst.Mutation then "  •  ✨ " .. tostring(inst.Mutation) else ""),
				"",
				"EVOLVED ✓",
				Color3.fromRGB(60, 120, 70),
				function()
					setStatus(instanceName(inst) .. " is already evolved.")
				end
			)
			row.Parent = contentFrame
		end
	end
end

-- ---- Traits tab -----------------------------------------------------------
local function rebuildTraits()
	clearContent()
	local pool = allInstances()
	if #pool == 0 then
		note("No Brainrots found yet — buy one on the conveyor first.")
		return
	end
	-- Instance picker.
	if selectedInstanceId == nil then
		selectedInstanceId = pool[1].InstanceId or pool[1].instanceId
	end
	local selected: any = nil
	for _, inst in pool do
		if (inst.InstanceId or inst.instanceId) == selectedInstanceId then
			selected = inst
			break
		end
	end
	if selected == nil then
		selected = pool[1]
		selectedInstanceId = selected.InstanceId or selected.instanceId
	end
	for _, inst in pool do
		local id = inst.InstanceId or inst.instanceId
		local away = isOnExpedition(inst)
		local row = buildRow(
			instanceName(inst) .. "  •  Lv " .. tostring(inst.Level or 1)
				.. (if inst.Evolved then "  •  ✨ Evolved" else "")
				.. (if away then "  •  🧭 ON EXPEDITION" else ""),
			"Pick this Brainrot to upgrade its traits.",
			"",
			if id == selectedInstanceId then "✓ SELECTED" else "SELECT",
			if away then Color3.fromRGB(70, 70, 90) else Color3.fromRGB(60, 120, 220),
			function()
				if away then
					setStatus(instanceName(inst) .. " is away on an expedition — traits wait until it returns.", true)
					return
				end
				selectedInstanceId = id
				LaboratoryController.Rebuild()
			end
		)
		row.Parent = contentFrame
	end
	if isOnExpedition(selected) then
		note(instanceName(selected) .. " is away on an expedition — trait upgrades wait until it returns.")
		return
	end
	-- Trait rows for the selected Brainrot.
	local charId = selected.CharacterId or selected.characterId
	local traits: { string } = {}
	if Characters and Characters.GetById and typeof(charId) == "string" then
		local def = Characters.GetById(charId)
		if def and typeof(def.Traits) == "table" then
			traits = def.Traits
		end
	end
	if #traits == 0 then
		note("This Brainrot has no listed traits.")
		return
	end
	local maxLevel = 3
	if LabDefs and LabDefs.TRAIT_MAX_LEVEL then
		maxLevel = LabDefs.TRAIT_MAX_LEVEL
	end
	local levels = selected.TraitLevels or {}
	for _, trait in ipairs(traits) do
		local current = math.floor(tonumber(levels[trait]) or 0)
		local nextLevel = current + 1
		local costText = "MAXED — trait mastered"
		if nextLevel <= maxLevel and LabDefs and LabDefs.GetTraitUpgradeCost then
			local ok, cost = pcall(function()
				return LabDefs.GetTraitUpgradeCost(nextLevel)
			end)
			if ok and typeof(cost) == "table" then
				costText = "🪙 " .. tostring(cost.Coins or 0) .. "  💠 " .. tostring(cost.MutationCrystals or 0)
					.. "  •  +" .. tostring(cost.XP or 0) .. " XP, +" .. tostring(cost.Gems or 0) .. " 💎"
					.. (if nextLevel == maxLevel then "  •  Lv 3 also glitch-infuses (2x income!)" else "")
			end
		end
		local row = buildRow(
			tostring(trait) .. "  •  Lv " .. tostring(current) .. "/" .. tostring(maxLevel),
			"Upgrade this trait on " .. instanceName(selected) .. ".",
			costText,
			if current >= maxLevel then "MAXED" else "UPGRADE → Lv " .. tostring(nextLevel),
			if current >= maxLevel then Color3.fromRGB(60, 120, 70) else Color3.fromRGB(200, 150, 30),
			function()
				if current >= maxLevel then
					setStatus(tostring(trait) .. " is already maxed on " .. instanceName(selected) .. ".")
					return
				end
				fireLab({ Action = "UpgradeTrait", InstanceId = selectedInstanceId, TraitId = trait }, "trait upgrade " .. tostring(trait))
			end
		)
		row.Parent = contentFrame
	end
end

-- ---- Recipes tab ----------------------------------------------------------
local function rebuildRecipes()
	clearContent()
	local discovered: { [string]: boolean } = {}
	if typeof(labState) == "table" and typeof(labState.DiscoveredRecipes) == "table" then
		for _, id in ipairs(labState.DiscoveredRecipes) do
			discovered[tostring(id)] = true
		end
	end
	local recipes: { any } = {}
	if LabDefs and LabDefs.GetSecretRecipes then
		local ok, list = pcall(function()
			return LabDefs.GetSecretRecipes()
		end)
		if ok and typeof(list) == "table" then
			recipes = list
		end
	end
	if #recipes == 0 then
		note("No secret recipes loaded yet.")
		return
	end
	local head = PanelKit.MakeLabel(contentFrame, "Secret recipes are found by discovering hidden things in the world — never by listing them. Each recipe below is an evolution form; the discovery it needs is NOT named here.", 12, Color3.fromRGB(200, 210, 230), false)
	head.Size = UDim2.new(1, -16, 0, 44)
	head.Position = UDim2.new(0, 8, 0, 8)
	for _, recipe in ipairs(recipes) do
		local found = discovered[tostring(recipe.Id)] == true
		local charName = PanelKit.CharacterName(recipe.CharacterId)
		local row = buildRow(
			tostring(recipe.FormName or recipe.Id) .. "  •  " .. charName,
			tostring(recipe.Description or "") .. "  •  Bonus mutation: " .. tostring(recipe.BonusMutation or "?") .. "  •  +" .. tostring(recipe.BonusGems or 0) .. " 💎 on evolve.",
			if found then "DISCOVERED ✓" else "Requires a hidden discovery",
			if found then "READY" else "DISCOVER",
			if found then Color3.fromRGB(40, 160, 90) else Color3.fromRGB(90, 70, 160),
			function()
				if found then
					setStatus(tostring(recipe.FormName) .. " is discovered — evolve a " .. charName .. " to use it.")
					return
				end
				fireLab({ Action = "DiscoverRecipe", RecipeId = recipe.Id }, "recipe discovery " .. tostring(recipe.FormName))
			end
		)
		row.Parent = contentFrame
	end
end

-- ---- Alternate forms tab --------------------------------------------------
local function rebuildForms()
	clearContent()
	local pool = allInstances()
	local shown = 0
	for _, inst in pool do
		if isOnExpedition(inst) then
			continue
		end
		local alt: string? = nil
		if LabDefs and LabDefs.GetAlternateForm then
			local ok, form = pcall(function()
				return LabDefs.GetAlternateForm(inst.CharacterId)
			end)
			if ok and typeof(form) == "string" then
				alt = form
			end
		end
		if alt == nil then
			continue
		end
		shown += 1
		local cost = LabDefs and LabDefs.AlternateFormCost or { Coins = 2000, MutationCrystals = 20 }
		local row = buildRow(
			instanceName(inst) .. "  →  " .. PanelKit.CharacterName(alt),
			"Swap this Brainrot into its alternate form (same rarity, keeps level + mutation).",
			"🪙 " .. tostring(cost.Coins or 2000) .. "  💠 " .. tostring(cost.MutationCrystals or 20),
			"SWITCH FORM",
			Color3.fromRGB(90, 70, 160),
			function()
				fireLab({ Action = "AlternateForm", InstanceId = inst.InstanceId or inst.instanceId }, "alternate form of " .. instanceName(inst))
			end
		)
		row.Parent = contentFrame
	end
	if shown == 0 then
		note("None of your Brainrots has an alternate form yet — alternate forms exist for 11 same-rarity pairs.")
	end
end

-- ---- Mutate tab (compact; the Shop Mutations tab is the full view) ------
local function rebuildMutate()
	clearContent()
	local placed: { any } = {}
	if typeof(baseState) == "table" then
		placed = baseState.Placed or {}
	end
	if #placed == 0 then
		note("Mutations apply to PLACED Brainrots — buy one on the conveyor, place it in your base, then come back here. (The full Mutation Lab also lives in the Shop — B.)")
		return
	end
	if mutateTarget == nil then
		mutateTarget = placed[1].InstanceId or placed[1].instanceId
	end
	local target: any = nil
	for _, p in placed do
		if (p.InstanceId or p.instanceId) == mutateTarget then
			target = p
			break
		end
	end
	if target == nil then
		target = placed[1]
		mutateTarget = target.InstanceId or target.instanceId
	end
	for _, p in placed do
		local id = p.InstanceId or p.instanceId
		local row = buildRow(
			instanceName(p) .. "  •  Lv " .. tostring(p.Level or 1) .. (if p.Mutation then "  •  ✨ " .. tostring(p.Mutation) else ""),
			"Mutate this placed Brainrot.",
			"",
			if id == mutateTarget then "✓ SELECTED" else "SELECT",
			Color3.fromRGB(60, 120, 220),
			function()
				mutateTarget = id
				LaboratoryController.Rebuild()
			end
		)
		row.Parent = contentFrame
	end
	local list: { any } = {}
	if Mutations and Mutations.GetAll then
		local ok, all = pcall(function()
			return Mutations.GetAll()
		end)
		if ok and typeof(all) == "table" then
			list = all
		end
	end
	local targetDef: any = nil
	if Characters and Characters.GetById then
		targetDef = Characters.GetById(target.CharacterId or target.characterId)
	end
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
		local applied = target.Mutation ~= nil and string.lower(tostring(target.Mutation)) == string.lower(tostring(mutation.Id))
		local cost = mutation.Cost or mutation.Crystals
		local row = buildRow(
			tostring(mutation.Name or mutation.Id) .. "  •  ×" .. tostring(mutation.IncomeMultiplier or "?") .. " income",
			tostring(mutation.Description or "") .. (if applied then " (already applied)" else ""),
			if typeof(cost) == "number" then "💠 " .. tostring(cost) else "Cost: see server",
			if applied then "APPLIED" elseif not compatible then "NO FIT" else "APPLY",
			if applied or not compatible then Color3.fromRGB(70, 70, 90) else Color3.fromRGB(200, 150, 30),
			function()
				if applied then
					setStatus(tostring(mutation.Name) .. " is already applied.")
					return
				end
				if not compatible then
					setStatus(instanceName(target) .. " cannot take " .. tostring(mutation.Name) .. ".", true)
					return
				end
				if not PanelKit.Debounce("mutate", 1) then
					return
				end
				local fired = PanelKit.FireServerChecked("MutateBrainrot", 0, {
					Action = "Mutate",
					InstanceId = mutateTarget,
					MutationId = mutation.Id,
				})
				if fired then
					setStatus("Applying " .. tostring(mutation.Name) .. " — waiting for the server…")
					armWatchdog("mutate", tostring(mutation.Name) .. " mutation")
					playSound("mutation")
				else
					setStatus("MutateBrainrot remote is not available yet.", true)
				end
			end
		)
		row.Parent = contentFrame
	end
end

-- ---- Fuse tab (compact; the Shop Fusion tab is the full view) ------------
local function rebuildFuse()
	clearContent()
	local unplaced: { any } = {}
	if typeof(baseState) == "table" then
		for _, inst in ipairs(baseState.Unplaced or {}) do
			if not isOnExpedition(inst) then
				table.insert(unplaced, inst)
			end
		end
	end
	local aName = "— pick below —"
	local bName = "— pick below —"
	for _, inst in unplaced do
		local id = inst.InstanceId or inst.instanceId
		if id == fuseA then
			aName = instanceName(inst)
		end
		if id == fuseB then
			bName = instanceName(inst)
		end
	end
	local fuseRow = buildRow(
		"Fuse:  " .. aName .. "  +  " .. bName,
		"Both inputs are consumed; the recipe result is granted at level 1. Server charges 1000 coins + 25 Mutation Crystals.",
		"",
		"FUSE",
		Color3.fromRGB(200, 150, 30),
		function()
			if fuseA == nil or fuseB == nil or fuseA == fuseB then
				setStatus("Pick two different unplaced Brainrots first.", true)
				return
			end
			if not PanelKit.Debounce("fuse", 1) then
				return
			end
			local fired = PanelKit.FireServerChecked("FuseBrainrot", 0, { InstanceIdA = fuseA, InstanceIdB = fuseB })
			if fired then
				setStatus("Fusing " .. aName .. " + " .. bName .. " — waiting for the server…")
				armWatchdog("fuse", "fusion")
				playSound("fusion")
			else
				setStatus("FuseBrainrot remote is not available yet.", true)
			end
		end
	)
	fuseRow.Parent = contentFrame
	if #unplaced == 0 then
		note("No unplaced Brainrots in your inventory (on-expedition Brainrots are hidden here). Buy one on the conveyor and leave it unplaced — placed Brainrots cannot fuse.")
		return
	end
	for _, inst in unplaced do
		local id = inst.InstanceId or inst.instanceId
		local slot = if id == fuseA then "A" elseif id == fuseB then "B" else nil
		local row = buildRow(
			instanceName(inst) .. "  •  Lv " .. tostring(inst.Level or 1) .. (if inst.Mutation then "  •  ✨ " .. tostring(inst.Mutation) else ""),
			"Unplaced — in your inventory, ready to fuse.",
			"",
			if slot then "✓ SLOT " .. slot else "SELECT",
			Color3.fromRGB(60, 120, 220),
			function()
				if id == fuseA then
					fuseA = nil
				elseif id == fuseB then
					fuseB = nil
				elseif fuseA == nil then
					fuseA = id
				elseif fuseB == nil then
					fuseB = id
				else
					fuseB = id
				end
				LaboratoryController.Rebuild()
			end
		)
		row.Parent = contentFrame
	end
end

function LaboratoryController.Rebuild()
	if activeTab == "Evolve" then
		rebuildEvolve()
	elseif activeTab == "Traits" then
		rebuildTraits()
	elseif activeTab == "Recipes" then
		rebuildRecipes()
	elseif activeTab == "Forms" then
		rebuildForms()
	elseif activeTab == "Mutate" then
		rebuildMutate()
	else
		rebuildFuse()
	end
end

function LaboratoryController.SetTab(tab: string)
	activeTab = tab
	LaboratoryController.Rebuild()
end

function LaboratoryController.RefreshFromServer()
	local ok, result = PanelKit.InvokeChecked("RequestLab")
	if ok and typeof(result) == "table" then
		labState = result
	else
		labState = { Evolvable = {}, Evolved = {}, DiscoveredRecipes = {} }
		setStatus("Lab state is not available from the server yet.", true)
	end
	local okBase, baseResult = PanelKit.InvokeChecked("RequestBase")
	if okBase and typeof(baseResult) == "table" then
		baseState = baseResult
	end
	LaboratoryController.Rebuild()
end

function LaboratoryController.ApplyLabUpdate(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local state = payload.State
	if typeof(state) == "table" then
		labState = state
		clearPending("lab:")
		clearPending("mutate")
		clearPending("fuse")
		fuseA = nil
		fuseB = nil
		setStatus("Lab updated by the server.")
		playSound("evolve")
		if isOpen then
			LaboratoryController.RefreshFromServer()
		end
	end
end

function LaboratoryController.Open()
	if gui then
		gui.Enabled = true
	end
	isOpen = true
	LaboratoryController.RefreshFromServer()
end

function LaboratoryController.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
end

function LaboratoryController.Toggle()
	if isOpen then
		LaboratoryController.Close()
	else
		LaboratoryController.Open()
	end
end

function LaboratoryController.IsOpen(): boolean
	return isOpen
end

function LaboratoryController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "Laboratory"
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
	PanelKit.Corner(panel, 14)
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(120, 255, 200)
	pStroke.Thickness = 2
	pStroke.Parent = panel

	local title = PanelKit.MakeLabel(panel, "🧪  MUTATION LAB", 20, Color3.fromRGB(255, 215, 0), true)
	title.Size = UDim2.new(0, 260, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 10)

	PanelKit.MakeButton(panel, "✕", UDim2.new(0, 36, 0, 30), UDim2.new(1, -48, 0, 10), Color3.fromRGB(200, 60, 60), function()
		LaboratoryController.Close()
	end)

	statusLabel = PanelKit.MakeLabel(panel, "Evolve max-level Brainrots, upgrade traits, discover secret recipes.", 12, Color3.fromRGB(200, 220, 255), false)
	statusLabel.Size = UDim2.new(1, -32, 0, 18)
	statusLabel.Position = UDim2.new(0, 16, 0, 44)

	local tabNames = { "Evolve", "Traits", "Recipes", "Forms", "Mutate", "Fuse" }
	local tabButtons: { [string]: TextButton } = {}
	for i, tab in tabNames do
		local btn = PanelKit.MakeButton(panel, string.upper(tab), UDim2.new(0, 92, 0, 30), UDim2.new(0, 16 + (i - 1) * 98, 0, 66), if tab == activeTab then Color3.fromRGB(90, 70, 160) else Color3.fromRGB(50, 48, 80), function()
			for name, b in tabButtons do
				b.BackgroundColor3 = if name == tab then Color3.fromRGB(90, 70, 160) else Color3.fromRGB(50, 48, 80)
			end
			LaboratoryController.SetTab(tab)
		end)
		btn.Name = "Tab_" .. tab
		tabButtons[tab] = btn
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

	-- Live lab feed.
	PanelKit.Listen("LabUpdate", function(payload: any)
		LaboratoryController.ApplyLabUpdate(payload)
	end)

	LaboratoryController.Rebuild()
	print("[GlitchTide] LaboratoryController ready")
end

return LaboratoryController
