# QA Test Report — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

**Version:** 1.1.0 — 2026-11-19 (EXTREME EXPANSION on v1.0.2; current release).
**Scope:** everything in `~/workspace/your_files/glitch-tide-v1.1/`
(68 Luau files, 42,045 lines) after the v1.1 expansion workstreams
(audit, visual overhaul, 9 new Brainrots, 2 new regions, 10 working tide
variants, Laboratory / Expeditions / Territory / Companions / Secrets,
deeper progression, 54 quests, 2 new bosses, 5 new powers, UI redesign,
sound, multiplayer hardening).
**Current-release status:** §§9–13 are the current v1.1.0 record
(audit summary, integration, v1.1 tests T12–T20, v1.1 bug list B1–B17,
delivery counts + paid-eligibility statement).
**§§1–8 below are HISTORICAL v1.0.2 evidence** — preserved verbatim as
history (the v1.0.1 final integration pass and the v1.0.2 packaging
correction). Do not read their counts (48 files, 26,062 lines,
18 Brainrots, 16 quests, 12 powers, 21 services, 14 controllers) as the
current release; the current counts are 68 files, 42,045 lines,
27 Brainrots, 54 quests, 17 playable powers, 30 services,
20 controllers — see §13.
**Honesty rule for this report:** a test is listed as passed only if a
tool in this workspace actually ran it and returned the result. Nothing
here claims a Studio playtest, a screenshot, a recording, or a live
DataStore round-trip — none of those happened in this workspace.

## 1. Camera — root cause and fix (HISTORICAL — v1.0.2 evidence)

### Root cause
The default Roblox camera only (re)binds its subject when the engine
spawns a character (`CharacterAdded`). `CharacterService` morphs the
player by **destroying** the default avatar and assigning
`player.Character = <custom Brainrot model>` — that assignment does
**not** fire `CharacterAdded`. So the default camera kept pointing at
the destroyed Humanoid and stayed frozen at the spawn point while the
player walked away. Secondary contributors: the morphed model was not
guaranteed to be a valid camera subject (no PrimaryPart / anchored
root possible), and the old model was destroyed before the new one had
replicated, leaving the client briefly pointing at a destroyed Humanoid.

### Fix (camera worker, verified in code — not in Studio)
- `src/client/Controllers/CameraController.luau` — a camera manager that
  owns the binding explicitly: rebind on every `CharacterAdded` AND on
  every `player.Character` property change (`:243`), on respawn, on
  teleport (snap when the camera is > 50 studs from the root), and on
  death/recovery; waits for the live Humanoid + HumanoidRootPart with a
  5 s timeout (never an infinite yield); sets `CameraType = Custom` and
  `CameraSubject = <live Humanoid>` (`:166-167`); a 0.5 s watchdog
  (`WATCHDOG_INTERVAL`, `:46`, loop `:273`) rebinds if the subject is
  nil, dead, a different Humanoid, or the CameraType drifted to
  Scriptable. It also rebinds when `CurrentCamera` itself changes
  (`:259`). Once bound it never fights the default camera: the default
  camera script drives CFrame every frame; this file only writes CFrame
  for the one-off snap on (re)bind.
- `src/server/Services/CharacterService.luau:301-302,325` — the morphed
  model is made a valid camera subject: `PrimaryPart = HumanoidRootPart`,
  root unanchored, and the new model is parented to `workspace` *before*
  the old model is destroyed and `player.Character` is reassigned.
- `src/client/Controllers/EffectsController.luau` — the only other file
  touching the camera: shake only (BindToRenderStep, offset-only, never
  rebinds the subject).

### Verification status
- **Static:** grep confirms only `CameraController` (11 refs) and
  `EffectsController` (2 refs) touch `CurrentCamera` / `CameraType` /
  `CameraSubject` across `src/` (see §4, check 11). `luau-compile`
  passes on both files.
- **NOT verified in Studio.** The regression test that must run first in
  Studio is `GROK_BUILD_HANDOFF.md` §1: spawn → walk 100 studs → morph
  switch → teleport blink → death/respawn → 60 s idle. Until it passes,
  the camera fix is code-reviewed, not proven.

## 2. Fixed-bug list (grouped by area) (HISTORICAL — v1.0.2 evidence)

File:line citations are to the fixed code (or the comment documenting the
fix) as it stands in v1.0.1. "Prior worker" items are the fixes the four
earlier workers landed; they were re-verified here by grep/read and by
the harnesses in §4, not re-implemented.

### 2.1 Camera (prior worker)
| # | Bug | File:line | Root cause | Fix |
|---|---|---|---|---|
| C1 | Camera frozen at spawn after morph | `CameraController.luau:5-30,166-167,243,259,273` | Default camera rebinds only on `CharacterAdded`; morph reassigns `player.Character` without firing it | Explicit camera manager: rebind on CharacterAdded + `Character` property change + respawn + teleport + death, 0.5 s watchdog, snap > 50 studs |
| C2 | Morphed model not a valid camera subject | `CharacterService.luau:301-302,325` | No PrimaryPart guarantee; old model destroyed before the new one replicated | PrimaryPart = HumanoidRootPart, root unanchored, parent new model before destroying the old one |

### 2.2 Core loop (prior workers)
| # | Bug | File:line | Root cause | Fix |
|---|---|---|---|---|
| L1 | Removed id `tung_tung` as fallback in 8 files | `CharacterService.luau:115,336` (representative) | Roster replacement left a stale default id | Replaced with starter `wobble_waffleton` everywhere |
| L2 | `PlayerStats` declared RemoteFunction, used as RemoteEvent everywhere | `Remotes.luau:24,118,128` | Wrong table in `Remotes.luau` | Moved to `EVENT_NAMES` |
| L3 | `QuestUpdate`, `EquipCosmetic` referenced but undeclared | `Remotes.luau` Names table | Names missing from the single source of truth | Added (`EquipCosmetic` reserved/inert; cosmetics equip via `SelectCharacter` envelope) |
| L4 | `ConveyorRarityWeights` covered 6 tiers only | `Config.luau:134-145` | Table predated the 10-tier ladder | All 10 tiers, aligned with `RarityWeights` (sums to 1.0) |
| L5 | `CombatService` never initialised | `Main.server.luau:21,47` | No caller ever ran `CombatService.Init` | Initialised after `GameManager.Init` |
| L6 | `Remotes.GetRemotes()` called (does not exist) | `CombatService.luau:27-33`, `EconomyService.luau:20-24` | Wrong Remotes API assumed | Per-name `Remotes.GetRemote` / `GetFunction` |
| L7 | 8 base plots vs MaxPlayers 12 | `Config.luau:371` | Plot count never raised with player cap | `MaxBasePlots = 12` |
| L8 | Raid defense prices hardcoded in `RaidService` | `Config.luau:164` | Tuning lived in service code | Prices read from `Config` |
| L9 | `default.project.json` used `$class` | `default.project.json` (integration pass, §2.6) | Rojo 7.7's schema key is `$className` | Corrected to `$className`; `rojo build` now succeeds |

