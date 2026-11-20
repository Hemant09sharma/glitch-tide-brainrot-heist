--!strict
-- AbilityService.luau
-- Glitch Tide — Brainrot Heist: The Memeverse.
-- Per-player loadout of 3 powers (data.AbilityLoadout) plus unlocks
-- (data.UnlockedPowers, bought with COINS). UsePower is validated
-- server-side: the power must be equipped + unlocked, the per-power
-- cooldown must have elapsed, and every effect is applied by the server
-- (velocity, ForceField, CFrame moves, Humanoid damage / WalkSpeed).
-- The client only ever sends a power id.
--
-- SINGLE SOURCE OF TRUTH (v1.0.1 QA): shared Powers.PlayablePowers
-- (Powers.GetPlayablePower) owns every power's cooldown, duration,
-- damage, range, radius and unlock cost. v1.0.0 kept a second table
-- here, SPEC_POWERS, that disagreed with the shared data on 9 of 12
-- powers (e.g. chaos_burst 15s here vs 30s shared, tide_surfer 30s/60s
-- here vs 9s/5s shared) AND charged Gems while the shared data charges
-- Coins — the server and the client could never agree on a cooldown or
-- a price. SPEC_POWERS is deleted; this file reads the shared defs.
-- Slam / Heal / character primaries are NOT handled here: CombatService
-- owns those on the same UseAbility remote (it ignores loadout ids,
-- this service ignores non-loadout ids, so the two never double-apply).
--
-- REMOTE: UseAbility exists in Remotes.Names. FX fire on SpawnEffect;
-- cooldown state is pushed to the using player on PowerUpdate (which
-- DOES exist in Remotes.Names — the v1.0.0 comment claiming otherwise
-- was wrong, and the client AbilityController already listens for it).
--
-- REAL EFFECTS (per power, all server-side):
--   dash           BodyVelocity burst forward (no damage, pure mobility)
--   energy_shield  ForceField on the character for 5s
--   magnet_pull    loose drop models within 20 studs glide to the player
--   teleport       blink <= 20 studs forward, ground raycast required
--   gravity_shift  upward BodyForce + boosted JumpPower for 5s
--   freeze_blast   nearby NPC/enemy Humanoids WalkSpeed 0 for 3s
--   shadow_walk    character ~invisible + faster for 4s
--   clone_decoy    a script-stripped character clone stands 8s as a decoy
--   tide_surfer    tide immunity for this tide (via TideService when
--                  linked, else a local expiry TideService can query)
--   rift_hook      velocity pull toward a raycast anchor (<= 30 studs)
--   chaos_burst    radial knockback + 10 damage within 12 studs
--   time_distortion nearby enemies slowed 50% for 5s
-- v1.1 (Workstream B): 5 new powers, all fully wired here with server
-- validation + cooldowns from the shared defs (never below 3s):
--   time_rewind      restore health + position from 3s ago (snapshots
--                    taken every 0.5s; cannot rewind death)
--   meteor_shower    5 pastry meteors over 3s around the player
--   void_dash        blink up to 14 studs, briefly untouchable, slices
--                    enemies passed through
--   gravity_crush    7-stud crush: damage + drag-in + rooted 2s
--   dimensional_prison nearest enemy in 12 studs caged 5s (no move/jump)
-- Power mastery (v1.1): +10 XP per successful use per power, levels
-- 0-5 (Powers.GetMasteryLevel); each level +5% damage, -2% cooldown
-- (cooldown floored at 3s). XP lives in data.PowerMastery and is
-- persisted via GetMasteryStateForSave / LoadMasteryState.
-- FX (v1.1): every successful use also fires a positional SpawnEffect
-- ring/flash in the power's colour — the positional form
-- EffectsController actually handles ("ring"/"flash"/"poof").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Powers = require(ReplicatedStorage:WaitForChild("Powers"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local _names: any = Remotes.Names

local AbilityService = {}

local _dataService: any = nil
local _tideService: any = nil

local DEFAULT_LOADOUT: { string } = { "dash", "energy_shield", "magnet_pull" }
local FALLBACK_COOLDOWN = 8

local _cooldowns: { [Player]: { [string]: number } } = {}
local _lastUse: { [Player]: number } = {}
-- Local Tide Surfer immunity (used when no TideService is linked).
local _surfers: { [Player]: number } = {}
-- Power mastery XP per player per power id (v1.1). Mirrored into
-- data.PowerMastery when a DataService is present so it persists.
local _masteryXP: { [Player]: { [string]: number } } = {}
-- Time Rewind snapshots: ring buffer of {Position, Health} taken every
-- 0.5s per player (v1.1). Oldest entry is ~3s old (7 entries).
local _snapshots: { [Player]: { { Position: Vector3, Health: number } } } = {}
local MASTERY_XP_PER_USE = 10
local MIN_COOLDOWN_SECONDS = 3

local Security: any = nil
pcall(function()
	local mod = script.Parent:FindFirstChild("SecurityService")
	if mod then
		Security = require(mod)
	end
end)

local function rateOk(player: Player, key: string, interval: number): boolean
	if Security and Security.RateLimit then
		local ok, allowed = pcall(function()
			return Security.RateLimit(player, key, interval)
		end)
		if ok then
			return allowed
		end
	end
	local now = os.clock()
	local last = _lastUse[player] or -math.huge
	if now - last < interval then
		return false
	end
	_lastUse[player] = now
	return true
end


-- R4-3: spendable balance — the raw balance minus any reservation
-- held for a pending reward commit (DataService.ReserveCoins).
-- Falls back to the raw balance when the DataService has no
-- reservation API (older stub).
local function spendableCoins(player: Player, data: any): number
	local coins = tonumber(data.Coins) or 0
	if _dataService and type(_dataService.GetSpendableCoins) == "function" then
		local ok, value = pcall(function()
			return _dataService.GetSpendableCoins(player)
		end)
		if ok and type(value) == "number" then
			return value
		end
	end
	return coins
end

local function sanitize(id: any): string?
	if Security and Security.SanitizeId then
		local ok, clean = pcall(function()
			return Security.SanitizeId(id)
		end)
		if ok then
			return clean
		end
	end
	if type(id) ~= "string" or #id < 1 or #id > 64 then
		return nil
	end
	if string.match(id, "^[%w%-_]+$") == nil then
		return nil
	end
	return id
end

local function getRemote(name: string): RemoteEvent?
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote ~= nil and (remote :: Instance):IsA("RemoteEvent") then
		return remote :: RemoteEvent
	end
	return nil
end

local function fireAll(name: string, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireAllClients(payload)
		end)
	end
end

local function fireClient(name: string, player: Player, payload: any)
	local remote = getRemote(name)
	if remote then
		pcall(function()
			remote:FireClient(player, payload)
		end)
	end
end

local function getData(player: Player): any
	if not _dataService then
		return nil
	end
	local ok, data = pcall(function()
		return _dataService.GetOrLoad(player)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

-- Shared playable-power def (Powers.GetPlayablePower), or nil when the
-- id is not one of the 17 loadout powers. This is the ONLY place power
-- tuning is read from — no local cooldown/cost table exists anymore.
local function getPlayableDef(powerId: string): any
	if Powers and type(Powers.GetPlayablePower) == "function" then
		local ok, def = pcall(function()
			return Powers.GetPlayablePower(powerId)
		end)
		if ok then
			return def
		end
	end
	return nil
end

local function getCooldownSeconds(powerId: string): number
	local def = getPlayableDef(powerId)
	if def and tonumber(def.Cooldown) then
		return tonumber(def.Cooldown) :: number
	end
	return FALLBACK_COOLDOWN
end

-- Mastery: XP / level for a player + power. Reads the in-memory table
-- first, falls back to data.PowerMastery (loaded saves).
local function getMasteryXP(player: Player, powerId: string): number
	local perPlayer = _masteryXP[player]
	if perPlayer ~= nil and type(perPlayer[powerId]) == "number" then
		return perPlayer[powerId]
	end
	local data = getData(player)
	if data ~= nil and type(data.PowerMastery) == "table" then
		return tonumber(data.PowerMastery[powerId]) or 0
	end
	return 0
end

local function getMasteryLevel(player: Player, powerId: string): number
	if Powers and type(Powers.GetMasteryLevel) == "function" then
		local ok, level = pcall(function()
			return Powers.GetMasteryLevel(getMasteryXP(player, powerId))
		end)
		if ok and type(level) == "number" then
			return level
		end
	end
	return 0
end

-- Effective cooldown for a player + power: shared cooldown reduced by
-- mastery (-2%/level), never below 3s.
local function getEffectiveCooldown(player: Player, powerId: string): number
	local base = getCooldownSeconds(powerId)
	if Powers and type(Powers.GetMasteryCooldownMultiplier) == "function" then
		local ok, mult = pcall(function()
			return Powers.GetMasteryCooldownMultiplier(getMasteryLevel(player, powerId))
		end)
		if ok and type(mult) == "number" then
			base *= mult
		end
	end
	return math.max(MIN_COOLDOWN_SECONDS, base)
end

-- Effective damage for a player + power: shared damage scaled by
-- mastery (+5%/level). Healing (negative damage) is NOT scaled.
local function getEffectiveDamage(player: Player, powerId: string, baseDamage: number): number
	if baseDamage <= 0 then
		return baseDamage
	end
	if Powers and type(Powers.GetMasteryDamageMultiplier) == "function" then
		local ok, mult = pcall(function()
			return Powers.GetMasteryDamageMultiplier(getMasteryLevel(player, powerId))
		end)
		if ok and type(mult) == "number" then
			return math.floor(baseDamage * mult + 0.5)
		end
	end
	return baseDamage
end

-- Award mastery XP for a successful use and mirror it into the
-- player's data table (persisted on the next DataService save).
local function awardMasteryXP(player: Player, powerId: string)
	_masteryXP[player] = _masteryXP[player] or {}
	_masteryXP[player][powerId] = (_masteryXP[player][powerId] or 0) + MASTERY_XP_PER_USE
	local data = getData(player)
	if data ~= nil then
		if type(data.PowerMastery) ~= "table" then
			data.PowerMastery = {}
		end
		data.PowerMastery[powerId] = _masteryXP[player][powerId]
	end
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function ensureLoadoutData(player: Player): any
	local data = getData(player)
	if not data then
		return nil
	end
	if type(data.AbilityLoadout) ~= "table" or #data.AbilityLoadout ~= 3 then
		data.AbilityLoadout = { DEFAULT_LOADOUT[1], DEFAULT_LOADOUT[2], DEFAULT_LOADOUT[3] }
	end
	if type(data.UnlockedPowers) ~= "table" then
		data.UnlockedPowers = { DEFAULT_LOADOUT[1], DEFAULT_LOADOUT[2], DEFAULT_LOADOUT[3] }
	end
	if type(data.Gems) ~= "number" then
		data.Gems = 0
	end
	return data
end

local function isUnlocked(data: any, powerId: string): boolean
	if type(data.UnlockedPowers) ~= "table" then
		return false
	end
	for _, id in ipairs(data.UnlockedPowers) do
		if id == powerId then
			return true
		end
	end
	return false
end

local function isEquipped(data: any, powerId: string): boolean
	if type(data.AbilityLoadout) ~= "table" then
		return false
	end
	for _, id in ipairs(data.AbilityLoadout) do
		if id == powerId then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Effect implementations (all server-side, all real).
-- ---------------------------------------------------------------------------

local function findDamageable(origin: Vector3, radius: number, exclude: Model?): { { Model: Model, Humanoid: Humanoid, Root: BasePart } }
	local out: { { Model: Model, Humanoid: Humanoid, Root: BasePart } } = {}
	local function consider(model: Model)
		if not model or model == exclude then
			return
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			if (root.Position - origin).Magnitude <= radius then
				table.insert(out, { Model = model, Humanoid = humanoid, Root = root })
			end
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			consider(player.Character)
		end
	end
	local npcFolder = workspace:FindFirstChild("NPCs")
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") then
				consider(child)
			end
		end
	end
	return out
end

local function applyVelocity(root: BasePart, velocity: Vector3, lifetime: number)
	local bv = Instance.new("BodyVelocity")
	bv.Name = "AbilityVelocity"
	bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bv.Velocity = velocity
	bv.Parent = root
	Debris:AddItem(bv, lifetime)
end

local function applyEffect(player: Player, powerId: string): boolean
	local character = player.Character
	local humanoid = getHumanoid(player)
	local root = getRoot(player)
	if not character or not humanoid or humanoid.Health <= 0 or not root then
		return false
	end
	-- Every number below comes from the shared playable def; nothing is
	-- hardcoded here (v1.0.1 QA: the old code used SPEC numbers that
	-- disagreed with the shared defs, e.g. chaos_burst dealt 10 damage
	-- in 12 studs while its def says 50 in 8, and freeze_blast dealt
	-- no damage at all while its def says 15).
	local def = getPlayableDef(powerId)
	if not def then
		return false
	end
	local duration = tonumber(def.Duration) or 0
	local damage = getEffectiveDamage(player, powerId, tonumber(def.Damage) or 0)
	local range = tonumber(def.Range) or 0
	local radius = tonumber(def.Radius) or 0

	if powerId == "dash" then
		-- Velocity burst in the facing direction.
		local dir = root.CFrame.LookVector
		applyVelocity(root, Vector3.new(dir.X, 0, dir.Z).Unit * 60 + Vector3.new(0, 4, 0), 0.25)
	elseif powerId == "energy_shield" then
		-- ForceField: real damage immunity for the def duration (5s).
		local existing = character:FindFirstChildOfClass("ForceField")
		if existing then
			existing:Destroy()
		end
		local ff = Instance.new("ForceField")
		ff.Parent = character
		Debris:AddItem(ff, duration > 0 and duration or 5)
	elseif powerId == "magnet_pull" then
		-- Pull loose drop models (workspace.Drops, or any model flagged
		-- with a "LooseDrop" attribute) within the def range toward the player.
		local pulled = 0
		local function consider(model: Model)
			if pulled >= 6 then
				return
			end
			local part = model.PrimaryPart or model:FindFirstChildOfClass("BasePart")
			if not part then
				return
			end
			if (part.Position - root.Position).Magnitude > range then
				return
			end
			pulled += 1
			local target = root.Position + Vector3.new(0, 2, 0)
			task.spawn(function()
				for step = 1, 10 do
					if not model.Parent then
						return
					end
					local current = model:GetPivot().Position
					model:PivotTo(CFrame.new(current:Lerp(target, 0.25)))
					task.wait(0.05)
				end
			end)
		end
		local drops = workspace:FindFirstChild("Drops")
		if drops then
			for _, child in ipairs(drops:GetChildren()) do
				if child:IsA("Model") then
					consider(child)
				end
			end
		end
		for _, child in ipairs(workspace:GetChildren()) do
			if child:IsA("Model") and child:GetAttribute("LooseDrop") == true then
				consider(child)
			end
		end
	elseif powerId == "teleport" then
		-- Blink up to the def range forward; the destination must have
		-- ground within 10 studs below it (raycast), otherwise the blink fails.
		local dir = root.CFrame.LookVector
		dir = Vector3.new(dir.X, 0, dir.Z)
		if dir.Magnitude < 0.01 then
			dir = Vector3.new(0, 0, 1)
		end
		local dest = root.Position + dir.Unit * range
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(dest + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
		if not hit then
			return false
		end
		root.CFrame = CFrame.new(dest.X, hit.Position.Y + 3, dest.Z)
	elseif powerId == "gravity_shift" then
		-- Counteract half of gravity + boosted jump for the def duration.
		local mass = 0
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				mass += part:GetMass()
			end
		end
		local force = Instance.new("BodyForce")
		force.Name = "GravityShift"
		force.Force = Vector3.new(0, mass * workspace.Gravity * 0.5, 0)
		force.Parent = root
		Debris:AddItem(force, duration > 0 and duration or 6)
		local oldJump = humanoid.JumpPower
		humanoid.JumpPower = oldJump * 1.5
		task.delay(duration > 0 and duration or 6, function()
			if humanoid.Parent then
				humanoid.JumpPower = oldJump
			end
		end)
	elseif powerId == "freeze_blast" then
		-- Damage (def Damage) + freeze nearby Humanoids in the def
		-- radius for the def duration. v1.0.0 froze within 10 studs and
		-- dealt no damage at all.
		for _, target in ipairs(findDamageable(root.Position, radius > 0 and radius or 5, character)) do
			local targetHumanoid = target.Humanoid
			if damage > 0 then
				pcall(function()
					targetHumanoid:TakeDamage(damage)
				end)
			end
			local oldSpeed = targetHumanoid.WalkSpeed
			targetHumanoid.WalkSpeed = 0
			target.Model:SetAttribute("Frozen", true)
			task.delay(duration > 0 and duration or 3, function()
				if targetHumanoid.Parent then
					target.Model:SetAttribute("Frozen", false)
					targetHumanoid.WalkSpeed = oldSpeed
				end
			end)
		end
	elseif powerId == "shadow_walk" then
		-- Near-invisible + faster for the def duration. Original transparencies restored.
		local originals: { [BasePart]: number } = {}
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				originals[part] = part.Transparency
				part.Transparency = 0.7
			end
		end
		local oldSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = oldSpeed * 1.25
		task.delay(duration > 0 and duration or 4, function()
			for part, transparency in pairs(originals) do
				if part.Parent then
					part.Transparency = transparency
				end
			end
			if humanoid.Parent then
				humanoid.WalkSpeed = oldSpeed
			end
		end)
	elseif powerId == "clone_decoy" then
		-- A script-stripped clone of the character that stands for the def duration.
		pcall(function()
			character.Archivable = true
			local clone = character:Clone()
			character.Archivable = false
			for _, descendant in ipairs(clone:GetDescendants()) do
				if descendant:IsA("Script") or descendant:IsA("LocalScript") then
					descendant:Destroy()
				end
			end
			local cloneHumanoid = clone:FindFirstChildOfClass("Humanoid")
			if cloneHumanoid then
				cloneHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			end
			clone.Name = "Decoy_" .. player.Name
			clone:PivotTo(root.CFrame * CFrame.new(3, 0, 0))
			clone.Parent = workspace
			Debris:AddItem(clone, duration > 0 and duration or 8)
		end)
	elseif powerId == "tide_surfer" then
		-- Ride the tide for the def duration: speed boost that ignores
		-- carry slowdown (WalkSpeed is set absolutely, not multiplied
		-- off the slowed value) + tide damage immunity for the window.
		-- v1.0.0 granted immunity only, with a 60s window from a table
		-- that disagreed with the shared def (5s); the shared def now
		-- says Duration 30 / Cooldown 60, and both effects run here.
		local window = duration > 0 and duration or 30
		if _tideService and type(_tideService.GrantSurfer) == "function" then
			pcall(function()
				_tideService.GrantSurfer(player, window)
			end)
		end
		_surfers[player] = os.clock() + window
		if character then
			character:SetAttribute("TideSurferUntil", os.clock() + window)
		end
		local oldSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = math.max(oldSpeed * 1.5, (tonumber(Config.BaseWalkSpeed) or 16) * 1.5)
		task.delay(window, function()
			if humanoid.Parent then
				humanoid.WalkSpeed = oldSpeed
			end
		end)
	elseif powerId == "rift_hook" then
		-- Grapple: raycast forward up to the def range; pull toward the hit.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		local dir = root.CFrame.LookVector
		local hit = workspace:Raycast(root.Position, dir * range, params)
		local anchor: Vector3
		if hit then
			anchor = hit.Position
		else
			anchor = root.Position + dir * math.min(range, 15)
		end
		local toAnchor = anchor - root.Position
		if toAnchor.Magnitude > 1 then
			applyVelocity(root, toAnchor.Unit * 55, 0.4)
		end
	elseif powerId == "chaos_burst" then
		-- Radial knockback + def damage within the def radius (not self).
		-- v1.0.0 dealt a hardcoded 10 damage in 12 studs; the shared
		-- def says 50 damage in 8 studs.
		for _, target in ipairs(findDamageable(root.Position, radius > 0 and radius or 8, character)) do
			if damage > 0 then
				pcall(function()
					target.Humanoid:TakeDamage(damage)
				end)
			end
			local away = target.Root.Position - root.Position
			away = Vector3.new(away.X, 0, away.Z)
			if away.Magnitude < 0.01 then
				away = Vector3.new(0, 0, 1)
			end
			applyVelocity(target.Root, away.Unit * 40 + Vector3.new(0, 8, 0), 0.25)
		end
	elseif powerId == "time_rewind" then
		-- Restore the oldest snapshot (~3s ago): position + health.
		-- Cannot rewind death (caller already checks Health > 0) and
		-- fails cleanly when no snapshot exists yet (first 0.5s).
		local snaps = _snapshots[player]
		if snaps == nil or #snaps == 0 then
			return false
		end
		local snap = snaps[1]
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(snap.Position + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
		if hit then
			root.CFrame = CFrame.new(snap.Position.X, hit.Position.Y + 3, snap.Position.Z)
		else
			root.CFrame = CFrame.new(snap.Position)
		end
		humanoid.Health = math.min(humanoid.MaxHealth, math.max(1, snap.Health))
	elseif powerId == "meteor_shower" then
		-- 5 pastry meteors over the def duration, one per interval,
		-- each landing at a random point within the def radius and
		-- dealing 1/5 of the def damage to enemies within 3 studs.
		local meteors = 5
		local perMeteor = math.max(1, math.floor(damage / meteors + 0.5))
		local interval = (duration > 0 and duration or 3) / meteors
		local origin = root.Position
		task.spawn(function()
			for _ = 1, meteors do
				local angle = math.random() * math.pi * 2
				local dist = math.random() * (radius > 0 and radius or 10)
				local impact = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
				for _, target in ipairs(findDamageable(impact, 3, character)) do
					pcall(function()
						target.Humanoid:TakeDamage(perMeteor)
					end)
					local away = target.Root.Position - impact
					away = Vector3.new(away.X, 0, away.Z)
					if away.Magnitude < 0.01 then
						away = Vector3.new(0, 0, 1)
					end
					applyVelocity(target.Root, away.Unit * 25 + Vector3.new(0, 6, 0), 0.2)
				end
				fireAll(_names.SpawnEffect, {
					type = "Power",
					powerId = powerId,
					player = player.Name,
					position = impact,
				})
				task.wait(interval)
			end
		end)
	elseif powerId == "void_dash" then
		-- Blink forward up to the def range, briefly untouchable
		-- (transparency 0.7 for the duration), slicing enemies within
		-- the def radius of the path.
		local dir = root.CFrame.LookVector
		dir = Vector3.new(dir.X, 0, dir.Z)
		if dir.Magnitude < 0.01 then
			dir = Vector3.new(0, 0, 1)
		end
		local mid = root.Position + dir.Unit * (range * 0.5)
		for _, target in ipairs(findDamageable(mid, radius > 0 and radius or 3, character)) do
			if damage > 0 then
				pcall(function()
					target.Humanoid:TakeDamage(damage)
				end)
			end
		end
		local dest = root.Position + dir.Unit * range
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(dest + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
		if hit then
			root.CFrame = CFrame.new(dest.X, hit.Position.Y + 3, dest.Z)
		else
			return false
		end
		local originals: { [BasePart]: number } = {}
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				originals[part] = part.Transparency
				part.Transparency = 0.7
			end
		end
		task.delay(duration > 0 and duration or 0.5, function()
			for part, transparency in pairs(originals) do
				if part.Parent then
					part.Transparency = transparency
				end
			end
		end)
	elseif powerId == "gravity_crush" then
		-- Crush everything in the def radius: def damage, dragged
		-- toward the player, rooted (WalkSpeed 0) for the def duration.
		for _, target in ipairs(findDamageable(root.Position, radius > 0 and radius or 7, character)) do
			if damage > 0 then
				pcall(function()
					target.Humanoid:TakeDamage(damage)
				end)
			end
			local toward = root.Position - target.Root.Position
			toward = Vector3.new(toward.X, 0, toward.Z)
			if toward.Magnitude > 0.01 then
				applyVelocity(target.Root, toward.Unit * 30, 0.3)
			end
			local targetHumanoid = target.Humanoid
			local oldSpeed = targetHumanoid.WalkSpeed
			targetHumanoid.WalkSpeed = 0
			task.delay(duration > 0 and duration or 2, function()
				if targetHumanoid.Parent then
					targetHumanoid.WalkSpeed = oldSpeed
				end
			end)
		end
	elseif powerId == "dimensional_prison" then
		-- Cage the NEAREST enemy within the def range for the def
		-- duration: no movement, no jump, inside a neon cage that
		-- vanishes when the prison ends. Small def damage on capture.
		local best: any = nil
		local bestDist = (range > 0 and range or 12) + 1
		for _, target in ipairs(findDamageable(root.Position, range > 0 and range or 12, character)) do
			local d = (target.Root.Position - root.Position).Magnitude
			if d < bestDist then
				best = target
				bestDist = d
			end
		end
		if best == nil then
			return false
		end
		if damage > 0 then
			pcall(function()
				best.Humanoid:TakeDamage(damage)
			end)
		end
		local targetHumanoid = best.Humanoid
		local oldSpeed = targetHumanoid.WalkSpeed
		local oldJump = targetHumanoid.JumpPower
		targetHumanoid.WalkSpeed = 0
		targetHumanoid.JumpPower = 0
		local cage = Instance.new("Model")
		cage.Name = "DimensionalPrison"
		local cageParts: { BasePart } = {}
		for i = 1, 4 do
			local angle = (i - 1) * math.pi / 2
			local wall = Instance.new("Part")
			wall.Name = "PrisonWall"
			wall.Size = Vector3.new(0.3, 5, 3)
			wall.Color = Color3.fromRGB(80, 200, 255)
			wall.Material = Enum.Material.Neon
			wall.Transparency = 0.4
			wall.Anchored = true
			wall.CanCollide = false
			wall.CFrame = CFrame.new(best.Root.Position + Vector3.new(math.cos(angle) * 1.6, 2.5, math.sin(angle) * 1.6)) * CFrame.Angles(0, -angle, 0)
			wall.Parent = cage
			table.insert(cageParts, wall)
		end
		cage.Parent = workspace
		Debris:AddItem(cage, duration > 0 and duration or 5)
		task.delay(duration > 0 and duration or 5, function()
			if targetHumanoid.Parent then
				targetHumanoid.WalkSpeed = oldSpeed
				targetHumanoid.JumpPower = oldJump
			end
		end)
	elseif powerId == "time_distortion" then
		-- Slow nearby enemies to 50% WalkSpeed for the def duration,
		-- within the def radius. v1.0.0 used a hardcoded 12 studs / 5s.
		for _, target in ipairs(findDamageable(root.Position, radius > 0 and radius or 10, character)) do
			local targetHumanoid = target.Humanoid
			local oldSpeed = targetHumanoid.WalkSpeed
			targetHumanoid.WalkSpeed = oldSpeed * 0.5
			task.delay(duration > 0 and duration or 4, function()
				if targetHumanoid.Parent then
					targetHumanoid.WalkSpeed = oldSpeed
				end
			end)
		end
	else
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- UsePower(player, powerId): returns (true) or (false, reason).
function AbilityService.UsePower(player: Player, powerId: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(powerId)
	if not clean or getPlayableDef(clean) == nil then
		return false, "unknown power"
	end
	local data = ensureLoadoutData(player)
	if not data then
		return false, "no data"
	end
	if not isUnlocked(data, clean) then
		return false, "power not unlocked"
	end
	if not isEquipped(data, clean) then
		return false, "power not in loadout"
	end
	local humanoid = getHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return false, "not alive"
	end
	local now = os.clock()
	_cooldowns[player] = _cooldowns[player] or {}
	local lastUsed = _cooldowns[player][clean] or 0
	local cooldown = getEffectiveCooldown(player, clean)
	if now - lastUsed < cooldown then
		return false, "on cooldown"
	end
	local applied = applyEffect(player, clean)
	if not applied then
		return false, "effect failed"
	end
	_cooldowns[player][clean] = now
	awardMasteryXP(player, clean)
	-- FX for all clients, plus the cooldown state to the using player
	-- on PowerUpdate (the client AbilityController listens for it and
	-- corrects its local cooldown display from this).
	local root = getRoot(player)
	fireAll(_names.SpawnEffect, {
		type = "Power",
		powerId = clean,
		player = player.Name,
		position = root and root.Position or Vector3.new(0, 0, 0),
	})
	-- v1.1 visual pass: a positional ring + flash in the power's colour
	-- (the positional form EffectsController handles), sized by the
	-- power's radius. Damage powers get the full ring+flash; utility
	-- powers get a smaller ring + poof.
	local def = getPlayableDef(clean)
	if root ~= nil and def ~= nil then
		local color = def.Color or Color3.fromRGB(120, 200, 255)
		local radius = tonumber(def.Radius) or 0
		local damage = tonumber(def.Damage) or 0
		local spawnRemote = getRemote("SpawnEffect")
		if spawnRemote ~= nil then
			local ringRadius = radius > 0 and radius or 5
			pcall(function()
				(spawnRemote :: RemoteEvent):FireAllClients("ring", root.Position, { radius = ringRadius, color = color })
				if damage > 0 then
					(spawnRemote :: RemoteEvent):FireAllClients("flash", root.Position, color)
				else
					(spawnRemote :: RemoteEvent):FireAllClients("poof", root.Position, nil)
				end
			end)
		end
	end
	fireClient(_names.PowerUpdate, player, {
		PowerId = clean,
		Cooldown = cooldown,
		Remaining = cooldown,
	})
	return true, nil
end

-- UnlockPower(player, powerId, costCoins): powers are bought with
-- COINS (shared Powers.PlayablePowers Cost). The shared cost is
-- authoritative — a caller-supplied cost that disagrees with it is
-- ignored, never trusted. Returns (true) or (false, reason).
function AbilityService.UnlockPower(player: Player, powerId: any, costCoins: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	local clean = sanitize(powerId)
	local def = clean and getPlayableDef(clean) or nil
	if not clean or not def then
		return false, "unknown power"
	end
	local data = ensureLoadoutData(player)
	if not data then
		return false, "no data"
	end
	if isUnlocked(data, clean) then
		return false, "already unlocked"
	end
	-- Server-side (shared) cost wins over any caller-supplied value.
	-- v1.0.0 charged Gems from its own table; the shared def charges
	-- Coins, and Coins is what is deducted here.
	local cost = tonumber(def.Cost) or 0
	if spendableCoins(player, data) < cost then
		return false, "not enough coins"
	end
	_dataService.AddCoins(player, -cost)
	table.insert(data.UnlockedPowers, clean)
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Gems = data.Gems,
		UnlockedPowers = data.UnlockedPowers,
		AbilityLoadout = data.AbilityLoadout,
	})
	return true, nil
end

-- GetLoadout(player): copy of the equipped 3-power loadout.
function AbilityService.GetLoadout(player: Player): { string }
	local data = ensureLoadoutData(player)
	if not data then
		return { DEFAULT_LOADOUT[1], DEFAULT_LOADOUT[2], DEFAULT_LOADOUT[3] }
	end
	local copy: { string } = {}
	for _, id in ipairs(data.AbilityLoadout) do
		table.insert(copy, id)
	end
	return copy
end

-- SetLoadout(player, loadout): replace the 3-power loadout. Every id
-- must be unlocked. Pushes the new loadout to the client on PlayerStats
-- (AbilityLoadout) so the AbilityController's 1/2/3 loadout bar can
-- rebuild. (No dedicated Loadout remote exists yet — call from
-- GameManager or a future remote.)
function AbilityService.SetLoadout(player: Player, loadout: any): (boolean, string?)
	if not player or not player:IsA("Player") then
		return false, "invalid player"
	end
	if type(loadout) ~= "table" or #loadout ~= 3 then
		return false, "loadout must have exactly 3 powers"
	end
	local data = ensureLoadoutData(player)
	if not data then
		return false, "no data"
	end
	local seen: { [string]: boolean } = {}
	for _, id in ipairs(loadout) do
		local clean = sanitize(id)
		if not clean or getPlayableDef(clean) == nil then
			return false, "unknown power: " .. tostring(id)
		end
		if seen[clean] then
			return false, "duplicate power in loadout"
		end
		seen[clean] = true
		if not isUnlocked(data, clean) then
			return false, "power not unlocked: " .. clean
		end
	end
	data.AbilityLoadout = { loadout[1], loadout[2], loadout[3] }
	task.spawn(function()
		pcall(function()
			_dataService.SaveData(player)
		end)
	end)
	AbilityService.PushLoadout(player)
	return true, nil
end

-- PushLoadout(player): send the player's current loadout to their
-- client (PlayerStats payload, AbilityLoadout field). GameManager calls
-- this on join so the loadout bar exists before the first fight.
function AbilityService.PushLoadout(player: Player)
	local data = ensureLoadoutData(player)
	if not data then
		return
	end
	fireClient(_names.PlayerStats, player, {
		Coins = data.Coins,
		XP = data.XP,
		Level = data.Level,
		Gems = data.Gems,
		UnlockedPowers = data.UnlockedPowers,
		AbilityLoadout = AbilityService.GetLoadout(player),
	})
end

-- GetMasteryXP(player, powerId): mastery XP the player has earned
-- for one power (0 when unknown). GetMasteryLevel(player, powerId)
-- returns the 0-5 level from Powers.GetMasteryLevel.
function AbilityService.GetMasteryXP(player: Player, powerId: string): number
	local clean = sanitize(powerId)
	if not clean then
		return 0
	end
	return getMasteryXP(player, clean)
end

function AbilityService.GetMasteryLevel(player: Player, powerId: string): number
	local clean = sanitize(powerId)
	if not clean then
		return 0
	end
	return getMasteryLevel(player, clean)
end

-- GetMasteryStateForSave(player) / LoadMasteryState(player, data):
-- mastery persistence. The XP table is mirrored into
-- data.PowerMastery on every use, so a normal DataService save
-- already persists it; these two functions are the explicit
-- snapshot/restore pair for the audit trail and for services that
-- want to carry mastery across a data reload.
function AbilityService.GetMasteryStateForSave(player: Player): { [string]: number }
	local copy: { [string]: number } = {}
	local perPlayer = _masteryXP[player]
	if perPlayer ~= nil then
		for id, xp in pairs(perPlayer) do
			copy[id] = xp
		end
	else
		local data = getData(player)
		if data ~= nil and type(data.PowerMastery) == "table" then
			for id, xp in pairs(data.PowerMastery) do
				if type(id) == "string" and type(xp) == "number" then
					copy[id] = xp
				end
			end
		end
	end
	return copy
end

function AbilityService.LoadMasteryState(player: Player, data: any): boolean
	if not player or not player:IsA("Player") then
		return false
	end
	if type(data) ~= "table" then
		return false
	end
	local source = data.PowerMastery or data
	if type(source) ~= "table" then
		return false
	end
	_masteryXP[player] = _masteryXP[player] or {}
	for id, xp in pairs(source) do
		if type(id) == "string" and type(xp) == "number" and getPlayableDef(id) ~= nil then
			_masteryXP[player][id] = math.max(0, math.floor(xp))
		end
	end
	return true
end

-- SetTideService(tideService): setter injection (GameManager's
-- tryWire does not call this today; call it from the parent when the
-- TideService is available so tide_surfer grants real immunity there).
function AbilityService.SetTideService(tideService: any)
	if tideService and type(tideService.GrantSurfer) == "function" then
		_tideService = tideService
	end
end

-- IsTideSurfer(player): TideService queries this through its callbacks.
function AbilityService.IsTideSurfer(player: Player): boolean
	local untilTime = _surfers[player]
	return untilTime ~= nil and os.clock() < untilTime
end

function AbilityService.GetCooldownRemaining(player: Player, powerId: string): number
	local clean = sanitize(powerId)
	if not clean then
		return 0
	end
	local perPlayer = _cooldowns[player]
	if not perPlayer then
		return 0
	end
	local lastUsed = perPlayer[clean] or 0
	return math.max(0, getEffectiveCooldown(player, clean) - (os.clock() - lastUsed))
end

local function onUseAbility(player: Player, powerId: any)
	if not player or not player:IsA("Player") then
		return
	end
	-- CombatService also listens on UseAbility but ignores loadout ids
	-- (it only acts on the character primary and the generic
	-- slam/heal), so only one handler acts per id.
	if type(powerId) ~= "string" then
		return
	end
	if getPlayableDef(powerId) == nil then
		return
	end
	if not rateOk(player, "UsePower", 0.25) then
		return
	end
	local ok, err = AbilityService.UsePower(player, powerId)
	if not ok then
		-- Silent for cooldown spam; warn for real validation failures.
		if err ~= "on cooldown" then
			warn("[AbilityService] UsePower failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
end

function AbilityService.Init(dataService: any, tideService: any?)
	assert(dataService ~= nil, "[AbilityService] Init requires DataService")
	_dataService = dataService
	-- GameManager's generic Init passes EconomyService positionally as
	-- the 2nd argument; only accept a real TideService (GrantSurfer).
	if tideService and type(tideService.GrantSurfer) == "function" then
		_tideService = tideService
	else
		_tideService = nil
	end

	Players.PlayerRemoving:Connect(function(player)
		_cooldowns[player] = nil
		_lastUse[player] = nil
		_surfers[player] = nil
		_masteryXP[player] = nil
		_snapshots[player] = nil
	end)

	-- Time Rewind snapshot loop (v1.1): every 0.5s, record each live
	-- player's root position + health. Ring buffer of 7 entries, so
	-- the oldest snapshot is ~3s old — exactly what time_rewind
	-- restores. Cheap (one table insert per player per 0.5s) and
	-- stops recording dead / absent characters.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, player in ipairs(Players:GetPlayers()) do
				local humanoid = getHumanoid(player)
				local root = getRoot(player)
				if humanoid ~= nil and humanoid.Health > 0 and root ~= nil then
					_snapshots[player] = _snapshots[player] or {}
					table.insert(_snapshots[player], { Position = root.Position, Health = humanoid.Health })
					while #_snapshots[player] > 7 do
						table.remove(_snapshots[player], 1)
					end
				end
			end
		end
	end)

	task.spawn(function()
		local remote: RemoteEvent? = nil
		for _ = 1, 50 do
			remote = getRemote(_names.UseAbility)
			if remote then
				break
			end
			task.wait(0.2)
		end
		if remote then
			remote.OnServerEvent:Connect(onUseAbility)
		else
			warn("[AbilityService] UseAbility remote not found, powers not wired")
		end
	end)
end

return AbilityService
