# Changelog — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

All notable changes to this project are documented here.
Versioning follows Semantic Versioning (MAJOR.MINOR.PATCH).

## [1.1.0] — 2026-11-19 — EXTREME EXPANSION

`Config.GameVersion` bumped to 1.1.0. 68 Luau files, 42,045 lines
(was 48 files / 26,062 lines in v1.0.2). All v1.0.2 fixes preserved.
No Studio playtest was run — every new feature is classified per the
Part 16 policy in `FEATURE_CHECKLIST.md` and `QA_TEST_REPORT.md` §9–§13;
nothing new here is "Fully implemented and tested" (that status requires
a Studio run).

- **Visual overhaul (Part 2):** `MapBuilder` rewritten (615 → 1,189
  lines, 575 parts, 16 lights): distinct architecture, elevation, and
  landmarks per region; new `LightingService` (12 moods, 2.5 s tweened
  transitions) and `EnvironmentService` (one Heartbeat loop, ~30
  animated elements). `docs/SHOT_LIST.md` documents 4 photographable
  compositions.
- **Brainrots (Part 3):** roster 18 → 27 (one new character per tier
  Common–Secret: Phantom Pancake, Prism Penguin, Neon Narwhal, Reactor
  Raccoon, Gravity Goblin, Thunder Tortoise, Quantum Quokka, Solar
  Sloth, Void Vulture). All 27 models rebuilt with distinct silhouettes
  and rarity presentation; `AnimationController` expanded to per-character
  idle/walk/run/jump/land/dance/celebrate/attack/damage/rare-discovery
  sets (procedural tween/bob — still no keyframed animation). 3 new
  synergies (13 total). Companion abilities on 15 characters, all 6
  bonuses now wired end-to-end (income, tide protection, carry speed,
  mutation bonus, rare detection, raid detection).
- **New regions (Part 4):** Abyssal Kingdom (sunken basin, 3 treasure
  chests, currents, boss altar) and Skyfall Kingdom (4 floating islands,
  4-checkpoint timed run, wind hazards, hidden SkyCache chest), via
  `DimensionsService` + shared `Dimensions.luau`; server-validated
  teleports, level gates (Abyssal L5, Skyfall L15), exclusive Brainrots
  (`puddle_professor`, `moon_mochi`).
- **Glitch Tide (Part 5):** 10-stage cinematic anticipation; all 10
  variants now working (Double/Dark/GiantBoss promoted out of data-only;
  `Config.TideVariationsDisabled` deleted); escape routes, 3 temporary
  shelters, 4 moving channel obstacles, risk zones, tide surfing,
  glitch barriers (Corrupted), low gravity (Cosmic), tide-exclusive
  conveyor spawns, flawless-survival Secret/Divine grant, co-op survival
  rewards, secret-encounter roll.
- **New systems (Part 6):** Brainrot Laboratory (Evolve, trait upgrades
  to level 3, 3 secret recipes, 11 alternate forms),
  Expeditions (6, 60 s–1800 s, risk reduces rewards, Brainrot never
  lost), Territory Control (7 capturable locations, 10 s channel,
  contested freeze, 60 s cooldown, flat-tick bonus by design),
  Secret Discovery (5 secrets, hidden merchant, 3-rune puzzle room),
  Achievements module (24 achievements, 13 titles).
- **Progression (Part 7):** prestige (past 10 rebirths), level
  milestones 15/20/30/40/50/75/100, collection milestones 10/15/20/27,
  8 challenges, rare-character mastery (Rare+, +1% income per tier to
  +3%), rebirth income contradiction fixed (single source: +10% per
  rebirth, +5% per prestige), banked-income cap now scales
  (`100,000 + 5,000/level + 10,000/rebirth + 25,000/prestige`).
- **Quests (Part 8):** 16 → 54 (story chain of 5 via new `Requires`
  field; daily 3 + weekly 3 with ISO-week reset; exploration, secret,
  collection, mutation, survival, boss, combat, raid/defense,
  expedition, territory, dimension, event). Single-funnel progress:
  `QuestService.RecordEvent` forwards to achievements/challenges.
