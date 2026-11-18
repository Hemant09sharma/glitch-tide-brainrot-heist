# Feature Checklist — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

Version 1.1.0 — 2026-11-19 (EXTREME EXPANSION on v1.0.2). A feature is marked **Implemented** only when its
behaviour exists in code. **Partial** means it works but with a known gap.
**Not implemented** means it is absent or intentionally omitted. Nothing here
was verified by a Roblox Studio playtest — see `QA_TEST_REPORT.md`. Per the
Part 16 policy, no v1.1 feature is "Fully implemented and tested" (that
status requires a Studio run); v1.1 features are **Implemented but not
runtime tested** unless marked Partial here. The per-workstream
classifications live in `docs/QA_V11_A.md` … `docs/QA_V11_E.md`.

## Core loop (Priority 1–3)

| Feature | Status | Notes |
|---|---|---|
| 3D world, 9 regions (Plaza, Rift Market, Base District, Tide Channel, Mutation Lab, Chaos Arena, Forbidden Rift + Abyssal Kingdom + Skyfall Kingdom) | Implemented but not runtime tested | `MapBuilder` rewritten (575 parts, 16 lights, elevation + landmarks per region); `LightingService` 12 moods; `EnvironmentService` ~30 animated elements. The 2 new regions are functional (see below), not scenery |
| Abyssal Kingdom (functional) | Implemented but not runtime tested | Sunken basin at (-150,150): 3 treasure chests (150/300/600 coins + XP), 3 currents (push + 5 dmg/s), boss altar (600 s cooldown → spawns a boss + one-time exclusive `puddle_professor`). Partial: the altar spawns THE ALGORITHM in the Chaos Arena, not an Abyssal-local boss |
| Skyfall Kingdom (functional) | Implemented but not runtime tested | 4 floating islands (y 45–57), bridges ≤25°, 4-checkpoint timed run (90 s → 250 coins + 40 XP + one-time exclusive `moon_mochi`), 2 wind hazards, hidden SkyCache chest, falling below y=20 returns to hub |
| Dimension teleports + level gates | Implemented but not runtime tested | Server-validated (hub-portal proximity 14 studs, hub-only origin, 3 s cooldown, denied while carrying); Abyssal L5, Skyfall L15, persisted in `data.DimensionUnlocks`. Gate fails OPEN only if no ProgressionService is linked (it is linked in the shipped wiring) |
| Market conveyor that actually moves | Implemented | `ConveyorService`: server weighted spawns every 8s, max 8 items, ~1 stud/s along waypoints, BillboardGui price display, despawn at end gate |
| Purchase from conveyor (server-validated) | Implemented | Price recomputed server-side; 0.25s rate limit; 12-stud distance check |
| Carrying (pickup / carry / drop / place) | Implemented | `CarryService`: 0.6x speed while carrying, welded 0.6-scale model, drop on death / tide, 30s world-pickup recovery then returns to inventory |
| Personal bases (12 plots) | Implemented | `BaseService`: assignment on join, owner sign, 10 pedestals, gate, upgrade station; one plot per player (MaxBasePlots = MaxPlayers = 12) |
| Passive income ticks + collect | Implemented | 1s server tick into capped BankedIncome (cap now scales: `100,000 + 5,000/level + 10,000/rebirth + 25,000/prestige`, was flat 10,000); `CollectIncome` banks it; level +25%/level, mutation and synergy multipliers applied; companion IncomeBonus applied via `EconomyService` (max +25%) |
| Base upgrades (slots, income multiplier, lock, turret, conveyor luck) | Implemented | 5 upgrade kinds, server-validated costs from `Config` tables |
| Brainrot level upgrades | Implemented | Max level 5, +25% income per level |
| Glitch Tide event (10-stage anticipation → wave → rewards) | Implemented but not runtime tested | `TideService`: 10 stages (EnvironmentFlicker → StructureFlicker → Sirens → SkyChange → PlayerWarning → WaveEmerges → WaveTravels → Survival → Climax → Rewards), each broadcast on `GlitchTideUpdate`; escape routes broadcast; 3 temporary shelters; 4 moving channel obstacles; risk zones (+5 coins/s banked); tide surfing bonus; flawless-survival 10% Secret/Divine grant; co-op survival rewards; 10% secret-encounter roll per tide |
| Tide variations | Implemented but not runtime tested | All 10 playable with real behaviour in `TideService` + `Config.TideVariations` (weights sum to 100): Standard, Fast, Toxic, Frozen, Meteor, Double (2 anti-phase walls), Dark (FogEnd 120, ambush spawns), GiantBoss (THE GLITCH COLOSSUS spawns mid-tide), Corrupted (glitch barriers teleport the exposed), Cosmic (gravity 196 → 60, starfall pickups). `Config.TideVariationsDisabled` deleted in v1.1 |
| Inventory (owned Brainrots) | Implemented | `data.OwnedInstances` registry shared by Conveyor/Base/Carry/Mutation services |
| DataStore save / load / autosave / BindToClose | Implemented | `DataService`: pcall everywhere, defaults on load failure, never overwrites valid data with defaults, Studio-safe in-memory fallback |
| Daily login bonus | Implemented | +50 coins, streak up to 7 days |

