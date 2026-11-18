# Feature Checklist — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

Version 1.0.2 — 2026-11-18 (packaging correction on v1.0.1; no gameplay changes). A feature is marked **Implemented** only when its
behaviour exists in code. **Partial** means it works but with a known gap.
**Not implemented** means it is absent or intentionally omitted. Nothing here
was verified by a Roblox Studio playtest — see `QA_TEST_REPORT.md`.

## Core loop (Priority 1–3)

| Feature | Status | Notes |
|---|---|---|
| 3D world, 7 zones (Plaza, Rift Market, Base District, Tide Channel, Mutation Lab, Chaos Arena, Forbidden Rift) | Implemented | `MapBuilder` builds ~300 anchored parts, 11 lights, portal/conveyor/fountain particles at runtime |
| Market conveyor that actually moves | Implemented | `ConveyorService`: server weighted spawns every 8s, max 8 items, ~1 stud/s along waypoints, BillboardGui price display, despawn at end gate |
| Purchase from conveyor (server-validated) | Implemented | Price recomputed server-side; 0.25s rate limit; 12-stud distance check |
| Carrying (pickup / carry / drop / place) | Implemented | `CarryService`: 0.6x speed while carrying, welded 0.6-scale model, drop on death / tide, 30s world-pickup recovery then returns to inventory |
| Personal bases (12 plots) | Implemented | `BaseService`: assignment on join, owner sign, 10 pedestals, gate, upgrade station; one plot per player (MaxBasePlots = MaxPlayers = 12) |
| Passive income ticks + collect | Implemented | 1s server tick into capped BankedIncome (cap 10,000); `CollectIncome` banks it; level +25%/level, mutation and synergy multipliers applied |
| Base upgrades (slots, income multiplier, lock, turret, conveyor luck) | Implemented | 5 upgrade kinds, server-validated costs from `Config` tables |
| Brainrot level upgrades | Implemented | Max level 5, +25% income per level |
| Glitch Tide event (Warning 30s → Tide 60s → Calm) | Implemented | `TideService`: physical moving wave wall, lighting change, safe zones (shelters/platforms/base plots), carried-Brainrot drop + recovery, survivor rewards |
| Tide variations | Implemented | Playable rotation: Standard, Fast, Toxic, Frozen, Meteor (each with real behaviour in `TideService` + `Config.TideVariations`). Double, Dark, GiantBoss are data-only in `Config.TideVariationsDisabled` — no behaviour, never roll, must not be offered in any UI |
| Inventory (owned Brainrots) | Implemented | `data.OwnedInstances` registry shared by Conveyor/Base/Carry/Mutation services |
| DataStore save / load / autosave / BindToClose | Implemented | `DataService`: pcall everywhere, defaults on load failure, never overwrites valid data with defaults, Studio-safe in-memory fallback |
| Daily login bonus | Implemented | +50 coins, streak up to 7 days |

## Characters, mutations, synergy

| Feature | Status | Notes |
|---|---|---|
| 18 original Brainrots | Implemented | Spec Part 7 roster, distinct procedural models in `CharacterModels`, distinct rarity/cost/income/ability/traits; no copyrighted names or designs |
| 10-tier rarity ladder | Implemented | Common → Impossible; `Config.RarityWeights` sums to 1.0; conveyor weights cover all 10 tiers |
| Character animations (idle/walk/dance/celebrate) | Partial | Procedural bob via `CharacterModels.GetIdleOffset` + `AnimationController` tween/bob; no keyframed Roblox animations (no external animation IDs) |
| Mutations (12) | Implemented | Golden, Diamond, Rainbow, Electric, Frozen, Toxic, Shadow, Glitched, Cosmic, Ancient, Void, Celestial; visible material/colour/particle change; income multipliers ×1.8–×8 |
| Fusion | Implemented | Recipe-based (`FusionService` + `Mutations.FusionRecipes`): two *unplaced* Brainrots → the recipe's result at level 1, for 1,000 coins + 25 Mutation Crystals; inputs consumed before output is granted, refund + restore on failure. Shop **Fusion** tab (v1.0.1) lists unplaced inventory + all 10 recipes and fires `FuseBrainrot {InstanceIdA, InstanceIdB}` with a 5 s no-reply watchdog. Placed Brainrots cannot fuse |
| Synergy system | Implemented | 10 trait synergies (`Synergies`); bonus applied to base income and shown via `SynergyUpdate` |
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
| 12 playable powers + 3-slot loadout | Implemented | Dash, Energy Shield, Magnet Pull, Teleport, Gravity Shift, Freeze Blast, Shadow Walk, Clone Decoy, Tide Surfer, Time Distortion, Rift Hook, Chaos Burst; cooldowns ≥ 3s, server-validated effects |
| Character primary abilities (18) | Implemented | One per Brainrot, Q key, via `CombatService` (primary ids only; loadout powers are handled by `AbilityService`, no double-apply) |
| NPCs (vendor, quest-giver, guard, enemies) | Implemented | `NPCService`: PathfindingService with direct-walk fallback, 1s staggered ticks, max 6 AI NPCs, Wander→Chase→Attack→Flee state machine |
| Boss: THE ALGORITHM | Implemented | `BossService`: 5,000 HP, 3 phases, 30-min auto-spawn, top-damager Epic+ grant, participant rewards |
| PvE waves (Chaos Arena) | Implemented | `WaveService`: wave N spawns N+2 NPCs (cap 24), mini-boss every 5th wave |
| World events (6) | Implemented | Golden Hour, Mutation Storm, Meteor Shower, Secret Merchant, Glitch Invasion, Chaos Arena challenge — all with real effects (income/cost multipliers, drops, spawns). Golden Hour 2× income is now actually applied to base income (v1.0.1: `BaseService.SetEventService` via `GameManager`, stacks with the Tide 2×). Event start/end and tide-survivor notices now reach the HUD (`EventUpdate` / `TideSurvivor` listeners, v1.0.1) |
| Quests (16) | Implemented | Tutorial, daily, collection, exploration, raid, mutation, combat, event; auto-tracked + claimable rewards. Client pulls via `RequestQuests` (wired v1.0.1) and gets `QuestUpdate` pushes on events/claims/shortly after join |
| Leveling / XP | Implemented | Shared XP curve, level-up coin/gem/slot rewards |
| Rebirth | Implemented | Level 25 + 100,000 coins + 10 *distinct* owned Brainrots; resets coins/level/placed (placed return to inventory) but keeps owned characters, rebirth count, wins/KOs, quests, cosmetics; +10% income and +2 slots per rebirth, +25 gems, max 10 rebirths |
| Cosmetics (titles, auras, trails) | Implemented | 11 cosmetics, unlock-by-level/rebirth, visual only, no gameplay advantage |
| Offline income | Not implemented | `DataService` tracks `LastLogin` and pays a daily bonus, but no offline-income payout is calculated on rejoin |

