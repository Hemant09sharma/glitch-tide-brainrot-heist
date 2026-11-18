# QA — Wave 3, Workstream E: UI REDESIGN + SOUND + MULTIPLAYER/REMOTES + OPTIMIZATION (v1.1)

**Date:** 2026-11-19
**Work dir:** `~/workspace/your_files/glitch-tide-v1.1/` (git repo; pristine v1.0.2 tree at `~/workspace/your_files/brainrot-battle-arena/` untouched — `Config.GameVersion` verified `"1.0.2"` there, `"1.1.0"` here).
**Status: WORKING — NOT "READY".** This is a static-verified client workstream: `luau-compile` 19/19, static checks (a)–(d) pass (see §8). **No Studio playtest was run here and none is claimed.** The game still needs a Studio playtest (Grok Build) before any "ready" claim, and one honest gap remains: `EquipTitle` has no server handler (§6.4), so title equips do not persist yet.
**Companion doc:** `docs/REMOTES_WIRED_E.md` (every remote added, every listener wired, every dead path fixed or left, `UsePower` decision).

---

## 1. Files changed / added (line counts are current totals)

| File | Lines | Change |
|---|---|---|
| `src/shared/Remotes.luau` | 341 | +17 remote names; WIRED/UNWIRED contract comment rewritten |
| `src/client/Controllers/PanelKit.luau` | 280 | NEW — shared panel helpers (library, no `Init()`) |
| `src/client/Controllers/SoundController.luau` | 524 | Rewritten (was 281): new cues, 3 volume buses, 5 named unassigned slots |
| `src/client/Controllers/EffectsController.luau` | 848 | Was 666: dual-form `SpawnEffect`/`DamageNumber`, capital-key tide fix, damage-number cap |
| `src/client/Controllers/DimensionController.luau` | 411 | NEW — Worlds panel + `DimensionUpdate` listener |
| `src/client/Controllers/LaboratoryController.luau` | 848 | NEW — Mutation Lab (evolve / traits / recipes / forms / mutate / fuse) |
| `src/client/Controllers/ExpeditionController.luau` | 378 | NEW — Expedition panel |
| `src/client/Controllers/TerritoryController.luau` | 290 | NEW — Territory panel |
| `src/client/Controllers/AchievementController.luau` | 411 | NEW — Achievements + Titles panel, `SecretDiscovered` banner |
| `src/client/Controllers/HUDController.luau` | 1534 | Was 1172: boss bar, tide stage line, title slot, death/victory screens, 2nd menu row, welcome banner, `BossUpdate` listener, `RequestEvents` fetch, dead fires removed |
| `src/client/Controllers/InteractionController.luau` | 885 | Was 591: steal scan + firer, `StealAlert` listener, steal watchdog |
| `src/client/Controllers/AbilityController.luau` | 645 | Was 549: left-click Attack firer, touch ATTACK button, session power-use tracking |
| `src/client/Controllers/BaseController.luau` | 705 | Was 612: Prestige button, `StealAlert` payload fix, dead `GetBase` removed |
| `src/client/Controllers/ShopController.luau` | 1059 | Was 965: Powers mastery display, Lab shortcut, on-expedition fuse filter, dead `GetBase` removed |
| `src/client/Controllers/CollectionController.luau` | 416 | Was 385: actually calls `RequestCollection`; roster count fixed 18 → 27 |
| `src/client/Controllers/QuestController.luau` | 456 | Was 427: grouped by Category, claim debounce, dead `RequestQuests` event branch removed |
| `src/client/Controllers/CharacterSelectController.luau` | 498 | Was 491: `CompanionAbility` on cards (card 196 → 214 px), dead `GetStats` invoke removed |
| `src/client/Main.client.luau` | 231 | Was 202: 17 new remotes in the wait list, 5 new controllers in `CONTROLLER_ORDER` |
| `src/client/ui/MainMenu.luau` | 801 | Was 606: two-column menu, 5 new-panel shortcuts, OBJECTIVES, Master/SFX/Music steppers |
| `docs/QA_V11_E.md` | — | THIS DOC |
| `docs/REMOTES_WIRED_E.md` | — | Remote inventory + decisions |

**Totals:** 6 new files (2,618 lines), 13 edited files (~1,655 net new lines), 2 new docs. No forbidden file was edited (`CHANGELOG.md`, `FEATURE_CHECKLIST.md`, `README.md`, `QA_TEST_REPORT.md`, `Config.luau`, `GameManager.luau`, `Main.server.luau`, any server service file) — verified by mtime sweep over the session window.

