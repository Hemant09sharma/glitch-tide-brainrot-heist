# QA — Workstream D (GLITCH TIDE v1.1: Event + Bosses + Combat)

**Scope:** `src/server/Services/TideService.luau`,
`src/server/Services/BossService.luau`, `src/server/Services/WaveService.luau`,
`src/shared/Config.luau` (tide tables only). Work dir
`~/workspace/your_files/glitch-tide-v1.1/` (symlink to the v1.1 tree;
`Config.GameVersion` is `"1.1.0"`).

**Honesty rule (same as QA_TEST_REPORT.md §3):** a feature is listed as
"Fully implemented and tested" only if a tool in this workspace actually ran
it and returned the result. **No Studio playtest was run** — there is no
Studio here — so nothing below claims live gameplay, a screenshot, or a
recording. Everything built here is static-verified only (luau-compile +
static checks, §5). Anything depending on a service that does not exist in
this tree is marked Partially implemented, not Implemented.

**Audit corrections applied (from `docs/AUDIT_V1_1.md`, read before finishing):**

- **(§4i — three-part rule.)** A new tide variation needs THREE things: a
  `Config.TideVariations` entry PLUS a behaviour branch in `runCycle` PLUS
  an entry in the `VARIATIONS` fallback. All ten variants satisfy all three
  (§5 check, 57/57). Config-only data is data-only and does not count.
- **(§4f — EconomyService has NO `AddCoins`/`AddGems` API.)** Its whole public
  API is `Init / AwardKO / AwardWin / AwardWave / BuyCharacter / GetBalance /
  NotifyBalance` (re-verified against the current tree — a parallel workstream
  has since added `SetCompanionService`/`GetCompanionIncomeMultiplier`, but
  still no currency API). Tide/boss rewards therefore use the real paths:
  coins via `DataService.AddCoins(player, n)`; gems / ChaosShards /
  EventTokens via direct field writes (`data.Gems += n`, guarded with
  `tonumber() or 0`) + a `PlayerStats` push. The dead `SetEconomyService`
  setter drafted mid-work was removed, not shipped.
- **(§4d — TideChannel waypoint contract.)** `getWaypoints` still reads the
  direct `BasePart` children of the `TideChannel` folder sorted by name.
  Verified byte-identical to v1.0.2 (`diff` vs the QA ZIP, §5). No new part
  was added directly under `TideChannel`; all D structures live in
  `workspace` root and are destroyed at tide end.
- **(§4j — BossUpdate.)** Boss announces previously went via
  `SpawnEffect`/`WaveUpdate` only. D now ALSO fires `BossUpdate` (spawn /
  phase / 2s health / death), but the `SpawnEffect`/`WaveUpdate` announces
  are kept, and **no client listens to `BossUpdate` yet** — the listener
  comes in a later workstream (see `docs/REMOTES_NEEDED_D.md`).
- **(§3 F1 — dead steal path.)** `StealBrainrot` (and melee `Attack`) have
  server handlers but no client `FireServer` anywhere. Not a D file; not
  changed here. Flagged for the UI/multiplayer workstream — see
  `docs/REMOTES_NEEDED_D.md` and §6 below.

## 1. Per-variant table (every variant gets its own row)

Status key: **I** = Implemented but not runtime tested · **P** = Partially
implemented · **N** = Not implemented. (Nothing in this workstream is
"Fully implemented and tested" — see the honesty rule above.)