### 2.3 Powers / mutations / tide / raids / progression (prior workers)
| # | Bug | File:line | Root cause | Fix |
|---|---|---|---|---|
| P1 | Fusion was random (60% level-up / 25% mutation / 15% "next rarity"), wrong ladder, same-character inputs no recipe accepts, no cost charged | `FusionService.luau:25-42,192-195` | v1.0.0 ignored the recipe table entirely | Recipe-based: two *unplaced* Brainrots → recipe result at level 1, 1,000 coins + 25 crystals, refund + input restore on failure |
| P2 | `MutationService` fallback table was a different 8-entry table + phantom Magma/Spectral | `MutationService.luau:46-70` | Fallback diverged from shared data | Exact copy of the shared 12; Magma/Spectral survive only in comments |
| P3 | `loadMutationTable` read `IncomeMult` (shared uses `IncomeMultiplier`), capitalised ids unfindable | `MutationService.luau` (see `TEST_REPORT.md` §4.6) | Field-name / case mismatch | Lowercase normalisation, reads `IncomeMultiplier`, rebirth gating Void/Celestial 1, Rainbow 2 |
| P4 | Mutation compatibility never enforced | `MutationService.luau:457` | Check missing entirely | Compatibility check added (character can only take listed mutations) |
| P5 | "Epic Discovery" quest fired for Rare | `QuestService.luau:20,499` | Rank threshold ≥ 3 instead of ≥ 4 | Requires Epic+ (rank ≥ 4) |
| P6 | Zone quests (Rift / Lab) had no caller | `QuestService.luau` position poll in `Init` | No service ever reported visits | 5 s poll records visits within 20 studs of the zone centres |
| P7 | Tide variations Double / Dark / GiantBoss had no behaviour | `Config.luau:278-285`, `TideService.luau:11-13` | Listed in rotation with no implementation; `ForceStart` rejected them as unknown | Demoted to `Config.TideVariationsDisabled`; playable rotation is Standard / Fast / Toxic / Frozen / Meteor |
| P8 | No boss tides | `TideService.luau` (boss-every-5th) | Boss only spawned on its own 30-min timer | Every 5th tide spawns the world boss (`Config.EventSchedule.BossTideEvery`) |
| P9 | `QuestService` never delegated XP to `ProgressionService`; `TideService` never knew `BossService` | `GameManager.luau:493-498` | Setters existed but `wireCrossLinks` never called them | Both setters added to the cross-link pass |
| P10 | Rebirth enforced 8 *placed*, paid 0 gems, +25% income, no cap, wiped the collection | `ProgressionService.luau:20,64-68,315,361-362` | Implementation contradicted `Config` | Level 25 + 100,000 coins + 10 *distinct* owned; +10% income, +2 slots, +25 gems, max 10 rebirths, owned characters kept |
| P11 | Keybinds disagreed (`Config.AbilitySlots` Q/E/R vs client Q/F/R/E) | `Config.luau`, `Powers.luau:13`, `AbilityController.luau:5` | Two mappings coexisted | One canonical table: Q primary, F Slam, R Heal, E Interact, G Drop, 1/2/3 loadout |

### 2.4 UI / security (prior workers)
| # | Bug | File:line | Root cause | Fix |
|---|---|---|---|---|
| U1 | Mutations had no client UI | `ShopController.luau:75,337-342` | No Mutations tab existed | Shop **Mutations** tab: pick placed Brainrot, apply mutation for crystals, server-validated |
| U2 | No burst limiting on purchase/equip remotes | `SecurityService.luau:127` | `BurstLimit` existed but nothing called it | Helper added (see I6 for the wiring) |

### 2.5 Shop / quest remotes (integration pass — this report)
| # | Bug | File:line | Root cause | Fix |
|---|---|---|---|---|
| I1 | `CharacterService` still called `Remotes.GetRemotes()` | `CharacterService.luau:47-56` (helper), `:377` (burst check) | Same wrong-API pattern as L6, missed in the core-loop pass; the old code silently fell back to the module table, so `remotes.SelectCharacter` was nil and the handler never connected | Per-name `getRemote(name)` via `Remotes.GetRemote`; `Init` polls for `SelectCharacter` directly. `EconomyService` verified already fixed (only a comment mentions `GetRemotes()`) |
| I2 | `RequestQuests` had NO server `OnServerInvoke` | `QuestService.luau:546`, `:410-419` | Handler never written; `InvokeServer` errored and a fresh client only learned quests when progress changed | `OnServerInvoke = GetQuests(player)`; `QuestUpdate` push shortly after join (`PlayerAdded` + already-present players). `QuestController.luau` header/status/print updated — stale "no server handler yet" warning removed |
| I2b | `RequestCollection` / `RequestEvents` also had no handler | `ProgressionService.luau:679`, `EventService.luau:594` | Getters existed (`GetCollection`, `GetActiveEvent`) with no wire | `OnServerInvoke` set to the existing getters (same polling pattern). No client caller exists yet for either — they are wired and ready, not reserved. `Remotes.luau` contract comment updated |
| I3 | Fusion had NO client UI | `ShopController.luau:472` (`rebuildFusion`), `:692-693`, `:879` (tab list) | `FusionService` had a server handler but nothing in-game could reach it | Shop **Fusion** tab (5 tabs now): lists unplaced inventory + all 10 recipes from `Mutations.FusionRecipes`, fires `FuseBrainrot {InstanceIdA, InstanceIdB}` (the exact payload `FusionService` expects), 5 s no-reply watchdog, clears on the `FusionResult` push. Supporting change: `BaseService.GetBase` now exposes `Unplaced` instances (read-only copy from `MutationService.GetInstances`). `FusionService` logic untouched |
| I4 | `EventUpdate` + `TideSurvivor` fired but NO client listened | `HUDController.luau:1052` (`EventUpdate`), `:1085` (`TideSurvivor`) | Listeners never written; `ShowEventBanner` existed with no caller | Both listeners added; events show via `ShowEventBanner` (event name/phase/multiplier; personal "You survived the X tide!" line when the local player is in `Survivors`). Server firing untouched |
| I5 | Golden Hour 2× income never applied | `BaseService.luau:397-410` (helper), `:468` (applied), `:653` (setter); `GameManager.luau:517` (wiring) | `EventService.GetIncomeMultiplier()` existed but `BaseService` never read it | `BaseService.SetEventService` wired in `GameManager.wireCrossLinks` (also added to the shared setter table); income now multiplies by the event multiplier. Tide multiplier verified already applied via `SetTideMultiplier` (`GameManager.luau:354`) and NOT double-applied |
| I6 | `BuyCharacter` / `SelectCharacter` had no burst limit | `EconomyService.luau:130`, `CharacterService.luau:377` | `SecurityService.BurstLimit` existed but nothing called it (U2) | `BurstLimit(player, key, 5, 5)` at the top of both handlers; bursts rejected with a clear warn + (SelectCharacter) a `CharacterSwitchFailed` "too many requests" reply. Purchase/equip logic untouched; the existing 0.25 s buy debounce is kept |
| I7 | `InteractType` / `InteractId` attribute scan found nothing | `InteractionController.luau:178-185` (stub), header comment | No producer ever set those attributes (`MapBuilder`, `ConveyorService`, `NPCService` never tag parts); the scan walked descendants 4×/s and always returned nil | Option (b): scan removed, `findNearest` is now an intentionally inert stub returning nil; ProximityPrompts documented as the sole interaction path. Behaviour-preserving — E with nothing nearby already showed only the "nothing nearby" hint |

