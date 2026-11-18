# Changelog — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

All notable changes to this project are documented here.
Versioning follows Semantic Versioning (MAJOR.MINOR.PATCH).

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