## Characters, mutations, synergy

| Feature | Status | Notes |
|---|---|---|
| 27 original Brainrots | Implemented but not runtime tested | 18 v1.0.2 + 9 new (one per tier Common–Secret), distinct procedural models in `CharacterModels`, distinct rarity/cost/income/ability/traits; no copyrighted names or designs. 15 grant companion abilities (capped per kind) |
| 10-tier rarity ladder | Implemented | Common → Impossible; `Config.RarityWeights` sums to 1.0; conveyor weights cover all 10 tiers |
| Character animations (idle/walk/run/jump/land/dance/celebrate/attack/damage/rare-discovery) | Partial | Per-character profiles in `AnimationController` (315 → 770 lines), procedural tween/bob; morphed models animated via root-CFrame deltas only; no keyframed Roblox animations (no external animation IDs) |
| Mutations (12) | Implemented | Golden, Diamond, Rainbow, Electric, Frozen, Toxic, Shadow, Glitched, Cosmic, Ancient, Void, Celestial; visible material/colour/particle change; income multipliers ×1.8–×8 |
| Fusion | Implemented | Recipe-based (`FusionService` + `Mutations.FusionRecipes`): two *unplaced* Brainrots → the recipe's result at level 1, for 1,000 coins + 25 Mutation Crystals; inputs consumed before output is granted, refund + restore on failure. Shop **Fusion** tab (v1.0.1) lists unplaced inventory + all 19 recipes and fires `FuseBrainrot {InstanceIdA, InstanceIdB}` with a 5 s no-reply watchdog. Placed Brainrots cannot fuse |
| Brainrot Laboratory (Evolve / traits / secret recipes / alternate forms) | Implemented but not runtime tested | `LaboratoryService`: Evolve (max-level Brainrot + materials → evolved form, keeps CharacterId, gains EvolvedTrait, mutation upgraded); trait upgrades to level 3 (level 3 sets Glitched=true, ×2 income); 3 secret recipes gated by SecretService discoveries; 11 alternate-form pairs; transform effects via `CharacterModels.PlayTransformEffect` + SpawnEffect + banner |
| Expeditions | Implemented but not runtime tested | `ExpeditionService`: 6 expeditions (60 s / 5% risk → 1800 s / 40% risk); rewards coins/gems/crystals/shards/XP/materials + rare discovery of a random unowned Brainrot ≥ min rarity; one active expedition per player; risk only reduces rewards, Brainrot never lost. Partial: on-expedition instances are hidden by the UI but Base/Mutation/Fusion services do not read the `OnExpedition` flag |
| Territory Control | Implemented but not runtime tested | `TerritoryService`: 7 capturable locations (Plaza, Market, Lab, Arena, Rift, Abyssal, Skyfall); 10 s channel, contested freeze, 60 s per-player cooldown, no captures during an Active tide, capture breaks on holder leave/death. Partial (deliberate): bonus is a flat tick (5/10/15 coins/s + 10/20/30 XP/min by tier), not an income multiplier |
| Companion Abilities | Implemented but not runtime tested | `CompanionService` + `Companions.luau`: 15 characters grant IncomeBonus, TideProtection, RareDetection, CarrySpeed, RaidDetection, or MutationBonus (capped: 0.25 / 0.20 / 0.20 / 0.15 / 0.25 / 0.15). All 6 bonuses wired: income via EconomyService→BaseService, tide via GameManager `IsTideSurfer`, carry via CarryService, mutation via BaseService, rare detection via ConveyorService weights, raid via RaidService channel extension |
| Secret Discovery | Implemented but not runtime tested | `SecretService`: 5 secrets (rift_whisper, hidden_merchant, puzzle_room, secret_sighting, skyfall_summit); never listed anywhere (no `RequestSecrets`); hidden merchant spawns via `NPCService.SpawnQuestGiver` on HiddenMerchant tides (120 s); 3-rune puzzle room. Partial: merchant is a discovery trigger, not a shop (no secret shop inventory) |
| Synergy system | Implemented | 13 trait synergies (`Synergies`, was 10); bonus applied to base income. Full-roster bonus is 2.8 (was 2.15 at 18 characters) |
| Collection book / encyclopedia | Implemented | `CollectionController` + `ProgressionService.GetCollection`; undiscovered shown as silhouette + hint |

