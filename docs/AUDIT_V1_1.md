# AUDIT — GLITCH TIDE v1.1 (read-only, Part 1)

**Audited tree:** `~/workspace/your_files/glitch-tide-v1.1/` — 48 Luau files, 26,061 lines.
**Date:** 2026-11-19. **Method:** read every `.luau` under `src/` (shared, server, client),
`default.project.json`, `rojo.toml`, and `QA_TEST_REPORT.md` (§1–§11). No game code was
changed, no git was run, no Studio playtest was run — this is a static code audit only.
**Version note (important):** `diff -r` of this tree against
`~/workspace/your_files/brainrot-battle-arena/` returns **no differences**, and
`Config.GameVersion` is `"1.1.0"` in both. The `QA_TEST_REPORT.md` / `CHANGELOG.md` /
`FEATURE_CHECKLIST.md` inside the tree are still the 1.0.2-era documents. So "v1.1" here
is a relabelled copy of the v1.0.2 code; there is no gameplay delta to audit, and every
QA claim cited below is the 1.0.2 report's, not a fresh verification.

**Headline:** the core loop (conveyor → carry → place → income → upgrade) is coherent and
mostly server-authoritative, the camera fix is well-designed, and the remote contract is
documented in one place. But this audit found **two server handlers no client can ever
reach** — melee `Attack` and `StealBrainrot` have no client `FireServer` anywhere, so
melee combat and stealing appear unreachable from the UI despite being "implemented" —
plus a live rebirth-income contradiction (+10% vs +25%) and two NPC types that are never
spawned. Those are the highest-value items for Part 2 / Grok Build verification.

---

## 1. Subsystem summaries (one paragraph each)

### Conveyor / market
`ConveyorService.luau` (809 lines) owns the shared Rift Market belt: weighted rarity
spawns every `Config.ConveyorSpawnInterval` (8s, max 8 items, `ConveyorRarityWeights`
covering all 10 tiers), items move ~1 stud/s along `MapBuilder.GetConveyorPath()`
(waypoints x=-30..+30 at z=-60), each with a price billboard and a procedural model
(`CharacterModels`, with a coloured-block fallback). `BuyItem` (L540) is properly
server-authoritative: it re-checks the item exists, recomputes nothing client-supplied,
enforces a 12-stud distance check, claims/removes the item *before* deducting coins
(no double-sell), creates the owned instance via `MutationService.CreateInstance` when
wired (else inserts the same record shape directly), refunds in full if record creation
fails, and saves immediately. Glitched items cost 1.5× (`Economy.ConveyorPrice`) and
despawn after 25s; glitch mode (tide) raises the glitch chance. Broadcasts go out on
`ConveyorUpdate` to all clients; `MarketController` renders the strip and fires
`BuyConveyor` per item with a 5s no-reply watchdog.

### Bases / income
`BaseService.luau` (1,425 lines, the largest service) owns the 12 plots: `AssignBase`
on join, `RebuildBase` (pedestal models, owner sign, gate), `GetBase` snapshot,
`PlaceBrainrot` / `RemovePlaced` / `CollectIncome` / `UpgradeBase` / `UpgradeBrainrot`.
Income is a 1s server tick (`Init`, L1394) banking `GetIncomePerSec × dt` (dt clamped
to 5s against lag windfalls) into `data.BankedIncome`, capped at `BANKED_CAP = 10,000`
(L42) — uncollected income above the cap is silently lost. `GetIncomePerSec` (L454)
multiplies per-Brainrot income (level +25%/level, glitched ×2, mutation multiplier —
delegated to `Economy.IncomePerSecond`, single application) by base income multiplier,
tide multiplier (`SetTideMultiplier`), event multiplier (Golden Hour, via
`SetEventService`), rebirth multiplier, and the synergy bonus
(`Synergies.GetSynergyBonusForCharacters`). Placed state lives in `data.Base.Placed`
(`ensureBaseData`, L188) while the instance registry lives in `data.OwnedInstances`;
the two are kept in sync via `MutationService.SetPlaced`. Slots: start 4, +2/rebirth,
capped at `BaseSlotsMax` (10) and at the physical pedestal count (10).

### Carrying / stealing / raids
`CarryService.luau` (768 lines) owns carry state: at most one Brainrot per player, a
0.6-scale welded model above the head, `Config.CarrySpeedMultiplier` (0.6) while
carrying, drop on death (its own `Humanoid.Died` hook) and on tide hits, manual drop
via `DropBrainrot` leaving a 30s world pickup (`DROP_RECOVERY_SECONDS`) that returns
to the owner's inventory on expiry. `RaidService.luau` (1,161 lines) owns stealing:
`StealBrainrot` (L861) — protection checks (`IsProtected`, L438: victim level < 3,
account age < 7 days, last placed Brainrot, placed < 120s ago, shield, lockdown),
3s channel within 8 studs, then the record moves to the thief as an in-transit hold
(`MutationService.MoveInstance`) and ownership confirms only on placement in the
thief's base (5s `PollInTransit` watchdog or `ConfirmDelivery`); death/drop returns
it via `ReturnStolen`. Defenses: shield (100 coins / 60s), lockdown (250 coins / 30s,
120s cooldown), gate open/closed, guard NPCs via `RegisterGuard`. **But see §3 F1:**
no client code fires `StealBrainrot`, so the whole steal flow is currently unreachable.

### Mutations / fusion
`MutationService.luau` (556 lines) owns `data.OwnedInstances` (seeded lazily from
`data.Unlocked`, one level-1 instance per unlocked id) and `MutateBrainrot` (L426):
sanitised ids, lowercase-normalised mutation lookup, rebirth gating (Void/Celestial
need 1 rebirth, Rainbow needs 2), compatibility enforced against
`Characters.MutationCompatibility` (`CanMutate`, L343), cost in Mutation Crystals
from `Config.MutationCosts` (halved during Mutation Storm via `EventService`), and a
`BaseUpdate` push on success. `FusionService.luau` (328 lines) is recipe-based:
`FuseBrainrot` (L166) takes two *unplaced* instances, looks up
`Mutations.GetFusionRecipe` (order-independent, 10 recipes), charges 1,000 coins +
25 crystals (`Config.FusionCosts`), consumes inputs, grants the recipe result at
level 1, refunds + restores on failure, and reports via a `FusionResult` action
envelope on `BaseUpdate` (L250). Both services fall back to `UpgradeBrainrot` if
their named remote ever disappears (dead fallback today — the names exist).

### Powers / abilities
Two services share one remote, partitioned by id. `CombatService` owns melee +
character primaries + generic slam/heal on `UseAbility`; `AbilityService.luau`
(792 lines) owns the 12 playable loadout powers (`Powers.PlayablePowers`, the single
source of truth since the v1.0.1 `SPEC_POWERS` deletion): `UsePower` (L537) validates
equipped + unlocked, per-power cooldown, and applies real server-side effects
(dash BodyVelocity, energy_shield ForceField, magnet_pull, teleport ≤ 20 studs with
ground raycast, gravity_shift, freeze_blast, shadow_walk, clone_decoy, tide_surfer
immunity via `TideService.GrantSurfer`, rift_hook, chaos_burst, time_distortion).
Loadout is 3 slots (`data.AbilityLoadout`, default dash/energy_shield/magnet_pull),
pushed to the client by `PushLoadout` on join; cooldown state is pushed on
`PowerUpdate`, which `AbilityController` listens to. `UsePower` (the *remote*) is
unwired — the Lua method `AbilityService.UsePower` is called only from the
`UseAbility` handler. **See §3 F1:** melee `Attack` likewise has a server handler
but no client firer.

### Quests
`QuestService.luau` (555 lines) defines 16 quests (Tutorial/Daily/Collection/
Exploration/Raid/Mutation/Combat/Event) as a data table with `{Id, Name, Description,
Category, Event, Goal, Reward={Coins, Gems, XP, EventTokens}}`. Progress is
auto-tracked two ways: `RecordEvent(player, eventName, amount)` called by other
services, plus a 5s poll in `Init` that derives earn-coins (balance delta),
own-distinct and discover-Epic+ from player data, and a zone poll (within 20 studs
of the ForbiddenRift / MutationLab folder centres, found by recursive workspace
search). Rewards are granted exactly once through `ClaimQuest` (server re-checks the
goal), paid in coins + gems (note: gems are written by direct field assignment,
`data.Gems +=`, not via any currency API — see §4f) + XP via `ProgressionService.AddXP`
when linked, else raw `DataService.AddXP`. Daily quests reset by calendar day
(`data.QuestDay`). Client pulls via `RequestQuests` and receives `QuestUpdate` pushes.

### Progression / rebirth
`ProgressionService.luau` (688 lines) owns XP/levels (shared `Economy.XPForLevel`
curve: 100 + 25/level), level-up rewards (50 + 25×level coins, +5 gems every 5
levels, +1 base slot every 10 levels clamped to `BaseSlotsMax`), `Rebirth` (L348:
Level ≥ 25 + 100,000 coins + 10 *distinct* owned Brainrots, all read from
`Config.RebirthRequirements`; resets coins/level/XP/placed slots, keeps `Unlocked`
+ `OwnedInstances` with `Placed=false`, +25 gems, +10% income/rebirth, +2 slots/
rebirth, max 10 rebirths), the collection book (`GetCollection`, merging
`Unlocked` + placed + `CollectionDiscovered`), and 11 cosmetics (titles/auras/
trails by level/rebirths/distinct count, equipped via the `EquipCosmetic` remote —
not the `SelectCharacter` envelope the header still claims). `AddXP` (L252) is the
one level-up path other services should call instead of `DataService.AddXP`.

