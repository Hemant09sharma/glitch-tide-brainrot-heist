-- CombatService (server)
-- Server-authoritative melee + ability combat. The client only ever sends
-- *intent* ("I attacked", "I used ability X"). All damage, range, cooldown
-- and kill-reward numbers come from the server-side Characters / Powers /
-- Config tables. Client-supplied damage is never trusted.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Characters = require(ReplicatedStorage:WaitForChild("Characters"))
local Powers = require(ReplicatedStorage:WaitForChild("Powers"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local CombatService = {}

local DataService = nil
local EconomyService = nil
local GameManager = nil
-- NOTE (v1.0.1 QA): an old comment here claimed a CarryService hook
-- ("set via Init 4th arg or SetCarryService") would drop carried
-- Brainrots on death. No such setter exists and HandleDeath never
-- called it — but nothing is lost: CarryService owns death drops
-- itself (it connects Humanoid.Died in its own Init and drops what the
-- dead player carried), so combat does not need the hook.

-- Resolve one live RemoteEvent by name. v1.0.1 QA: the old getRemotes()
-- called Remotes.GetRemotes() (which does not exist on the Remotes
-- module) and fell back to indexing the module table itself, so
-- remotes["Attack"] / remotes["SpawnEffect"] / remotes["DamageNumber"]
-- were all nil — Init never connected Attack/UseAbility and no damage
-- number or swing effect ever fired. Combat was silently dead. Every
-- remote here now goes through Remotes.GetRemote(name).

--------------------------------------------------------------------------------
-- Tuning (server-side only)
--------------------------------------------------------------------------------
local ATTACK_COOLDOWN = Config.AttackCooldown or 0.45 -- seconds between melee swings per player
local ATTACK_RANGE = Config.AttackRange or 6 -- studs, attacker HumanoidRootPart -> target HumanoidRootPart (was hardcoded 8, Config says 6)
local ATTACK_ARC = 100 -- degrees; target must be roughly in front of attacker
local ABILITY_STUN_DURATION = 1.5

-- player -> os.clock() of last melee attack
local LastAttackAt = {}
-- player -> { [abilityId] = os.clock() of last use }
local AbilityCooldowns = {}
-- player -> current KO streak (reset on death)
local Streaks = {}
-- Humanoid -> true while a stun is active (prevents double-stun timers)
local Stunned = {}
-- Model -> true for NPCs currently counted as dead (prevents double rewards)
local DeathHandled = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function safeFireClient(remote, player, payload)
	if not remote then
		return
	end
	pcall(function()
		remote:FireClient(player, payload)
	end)
end

local function safeFireAllClients(remote, payload)
	if not remote then
		return
	end
	pcall(function()
		remote:FireAllClients(payload)
	end)
end

-- Fire a remote by name through the resolved remotes table.
local function fireClient(name, player, payload)
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote then
		safeFireClient(remote, player, payload)
	end
end

local function fireAllClients(name, payload)
	local ok, remote = pcall(function()
		return Remotes.GetRemote(name)
	end)
	if ok and remote then
		safeFireAllClients(remote, payload)
	end
end

local function getRoot(model)
	if not model then
		return nil
	end
	return model:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid(model)
	if not model then
		return nil
	end
	return model:FindFirstChildOfClass("Humanoid")
end

local function getPlayerCharacterId(player)
	local data
	if DataService then
		pcall(function()
			data = DataService.GetData(player)
		end)
	end
	if type(data) == "table" then
		if type(data.SelectedCharacter) == "string" and data.SelectedCharacter ~= "" then
			return data.SelectedCharacter
		end
		if type(data.Selected) == "string" and data.Selected ~= "" then
			return data.Selected
		end
	end
	-- Fallback: read the CharacterId tag stamped by CharacterService.
	local character = player.Character
	if character then
		local tag = character:FindFirstChild("CharacterId")
		if tag and tag:IsA("StringValue") and tag.Value ~= "" then
			return tag.Value
		end
	end
	return "wobble_waffleton"
end

local function getCharacterStats(player)
	local def = Characters.GetById(getPlayerCharacterId(player))
	if def then
		return def
	end
	return { Id = "wobble_waffleton", DisplayName = "Wobble Waffleton", Health = 100, Speed = 16, Damage = 10, AbilityId = "" }
end

-- True when `model` belongs to a player (and returns that player) or an NPC.
local function getOwnerPlayer(model)
	if not model then
		return nil
	end
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		return player
	end
	return nil
end

local function isNPC(model)
	if not model then
		return false
	end
	return model:FindFirstChild("IsNPC") ~= nil
end

local function getCreatorPlayer(model)
	if not model then
		return nil
	end
	local creator = model:FindFirstChild("Creator")
	if creator and creator:IsA("ObjectValue") and creator.Value then
		if creator.Value:IsA("Player") then
			return creator.Value
		end
	end
	return nil
end

local function isStunned(model)
	local humanoid = getHumanoid(model)
	if not humanoid then
		return false
	end
	return Stunned[humanoid] == true
end

local function applyStun(model, duration)
	local humanoid = getHumanoid(model)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if Stunned[humanoid] then
		return
	end
	Stunned[humanoid] = true
	local originalSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = 0
	-- Stun visual: brief yellow highlight via an attribute clients can read.
	model:SetAttribute("Stunned", true)
	task.delay(duration, function()
		Stunned[humanoid] = nil
		if humanoid.Parent then
			model:SetAttribute("Stunned", false)
			-- Restore speed from the character definition, not a stale value
			-- that may predate a morph.
			local owner = getOwnerPlayer(model)
			if owner then
				humanoid.WalkSpeed = getCharacterStats(owner).Speed or Config.BaseWalkSpeed or 16
			else
				humanoid.WalkSpeed = originalSpeed
			end
		end
	end)
end

local function applyKnockback(model, fromPosition, force)
	local root = getRoot(model)
	if not root then
		return
	end
	local direction = root.Position - fromPosition
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.01 then
		direction = Vector3.new(0, 0, 1)
	end
	direction = direction.Unit
	local bv = Instance.new("BodyVelocity")
	bv.Name = "CombatKnockback"
	bv.MaxForce = Vector3.new(math.huge, 0, math.huge)
	bv.Velocity = direction * force + Vector3.new(0, 6, 0)
	bv.Parent = root
	Debris:AddItem(bv, 0.25)
end

-- Find every damageable model (player character or NPC) within `radius` of
-- `origin`, excluding `excludeModel`. Returns { {model, humanoid, root, distance} }.
local function findTargetsInRadius(origin, radius, excludeModel)
	local results = {}
	local function consider(model)
		if not model or model == excludeModel then
			return
		end
		local humanoid = getHumanoid(model)
		local root = getRoot(model)
		if not humanoid or not root or humanoid.Health <= 0 then
			return
		end
		local dist = (root.Position - origin).Magnitude
		if dist <= radius then
			table.insert(results, { model = model, humanoid = humanoid, root = root, distance = dist })
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			consider(player.Character)
		end
	end
	-- NPCs live in workspace under a folder named "NPCs" (created by
	-- NPCService); also scan workspace children as a fallback.
	local npcFolder = workspace:FindFirstChild("NPCs")
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") then
				consider(child)
			end
		end
	end
	return results
end

--------------------------------------------------------------------------------
-- Damage / death
--------------------------------------------------------------------------------

-- DamagePlayer(target, amount, attacker)
-- `target` may be a Player, a Model (player character or NPC), or a Humanoid.
-- `attacker` may be a Player, a Model, or nil (environment / NPC).
-- Damage is always applied server-side; the attacker never supplies it.
-- Returns true when damage was applied.
function CombatService.DamagePlayer(target, amount, attacker)
	if type(amount) ~= "number" or amount <= 0 then
		return false
	end

	local model
	local targetPlayer
	if type(target) == "userdata" then
		if target:IsA("Player") then
			targetPlayer = target
			model = target.Character
		elseif target:IsA("Model") then
			model = target
			targetPlayer = getOwnerPlayer(model)
		elseif target:IsA("Humanoid") then
			model = target.Parent
			targetPlayer = getOwnerPlayer(model)
		end
	end
	if not model then
		return false
	end

	local humanoid = getHumanoid(model)
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local attackerPlayer
	if type(attacker) == "userdata" then
		if attacker:IsA("Player") then
			attackerPlayer = attacker
		elseif attacker:IsA("Model") then
			attackerPlayer = getOwnerPlayer(attacker) or getCreatorPlayer(attacker)
		elseif attacker:IsA("Humanoid") then
			attackerPlayer = getOwnerPlayer(attacker.Parent)
		end
	end

	-- Friendly-fire guard: never damage your own character.
	if attackerPlayer and targetPlayer and attackerPlayer == targetPlayer then
		return false
	end

	-- Record the killer for kill credit (Roblox convention: Creator tag).
	if attackerPlayer then
		local creator = model:FindFirstChild("Creator")
		if not creator then
			creator = Instance.new("ObjectValue")
			creator.Name = "Creator"
			creator.Parent = model
		end
		if creator:IsA("ObjectValue") then
			creator.Value = attackerPlayer
		end
	end

	amount = math.floor(amount)
	humanoid:TakeDamage(amount)

	-- Floating damage number for the attacker (and the victim, if a player).
	local root = getRoot(model)
	local payload = {
		target = root and root.Position or model:GetPivot().Position,
		amount = amount,
		isCrit = false,
	}
	if attackerPlayer then
		fireClient("DamageNumber", attackerPlayer, payload)
	end
	if targetPlayer and targetPlayer ~= attackerPlayer then
		fireClient("DamageNumber", targetPlayer, payload)
	end

	if humanoid.Health <= 0 then
		CombatService.HandleDeath(model, attackerPlayer)
	end
	return true
end

-- HandleDeath(model, killerPlayer): KO bookkeeping, rewards, respawn/despawn.
function CombatService.HandleDeath(model, killerPlayer)
	if not model then
		return
	end
	if DeathHandled[model] then
		return
	end
	DeathHandled[model] = true
	-- Allow the entry to be garbage-collected once the model is gone.
	task.delay(5, function()
		DeathHandled[model] = nil
	end)

	local victimPlayer = getOwnerPlayer(model)
	local wasNPC = isNPC(model)

	if victimPlayer then
		-- Victim's streak resets on death.
		Streaks[victimPlayer] = 0
	end

	if killerPlayer and victimPlayer and killerPlayer ~= victimPlayer then
		-- Player-vs-player KO only. NPC kills are rewarded by
		-- NPCService.HandleNPCDeath (25 coins + 20 XP); calling
		-- AwardKO here too double-paid every NPC kill in v1.0.0, and
		-- NPC kills also inflated the killer's streak.
		Streaks[killerPlayer] = (Streaks[killerPlayer] or 0) + 1

		-- KO rewards via EconomyService (guarded: never crash combat).
		if EconomyService and EconomyService.AwardKO then
			pcall(function()
				EconomyService.AwardKO(killerPlayer, Streaks[killerPlayer])
			end)
		end
		-- Fallback direct rewards if EconomyService is absent.
		if not EconomyService and DataService then
			pcall(function()
				if DataService.AddCoins then
					DataService.AddCoins(killerPlayer, Config.CoinPerKO or 25)
				end
				if DataService.AddXP then
					DataService.AddXP(killerPlayer, Config.XPPerKO or 20)
				end
			end)
		end

		-- Notify the game manager (scoreboard / round state).
		if GameManager and GameManager.RegisterKO then
			pcall(function()
				GameManager.RegisterKO(killerPlayer, victimPlayer)
			end)
		end

		-- Tell everyone about the KO (kill feed / effects).
		fireAllClients("SpawnEffect", {
			type = "KO",
			killer = killerPlayer.Name,
			victim = victimPlayer and victimPlayer.Name or model.Name,
			streak = Streaks[killerPlayer],
			position = model:GetPivot().Position,
		})
	end

	if victimPlayer then
		-- Respawn the player after Config.RespawnTime. loadCharacter() is the
		-- standard respawn path; CharacterService re-applies the morph on
		-- CharacterAdded.
		task.delay(Config.RespawnTime or 3, function()
			if victimPlayer.Parent then
				pcall(function()
					victimPlayer:LoadCharacter()
				end)
			end
		end)
	elseif wasNPC then
		-- NPC death: the NPCService owns despawn + its coin reward to the
		-- killer (via the Creator tag). Just make sure the corpse does not
		-- linger; NPCService listens to Humanoid.Died as well.
		task.delay(1.5, function()
			if model.Parent then
				-- Leave the model for NPCService cleanup; only break joints
				-- so it ragdolls/falls instead of standing frozen.
				pcall(function()
					model:BreakJoints()
				end)
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- Melee attack (Attack remote)
--------------------------------------------------------------------------------

local function onAttack(player, _payload)
	if not player or not player:IsA("Player") then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local humanoid = getHumanoid(character)
	local root = getRoot(character)
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	if isStunned(character) then
		return
	end

	-- Rate limit: max 1 attack per 0.45s.
	local now = os.clock()
	if LastAttackAt[player] and now - LastAttackAt[player] < ATTACK_COOLDOWN then
		return
	end
	LastAttackAt[player] = now

	local stats = getCharacterStats(player)
	local damage = stats.Damage or 10

	-- Targets: nearest damageable model within range AND roughly in front.
	-- A short raycast from the attacker toward each candidate confirms line
	-- of sight (walls block the swing); magnitude is the primary check.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local best = nil
	local bestDist = ATTACK_RANGE + 1
	local candidates = findTargetsInRadius(root.Position, ATTACK_RANGE, character)
	for _, candidate in ipairs(candidates) do
		if candidate.distance < bestDist then
			-- Facing check: angle between look direction and direction to target.
			local toTarget = (candidate.root.Position - root.Position)
			toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
			if toTarget.Magnitude > 0.01 then
				local forward = root.CFrame.LookVector
				forward = Vector3.new(forward.X, 0, forward.Z).Unit
				local dot = forward:Dot(toTarget.Unit)
				local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))
				if angle <= ATTACK_ARC then
					-- Line of sight: raycast toward the target; a hit on
					-- anything that is not the target model blocks the swing.
					local direction = candidate.root.Position - root.Position
					local result = workspace:Raycast(root.Position, direction, rayParams)
					local blocked = false
					if result and result.Instance then
						local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
						if hitModel ~= candidate.model then
							blocked = true
						end
					end
					if not blocked then
						best = candidate
						bestDist = candidate.distance
					end
				end
			end
		end
	end

	-- Swing effect for everyone nearby (clients animate from this).
	fireAllClients("SpawnEffect", {
		type = "Swing",
		player = player.Name,
		position = root.Position,
	})

	if best then
		CombatService.DamagePlayer(best.model, damage, player)
	end
end

--------------------------------------------------------------------------------
-- Abilities (UseAbility remote)
--------------------------------------------------------------------------------

-- Which Effect strings knock the target back / slow it / stun it.
-- v1.0.1 QA: the old code only recognised the literal effects
-- "knockback" and "stun", which NO power in Powers.luau uses — every
-- primary's real Effect string (GroundSlam, Splash, Shock, ...) fell
-- through, so primaries dealt damage and nothing else: no knockback on
-- Waffle Wobble, no slow on Jelly Splash, no stun on Zap Bolt.
local KNOCKBACK_EFFECTS: { [string]: boolean } = {
	GroundSlam = true, RoyalSlam = true, SpringSlam = true, Bounce = true,
	Roll = true, Explosion = true, Blast = true, Whip = true,
	RingBlast = true, ClawSlash = true, Beam = true,
}
local SLOW_EFFECTS: { [string]: boolean } = {
	Splash = true, Haunt = true,
}
local STUN_EFFECTS: { [string]: boolean } = {
	Shock = true, Dazzle = true,
}

local function applySlow(model, duration)
	local humanoid = getHumanoid(model)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local oldSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = oldSpeed * 0.5
	task.delay(duration, function()
		if humanoid.Parent then
			humanoid.WalkSpeed = oldSpeed
		end
	end)
end

-- Generic slot abilities any player may use (slam / heal). Derived from
-- Config.GenericAbilities minus anything in the loadout pool, so Dash
-- (a loadout power owned by AbilityService) is never double-applied
-- here. v1.0.0: CombatService only accepted the character primary and
-- AbilityService only accepted loadout ids, so F (Slam) and R (Heal)
-- were accepted by NOBODY — the buttons did nothing server-side.
local function isGenericCombatAbility(abilityId: string): boolean
	if abilityId == "dash" then
		return false
	end
	local generics = Config.GenericAbilities
	if type(generics) ~= "table" then
		return abilityId == "slam" or abilityId == "heal"
	end
	for _, id in pairs(generics) do
		if id == abilityId then
			return true
		end
	end
	return false
end

local function onUseAbility(player, abilityId)
	if not player or not player:IsA("Player") then
		return
	end
	if type(abilityId) ~= "string" or abilityId == "" then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local humanoid = getHumanoid(character)
	local root = getRoot(character)
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	if isStunned(character) then
		return
	end

	-- The ability must be the player's character primary, or a generic
	-- slot ability (slam / heal). Clients cannot fire arbitrary abilities.
	local stats = getCharacterStats(player)
	local isPrimary = stats.AbilityId == abilityId
	local isGeneric = isGenericCombatAbility(abilityId)
	if not isPrimary and not isGeneric then
		return
	end

	local power = Powers.GetById(abilityId)
	if not power then
		return
	end

	-- Per-player cooldown table.
	local cooldown = power.Cooldown or 5
	local now = os.clock()
	AbilityCooldowns[player] = AbilityCooldowns[player] or {}
	local lastUsed = AbilityCooldowns[player][abilityId] or 0
	if now - lastUsed < cooldown then
		return
	end
	AbilityCooldowns[player][abilityId] = now

	local effect = power.Effect or ""
	local damage = power.Damage or 0
	local range = power.Range or 10
	local radius = power.Radius or 0

	fireAllClients("SpawnEffect", {
		type = "Ability",
		abilityId = abilityId,
		player = player.Name,
		position = root.Position,
	})

	-- Heal (generic R, and any future Heal primary): restore
	-- |Damage| HP, clamped to MaxHealth. v1.0.0 checked effect ==
	-- "heal" (lowercase; the def says "Heal") AND added the negative
	-- Damage (-25) to health, which would have DAMAGED the user — and
	-- the branch was unreachable anyway (heal is not a primary).
	if effect == "Heal" or effect == "heal" then
		local healAmount = math.abs(damage)
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + healAmount)
		fireClient("DamageNumber", player, {
			target = root.Position,
			amount = healAmount,
			isHeal = true,
		})
		return
	end

	-- SpeedBoost (Turbo Boost): a real speed burst for 3s, plus the
	-- def damage in a small radius. v1.0.0 dealt the damage and never
	-- boosted speed at all.
	if effect == "SpeedBoost" then
		local oldSpeed = humanoid.WalkSpeed
		humanoid.WalkSpeed = oldSpeed * 1.5
		task.delay(3, function()
			if humanoid.Parent then
				humanoid.WalkSpeed = oldSpeed
			end
		end)
	end

	-- GlitchTeleport (Glitchy Goose): flicker behind the nearest target
	-- in range, then hit in the def radius. v1.0.0 never moved the
	-- player — the teleport was data-only.
	if effect == "GlitchTeleport" then
		local best: any = nil
		local bestDist = range + 1
		for _, candidate in ipairs(findTargetsInRadius(root.Position, range, character)) do
			if candidate.distance < bestDist then
				best = candidate
				bestDist = candidate.distance
			end
		end
		if best then
			local targetRoot = best.root
			local behind = targetRoot.CFrame * CFrame.new(0, 0, 3)
			root.CFrame = CFrame.new(behind.Position.X, targetRoot.Position.Y, behind.Position.Z)
		else
			-- No target: flicker a short distance forward instead.
			local dir = root.CFrame.LookVector
			root.CFrame = root.CFrame + Vector3.new(dir.X, 0, dir.Z).Unit * 8
		end
	end

	local function applySecondaryEffects(targetModel)
		if KNOCKBACK_EFFECTS[effect] then
			applyKnockback(targetModel, root.Position, 40)
		elseif SLOW_EFFECTS[effect] then
			applySlow(targetModel, 3)
		elseif STUN_EFFECTS[effect] then
			applyStun(targetModel, ABILITY_STUN_DURATION)
		end
	end

	if radius and radius > 0 then
		-- AoE: hit every valid target inside the radius, with range as the
		-- maximum distance from the caster to the AoE centre (the caster).
		local origin = root.Position
		for _, candidate in ipairs(findTargetsInRadius(origin, radius, character)) do
			CombatService.DamagePlayer(candidate.model, damage, player)
			applySecondaryEffects(candidate.model)
		end
		return
	end

	-- Single-target ability: nearest valid target within `range`, in front,
	-- with line of sight (same validation as melee).
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local best = nil
	local bestDist = range + 1
	for _, candidate in ipairs(findTargetsInRadius(root.Position, range, character)) do
		if candidate.distance < bestDist then
			local toTarget = candidate.root.Position - root.Position
			toTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
			if toTarget.Magnitude > 0.01 then
				local forward = root.CFrame.LookVector
				forward = Vector3.new(forward.X, 0, forward.Z).Unit
				local dot = forward:Dot(toTarget.Unit)
				local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))
				if angle <= ATTACK_ARC then
					local direction = candidate.root.Position - root.Position
					local result = workspace:Raycast(root.Position, direction, rayParams)
					local blocked = false
					if result and result.Instance then
						local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
						if hitModel ~= candidate.model then
							blocked = true
						end
					end
					if not blocked then
						best = candidate
						bestDist = candidate.distance
					end
				end
			end
		end
	end

	if best then
		CombatService.DamagePlayer(best.model, damage, player)
		applySecondaryEffects(best.model)
	end