## Multiplayer, raiding, defense

| Feature | Status | Notes |
|---|---|---|
| Multiplayer bases / independent income | Implemented | Per-player base + data; server-authoritative economy |
| Stealing / raiding | Implemented | `RaidService`: 3s channel, 8-stud range, alarm + `StealAlert`, ownership transfers only after delivery to thief's base; stolen Brainrot returns to victim if dropped |
| Base defense (shield, gate, lockdown, guard, turret) | Implemented | Shield blocks steals, lockdown 30s (250 coins), guard NPC patrol, turret upgrade tier |
| Raid fairness protections | Implemented | New-player (level < 3), account age < 7d, last-creature, recently-placed (< 120s), offline victims cannot be raided (victim must be in-game) |
| Failed-theft consequences | Implemented | 3s stun + 60s cooldown |
| Trading | Not implemented | Intentionally omitted for safety. Trade remote names exist as reserved names only; no handler moves items/currency between players |

## Powers, NPCs, bosses, events

| Feature | Status | Notes |
|---|---|---|
| 17 playable powers + 3-slot loadout | Implemented but not runtime tested | 12 v1.0.2 + 5 new (Time Rewind 20 s, Meteor Shower 18 s, Void Dash 10 s, Gravity Crush 22 s, Dimensional Prison 25 s), each with a def in `Powers.PlayablePowers` AND an effect branch in `AbilityService.UsePower`; cooldowns ≥ 3s, server-validated effects. Power mastery: +10 XP/use, levels 0–5, +5% damage / −2% cooldown per level (floored at 3 s) |
| Character primary abilities (27) | Implemented but not runtime tested | One per Brainrot, Q key, via `CombatService` (primary ids only; loadout powers are handled by `AbilityService`, no double-apply). 9 new Q primaries (6–9 s cooldowns) using Effect strings already handled by CombatService |
| NPCs (vendor, quest-giver, guard, enemies) | Implemented | `NPCService`: PathfindingService with direct-walk fallback, 1s staggered ticks, max 6 AI NPCs, Wander→Chase→Attack→Flee state machine |
| Boss: THE ALGORITHM | Implemented | `BossService`: 5,000 HP, 3 phases, 30-min auto-spawn, top-damager Epic+ grant, participant rewards. Unchanged behaviour in v1.1 (now runs through the shared generic boss path) |
| Boss: THE GLITCH COLOSSUS | Implemented but not runtime tested | Chaos Arena. 7,500 HP base, +10% per extra player (cap 2×). P1 slam, P2 shockwave + teleport-to-player, P3 meteor + summons + glitch nova. Top damager +75 gems + unowned Legendary/Mythic/Divine grant; co-op rewards. Spawns mid-tide on GiantBoss tides and on every 10th wave |
| Boss: THE VOID EMPEROR | Implemented but not runtime tested | Forbidden Rift. 9,000 HP base, same scaling. P1 void bolt, P2 void zones + summons, P3 starfall + shockwave + void nova. Top damager +100 gems + unowned Mythic/Divine/Celestial/Secret grant; co-op rewards. Spawns on wave % 20 == 0 |
| BossUpdate broadcasts | Implemented but not runtime tested | Fired on spawn / phase / 2 s health / death (`{Event, BossId, BossName, Arena, Active, Health, MaxHealth, Phase}`); HUD now listens and shows a boss bar (was Partial in v1.0.1 — no listener) |
| PvE waves (Chaos Arena) | Implemented | `WaveService`: wave N spawns N+2 NPCs (cap 24), mini-boss every 5th wave; no wave starts mid-tide; every 10th wave summons a real boss (wave % 20 == 0 → Void Emperor, else Colossus) |
| World events (6) | Implemented | Golden Hour, Mutation Storm, Meteor Shower, Secret Merchant, Glitch Invasion, Chaos Arena challenge — all with real effects (income/cost multipliers, drops, spawns). Golden Hour 2× income is now actually applied to base income (v1.0.1: `BaseService.SetEventService` via `GameManager`, stacks with the Tide 2×). Event start/end and tide-survivor notices now reach the HUD (`EventUpdate` / `TideSurvivor` listeners, v1.0.1) |
| Quests (54) | Implemented but not runtime tested | Was 16. Story chain of 5 (`Requires` field: prerequisite must be CLAIMED first); daily 3 + weekly 3 (ISO-week reset); exploration, secret, collection (10/20/27), mutation, survival (incl. flawless no-damage tide), boss, combat, raid/defense, expedition, territory, dimension, event. Single-funnel progress via `QuestService.RecordEvent`. Not implemented: synergy-formation quest (no server-side synergy event exists); boss-without-dying quest (covered by flawless-tide + boss-defeat quests); per-family quests (families not defined) |
| Achievements (24) + titles (13) | Implemented but not runtime tested | `AchievementService` + `AchievementDefs`: 12 firsts + 12 cumulative; rewards paid once; `AchievementUnlocked` broadcast + banner. Titles granted into `data.Titles`; equipping persists server-side via `SetEquippedTitle` + `EquipTitle` remote (wired in integration). Milestones: levels 15/20/30/40/50/75/100, collection 10/15/20/27, 8 challenges |
| Leveling / XP | Implemented | Shared XP curve, level-up coin/gem/slot rewards |
| Rebirth | Implemented | Level 25 + 100,000 coins + 10 *distinct* owned Brainrots; resets coins/level/placed (placed return to inventory) but keeps owned characters, rebirth count, wins/KOs, quests, cosmetics; +10% income and +2 slots per rebirth, +25 gems, max 10 rebirths. Rebirth income contradiction fixed in v1.1 (Config +10% is now the single source of truth on both paths) |
| Prestige | Implemented but not runtime tested | Past max rebirths: 10 rebirths + Level 25 + 250,000 coins + 15 distinct Brainrots → Rebirths 0, Prestige +1, keeps collection / dimension unlocks / mastery, +50 gems, grants `title_prestiged`, +5% income per prestige rank. Via the existing `Rebirth` remote `{Action="Prestige"}` |
| Rare-character mastery | Implemented but not runtime tested | Rare+ Brainrots only; 100/500/1000 mastery XP → +1% income each, max +3% per Brainrot (+15% total), folded into `GetIncomeMultiplier`. Awarded by expeditions and evolutions. Partial: mastery is shown in the Shop from session use counts; the server pushes no mastery state |
| Cosmetics (titles, auras, trails) | Implemented | 11 cosmetics, unlock-by-level/rebirth, visual only, no gameplay advantage |
| Offline income | Not implemented | `DataService` tracks `LastLogin` and pays a daily bonus, but no offline-income payout is calculated on rejoin |