### Events / tides
`TideService.luau` (923 lines) runs the signature event on a scheduler: idle
countdown (`Config.GlitchTideIntervalSeconds` = 240s) → Warning (30s, storm lighting,
`SetGlitchMode(true)`, siren `SpawnEffect`) → Active (60s, a physical wave wall
sweeps the TideChannel waypoints, players outside safe zones take damage + stun and
drop what they carry) → Calm → Survivor broadcast. Five variations roll weighted
from `Config.TideVariations` (Standard 40 / Fast 20 / Toxic 15 / Frozen 15 / Meteor
10) with real behaviour per variation (Fast 1.5× wave speed, Toxic DoT in the
channel, Frozen halves WalkSpeed with restore bookkeeping, Meteor spawns damaging
meteors every 2s). Survivors get ~100 coins × reward multiplier + 50 XP + 5 tokens
(flawless +5 tokens; Meteor +3 Chaos Shards), quest events fire, and every 5th tide
spawns the boss. `EventService.luau` (626 lines) rotates 6 events (Golden Hour 2×
income 120s, Mutation Storm half-price mutations, Meteor Shower via
`TideService.ForceStart("Meteor")`, Secret Merchant flag, Glitch Invasion NPC wave,
Chaos Arena KO challenge) with a 150–240s gap, never repeating the last event, first
event 60s after start; `GetIncomeMultiplier` / `GetMutationCostMultiplier` /
`GetGlitchChanceBonus` are the read API.

### Bosses / waves
`BossService.luau` (620 lines) spawns THE ALGORITHM (5,000 HP, parts-built obelisk)
in the Chaos Arena on `EventService` trigger, every 5th tide, or its own 30-min timer
(`RESPAWN_INTERVAL`). Three phases by HP (P1 >66%: speed 10, dmg 15, melee only;
P2 33–66%: speed 14, dmg 25, radial shockwave every 8s; P3 <33%: speed 18, dmg 35,
meteor rain every 5s, 2 minion summons every 20s — summons skipped without
`NPCService`). Damage credit comes from `CombatService`'s Creator tag on
`HealthChanged` deltas — no client-supplied damage is trusted. Death pays the top
damager +50 gems and a guaranteed unowned Epic/Legendary/Mythic grant, every
participant +10 Event Tokens + 200 coins, and fires `defeat_boss`. **No `BossUpdate`
is ever fired** — the boss announces via `SpawnEffect`/`WaveUpdate` only, and
`GetBossState()` has no client poller. `WaveService.luau` (368 lines) is the
secondary PvE loop: wave N spawns N+2 wild NPC Brainrots (cap 24, mini-boss every
5th wave at 5× HP / 2× damage / double reward), pays `Economy.CoinsForWave` + XP to
all players on clear, auto-starts in `Init`, and falls back to minimal block-enemies
when `NPCService` is absent.

### NPCs
`NPCService.luau` (772 lines) builds part-only NPCs (HumanoidRootPart + welded torso/
head + coloured body, no assets/rigs) in a workspace `NPCs` folder, with a
Wander→Chase→Attack→Flee state machine on a 1s staggered Heartbeat tick, max 6
AI-ticked NPCs (`MAX_AI_NPCS`), PathfindingService with direct-walk fallback.
Four spawners: `SpawnVendor` (stationary, ProximityPrompt → `NPCDialogue` lines),
`SpawnQuestGiver` (same, lists live quests), `SpawnGuard` (patrols 4 points around
a base, chases non-owners within 20 studs, registers via `RaidService.RegisterGuard`),
`SpawnEnemy(characterId, position, opts={Health, Damage, Scale})`. Death pays 25
coins + 20 XP via `HandleNPCDeath` (L525). **See §3 F6:** only `SpawnVendor`
(Secret Merchant event) and `SpawnEnemy` (events/waves) are ever called — the
quest-giver and guards are never spawned by any code path.

### Map / world
`MapBuilder.luau` (615 lines) builds the whole world at runtime into a model named
`GlitchTideWorld` (Workspace is intentionally empty in the Rojo tree): 420×420 ground
with boundary walls at ±210, 7 zones — `MemeversePlaza` (spawn at (0,3,0), portal
ring, tower, leaderboard/event boards, fountain), `RiftMarket` (conveyor belt 62×6
at z=-60, waypoints x=-30..+30, spawn/end gates), `BaseDistrict` (12 plots on a
ring of radius 120, ~62 studs apart), `TideChannel` (markers at z=75, channel floor
300×10, 3 escape platforms at y=6 with ramps, 3 safe shelters at z=92),
`MutationLab`, `ChaosArena` (30×30 platform + 4 enemy spawn pads), `ForbiddenRift`.
Each plot has 10 pedestals (2×5), a gate (the wall facing map centre), owner sign,
upgrade station and one PointLight; total light budget is tracked (`_lightCount`).
Accessors: `GetBasePlot(i)` → `{Index, Center, Folder, Floor, Gate, Sign, Station,
Pedestals, PedestalParts}`, `GetBasePlots()`, `GetConveyorPath()`, `GetSafeZones()`
(3 platforms r=7 + 3 shelters r=8), `GetSpawnPosition()`, `GetBeltParts()`,
`GetBeltBounds()`. `Build()` is idempotent.

### Character models / animation
`CharacterModels.luau` (593 lines) builds all 18 Brainrots procedurally from Parts
only — one builder branch per `BuildSpec.BodyShape` (18 shapes: Waffle, Turnip, Jelly,
Comet, Noodle, ToastGhost, Dumpling, PicklePirate, Mochi, Gumball, SoupShip, Puddle,
Spaghetti, Zucchini, Cupcake, Goose, Crab, WobbleKing), each with distinct sizes,
materials and a signature prop welded to the HumanoidRootPart, plus eyes/smile.
Contract: `Build(def, parent)` / `BuildCharacterModel(characterId, parent)`
(with a grey "Fallback Friend" for unknown ids), `SetDisplayMode(model, anchored)`
for static display, `ApplyMutation(model, mutationId)` (recolours `IsBodyPart` parts),
`GetIdleOffset(t)` (sine bob). Models are unanchored, welded, `CanCollide=false`,
`Massless=true`. `CharacterService.ApplyCharacter` (L216) morphs by building the new
model, parenting it to workspace *before* destroying the old avatar, setting
`PrimaryPart = HumanoidRootPart` with the root unanchored, preserving position and
health fraction, and reassigning `player.Character`. Animation is purely procedural:
`AnimationController` (315 lines) drives Motor6D CFrames on RenderStepped (idle bob,
walk swing, attack sweep, carry pose with arms up) and `BaseService` bobs placed
models at 0.1s intervals — **no keyframed Roblox animations exist anywhere**.

### UI architecture
All UI is built in code (no .rbxmx / ScreenGui assets). `MainMenu.luau` (606 lines,
in StarterGui → PlayerGui) is the entry screen: PLAY / COLLECTION / SETTINGS (mute
+ volume via `SoundController`) / HOW TO PLAY, with in-menu fallback panels when a
controller is absent; it finds controllers via `PlayerScripts`, not `script.Parent`.
`HUDController.luau` (1,172 lines, the largest client file) owns the HUD ScreenGui
(health, coins, gems, shards, income/s, XP/level, timer, wave, KOs, player count,
team, tide countdown, carrying + base chips, quest tracker, damage vignette,
`ShowEventBanner(text, duration)`) and the bottom menu bar (Market/Shop/Brainrots/
Base/Quests/Collection) that lazy-requires controllers on click. Panels, each owned
by one controller: Market (`MarketController`, N), Shop 5 tabs (`ShopController`, B:
Upgrades / Brainrots / Mutations / Fusion / Powers), Brainrots picker
(`CharacterSelectController`, C), Base (`BaseController`, V), Quests
(`QuestController`, J), Collection (`CollectionController`, L). Every purchase button
shows "Sent — waiting for server…" and only confirms on a server push or a fresh
RemoteFunction reply, with a 5s no-reply watchdog. `Main.client.luau` loads
controllers in fixed order (HUD → Interaction → Market → CharacterSelect → Shop →
Base → Ability → Quest → Collection → Camera) and auto-loads any extra module with
an `Init()` afterwards; `EffectsController` (666 lines) owns particles/shake/damage
numbers, `SoundController` (281 lines) uses built-in `rbxasset://` sounds only, and
`RarityColors.luau` is the shared rarity→colour table.

### Data / economy
`DataService.luau` (413 lines) is the persistence layer: one DataStore
(`Config.DataStoreName` = `GlitchTide_Data_v1`, key `Brainrot_Player_<UserId>`),
3-attempt load/save with retries, `applyDefaults` merging so old/partial saves stay
valid, daily bonus (50 + 10/streak-day, cap day 7, via `Economy.DailyBonusAmount`),
autosave every `Config.AutosaveInterval` (120s) + save on leave + `BindToClose`
(live servers only). The load-failure guard is a genuine strength: if the store
can't be read, `_loadFailed` is set and `SaveData` **refuses** to overwrite the real
save with fresh defaults for that session. Persisted shape (`DEFAULT_DATA` + lazily
added fields): `Coins, XP, Level, Unlocked[], Selected, Wins, KOs, LastLogin,
LoginStreak, Gems, ChaosShards, MutationCrystals, EventTokens, Rebirths,
OwnedInstances[], BankedIncome`, plus `Base{...}` (via `BaseService.ensureBaseData`),
`Quests{}`/`QuestDay`, `AbilityLoadout`/`UnlockedPowers`, `Cosmetics`,
`CollectionDiscovered`, `BaseSlots`. `EconomyService.luau` (290 lines) is the
server-authoritative purchase/award layer (`BuyCharacter` with race-safe refund,
`AwardKO`/`AwardWin`/`AwardWave`, level-ups in `grantXP`), and the shared pure
`Economy.luau` (241 lines) holds the math both sides can use (XP curve, KO/win/wave
rewards, `IncomePerSecond`, `UpgradeCost`, `ConveyorPrice`, `StealReward`,
`FusionCost`). **There is no `AddCoins`/`AddGems` API on EconomyService** — callers
use `DataService.AddCoins/AddXP` directly, and gems/shards/crystals/tokens are
mutated by direct field assignment in each service (§4f).

