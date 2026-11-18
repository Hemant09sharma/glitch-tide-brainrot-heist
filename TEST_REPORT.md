# Test Report — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

> **ARCHIVED — HISTORICAL REPORT ONLY. DO NOT USE AS CURRENT TEST STATUS.**
>
> This is the **v1.0.0** test report (2026-11-18), kept verbatim below for
> the record. It is **superseded by `QA_TEST_REPORT.md` (v1.0.1, then
> v1.0.2)**. Everything in it that contradicts the QA report is outdated:
> in particular its §6 limitations (8 base plots vs MaxPlayers 12,
> Double/Dark/GiantBoss tide variations, keybind mismatch, Magma/Spectral
> fallback mutations, and the v1.0.0 `default.project.json` `$class`
> problem) were all fixed in the v1.0.1 QA pass, and its project-file
> description predates the v1.0.2 packaging fix (`StarterGui` moved to a
> direct DataModel child; `StarterPlayerScripts` now maps only
> `Main.client.luau` + `Controllers/`). The current, authoritative test
> status is `QA_TEST_REPORT.md` only.

Version 1.0.0 — 2026-11-18. This report states exactly what was checked, with
what tool, and what the result was. **No Roblox Studio playtest was run** —
there is no Roblox Studio in this workspace — so no gameplay behaviour,
screenshot, recording, or DataStore round-trip is claimed as tested.

## Environment

- No `rojo`, `luau`, `lune`, or `stylua` binary was installed at the start.
  The Luau toolchain (luau-compile / luau-analyze, version 0.700/0.747 class)
  was downloaded to `/tmp` during the build and used for the checks below.
  It is not part of the delivered project.
- No Roblox Studio, no Studio MCP, no live Roblox DataStore access.
- Python 3 available; used for JSON validation and static cross-checks.

## Checks run (all in this workspace, 2026-11-18)

### 1. Luau compile — PASS (48/48)

Command: `/tmp/luau-compile <file>` for every `src/**/*.luau` file.

Result: **48 files, 0 failures.** Every file parses and compiles to Luau
bytecode. (An earlier invocation with an unsupported `-o` flag failed on all
files; that was a wrong command line, not a code failure — re-run correctly,
all pass.)

### 2. Luau strict analysis — PASS with documented noise

Command: `/tmp/luau-analyze --mode=strict --no-summary <all 48 files>`.

Result: 4,079 diagnostics, of which **3,886 are environment noise** caused
by the absence of Roblox API type definitions in this workspace:
2,628 "Unknown global" (`game`, `script`, `task`, `CFrame`, `Enum`, …),
793 "Unknown type" (`Model`, `Humanoid`, `BasePart`, …), 465 `*error-type*`
cascades, and 126 "Unknown require" (requires resolved through
`ReplicatedStorage:WaitForChild` / `script.Parent`, which the analyzer
cannot resolve without a place file).

Remaining ~191 diagnostics were individually spot-checked. All sampled
cases are the same root cause, not code bugs:

- `local ok, x = pcall(...)` reported as "Function only returns 1 value"
  (40x) — `pcall` is untyped without Roblox definitions.
- `HUDController.SetPlayerCount(1 arg)` / `SetWave(1 arg)` — Luau allows
  missing arguments (nil); the functions handle nil counts.
- `CharacterService` "Expected to return 2 values, but 1 is returned" —
  single `return true` in a `(boolean, string?)` function; the second value
  is nil at runtime, which callers already handle.
- `DataService` `#merged.Unlocked`, `RaidService` boolean comparison,
  `Utils` generic cast, `QuestController` union iteration — all verified by
  reading the code; no runtime defect found.

One genuine defect was found by this analysis pass and fixed (see §4).

### 3. Static cross-checks (Python) — PASS

Script: `/tmp/verify_all.py` (re-run after fixes; the first run surfaced
three items, all resolved — see §4).

- `default.project.json` is valid JSON; name `GlitchTide`; mapped dirs exist.
- 18 character entries, exactly the spec Part 7 roster; every `AbilityId`
  resolves in `Powers.luau`.
- All remote names referenced in code exist in `Remotes.Names`; all 40
  event names and 5 function names in `Remotes.luau` are declared.
- All static `require(...)` / `WaitForChild("...")` module targets exist.
- `Config.RarityWeights` sums to exactly 1.0 across 10 tiers.
- No `TODO` / `FIXME` / `placeholder` / `stub` text in `src/`.
- No copyrighted Italian Brainrot names anywhere in code or docs.
- No "Brainrot Battle Arena" branding remains in `src/`.
- 12 mutations in shared data; 10 fusion recipes point at real character ids.

### 4. Integration defects found and fixed