## Presentation, controls, security

| Feature | Status | Notes |
|---|---|---|
| HUD (coins/gems/shards, income/s, level/XP, region, powers, quest tracker, tide countdown, carry/base status) | Implemented but not runtime tested | `HUDController`; event banner shows world-event start/end (`EventUpdate`) and tide-survivor notices (`TideSurvivor`); new in v1.1: boss bar (`BossUpdate` listener), tide stage line, title slot, death & victory screens, welcome banner |
| Menus (Collection, Inventory, Market, Base Upgrades, Abilities, Mutation Lab, Quests, Events, Rebirth, Settings, Leaderboards, Achievements, Cosmetics, Worlds, Laboratory, Expeditions, Territories) | Implemented but not runtime tested | All listed menus exist and open working panels, including the new Dimension (Worlds), Laboratory, Expedition, Territory, and Achievement+Titles panels. Trading intentionally absent — no button. World Selection now exists (Dimension panel). MainMenu two-column layout with 5 panel shortcuts + OBJECTIVES + Master/SFX/Music steppers |
| Every button works / no fake buttons | Implemented but not runtime tested | Verified by grep: every TextButton has a handler (`PanelKit.MakeButton` always connects); Shop/Quest buttons show server-result feedback and a "no reply" watchdog |
| Mobile + desktop + controller | Partial | Desktop WASD/mouse, E interact, G drop, Q/F/R powers, menu hotkeys; mobile touch buttons for interact/abilities/menus (incl. Attack touch button). Controller input is not explicitly bound |
| Sound (built-in Roblox sounds only) | Implemented but not runtime tested | `SoundController`; 34 verified `rbxasset://sounds/...` cues (pcall-guarded, client-local, Master/SFX/Music steppers); 5 slots deliberately unassigned (marketAmbience, conveyorLoop, music, dimensionAmbience, tideSirenLoop — named slots, no invented IDs). `SoundHook` wired; no `rbxassetid://` in code (2 comment mentions only, explaining no invented IDs) |
| Camera follows the character (morph / respawn / teleport) | Implemented | `CameraController` camera manager (v1.0.1): explicit rebind on `CharacterAdded` + `player.Character` property change + respawn + teleport + death/recovery, 0.5 s watchdog; only `CameraController` / `EffectsController` touch the camera. **Studio regression test still required — and must be re-run after the v1.1 overhaul** — see `GROK_BUILD_HANDOFF.md` §1 |
| Server authority + validation | Implemented | All economy/ownership/damage/rewards server-side; rate limiting, distance/price/cooldown/ownership checks; `SecurityService` helpers. `BuyCharacter` / `SelectCharacter` now also burst-limited (5 per 5 s, v1.0.1). Attack/Steal now have client firers with server-side validation (steal: 1 s debounce + 60 s per-victim cooldown) |
| Performance measures | Implemented but not runtime tested | Anchored static geometry, ≤ 16 lights, pooled/staggered NPC loops, cleanup of temporary objects; EnvironmentService uses one Heartbeat loop with cached CFrames (no per-frame Instance creation); damage-number cap 40; quest tracker push-only; no StreamingEnabled tuning done in Studio (unverified) |