- **Bosses + combat (Part 9):** THE GLITCH COLOSSUS (7,500 HP) and
  THE VOID EMPEROR (9,000 HP), both 3-phase with telegraphs, scaling
  (+10% per extra player, cap 2×), co-op rewards; THE ALGORITHM
  unchanged (5,000 HP, unscaled). Every 10th wave summons a real boss;
  no wave starts mid-tide.
- **Powers (Part 10):** 5 new playable powers, fully wired in
  `AbilityService` (Time Rewind 20 s, Meteor Shower 18 s, Void Dash
  10 s, Gravity Crush 22 s, Dimensional Prison 25 s); power mastery
  (+10 XP/use, levels 0–5, +5% damage / −2% cooldown per level,
  floored at 3 s). Keybinds unchanged (Q/F/R/E/G, 1/2/3).
- **UI (Part 11):** 6 new panels (Dimension/Worlds, Laboratory,
  Expedition, Territory, Achievement+Titles, plus HUD boss bar / tide
  stage line / title slot / death & victory screens / welcome banner /
  2nd menu row); MainMenu two-column layout; quests grouped by
  category; collection fixed to X/27. No decorative nonfunctional UI —
  every button has a handler.
- **Sound (Part 12):** 34 verified `rbxasset://sounds/...` cues
  (pcall-guarded, client-local, Master/SFX/Music steppers); 5 slots
  deliberately unassigned (no invented IDs). `SoundHook` wired.
- **Multiplayer (Part 13):** dead paths fixed — Attack firer
  (left-click + touch, 0.45 s cooldown), StealBrainrot firer (cached
  plot scan, 60 s per-victim cooldown, 5 s watchdog),
  `RequestCollection` / `RequestEvents` now invoked by clients,
  `BossUpdate` listener in HUD, `EquipTitle` server handler wired.
  `UsePower` / `SettingsUpdate` / `SynergyUpdate` stay unwired by
  documented decision (see `docs/REMOTES_WIRED_E.md`).
- **Engineering (Part 15):** 9 new services registered in `GameManager`
  (`OPTIONAL_SERVICES` + explicit `loadOptional` branches where
  signatures differ); `wireCrossLinks` extended; companion hooks in
  GameManager/CarryService/BaseService/ConveyorService/RaidService;
  stale Utils slam-"E" comment fixed; dead 5 s PlayerStats poll and
  5 dead remote fires removed.
- **Verification (Part 17):** `luau-compile` 68/68; Python harness
  extended 50 → 70 checks (all pass); Lune harness extended 33 → 40
  checks (all pass); Rojo build twice, byte-identical
  (SHA-256 `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`,
  558,606 bytes); source-to-place byte matching 68/68
  (`scripts/verify-rbxl.py`); hierarchy re-verified via Rojo's
  `/show-instances` tree (StarterGui → MainMenu once;
  StarterPlayerScripts → Main + Controllers; Workspace empty).

## [1.0.2] — 2026-11-18

Packaging correction only — no gameplay changes, all v1.0.1 fixes
preserved. `Config.GameVersion` bumped to 1.0.2.

- `default.project.json`: `StarterGui` was nested inside
  `StarterPlayer` (not a real Roblox service hierarchy), so `MainMenu`
  was never cloned into `PlayerGui` and the main menu never appeared.
  `StarterGui` is now a direct child of the DataModel mapping to
  `src/client/ui`, and `StarterPlayerScripts` now maps only
  `src/client/Main.client.luau` (as `Main`, a LocalScript) +
  `src/client/Controllers` — `src/client/ui` is no longer duplicated
  under `StarterPlayerScripts` (in v1.0.1 `MainMenu` existed twice in
  the built place, once under each location).
- `src/map/README.md` moved to `docs/map.md`, outside the Rojo tree, so
  no documentation file lives under `src/`; `src/map/` holds only an
  empty `.gitkeep` and the built `Workspace` is intentionally empty
  (`MapBuilder` constructs the arena at runtime).