| # | Defect | Fix |
|---|---|---|
| 1 | `tung_tung` fallback id in 8 files after the roster replacement | Replaced with `wobble_waffleton` (starter) in server + client |
| 2 | `PlayerStats` declared RemoteFunction, used as RemoteEvent everywhere | Moved to `EVENT_NAMES` in `Remotes.luau` |
| 3 | `QuestUpdate`, `EquipCosmetic` remote names referenced but undeclared | Added to `Remotes.Names` (`EquipCosmetic` reserved/inert; cosmetics equip via `SelectCharacter` envelope) |
| 4 | `Config.ConveyorRarityWeights` covered 6 tiers only | Replaced with all 10 tiers, aligned with `RarityWeights` |
| 5 | `CombatService` never initialised by anyone | Initialised in `Main.server.luau` after `GameManager.Init` |
| 6 | `MutationService.loadMutationTable` read `entry.IncomeMult` (shared data uses `IncomeMultiplier`) and kept capitalised ids — all 12 shared mutations would have loaded at 1x income and been unfindable by lowercase id | Normalise ids to lowercase, read `IncomeMultiplier`, restore rebirth gating (Void/Celestial 1, Rainbow 2) |
| 7 | Stale docs: old Italian roster table, "names need review", "MapBuilder/GameManager missing", "quests/rebirth unconfirmed" | Corrected in `README.md`, `THIRD_PARTY_NOTICES.md`, `CHANGELOG.md`, `GROK_BUILD_HANDOFF.md` |

### 5. ZIP integrity — PASS

- ZIP created at `~/workspace/your_files/glitch-tide-brainrot-heist.zip`
  from the project root; verified by unzipping to a fresh temp directory
  and comparing the file tree (see §6 for the exact counts).
- No absolute workspace paths inside the project; all paths are relative.

### 6. Final counts

- 59 files in the project (57 before this report's two new files).
- 22,805 lines of Luau across 48 `.luau` files (plus docs).
- 18 Brainrots, 12 mutations, 12 playable powers + 18 primary abilities,
  16 quests, 6 world events, 21 server services, 15 client controllers.

## NOT run — Grok Build must run these in Roblox Studio

The following were **not** run and must **not** be reported as passed:

1. `rojo build -o GlitchTide.rbxl` (no Rojo binary here) and `rojo serve` sync.
2. Opening the place in Roblox Studio; any Studio playtest (solo or
   2-client), including the Part 36 acceptance scenario: spawn → base →
   market buy → carry → tide warning → escape → place → income → upgrade →
   ability → mutation/fusion → quest → save/rejoin → 2-player raid.
3. Live DataStore save/load round-trip (needs Studio API access enabled).
4. Any performance measurement (frame rate, memory, part counts in Studio).
5. Any screenshot, video, or recording of gameplay.
6. Publishing, icon/thumbnail upload, or make.fun submission (not our job).

Known Studio-only risks to check first (from the analysis above):
- Strict-mode type noise will disappear once Roblox definitions are
  present; if `luau-analyze` in Studio still flags a file, check that file
  first (list in §2).
- `Config.AbilitySlots` still lists the older Q/E/R generic mapping while
  the client ships Q primary / F Slam / R Heal / E Interact.
- `MutationService`'s local fallback table contains "Magma" and "Spectral"
  mutations that the shared 12-mutation table does not; with the shared
  module present (normal case) only the 12 shared mutations exist.
- 8 base plots vs `MaxPlayers = 12`: the 9th+ concurrent player gets no
  base (warned in Output); everything else still works.


---

## Appendix — what superseded this report (added 2026-11-18, v1.0.1 / v1.0.2)

This appendix is the only part of this file written after v1.0.0. It maps
each outdated limitation in this report to its fix, so nobody has to
guess which parts are still true:

| This report's v1.0.0 claim | Current status (see QA_TEST_REPORT.md) |
|---|---|
| 8 base plots vs MaxPlayers 12 | Fixed v1.0.1: 12 plots = 12 players |
| Double / Dark / GiantBoss tide variations | Demoted to data-only in v1.0.1; only Standard / Fast / Toxic / Frozen / Meteor are playable |
| Keybind mismatch (Q/E/R vs Q/F/R/E) | Fixed v1.0.1: canonical Q primary / F Slam / R Heal / E interact / G drop |
| Magma / Spectral fallback mutations | Removed v1.0.1; shared 12 mutations only |
| `default.project.json` used `$class` | Fixed v1.0.1: `$className` |
| `StarterGui` nested inside `StarterPlayer` | Fixed v1.0.2: `StarterGui` is a direct DataModel child mapping to `src/client/ui`; `StarterPlayerScripts` maps only `src/client/Main.client.luau` (as `Main`) + `src/client/Controllers` |
| `src/map/README.md` inside the Workspace tree | Fixed v1.0.2: moved to `docs/map.md`, outside the Rojo tree; `src/map/` holds only an empty `.gitkeep` |
| Camera stuck at spawn (not in this report) | Fixed v1.0.1: CameraManager in CameraController; see QA_TEST_REPORT.md §1 |

No Roblox Studio playtest has been run in this workspace at any version;
that limitation remains true and is stated in QA_TEST_REPORT.md §6.
