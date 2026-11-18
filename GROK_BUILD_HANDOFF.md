# GROK BUILD HANDOFF — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

**For:** Grok Build (Studio integration, competition packaging, publishing,
and make.fun submission).
**From:** Muse (game code + documentation only).
**Version:** v1.0.2 — 2026-11-18 (packaging correction on top of v1.0.1; no gameplay changes).

**Read first:** run the camera regression test in §1 *before* anything
else. It is the highest-risk item in this delivery: the camera fix is
verified only statically here, never in Studio. If §1 fails, stop and
fix the camera — do not proceed to the acceptance scenario.

Muse does **not** do publishing or submission. Everything in this document
after step 9 is Grok Build's job. Muse has not run a Studio playtest, has
not produced screenshots or recordings, and has not published anything.

---

## 1. Camera regression test — RUN THIS FIRST

The v1.0.1 camera fix is the highest-risk change in this delivery: it was
verified statically only (grep + `luau-compile` + code review), never in a
running Studio session. Run this test **before** the acceptance scenario
(§4). Any failure here is a blocker — do not publish, do not proceed.

**Root cause it fixes:** the default Roblox camera only (re)binds its
subject when the engine spawns a character (`CharacterAdded`).
`CharacterService` morphs the player by *destroying* the default avatar
and assigning `player.Character = <custom Brainrot model>` — that
assignment does **not** fire `CharacterAdded`, so the default camera kept
pointing at the destroyed Humanoid and stayed frozen at the spawn point
while the player walked away. `CameraController` now owns the binding
explicitly (rebind on `CharacterAdded` + `player.Character` property
change + respawn + teleport + death/recovery, 0.5 s watchdog, snap when
the camera is > 50 studs from the root), and `CharacterService` makes the
morphed model a valid camera subject (PrimaryPart = HumanoidRootPart,
root unanchored, new model parented before the old one is destroyed).

| # | Step | Pass when… |
|---|---|---|
| 1.1 | Spawn | Play solo. The camera follows the character from spawn; the character is centred on screen, not stuck at the spawn point |
| 1.2 | Walk 100 studs | Walk in a straight line ~100 studs from spawn. The camera tracks the character the whole way — no frozen view, no camera left behind |
| 1.3 | Morph switch | Switch character (character-select UI / `SelectCharacter`). The camera rebinds to the new Brainrot model immediately; no black screen, no view of the old/destroyed model |
| 1.4 | Teleport blink | Use the Teleport loadout power (blink). The camera snaps to the character at the new location within ~1 s; it is not left at the old location |
| 1.5 | Death / respawn | Die (fall / NPC) and respawn. The camera follows the fresh character; it does not stay on the corpse or at the death spot |
| 1.6 | 60 s idle | Stand still for 60 s. The camera stays bound and stable — no drift, no snap to spawn, no `CameraType` change in Output |
| 1.7 | Output check | No camera-related errors/warnings in Output during 1.1–1.6 (no "CameraSubject is nil", no bind-timeout warnings) |

**If 1.3 fails** (camera does not follow after a morph): check
`CharacterService.ApplyCharacter` — the new model must have
`PrimaryPart = HumanoidRootPart`, an unanchored root, a live Humanoid,
and must be parented to `workspace` *before* the old model is destroyed
and `player.Character` is reassigned. **If 1.4 fails**: check
`CameraController`'s snap (50-stud threshold) and the 0.5 s watchdog.
**If any step shows a Scriptable camera**: nothing in this game sets a
scripted camera — a non-Custom `CameraType` is stale and the watchdog
should have rebound it; report the exact Output lines.

## 2. What you are receiving

- A Rojo 7.7 project: `default.project.json` + `rojo.toml` + `src/`
  (shared / server / client / map). See `README.md` §10 for the
  service mapping.
- **A prebuilt place file is included: `GlitchTide.rbxl`** (333,816 bytes,
  built in this workspace with Rojo 7.7.1 and verified — decompressed — to
  contain all 48 script sources). Open it directly in Studio to skip
  step 4, or rebuild it yourself to confirm the build (step 4).
- Documentation: `README.md`, `QA_TEST_REPORT.md` (v1.0.2 test report),
  `FEATURE_CHECKLIST.md`, `THIRD_PARTY_NOTICES.md`, `CHANGELOG.md`,
  `TEST_REPORT.md` (archived v1.0.0 report — historical only),
  `docs/map.md` (world note, outside the Rojo tree),
  `LICENSE` (MIT, "Glitch Tide Contributors", 2026).