## 3. Tests actually executed (tool + result) (HISTORICAL — v1.0.2 evidence)

All run 2026-11-18 in this workspace, after the 7 integration fixes.

| # | Test | Tool / command | Result |
|---|---|---|---|
| T1 | Luau compile, every file | `/tmp/luau-compile <file>` for all 48 `src/**/*.luau` (Luau 0.747 toolchain, reused from `/tmp`) | **PASS 48/48, 0 failures.** (First attempt used a wrong `--mode=binary -o` command line and failed on all files — a wrong invocation, not a code failure; re-run with the bare form, all pass.) |
| T2 | Luau strict analysis | `/tmp/luau-analyze <file>` per file (all 48) | **PASS with documented noise.** Diagnostics are dominated by missing Roblox definitions: "Unknown global" (`game`, `Enum`, `Color3`, …), "Unknown type" (`Model`, `Humanoid`, …), "Unknown require" (requires via `ReplicatedStorage:WaitForChild` / `script.Parent`), and `*error-type*` cascades from those. Non-noise items are pre-existing patterns, all spot-checked: `pcall` reported as "returns 1 value" (untyped `pcall` without Roblox defs), `gui = Instance.new(...)` cascades from unknown `Instance`, a pre-existing unused `Utils` import in `CharacterService`, a pre-existing unused `timerFrame` in `HUDController`. **Zero non-noise diagnostics on any line edited by the integration pass** (checked: `ShopController` fusion range 472–617 clean; `HUDController` event listeners clean; all 7 fix files clean apart from the pre-existing items above). No real defect found; nothing changed as a result of this test. |
| T3 | Rojo build | Rojo 7.7.1 downloaded from GitHub releases (`rojo-7.7.1-linux-x86_64.zip`); `rojo build -o /tmp/GlitchTide.rbxl` in the project root | **PASS — `GlitchTide.rbxl` built, 341,613 bytes.** First attempt failed: `default.project.json` used `$class`, which Rojo 7.7 rejects ("Failed to deserialize JSON" — reproduced even on a minimal project with Rojo 7.7.1; Rojo 7.5.1 gave the precise error `invalid type: string "DataModel", expected struct ProjectNode`). Root cause was the project file, confirmed against the Rojo docs (`$className` is the schema key). Fixed to `$className` (fix L9); build then succeeded. The `.rbxl` was verified by parsing its chunks (LZ4-compressed PROP chunk, 853,191 bytes decompressed) and confirming all 48 script sources are embedded, including every v1.0.1 fix marker (`rebuildFusion`, `SetEventService`, `BurstLimit`, `RequestQuests`, `FuseBrainrot`, `TideSurvivor`, `EventUpdate`, `Unplaced`). Copy kept at `GlitchTide.rbxl` in the project root and included in the final ZIP. |
| T4 | Python static harness (47 checks) | `/tmp/glitch_tide_harness.py` (read-only regex/JSON checks over `src/`) | **PASS 47/47.** Covers: project JSON valid + `$className` + service mapping; 18-character roster with all AbilityIds resolving to Powers; `RarityWeights` sum exactly 1.0 over 10 tiers; all referenced remote names exist in `Remotes.luau`; every non-reserved remote referenced by server or client (`BossUpdate` / `SynergyUpdate` / `SettingsUpdate` are documented in `Remotes.luau` as fired-by-no-service-yet / unwired, and are treated as such); `OnServerInvoke` present for `RequestQuests` / `RequestCollection` / `RequestEvents` / `RequestShop` / `RequestBase`; all `WaitForChild` / `require` targets exist; keybinds Q/F/R/E/G + loadout 1/2/3 consistent across `Config.Keybinds` / `AbilitySlots`; no TODO/FIXME/STUB in `src/`; no copyrighted Italian Brainrot names; no "Brainrot Battle Arena" branding in `src/`; `MaxBasePlots == MaxPlayers == 12`; all 5 playable tide variations have behaviour in `TideService`; Double/Dark/GiantBoss data-only in `TideVariationsDisabled`; Magma/Spectral only in comments; camera touched only by CameraController/EffectsController (13 refs); all 7 integration fixes present; all 10 fusion recipe ResultIds are real characters. Three first-run failures were harness bugs, not game bugs (roster regex also matched `AbilityId` values; `BossUpdate`/`SynergyUpdate`/`SettingsUpdate` not recognised as documented-unwired; `WaitForChild` targets `PlayerGui`/`Humanoid`/remote names not in the module set) — fixed in the harness, re-run 47/47. |
| T5 | Lune pure-logic harness (33 checks) | Lune 0.11.1 downloaded from GitHub releases; `/tmp/lune_harness/main.luau` loads the 9 shared modules with stubbed Roblox globals (`game`, `Color3`, `Enum`, `Vector3`, `BrickColor`, …) and exercises pure logic | **PASS 33/33.** Covers: `GameVersion` 1.0.1; rarity weights sum 1.0; plots/players 12; fusion costs 1000 + 25; rebirth requirements (Level 25, 100,000 coins, 10 distinct); playable tide variations + weights; 18-character roster, 10 rarities, positive income, AbilityIds resolve, `GetRarityRank("Epic") >= 4`; 12 mutations, no Magma/Spectral; fusion recipe lookup incl. order-independence and unknown-pair → nil; all 10 recipe results real; `FusionCost` present/nil cases; `XPForLevel` increasing; `CoinsForWave` increasing; KO reward streak scaling; synergy bonus 0 for empty list, 2.15 for the full roster; income formula (level-5 = 2× level-1, Golden 2.5×, Tide 2× × Golden Hour 2× = 4×); remotes names; keybinds Q/F/R/E/G + loadout 1/2/3. Two first-run failures were harness bugs (field is `Brainrots`, not `DistinctBrainrots`; loadout keys live in `Config.Keybinds`, not `Utils.GetKeybinds`) — fixed in the harness, re-run 33/33. Quest progress, rebirth granting, and tide phase transitions were **not** exercised here: `QuestService` / `TideService` / `ProgressionService` need live Roblox services and cannot run under Lune — see §6. |
| T6 | Camera grep | `grep -rn "CurrentCamera\|CameraType\|CameraSubject" src/` | **PASS.** 13 references, all in `CameraController.luau` (11) and `EffectsController.luau` (2). |
| T7 | ZIP integrity | Unzip `GLITCH_TIDE_FINAL_QA.zip` to a fresh temp dir, compare the tree with the project | **PASS** — see §7 for counts. |