| # | Variant | Status | Wave wall | Lighting mood | Distinct hazard | Rewards (survivor) | Announcement |
|---|---|---|---|---|---|---|---|
| 1 | Standard | I | 1 wall, speed 1.0, dmg 1.0, purple | `TideActive` | none (baseline) | ×1.0 coins/XP, 5 tokens, +1 ChaosShard | "GLITCH TIDE INCOMING — get to a shelter, a platform, or your base!" |
| 2 | Fast | I | 1 wall, speed 1.5 (ping-pong sweeps), orange | `TideActive` | speed itself (wave crosses 1.5×) | ×1.25, +1 shard | "FAST TIDE — the wave is sweeping the channel half as fast again. Run!" |
| 3 | Toxic | I | 1 wall, speed 1.0, dmg 1.25, green | `Toxic` | channel-wide DoT (6×dmg/tick) + 3 toxic pools (extra DoT inside, r=8) | ×1.5, +2 shards | "TOXIC TIDE — the air itself hurts. Stay out of the green pools and the channel!" |
| 4 | Frozen | I | 1 wall, speed 0.7, ice-blue | `Frozen` | global WalkSpeed ×0.5 (re-applied every tick, join/respawn-safe, Surfers exempt) + 3 slow fields (×0.35 inside) | ×1.5, +2 shards | "FROZEN TIDE — everything slows to a crawl. The ice fields will freeze you in place!" |
| 5 | Meteor | I | 1 wall, dmg 1.5, red-orange | `Meteor` | meteor every 2s (25×dmg, safe-zone/Surfer immune); impacts leave collectible fallout (+1 shard on touch) | ×1.75, +3 shards | "METEOR TIDE — pastry meteors are raining down! Dodge them and grab the fallout!" |
| 6 | Double | I | **2 walls** (purple + cyan, anti-phase), speed 1.25 | `TideActive` | second wall damages independently (same 38×9 stud check) | ×2.0, +4 shards | "DOUBLE TIDE — TWO wave walls are coming down the channel at once. Double trouble, double rewards!" |
| 7 | Dark | I | 1 wall, speed 1.25, dmg 1.25, near-black | `Dark` (FogEnd 120, Brightness 0.4) | darkness itself (4×dmg/tick to the exposed) + ambush spawns every 10s (cap 4 alive; NPCService when linked, else minimal fallback enemy) | ×1.75, +3 shards | "DARK TIDE — the lights are dying. Something is moving in the dark. Stay in the light!" |
| 8 | GiantBoss | I | 1 wall, speed 0.8, dmg 2.0, red | `Boss` | **THE GLITCH COLOSSUS spawns mid-tide** via `BossService.SpawnBoss("GlitchColossus")` (falls back to `SpawnBoss()` if that fails) | ×3.0, +5 shards | "GIANT BOSS TIDE — THE GLITCH COLOSSUS is storming the arena mid-tide! Triple rewards for survivors!" |
| 9 | Corrupted | I | 1 wall, speed 1.1, dmg 1.5, magenta | `TideActive` | 3 glitch barriers across the channel (touch = teleported to a random escape route, 3s per-target cooldown) + random teleport of an exposed player every 15s | ×2.25, +4 shards | "CORRUPTED TIDE — glitch barriers are tearing the world apart. Touch one and you will be thrown somewhere else!" |
| 10 | Cosmic | I | 1 wall, speed 0.9, dmg 1.25, starlight cyan | `Cosmic` | **low gravity** (`workspace.Gravity` 196 → 60 for the tide, restored after) + starfall pickup every 8s (+25 coins +1 shard on touch) | ×2.5, +5 shards | "COSMIC TIDE — gravity is failing and the stars are falling! Catch the starfall for Chaos Shards!" |

Shared by ALL variants (not per-variant): wave damage 12×dmg + stun + carried
drop on hit; flawless survivors +5 tokens and a 10% roll at a tide-exclusive
Secret/Divine Brainrot grant (preferring unowned); risk-zone earnings
(+5 coins/s banked, paid on survival); tide surfing bonus (Surfers near the
wave: +10 coins per 5s, +1 shard per 15s); co-op survival (2+ survivors:
+25% coins/XP, +2 tokens); tide-exclusive conveyor spawns
(`ConveyorService.ForceSpawn("Secret")` at tide start + every 25s at 50%).

## 2. Feature classification (Part 16)