### Security / anti-cheat
`SecurityService.luau` (233 lines) is a dependency-free helper module: `RateLimit`
(fixed-gap), `ValidateCooldown` (returns remaining seconds), `BurstLimit` (N calls
per window), `ValidateDistance` (live HumanoidRootPart within N studs),
`SanitizeId` (1–64 chars, `^[%w%-_]+$`), `LogCall`/`GetCallLog` (capped at 200
entries/player), `ClearPlayer`. It self-registers its `PlayerRemoving` cleanup hook
at require time because **`Init()` is never called** from `Main.server` or
`GameManager` — the module comments document this explicitly. Actual enforcement is
uneven: `BurstLimit(player, key, 5, 5)` guards `BuyCharacter` and `SelectCharacter`
(v1.0.1 I6); most other services roll their own local `rateOk` fallback (0.25s–1s
per key) and call `Security.RateLimit` only if the lazy require succeeded; the
server never trusts client-supplied damage, prices, or ids (Combat stamps Creator
tags; Conveyor/BuyCharacter recompute price server-side; ids are sanitised per
service). No server-side movement/teleport validation exists beyond the per-action
distance checks (12 studs buy/pickup, 8 studs steal channel).

### Camera
`CameraController.luau` (464 lines) owns the binding explicitly after the v1.0.1
stuck-camera fix: rebind on every `CharacterAdded` **and** every `player.Character`
property change (morph/swap, which never fires `CharacterAdded`), on respawn,
teleport (snap when the camera is > 50 studs from the root, to 11 studs behind /
6 above), and death/recovery; waits for the live Humanoid + HumanoidRootPart with
a 5s timeout (never an infinite yield); sets `CameraType = Custom` and
`CameraSubject = <live Humanoid>`; a 0.5s watchdog rebinds if the subject is nil,
dead, a different Humanoid, or the CameraType drifted to Scriptable; it also
rebinds when `CurrentCamera` itself changes. Once bound it never fights the default
camera (only the one-off snap writes CFrame); FOV punch/celebrate are tween-only.
`Main.client.luau` adds a redundant safety-net rebind on the same two events.
`EffectsController` is the only other file touching the camera — shake only, via
`BindToRenderStep` at Camera priority +1, offset-only, never storing CFrame (the
old compounding random-walk bug is fixed). **Not verified in Studio** — the
regression test in `GROK_BUILD_HANDOFF.md` §1 is still the first thing to run.

---

## 2. What is SOLID (verified working patterns)

- **Canonical keybinds, single source of truth.** `Config.Keybinds` (`Config.luau:87`)
  — Q primary, F Slam, R Heal, E Interact, G Drop, 1/2/3 loadout — is read by
  `AbilityController` (L56–60), `Config.AbilitySlots` / `Config.GenericAbilities`
  match it, and `Utils.GetKeybinds` derives ability keys from it dynamically.
  The v1.0.0 three-way keybind collision is genuinely gone (one stale comment
  remains in `Utils.luau`, §3 F4 — the *values* are correct).
- **12 plots = 12 players.** `Config.MaxBasePlots = 12 = Config.MaxPlayers`
  (`Config.luau:371`), `MapBuilder` builds exactly 12 plots on a radius-120 ring.
- **Camera manager.** `CameraController` rebinds on `CharacterAdded` +
  `Character` property change + 0.5s watchdog + 50-stud snap; `CharacterService`
  makes morphed models valid subjects (PrimaryPart, unanchored root,
  parent-before-destroy). Only `CameraController` (11 refs) and
  `EffectsController` (2 refs, shake-only) touch the camera (QA §3 T6).
- **Server-authoritative remotes.** Prices, damage, cooldowns, quest goals,
  rebirth requirements and steal outcomes are all computed server-side; the
  client only sends ids/intent. `ConveyorService.BuyItem` claims the item before
  charging; `EconomyService.BuyCharacter` refunds on a lost unlock race.
- **DataStore load-failure guard.** `DataService` refuses to save over a real
  save when the load failed (`_loadFailed`, `DataService.luau:287`); defaults are
  merged onto old saves (`applyDefaults`); 3-attempt retries; autosave + leave
  save + `BindToClose`.
- **Remote contract in one file.** `Remotes.luau` is the single source of truth
  for all 45 names, creation is server-guarded and idempotent, and its header
  comment honestly documents which names are wired / broadcast-only / orphan /
  reserved. All 5 RemoteFunctions have server `OnServerInvoke` handlers
  (fixed in v1.0.1 I2/I2b).
- **Optional-service loading that degrades instead of crashing.**
  `GameManager.loadOptional` pcall-requires each of the 11 optional services,
  special-cases each `Init` signature, retries with a no-arg `Init`, then runs
  `wireCrossLinks` as a second pass for late-loaded setters. A missing service
  warns; it never takes the server down.
- **Income math, single application.** `BaseService.singleIncome` delegates to
  `Economy.IncomePerSecond` (level / glitched ×2 / mutation applied exactly
  once — the old Golden 6.25× / glitched 4× double-apply is fixed and commented,
  `BaseService.luau:354`); tide and Golden Hour multipliers are separate and
  never double-applied.
- **Rarity/economy tables are consistent.** `Config.RarityWeights` sums to 1.0
  over 10 tiers; `ConveyorRarityWeights` covers all 10; all 18 `AbilityId`s
  resolve in `Powers`; all 10 fusion `ResultId`s are real characters; mutation
  fallback table is an exact copy of the shared 12 (QA T4/T5: 47/47, 33/33).
- **Defensive client.** Controllers pcall-require shared modules, wait for
  remotes with capped timeouts, degrade gracefully when a remote is absent, and
  never claim purchase success without a server push (5s watchdogs in
  Market/Shop). `Main.client` loads controllers in dependency order and
  auto-loads extra `Init()` modules dropped into the folder.
- **Security helpers exist and are used where it matters most.**
  `BurstLimit(…, 5, 5)` on `BuyCharacter`/`SelectCharacter`; per-service
  `rateOk` fallbacks elsewhere; `SanitizeId` on client-supplied ids;
  `ValidateDistance` available (used by buy/pickup/steal checks via local
  equivalents). `SecurityService` self-registers cleanup at require time so
  the never-called `Init()` is harmless.

## 3. What is FRAGILE (known limits + new findings)

**F1 — NEW, most severe: two server handlers no client can ever reach.**
`Attack` (melee; `CombatService.Init`, `CombatService.luau:810`) and `StealBrainrot`
(`RaidService.Init`, `RaidService.luau:1154`) both have `OnServerEvent` handlers,
and `Main.client.luau:41,56` waits for both names — but a grep over all of
`src/client/` finds **no `FireServer` for either name anywhere**. `MainMenu`
documents "Left Click — Attack" (`MainMenu.luau:166,179`) and the QA report / feature
checklist describe stealing as implemented, yet neither action can be triggered from
any UI, panel, prompt or keybind in this tree. Melee combat and stealing are
effectively dead code paths until a client firer is added (likely
`AbilityController`/`InteractionController` for Attack; a steal prompt/panel for
`StealBrainrot`). Grok Build must confirm in Studio — but the static evidence is
unambiguous: zero callers. (By contrast `UseAbility`, `BuyConveyor`, `PlaceBrainrot`,
`Pickup/DropBrainrot`, `Mutate/FuseBrainrot`, `ClaimQuest`, `Rebirth`, `CollectIncome`,
`UpgradeBase/Brainrot`, `Buy/SelectCharacter` all have verified client firers.)

**F2 — Rebirth income: live code contradicts Config, and the comments disagree
with each other.** `Config.RebirthRequirements.IncomeBonusPerRebirth = 0.10`
(`Config.luau:352`) and `ProgressionService.GetIncomeMultiplier` uses it
(`ProgressionService.luau:314`, `rebirthConfig().IncomePer`). But
`BaseService.rebirthIncomeMultiplier` (`BaseService.luau:414–427`) falls back to
`1 + rebirths × 0.25` and its comment calls Config's 0.10 "stale and unused by the
live rebirth implementation" — which is false whenever `ProgressionService` is wired
(it is, via `wireCrossLinks` → `SetProgressionService`). Live behaviour is +10%
when the wiring holds and +25% when `ProgressionService` is absent or its setter
was missed — a silent 2.5× income divergence depending on load order. One source
must win; delete the other. (Related: `ProgressionService.AddXP` and
`EconomyService.grantXP` are *two* level-up implementations — different rewards:
50+25×level coins + gems/slots vs 25 coins/level — and which one runs depends on
which service the caller happened to use. `CombatService`'s fallback path even
calls raw `DataService.AddXP`, which never levels anyone up.)

**F3 — Stale headers/comments that now misdescribe the code (a real hazard for
parallel workers).** `QuestService` header says `ClaimQuest` "reuses the
CollectIncome remote" — it binds `ClaimQuest` directly (`QuestService.luau:524`).
`ProgressionService` header says "Rebirth does not exist in Remotes.Names yet" and
cosmetics reuse `SelectCharacter` — both remotes exist and are bound directly
(`ProgressionService.luau:640,657`). `Utils.luau:61–66` still claims Config binds
slam to "E" and primary/dash both to "Q" (fixed in v1.0.1; values are now correct).
`Types.PlayerData` (`Types.luau:62`) lists fields that are **not** in
`DataService.DEFAULT_DATA` and some that exist nowhere (`UserId, CharacterId,
Deaths, BestStreak, CurrentStreak, OwnedCharacters, LastDailyClaim, DailyStreak,
TotalMatches, TotalEarned, TotalStolen, TotalSteals, HeistsCompleted`) — its own
comment admits the drift. `FEATURE_CHECKLIST.md` claims synergies are "shown via
`SynergyUpdate`" — `SynergyUpdate` is never fired (§4a). Treat every header comment
as suspect until the code beneath it is read.

