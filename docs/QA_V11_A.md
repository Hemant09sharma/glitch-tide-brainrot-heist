# QA — GLITCH TIDE v1.1, Workstream A: Visual Overhaul + New Regions

**Date:** 2026-11-19. **Scope:** the five files this workstream owns
(`src/shared/Dimensions.luau` [new], `src/server/Services/MapBuilder.luau`
[rewritten], `LightingService.luau` [new], `EnvironmentService.luau`
[new], `DimensionsService.luau` [new]) plus `docs/SHOT_LIST.md`,
`docs/REMOTES_NEEDED_A.md`, and this file. Nothing else was touched:
no `Config.luau`, no `Remotes.luau`, no `GameManager` / `Main.server`,
no `DataService` / `EconomyService` / `TideService`, no `CHANGELOG.md` /
`FEATURE_CHECKLIST.md` / `README.md` / `QA_TEST_REPORT.md`, no git.

**Honesty rule (same as QA_TEST_REPORT §1):** a feature is listed as
"tested" only if a tool in this workspace actually ran it. Nothing
here claims a Studio playtest, a screenshot, a recording, a live
DataStore round-trip, or a running server — none of those happened.
Everything gameplay-shaped is **code-reviewed + statically verified**,
not proven running.

## 1. Verification actually executed

| # | Test | Tool / command | Result |
|---|---|---|---|
| A1 | Luau compile, all 5 owned files | `/tmp/luau-compile <file>` (Luau 0.747, `luau-ubuntu.zip` from GitHub releases — the `luau-0.747-linux.zip` asset name 404s; the correct asset is `luau-ubuntu.zip`) | **PASS 5/5, 0 failures.** |
| A2 | Luau strict analysis, all 5 owned files | `/tmp/luau-analyze <file>` | **PASS with the documented noise only.** Every remaining diagnostic is an `unknown`-type cascade from missing Roblox definitions (`game`, `Enum`, `Color3`, `Vector3`, `Instance` methods) and `Unknown require` for `ReplicatedStorage:WaitForChild(...)` modules — the exact noise class QA §3 T2 documents for v1.0.2. One REAL diagnostic was found and fixed during this pass: `DimensionsService.GetDimensions` built sealed table literals where `{[string]: any}` was declared (fixed with annotated locals; re-run clean apart from noise). Zero non-noise diagnostics remain on any owned line. |
| A3 | Static structural harness (Python, read-only regex/counts over `src/`) | `/tmp` one-off script (not kept — counts below are reproducible by hand from the file) | **PASS.** All 12 pre-existing MapBuilder accessors present (`GetBasePlot`, `GetBasePlots`, `GetConveyorPath`, `GetSafeZones`, `GetSpawnPosition`, `GetBeltParts`, `GetBeltBounds` + 5 new dimension accessors); all 7 original zone folders + 2 new ones present; `TideChannel` direct `newPart` children are ONLY the 5 `TidePoint0*` markers (everything else under `Props`); `ForbiddenRift` first BasePart is now `RiftPostA` at the rift (see §4); `MutationLab` first BasePart is still `LabMachine`; no `Magma`/`Spectral` in any owned file; no `GetRemotes` call; no `EconomyService.AddCoins` call (it does not exist — see §5); `puddle_professor` and `moon_mochi` are real roster ids; chest/checkpoint/hazard names in `Dimensions.luau` match the parts MapBuilder builds from those defs (names are used dynamically via `chest.Name` / `cp.Name` / `hazard.Name`, so a literal grep does not show them — verified by reading the builder loops). |
| A4 | Part-count estimate (static) | Call-site count × loop multipliers, per builder (see §3) | **575 parts estimated** (v1.0.2 base ≈ 368 by the same method; +207). Target was < 600. **This is an estimate, not a Studio measurement** — the runtime count is printed by `MapBuilder.Build` (`GetPartCount()`) and must be confirmed in Studio. 12 parts were trimmed from the first draft (587 → 575) to keep margin. |
| A5 | Light-budget count (static) | `addPointLight` call sites | **16/16 at the cap, never over.** 12 plot lights + hub portal + tower + siren + Abyssal hub portal. The Skyfall hub portal and both new regions use Neon + particles only, no PointLights. `LightingService` creates no lights (it only tints the portal lights). |
| A6 | Cross-file API check | Read of `EconomyService`, `DataService`, `BossService`, `CarryService`, `SecurityService`, `GameManager` (audit §4c/§4f) | **PASS.** Every external call DimensionsService / LightingService / EnvironmentService make names a method that exists with the signature used (see §5). |