- `TEST_REPORT.md` marked as an archived historical v1.0.0 report
  (kept verbatim, with a supersession appendix) — its v1.0.0
  limitations contradicted `QA_TEST_REPORT.md` v1.0.1.
- Stale `MainMenu.luau` comment about Config binding Slam to "E"
  corrected (canonical mapping is Q/F/R since v1.0.1); `README.md`
  solo-test step corrected from "Q / E / R" to "Q / F / R".
- Rebuilt `GlitchTide.rbxl` with Rojo 7.7.1 (333,816 bytes) and
  verified the built hierarchy two ways: by decompressing the `.rbxl`
  (real `StarterGui` class present, no `StarterGui`/`ui` folders,
  `MainMenu` once, PRNT pair count 58 → 56) and from Rojo's own
  `/show-instances` tree (`StarterGui → MainMenu`;
  `StarterPlayer → StarterPlayerScripts → Controllers/ + Main`;
  `Workspace` empty). No Studio playtest was run — see
  `QA_TEST_REPORT.md`.

## [1.0.1] — 2026-11-18

QA pass over v1.0.0: four fix workers (camera, core loop,
powers/mutations/tide, UI/security) plus a final integration pass.
Verified in this workspace: `luau-compile` 48/48, `luau-analyze`
(Roblox-definition noise only), Rojo 7.7.1 build to `GlitchTide.rbxl`
(341,613 bytes, all 48 script sources verified inside), a 47-check
Python static harness (all pass) and a 33-check Lune pure-logic harness
(all pass). No Studio playtest was run — see `QA_TEST_REPORT.md`.

### Camera
- Stuck-camera bug fixed: the default camera only rebinds on
  `CharacterAdded`, but `CharacterService` morphs by destroying the
  avatar and reassigning `player.Character` (which does not fire
  `CharacterAdded`), so the camera stayed frozen at spawn.
  `CameraController` now owns the binding explicitly (rebind on
  `CharacterAdded` + `player.Character` change + respawn + teleport +
  death/recovery, 0.5 s watchdog, snap when > 50 studs from the root),
  and `CharacterService` makes morphed models valid camera subjects
  (PrimaryPart = HumanoidRootPart, unanchored root, parent-before-destroy
  order). Only `CameraController` / `EffectsController` touch the camera.
- Camera regression test added as `GROK_BUILD_HANDOFF.md` §1 (run first).

### Core loop
- `CharacterService` / `DataService` / `CombatService` /
  `ProgressionService` / client controllers defaulted to the removed id
  `tung_tung` — now `wobble_waffleton` everywhere.
- `PlayerStats` was declared a RemoteFunction but used as a RemoteEvent
  everywhere — now a RemoteEvent in `Remotes.luau`.
- `QuestUpdate` and `EquipCosmetic` remote names referenced but missing —
  added (`EquipCosmetic` reserved/inert; cosmetics equip via the
  `SelectCharacter` envelope).
- `Config.ConveyorRarityWeights` covered 6 tiers only — now all 10 tiers,
  aligned with `Config.RarityWeights` (sums to 1.0).
- `CombatService` was never initialised — now initialised in
  `Main.server.luau` after `GameManager.Init`.
- `CombatService` / `EconomyService` called the non-existent
  `Remotes.GetRemotes()` — now per-name `GetRemote` / `GetFunction`.
- `Config.MaxBasePlots` was 8 while `MaxPlayers` is 12 — now 12 = 12.
- Raid defense prices were hardcoded in `RaidService` — now read from
  `Config`.

### Powers / mutations / tide / raids / progression
- Fusion was random (60% level-up / 25% mutation / 15% "next rarity",
  wrong ladder, same-character inputs that no recipe accepts, no cost) —
  now recipe-based: two *unplaced* Brainrots → the recipe's result at
  level 1, for 1,000 coins + 25 Mutation Crystals, with refund + restore
  on failure.