**F4 — Orphan / reserved remotes (from QA, confirmed by grep).** `BossUpdate` and
`SynergyUpdate`: declared, fired by no service, listened to by no client
(`BossService` uses `SpawnEffect`/`WaveUpdate` instead; synergy is applied silently
inside `GetIncomePerSec`). `RequestCharacter`: no handler, no caller, but
`Main.client` still waits for it. `UsePower` (remote): nothing fires it
(`AbilityService` uses `UseAbility`). `SettingsUpdate`: no settings sync exists;
mute/volume are client-local in `SoundController`. `TradeRequest`/`TradeAccept`/
`TradeCancel`: reserved only — **trading is intentionally omitted** (no handler may
move items/currency). `RequestCollection` / `RequestEvents`: wired server-side but
**no client caller invokes them** (`CollectionController` reads `RequestShop`;
nothing polls the active event) — wired and ready, not yet used.

**F5 — Known omissions from QA §4–§5 (unchanged).** No offline income
(`DataService` tracks `LastLogin` but pays only the daily bonus on rejoin — the
master spec §35 asks for capped offline income). No Achievements module (shown
inside Quests/Collection panels only). No World Selection (single world).
Controller input not bound (desktop WASD/mouse + mobile touch buttons only; the
spec asks for controller "where practical"). Procedural animation only — no
keyframed Roblox animations, no external animation IDs. Tide variations Double /
Dark / GiantBoss are data-only in `Config.TideVariationsDisabled`. Fusion tab shows
unplaced instances only (all-placed players see recipes but nothing to fuse — by
design, server rejects placed inputs). Secret Merchant has a flag but no NPC model
while `NPCService` is absent (see F6).

**F6 — NEW: two NPC types are never spawned.** `SpawnQuestGiver` and `SpawnGuard`
have no callers anywhere in `src/` (only `SpawnVendor` is called, by the Secret
Merchant event at `EventService.luau:348`, and `SpawnEnemy` by events/waves).
`NPCService.Init` only creates the `NPCs` folder and connects the Heartbeat — it
spawns nothing. So the plaza has no quest-giver NPC and no base ever gets a guard
NPC, despite `RaidService.RegisterGuard` and the feature checklist describing guard
defense as implemented. If guards are wanted, something must call
`SpawnGuard(owner, basePosition)` on base assignment.

**F7 — Duplicated logic (drift risk).** `getRemote`/`getFunction`/`fireClient`/
`fireAll` helpers are re-implemented in ~24 files; `rateOk` + `sanitize` are
copy-pasted into Ability/Fusion/Mutation/Progression/Quest/Raid services;
`addXP` (prefer `ProgressionService.AddXP`, else raw `DataService.AddXP`) is
duplicated in Tide/Event/NPC/Wave services; `buildModelFor` (procedural fallback
model) is duplicated verbatim in `ConveyorService` and `CarryService`; income math
exists twice (`Economy.IncomePerSecond` + the manual fallback inside
`BaseService.singleIncome`, which must be kept in sync by hand); upgrade-cost
lookup exists twice (`Economy.UpgradeCost` + `BaseService`'s local copy at
L330–348, with *different* indexing comments — `Economy` special-cases
BrainrotLevel to `table[level]`, `BaseService`'s copy does not visibly do so;
verify before touching either).

**F8 — pcall-hidden errors (445 `pcall` lines across src).** The dominant pattern is
`pcall(fn)` with no error handling or only a `warn` — e.g. `GameManager`'s
optional-service retry calls `service.Init()` with no args on failure and only
warns if *that* fails; `QuestService`'s 5s poll swallows per-player errors
silently (`if not ok then -- never stop the loop`); `BaseService`'s income tick
wraps each player in pcall with no logging at all. Failures are therefore invisible
in production logs unless someone is watching `warn` output. Any new service should
log the error with context, not swallow it.

**F9 — Dead Config keys (arena leftovers, 0 uses outside Config).**
`RoundDuration, IntermissionDuration, LobbyDuration, MinPlayersToStart, UseTeams,
Teams, FFA_TEAM_NAME, CoinPerAssist, DailyBonus, MaxDailyStreak, ShopRefreshSeconds,
MaxCoinsPerMatch, MaxNameLength, SafeZoneHeight, RoundEndDelay, SprintMultiplier,
MaxHealthRegenPerSecond` — the whole round/team system (`MatchState` in `Types`,
`Config.Teams` Red/Blue) is vestigial: `GameManager` runs a persistent world with no
rounds, no teams, no win condition. `CoinPerWin`/`XPPerWin` survive only as fallbacks
inside `EconomyService`. New work should not read these; a cleanup pass could delete
them, but only together with `Types.MatchState` and the HUD round-timer path.