### NOT executed (same limits as QA §6)
No Studio playtest, no `rojo build` of this tree, no `rojo serve`,
no live DataStore round-trip, no multi-client test, no screenshot or
recording, no performance measurement. Grok Build must run the Studio
acceptance for this workstream: build the place, confirm
`GlitchTideWorld` contains `AbyssalKingdom` + `SkyfallKingdom`,
walk into both hub portals, open a chest, run the Skyfall checkpoints,
stand in a current, trigger the altar, and confirm the part count in
`MapBuilder`'s print line. The camera regression test
(`GROK_BUILD_HANDOFF.md` §1) still comes first.

## 2. Feature classification (Part 16 statuses)

### Fully implemented and tested
*None.* Nothing in this workstream ran in Studio, so nothing earns
this status. (Anything below that sounds like it does is a wording
error — please flag it.)

### Implemented but not runtime tested
- **Visual overhaul of all 7 existing regions** (MapBuilder):
  elevation (plaza dais, market stalls, hills, gauge tower, arena
  dais), large landmarks (portal arch, market arch, mountain spires,
  tide-gauge tower), distinctive silhouettes per region (plaza
  banners/stalls, market awnings, lab pipes/vats/coils/antenna,
  arena pillars/braziers, rift crystals/broken arch/totem),
  environmental storytelling (broken piers, channel debris, glitch
  crystals, collapsed rift arch), background scenery (4 spires,
  3 hills), terrain variation (hills + basin + floating islands).
  All preserved accessors, zone names, safe zones, waypoints, belt
  parts/bounds, spawn position verified statically (A3). The two
  known minor map contacts were not touched (no ramp/plot/channel
  geometry moved) and cannot have got worse — but they were not
  re-measured geometrically either.
- **LightingService + 12 moods** (`Hub, Market, Abyssal, Skyfall,
  TideWarning, TideActive, Toxic, Frozen, Meteor, Dark, Cosmic,
  Boss`): full property sets (ClockTime, Brightness, Ambient,
  OutdoorAmbient, Fog, ColorCorrection, Atmosphere, Bloom,
  DepthOfField, SunRays) + portal-light tinting, `SetMood` /
  `GetMood` / `GetMoods`, 2.5s tweened transitions, unknown-mood
  warn + `false`, nil-safe `pcall`-require usage documented for
  TideService. Post-effect instances are created once, named
  `V11*`, re-found (not duplicated) on re-Init.
- **EnvironmentService**: one Heartbeat loop, sine math from cached
  base CFrames, ~30 animated elements (portal swirls, rift pulse,
  fountain bob, beacon pulse, lab coils, arena chest spin+bob,
  buoys, sirens, plant sway, wisp orbits, cloud bob, market-sign
  colour cycle), `SetEventMode` / `GetEventMode` /
  `GetAnimatedCount`, graceful degrade on missing parts (warn once,
  skip). No per-frame Instance creation, all parts anchored.
- **Dimensions.luau**: both region defs (id, display name, portal
  position/yaw, spawn, return portal, lighting mood, description,
  rewards, hazards, checkpoints, exclusive character). Single source
  of truth — MapBuilder and DimensionsService both build from it.
- **DimensionsService — teleport + return**: server-validated
  (`TeleportToDimension` / `ReturnToHub`), hub-portal proximity
  (14 studs), hub-only origin, 3s cooldown, denied while carrying
  (when CarryService is linked), fall-return below y=20 in Skyfall,
  `GetStateForSave` / `LoadState` (in-memory; DataService untouched).