- `MutationService` fallback table was a different 8-entry table with
  wrong costs/multipliers plus phantom Magma/Spectral mutations — now an
  exact copy of the shared 12 (Magma/Spectral survive only in comments).
- `MutationService.loadMutationTable` mapped shared `IncomeMultiplier`
  to nothing (all mutations at 1×) and kept capitalised ids unfindable —
  fixed (lowercase normalisation, `IncomeMultiplier`, rebirth gating
  Void/Celestial 1, Rainbow 2). Mutation compatibility is now enforced.
- "Epic Discovery" quest fired for Rare (rank ≥ 3) — now Epic+ (rank ≥ 4).
  Zone quests (Forbidden Rift / Mutation Lab) had no caller — a position
  poll in `QuestService` now records visits.
- Tide variations Double / Dark / GiantBoss had no behaviour — demoted to
  `Config.TideVariationsDisabled`; playable rotation is Standard / Fast /
  Toxic / Frozen / Meteor, each with real behaviour in `TideService`.
  Boss tides now run every 5th tide (`Config.EventSchedule.BossTideEvery`).
- `QuestService` now delegates XP to `ProgressionService` (single level-up
  reward path) and `TideService` now knows about `BossService` — both
  setters existed but were never called by `GameManager.wireCrossLinks`.
- Rebirth fixed: v1.0.0 enforced 8 *placed* (not 10 distinct), paid 0 gems
  (Config promises 25), granted +25% income (Config says +10%), had no
  cap, and wiped the whole collection — now level 25 + 100,000 coins +
  10 distinct owned, +10% income, +2 slots, +25 gems, max 10 rebirths,
  owned characters kept.
- Canonical keybinds: Q primary, F Slam, R Heal, E Interact, G Drop,
  1/2/3 loadout — `Config.AbilitySlots`, `Config.Keybinds` and
  `Utils.GetKeybinds` now agree; the old Q/E/R mapping is gone.

### UI / security
- Shop **Mutations** tab added (Mutation Lab: placed Brainrot + mutation
  for Mutation Crystals, server-validated).
- `SecurityService.BurstLimit` added; buy/select remotes are now
  burst-limited (see integration fixes below).

### Integration fixes (final pass)
- `CharacterService` still called `Remotes.GetRemotes()` — fixed to
  per-name `Remotes.GetRemote` (`CharacterService.luau:48`); `EconomyService`
  verified already fixed.
- `RequestQuests` had no server `OnServerInvoke` — `QuestService` now
  returns `GetQuests(player)` (`QuestService.luau:546`) and pushes
  `QuestUpdate` shortly after join (`QuestService.luau:410-419`);
  `QuestController`'s stale "no server handler yet" warning removed.
  `RequestCollection` → `ProgressionService.GetCollection`
  (`ProgressionService.luau:679`) and `RequestEvents` →
  `EventService.GetActiveEvent` (`EventService.luau:594`) wired the same
  way; `Remotes.luau` contract comment updated.
- Fusion had no client UI — Shop **Fusion** tab added
  (`ShopController.luau:472`, five tabs now): lists unplaced inventory
  (new `Unplaced` field in `BaseService.GetBase`) + all 10 recipes from
  `Mutations.FusionRecipes`, fires `FuseBrainrot {InstanceIdA,
  InstanceIdB}` with a 5 s no-reply watchdog, clears on the
  `FusionResult` push. `FusionService` logic untouched.
- `EventUpdate` + `TideSurvivor` were fired but never listened to —
  `HUDController` now listens (`HUDController.luau:1052,1085`) and shows
  them via the existing `ShowEventBanner`.
- Golden Hour 2× income existed on `EventService` but `BaseService` never
  applied it — wired via `BaseService.SetEventService`
  (`BaseService.luau:653`, `GameManager.luau:517`); stacks with, and never
  double-applies, the Tide multiplier.