### Failed tests
**None.** No test executed in this pass failed on game code. The only
failures encountered were wrong tool invocations / harness bugs (T1
command line, T3's `$class` project-file defect which was itself a real
bug and was fixed as L9, T4/T5 harness field-name bugs), all resolved
and re-run green. See the per-test notes above.

## 4. Partially implemented features (HISTORICAL — v1.0.2 evidence)

These exist in code but with a known gap. None is new in v1.0.1; all are
carried forward from v1.0.0 and recorded here so they are not mistaken
for complete features.

| Feature | Gap |
|---|---|
| Character animations (idle/walk/dance/celebrate) | Procedural bob via `CharacterModels.GetIdleOffset` + `AnimationController` tween/bob; no keyframed Roblox animations (no external animation IDs) |
| Menus (Collection, Inventory, Market, Base, Abilities, Mutation Lab, Quests, Events, Rebirth, Settings, Leaderboards, Achievements, Cosmetics) | All listed panels exist except: Trading (intentionally absent — no button), Achievements (shown inside Quests/Collection panels, no separate module), World Selection (single world; additional dimensions from the spec are not built) |
| Mobile + desktop + controller | Desktop WASD/mouse, E interact, G drop, Q/F/R powers, menu hotkeys; mobile touch buttons for interact/abilities/menus. Controller input is not explicitly bound |
| Performance measures | Anchored static geometry, ≤ 12 lights, pooled/staggered NPC loops, cleanup of temporary objects; no StreamingEnabled tuning done in Studio (unverified) |
| `BossUpdate` / `SynergyUpdate` remotes | Declared in `Remotes.luau`; fired by no service yet. Clients degrade gracefully |
| `RequestCharacter` (legacy) | Declared; no server handler, no client caller. `Main.client` still waits for it |
| `UsePower` remote | Declared; `AbilityService` uses `UseAbility` instead; nothing fires `UsePower` |
| `SettingsUpdate` remote | Declared; no settings sync exists; mute/volume are client-local |
| `RequestCollection` / `RequestEvents` | Wired in v1.0.1 (I2b) but no client caller invokes them yet — the Collection UI reads `RequestShop` and nothing polls the active event. Ready, not yet used |
| Secret Merchant event | Flag works; no NPC model while `NPCService` is absent (see `EventService` header) |
| Fusion tab inventory | Shows unplaced instances only; a player whose Brainrots are all placed sees the recipes but nothing to fuse (by design — the server rejects placed inputs) |

## 5. Not implemented (intentional) (HISTORICAL — v1.0.2 evidence)
- **Trading** — intentionally omitted for safety. `TradeRequest` /
  `TradeAccept` / `TradeCancel` exist as reserved names only; no handler
  moves items or currency between players.
- **Offline income** — `DataService` tracks `LastLogin` and pays a daily
  bonus, but no offline-income payout is calculated on rejoin.
- **Tide variations Double / Dark / GiantBoss** — data-only in
  `Config.TideVariationsDisabled`; no behaviour, never roll.

## 6. Tests NOT executed (no Studio / live services in this workspace) (HISTORICAL — v1.0.2 evidence)

The following were **not** run and must **not** be reported as passed.
Grok Build must run them in Roblox Studio.

1. Opening `GlitchTide.rbxl` in Roblox Studio; any Studio playtest
   (solo or multi-client), including the camera regression test
   (`GROK_BUILD_HANDOFF.md` §1) and the Part 33/36 acceptance scenario
   (§4): spawn → base → market buy → carry → tide warning → escape →
   place → income → upgrade → ability → mutation/fusion → quest →
   save/rejoin → 2-player raid.
2. `rojo serve` live sync with the Studio plugin.
3. Live DataStore save/load round-trip (needs Studio Access to API
   Services enabled in Game Settings → Security) and `BindToClose`
   behaviour.
4. Multi-client behaviour: 2-player raid (steal + defended steal),
   12-player full server (12 base plots), steal alerts, base locks.
5. Any performance measurement (frame rate, memory, part counts).
6. Quest progress / rebirth granting / tide phase transitions as *live*
   behaviour (their config values and pure-logic helpers were checked
   in T5; the server services themselves need Roblox services and were
   not executed).
7. Any screenshot, video, or recording of gameplay.
8. Publishing, icon/thumbnail upload, or make.fun submission (Grok
   Build's job, not Muse's).

Known Studio-only risks to check first:
- The camera fix (§1) is the highest-risk item — run
  `GROK_BUILD_HANDOFF.md` §1 before anything else.
- Strict-mode type noise from `luau-analyze` (§3, T2) will disappear
  once Roblox definitions are present; if Studio still flags a file,
  check that file first.
- The Fusion tab depends on the `Unplaced` field in the `RequestBase`
  snapshot — if an older `BaseService` is ever restored, the tab shows
  recipes but no inventory.
- `Config.AbilitySlots` and the client binding now agree, but any
  future keybind change must update `Config.Keybinds`,
  `Config.AbilitySlots`, and `Utils.GetKeybinds` together.

## 7. Delivery counts (v1.0.1) (HISTORICAL — v1.0.2 evidence)

- 48 Luau files, 26,062 lines (was 25,625 lines at the start of this
  pass; +437 lines, almost all the Fusion tab, the HUD listeners, the
  remote handlers, and the new comments).
- 18 Brainrots, 12 mutations, 10 fusion recipes, 12 playable powers +
  18 primary abilities, 16 quests, 6 world events, 5 playable tide
  variations (+ 3 data-only), 21 server services, 14 client controllers.
- `GlitchTide.rbxl`: 333,816 bytes (v1.0.2 rebuild; was 341,613 in
  v1.0.1), Rojo 7.7.1, all 48 script sources verified inside
  (decompressed PROP chunk, 853,191 bytes in v1.0.1; hierarchy
  re-verified in v1.0.2 — see §8).
- Final ZIP: `~/workspace/your_files/GLITCH_TIDE_FINAL_QA.zip` (see
  parent report for exact size + SHA-256; verified by unzipping to a
  fresh temp dir and comparing the tree).
- Prior delivery `glitch-tide-brainrot-heist.zip` (v1.0.0, 234 KB) is
  superseded by this ZIP.


## 8. v1.0.2 packaging correction — what changed and how it was verified (HISTORICAL — v1.0.2 evidence)

Packaging only. No gameplay code changed except `Config.GameVersion`
1.0.1 → 1.0.2 and one stale comment in `MainMenu.luau` (see below).
All v1.0.1 fixes are preserved; the v1.0.1 test results in §3 stand,
with the re-runs in T10–T11 below.

### The defect (found by the user on inspecting the v1.0.1 ZIP)

`default.project.json` nested `StarterGui` inside `StarterPlayer`:

```json
"StarterPlayer": { "StarterGui": { "$path": "src/client/ui" },
                   "StarterPlayerScripts": { "$path": "src/client" } }
```