- **DimensionsService — Abyssal chests + Skyfall cache**: prompts,
  proximity + per-chest cooldown (300s / 600s for the Drowned
  King's Chest), real rewards via `DataService.AddCoins` + XP via
  `ProgressionService.AddXP` (else `DataService.AddXP`) +
  `EconomyService.NotifyBalance` (see §5 for why this exact stack).
- **DimensionsService — Skyfall checkpoint run**: 4 pads in order,
  90s limit, 250 coins + 40 XP on completion, one-time exclusive
  `moon_mochi` on first completion, debounce + wrong-order ignored.
- **DimensionsService — hazards**: 0.5s server poll; currents push
  (velocity blend) + 5 dmg/s; wind pushes only; no client-trusted
  values.
- **docs/SHOT_LIST.md**: 4 compositions with camera angle,
  time-of-day/mood, what must be visible, zone/mood to set. No
  screenshot fabricated.
- **docs/REMOTES_NEEDED_A.md**: 3 names with payloads and the
  degrade behaviour while they are missing.

### Partially implemented
- **Abyssal boss trigger.** The altar prompt, server-wide 600s
  cooldown, proximity check, and one-time exclusive
  `puddle_professor` + 100 coins are implemented. BUT the boss it
  summons is the shared world boss THE ALGORITHM in the **Chaos
  Arena** (`BossService.SpawnBoss()` takes no position) — there is
  no Abyssal-local boss in `BossService`. The spec asked for "a
  secret boss trigger or exclusive Brainrot encounter hook": the
  trigger + encounter hook exist; an Abyssal-local boss fight does
  not. Needs a `BossService` change (future work, not this
  workstream).
- **DimensionUpdate client feedback.** The server fires every
  payload listed in `REMOTES_NEEDED_A.md`, but no client controller
  listens yet and the remote name does not exist in `Remotes.luau`,
  so today every fire is a silent no-op. Gameplay works; the player
  gets no toast/banner. A client controller is future work for
  another workstream.
- **TeleportDimension / RequestDimensions remotes.** The server
  wires them IF they appear (10s poll after Init); the names do not
  exist in `Remotes.luau` yet, so today travel is prompt-only and
  dimensions are not listable from the client.
- **Lighting moods for dimensions.** `Abyssal` / `Skyfall` moods
  exist and `DimensionsService.ApplyDimensionMood` applies them, but
  nothing calls it automatically — correctly so, because Lighting
  is global and auto-applying on one player's teleport would
  re-light the hub for everyone. A server-wide decision (or a
  future per-player client mood) is needed before these moods are
  seen in normal play.
- **Quest-zone centre fix (side effect).** `ForbiddenRift`'s first
  BasePart is now the rift frame at (-150, -150) instead of the
  first path stone (~47 studs away), so `QuestService`'s 20-stud
  zone poll now triggers at the rift itself. Intended and noted,
  but it changes where `visit_rift` fires — Grok Build should
  confirm the quest still completes (walk to the rift).

### Not implemented
- **Client UI for dimensions.** No Dimension panel, no HUD region
  indicator, no DimensionUpdate listener, no keybind. Out of scope
  for this (server) workstream; needs a client controller.
- **Persistence wiring.** `GetStateForSave` / `LoadState` exist and
  are in-memory only. Nothing writes dimension state into
  `DataService` (deliberately — `DataService` is not owned here).
- **Offline income / trading / controller input / keyframed
  animations.** Unchanged from v1.0.2 (audit §3 F5). Not this
  workstream.
- **An Abyssal-local boss model / fight.** See "Partially
  implemented" above.
- **Per-player lighting moods.** Impossible with global Lighting;
  would need client-side mood application (future work).

## 3. Counts

| Item | Count |
|---|---|
| Files added | 6 (`Dimensions.luau`, `LightingService.luau`, `EnvironmentService.luau`, `DimensionsService.luau`, `docs/SHOT_LIST.md`, `docs/REMOTES_NEEDED_A.md`) + this file |
| Files changed | 1 (`MapBuilder.luau`, 615 → ~1,190 lines) |
| Lines (owned files) | `Dimensions.luau` 223; `MapBuilder.luau` ~1,190; `LightingService.luau` 566; `EnvironmentService.luau` ~460; `DimensionsService.luau` ~860. Total ≈ 3,300 lines |
| Parts (static estimate) | **575** (ground 15, plaza 60, conveyor 41, plots 264, tide 51, lab 12, arena 14, rift 16, Abyssal 57, Skyfall 45 — after trimming 12 from the first draft's 587). Target was < 600. **This is an estimate, not a Studio measurement** — the runtime count is printed by `MapBuilder.Build` (`GetPartCount()`) and must be confirmed in Studio. |
| PointLights | **16/16** (12 plots + hub portal + tower + siren + Abyssal hub portal) |
| Moods | 12 (`Hub, Market, Abyssal, Skyfall, TideWarning, TideActive, Toxic, Frozen, Meteor, Dark, Cosmic, Boss`) |
| Animated elements | ~30 collected by EnvironmentService (spins, bobs, pulses, sways, orbits, 1 sign) |
| Regions | 9 zones total (7 original + Abyssal Kingdom + Skyfall Kingdom) |
| Chests | 4 (3 Abyssal + 1 Skyfall cache) |
| Hazard zones | 5 (3 Abyssal currents + 2 Skyfall winds) |
| Checkpoints | 4 (Skyfall, 90s) |

## 4. Preserved v1.0.2 behaviour (verified statically, A3)

- Camera manager untouched; only `CameraController` /
  `EffectsController` touch the camera (no new camera code here).
- Keybinds untouched (no `Config` edits).
- 12 plots, 12 players, 10 pedestals per plot, plot record fields
  identical.
- Rojo hierarchy untouched (`default.project.json` not edited;
  `src/shared` → `ReplicatedStorage`, `src/server` →
  `ServerScriptService`, so the new modules are picked up by the
  directory mappings with no project change).
- No Magma/Spectral anywhere in owned files (only the shared 12
  mutations exist; this workstream does not touch mutations).
- No fake asset IDs, no fake screenshots, no Studio runtime claims.

## 5. Reward-API decision (audit §4f applied)

`EconomyService` has **no** `AddCoins`/`AddGems` method — its entire
public API is `Init`, `AwardKO`, `AwardWin`, `AwardWave`,
`BuyCharacter`, `GetBalance`, `NotifyBalance`. Its award methods pay
small fixed event amounts (`CoinsForWave(1..3)` = 15/20/25 coins),
which are wrong for treasure chests (150/300/600). So chest /
checkpoint / altar rewards use the stack every other service uses
(audit §4f):
- **Coins:** `DataService.AddCoins(player, n)` (the primitive
  `EconomyService` itself uses internally).
- **XP:** `ProgressionService.AddXP(player, n)` when linked (the
  preferred path — handles level-ups), else `DataService.AddXP`.
- **Balance push:** `EconomyService.NotifyBalance(player)` after
  every reward, so the client `PlayerStats` HUD refreshes.
- **Exclusive Brainrots:** `DataService.UnlockCharacter(player, id)`
  (no EconomyService grant-character method exists).
- **Boss:** `BossService.SpawnBoss()` (exists, `-> boolean`).

## 6. Registration — what the integrator must do (GameManager NOT edited here)

New service names for `OPTIONAL_SERVICES` (suggested order —
`LightingService` right after `TideService` so moods exist early,
the other two at the end after `ProgressionService`):

```lua
local OPTIONAL_SERVICES = {
	"TideService",
	"LightingService", -- NEW (Workstream A)
	"QuestService",
	"NPCService",
	"EventService",
	"MutationService",
	"FusionService",
	"AbilityService",
	"RaidService",
	"BossService",
	"WaveService",
	"ProgressionService",
	"EnvironmentService", -- NEW (Workstream A)
	"DimensionsService",  -- NEW (Workstream A)
}
```

**Init signatures (exact):**
- `LightingService.Init(dataService, economyService, map)` —
  first two args accepted and ignored; `map` optional (portal-light
  tinting only). `Init()` / `Init(map)` also work.
- `EnvironmentService.Init(dataService, economyService, map)` —
  first two args accepted and ignored. `Init()` / `Init(map)` also
  work; without a map it warns and stays idle.
- `DimensionsService.Init(dataService, economyService, map)` —
  all three used. `Init(map, dataService, economyService)` and
  `Init(map)` are also accepted (arguments are duck-typed in
  `normalizeArgs`).

All three signatures match `GameManager.loadOptional`'s generic
fallback call `service.Init(_dataService, _economyService, _map)`,
so a per-name branch is **not strictly required** for arguments —
but per audit §4c a per-name branch is still recommended for
clarity, e.g.:

```lua
elseif name == "LightingService" then
	initOk, initErr = pcall(function() service.Init(_dataService, _economyService, _map) end)
elseif name == "EnvironmentService" then
	initOk, initErr = pcall(function() service.Init(_dataService, _economyService, _map) end)
elseif name == "DimensionsService" then
	initOk, initErr = pcall(function() service.Init(_dataService, _economyService, _map) end)
```

**`wireCrossLinks` — one addition needed:** the shared setter table
already contains `SetDataService`, `SetEconomyService`,
`SetBossService`, `SetCarryService`, `SetProgressionService`
(all used by DimensionsService and wired automatically). It does
**not** contain `SetLightingService`, so add:

```lua
SetLightingService = _optional["LightingService"],
```

to the `shared` table in `wireCrossLinks` (otherwise
`DimensionsService.ApplyDimensionMood` can never find
LightingService — it fails closed and returns `false`).

**Load-order note:** `DimensionsService` needs the map built
(`Main.server` already calls `MapBuilder.Build()` before
`GameManager.Init`) and degrades gracefully if `BossService` /
`CarryService` / `ProgressionService` / `EconomyService` are absent
(warns, skips the dependent feature, keeps teleports working).

## 7. Flags for the parent / other workstreams

1. **The "v1.0.2 copy" is not a copy.** `~/workspace/your_files/
   glitch-tide-v1.1/` and `~/workspace/your_files/brainrot-battle-arena/`
   are both symlinks to the same directory
   (`~/workspace/goals/glitch-tide-brainrot-heist-the-memeverse/files/
   brainrot-battle-arena`, same inode). Every edit in this
   workstream landed in the shared tree that the `brainrot-battle-arena`
   path also resolves to. The "do not touch brainrot-battle-arena"
   instruction cannot be satisfied while both paths point at one
   directory — the parent should either split the trees or accept
   that v1.1 work lands in the shared tree (the audit already found
   `diff -r` between the two paths empty before this workstream
   started). Other workstreams are editing the same tree in parallel
   (`Companions.luau`, `QA_V11_B.md`, `QA_V11_D.md` appeared during
   this pass); only owned files were touched here.
2. **Dead paths NOT assumed (audit §3 F1/F6).** Nothing in this
   workstream depends on `Attack` or `StealBrainrot` (no client
   firers exist), on `NPCService` quest-givers/guards (never
   spawned), or on `BossUpdate` / `SynergyUpdate` (never fired).
   Sky Wisps are animated parts, not NPCs, deliberately.
3. **Lighting is global.** Dimension moods cannot be per-player
   (see §2). If the design wants per-player mood, that is a
   client-side feature, not a LightingService change.
4. **`ForbiddenRift` quest-centre shift** (see §2, Partially
   implemented) — verify `visit_rift` still completes in Studio.
5. **Part count is an estimate (575).** Confirm the runtime
   `MapBuilder` print line in Studio before claiming < 600.
6. **`luau-0.747-linux.zip` does not exist** on the Luau 0.747
   release — the Linux asset is `luau-ubuntu.zip`. The toolchain
   now lives at `/tmp/luau-compile` / `/tmp/luau-analyze` (rebuilt
   this pass; `/tmp` is wiped on VM restart, so a later pass must
   re-download it).