---

## 2. Part 16 classification — every feature

Legend: ✅ Wired & verified (static) · ⚠️ Wired with a known limit · ❌ Not done / deliberately left.

### Part 11 — UI REDESIGN

| Feature | Status | Notes |
|---|---|---|
| MainMenu redesign (two-column, new-panel shortcuts) | ✅ | PLAY / COLLECTION / SETTINGS / HOW TO PLAY / OBJECTIVES + LAB / EXPEDITIONS / TERRITORY / WORLDS / ACHIEVEMENTS; touch layout widens buttons; PLAY poof kept |
| HUD second menu row | ✅ | LAB / EXPEDITIONS / TERRITORY / WORLDS / ACHIEVEMENTS via existing `openController` |
| HUD boss health bar | ✅ | `BossUpdate` listener; spawn/death banners + sounds |
| HUD tide stage line (10-stage anticipation) | ✅ | `Stage` / `StageName` / `Announcement` from `GlitchTideUpdate`; `EscapeRoutes` (stage 5) NOT drawn — no client map-marker API exists (see §6.5) |
| HUD equipped-title slot | ⚠️ | Displays the locally-equipped title; persists only after the `EquipTitle` handler is wired (§6.4) |
| Death / victory / respawn screens | ✅ | `Humanoid.Died` → death screen (hidden on respawn rebind); `TideSurvivor` survived → victory screen + banner |
| Welcome banner (first open) | ✅ | One-line onboarding on first `Init` |
| Mutation Lab panel | ✅ | Evolve / traits / recipes / alternate forms / mutate / fuse; costs from shared `LabDefs` (server return lacks them — see REMOTES_WIRED_E §7) |
| Expedition panel | ✅ | Start / claim / status; 1 s countdown tick only while open + active |
| Territory panel | ✅ | Capture / status / flat income (tier 1: 5 coins/s + 10 XP/min; tier 2: 10 + 20; tier 3: 15 + 30 — NOT a multiplier); manual refresh + push, no polling |
| Achievements + Titles panel | ⚠️ | List/progress/equip work; equip is local-only until the handler is wired (§6.4) |
| Quests (grouped chains) | ✅ | Grouped by Category (story/daily/weekly/expedition/territory/secret/…); claim debounce 2 s per quest |
| Rebirth + Prestige panel | ✅ | Rebirth (existing) + Prestige button firing `Rebirth {Action="Prestige"}` with documented requirements (10 rebirths, Lv 25, 250,000 coins, 15 distinct Brainrots); server validates |
| Shop Powers mastery display | ⚠️ | Formula shown (true) + session-only use counts (labelled session-only); the server pushes NO mastery state, so the real mastery level cannot be shown (no `PowerMasteryUpdate` exists) |
| World Selection (dimensions) | ✅ | Hub + Abyssal (Lv 5) + Skyfall (Lv 15) cards with chests/checkpoint/exclusive character; level gates are display-only — the server enforces them (`TeleportDenied`) |
| Event notifications (tide/boss/rare/secret) | ✅ | Tide stages, boss spawns, rare acquisitions (`SoundHook`), secret discoveries (generic banner only — payload carries no secret id/name) |
| Character cards (companion ability) | ✅ | `CompanionAbility` shown as e.g. "Companion: IncomeBonus +5%" |
| Collection (X / 27) | ✅ | Actually calls `RequestCollection`; count fixed from the stale 18 |
| Rarity presentation | ✅ | `RarityColors` reused everywhere (cards, chips, strokes) |
| Mobile support | ✅ | Touch layouts in MainMenu (wider two-column buttons), HUD (compact panels), Lab/Expedition/Territory/Achievement/Dimension panels (0.94 × 0.86), touch ATTACK + Interact buttons; every new panel button is a real `TextButton` |
| Every button does something real | ✅ | Static check (b): every `TextButton` in client code has a `MouseButton1Click` connection, or is built via `PanelKit.MakeButton` (which always connects one). Zero display-only buttons in the new code |

### Part 12 — SOUND (see §5 for the full inventory)