That is not a real Roblox service hierarchy. Rojo built it anyway
(a `Folder` named `StarterGui` under `StarterPlayer`), so `MainMenu`
was never cloned into `PlayerGui` and the main menu never appeared —
and `MainMenu` existed **twice** in the built place (once under the
`StarterGui` folder, once under the `ui` folder that `src/client`
also mapped into `StarterPlayerScripts`). `Main.client.luau:182`
expects `MainMenu` in `PlayerGui` (cloned from the real `StarterGui`
service), so the menu path was broken in v1.0.1 even though every
other system was fixed.

### The fix

`default.project.json` now maps exactly the hierarchy the user
specified:

| Disk path | Roblox service |
|---|---|
| `src/shared` | `ReplicatedStorage` |
| `src/server` | `ServerScriptService` |
| `src/client/ui` | `StarterGui` (direct child of DataModel) |
| `src/client/Main.client.luau` | `StarterPlayer → StarterPlayerScripts → Main` (LocalScript) |
| `src/client/Controllers` | `StarterPlayer → StarterPlayerScripts → Controllers/` |
| `src/map` | `Workspace` (intentionally empty) |

`src/map/README.md` moved to `docs/map.md`, outside the Rojo tree, so
no documentation file lives under `src/` (verified: zero `.md` files
under `src/`; `src/map/` holds only an empty `.gitkeep`). The built
`Workspace` is empty by design — `MapBuilder` constructs the arena at
runtime.
`TEST_REPORT.md` (v1.0.0) was marked as an archived historical report
(banner + supersession appendix mapping each outdated limitation to
its v1.0.1/v1.0.2 fix) — it contradicted this report. Stale
`MainMenu.luau` comment about Config binding Slam to "E" corrected
(canonical Q/F/R since v1.0.1); `README.md` solo-test step corrected
from "Q / E / R" to "Q / F / R".

### Tests executed for v1.0.2

| # | Test | Tool / command | Result |
|---|---|---|---|
| T8 | Rojo rebuild + built-hierarchy verification | `/tmp/rojo-7.7.1/rojo build -o GlitchTide.rbxl` (exit 0, 333,816 bytes, SHA-256 `e7ee556910812649cd1062eb28f74809833afe8815e568ff4f6cbe642c3a48de`); then decompressed the `.rbxl` (LZ4 chunk parse) and checked INST classes + Name PROPs; then read Rojo's own `/show-instances` tree from a local `rojo serve` | **PASS.** Decompressed check: a real `StarterGui` **class** is present (absent in v1.0.1); Folder names are only `Services` and `Controllers` — no `StarterGui` folder, no `ui` folder; `MainMenu` appears exactly once (twice in v1.0.1); no `README` string anywhere in the place; PRNT pair count 58 → 56, exactly the `ui` Folder + duplicate `MainMenu` removed. Rojo's `/show-instances` tree (authoritative, rendered by Rojo itself from the corrected project file) shows: `DataModel → StarterGui → MainMenu (ModuleScript)`; `DataModel → StarterPlayer → StarterPlayerScripts → Controllers/ (14 controllers) + Main (LocalScript)`; `Workspace` with no children; 57 instances total. |
| T9 | Luau compile, all 48 files + edited files | `/tmp/luau-compile` on every `src/**/*.luau` | **PASS 48/48, 0 failures.** (Edited files `Config.luau`, `MainMenu.luau`, `Main.client.luau` compile clean.) |
| T10 | Lune pure-logic harness, re-run on v1.0.2 shared modules | `/tmp/lune_harness/main.luau` with `GameVersion` expectation updated 1.0.1 → 1.0.2; harness copies of the shared modules refreshed from the project (harness-only patch: `require(script.Parent.X)` → `require("./X")`, as in the v1.0.1 run — the project files are untouched) | **PASS 33/33.** (First re-run failed 1 check only because the harness still held a stale copy of `Config.luau` at 1.0.1 — a harness-copy staleness, not game code; refreshed and re-run green. A second run errored on `script.Parent` in the fresh copies until the harness-only require patch was re-applied — same patch the v1.0.1 run used.) |
| T11 | Python static harness, re-run with v1.0.2 project expectations | `/tmp/glitch_tide_harness.py` with 3 new checks: `StarterGui` is a direct DataModel child mapping to `src/client/ui`; `StarterPlayerScripts` is exactly `{Main, Controllers}` with the right paths; `Workspace` maps to `src/map` | **PASS 50/50** (47 original checks + 3 new packaging checks). |

### Failed tests (v1.0.2)
**None.** No test executed in this pass failed on game code. The only
failures encountered were stale harness copies (T10, above), fixed in
the harness and re-run green.

### Not executed (unchanged from §6)
No Studio playtest was run for v1.0.2 either — the hierarchy fix is
verified from the built place file and Rojo's own tree view, not from
a running Studio session. Grok Build must still run the camera
regression test (`GROK_BUILD_HANDOFF.md` §1) and the packaging check
in `GROK_BUILD_HANDOFF.md` §2 (Explorer: `StarterGui → MainMenu`,
`StarterPlayerScripts → Main + Controllers/`, `Workspace` empty)
before playtesting.


## 9. v1.1 audit (Part 1) — summary

Full audit: `docs/AUDIT_V1_1.md` (989 lines, all 48 v1.0.2 scripts).
Solid: DataStore patterns, server-authoritative economy, the v1.0.1
camera fix, the corrected Rojo hierarchy, keybind consistency.
Five most fragile findings (all addressed in v1.1 unless noted):

1. **Attack (melee) and StealBrainrot server handlers had no client
   FireServer calls — dead paths**, despite the menu advertising attack
   and stealing as implemented. Fixed in Wave 3 (firers added).
2. **Rebirth income contradiction** (+10% Config/ProgressionService vs
   +25% BaseService fallback, load-order-dependent) plus two level-up
   implementations with different rewards. Fixed in Wave 2/C:
   Config +10% is the single source of truth on both paths.
3. **Orphan remotes**: BossUpdate/SynergyUpdate never fired/listened;
   UsePower/RequestCharacter/SettingsUpdate unwired;
   RequestCollection/RequestEvents wired server-side but never invoked
   by any client. Fixed in Wave 3 except UsePower/SettingsUpdate/
   SynergyUpdate, which stay unwired by documented decision (see §12).
4. **`SpawnQuestGiver`/`SpawnGuard` had no callers** — NPCService.Init
   spawned nothing; no quest-giver NPC, no base guard. The merchant
   hook now calls `SpawnQuestGiver` (Wave 2/C).
5. **Stale headers, duplicated helpers (~24 files), 445 pcall lines**
   mostly swallowing errors; banked-income cap 10,000 (a top base
   fills it in <1s). Cap fixed in Wave 2/C (now scales with level /
   rebirths / prestige).