- No screenshots, recordings, or published place exist yet.

**Tree completeness (v1.0.2, verified):** all 48 Luau files are present,
every module `Main.server.luau` requires resolves, `luau-compile` passes
48/48, and `rojo build` succeeds — see `QA_TEST_REPORT.md`. The old
2026-11-18 warning about missing `MapBuilder` / `GameManager` no longer
applies.

**Packaging check (v1.0.2, do this in Studio after opening the place or
syncing):** in the Explorer, confirm `StarterGui` (a real service, direct
child of the DataModel) contains `MainMenu`; `StarterPlayer →
StarterPlayerScripts` contains exactly `Main` (LocalScript) and
`Controllers/` (14 controllers); and `Workspace` is empty (the arena is
built at runtime by `MapBuilder`). If `MainMenu` is missing from
`StarterGui`, or a `ui` folder appears under `StarterPlayerScripts`,
you are looking at the old v1.0.1 project file — stop and use the
v1.0.2 `default.project.json`.

**Project-file note:** `default.project.json` uses `$className` (not
`$class`) for the DataModel root — Rojo 7.7 rejects `$class` with
"Failed to deserialize JSON". Do not "fix" it back to `$class`. It also
maps `StarterGui` as a direct DataModel child (`src/client/ui`) and
`StarterPlayerScripts` as only `Main` + `Controllers/` — do not move
`StarterGui` back under `StarterPlayer` (v1.0.1 did that, and the menu
never appeared because `MainMenu` was never cloned into `PlayerGui`).

Canonical keybinds are `README.md` §8 (Q primary, F Slam, R Heal,
E Interact, G Drop, 1/2/3 loadout, B Shop, N Market, J Quests, C
Brainrots, V Base, L Collection, M Mute).

---

## 3. Build steps

### Step 1 — Unzip
Unzip the project to a working folder. Keep the folder structure intact:
`default.project.json` and `rojo.toml` must stay in the project root next
to `src/`.

### Step 2 — Install Rojo 7.7 + the Studio plugin
1. Install the Rojo 7.7 CLI. Official instructions:
   <https://rojo.space/docs/v7/getting-started/installation/>
   With Rokit, pin it, e.g. `rojo = "rojo-rbx/rojo@7.7.0"` in `rokit.toml`.
2. Install the Rojo Studio plugin from the same Rojo 7.7 release.
   The plugin major version must match the CLI major version (Rojo 7
   plugin with Rojo 7 CLI).
3. Verify the CLI works:
   ```sh
   rojo --version
   ```

### Step 3 — `rojo serve` + connect in Studio
1. In a terminal in the project root, run:
   ```sh
   rojo serve
   ```
   It listens on `127.0.0.1:34872` by default (see `rojo.toml`).
2. Open Roblox Studio and open a new baseplate place.
3. In the Rojo plugin, click **Connect**. The project tree should sync
   into Studio: `ReplicatedStorage` ← `src/shared`,
   `ServerScriptService` ← `src/server`,
   `StarterGui` ← `src/client/ui`,
   `StarterPlayerScripts` ← `src/client/Main.client.luau` (as `Main`)
   + `src/client/Controllers`, `Workspace` ← `src/map` (empty —
   `MapBuilder` builds the arena at runtime). Verify the packaging
   check in §2 (Explorer: `StarterGui → MainMenu`,
   `StarterPlayerScripts → Main + Controllers/`) before playtesting.
4. Edit Luau files on disk from here on; do not edit Rojo-managed scripts
   inside Studio — the next sync overwrites them.

### Step 4 — `rojo build -o GlitchTide.rbxl`
```sh
rojo build -o GlitchTide.rbxl
```
(`rojo.toml` also sets the default build output to `GlitchTide.rbxl`.)
A successful build prints no errors and writes the place file. Open it in
Studio to confirm it loads. **Already verified in this workspace with
Rojo 7.7.1** (the included `GlitchTide.rbxl` is that build) — re-run it
here mainly to confirm your Rojo install matches. If your Rojo reports
"Failed to deserialize JSON", check `default.project.json` still uses
`$className`, not `$class` (see §2).