## Presentation, controls, security

| Feature | Status | Notes |
|---|---|---|
| HUD (coins/gems/shards, income/s, level/XP, region, powers, quest tracker, tide countdown, carry/base status) | Implemented | `HUDController`; event banner now shows world-event start/end (`EventUpdate`) and tide-survivor notices (`TideSurvivor`) via `ShowEventBanner` (v1.0.1) |
| Menus (Collection, Inventory, Market, Base Upgrades, Abilities, Mutation Lab, Quests, Events, Rebirth, Settings, Leaderboards, Achievements, Cosmetics) | Partial | All listed menus exist and open working panels except: Trading (intentionally absent — no button), Achievements (shown inside the Quests/Collection panels, no separate module), World Selection (single world in this build; additional dimensions from the spec are not built) |
| Every button works / no fake buttons | Implemented | Verified by grep: no dead buttons in client code; Shop/Quest buttons show server-result feedback and a "no reply" watchdog |
| Mobile + desktop + controller | Partial | Desktop WASD/mouse, E interact, G drop, Q/F/R powers, menu hotkeys; mobile touch buttons for interact/abilities/menus. Controller input is not explicitly bound |
| Sound (built-in Roblox sounds only) | Implemented | `SoundController`; no copyrighted audio, no external asset IDs |
| Camera follows the character (morph / respawn / teleport) | Implemented | `CameraController` camera manager (v1.0.1): explicit rebind on `CharacterAdded` + `player.Character` property change + respawn + teleport + death/recovery, 0.5 s watchdog; only `CameraController` / `EffectsController` touch the camera. **Studio regression test still required** — see `GROK_BUILD_HANDOFF.md` §1 |
| Server authority + validation | Implemented | All economy/ownership/damage/rewards server-side; rate limiting, distance/price/cooldown/ownership checks; `SecurityService` helpers. `BuyCharacter` / `SelectCharacter` now also burst-limited (5 per 5 s, v1.0.1) |
| Performance measures | Implemented | Anchored static geometry, ≤ 12 lights, pooled/staggered NPC loops, cleanup of temporary objects; no StreamingEnabled tuning done in Studio (unverified) |

## Delivery (not gameplay)

| Feature | Status | Notes |
|---|---|---|
| Rojo project (`default.project.json`, `rojo.toml`) | Implemented | Rojo 7.7 layout; `rojo build -o GlitchTide.rbxl` / `rojo serve`. v1.0.1: project file corrected from `$class` to `$className` (Rojo 7.7 rejects `$class`); build verified in this workspace with Rojo 7.7.1. v1.0.2: `StarterGui` moved to a direct DataModel child (`src/client/ui`); `StarterPlayerScripts` maps only `Main.client.luau` + `Controllers/`; `src/map/README.md` moved to `docs/map.md` (outside the Rojo tree); built hierarchy verified from the `.rbxl` and Rojo's `/show-instances` tree |
| README / Grok Build handoff / QA test report / third-party notices / changelog / MIT license | Implemented | In project root; `QA_TEST_REPORT.md` added in v1.0.1 |
| `.rbxl` place file | Implemented | `GlitchTide.rbxl` (333,816 bytes, v1.0.2 rebuild; was 341,613 in v1.0.1) built in this workspace with Rojo 7.7.1 and verified (decompressed + Rojo `/show-instances` tree) to contain all 48 script sources, with `MainMenu` under the real `StarterGui` service and `Main` + `Controllers/` under `StarterPlayerScripts` |
| Studio playtest / screenshots / publishing / make.fun submission | Not implemented | Explicitly Grok Build's job; nothing here claims otherwise |

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