end

--------------------------------------------------------------------------------
-- NPC damage entry point (used by NPCService AI)
--------------------------------------------------------------------------------

-- NPCs attack through this function instead of duplicating damage logic.
-- `npcModel` is the attacking NPC; damage comes from the NPC's stored
-- Damage attribute / NumberValue, never from a client.
function CombatService.NPCAttack(npcModel, targetModel)
	if not npcModel or not targetModel then
		return
	end
	local npcHumanoid = getHumanoid(npcModel)
	if not npcHumanoid or npcHumanoid.Health <= 0 then
		return
	end
	local targetHumanoid = getHumanoid(targetModel)
	if not targetHumanoid or targetHumanoid.Health <= 0 then
		return
	end
	local damage = npcModel:GetAttribute("Damage") or 10
	if type(damage) ~= "number" then
		damage = 10
	end
	CombatService.DamagePlayer(targetModel, damage, npcModel)
end

function CombatService.GetStreak(player)
	return Streaks[player] or 0
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

function CombatService.Init(dataService, economyService, gameManager)
	DataService = dataService
	EconomyService = economyService
	GameManager = gameManager

	local attackRemote: any = nil
	local abilityRemote: any = nil
	pcall(function()
		attackRemote = Remotes.GetRemote("Attack")
	end)
	pcall(function()
		abilityRemote = Remotes.GetRemote("UseAbility")
	end)
	if attackRemote then
		attackRemote.OnServerEvent:Connect(onAttack)
	else
		warn("[CombatService] Attack remote not found, melee not wired")
	end
	if abilityRemote then
		abilityRemote.OnServerEvent:Connect(onUseAbility)
	else
		warn("[CombatService] UseAbility remote not found, abilities not wired")
	end

	Players.PlayerRemoving:Connect(function(player)
		LastAttackAt[player] = nil
		AbilityCooldowns[player] = nil
		Streaks[player] = nil
	end)
end

return CombatService