| Feature | Status | Notes |
|---|---|---|
| Verified built-in sounds wired | ✅ | 34 named cues on `rbxasset://sounds/...` paths verified by web search (see §5) |
| Market ambience loop | ❌ | No verified built-in loop exists — named unassigned slot `marketAmbience` |
| Conveyor loop | ❌ | No verified built-in loop exists — named unassigned slot `conveyorLoop` |
| Background music | ❌ | No verified built-in music exists — named unassigned slot `music`; music volume stored, scales nothing audible today |
| Dimension ambience loop | ❌ | Named unassigned slot `dimensionAmbience` |
| Tide siren loop | ⚠️ | One-shot siren cue IS assigned (`PlaySiren`, stage 3 + `TideSiren` table effect); the loop is an unassigned slot `tideSirenLoop` |
| Rare / secret acquisition sounds | ✅ | `EventUpdate.SoundHook` ("rare"/"secret") → `PlaySoundHook` |
| Volume controls (Master / SFX / Music) | ✅ | MainMenu Settings steppers (100 → 70 → 40 → 100) + mute (M); client-local by design |
| Server sound sync (`SettingsUpdate`) | ❌ | Deliberately unwired — no server settings store exists (see §6.1) |
| Server `SoundService` | ❌ | Not created — not needed; every sound is a client-side one-shot on a broadcast the client already receives |

### Part 13 — MULTIPLAYER

| Feature | Status | Notes |
|---|---|---|
| Multiple players (per-player state) | ✅ | Verified: controllers only ever read the local player's state (`LocalPlayer`, `RequestBase`/`RequestShop`/`RequestLab` etc. are per-player server functions); the steal scan excludes own instances and resolves victims by `OwnerSign`/proximity, never by assuming shared state |
| Shared events (tide/boss/event banners) | ✅ | All three are server broadcasts with client listeners (§2 of REMOTES_WIRED_E) |
| Raids / stealing (firer now exists) | ✅ | `StealBrainrot` firer + `StealAlert` both sides; server still validates protection/cooldown/gate/distance |
| Carrying | ✅ | Unchanged; `CarryUpdate` feed + HUD chip + `AnimationController` pose |
| Respawning (camera re-bind) | ✅ | `CameraController` logic untouched (verified by grep: `CharacterAdded` + `Character` property change + CurrentCamera change, Custom + live Humanoid, 0.5 s watchdog, teleport snap); death screen hides on respawn rebind |
| Base ownership | ✅ | Steal victim resolution reads the plot `OwnerSign` ("BASE n\n\<ownerName\>") |
| Event rewards | ✅ | Shown from server pushes only (`QuestUpdate`, `AchievementUnlocked`, `ExpeditionUpdate`, `TideSurvivor`); the client never claims a reward on its own |
| Duplicate prevention | ✅ | Debounce guards added: quest claims (2 s per quest), Lab actions (1 s per action), expedition start/claim (1 s), territory capture (1 s), title equip (1 s), steal (1 s + 60 s per-victim pair), Attack (0.45 s), `PanelKit.Debounce` on every new-panel fire |
| Client-trusted values found | ⚠️ | One pre-existing pattern remains, documented not fixed: `HUDController.SetTideStage` trusts the server's `Stage`/`StageName` for display only (display-only, no gameplay effect). No client value is sent to the server as authority — every purchase/claim/evolve is a server-validated request |

### Part 14 — ONBOARDING / PRESENTATION

| Feature | Status | Notes |
|---|---|---|
| Spawn entrance (PLAY poof) | ✅ | Kept: `EffectsController.Poof` at spawn on PLAY (local, direct — the old server fire never happened) |
| First-time tutorial hints | ✅ | Welcome banner + OBJECTIVES button (live top quest or static starter chain) + quest tracker on the HUD |
| Immediate objectives | ✅ | Starter quest chain visible from the menu and the HUD tracker; `QuestController.GetTopQuest` |
| Visual hierarchy | ✅ | Big dark banner headings in panels, gold titles, rarity-coloured strokes/chips, status line under every panel title |

### Part 15 — OPTIMIZATION (client-side only; server notes are documentation only)