- `BuyCharacter` / `SelectCharacter` had no burst limit —
  `SecurityService.BurstLimit(player, key, 5, 5)` now rejects bursts with
  a clear message (`EconomyService.luau:130`,
  `CharacterService.luau:377`); purchase/equip logic untouched.
- `InteractType` / `InteractId` attribute scan removed from
  `InteractionController` (option b): no producer ever set those
  attributes. ProximityPrompts are the sole interaction path.
- `default.project.json` used `$class` — Rojo 7.7 rejects it ("Failed to
  deserialize JSON"); corrected to `$className`. `rojo build` now
  succeeds; `GlitchTide.rbxl` is included in this delivery.

### Known limitations (still open — see `QA_TEST_REPORT.md`)
- No Studio playtest has been run; camera regression test + acceptance
  scenario are Grok Build's job.
- Trading intentionally not implemented; offline income not implemented.
- Tide variations Double / Dark / GiantBoss are data-only.
- Character animation is procedural bob/tween, not keyframed; controller
  input is not bound; no separate Achievements module; no World Selection.

## [1.0.0] — 2026-11-18

Initial complete build.

### Added
- Core heist loop: central conveyor market, buying, carrying, placing
  Brainrots in a personal base, and passive per-second income.
- 18 Brainrots across six rarities (Common, Rare, Epic, Legendary,
  Mythic, Glitch), each with a defence trait, a primary ability, and
  per-second income defined in `src/shared/Characters.luau`.
- Personal bases: 4 starting slots (upgradeable to 10), income
  multiplier, locks, turrets, and conveyor-luck upgrades.
- Stealing and defence: 3-second steal channel, 60-second steal
  cooldown, slowed carrying (0.6× speed), drop-on-knockout, 30-second
  base locks, and turrets.
- Glitch Tide event: every 240 seconds, 30-second warning, 60-second
  duration, Glitched Brainrots flood the conveyor (35% glitch chance)
  and all income doubles.
- Glitched (mutated) Brainrot variants: 1.5× price, bonus income.
- Powers: 18 character primary abilities (Q) plus generic Dash (Q),
  Slam (E), and Heal (R).
- Brainrot levelling: +25% income per level, max level 5.
- Combat and PvE: arena combat, knock-out / assist / win rewards,
  XP and levels (cap 100), PvE waves every 90 seconds with a boss
  every 5th wave, rounds (180 s), lobby (20 s), intermission (15 s),
  Red vs Blue teams (max 12 players).
- Persistence: DataStoreService saves (autosave every 120 s, save on
  leave, flush on shutdown via `BindToClose`), with `pcall`-guarded
  calls, per-player keys (`GlitchTide_Data_v1`), and a leaderboard
  store (`GlitchTide_Leaderboard_v1`).
- Rojo 7.7 project structure (`default.project.json`, `rojo.toml`),
  runtime-built map (`MapBuilder`), client controllers (animation,
  effects, HUD, sound), and main menu UI.
- Documentation: `README.md`, `GROK_BUILD_HANDOFF.md`,
  `THIRD_PARTY_NOTICES.md`, this changelog, and the MIT `LICENSE`.

### Known limitations
- **No Studio playtest has been run.** Behaviour in Studio is unverified
  until Grok Build runs the acceptance scenario in
  `GROK_BUILD_HANDOFF.md` §3.
- **No `.rbxl` place file is included.** Grok Build generates it with
  `rojo build -o GlitchTide.rbxl`.
- **DataStore testing in Studio requires** Game Settings → Security →
  Enable Studio Access to API Services.
- **Trading is intentionally omitted** for safety — no player-to-player
  trading system is included in this build.
- **Ability keybinds** — Q primary, F Slam, R Heal, E Interact
  (`AbilityController`); `Config.AbilitySlots` still lists the older
  Q/E/R generic mapping.
- **8 base plots vs MaxPlayers 12** — the 9th+ concurrent player gets no
  base; see `README.md` §15.
- **Character roster is original** — no Italian Brainrot meme names or
  designs are used (see `THIRD_PARTY_NOTICES.md`).