Integration contracts the workstreams had to respect (audit §4):
Remotes.luau is the single source of truth (45 names in v1.0.2, 62 in
v1.1); GameManager load order and the OPTIONAL_SERVICES pcall pattern
(a new service needs an OPTIONAL_SERVICES entry AND a `loadOptional`
branch); DataService DEFAULT_DATA shape + owned-instance record;
EconomyService has NO AddCoins/AddGems API (coins via
`DataService.AddCoins`, XP via `ProgressionService.AddXP`, gems/shards/
crystals/tokens are direct field writes); MapBuilder accessors and zone
folders; TideService reads TideChannel's direct BasePart children as
the wave path; new-Brainrot rules (AbilityId must resolve in Powers,
income in rarity bands, MutationCompatibility subset of 12, BodyShape
must match a CharacterModels builder branch); a new power needs a def
in Powers.PlayablePowers AND an effect branch in
`AbilityService.UsePower` (def-only = silently ignored); a new tide
variant needs a Config entry + a `runCycle` behaviour branch + a
VARIATIONS fallback entry.

## 10. v1.1 integration — what was wired (coordinator pass)

- `GameManager`: 9 new services added to OPTIONAL_SERVICES
  (LightingService, EnvironmentService, DimensionsService,
  CompanionService, LaboratoryService, ExpeditionService,
  TerritoryService, SecretService, AchievementService, after
  ProgressionService); explicit `loadOptional` branches for
  LaboratoryService (`Init(_dataService, mutationService,
  _optional["FusionService"])`), TerritoryService
  (`Init(_dataService, _map)`), SecretService
  (`Init(_dataService, npcService)`), AchievementService
  (`Init(_dataService, questService)`) — the generic fallback
  `Init(_dataService, _economyService, _map)` would pass wrong args to
  those four. Lighting/Environment/Dimensions/Companion/Expedition use
  the generic fallback (signatures match).
- `wireCrossLinks` gained `SetLightingService`,
  `SetCompanionService`, `SetDimensionsService`,
  `SetLaboratoryService`, `SetExpeditionService`,
  `SetTerritoryService`, `SetSecretService`, `SetAchievementService`
  (`SetLightingService` is consumed by DimensionsService).
  `IsTideSurfer` callback also consults
  `CompanionService.IsTideProtected` (lazy, pcall-guarded).
- **EquipTitle handler wired** in AchievementService.Init
  (QuestService retry pattern: task.spawn, 50 tries × 0.2 s, warn if
  missing; accepts `{TitleId = id}` table or bare string; ownership
  validated by SetEquippedTitle). AchievementController stale texts
  updated (titles persist; status messages updated).
- **All 6 companion bonuses wired:** IncomeBonus (BaseService via
  EconomyService, Wave 2/C); TideProtection (GameManager IsTideSurfer);
  CarrySpeed (CarryService `SetCompanionService` + `applyCarrySpeed`,
  clamped 0.1–0.75); MutationBonus (BaseService lazy resolver,
  applied in `singleIncome` on BOTH the Economy-mod path and the
  fallback path, mutated instances only, max +0.15); RareDetection
  (ConveyorService `pickRarity`: strongest detection bonus among
  players in-game boosts Epic+ weights on the shared conveyor, capped
  +20%, cached weights table never mutated — per-player roll impossible
  since spawn has no buying player); RaidDetection (RaidService steal
  channel extended: `channelSeconds = STEAL_CHANNEL +
  clamp(GetRaidWarningSeconds(victim), 0, 7.5)`, max 10.5 s).
- Stale `Utils.luau` comment fixed (claimed slam was on "E" — false
  since v1.0.1; now notes Config is canonical Q/F/R).
- D's Lighting-mood partial is resolved by the service existing:
  TideService's `pcall(require(...))` for LightingService now
  resolves, so variant moods use the real service instead of the
  built-in `game.Lighting` tween fallback. D's BossUpdate partial is
  resolved by the Wave 3 HUD listener. C's title-equip partial is
  resolved by the EquipTitle handler above. C's dimension-gate
  fails-open note no longer applies in the shipped wiring
  (ProgressionService is linked). The remaining partials are listed
  in §12.

## 11. Tests actually executed for v1.1

All run 2026-11-18/19 in this workspace, after the integration pass.
Tools were re-downloaded into /tmp (it gets wiped between sessions):
Luau 0.747 (`luau-ubuntu.zip` — the `luau-0.747-linux.zip` asset 404s),
Rojo 7.7.1 (`rojo-7.7.1-linux-x86_64.zip` — the
`rojo-7.7.1-linux.zip` asset name 404s), Lune 0.11.1, Node v24.22.1.