| Change | Notes |
|---|---|
| Removed dead 5 s `PlayerStats` polling fallback (`HUDController`) | `PlayerStats` is a server-pushed event; the poll invoked a RemoteFunction that does not exist |
| Removed dead `FireServer("GetStats")` / `FireServer("GetBase")` / `RequestQuests`-as-event fires | 5 dead fires removed across HUD/Base/Shop/Quest/CharacterSelect (see REMOTES_WIRED_E §3) |
| Steal scan folded into the existing 0.25 s loop | No new loop; the `workspace:GetDescendants()` walk runs once every 5 s into a cache, per-tick work is distance checks only |
| Damage-number cap (40 live anchors) | `EffectsController`: beyond 40, new numbers are dropped instead of spawning unbounded GUI/parts in a big fight |
| Quest tracker refreshes on `QuestUpdate` only | No polling; `RefreshQuestTracker` is called from `ApplyQuests` |
| Expedition countdown ticks only while the panel is open and a trip is active | 1 s ticker stops on close / when no trip is active |
| Territory refreshes on push + manual refresh | No polling |
| HUD updates on change, not every frame | Unchanged; `AbilityController`'s 6-slot cooldown ticker is cheap and stays |
| Server-side optimization notes (documentation only, no service rewrites) | `BossUpdate` fires every 2 s while a boss is alive (not every frame) — acceptable. `TerritoryUpdate` broadcasts to ALL players on every change — fine at 7 territories, but a future per-player delta would scale better. `DimensionUpdate` is per-player. No service file was edited |

---

## 3. Bug fixes in scope (all in client code)