### Step 5 — Enable Studio Access to API Services
In Studio: **Game Settings → Security → Enable Studio Access to API
Services**. This is required for DataStore testing in Studio; without it,
saves fail in playtests (live-game DataStores do not need this setting).
This is the single most common cause of "DataStore errors in Studio".

### Step 6 — Run the camera test, then the acceptance scenario
Run the camera regression test in §1 first, then the full scenario in §4 below (Part 33/36 acceptance scenario).
Every check must pass with a clean Output window.

### Step 7 — Fix any Output errors
Fix, rebuild (`rojo build -o GlitchTide.rbxl` or re-sync via
`rojo serve`), and re-run the failing part of the scenario. Do not publish
with Output errors outstanding.

### Step 8 — Screenshots
Capture screenshots (and a short recording if the competition entry
needs one) from the built place in Studio / a test server: conveyor with
Brainrots, a populated base, the Glitch Tide in progress, a steal in
progress, and the HUD/shop. No screenshots exist yet — these are yours to
produce.

### Step 9 — Publishing + make.fun submission (Grok Build's job)
Publish the place to Roblox from Studio (File → Publish to Roblox As…),
configure the game page, and submit to make.fun per the competition's
current submission instructions. **This step is Grok Build's job, not
Muse's, and it has not been done.**

---

## 4. Acceptance scenario (Part 33/36)

Run in Studio with 2 clients where a step needs a second player
(Test tab → Clients and Servers → Players: 2 → Start). The Output window
must stay free of errors throughout.