| # | Test | Tool / command | Result |
|---|---|---|---|
| T12 | Luau compile, every file | `/tmp/luau-compile <file>` for all 68 `src/**/*.luau` (Luau 0.747, bare invocation — output bytecode to stdout, exit code checked) | **PASS 68/68, 0 failures.** (First attempt used a wrong `--format=summary` flag the binary rejects — a wrong invocation, not a code failure; re-run bare, all pass.) |
| T13 | Luau strict analysis | `/tmp/luau-analyze --mode=strict <file>` per file (all 68) | **PASS with documented noise (same conclusion as v1.0.1 T2, at larger scale).** 6,764 single-line TypeError diagnostics: 4,514 "Unknown global" (`game`, `task`, `Color3`, `Enum`, `Instance`, `UDim2`, `script`, …), 1,274 "Unknown type" (Roblox classes: `Model`, `Humanoid`, `Frame`, `RemoteEvent`, …), 219 "Unknown require" (requires via `ReplicatedStorage:WaitForChild` / `script.Parent`), 39 `*error-type*` cascades, and ~718 downstream artifacts ("Type 'unknown'/'nil' does not have key …", operators on `unknown`, narrowing "Expected this to be unreachable") — **all rooted in the missing Roblox definitions**. Zero diagnostics independent of the missing defs. The single "Argument count mismatch" diagnostic is a valid `Instance:FindFirstChild(name, true)` call in `CharacterService.luau:123`, flagged only because the analyzer lacks the real Instance type. (An earlier per-file count of "98" was a miscount — `grep -c "error"` matched only lowercase `error`, i.e. `*error-type*` lines; the correct total is 6,764. Nothing was hidden; the classification above is from the full output, saved at `/tmp/analyze_all.txt` for this run.) No real defect found; nothing changed as a result of this test. |
| T14 | Python static harness (70 checks) | `python3 scripts/harness-python.py` (read-only regex/JSON checks over `src/`; v1.1 update: 50 v1.0.2 checks with expectations moved to v1.1 + 20 new checks 51–70) | **PASS 70/70.** Covers: project JSON valid + `$className` + service mapping; 27-character roster with all AbilityIds resolving to Powers; `RarityWeights` sum 1.0 over 10 tiers; 10 tide variants with behaviour in TideService; `TideVariationsDisabled` deleted; 19 fusion recipes, all results real; 54 quests; 17 playable powers; 24 achievements + 13 titles; 6 expeditions; 7 territories; all 17 v1.1 remote names; GameManager registration of all 9 new services; EquipTitle handler; all 6 companion bonuses wired; Attack/Steal firers; RequestCollection/RequestEvents callers; BossUpdate listener; SpawnEffect dual-form; no `rbxassetid://` in code; stale Utils comment gone; DataService v1.1 fields; docs exist. First run: 69/70 — check 65 failed on two `rbxassetid://` mentions inside `SoundController.luau` **comments** (explaining that no invented IDs are used). That was a harness false positive, not game code; the check now strips `--` comments before searching. Re-run 70/70. The two make.fun-package-only checks from v1.0.2 (vendor file, PLAY.json.template) were replaced by GameManager registration + EquipTitle checks — they belong to the competition package, not the game tree. |
| T15 | Lune pure-logic harness (40 checks) | `/tmp/lune-0.11.1/lune run scripts/harness-lune/main.luau` (loads the 15 shared modules with stubbed Roblox globals; refresh.sh re-copies `src/shared/*.luau` with the harness-only require patch) | **PASS 40/40.** Covers: GameVersion 1.1.0; rarity weights sum 1.0; plots/players 12; fusion costs; rebirth requirements; 10 tide variants, weights sum 100; 27-character roster, 10 rarities, positive income, AbilityIds resolve; 12 mutations, no Magma/Spectral; 19 fusion recipes incl. order-independence; FusionCost present/nil; XP/wave/KO scaling; synergy 0 for empty list, **2.8 for the full roster** (was 2.15 at 18 characters — recomputed from the code, not guessed); income formula; remotes; keybinds; 9 new characters resolve; 17 playable powers, every cooldown ≥ 3 s; 15 CompanionAbility entries; `TideVariationsDisabled` deleted; Dimensions Abyssal + Skyfall; 6 expeditions, 24 achievements, 13 titles; v1.1 remotes present. First run failed to start — /tmp had been wiped and the Lune binary was gone; re-downloaded 0.11.1 and re-ran green. |
| T16 | Rojo build × 2 (determinism) | `/tmp/rojo-7.7.1/rojo build --output /tmp/GlitchTide_v11_a.rbxl` then `..._b.rbxl`, same project | **PASS — byte-identical.** Both builds SHA-256 `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`, 558,606 bytes. `cmp` confirms identical. Copy kept at `GlitchTide.rbxl` in the project root. |
| T17 | Source-to-place byte matching | `python3 scripts/verify-rbxl.py GlitchTide.rbxl` (new script; parses the rbxl chunk stream — 16-byte chunk headers, LZ4 block decompression — and compares every Source PROP value against `src/`) | **PASS 68/68.** 68 Source values in the place (66 ModuleScript + 1 LocalScript + 1 Script); every src file present byte-for-byte, no extra sources, no duplicates. Header: 10 classes, 76 instances, 26 chunks. (Parser notes: chunk headers are 16 bytes — signature, compressed length, uncompressed length, reserved u32 — not 12 as the format summary in the v1.0.1 report implied; Source is stored as String type 0x01 in this Rojo build, not ProtectedString; the INST referent encoding was not reimplemented — the hierarchy check below uses Rojo's own tree instead.) |
| T18 | Built-hierarchy verification | `rojo serve` + `/show-instances` (Rojo's own tree, rendered from the corrected project file) | **PASS.** 77 instances (76 + DataModel root). DataModel children: ReplicatedStorage, ServerScriptService, StarterGui, StarterPlayer, Workspace. `StarterGui → MainMenu (ModuleScript)` exactly once; `StarterPlayer → StarterPlayerScripts → Main (LocalScript) + Controllers/`; `ServerScriptService → Main (Script) + Services/`; `ReplicatedStorage → 15 shared ModuleScripts`; `Workspace` empty (map built at runtime by MapBuilder). The v1.0.2 packaging fix holds. |
| T19 | JSON validation | `python3 -c "json.load(open('default.project.json'))"` + Rojo build (T16) succeeding | **PASS.** `default.project.json` is valid JSON; `rojo.toml` present. |
| T20 | ZIP extraction test | Unzip `GLITCH_TIDE_V1_1_EXPANDED.zip` to a fresh temp dir, `diff -r` against the project (excluding `.git`), re-run validators from the extracted copy | **PASS.** `diff -r`: identical (re-verified after the final rebuild). From the extracted copy: Python harness 70/70, Lune harness 40/40, `verify-rbxl.py` 0 failed; extracted `GlitchTide.rbxl` SHA-256 matches the build (`40f0cf4f…`). ZIP: 117 files. (The archive's own size + SHA-256 are recorded in the delivery report, not here — a file cannot truthfully print its own hash.) |

### Not applicable to the game tree (not failures)
- `scripts/validate-package.py` is a **make.fun package** validator
  (checks `main.ts`, `vendor/`, `PLAY.json.template` in a competition
  package dir). Run against the game tree it fails with
  `FileNotFoundError: main.ts` — expected; the game tree is not a
  package. It is not run here.
- `scripts/validate-screenshots.py` reports FAIL because no
  `screenshots/` directory exists. That is by design: no screenshots
  exist (none were fabricated) and none can be captured without Studio.
- Icon validation: no icon file lives in the game tree (the
  `icon-512.png` belongs to the make.fun package, not the game). Nothing
  to validate here.

### Failed tests (v1.1)
**None.** No test executed in this pass failed on game code. The only
failures encountered were wrong tool invocations / missing tools after
the /tmp wipe (T12 flag, T15 missing Lune binary, T16 wrong Rojo asset
name) and harness false positives (T14 check 65 comment mentions, T13
miscount), all resolved and re-run green. See the per-test notes above.

## 12. New + unresolved bug list (v1.1)

Carried forward from §4/§5 where still true, plus new v1.1 items.
"Implemented but not runtime tested" items are NOT listed here unless
they have a known defect — see `FEATURE_CHECKLIST.md` and
`docs/QA_V11_A.md` … `docs/QA_V11_E.md` for the full classification.

| # | Item | Status / note |
|---|---|---|
| B1 | Abyssal boss altar spawns THE ALGORITHM in the Chaos Arena, not an Abyssal-local boss | Partial (Wave 1/A). `BossService.SpawnBoss()` takes no position. Needs a BossService change for an Abyssal-local boss fight. |
| B2 | Dimension lighting moods (Abyssal/Skyfall) do not auto-apply | Partial (Wave 1/A). Lighting is global; auto-applying on one player's teleport would re-light the hub for everyone. Needs a server-wide decision or per-player client moods. |
| B3 | Territory bonuses are a flat tick, not an income multiplier | Partial by deliberate design (Wave 2/C). 5/10/15 coins/s + 10/20/30 XP/min by tier, paid straight into Coins (never BankedIncome). A true multiplier needs a BaseService edit. |
| B4 | Hidden merchant is a discovery trigger, not a shop | Partial (Wave 2/C). No secret shop inventory exists; a merchant shop (spending event tokens/shards) is a follow-up. |
| B5 | Expedition on-expedition instances not blocked by Base/Mutation/Fusion | Partial (Wave 2/C). Enforced at the expedition API and hidden by the Wave 3 UI, but BaseService/MutationService/FusionService do not read the `OnExpedition` flag. Risk is reduced rewards only; the Brainrot is never lost. |
| B6 | Dimension gate fails OPEN when ProgressionService is unwired | Known limitation (Wave 2/C). Does NOT apply in the shipped wiring (ProgressionService is linked in GameManager); only a risk if a future change unwires it. |
| B7 | Tide EscapeRoutes (stage 5) not drawn on the client | Not implemented (Wave 3/E). The server broadcasts positions in the stage-5 Warning payload; no client map-marker API exists to draw them. |
| B8 | Power mastery shown from session-only use counts | Partial (Wave 3/E). The server pushes no mastery state; the Shop shows mastery as a formula + session counts. |
| B9 | 5 sound slots unassigned by design | marketAmbience, conveyorLoop, music, dimensionAmbience, tideSirenLoop — named slots that play nothing. No invented IDs. A guide for adding licensed IDs later is in `SoundController`. |
| B10 | `UsePower` / `SettingsUpdate` / `SynergyUpdate` unwired by documented decision | `UsePower`: `AbilityService` uses `UseAbility` instead; nothing fires it. `SettingsUpdate`: no settings sync exists; mute/volume are client-local. `SynergyUpdate`: no server-side synergy event exists for clients to consume (synergy bonus is applied to base income and shown in the Shop). See `docs/REMOTES_WIRED_E.md`. |
| B11 | Trading intentionally omitted; offline income absent; controller input unbound; procedural animation only | Unchanged from v1.0.2 (§5). |
| B12 | Two minor map contacts (escape-ramp edge grazing a plot gate post; 2-stud channel/floor clip, no collision) | Unchanged from v1.0.2. Wave 1/A rewrote MapBuilder but did not move that geometry and did not re-measure it geometrically; cannot have got worse, not confirmed fixed. |
| B13 | `RequestCharacter` (legacy) declared, no server handler, no client caller | Unchanged from v1.0.1 (§4). `Main.client` still waits for it. |
| B14 | No synergy-formation quest; no boss-without-dying quest; no per-family quests | Not implemented (Wave 2/C). Synergy tracking belongs to D's domain (no server-side synergy event); flawless-tide + boss-defeat quests cover the boss case; families are not defined in the shared defs. |
| B15 | Secret-encounter merchant/sighting has no NPC model of its own | The encounter is a roll + broadcast + payout; the merchant itself spawns via `NPCService.SpawnQuestGiver` (Wave 2/C consumes D's hook). |
| B16 | Boss-tide survivor quests + boss tides: `TideService` quest hooks | Implemented in Wave 2/C (survivor quests incl. flawless no-damage tide). No known defect; listed so the Studio playtest covers them. |
| B17 | `luau-analyze` strict-mode noise | 6,764 diagnostics, all rooted in missing Roblox definitions (T13). Not game defects; will disappear once Roblox definitions are present in Studio. |

## 13. Delivery counts (v1.1) + paid-eligibility statement

- 68 Luau files, 42,045 lines (was 48 files / 26,062 lines in v1.0.2;
  +20 files, +15,983 lines). Breakdown: 15 shared modules, 30 server
  services + `Main.server.luau`, 20 client controllers + `Main.client.luau`
  + `MainMenu.luau`, `src/map` empty by design (MapBuilder builds at runtime).
- 27 Brainrots (18 + 9 new), 12 mutations, 19 fusion recipes (10 + 9),
  17 playable powers (12 + 5) + 27 character Q primaries, 13 synergies
  (10 + 3), 54 quests (16 + 38), 24 achievements, 13 titles, 6
  expeditions, 7 territories, 5 secrets, 10 working tide variants
  (5 + 5 promoted), 3 bosses (1 + 2), 9 regions (7 + 2), 12 lighting
  moods, 34 verified sound cues (+ 5 unassigned slots), 62 remote names
  (45 + 17).
- `GlitchTide.rbxl`: 558,606 bytes, Rojo 7.7.1, built twice
  byte-identical, SHA-256
  `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`;
  all 68 script sources verified byte-for-byte inside (T17); hierarchy
  verified via Rojo's own tree (T18).
- Final ZIP: `~/workspace/your_files/GLITCH_TIDE_V1_1_EXPANDED.zip`
  (117 files), verified by clean-room unzip + `diff -r` (identical,
  excluding `.git`) and by re-running the harnesses from the extracted
  copy (T20). Final size + SHA-256 are recorded in the delivery report
  (the archive cannot truthfully print its own hash). Prior ZIPs
  (`GLITCH_TIDE_FINAL_QA.zip`, `GLITCH_TIDE_MAKEFUN_READY.zip`,
  `GLITCH_TIDE_FINAL_SUBMISSION_CANDIDATE.zip`) are NOT overwritten.

### Paid eligibility — NOT claimed

This version is **not claimed paid-eligible** for the make.fun bounty
`roblox-brainrot-01`, and the expansion does not by itself make the
entry paid-eligible. The recording/authorship rules are unchanged from
the 2026-11-19 strict accountability audit: the game was built before
any kit record command ran, so no sealed recording of its development
exists; the strict-transcripts bounty takes sealed recordings only and
`submit` refuses `--bundle`/`--transcript`, so there is no
ranked-but-unpaid fallback. A fresh recorded rebuild would still need
~10,860 genuinely new authored lines (gate: authored ÷ final total ≥
30%) against ~2,500–4,000 lines of genuine open work in this expansion
— a gap of ~7,000–8,000 lines — plus the parent-chain risk (sessions
trace to the main chat begun 2026-09-26, before the bounty opened).
Nothing in v1.1 changes any of that. What v1.1 does is make the game
itself substantially more complete, polished, and impressive as a
competition entry on its merits.

### Still needs Studio (Grok Build)

1. Playtest (solo + multi-client), including the camera regression
   test (`GROK_BUILD_HANDOFF.md` §1) — **re-run after the overhaul**:
   MapBuilder, LightingService, and CharacterModels all changed.
2. The Part 33/36 acceptance scenario (§6) extended for v1.1:
   spawn → base → market buy → carry → tide warning → escape →
   place → income → upgrade → ability → mutation/fusion → quest →
   save/rejoin → 2-player raid → **new**: teleport to Abyssal/Skyfall
   → open a dimension chest → complete the Skyfall checkpoint run →
   evolve a Brainrot in the Lab → start + claim an expedition →
   capture a territory → defeat THE GLITCH COLOSSUS → survive a
   Double/Dark/GiantBoss/Corrupted/Cosmic tide → equip a title.
3. Screenshots (4 compositions in `docs/SHOT_LIST.md`) for the
   competition package; `rojo serve` live sync; live DataStore
   round-trip; 12-player full server; performance measurement.
4. Publishing, icon/thumbnail upload, PLAY.json, and make.fun
   submission remain Grok Build's job — nothing here submits, signs,
   publishes, or creates a wallet.
