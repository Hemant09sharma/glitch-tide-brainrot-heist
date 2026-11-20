# GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE

[![roblox-brainrot-01](https://make.fun/badge/roblox-brainrot-01.svg)](https://make.fun/bounty/roblox-brainrot-01)
[![rank](https://make.fun/badge/roblox-brainrot-01/Hemant09sharma/glitch-tide-brainrot-heist/rank.svg)](https://make.fun/bounty/roblox-brainrot-01)
[![reward](https://make.fun/badge/roblox-brainrot-01/Hemant09sharma/glitch-tide-brainrot-heist/reward.svg)](https://make.fun/bounty/roblox-brainrot-01)

Entered on [make.fun](https://make.fun/bounty/roblox-brainrot-01).

> **COLLECT THE CHAOS. BUILD YOUR EMPIRE. SURVIVE THE TIDE.**

A multiplayer Roblox heist-tycoon game. Buy Brainrots from a shared conveyor,
carry them home, place them in your base to earn passive income, upgrade your
defences, and steal from rival bases — while the Glitch Tide periodically
floods the map with corrupted, high-value Brainrots.

**Status (2026-11-19, v1.1.0 — EXTREME EXPANSION):** the Rojo project tree is complete on disk
(68 Luau files, 42,045 lines) and the place file **is included**:
`GlitchTide.rbxl` was built in this workspace with
Rojo 7.7.1 (`rojo build -o GlitchTide.rbxl`, built twice — byte-identical,
SHA-256 `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`,
558,606 bytes) and verified to contain all
68 script sources byte-for-byte, with `MainMenu` under the real `StarterGui` service
and `Main` + `Controllers/` under `StarterPlayerScripts` (see §10 and §12).
Static verification also ran here:
`luau-compile` 68/68, a 70-check Python static harness (all pass) and a 40-check Lune
pure-logic harness (all pass) — see `QA_TEST_REPORT.md` §9–§13. **No Studio
playtest has been run from this workspace** — no screenshots or
recordings exist, and the game has not been published or submitted
anywhere. Publishing and submission are Grok Build's job — see
`GROK_BUILD_HANDOFF.md`. The camera regression test in
`GROK_BUILD_HANDOFF.md` §1 must run first in Studio, and again after this
overhaul (map, lighting, and character models all changed).

**What v1.1 adds over v1.0.2:** visual overhaul of all 7 regions
(`MapBuilder` rewritten, `LightingService` with 12 moods,
`EnvironmentService` animation) + **2 new functional regions**
(Abyssal Kingdom, Skyfall Kingdom); roster **18 → 27** Brainrots with
companion abilities on 15 of them; **10 working tide variants**
(Double/Dark/GiantBoss promoted out of data-only) with a 10-stage
cinematic anticipation; **2 new bosses** (THE GLITCH COLOSSUS,
THE VOID EMPEROR); Brainrot Laboratory (Evolve, trait upgrades, secret
recipes, alternate forms), Expeditions, Territory Control, Secret
Discovery, Achievements module (24 achievements, 13 titles), prestige,
54 quests (was 16), 5 new powers (17 total), power mastery, UI redesign
(6 new panels), 34 verified built-in sound cues, dead-path fixes
(Attack/Steal firers, `RequestCollection`/`RequestEvents` callers,
`BossUpdate` listener), and all 6 companion bonuses wired end-to-end.
See `CHANGELOG.md` and `FEATURE_CHECKLIST.md` for the per-feature
Part 16 classification. **This version is not claimed paid-eligible
for the make.fun bounty** — the recording/authorship rules are
unchanged (see `QA_TEST_REPORT.md` §13).

---

## 1. The game at a glance

| Item | Detail |
|---|---|
| Full name | GLITCH TIDE — BRAINROT HEIST: THE MEMEVERSE |
| Short name | Glitch Tide |
| Engine | Roblox (Luau) |
| Build tool | Rojo 7.7.1 (`default.project.json` + `rojo.toml`) — place file `GlitchTide.rbxl` included |
| Players | 2–12 per server (lobby 20 s, round 180 s, intermission 15 s) |
| Base plots | 12 — one per player, equal to MaxPlayers |
| Brainrots | 27 original (18 v1.0.2 + 9 new, one per tier Common–Secret); 15 grant companion abilities |
| Regions | 9 — the original 7 zones + Abyssal Kingdom + Skyfall Kingdom (both functional: chests, hazards, checkpoint run, boss altar) |
| Tide variants | 10 working (Standard, Fast, Toxic, Frozen, Meteor, Double, Dark, GiantBoss, Corrupted, Cosmic) |
| Bosses | 3 — THE ALGORITHM + THE GLITCH COLOSSUS + THE VOID EMPEROR (all 3-phase) |
| Quests | 54 (16 v1.0.2 + 38 new, incl. a 5-quest story chain) |
| Achievements / titles | 24 achievements, 13 titles (new in v1.1) |
| Playable powers | 17 (12 v1.0.2 + 5 new) + 27 character Q primaries |
| Teams | Red Rotters vs Blue Brainrots (plus a FreeForAll mode) |
| Data | DataStoreService — `GlitchTide_Data_v1` (+ leaderboard store `GlitchTide_Leaderboard_v1`) |
| Starting cash | 100 coins |
| Trading | Intentionally omitted for safety |

## 2. Core loop — 16 steps

1. **Spawn in the lobby** and wait for the round to start (minimum 2 players).
2. **Claim your personal base** — it starts with 4 Brainrot slots (upgradeable to 10).
3. **Watch the central conveyor.** A new Brainrot spawns on it every 8 seconds
   (maximum 8 on the belt at once), with rarity weighted across 10 tiers
   (`Config.RarityWeights`, probabilities summing to 1.0): Common 0.40 /
   Uncommon 0.25 / Rare 0.16 / Epic 0.10 / Legendary 0.05 / Mythic 0.025 /
   Divine 0.008 / Celestial 0.004 / Secret 0.002 / Impossible 0.001.
4. **Buy a Brainrot** from the conveyor with coins. Prices rise with rarity
   and income; Glitched ones cost 1.5×.
5. **Carry it home.** While carrying you move at 0.6× speed, and if you are
   knocked out you drop what you are carrying.
6. **Place it on a free slot in your base.** It starts earning income every second.
7. **Collect passive income.** Income ticks every second; each Brainrot earns
   its `IncomePerSec`, boosted +25% per Brainrot level (max level 5).
8. **Bank and spend.** Use earned coins to buy rarer Brainrots off the conveyor.
9. **Upgrade your base.** Buy extra slots, an income multiplier, locks, turrets,
   and conveyor luck (see §6).
10. **Level up your Brainrots** to raise their income.
11. **Fight rivals in the arena.** Knock-outs pay 25 coins and 20 XP; assists
    pay 10 coins; an arena win pays 100 coins and 50 XP. PvE waves spawn every
    90 seconds, with a boss every 5th wave.
12. **Use abilities** — one character primary ability (Q) plus a 3-slot
    loadout of playable powers (see §8).
13. **Raid a rival base.** Channel for 3 seconds to grab a Brainrot, then carry
    it back to your own base. Steal cooldown is 60 seconds.
14. **Defend your base.** Lock it for 30 seconds, rely on turrets, and chase
    thieves down — a steal only counts once the Brainrot reaches the thief's base.
15. **Survive the Glitch Tide** (§5): every 240 seconds the conveyor floods
    with Glitched Brainrots and income doubles for 60 seconds.
16. **Save and come back.** Progress autosaves every 120 seconds, on leaving,
    and on server shutdown; rejoining restores your coins, Brainrots, base,
    and upgrades.

## 3. Zones

The map is built at runtime by the server-side `MapBuilder` module (see §10),
so there are no static part files in the project — the layout is identical on
every server.

- **Lobby** — spawn / waiting area before the round starts.
- **Arena floor** — the shared combat space between the bases.
- **Central conveyor** — the shared market belt where Brainrots spawn and are bought.
- **Personal bases** — one per player, with Brainrot slots, a lock button,
  and turret positions. Your most valuable Brainrots belong furthest from the door.
- **Spawn pads** — team spawn points (Red / Blue).

## 4. The 27 Brainrots

Roster, rarity, and base income are defined in `src/shared/Characters.luau`.
Income is coins per second at level 1, before multipliers.
Rows 19–27 are new in v1.1 (one per tier, Common–Secret; the Wobble King
stays the sole Impossible). 15 of the 27 grant a companion ability
(income bonus, tide protection, rare-market detection, carry speed, raid
detection, mutation bonus — capped per kind; see `src/shared/Companions.luau`).

| # | Brainrot | Rarity | Cost | Income/s |
|---|---|---|---|---:|
| 1 | Wobble Waffleton | Common | 0 | 5 |
| 2 | Turbo Turnip | Common | 120 | 8 |
| 3 | Bloop Bloomington | Uncommon | 400 | 15 |
| 4 | Crumb Comet | Uncommon | 650 | 18 |
| 5 | Noodle Nebula | Rare | 1,200 | 35 |
| 6 | Toast Ghost | Rare | 1,800 | 45 |
| 7 | Disco Dumpling | Rare | 2,500 | 55 |
| 8 | Captain Picklebyte | Epic | 4,500 | 90 |
| 9 | Moon Mochi | Epic | 6,000 | 120 |
| 10 | Giga Gumball | Epic | 8,000 | 145 |
| 11 | Miso Mothership | Legendary | 15,000 | 250 |
| 12 | Puddle Professor | Legendary | 22,000 | 380 |
| 13 | Springy Spaghetti | Mythic | 40,000 | 700 |
| 14 | Zap Zucchini | Mythic | 60,000 | 1,100 |
| 15 | Cosmic Cupcake | Divine | 120,000 | 2,200 |
| 16 | Glitchy Goose | Celestial | 250,000 | 4,500 |
| 17 | Caramel Crab | Secret | 500,000 | 9,000 |
| 18 | The Wobble King | Impossible | 1,000,000 | 18,000 |
| 19 | Phantom Pancake | Common | 250 | 7 |
| 20 | Prism Penguin | Uncommon | 550 | 12 |
| 21 | Neon Narwhal | Rare | 2,000 | 50 |
| 22 | Reactor Raccoon | Epic | 7,000 | 130 |
| 23 | Gravity Goblin | Legendary | 18,000 | 300 |
| 24 | Thunder Tortoise | Mythic | 50,000 | 900 |
| 25 | Quantum Quokka | Divine | 150,000 | 2,800 |
| 26 | Solar Sloth | Celestial | 300,000 | 5,500 |
| 27 | Void Vulture | Secret | 600,000 | 11,000 |

Each Brainrot also has a defence trait (for example Sturdy, Swift, Armored,
Spiky, FreezeAura, Alarm, RingGuard, Watchful) and a primary ability (§8).
Character models are assembled in code from primitive parts and props —
no external asset IDs are used.

> **Originality note:** this is an original roster created for this game.
> None of the names, designs, audio, or models of existing Italian Brainrot
> meme characters are used — see `THIRD_PARTY_NOTICES.md`.

## 5. Currencies and economy

- **Coins** — the main currency. Earned from Brainrot income, knock-outs
  (25), assists (10), round wins (100), and a daily bonus (50, streak up to 7).
  Spent on Brainrots, base slots, upgrades, and Brainrot levels.
  Starting balance: 100 coins. Sanity cap: 5,000 coins per match.
- **XP / levels** — earned from knock-outs (20), waves (15), and wins (50).
  Level cap: 100.
- **No Robux purchases and no trading** are part of this build. Trading was
  intentionally omitted for safety.

Base upgrade costs (coins, per level — the last cost repeats at higher levels):

| Upgrade | Costs |
|---|---|
| Extra base slot (4 → 10) | 150 / 300 / 600 / 1,200 / 2,400 / 5,000 |
| Income multiplier | 200 / 450 / 900 / 1,800 / 3,600 |
| Base lock | 100 / 250 / 500 |
| Turret | 400 / 900 / 2,000 |
| Conveyor luck | 250 / 600 / 1,200 / 2,500 |
| Brainrot level (max 5) | 100 / 250 / 500 / 1,000 / 2,000 |

All tuning values live in one place — `src/shared/Config.luau` — so balance
changes never require touching game logic.

## 6. The Glitch Tide

The signature event, tuned in `Config.luau`:

- **Every 240 seconds**, a 30-second warning goes out, then the Tide runs
  for **60 seconds**.
- During the Tide the conveyor is flooded with Glitched Brainrots
  (35% glitch chance on spawns) and **all income is doubled** (×2).
- Glitched Brainrots cost 1.5× their normal price and earn bonus income.
- The Tide is the best time to buy high and the worst time to leave your
  base unguarded — everyone is rich, and everyone is a target.
- **Playable variations** (one rolls each tide, `Config.TideVariations`,
  weights sum to 100):
  **Standard** (no modifiers), **Fast** (speed ×1.5, rewards ×1.25),
  **Toxic** (damage ×1.25, rewards ×1.5), **Frozen** (movement ×0.7,
  rewards ×1.5), **Meteor** (meteor strikes, damage ×1.5, rewards
  ×1.75), **Double** (two anti-phase wave walls, rewards ×2.0),
  **Dark** (FogEnd 120, ambush spawns, rewards ×1.75),
  **GiantBoss** (THE GLITCH COLOSSUS spawns mid-tide, rewards ×3.0),
  **Corrupted** (glitch barriers teleport the exposed, rewards ×2.25),
  **Cosmic** (gravity 196 → 60, starfall pickups, rewards ×2.5).
  Each variation's behaviour lives in `TideService`; Double / Dark /
  GiantBoss are no longer data-only — `Config.TideVariationsDisabled`
  was deleted in v1.1. The tide now runs a 10-stage cinematic
  anticipation (environment flicker → sirens → sky change → warning →
  wave emerges → travels → survival → climax → rewards), with escape
  routes broadcast, 3 temporary shelters, moving channel obstacles,
  risk zones, tide surfing, co-op survival rewards, and a 10% secret
  encounter roll per tide.
- **Golden Hour** (rotating world event, `EventService`): 2× income for
  120 s. It stacks with the Tide multiplier (Tide 2× × Golden Hour 2× =
  4×) and is announced on the HUD event banner (`EventUpdate`); tide
  survivors get a banner too (`TideSurvivor`).

## 7. Stealing and defence

- **Steal:** enter an unlocked rival base, channel for **3 seconds** on a
  Brainrot, pick it up, and carry it back to your own base. You move at
  0.6× speed while carrying and drop the Brainrot if you are knocked out.
  Steal cooldown: **60 seconds**.
- **Reward:** the thief keeps half of the victim's banked income from that
  Brainrot, plus a flat bonus tied to its income rate.
- **Defence:** lock your base for **30 seconds** (lock upgrades available),
  build turrets, and chase thieves — a steal fails if the thief is stopped
  before reaching home.
- **Combat:** base attack 12 damage, 6-stud range, 0.45 s cooldown,
  knockback 18; walk speed 16, sprint ×1.25, jump power 50; health
  regenerates up to 2/s. Respawn time: 3 seconds.

## 8. Powers and abilities

Every character has **one primary ability** (bound to **Q**) and every
player also gets generic abilities. The bindings below are the canonical
keybinds — `Config.Keybinds` / `Config.AbilitySlots` and
`Utils.GetKeybinds` agree on all of them (verified by the v1.0.1 QA
harness; there is no second, conflicting mapping any more).

| Key | Ability |
|---|---|
| Q | Character primary ability (see list below) |
| F | Slam (generic) |
| R | Heal (generic) |
| E | Interact (buy / grab / place) — not an ability key |
| G | Drop a carried Brainrot |
| 1 / 2 / 3 | Loadout power slots |
| B | Shop (also the HUD SHOP button) |
| N | Market / conveyor panel |
| J | Quests panel |
| C | Brainrots / collection panel |
| V | Base panel |
| L | Collection book |
| M | Mute sounds |

The 3-slot loadout powers are Dash, Energy Shield, Magnet Pull,
Teleport, Gravity Shift, Freeze Blast, Shadow Walk, Clone Decoy, Tide
Surfer, Time Distortion, Rift Hook and Chaos Burst
(`src/shared/Powers.luau`, `AbilityService`).

Primary abilities (one per Brainrot, all on Q): Waffle Wobble, Turbo Boost,
Jelly Splash, Comet Crash, Noodle Whip, Toast Haunt, Disco Fever, Pickle
Blast, Mochi Bounce, Gumball Roll, Miso Beam, Puddle Splash, Spaghetti
Spring, Zap Bolt, Cosmic Ring, Glitch Flicker, Caramel Claw, Royal Wobble.

## 9. Mutations, quests, and rebirth

 - **Mutations.** Twelve mutations (`MutationService` + `src/shared/Mutations.luau`):
  Golden (×2.5), Diamond (×4), Rainbow (×5), Electric (×2), Frozen (×1.8),
  Toxic (×2.2), Shadow (×3), Glitched (×3.5), Cosmic (×4.5), Ancient (×3),
  Void (×6), Celestial (×8) income, each visibly changing the model
  (material / colour / particles). Apply them from the Shop's **Mutations**
  tab (placed Brainrots, Mutation Crystals, server-validated).
- **Fusion.** `FusionService` is recipe-based: two *unplaced* Brainrots
  fuse into the character their shared `Mutations.FusionRecipes` recipe
  produces (10 recipes, all pointing at real characters), for 1,000 coins
  + 25 Mutation Crystals. The Shop's **Fusion** tab (v1.0.1) lists your
  unplaced inventory and every recipe, and fires `FuseBrainrot`
  `{InstanceIdA, InstanceIdB}`; the server charges, consumes both inputs
  and grants the result at level 1, refunding + restoring on failure.
  Placed Brainrots cannot fuse.
- **Quests.** Sixteen auto-tracked quests (`QuestService`): tutorial, daily,
  collection, exploration, raid, mutation, combat and event quests, with
  claimable coin / gem / XP / Event Token rewards. The client pulls the
  live list via the `RequestQuests` RemoteFunction (wired in v1.0.1) and
  also gets a `QuestUpdate` push on quest events, on claims, and shortly
  after joining. The collection book pulls via `RequestCollection`
  (`ProgressionService.GetCollection`); the active event pulls via
  `RequestEvents` (`EventService.GetActiveEvent`).
- **Rebirth.** `ProgressionService`: requires level 25 + 100,000 coins +
  10 *distinct* owned Brainrots; resets coins (to starting coins),
  level/XP (to 1/0) and placed Brainrots (they return to the inventory),
  but **keeps** owned characters, rebirth count, wins/KOs, quests and
  cosmetics. Each rebirth grants a permanent +10% income
  (`Config.RebirthRequirements.IncomeBonusPerRebirth`), +2 base slots,
  +25 gems, and unlocks the rebirth-only mutation tier. Max 10 rebirths.

## 10. Architecture

Rojo project tree (`default.project.json` — v1.0.1 uses `$className`,
which Rojo 7.7 requires; the v1.0.0 file used `$class` and Rojo rejected
it with "Failed to deserialize JSON". v1.0.2 additionally moves
`StarterGui` out of `StarterPlayer` to a direct DataModel child, and
`StarterPlayerScripts` now maps only `Main.client.luau` + `Controllers/`,
so `src/client/ui` is no longer duplicated under `StarterPlayerScripts`):

| Disk path | Roblox service | Contents |
|---|---|---|
| `src/shared` | `ReplicatedStorage` | 15 shared modules both sides require: `AchievementDefs`, `CharacterModels`, `Characters`, `Companions`, `Config`, `Dimensions`, `Economy`, `ExpeditionDefs`, `LabDefs`, `Mutations`, `Powers`, `Remotes`, `Synergies`, `Types`, `Utils` |
| `src/server` | `ServerScriptService` | `Main.server.luau` entry point + `Services/` (30 services: data, economy, character, combat, map, game loop, tide, quests, events, fusion, progression, raids, bosses, waves, NPCs, security, lighting, environment, dimensions, laboratory, expedition, territory, companion, secret, achievements, …) |
| `src/client/Main.client.luau` | `StarterPlayerScripts` (as `Main`, a LocalScript) | Client entry point; loads `Controllers/` in order |
| `src/client/Controllers` | `StarterPlayerScripts` → `Controllers/` | 20 controllers: animation, camera, effects, HUD, interaction, market, shop, quests, collection, achievement, dimension, expedition, laboratory, territory, sound, … |
| `src/client/ui` | `StarterGui` (direct child of DataModel) | `MainMenu.luau` (ModuleScript, cloned into PlayerGui on spawn) |
| `src/map` | `Workspace` | Intentionally empty — the map is built at runtime by `MapBuilder` (see `docs/map.md`); do not put `.rbxl` / `.rbxm` files here. No documentation file lives under `src/`, so nothing non-code enters the Roblox instance tree. |

68 Luau files, 42,045 lines in total. Every module `Main.server.luau`
requires resolves; the Rojo build was verified in this workspace
(`rojo build -o GlitchTide.rbxl`, Rojo 7.7.1).

**Startup order** (`src/server/Main.server.luau`): create all remotes first
(`Remotes.CreateRemotes`) → build the world (`MapBuilder.Build()`) → init
`DataService` → init `EconomyService` → init `GameManager` → start the game
loop in its own thread so a loop error cannot kill startup. Late joiners get
a guarded data-load retry.

**Client/server boundary:** clients may only *request* things (buy, steal,
select character, request shop/base/stats). All validation, money changes,
and ownership changes happen on the server. Remotes are defined once in
`src/shared/Remotes.luau` — the single source of truth for every
RemoteEvent / RemoteFunction name — and created idempotently by the server
at startup.

**Persistence design** (`src/server/Services/DataService.luau`): one
DataStore key per player, cached in memory on the server, autosaved every
120 seconds, saved on player leave, and flushed on server shutdown via
`game:BindToClose`. Every DataStore call is wrapped in `pcall`. This follows
the standard Roblox pattern — `UpdateAsync` for read-modify-write,
retries with backoff, and session locking so two servers never own the same
player's data at once (the ProfileService / ProfileStore pattern); see
"Sources consulted" below. DataStore access requires **Studio Access to API
Services** to be enabled in Game Settings → Security when testing in Studio.

**Camera (v1.0.1 fix).** Only `CameraController` and `EffectsController`
ever touch `CurrentCamera` / `CameraType` / `CameraSubject` (verified by
grep: 13 references, all in those two files). The camera rebinds on the
`player.Character` property change after a morph / respawn / teleport;
see `QA_TEST_REPORT.md` for the root cause and the regression test in
`GROK_BUILD_HANDOFF.md` §1.

**Interaction (v1.0.1).** The sole interaction path is server-created
`ProximityPrompt`s (NPC talk, conveyor buy via `MarketController`) plus
explicit panels (Market / Shop / Base). The old `InteractType` /
`InteractId` attribute scan in `InteractionController` was removed: no
producer ever set those attributes, so the scan always found nothing.
E (Interact) with nothing nearby shows a hint and never spends coins.

## 11. Controls

The canonical keybind table is §8 above (`Config.Keybinds` /
`Config.AbilitySlots` / `Utils.GetKeybinds` — one mapping, verified
consistent by the v1.0.1 QA harness). Summary: move W A S D, jump Space,
sprint Shift, camera / aim Mouse, Interact E, Drop G, primary ability Q,
Slam F, Heal R, loadout 1 / 2 / 3, Shop B, Market N, Quests J, Brainrots
C, Base V, Collection L, Mute M. Touch controls are provided through the
HUD where implemented; confirm the final touch layout in Studio before
release.

## 12. How to import with Rojo (recommended)

Prerequisites: Roblox Studio installed, Rojo 7.7 CLI, and the Rojo Studio
plugin (plugin major version must match the CLI major version).

> **Project-file note (v1.0.1 / v1.0.2):** `default.project.json` must use
> `$className` (not `$class`) for the DataModel root — Rojo 7.7 rejects
> `$class` with "Failed to deserialize JSON". And `StarterGui` must be a
> direct child of the DataModel (v1.0.2 fix): in v1.0.1 it was nested
> inside `StarterPlayer`, which is not a real Roblox service hierarchy,
> so `MainMenu` was never cloned into `PlayerGui` and the menu never
> appeared. The shipped file is already corrected — `StarterGui` →
> `src/client/ui`, and `StarterPlayerScripts` contains only `Main`
> (`src/client/Main.client.luau`) and `Controllers/` (`src/client/Controllers`).
> A prebuilt place file is included in this delivery:
> `GlitchTide.rbxl` (built with Rojo 7.7.1, verified to contain all 48
> script sources, `MainMenu` under `StarterGui`, `Main` + `Controllers/`
> under `StarterPlayerScripts`) — open it directly in Studio to skip the build step.

1. Unzip the project and open a terminal in the project root.
2. Install the Rojo CLI (see <https://rojo.space/docs/v7/getting-started/installation/>).
   With Rokit, pin it — for example `rojo = "rojo-rbx/rojo@7.7.0"` in `rokit.toml`.
3. Install the Rojo Studio plugin from the same Rojo release.
4. Start the live-sync server:
   ```sh
   rojo serve
   ```
   It listens on `127.0.0.1:34872` by default (see `rojo.toml`).
5. Open Roblox Studio, open a new baseplate place, then in the Rojo plugin
   click **Connect**. The project tree syncs into Studio.
6. Edit Luau files on disk; supported changes live-sync into Studio.
   Do not edit Rojo-managed scripts inside Studio — the next sync overwrites them.
7. Build a standalone place file whenever you need one:
   ```sh
   rojo build -o GlitchTide.rbxl
   ```
   (`rojo.toml` also sets the default build output to `GlitchTide.rbxl`,
   so a bare `rojo build` writes the same file.)

## 13. Manual Studio import (no Rojo)

If Rojo is unavailable, copy the folders by hand:

| Disk folder | Studio destination |
|---|---|
| `src/shared/*` | `ReplicatedStorage` |
| `src/server/Main.server.luau` | `ServerScriptService` (as a Script) |
| `src/server/Services/*` | `ServerScriptService` → `Services` folder |
| `src/client/Main.client.luau` | `StarterPlayer` → `StarterPlayerScripts` (as a LocalScript) |
| `src/client/Controllers/*` | `StarterPlayerScripts` → `Controllers` folder |
| `src/client/ui/*` | `StarterGui` |
| `src/map` | Do **not** copy — the map is built at runtime by `MapBuilder` |

Keep module names exactly as on disk: `Main.server.luau` requires
`Services/MapBuilder`, `Services/GameManager`, `Services/DataService`, and
`Services/EconomyService` by name, and shared modules are required from
`ReplicatedStorage` by name (`Config`, `Remotes`, …). Renaming a module
breaks those requires.

## 14. Testing

### What was verified in this workspace (v1.1.0, no Studio)

- `luau-compile` on every `.luau` file: **68/68 pass**.
- Rojo build, run twice: byte-identical `GlitchTide.rbxl` (558,606 bytes,
  SHA-256 `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`),
  verified to contain all 68 script sources byte-for-byte
  (`scripts/verify-rbxl.py` 68/68) and checked against Rojo's own
  `/show-instances` tree (77 instances; `StarterGui → MainMenu` exactly
  once; `StarterPlayerScripts → Main + Controllers/`; `Workspace` empty).
- Python static harness (70 checks, all pass) and Lune pure-logic harness
  (40 checks, all pass) — see `QA_TEST_REPORT.md` §11 (tests T12–T20).
  Full v1.1 verification record: `QA_TEST_REPORT.md` §9–§13.
- **Not verified here (needs Studio):** any runtime behaviour — see below.

### What was verified in this workspace (v1.0.2, no Studio) — HISTORICAL

The bullets below are v1.0.2 evidence, preserved verbatim as history.
Do not read their counts (48 files, 18 Brainrots, 16 quests, 12 powers)
as the current release; the current release is v1.1.0 (see above).

- `luau-compile` on every `.luau` file: **48/48 pass**.
- `luau-analyze`: diagnostics are Roblox-definition noise only
  (unknown `game` / `Enum` / `Color3` globals, unknown requires);
  no real defect on any line edited in v1.0.1.
- Rojo build: `rojo build -o GlitchTide.rbxl` with Rojo 7.7.1 succeeds
  (333,816 bytes in v1.0.2; was 341,613 in v1.0.1); the `.rbxl` was
  decompressed and verified to contain all 48 script sources,
  including the v1.0.1 fix markers, and the v1.0.2 hierarchy was
  verified from the decompressed place and Rojo's own
  `/show-instances` tree: `StarterGui → MainMenu`,
  `StarterPlayerScripts → Main + Controllers/`, `Workspace` empty.
- Python static harness (47 checks, all pass): project JSON, 18-character
  roster with resolving AbilityIds, rarity weights summing to 1.0, remote
  wiring, require targets, keybind consistency, no TODOs / Italian names /
  old branding, 12 plots == 12 players, playable tide variations with
  behaviour, Magma/Spectral only in comments, camera touched only by
  CameraController/EffectsController, all 7 integration fixes present.
- Lune pure-logic harness (33 checks, all pass): shared modules loaded
  with stubbed Roblox globals — rarity weights, roster, fusion recipes
  (order-independent, all results real), fusion costs, XP/wave/KO curves,
  synergy bonuses, income formula (level scaling, Golden 2.5×, Tide 2× ×
  Golden Hour 2× = 4×), rebirth requirements, keybinds.
- **Not verified here (needs Studio):** any runtime behaviour — the
  camera regression test, the acceptance scenario, DataStore saves,
  multi-client play. Those are Grok Build's job; see below and
  `GROK_BUILD_HANDOFF.md`.

### Camera regression test (run FIRST in Studio)

See `GROK_BUILD_HANDOFF.md` §1: spawn → walk 100 studs → morph switch →
teleport blink → death/respawn → 60 s idle. The camera must keep
following the character through every step, with no black screen, no
frozen view, and no camera stuck at the spawn point.

### Solo test (1 player, Studio)

1. Enable **Game Settings → Security → Enable Studio Access to API Services**
   (required for DataStore testing).
2. `rojo serve` → connect the plugin, or open the built `GlitchTide.rbxl`.
3. Press **Play** (F5). Confirm in Output: remotes created, map built,
   DataService initialised, EconomyService initialised, GameManager
   initialised, server started.
4. Walk to the conveyor, buy the cheapest Brainrot, carry it to your base,
   place it, and watch coins tick up.
5. Buy a base slot and a lock; trigger a Glitch Tide (wait for the 240 s
   timer or shorten `GlitchTideIntervalSeconds` in `Config.luau` for testing
   only) and confirm income doubles.
6. Use Q (primary), F (Slam) and R (Heal) and confirm each ability fires. E is Interact, G is Drop — do not use E/R as the old test step said.
7. Stop, press Play again, and confirm coins, Brainrots, and upgrades persisted.

### 2-player test (Studio Test tab)

1. In Studio, open the **Test** tab → **Clients and Servers** → set
   **Players: 2** → **Start**.
2. In client 1: buy a Brainrot, place it, lock the base, and note the balance.
3. In client 2: wait for the lock to expire (or test while unlocked), enter
   client 1's base, channel 3 seconds, grab the Brainrot, and carry it home.
4. In client 1: chase and knock out client 2 mid-carry — confirm the
   Brainrot drops and the steal fails.
5. Repeat the steal without interference — confirm the Brainrot arrives in
   client 2's base and the balances change as designed.
6. Stop both clients; confirm both players' data saved without errors in Output.

### Acceptance scenario (for Grok Build)

Spawn → claim base → buy from the market/conveyor → carry → survive a
Glitch Tide → place in base → earn income → upgrade base → use an ability →
buy/place a Glitched (mutated) Brainrot → complete a quest objective if
implemented → save, leave, and rejoin with progress intact → 2-player raid
(steal and defended steal). Any error in the Output window during this run
is a failure to fix before publishing. See `GROK_BUILD_HANDOFF.md`.

## 15. Known limitations

- **No Studio playtest has been run from this workspace.** Everything above
  describes the code and configuration as verified statically; behaviour
  in Studio is unverified until Grok Build runs the camera regression
  test and the acceptance scenario — and re-runs them after the v1.1
  overhaul (map, lighting, and character models all changed).
- **DataStore needs API access enabled in Studio** (Game Settings → Security),
  otherwise saves fail in playtests. Live-game DataStores work without this
  setting; it is a Studio-only requirement.
- **12 base plots, MaxPlayers 12** — one plot per player.
- **No trading system** (intentional, for safety).
- **No offline income** — income only accrues while playing (banked income
  is collected via CollectIncome while in-game).
- **No screenshots, recordings, or published game exist yet.**
- **v1.1 known gaps** (see `QA_TEST_REPORT.md` §12): the Abyssal boss
  altar summons THE ALGORITHM in the Chaos Arena, not an Abyssal-local
  boss; dimension lighting moods do not auto-apply (Lighting is global);
  territory bonuses are a flat tick, not an income multiplier; the hidden
  merchant is a discovery trigger, not a shop; expedition
  on-expedition instances are hidden by the UI but not blocked by
  Base/Mutation/Fusion services; mastery is shown from session counts
  (no server push); 5 sound slots are unassigned by design;
  `UsePower` / `SettingsUpdate` / `SynergyUpdate` stay unwired by
  documented decision; controller input is not bound; animation is
  procedural, not keyframed.

## 16. Sources consulted (research for this document)

No code or text was copied from any of these sources. All game code is
original to this project; the sources below informed the Rojo workflow,
the DataStore design pattern, and the steal-loop design only.

- Rojo 7.7 installation & CLI — <https://github.com/nonlooped/roblox-suite/blob/HEAD/roblox-rojo/references/installation-and-cli.md> (summarising <https://rojo.space/docs/v7/getting-started/installation/>)
- Rojo workflows & syncback — <https://github.com/nonlooped/roblox-suite/blob/HEAD/roblox-rojo/references/workflows-and-syncback.md>
- Rojo project setup — <https://github.com/nonlooped/roblox-suite/blob/HEAD/evals/runs/codex-gpt-5.6-sol-baseline-2026-07-16/responses/rojo-project-setup.md>
- Roblox DataStore patterns (UpdateAsync, retries, session locking, ProfileStore) — <https://github.com/el4cteo/roblox-skills/blob/HEAD/skills/roblox-data-stores/SKILL.md>
- Roblox DataStores: retry/backoff, session locking, autosave, BindToClose — <https://github.com/ivar-anon/roblox-dev/blob/HEAD/skills/roblox-datastores/SKILL.md>
- Roblox DataStore patterns that scale — <https://simplified.media/guides/roblox-data-stores>
- Steal a Brainrot core loop (buy / earn / steal / defend) — <https://moltoclix.com/roblox-steal-a-brainrot>
- Steal a Brainrot gameplay guide — <https://www.bloxbonuses.com/articles/steal-a-brainrot-guide/>
- Steal a Brainrot mechanics overview — <https://ozogames.com/game/steal-a-brainrot-unblocked/>

## 17. Files in this project

- `README.md` — this file
- `QA_TEST_REPORT.md` — v1.0.1 QA report: fixed-bug list, tests executed
  (tool + result), tests NOT executed, partial/missing features
- `GROK_BUILD_HANDOFF.md` — build, test, publish, and submit steps for Grok Build
- `FEATURE_CHECKLIST.md` — feature-by-feature status after v1.0.1 fixes
- `TEST_REPORT.md` — **ARCHIVED historical report (v1.0.0, 2026-11-18).**
  Kept verbatim for the record only; its v1.0.0 limitations are outdated
  and superseded by `QA_TEST_REPORT.md` v1.0.1/v1.0.2 — do not use it as
  the current test status
- `THIRD_PARTY_NOTICES.md` — reuse / originality statement
- `CHANGELOG.md` — version history
- `LICENSE` — MIT License
- `default.project.json`, `rojo.toml` — Rojo project definition
- `GlitchTide.rbxl` — prebuilt place file (Rojo 7.7.1, v1.1.0 rebuild, 558,606 bytes)
- `docs/map.md` — world/map note (excluded from the Rojo instance tree)
- `src/` — all Luau code and the map placeholder (68 files, 42,045 lines)