1. **`SpawnEffect` payload mismatch** — servers fire both positional `(string, Vector3, extra)` and table `{type, position, ...}` forms; `EffectsController` only handled positional, so most server FX was a silent no-op. Now accepts both; D's table types mapped; unknown table types with a position degrade to a visible ring + burst; count-only table fires (no position) are ignored by design.
2. **`DamageNumber` table form** — server fires `{target, amount, isCrit, isHeal}`; both `EffectsController` and `HUDController` only handled positional. Both fixed.
3. **`GlitchTideUpdate` capital keys** — server sends `Phase`/`TimeLeft`; `EffectsController` only read lowercase `phase`/`secondsRemaining` and compared case-sensitively, so tide visuals never ran. Fixed (reads both, lowercases), plus stage-3 siren.
4. **`StealAlert` parsing** — `BaseController` read `ThiefName`/`CharacterName`/`BrainrotName`/`Name`, none of which exist; the banner always showed "Someone" / "a Brainrot". Now parses `{Thief, ThiefUserId, Victim, CharacterId, Phase}` + Lockdown variant; character name resolved via the `Characters` catalogue.
5. **Dead fires** — 5 removed (see REMOTES_WIRED_E §3 #6–#9) plus the `SpawnEffect`/`DamageNumber`/`GlitchTideUpdate` mismatches above.
6. **On-expedition instances in buy/place/fuse UI** — the active expedition's instance is now excluded from the Lab (evolve/traits/mutate/fuse/forms) and the Shop fuse list (via `ExpeditionController.GetActiveInstanceId()`; only one trip can be active, so excluding that one id is sufficient). The server enforces `OnExpedition` only at the expedition API — the client exclusion is the UI half.
7. **Collection count** — "X / 18" was stale (roster is 27 since Wave 1); now "X / 27" and driven by `RequestCollection.Total`.

---

## 4. Multiplayer / remotes summary (detail in REMOTES_WIRED_E.md)

- **17 remotes added** (13 C + 3 A + `EquipTitle` per C's Wave-3 instruction; B and D needed none).
- **Listeners wired:** `BossUpdate` (HUD), `DimensionUpdate`, `LabUpdate`, `ExpeditionUpdate`, `TerritoryUpdate`, `AchievementUnlocked`, `SecretDiscovered`; `EventUpdate.SoundHook`; `GlitchTideUpdate` stage fields; `StealAlert` thief side.
- **Dead paths fixed:** 14 (Attack firer, StealBrainrot firer, `RequestCollection`, `RequestEvents`, `BossUpdate` listener, 5 dead fires, 3 payload mismatches, `StealAlert` parsing, `SoundHook`).
- **Decisions:** `UsePower` stays unwired (alias of `UseAbility`); `SettingsUpdate` stays unwired (no server store); `SynergyUpdate` stays reserved (never fired); `EquipTitle` handler-pending (§6.4).

---

## 5. Sound inventory (Part 12) — verified vs unassigned

### Verified sources (web search, 2026-11-19)

| Source | What it verified |
|---|---|
| Roblox client script `RbxCharacterSounds.lua` (CloneTrooper1019 / Roblox-Client-Tracker, raw.githubusercontent.com, fetched 2026-11-19) | `action_get_up.mp3`, `action_jump.mp3`, `action_jump_land.mp3`, `action_footsteps_plastic.mp3`, `action_falling.ogg`, `action_swim.mp3`, `impact_water.mp3`, `uuhhh.mp3` |
| RoClicks "Sound sourcing and upload" engine-built-ins list (roclicks.gg, search result 2026-11-19) | `electronicpingshort.wav`, `switch.wav`, `button.wav`, `clickfast.wav`, `snap.wav`, `hit.wav`, `victory.wav`, `collide.wav`, `splat.wav` — with the caveat that not every built-in exists on every build, so all plays are `pcall`-guarded |
| Gear-sound lists (pastebin) — **weakest verification** | `swordslash.wav` (used once, for the melee swing) |

### Assigned cues (all `rbxasset://sounds/...`, all `pcall`-guarded)

| Cue | Path | Used by |
|---|---|---|
| hit / damage | `impact_water.mp3` / `hit.wav` | `PlayHit`, `PlayDamage` |
| ko | `electronicpingshort.wav` | `PlayKO` |
| coin / buy / chaChing / pickup / upgrade | `electronicpingshort.wav` | `PlayCoin`, `PlayBuy`, `PlayBuyChaChing`, `PlayPickup`, `PlayUpgrade` |
| ability / wave / spawn / conveyor / glitchWarning / evolve | `action_get_up.mp3` | `PlayAbility`, `PlayWaveStart`, `PlaySpawn`, `PlayConveyorSpawn`, `PlayGlitchWarning`, `PlayEvolve` |
| click | `clickfast.wav` | `PlayClick` |
| win / victory / secret / achievement | `victory.wav` | `PlayWin`, `PlayVictory`, `PlaySecret`, `PlayAchievement` |
| lose / defeat | `uuhhh.mp3` | `PlayLose`, `PlayDefeat` |
| error / place / splash | `impact_water.mp3` | `PlayError`, `PlayPlace`, `PlaySplash` |
| stealAlarm / rare / siren / expedition | `electronicpingshort.wav` | `PlayStealAlarm`, `PlayRare`, `PlaySiren`, `PlayExpedition` |
| swing | `swordslash.wav` ⚠️ weakest verification | `PlaySwing` |
| discover / fusion | `snap.wav` | `PlayDiscover`, `PlayFusion` |
| mutation | `switch.wav` | `PlayMutation` |
| boss | `collide.wav` | `PlayBoss` |
| teleport / jump | `action_jump.mp3` | `PlayTeleport`, `PlayJump` |
| land | `action_jump_land.mp3` | `PlayLand` |
| capture | `button.wav` | `PlayCapture` |

### Unassigned slots (named in `SoundController.SOUND_SLOTS`, play nothing — never an invented ID)

| Slot | Note |
|---|---|
| `marketAmbience` | Looped market ambience — no verified built-in loop |
| `conveyorLoop` | Looped conveyor hum — no verified built-in loop |
| `music` | Background music loop — no verified built-in music; music volume is stored for the future music system and scales nothing audible today |
| `dimensionAmbience` | Abyssal / Skyfall ambience loop — no verified built-in loop |
| `tideSirenLoop` | Looped tide siren — the one-shot siren cue IS assigned; a loop is not |

**How to fill a slot later:** add a licensed Creator Store / own-upload audio ID to `SoundController.SOUND_PATHS` — never invent an `rbxassetid://` ID. `SoundController.IsAssigned(name)` / `GetUnassignedSlots()` report the state at runtime.

**Volumes:** master (old `SetVolume`/`GetVolume`) × SFX (`SetSFXVolume`/`GetSFXVolume`) scale every one-shot; music (`SetMusicVolume`/`GetMusicVolume`) is stored only. Mute overrides everything. All client-local.

---

## 6. Deliberately left undone / known limits (honest list)

1. **`EquipTitle` server handler missing** — the one honest gap. `AchievementService.SetEquippedTitle` exists but no remote handler calls it. Title equips show locally this session only and do not persist. Integrator step is one handler (see REMOTES_WIRED_E §4).
2. **No Studio playtest** — nothing in this workstream was run in Roblox Studio. All verification is static. Camera re-bind, steal flow, dimension teleports, lab actions and the new panels still need a real playtest (Grok Build).
3. **Tide `EscapeRoutes` (stage 5) not drawn** — the field arrives in `GlitchTideUpdate` but there is no client map-marker API; the HUD shows the stage line and announcement only.
4. **Mastery level not shown as a number** — the server pushes no mastery state; the Shop shows the formula + session-only use counts, labelled as such. A real mastery level needs a `PowerMasteryUpdate` push (B's proposed name, not fired by any service today).
5. **Companion bonuses are display-only** — companion abilities are shown on character cards from the catalogue; their in-game effect hooks were pending in B and are server-side.
6. **Five sound slots unassigned** — see §5. No invented IDs were used to fill them.
7. **`UsePower` / `SettingsUpdate` / `SynergyUpdate` unwired by decision** — see REMOTES_WIRED_E §4.
8. **Trading stays omitted** — `TradeRequest`/`TradeAccept`/`TradeCancel` are defined but never fired (intentional, unsafe).

---

## 7. Keybinds preserved (canonical)

Q primary · F Slam · R Heal · E Interact · G Drop · 1/2/3 loadout · N Market · B Shop · C Brainrots · V Base · J Quests · L Collection · M mute · **left-click Attack (new, Wave 3 E)**. All labels read from the shared bind table (`Utils.GetKeybinds` / `Config.Keybinds`), never hardcoded.

---

## 8. Verification results

| Check | Result |
|---|---|
| `luau-compile` (Luau 0.747, `/tmp/luau-compile`) on all 19 touched/added files | **19/19 PASS** |
| `luau-analyze` on all 19 files | No real errors. Remaining findings are analyzer artifacts of running without the Roblox type environment ("Unknown global/type/require", error-type cascades from untyped `require`s, "unknown does not have key" on untyped `GetDescendants()` results) plus pre-existing unused-variable warnings (`EffectsController` `camera`, `HUDController` `timerFrame`, `ShopController` `RarityColors`/`Config`, `CharacterSelectController` `TweenService`/`Powers`). The three unused items in the NEW `ExpeditionController` were cleaned up. |
| (a) Every name in `REMOTES_NEEDED_*` exists in `Remotes.luau` | **PASS** for every actual remote name (17/17). Names correctly absent: `RequestSecrets`, `RequestTitles`, `TitleUpdate`, `LabFailure`, `ExpeditionFailure`, `TerritoryFailure`, `CompanionUpdate`, `PowerMasteryUpdate` (explicitly not requested / not fired). Effect-type strings (`TideSiren`, `BossVoidBolt`, …) are `SpawnEffect` payload values, not remote names |
| (b) Every `TextButton` has a handler | **PASS** — every `TextButton` call site has a `MouseButton1Click:Connect` (if/else branches share one button), or is built via `PanelKit.MakeButton`, which always connects one. Zero display-only buttons in the new code |
| (c) No `rbxassetid://` invented IDs in `src/` | **PASS** — zero uses; only two comment mentions in `SoundController.luau` explaining why no ID is invented |
| (d) No client `FireServer` for a name with no server handler | **PASS** — every fired name resolves to a server handler via `Remotes.Names.X`, except `EquipTitle` (handler-pending, §6.1). Remaining `GetBase`/`GetStats` hits in `src/client/` are comments documenting the fix, not live fires |
| Server-referenced names not in `Remotes.luau` | **None** |
| Defined but never referenced | `SynergyUpdate` (reserved), `TradeAccept`/`TradeCancel`/`TradeRequest` (trading omitted) |
| Pristine v1.0.2 tree untouched | **Verified** — `Config.GameVersion` is `"1.0.2"` in `brainrot-battle-arena/`; no files modified there this session |
| Forbidden files edited | **None** (see §1) |
| Studio playtest | **NOT RUN** — not claimed |

---

## 9. Notes for the next workstream

- **First:** wire the `EquipTitle` handler (one handler, REMOTES_WIRED_E §4), then the title slot + Achievements panel become fully persistent.
- **Second:** Studio playtest order — (1) camera re-bind on respawn/morph/teleport, (2) steal flow end-to-end (prompt → fire → `StealAlert` → delivery), (3) dimension teleport + chest + checkpoint run, (4) lab evolve/trait/recipe/form with real coins/crystals, (5) expedition start/claim, (6) territory capture channel, (7) boss bar on a boss spawn.
- **Third:** if a server mastery push is ever added (`PowerMasteryUpdate`), the Shop Powers tab already has the display slot — replace the session-only counts with the pushed level.
- **Fourth:** fill the five unassigned sound slots with licensed audio IDs when available; the `SOUND_SLOTS` table is the checklist.