## Delivery (not gameplay)

| Feature | Status | Notes |
|---|---|---|
| Rojo project (`default.project.json`, `rojo.toml`) | Implemented | Rojo 7.7 layout; `rojo build -o GlitchTide.rbxl` / `rojo serve`. v1.0.1: project file corrected from `$class` to `$className` (Rojo 7.7 rejects `$class`); build verified in this workspace with Rojo 7.7.1. v1.0.2: `StarterGui` moved to a direct DataModel child (`src/client/ui`); `StarterPlayerScripts` maps only `Main.client.luau` + `Controllers/`; `src/map/README.md` moved to `docs/map.md` (outside the Rojo tree); built hierarchy verified from the `.rbxl` and Rojo's `/show-instances` tree |
| README / Grok Build handoff / QA test report / third-party notices / changelog / MIT license | Implemented | In project root; `QA_TEST_REPORT.md` added in v1.0.1 |
| `.rbxl` place file | Implemented | `GlitchTide.rbxl` (558,606 bytes, v1.1.0 rebuild; was 333,816 in v1.0.2) built in this workspace with Rojo 7.7.1 (built twice — byte-identical) and verified (decompressed + Rojo `/show-instances` tree + `scripts/verify-rbxl.py`) to contain all 68 script sources byte-for-byte, with `MainMenu` under the real `StarterGui` service and `Main` + `Controllers/` under `StarterPlayerScripts` |
| Studio playtest / screenshots / publishing / make.fun submission | Not implemented | Explicitly Grok Build's job; nothing here claims otherwise. **v1.1 is not claimed paid-eligible** — the recording/authorship rules are unchanged (see `QA_TEST_REPORT.md` §13) |

## Known integration issues fixed during integration (2026-11-18)

- `CharacterService` / `DataService` / `CombatService` / `ProgressionService` / client controllers defaulted to the removed character id `tung_tung` — now `wobble_waffleton` everywhere.
- `PlayerStats` was declared a RemoteFunction but every server service fires it as an event and the client connects `OnClientEvent` — now a RemoteEvent in `Remotes.luau`.
- `QuestUpdate` and `EquipCosmetic` remote names were referenced but missing — added (`EquipCosmetic` is reserved/inert; cosmetics equip via the `SelectCharacter` envelope).
- `Config.ConveyorRarityWeights` covered only 6 tiers — now all 10 tiers, aligned with `Config.RarityWeights`.
- `CombatService` was never initialised — now initialised in `Main.server.luau` after `GameManager.Init`.
- `MutationService.loadMutationTable` mapped shared `IncomeMultiplier` to nothing (all shared mutations would have loaded at 1x) and kept capitalised ids unfindable — fixed to normalise lowercase ids and read `IncomeMultiplier`, with rebirth gating for Void/Celestial (1) and Rainbow (2).
- Stale documentation (old Italian roster table, "review required" naming note, "MapBuilder/GameManager missing", "quests/rebirth unconfirmed") corrected in `README.md`, `THIRD_PARTY_NOTICES.md`, `CHANGELOG.md`, `GROK_BUILD_HANDOFF.md`.
- `Config.AbilitySlots` now matches the shipped client binding (Q primary,
  F Slam, R Heal, E Interact) — the v1.0.0 Q/E/R mapping is gone; one
  canonical keybind table, verified by the v1.0.1 QA harness.