| # | Check | Pass when… |
|---|---|---|
| 1 | Spawn | Player spawns in the lobby; no startup errors; Output shows remotes created, map built, DataService / EconomyService / GameManager initialised |
| 2 | Base | Player claims a personal base with 4 starting slots |
| 3 | Market buy | A Brainrot is bought from the conveyor with coins; balance decreases correctly |
| 4 | Carry | Bought Brainrot is carried; movement is visibly slower (0.6×) |
| 5 | Tide | A Glitch Tide occurs (or is forced by shortening `GlitchTideIntervalSeconds` for the test only); conveyor floods with Glitched Brainrots and income doubles for 60 s |
| 6 | Place | Brainrot placed on a base slot; income starts ticking every second |
| 7 | Income | Coins increase over time at the expected rate for the placed Brainrot(s) |
| 8 | Upgrade | A base upgrade is bought (slot, income multiplier, lock, or turret); cost deducted and effect visible |
| 9 | Ability | Q (primary), F (Slam), R (Heal) each fire; E is Interact (not an ability) and G drops a carried Brainrot; confirm the final keybinds match `README.md` §8 and correct the docs if they differ |
| 10 | Mutation | A Glitched Brainrot is bought/placed; its 1.5× price and bonus income apply |
| 11 | Quest | Complete a quest objective (`QuestService`, 16 quests) and claim its reward; confirm the Quests panel (J) loads the live list via `RequestQuests` on open, not only after progress changes |
| 11b | Fusion | Buy two Brainrots, leave both unplaced, open the Shop → Fusion tab, select the recipe pair and press FUSE — the recipe result appears in the inventory and both inputs are consumed (cost: 1,000 coins + 25 Mutation Crystals) |
| 11c | Golden Hour | Force or wait for a Golden Hour event; confirm the HUD event banner announces it and base income doubles (stacks with the Tide 2×) |
| 12 | Save / rejoin | Stop the test, restart, and confirm coins, Brainrots, and upgrades persisted (requires Step 5's API-access setting) |
| 13 | 2-player raid | Player 2 enters Player 1's unlocked base, channels 3 s, grabs a Brainrot, and carries it home — steal succeeds; then repeat with Player 1 defending (knock-out mid-carry) — steal fails and the Brainrot drops |
| 14 | Clean output | No errors or warnings that indicate broken logic remain in the Output window at the end |

If check 11 or any other check cannot be performed because a module is
missing, record it as a gap and fix the code — do not mark it passed.

---

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Rojo plugin will not connect / nothing syncs | `rojo serve` not running; wrong port; plugin major version mismatched with CLI | Start `rojo serve` in the project root first; check it listens on `127.0.0.1:34872`; install the Rojo 7 plugin to match the Rojo 7 CLI |
| Rojo syncs but Studio shows an empty / partial tree | `default.project.json` paths wrong, or Studio place already had conflicting instances | Confirm the project root contains `default.project.json` next to `src/`; sync into a fresh baseplate place; check the `rojo serve` terminal for errors |
| `rojo build` fails | Project file error, or a `.luau` syntax error in `src/` | Read the exact build error; fix the named file/line; re-run `rojo build -o GlitchTide.rbxl` |
| `rojo build` fails with "Failed to deserialize JSON" | `default.project.json` uses `$class` instead of `$className` | Change the DataModel root key to `$className` (the shipped file is already correct — do not revert it) |
| Camera stuck at spawn after morph / teleport / respawn | Camera did not rebind (see §1) | Run the §1 regression test; check `CameraController` watchdog + `CharacterService.ApplyCharacter` (PrimaryPart, unanchored root, parent-before-destroy order) |
| Fusion tab shows no Brainrots to fuse | Fusion only takes *unplaced* instances; everything owned is placed | Buy a Brainrot and leave it unplaced — placed Brainrots are rejected by design; the Fusion tab lists the `Unplaced` inventory from `RequestBase` |
| Remotes missing at runtime (`WaitForChild` hangs / nil remote) | `Main.server.luau` did not run, or `Remotes.CreateRemotes` was skipped | Confirm `Main.server.luau` is in `ServerScriptService` and runs first; check Output for its startup prints; remotes are created by the server at startup, never by clients |
| DataStore errors in Studio (save/load failures) | Studio Access to API Services not enabled | Game Settings → Security → Enable Studio Access to API Services; restart the playtest. Note: DataStores do not work in Studio without this, and `BindToClose` does not run the same way in Studio as on live servers |
| Data loss / duplicated items after fast rejoin | Session-lock / save-order issue in `DataService` | Check `DataService.luau` save paths (autosave, leave, `BindToClose`); saves must be `pcall`-guarded with retries; do not run two servers owning the same player's key at once |
| Character morph errors (Brainrot model fails to appear / wrong parts) | `CharacterService` / `Characters.luau` definition mismatch (bad `BodyShape`, `Prop`, or Id) | Check Output for the exact error; confirm the character Id exists in `Characters.luau` and its `BodyShape`/`Prop` values are ones the morph code handles |
| Conveyor not spawning Brainrots | `GameManager` / economy loop not started, or conveyor config wrong | Confirm `GameManager.Start()` runs (Output print from `Main.server.luau`); check `Config.ConveyorSpawnInterval` (8 s) and `Config.ConveyorMaxItems` (8); look for errors from the economy/conveyor loop in Output |
| Abilities do nothing | Wrong keybinds, or client controller not wired | Confirm the bindings in `Config.luau` (`AbilitySlots` / `GenericAbilities`) and `Powers.luau`; check `Main.client.luau` wires the controllers; correct `README.md` §8 if the binding differs |
| "Not a valid member" require error at startup | A module `Main.server.luau` requires is missing from `Services/` | Confirm `MapBuilder`, `GameManager`, `DataService`, and `EconomyService` all exist under `src/server/Services/`; restore the missing module before building |
| Map is empty / no bases, conveyor, or lobby | `MapBuilder.Build()` failed or was not called | Check Output for the MapBuilder print/error; the map is built at runtime, not stored as parts — `src/map` intentionally contains only a README |

---

## 6. Dependencies

- **Rojo 7.7 only.** No other packages, no Wally / pesde dependencies,
  no third-party libraries are used by this project.
- The project uses only Roblox engine services (see §6) and the Rojo
  tool itself. Rojo is a build/sync tool; it is not bundled into the game.

## 7. Roblox services used

`DataStoreService` (player data + leaderboard), `Players`,
`ReplicatedStorage`, `ServerScriptService`, `StarterPlayer` /
`StarterPlayerScripts`, `StarterGui`, `Workspace`, `RunService`,
`UserInputService` (client input / mute key), `Teams` (Red / Blue),
`SoundService` (via the client sound controller where applicable).
No external asset IDs, no HTTP requests, and no third-party plugins are
required at runtime.

## 8. Do not change without asking

- Do not rename modules under `src/shared` or `src/server/Services` —
  they are required by name (`Config`, `Remotes`, `MapBuilder`,
  `GameManager`, `DataService`, `EconomyService`, …).
- Do not edit Rojo-managed scripts inside Studio while `rojo serve` is
  running — disk is the source of truth.
- Do not publish with Output errors outstanding or with the acceptance
  scenario incomplete.