**F10 — Map contacts (QA §2, not re-verified geometrically).** Two minor contacts
recorded in QA and visible in the code comments: the tide-channel floor clips a
2-stud strip of the 30°/150° plot floors (`MapBuilder.luau:365–383`, "different Y,
no collision") and the escape-ramp edge grazes a plot gate post. Also note the
`TideChannel` waypoint contract is implicit: `TideService` reads the *direct
BasePart children* of the `TideChannel` folder sorted by name as the wave path, so
anyone adding a part directly under that folder (instead of under `Props`) silently
reroutes the wave.

**F11 — Balance / economy risks (unverified in play).** Banked income caps at
10,000 and excess is discarded (`BaseService.luau:1395`) — a high-rarity base
(wobble_king earns 18,000/s base) fills the cap in under a second, so the cap is
effectively "collect constantly or lose everything". `Config.MaxCoinsPerMatch`
(5,000) is never enforced. `Economy.CalculateKOReward` caps streak bonus at +50
but there is no cap on total coins from repeated KOs. Rebirth requires 100,000
coins while the bank cap is 10,000 — rebirth savings must sit in `Coins`, not
banked income, which is correct but easy to misunderstand. Synergy bonuses stack
additively and can reach +2.15 for a full roster (QA T5) on top of tide ×2 ×
Golden Hour ×2 = ×4 — late-game income explodes; no playtest has validated the
curve. `WaveService` auto-starts in `Init` and `EventService` starts 60s after
server start — both run even on an empty server.

**F12 — Client fragility.** `InteractionController.findNearest` is intentionally
inert (v1.0.1 I7): E-interact works only through ProximityPrompts or explicit
panels; the header's "every 0.25s it finds the nearest interactable" is stale.
`QuestController` shows a hardcoded *preview* quest list labelled "coming soon"
while live data hasn't arrived — fine, but the preview rewards (100–300 coins)
differ from the real quest rewards. `HUDController` still carries a
`PlayerStats`-as-RemoteFunction polling fallback (`HUDController.luau:1017`) that
`InvokeServer("GetStats")`s every 5s — dead code now that `PlayerStats` is a
RemoteEvent, and a `FireServer("GetStats")` at `HUDController.luau:1145` has no
server handler (silent no-op). `CharacterSelectController` and `HUDController`
both `InvokeServer("GetStats")` on `PlayerStats` in fallback branches — same
dead path. `SoundController` has no music system (SFX only, stated in its header).

**F13 — `data.Base` vs legacy fields.** Three overlapping slot sources exist:
`data.Base.Slots` (live), `data.BaseSlots` (legacy), and `ProgressionService.GetBaseSlots`
(rebirth bonus, clamped to `MaxBasePlots`). `BaseService.effectiveSlots` adds the
rebirth bonus itself (`+2/rebirth`) while `ProgressionService.GetBaseSlots` *also*
adds it — callers must know which one they are reading or slots double-count.
`ProgressionService.Rebirth` sets both `data.Base.Slots` and `data.BaseSlots` to the
same value, which papers over the split for the rebirth path only. Similarly
`data.Placed` (legacy) vs `data.Base.Placed` (live) are both cleared in `Rebirth`
— a sign the migration is incomplete.

**F14 — `CharacterService` / morph edge cases.** Morph debounce is 0.5s per player
and `ApplyCharacter` returns `(true)` when the player has no character yet
(remember-and-apply-later) — callers can't distinguish "morphed" from "queued".
`GameManager.onPlayerAdded` calls `grantStarter` → `CarryService.PickupOwned` after
a 1s delay with no check the player is still carrying nothing. `NPCService.Init`
sniffs its arguments by capability (duck-typing) because `GameManager` passes them
positionally — the same pattern in `EventService.Init` and `AbilityService.Init`
(2nd arg must implement `GrantSurfer`/`ForceStart`/`SpawnEnemy` or it is silently
dropped to nil). A new service with a same-named method can be misdetected.

---

## 4. Integration points for expansion workstreams

### (a) Every remote name — wired / fired / listened

Source: `Remotes.Names` (`Remotes.luau:17–102`); 45 names, 40 RemoteEvents + 5
RemoteFunctions (`RequestShop, RequestBase, RequestQuests, RequestCollection,
RequestEvents`). Verified by grep over `src/server` + `src/client`.

| Remote | Kind | Server handler | Client firer | Client listener | Status |
|---|---|---|---|---|---|
| `Attack` | Event | `CombatService:810` onAttack | **NONE FOUND** | — | Handler exists, unreachable |
| `UseAbility` | Event | `CombatService:815` (primaries/generic) + `AbilityService:785` (loadout; id-partitioned) | `AbilityController:180` | — | WIRED |
| `RequestCharacter` | Event | none | none | — (`Main.client:43` waits for it) | ORPHAN |
| `SelectCharacter` | Event | `CharacterService:421` | `CharacterSelectController:168` | — | WIRED |
| `BuyCharacter` | Event | `EconomyService:121` | `CharacterSelectController:213`, `ShopController:674` (Powers tab) | — | WIRED |
| `RequestShop` | Function | `EconomyService:154` | `CharacterSelectController:135`, `CollectionController:251`, `ShopController:709` (InvokeServer) | — | WIRED |
| `PlayerStats` | Event | none (broadcast only) | — (dead `FireServer("GetStats")` at `HUDController:1145`) | `AbilityController:512`, `CharacterSelectController:454`, `HUDController:1011`, `ShopController:927` | BROADCAST |
| `WaveUpdate` | Event | fired by `BossService`, `WaveService` | — | `HUDController:992` | BROADCAST |
| `RoundUpdate` | Event | fired by `GameManager.Start` (leaderboard, Phase="Persistent") | — | `HUDController:976` | BROADCAST |
| `SpawnEffect` | Event | fired by Combat/Ability/Boss/Progression/Tide/Event | — | `CameraController:450`, `EffectsController:614` | BROADCAST |
| `DamageNumber` | Event | fired by CombatService | — | `CameraController:454`, `EffectsController:617`, `HUDController:1030` | BROADCAST |
| `BuyConveyor` | Event | `ConveyorService:733` | `MarketController:196` | — | WIRED |
| `PickupBrainrot` | Event | `CarryService:732` | `InteractionController:312` | — | WIRED |
| `DropBrainrot` | Event | `CarryService:737` | `InteractionController:360` (G) | — | WIRED |
| `PlaceBrainrot` | Event | `BaseService:1334` | `InteractionController:297` | — | WIRED |
| `StealBrainrot` | Event | `RaidService:1154` onSteal | **NONE FOUND** | — | Handler exists, unreachable |
| `RequestBase` | Function | `BaseService:1354` | `BaseController:317`, `ShopController:734` (InvokeServer; also a stray `FireServer("GetBase")` at `BaseController:327` / `ShopController:751` — no handler, no-op) | — | WIRED |
| `UpgradeBase` | Event | `BaseService:1344` | `BaseController:516`, `ShopController:268` | — | WIRED |
| `UpgradeBrainrot` | Event | `BaseService:1349` | `BaseController:267`, `ShopController:329` | — | WIRED |
| `CollectIncome` | Event | `BaseService:1339` | `BaseController:302` | — | WIRED |
| `ConveyorUpdate` | Event | fired by `ConveyorService`, `GameManager.sendWelcome` | — | `MarketController:456` | BROADCAST |
| `BaseUpdate` | Event | fired by `BaseService`, `MutationService`, `FusionService` (incl. `FusionResult` Action envelope) | — | `BaseController:584`, `HUDController:1125`, `ShopController:946` (+ `FusionResult` check at `ShopController:800`) | BROADCAST |
| `CarryUpdate` | Event | fired by `CarryService`, `GameManager.sendWelcome` | — | `HUDController:1135`, `InteractionController:547` | BROADCAST |
| `StealAlert` | Event | fired by `RaidService` | — | `BaseController:592` | BROADCAST |
| `GlitchTideUpdate` | Event | fired by `TideService.broadcast` | — | `CameraController:458`, `EffectsController:626`, `HUDController:1043` | BROADCAST |
| `MutateBrainrot` | Event | `MutationService:549` | `ShopController:449` (`{Action="Mutate", InstanceId, MutationId}`) | — | WIRED |
| `FuseBrainrot` | Event | `FusionService:321` | `ShopController:520` (`{InstanceIdA, InstanceIdB}`) | — | WIRED |
| `RequestQuests` | Function | `QuestService:546` | `QuestController:266` (InvokeServer) | — | WIRED |
| `ClaimQuest` | Event | `QuestService:524` | `QuestController:246` (fires questId string, **not** an Action envelope) | — | WIRED |
| `RequestCollection` | Function | `ProgressionService:679` | **NONE** | — | Wired, unused |
| `Rebirth` | Event | `ProgressionService:640` | `BaseController:286` (`{Action="Rebirth"}`) | — | WIRED |
| `RequestEvents` | Function | `EventService:594` | **NONE** | — | Wired, unused |
| `UsePower` | Event | none | none | — | ORPHAN (method exists, remote unused) |
| `PowerUpdate` | Event | fired by `AbilityService` | — | `AbilityController:498` | BROADCAST |
| `TideSurvivor` | Event | fired by `TideService` (end of tide) | — | `HUDController:1088` | BROADCAST |
| `QuestUpdate` | Event | fired by `QuestService.pushProgress` | — | `QuestController:408` | BROADCAST |
| `BossUpdate` | Event | **never fired by any service** | — | none | ORPHAN |
| `EventUpdate` | Event | fired by `EventService` | — | `HUDController:1055` | BROADCAST |
| `SynergyUpdate` | Event | **never fired by any service** | — | none | ORPHAN |
| `TradeRequest` / `TradeAccept` / `TradeCancel` | Event | none — reserved | none | none | RESERVED (trading omitted) |
| `NPCDialogue` | Event | fired by `NPCService` (vendor/quest-giver prompts) | — | `InteractionController:566` | BROADCAST |
| `SettingsUpdate` | Event | none | none | none | ORPHAN (settings are client-local) |
| `EquipCosmetic` | Event | `ProgressionService:657` | *(no client firer found in this audit — verify before relying on it)* | — | WIRED server-side; client path unconfirmed |

**Payload conventions to preserve.** Most handlers take a bare id string
(`BuyCharacter`, `SelectCharacter`, `BuyConveyor`, `Pickup/DropBrainrot`,
`UpgradeBrainrot` = InstanceId, `ClaimQuest` = questId string). Envelopes are the
exception: `Rebirth` needs `{Action="Rebirth"}`; `MutateBrainrot` needs
`{Action="Mutate", InstanceId, MutationId}`; `FuseBrainrot` is a bare
`{InstanceIdA, InstanceIdB}` table; `EquipCosmetic` needs
`{Action="EquipCosmetic", CosmeticId=...}`. `PlaceBrainrot` takes
`(InstanceId, slot)` — InstanceId is a GUID, **never** a CharacterId
(`Types.CarryUpdatePayload` warns about this explicitly). New remotes must be
added to `Remotes.Names` + `EVENT_NAMES`/`FUNCTION_NAMES` in `Remotes.luau` first —
that file is the single source of truth both sides require.

### (b) Config keys each system reads

`Config.luau` (379 lines) is the one balance file. Read map (verified by grep):
- **All:** `GameName, GameVersion ("1.1.0"), MaxPlayers (12), StartingCoins (100),
  StartingGems (10), StarterCharacterId ("wobble_waffleton")`.
- **Combat:** `BaseWalkSpeed (16), BaseJumpPower (50), BaseAttackDamage (12),
  AttackRange (6), AttackCooldown (0.45), KnockbackForce (18), CoinPerKO (25),
  XPPerKO (20), XPPerWave (15), MaxLevel (100), RespawnTime (3)`.
- **Waves:** `WaveInterval (90), BossEvery (5), MaxWaveNPCs (24),
  WaveNPCHealthBase (60), WaveNPCHealthPerWave (18), WaveNPCDamageBase (8),
  WaveSpawnDelay (1.5)`.
- **Keybinds:** `Keybinds {Primary Q, Slam F, Heal R, Interact E, Drop G,
  Loadout1/2/3}`, `AbilitySlots {Primary Q, Slam F, Heal R}`,
  `GenericAbilities {F="slam", R="heal"}` — all three must move together.
- **Conveyor/bases:** `ConveyorSpawnInterval (8), ConveyorRarityWeights (10 tiers),
  ConveyorMaxItems (8), ConveyorLength (60), BaseSlotsStart (4), BaseSlotsMax (10),
  IncomeTickSeconds (1), BaseIncomeMultiplierStart (1.0), CarrySpeedMultiplier (0.6),
  CarryDropOnDeath (true), MaxBasePlots (12)`.
- **Steal/raid:** `StealChannelSeconds (3), StealCooldownSeconds (60),
  StealRewardMultiplier (0.5), BaseLockDuration (30), ShieldCost (100),
  ShieldDurationSeconds (60), LockdownCost (250), LockdownCooldownSeconds (120)`.
- **Tide:** `GlitchTideIntervalSeconds (240), GlitchTideWarningSeconds (30),
  GlitchTideDurationSeconds (60), GlitchTideIncomeMultiplier (2),
  GlitchTideGlitchChance (0.35), TideVariations (5 playable),
  TideVariationsDisabled (Double/Dark/GiantBoss — do not use),
  EventSchedule {GlitchTideIntervalSeconds, BossTideEvery 5,
  WeekendBonusMultiplier 1.5, DailyQuestResetHour 0}`.
- **Upgrades:** `BaseSlotCost, IncomeMultiplierCost, LockCost, TurretCost,
  ConveyorLuckCost, BrainrotLevelCost` (flat lists, last entry repeats),
  `BrainrotLevelIncomeBonus (0.25), MaxBrainrotLevel (5), MaxUpgradeLevel (5)`.
- **Currencies/rarity:** `Currencies {Coins, Gems, ChaosShards, MutationCrystals,
  EventTokens}` (descriptions only), `RarityWeights` (sums to 1.0),
  `MutationCosts` (12 ids), `FusionCosts {Coins 1000, MutationCrystals 25}`,
  `RebirthRequirements {Coins 100000, Level 25, Brainrots 10, RewardGems 25,
  IncomeBonusPerRebirth 0.10, SlotsPerRebirth 2, MaxRebirths 10}`,
  `QuestRewards {DailyCoins 250, DailyGems 5, DailyMutationCrystals 10,
  WeeklyCoins 1500, WeeklyGems 25, WeeklyMutationCrystals 50}` (note: actual quest
  rewards are hardcoded per-quest in `QuestService`, not read from here).
- **Persistence:** `DataStoreName ("GlitchTide_Data_v1"),
  LeaderboardStoreName ("GlitchTide_Leaderboard_v1"), AutosaveInterval (120)`.
- **Dead keys (0 uses):** see §3 F9 — do not build on them.

### (c) Server service Init signatures + load order

`Main.server.luau` order: `Remotes.CreateRemotes` → `MapBuilder.Build()` →
`DataService.Init()` → `EconomyService.Init(DataService)` →
`GameManager.Init(DataService, EconomyService, arena)` → `CombatService.Init(DataService,
EconomyService, GameManager)` (pcall-guarded) → `GameManager.Start()` in its own
thread (pcall-guarded). `GameManager.Init` order inside: `BaseService.Init` →
`CarryService.Init` → `ConveyorService.Init` → setter injection →
`CharacterService` (pcall-required, Init on success) → 11 optional services in
`OPTIONAL_SERVICES` order → `wireCrossLinks()` second pass → PlayerAdded/Removing
hooks → `BindToClose` save.

| Service | Init signature | Optional deps / notes |
|---|---|---|
| `DataService` | `Init()` | None. Starts autosave loop + leave-save + BindToClose. |
| `EconomyService` | `Init(dataService)` | Lazy-requires `SecurityService`. Polls ≤10s for BuyCharacter/RequestShop remotes. |
| `MapBuilder` | `Build(): Model` (not Init) | Idempotent; mutates Lighting. |
| `GameManager` | `Init(dataService, economyService, map)` | Owns core services; `GetService(name)` / `GetOptionalServices()` accessors; `RegisterKO(killer, victim?)`. |
| `BaseService` | `Init(dataService, map)` | Setters: `SetCarryService, SetMutationService, SetRaidService, SetProgressionService, SetEventService, SetTideMultiplier`. |
| `CarryService` | `Init(dataService, baseService)` | Setter: `SetRaidService`. Own Died hook. |
| `ConveyorService` | `Init(dataService, economyService, map)` | Setters: `SetCarryService, SetMutationService, SetLuckProvider(fn()->number)`. |
| `CharacterService` | `Init(dataService)` | pcall-required by GameManager only; never a hard dep. |
| `CombatService` | `Init(dataService, economyService, gameManager)` | Called from Main.server, NOT GameManager. No CarryService hook (CarryService owns death drops). |
| `TideService` | `Init(dataService, map, callbacks)` | callbacks: `DropCarried(player)`, `GetSafeZones()->{{Position,Radius}}`, `SetGlitchMode(bool)`, `IsTideSurfer(player)` — all optional. Setters: `SetQuestService, SetProgressionService, SetBossService`. |
| `QuestService` | `Init(dataService)` | Setter: `SetProgressionService`. Starts 5s poll + zone poll. |
| `NPCService` | `Init(map, combatService, questService, raidService)` | **Duck-types its args by capability** — any arg with `GetOrLoad` is treated as DataService, etc. Setters: `SetDataService, SetCombatService, SetQuestService, SetRaidService, SetProgressionService`. |
| `EventService` | `Init(dataService, tideService?, npcService?, questService?)` | Accepts args only if they implement `ForceStart` / `SpawnEnemy`; else nil. Setters: `SetNPCService, SetTideService, SetQuestService, SetProgressionService`. |
| `MutationService` | `Init(dataService, questService?, eventService?)` | Loads shared `Mutations` table; local 12-entry fallback. |
| `FusionService` | `Init(dataService, mutationService?, questService?)` | — |
| `AbilityService` | `Init(dataService, tideService?)` | 2nd arg accepted only if it implements `GrantSurfer`. Setter: `SetTideService`. |
| `RaidService` | `Init(dataService, baseService?, carryService?, opts?)` | `opts = {MutationService=…, QuestService=…}`. Setters: `SetBaseService, SetCarryService, SetMutationService, SetQuestService`. |
| `BossService` | `Init(map, dataService?, npcService?, questService?)` | All after `map` optional/nil-safe. Setters: `SetNPCService, SetQuestService`. |
| `WaveService` | `Init(dataService, map, npcService?)` | Auto-starts in Init. Setters: `SetNPCService, SetQuestService, SetProgressionService`. |
| `ProgressionService` | `Init(dataService)` | Wires Rebirth / EquipCosmetic / RequestCollection. |
| `SecurityService` | `Init()` | **Never called**; cleanup self-registers at require time. Safe to call (no-op). |

**`GameManager` OPTIONAL_SERVICES pcall pattern** (`GameManager.luau:53–63, 330–470`):
load order is `TideService, QuestService, NPCService, EventService,
MutationService, FusionService, AbilityService, RaidService, BossService,
WaveService, ProgressionService` — order matters because `MutationService.Init`
takes Quest/Event, `FusionService` takes Mutation, `RaidService` takes Mutation/
Quest, `BossService`/`WaveService` take NPC. Each service is special-cased by name
in `loadOptional` (Tide gets the callbacks table; NPC gets `(map, nil, quest, nil)`;
etc.); an unknown service falls back to a generic
`(dataService, economyService, map)` call, then a no-arg `Init()` retry. After all
load, `wireCrossLinks` re-runs every `Set*` setter with the final service set
(including `SetProgressionService`/`SetBossService`/`SetEventService`, which the
first pass missed in v1.0.0). **A new service must be added to `OPTIONAL_SERVICES`
*and* given a branch in `loadOptional` if its Init signature differs from the
generic one — otherwise it silently gets the wrong arguments and falls back to
no-arg Init.** All setters use dot notation (no `self`).

### (d) MapBuilder accessors + zone names other services depend on

- `GetBasePlot(index)` → `{Index, Center, Folder, Floor, Gate, Sign, Station,
  Pedestals: {[slot]=CFrame}, PedestalParts: {[slot]=Part}}` — 10 pedestals, 2 rows × 5.
- `GetBasePlots()` → `{[1..12] = plot}` (same records; live table, not a copy).
- `GetConveyorPath()` → copy of 7 waypoints `(-30..+30 step 10, y 2.6, z -60)`.
- `GetSafeZones()` → copy of 6 zones: 3 escape platforms `{Position (x,6,75),
  Radius 7}` for x ∈ {-90, 0, 90} + 3 shelters `{Position (x,1,92), Radius 8}`
  for x ∈ {-100, 0, 100}. `GameManager` adds all 12 base-plot centres (radius 12)
  when building `TideService`'s safe-zone list.
- `GetSpawnPosition()` → `Vector3.new(0, 3, 0)`.
- `GetBeltParts()` → moving chevron parts (for belt animation); `GetBeltBounds()`
  → `(minX, maxX, beltY)`.
- Zone folder names (children of `GlitchTideWorld`): `MemeversePlaza`,
  `RiftMarket`, `BaseDistrict` (contains `BasePlot1`…`BasePlot12`), `TideChannel`
  (**direct BasePart children are the wave path — see §3 F10**; everything else
  under `TideChannel/Props`), `MutationLab`, `ChaosArena`, `ForbiddenRift`.
  `QuestService` finds `ForbiddenRift`/`MutationLab` by recursive workspace search
  (`FindFirstChild(name, true)`) and uses the first BasePart descendant as the zone
  centre (20-stud radius). `BossService`/`WaveService` find the arena via
  `workspace:FindFirstChild("ChaosArena")` **or** `workspace:FindFirstChild("Arena")`
  as a BasePart, else `_map:FindFirstChild("ChaosArena")`, else `(0,5,0)` — note
  the map model is named `GlitchTideWorld`, so the workspace lookup only works if
  the folders are parented where expected; both services fall back to origin.
- Plot centres: ring radius 120, angle `(i-1)×30°` — plot 1 at (120,0,0), plot 4
  at (0,0,120), etc. Neighbouring plots ~62 studs apart.

### (e) DataService save/load shape

Key `Brainrot_Player_<UserId>` in `GlitchTide_Data_v1`. `DEFAULT_DATA`
(`DataService.luau:39–57`): `Coins (StartingCoins), XP 0, Level 1,
Unlocked {StarterId}, Selected StarterId, Wins 0, KOs 0, LastLogin 0,
LoginStreak 1, Gems (StartingGems), ChaosShards 0, MutationCrystals 0,
EventTokens 0, Rebirths 0, OwnedInstances {}, BankedIncome 0`. Lazily added by
other services (not in DEFAULT_DATA — always guard with `tonumber()/type()` checks):
`Base {OwnerUserId, Slots, IncomeMultiplier, IncomeMultiplierLevel, LockLevel,
TurretLevel, ConveyorLuckLevel, LockedUntil, Placed[], StoredCoins, TotalEarned}`,
`Quests {[id]={Progress, Claimed}}`, `QuestDay "YYYY-MM-DD"`, `AbilityLoadout
[string×3]`, `UnlockedPowers []`, `Cosmetics {Equipped}`, `CollectionDiscovered []`,
`BaseSlots` (legacy). Owned-instance record shape (shared by Conveyor/Base/Carry/
Mutation — **do not change fields without updating all four**):
`{InstanceId (GUID), CharacterId, Level, Glitched (bool), Mutation (string? —
lowercase, e.g. "golden"; glitched buys store "glitched"), Placed (bool),
Slot (number, 0 = unplaced), PurchasedAt (os.time())}`. Placed record shape
(`data.Base.Placed`, `Types.PlacedBrainrot`): `{InstanceId, CharacterId, Slot,
Level, Glitched, Mutation, BankedIncome (per-Brainrot — note: income actually
banks globally in data.BankedIncome; the per-placed field is copied into
snapshots but the tick writes the global), PlacedAt}`. API:
`Init(), LoadData(player), SaveData(player)->bool, GetData(player),
GetOrLoad(player), AddCoins(player, amount)->newBalance (clamped ≥ 0),
AddXP(player, amount), SetLevel(player, level), AddWin(player), AddKO(player),
HasCharacter(player, id), UnlockCharacter(player, id)->bool,
SetSelected(player, id)->bool, GetSelected(player)`. There is **no**
`AddGems/AddCrystals/AddTokens` — those are direct field writes (see §4f).
`SaveData` returns false with no write when `_loadFailed` is set or a save is
already in flight past the 5s wait.

### (f) EconomyService public API — exact method names + signatures

`EconomyService.luau` — **there is no `AddCoins`/`AddGems`/`AddCurrency` method.**
The entire public API is:
`Init(dataService)`; `AwardKO(player, streak)->coins?`;
`AwardWin(player)->coins?`; `AwardWave(player, wave)->coins?`;
`BuyCharacter(player, characterId)->(bool, characterId|reason)`;
`GetBalance(player)->number` (coins only); `NotifyBalance(player)` (fires
`PlayerStats` with `{Coins, XP, Level, Wins, KOs, LoginStreak}`).
Currency mutation in practice: **coins** via `DataService.AddCoins(player, ±n)`
(used by Conveyor, Base, Raid, Quest, Tide, Boss, Combat-fallback, Economy
itself); **XP** via `ProgressionService.AddXP(player, n)->(level, leveledUp)`
(preferred — handles level-ups) or raw `DataService.AddXP` (no level-up);
**gems / ChaosShards / MutationCrystals / EventTokens** via direct field
assignment, e.g. `data.Gems = (tonumber(data.Gems) or 0) + 50`
(`BossService.onBossDeath`), `data.MutationCrystals = crystals - cost`
(`MutationService`, `FusionService`), `data.EventTokens += n`
(`TideService`, `BossService`, `QuestService.ClaimQuest`). A new currency helper
belongs in `DataService` (or a new `EconomyService.AddCurrency(player, key,
delta)` wrapper) — today every service re-implements the `tonumber() or 0`
guard inline. Pure math lives in shared `Economy.luau`:
`CalculateKOReward(streak), CalculateWinBonus(wins), XPForLevel(level),
TotalXPForLevel(level), LevelFromXP(xp), XPProgress(xp), CoinsForWave(wave),
CanAfford, DailyBonusAmount(streak), SpendCoins, IncomePerSecond(placed),
BaseIncomePerSecond(list, mult?), UpgradeCost(kind, level)->number?,
ConveyorPrice(id, glitched?), StealReward(id, banked), FusionCost(a, b)`.
Note the `UpgradeCost` indexing split (§3 F7): kind `"BrainrotLevel"` indexes
`table[level]`, all other kinds `table[level+1]`.

### (g) CharacterDef / BuildSpec / PowerDef shapes + rules for a new Brainrot/power

`Characters.CharacterDef` (`Characters.luau:18–43`, mirrored in `Types.luau:6–36`):
required fields `Id, Name, DisplayName, Rarity, Cost, IncomePerSec, Description,
Health, Speed, Damage, AbilityId, DefenseTrait, Traits {string} (2–3 of Electric |
Cosmic | Food | Royal | Mechanical | Water | Glitch | Ancient), Color, AccentColor,
Scale, MutationCompatibility {string}, Personality, UnlockCondition, BuildSpec`.
`BuildSpec` (`Characters.luau:10–16`): `{BodyColor, HeadColor, BodyShape, Prop,
PropColor}` — `BodyShape` **must** be one of the 18 builder branches in
`CharacterModels.luau` (Waffle, Turnip, Jelly, Comet, Noodle, ToastGhost, Dumpling,
PicklePirate, Mochi, Gumball, SoupShip, Puddle, Spaghetti, Zucchini, Cupcake, Goose,
Crab, WobbleKing); an unknown shape falls through to the grey Fallback Friend.
Rules a new Brainrot must satisfy:
1. `Id` lowercase snake_case, unique; `AbilityId` **must resolve** in
   `Powers.LIST` (all 18 current ids do; QA T4 checks this — a dangling id means
   the character's Q does nothing and `CombatService` ignores it).
2. `Rarity` must be one of the 10 tiers (Common → Impossible) and `IncomePerSec`
   inside the documented band for that tier (`Characters.luau:38–47`: Common 3–8,
   Uncommon 8–20, Rare 20–60, Epic 60–150, Legendary 150–500, Mythic 500–1500,
   Divine 1500–4000, Celestial 4000–8000, Secret 8000–15000, Impossible 15000+)
   **and** `Cost` must be consistent with the tier (conveyor weights + shop
   pricing + fusion recipes all key off these).
3. `MutationCompatibility` lists the mutation ids the character may take
   (subset of the 12 in `Mutations.luau` / `Config.MutationCosts`); empty or
   missing means `CanMutate` returns false. Mutation ids are case-insensitive
   in lookups but stored lowercase in instances.
4. `Traits` drive synergies (`Synergies.luau`: 10 rules, e.g. 2× Electric = +15%);
   adding a new trait string with no synergy rule is harmless but inert.
5. If the Brainrot should be fusable, add a recipe to `Mutations.FUSION_RECIPES`
   (`{Characters={idA, idB}, ResultId, Hint}` — order-independent, `ResultId`
   must be a real character id); if it should be a fusion *result*, it must be
   somebody's `ResultId`. The capstone recipe (`caramel_crab + wobble_king →
   wobble_king`) shows results may equal an input.
6. Do not reuse the removed id `tung_tung` or any copyrighted Italian Brainrot
   name — the roster is original by design (QA T4 checks this).
`Powers.PowerDef` (`Powers.luau:22–33`, `Types.luau:38–49`): `{Id, Name, Key,
Cooldown (≥3s, enforced by convention), Damage, Range, Radius, Effect, Description,
Color}`. Character primaries use `Key="Q"`; generics are `slam` (F) and `heal` (R)
in `Powers.LIST` + `Config.GenericAbilities`. `PlayablePowerDef` adds
`{Duration, Cost}` (coins to unlock). Rules for a new power: add it to
`Powers.PlayablePowers` (12 today: dash, energy_shield, magnet_pull, teleport,
gravity_shift, freeze_blast, shadow_walk, clone_decoy, tide_surfer,
time_distortion, rift_hook, chaos_burst) **and** implement its effect branch in
`AbilityService.UsePower` — a def with no branch is silently ignored
(`getPlayableDef` nil → return). `Effect` is a free string naming the behaviour;
`Cooldown`/`Cost` are read from the shared def, never hardcoded in the service.
A new *primary* ability needs a `Powers.LIST` entry **and** a branch in
`CombatService.onUseAbility` (same rule — def without a branch does nothing).

### (h) UI controller contracts

- **HUDController** owns the HUD ScreenGui + menu bar + `ShowEventBanner(text,
  durationSeconds)` (`HUDController.luau:340`) — the one banner API other
  controllers/services reach through (event/tide/survivor notices arrive via
  `EventUpdate`/`TideSurvivor` listeners at L1055/L1088). Public setters:
  `SetHealth/SetCoins/SetGems/SetShards/SetIncome/SetRegion/SetXP/SetLevel/
  SetKOs/SetTimer/SetWave/SetPlayerCount/SetTeam/SetTide/SetCarrying/
  SetBaseStatus/SetQuestTracker/RefreshQuestTracker/FlashDamage/
  UpdateLowHealth/OpenPanel(moduleName)` (L157–490). Menu bar lazy-requires
  controllers on click — HUD never hard-depends on another controller's Init.
- **MainMenu** (`client/ui/MainMenu.luau`): `Show()/Hide()/IsVisible()/
  SetCharacterPreview(text)/Init()`; buttons PLAY (close), COLLECTION (opens
  `CollectionController` or an in-menu catalogue fallback), SETTINGS (mute/volume
  via `SoundController`), HOW TO PLAY (static text incl. keybinds from
  `Utils.GetKeybinds`). Required by `Main.client` from `PlayerGui` (cloned from
  `StarterGui` — the v1.0.2 packaging fix; do not move it under StarterPlayer).
- Panel ownership + toggle keys (from `Utils.GetKeybinds`): Market N
  (`MarketController`), Shop B (`ShopController`, tabs Upgrades/Brainrots/
  Mutations/Fusion/Powers via `SetTab(tab)`), Brainrots C
  (`CharacterSelectController`), Base V (`BaseController`, incl. Rebirth button +
  StealAlert banner), Quests J (`QuestController`, `Claim(questId)`,
  `GetTopQuest()` for the HUD tracker), Collection L (`CollectionController`,
  `MarkDiscovered(id)`, `GetDiscoveredCount()`). `AbilityController` owns the
  loadout bar (`UseSlot(slotKey)`, `SetCharacter(id)`, `SetLoadout(loadout)`,
  `GetLoadout()`, `RefreshBar()`); `InteractionController` owns E/G
  (`Interact()`, `Drop()`, `ApplyCarryUpdate(payload)`, `ShowDialogue(payload)`,
  `IsCarrying()/GetCarried()`); `CameraController` exposes `Rebind(snap?)` /
  `BindCamera(character)` / `ForceSnap()` / `GetBoundHumanoid()`; `AnimationController`
  exposes `PlayAttack/PlayJump/PlaySpawnSpin/SetCarrying/Stop/Step(dt)`;
  `EffectsController` exposes `Shake/Flash/Burst/Ring/Poof/GlitchPadSparkles/
  GlitchAura/StealAlarm/SetGlitchActive`; `SoundController` exposes
  `PlaySound(name)/PlayHit/PlayKO/PlayCoin/…/IsMuted/SetMuted/ToggleMute/
  GetVolume/SetVolume`.
- **Cross-controller communication is by lazy `require` + public method, never by
  shared state**: e.g. `InteractionController.Interact` requires `MarketController`
  / `BaseController` / `ShopController` on demand; `HUDController.OpenPanel`
  lazy-requires the target. A new panel must follow this: one controller, one
  ScreenGui, `Open/Close/Toggle/IsOpen/Init`, hotkey from `Utils.GetKeybinds`,
  and an entry in `Main.client.CONTROLLER_ORDER` (or it loads last via the
  auto-load sweep — order-sensitive panels must be listed explicitly).

### (i) TideService phases / variation table / callbacks

Phases (`TideService.luau:47, 311`): `Idle → Warning (30s) → Active (60s) →
Calm → Survivor → Idle`, broadcast on `GlitchTideUpdate` as
`{Phase, TimeLeft, NextTideIn, Variation, IncomeMultiplier, GlitchChance}`
(`Types.GlitchTidePhase`; Calm and Survivor are broadcast as two separate
messages at tide end). Variation table: built at load from
`Config.TideVariations` into `VARIATIONS[id] = {Weight, WaveSpeed, RewardMult,
DamageMult}` with a hardcoded 5-entry fallback (`TideService.luau:70–80`) —
**Config wins when present; the fallback literals must be kept in sync by hand.**
Callbacks (from `GameManager.loadOptional`, `GameManager.luau:340–375`):
`DropCarried(player)` → `CarryService.DropCarried(player, "tide")`;
`GetSafeZones()` → `MapBuilder.GetSafeZones()` + all base plots (radius 12);
`SetGlitchMode(bool)` → `ConveyorService.SetGlitchMode` + `BaseService.SetTideMultiplier(2 or 1)`;
`IsTideSurfer(player)` → lazily resolves `AbilityService.IsTideSurfer`
(AbilityService loads later). Public API: `GetState()->{Phase, TimeLeft,
NextTideIn, Variation, IncomeMultiplier}`, `IsTideActive()`,
`GetIncomeMultiplier()`, `GrantSurfer(player, durationSeconds)`,
`IsSurfer(player)`, `IsInSafeZone(player)`, `ForceStart(variationId?)->bool`
(false when a cycle is running or the variation is unknown — including the three
demoted ones), `GetTideCount()`, setters `SetQuestService/SetProgressionService/
SetBossService` (each validates the interface before accepting), `Init(dataService,
map, callbacks)`. Damage constants are locals, not Config: `TIDE_DAMAGE 12`,
`TOXIC_DOT 6`, `METEOR_DAMAGE 25`, survivor `100 coins / 50 XP / 5 tokens`
(× RewardMult; flawless +5 tokens; Meteor +3 Chaos Shards). Every 5th tide
(`Config.EventSchedule.BossTideEvery`) calls `BossService.SpawnBoss()` when linked.
A new variation needs: a `Config.TideVariations` entry **and** a behaviour branch
in `runCycle` (wave speed / DoT / slow / meteors are the existing hooks) **and**
an entry in the `VARIATIONS` fallback — adding Config-only data with no behaviour
repeats the v1.0.0 Double/Dark/GiantBoss failure.

### (j) BossService boss pattern (phases, rewards, damage credit)

Pattern for a new boss: build a parts-only model with `HumanoidRootPart` as
`PrimaryPart`, set `model:SetAttribute("Damage", n)`, connect
`humanoid.HealthChanged` to attribute deltas to the current `Creator` ObjectValue
(`CombatService` stamps it on every hit — **damage credit must come from Creator,
never from a client argument**), connect `humanoid.Died` to the death handler,
and fire `SpawnEffect {type="BossSpawn"|"BossPhase", phase, position}` +
`WaveUpdate {BossSpawned=true | BossDefeated=true, TopDamager}` (there is no
`BossUpdate` fire — if a boss-health UI is added, it must either use
`GetBossState()` via a new RemoteFunction or start firing `BossUpdate`).
THE ALGORITHM's numbers (`BossService.luau:38–44`): `BOSS_MAX_HEALTH 5000`,
`RESPAWN_INTERVAL 30 min`, phase thresholds 0.66 / 0.33; P1 speed 10 / dmg 15 /
melee only; P2 speed 14 / dmg 25 / shockwave (knockback + 20 dmg, 15 studs)
every 8s; P3 speed 18 / dmg 35 / meteor rain every 5s / 2 minion summons every
20s (via `NPCService.SpawnEnemy`, skipped without it); one Heartbeat loop, 0.5s
boss tick. Rewards (`onBossDeath`, L380–460): top damager +50 gems (direct field
write) + guaranteed unowned Epic/Legendary/Mythic grant (falls back to any
Epic+ if all owned); every participant (damage > 0) +10 Event Tokens + 200 coins;
`QuestService.RecordEvent(player, "defeat_boss", 1)`. `SpawnBoss()->bool`
(false when already active); `IsBossActive()`, `GetBossState()->{Active,
Health, MaxHealth, Phase}`, `OnEventTrigger()` (EventService entry point),
`Init(map, dataService?, npcService?, questService?)`.

---

## 5. Safe for parallel editing vs single-owner files

**Single owner — one writer at a time, coordinate every change:**
- `src/shared/Config.luau` — every system reads it; a wrong value breaks
  balance everywhere. Keybind/economy/rebirth changes need a second look at §3
  F2/F7 (the +10% vs +25% split lives here).
- `src/shared/Remotes.luau` — the remote contract; renaming/adding a name
  desyncs server and client. New remotes go here first, with the wiring-status
  comment updated in the same change.
- `src/server/Services/GameManager.luau` — load order, optional-service
  special-casing, cross-linking, join/leave hooks, starter grant. A new service
  touches `OPTIONAL_SERVICES` + `loadOptional` + `wireCrossLinks` together.
- `src/server/Main.server.luau` — boot order (remotes → map → data → economy →
  game loop → combat → start). Any Init-order change goes through here.
- `src/server/Services/DataService.luau` — the persisted shape; adding/removing
  a field affects saves, defaults, migration and every service that lazily
  creates fields. Never change `DEFAULT_DATA` without updating `applyDefaults`.
- `src/server/Services/MapBuilder.luau` — the whole world; zone names, plot
  records, safe zones and the TideChannel waypoint contract (§4d) are depended
  on by Tide/Quest/Boss/Wave services. Geometry changes need the §3 F10
  contacts re-checked.

**Safe for parallel editing (low coupling, one owner per file is still preferred):**
- `src/shared/Characters.luau` (add a Brainrot — follow §4g rules; do not touch
  the 18 existing entries' ids), `src/shared/Powers.luau` (add a power def — the
  effect branch lives in `AbilityService`/`CombatService`, a separate file),
  `src/shared/Mutations.luau` (add a mutation + `Config.MutationCosts` entry;
  keep the `MutationService` fallback table in sync), `src/shared/Synergies.luau`
  (add a synergy rule — pure data), `src/shared/Economy.luau` (pure math — but
  coordinate with `BaseService`'s duplicated fallback, §3 F7),
  `src/shared/CharacterModels.luau` (add a `BodyShape` branch + a roster entry).
- `src/server/Services/EventService.luau` (add an event entry to `EVENTS` —
  self-contained `{Id, Name, Duration, Cooldown, Start(), End()}`),
  `src/server/Services/QuestService.luau` (add a quest to `QUESTS` + a
  `RecordEvent` call site), `src/server/Services/NPCService.luau` (new NPC kind —
  but spawning call sites are the gap, §3 F6), `src/server/Services/WaveService.luau`,
  `src/server/Services/BossService.luau` (new boss following §4j — coordinate
  with `TideService` if it should appear on boss tides).
- Client panels: `MarketController`, `ShopController`, `BaseController`,
  `QuestController`, `CollectionController`, `CharacterSelectController`,
  `EffectsController`, `SoundController`, `AnimationController` — one controller
  per panel; do not touch `HUDController` (menu bar + banners) or `MainMenu`
  without coordinating, since every panel hangs off them.
- `src/shared/Types.luau` is *documentation-grade* — safe to edit, but its
  `PlayerData` is already stale (§3 F3); fix it in the same change as any
  `DataService` shape change, not separately.

**Do-not-touch without a design decision:** `src/shared/Utils.luau`
(`GetKeybinds` is the client-wide bind table — a change moves every label and
handler at once; fix the stale comment in §3 F3 first), `src/client/Main.client.luau`
(`CONTROLLER_ORDER` + camera safety-net wiring), `src/server/Services/SecurityService.luau`
(shared by 8 services via lazy require — changing `RateLimit`/`BurstLimit`
semantics changes every caller), `default.project.json` / `rojo.toml`
(the v1.0.2 packaging fix; any hierarchy change re-breaks `MainMenu` cloning).

---

## Appendix — verification notes and limits

- **Counts re-verified in this audit:** 48 Luau files; `wc -l` total 26,061;
  18 Brainrots; 12 mutations; 10 fusion recipes; 12 playable powers + 18 primaries
  + 2 generics; 16 quests; 6 world events; 5 playable tide variations;
  21 server services (incl. GameManager) + SecurityService; 14 client controllers
  + RarityColors; 45 remote names.
- **v1.1 = v1.0.2 code.** `diff -r` between `~/workspace/your_files/glitch-tide-v1.1/`
  and `~/workspace/your_files/brainrot-battle-arena/` is empty; only
  `Config.GameVersion` reads `"1.1.0"` while the bundled QA report, changelog and
  feature checklist still say 1.0.2. Any "v1.1" claim beyond the version string
  should be treated as unmade until a changelog entry exists.
- **What this audit did NOT do:** no Studio playtest, no `rojo build`, no Luau
  compile/analyze run, no live DataStore round-trip, no multi-client test. The
  camera fix, the income formula, the steal flow and the boss fight are all
  code-reviewed here, not proven running. The two unreachable remotes (§3 F1)
  are static findings (zero client callers by grep) — they still need a Studio
  confirmation that no dynamic path (e.g. a `require`d module not under `src/`)
  fires them, though no such path exists in this tree.
- **Files read:** all 48 `.luau` files, `default.project.json`, `rojo.toml`,
  `QA_TEST_REPORT.md` §1–§11, `CHANGELOG.md`, `FEATURE_CHECKLIST.md`,
  `docs/map.md`; master prompt skimmed (Parts 1–10, 35 and keyword grep) for
  spec-vs-built gaps only.
- **No game code was modified.** This file is the only write.