## Integration fixes, v1.0.1 final pass (2026-11-18)

- `CharacterService` called the non-existent `Remotes.GetRemotes()` —
  now per-name `Remotes.GetRemote("SelectCharacter" / "PlayerStats")`
  like `EconomyService` / `CombatService`.
- `RequestQuests` had no server handler — `QuestService` now sets
  `OnServerInvoke` to `GetQuests(player)` and pushes `QuestUpdate`
  shortly after join; `QuestController`'s stale "no server handler yet"
  warning removed. `RequestCollection` → `ProgressionService.GetCollection`
  and `RequestEvents` → `EventService.GetActiveEvent` wired the same way.
- Fusion had no client UI — Shop **Fusion** tab added (unplaced inventory
  + 10 recipes + `FuseBrainrot {InstanceIdA, InstanceIdB}` + 5 s watchdog);
  `BaseService.GetBase` now exposes the unplaced instances the tab needs.
  `FusionService` logic untouched.
- `EventUpdate` / `TideSurvivor` were fired but never listened to —
  `HUDController` now listens and shows them via `ShowEventBanner`.
- Golden Hour 2× income existed on `EventService` but `BaseService` never
  applied it — now wired via `BaseService.SetEventService` in
  `GameManager.wireCrossLinks`; stacks with (never double-applies) the
  Tide multiplier.
- `BuyCharacter` / `SelectCharacter` had no burst limit —
  `SecurityService.BurstLimit(player, key, 5, 5)` now rejects bursts with
  a clear message; purchase/equip logic untouched.
- `InteractType` / `InteractId` attribute scan removed from
  `InteractionController` (option b): no producer ever set those
  attributes, so the scan always found nothing. ProximityPrompts are the
  sole interaction path, documented in the controller header.
- `default.project.json` used `$class` — Rojo 7.7 rejects it; corrected
  to `$className`, and `rojo build` now succeeds (see `QA_TEST_REPORT.md`).

## Integration fixes, v1.1 (2026-11-18/19)

- `GameManager` registers all 9 new services in `OPTIONAL_SERVICES`
  (Lighting, Environment, Dimensions, Companion, Laboratory, Expedition,
  Territory, Secret, Achievement) with explicit `loadOptional` branches
  for Laboratory / Territory / Secret / Achievement (their `Init`
  signatures do not match the generic fallback).
- `wireCrossLinks` extended with `SetLightingService`,
  `SetCompanionService`, `SetDimensionsService`, `SetLaboratoryService`,
  `SetExpeditionService`, `SetTerritoryService`, `SetSecretService`,
  `SetAchievementService`; `IsTideSurfer` callback also consults
  `CompanionService.IsTideProtected`.
- `EquipTitle` server handler wired in `AchievementService.Init`
  (QuestService retry pattern; accepts `{TitleId}` table or bare
  string; ownership validated by `SetEquippedTitle`).
- All 6 companion bonuses wired: income (BaseService via
  EconomyService), tide protection (GameManager), carry speed
  (CarryService setter, clamped 0.1–0.75), mutation bonus (BaseService,
  mutated instances only, max +0.15), rare detection (ConveyorService
  shared-conveyor weights, capped +20%), raid detection (RaidService
  steal channel extended, max 10.5 s).
- Stale `Utils.luau` comment fixed (claimed slam was on "E" — false
  since v1.0.1; canonical Q/F/R now).
- Rebirth income contradiction fixed: Config +10% is the single source
  of truth on both paths (+5% per prestige rank mirrors it).
- Banked-income cap flat 10,000 → scaled
  (`100,000 + 5,000/level + 10,000/rebirth + 25,000/prestige`).
- Fusion recipes for the 9 new characters added (19 total).
- `Types.luau` CharacterDef mirror synced (`CompanionAbility`).
- Dead paths fixed (Wave 3): Attack firer, StealBrainrot firer,
  `RequestCollection` / `RequestEvents` callers, `BossUpdate` listener,
  `SpawnEffect` dual-form acceptance, `StealAlert` payload parsing,
  `GlitchTideUpdate` capital-key fix, 5 dead fires removed.
- Harness check 65 first failed on two `rbxassetid://` mentions in
  `SoundController.luau` comments (explaining that no invented IDs are
  used) — the check now strips comments before searching; code contains
  zero `rbxassetid://` uses.