| Feature | Status | Honest notes |
|---|---|---|
| 10 tide variants with real mechanics | I | All three parts of the audit §4i rule verified per variant (§5, 57/57). Weights sum to 100 (Standard 30 / Fast 15 / Toxic 12 / Frozen 12 / Meteor 10 / Double 8 / Dark 6 / GiantBoss 4 / Corrupted 2 / Cosmic 1). `Config.TideVariationsDisabled` deleted — zero code references remain (2 comment mentions documenting the deletion). |
| Cinematic 10-stage anticipation | I | Explicit `broadcastStage` calls: 1 EnvironmentFlicker → 2 StructureFlicker → 3 Sirens → 4 SkyChange → 5 PlayerWarning (stages 1–5 split `Config.GlitchTideWarningSeconds` 15/15/20/20/30%) → 6 WaveEmerges → 7 WaveTravels → 8 Survival (halfway) → 9 Climax (last `Config.TideClimaxSeconds` = 5s, wave ×1.5 faster, Meteor rain doubles) → 10 Rewards. Each stage broadcast on `GlitchTideUpdate` (`Stage`/`StageName`); stage 5 also on `EventUpdate`; stage 3 fires the `TideSiren` `SpawnEffect` for the sound workstream. Stage 2 flickers real Neon parts of the built world (read-only, capped at 40, restored). |
| Lighting moods | P | Mood table implemented for all 10 variants + `TideWarning`/`Hub`; `LightingService.SetMood` is attempted first via `pcall(require(...))` — **but no `LightingService` file exists in this tree** (another workstream's file), so today the built-in `game.Lighting` tween fallback is what runs. The fallback is real (Ambient/OutdoorAmbient/Brightness/FogColor/FogEnd per mood, `Hub` restores pre-tide values). "Partially" because the service path is untestable until that file lands. |
| Multiple escape routes | I | `GetEscapeRoutes()` returns MapBuilder safe zones (platforms/shelters) + base plots (r=12) + callback zones + standing tide shelters; the full list is broadcast in the stage-5 Warning payload (`EscapeRoutes` with `{x,y,z}` positions). |
| Temporary safe shelters | I | 3 shelters (`Config.TideShelterCount`) spawn at Active start (floor+roof+4 posts, green roof), count as safe zones via `IsInSafeZone`, destroyed at tide end. Map's 3 built shelters are untouched. |
| Moving obstacles in the TideChannel | I | 4 anchored blocks slide along the channel (`sin` motion, distinct speeds/phases); touch = 5×dmg damage + knockback (1s per-target cooldown). Destroyed at tide end. |
| Tide surfing (extended) | I | Existing `GrantSurfer`/`IsSurfer` hooks kept (incl. `TideSurferUntil` attribute + `IsTideSurfer` callback). New: Surfers within 20×12 studs of the wave bank surf time; +10 coins per 5s and +1 shard per 15s paid at survivor payout; `TideSurf` `SpawnEffect` per 5s block. |
| Glitch barriers (Corrupted) | I | See variant row 9. Barriers also exist only during the tide and are cleaned up after. |
| Risk-and-reward areas | I | 2 gold risk zones inside the wave path; +5 coins/s banked while standing in one (exposed players only — safe/Surfer players do not bank); paid only on survival. |
| Rare event-only Brainrots | I | Two paths: (a) conveyor `ForceSpawn("Secret")` during the tide when `ConveyorService` is linked (GameManager auto-wires via `SetConveyorService`); (b) flawless-survival 10% direct grant of a Secret/Divine Brainrot via `DataService.UnlockCharacter` (preferring unowned). Secret rarity has roster entries (`Characters.GetByRarity("Secret")` non-empty). |
| Special event materials | I | Per-variant ChaosShards (1–5, §1) + Meteor fallout (+1) + Cosmic starfall (+1, +25 coins) + boss participant shards (Colossus +3, Void Emperor +5). All via direct field writes (audit §4f — no EconomyService shard API exists). |
| Co-op survival rewards | I | 2+ survivors: +25% coins/XP each, +2 tokens each. Computed from the survivor list before payout, so the bonus is exact. |
| Secret event encounters | P | Roll implemented: 10% per tide (`Config.TideSecretEncounterChance`), 50/50 Hidden Merchant (survivors +5 tokens at payout) vs Secret Brainrot Sighting (everyone online +1 shard immediately). Broadcast on `EventUpdate` + `SpawnEffect`, record kept for `TideService.GetSecretEncounter()` — **the hook for the secrets workstream**. "Partially" because there is no merchant NPC / sighting model: the encounter is a roll + broadcast + payout, and the full encounter content belongs to the secrets workstream. |
| Boss: THE GLITCH COLOSSUS | I | Chaos Arena. 7,500 HP base, scaled +10% per extra player online (cap 2×). P1 (>66%): speed 8, dmg 20, melee slam + glitch-barrier telegraphs. P2 (33–66%): speed 12, dmg 30, + shockwave every 10s, + teleport to a random player every 12s. P3 (<33%): speed 16, dmg 40, + meteor rain every 6s, + 2 minion summons every 18s, + glitch nova every 15s (nearby players randomly teleported). Rewards: top damager +75 gems (×1.25 when 2+ participants) + guaranteed unowned Legendary/Mythic/Divine grant; participants +15 tokens +300 coins +3 shards (×1.5 when 2+ participants); quest events `defeat_boss` + `defeat_boss_colossus`. |
| Boss: THE VOID EMPEROR | I | Forbidden Rift (arena lookup fixed to find the `RiftPortal` part; v1.0.2 only looked for a `BasePart` named `ChaosArena`/`Arena` and fell back to origin). 9,000 HP base, same player-count scaling. P1: speed 12, dmg 25, melee + void bolt (ranged, telegraphed, nearest player ≤30 studs) every 4s. P2: speed 15, dmg 35, + void zones (DoT field, 8 dmg/s, 10s) every 9s, + summons every 15s. P3: speed 20, dmg 45, + starfall/meteor rain every 5s, + shockwave every 12s, + void nova every 15s. Rewards: top damager +100 gems (×1.25 co-op) + guaranteed unowned Mythic/Divine/Celestial/Secret grant; participants +20 tokens +400 coins +5 shards (×1.5 co-op); quest events `defeat_boss` + `defeat_boss_void_emperor`. |
| Boss: THE ALGORITHM (existing) | I | **Unchanged behaviour.** 5,000 HP, never scaled, same speeds/damages/intervals (P1 10/15 melee; P2 14/25 shockwave 8s; P3 18/35 meteor 5s, summons 20s), same rewards (top +50 gems + Epic+ grant; participants +10 tokens +200 coins), 30-min auto-spawn, `SpawnBoss()` with no argument still spawns it. Internally it now runs through the shared generic boss path (same numbers, same `Creator`-tag credit, same death flow); `GetBossState` gains `BossId`/`BossName` fields, old fields unchanged. |
| BossUpdate broadcasts | P | Fired on spawn / phase / 2s health / death with `{Event, BossId, BossName, Arena, Active, Health, MaxHealth, Phase}`. "Partially" because **no client listens yet** (later workstream); the old `SpawnEffect`/`WaveUpdate` announces are kept so nothing is lost meanwhile. |
| WaveService boss-wave integration | I | No new wave starts while a tide is Warning/Active (2s poll; in-progress waves keep running and pay on clear). Every 10th wave additionally summons a real boss when linked and none is live (wave % 20 == 0 → Void Emperor, else Glitch Colossus); the wave's own mini-boss still spawns. `WaveUpdate` now also carries `BossActive`/`BossName`. WaveNPC caps unchanged (`min(wave+2, MaxWaveNPCs=24)`); `SetBossService`/`SetTideService` auto-wired by `GameManager.wireCrossLinks`. |
| ForceStart validation (all 10) | I | Gate is the Config-loaded `VARIATIONS` table: accepts all 10, rejects unknown names, refuses while a cycle runs. Verified statically (§5). |
| v1.0.2 fixes preserved | I | Phase machine, callbacks (`DropCarried`/`GetSafeZones`/`SetGlitchMode`/`IsTideSurfer`), survivor payout logic, boss tide every 5th tide, Frozen slow re-applied every tick, meteor safe-zone/Surfer immunity, `getWaypoints` byte-identical to v1.0.2, `RarityWeights` byte-identical to v1.0.2. No forbidden file touched (only the 4 D-owned files + these docs; other files that differ from the v1.0.2 ZIP are parallel workstreams' edits, not D's). |

## 3. Deliberately left undone

- **No Studio playtest, no `rojo build`, no screenshots/recording.** Nothing
  here is runtime-proven; Grok Build must playtest (tide warning → escape →
  survive → payout; each variant via `ForceStart`; both new bosses).
- **No `BossUpdate` client listener** — later workstream (see §2).
- **No `LightingService`** — another workstream's file; D degrades gracefully
  without it (built-in tween fallback).
- **No merchant NPC / sighting model for secret encounters** — secrets
  workstream owns the content; D ships the roll + broadcast + hook.
- **No new RemoteEvent/RemoteFunction names** — everything D fires already
  exists (`docs/REMOTES_NEEDED_D.md`).
- **No `Remotes.luau`, `GameManager.luau`, `EconomyService.luau`,
  `MapBuilder.luau` or other forbidden-file edits.** `BossService.SpawnBoss`
  and `WaveService` setters are wired by the existing `GameManager`
  `wireCrossLinks` shared table (it calls every `Set*` setter present) —
  no GameManager change was needed or made.
- **No balance tuning beyond the Config tide tables.** Weights/rewards are
  first-pass values from the task brief; playtesting should validate them
  (notably GiantBoss ×3.0 and Cosmic ×2.5 survivor multipliers).

## 4. Files changed / added

| File | v1.0.2 lines | v1.1 lines | Delta |
|---|---|---|---|
| `src/server/Services/TideService.luau` | 923 | 2,130 | +1,207 (10 variants, 10 stages, hazards, shelters, obstacles, risk zones, surfing, secret encounters, exclusive spawns, co-op) |
| `src/server/Services/BossService.luau` | 620 | 1,061 | +441 (generic boss registry, 2 new bosses, BossUpdate, scaling, co-op) |
| `src/server/Services/WaveService.luau` | 368 | 440 | +72 (tide pause, 10th-wave boss summons, `SetBossService`/`SetTideService`, `BossActive`/`BossName` broadcast) |
| `src/shared/Config.luau` (tide tables only) | 379 | 418 | +39 (5 new variation entries, `ChaosShards`+`Announcement` on all 10, `TideVariationsDisabled` deleted, `TideClimaxSeconds`/`TideSecretEncounterChance`/`TideShelterCount`) |
| `docs/REMOTES_NEEDED_D.md` | — | new | Remote needs (none new) + dead-path flags |
| `docs/QA_V11_D.md` | — | new | This file |

Line counts are `wc -l` against the v1.0.2 QA ZIP baseline (which matches the
audit's 26,061-line count). `Config.RarityWeights` is byte-identical to
v1.0.2 (verified by diff).

## 5. Verification actually run

| # | Check | Tool / command | Result |
|---|---|---|---|
| V1 | Luau compile, all 4 touched files | `/tmp/luau-compile <file>` (Luau 0.747) | **PASS 4/4.** TideService, BossService, WaveService, Config all compile clean. |
| V2 | Static check script (57 checks) | `/tmp/check_d.py` (kept outside the tree; re-runnable) | **PASS 57/57.** Covers: 10 Config variations + weights sum 100 + ChaosShards/Announcement on all 10; `TideVariationsDisabled` deleted; `RarityWeights` sums to 1.0; VARIATIONS fallback has all 10; a behaviour branch per variant (audit §4i three-part rule); ForceStart gate accepts all 10 / rejects unknown; phase machine + callbacks preserved; `getWaypoints` contract; no `EconomyService.*` currency calls in D files, coins via `DataService.AddCoins`, gems/shards via direct field writes; `BossUpdate` fired on spawn/phase/health/death + `SpawnEffect`/`WaveUpdate` kept; Algorithm 5,000 HP unscaled; both new bosses in `BOSS_DEFS`; `SpawnBoss(id?)` nil → Algorithm; Creator-tag credit; WaveService cap + tide pause + 10th-wave boss + setters; all 10 stages broadcast; LightingService pcall + fallback; secret-encounter roll + hook. (First run showed 3 stage "failures" — a regex bug in the check script: stages 5/6/10 pass an extra payload table. Verified by grep that all three calls exist; script fixed, re-run 57/57.) |
| V3 | Luau strict analysis | `/tmp/luau-analyze <file>` per file | **PASS with documented noise only.** Remaining diagnostics are the same two classes QA T2 already accepted: missing Roblox definitions (`BasePart`/`Player.Character`/`Humanoid` unknown without Studio defs) and `unknown` cascades from untyped `require`d modules (`Config`/`Characters` tables, `pcall` narrowing). Every flagged line was spot-checked: the expressions are runtime-guarded (`tonumber()`/`type()` checks, `pcall`, nil checks) or use types that exist in Studio. Zero diagnostics point at a real defect. |
| V4 | Config diff vs v1.0.2 | `diff` vs QA ZIP copy | **PASS.** Only the tide section changed (+ `GameVersion` 1.0.2 → 1.1.0, which predates this workstream — the tree was already relabelled when received). |
| V5 | `getWaypoints` diff vs v1.0.2 | `diff` of the function | **PASS — byte-identical.** TideChannel waypoint contract preserved. |
| V6 | `TideVariationsDisabled` references | `grep -rn` over `src/` | **PASS.** Only 2 comment mentions documenting the deletion; zero code references. |

### NOT run (no Studio / live services in this workspace)

- Any Studio playtest (tide cycle, variant behaviour, boss fights, wave
  pause, shelter safety, surfing payout, secret encounter).
- `rojo build` / `rojo serve` (another workstream owns the build; D changed
  no project file).
- Live DataStore round-trip; multi-client behaviour; performance measurement.
- The `LightingService.SetMood` path (no such service exists yet to call).

## 6. Notes for other workstreams / parent

- **StealBrainrot + Attack are dead paths (audit §3 F1).** Server handlers
  exist; no client code fires either remote. Stealing and melee combat cannot
  be triggered from any UI today. Flagged in `docs/REMOTES_NEEDED_D.md` for
  the UI/multiplayer workstream. D did not touch `RaidService`/`CombatService`
  or any client file.
- **Parallel-workstream caution:** this tree is being edited concurrently —
  files outside D's ownership already differ from the v1.0.2 ZIP
  (`CompanionService`, `Dimensions`, `Characters`, `Powers`, `Synergies`,
  `AbilityService`, `EconomyService`, `AnimationController`,
  `CharacterModels`). D touched only its 4 files + 2 docs. In particular,
  `EconomyService` gained companion setters from another workstream; audit
  §4f still holds (no currency API). `Characters.GetByRarity`/`GetAll` (used
  by D for exclusive grants) still exist.
- **Symlink note (for the parent, not a defect):**
  `~/workspace/your_files/glitch-tide-v1.1` and
  `~/workspace/your_files/brainrot-battle-arena` are both symlinks to the
  same tree (`~/workspace/goals/glitch-tide-brainrot-heist-the-memeverse/files/brainrot-battle-arena`,
  `GameVersion "1.1.0"`). All D edits went through the `glitch-tide-v1.1`
  path as instructed. The v1.0.2 original survives only in the ZIPs
  (`GLITCH_TIDE_FINAL_QA.zip` etc.).
- **Quest event ids introduced by D** (`survive_boss_tide`,
  `defeat_boss_colossus`, `defeat_boss_void_emperor`) have no quest entries
  yet — `QuestService.RecordEvent` is `pcall`d, so unknown ids are harmless,
  but the quest workstream should add quest definitions for them if they
  are to be completable.
- **`BossUpdate` payload** is stable (`Event/BossId/BossName/Arena/Active/
  Health/MaxHealth/Phase`) — the client-listener workstream can build
  against it as documented in `docs/REMOTES_NEEDED_D.md`.
