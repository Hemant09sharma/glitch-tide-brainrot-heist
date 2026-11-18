# QA — Workstream C (v1.1): New Systems + Progression + Quests

**Date:** 2026-11-19 · **Workstream:** C (Wave 2) · **Work dir:**
`~/workspace/your_files/glitch-tide-v1.1/` (git HEAD `ad676b7`, Wave 1)

**Verdict in one line:** all assigned systems are implemented server-side and
compile clean, but **nothing here has had a Studio playtest, a live DataStore
round-trip, or a client** — every feature below is "Implemented but not
runtime tested" unless marked Partially / Not implemented. Do not call this
workstream "ready" on the strength of compile + static checks alone.

## 1. Files changed / added

### New files (8) — 3,109 lines

| File | Lines | Contents |
|---|---|---|
| `src/shared/LabDefs.luau` | 240 | Evolve costs by rarity, secret recipes (3), alternate forms (11 pairs), trait upgrade costs, `TRAIT_MAX_LEVEL = 3` |
| `src/shared/ExpeditionDefs.luau` | 165 | 6 expeditions with duration / risk / requirements / reward tables |
| `src/shared/AchievementDefs.luau` | 132 | 24 achievements, 13 titles |
| `src/server/Services/LaboratoryService.luau` | 840 | Evolve / trait upgrade / secret recipes / alternate forms / mutate+fuse pass-throughs |
| `src/server/Services/ExpeditionService.luau` | 646 | Timed expeditions, claim rewards, rare discoveries |
| `src/server/Services/TerritoryService.luau` | 569 | 7 capturable territories, channel/contest/cooldown, flat-tick bonuses |
| `src/server/Services/SecretService.luau` | 518 | 5 secrets, hidden merchant, rune puzzle, secret-sighting hook |
| `src/server/Services/AchievementService.luau` | 449 | Achievement tracking, rewards, titles store |

### Edited files (10) — totals are whole-file line counts after edit

| File | Lines | What changed (and only that) |
|---|---|---|
| `src/server/Services/QuestService.luau` | 810 | 16 → 54 quests; `ReportProgress` funnel; `Requires` story-chain gating; weekly reset; Abyssal/Skyfall zone checks; `SetAchievementService`; stale header comment fixed |
| `src/server/Services/ProgressionService.luau` | 1274 | Level/collection milestones, dimension unlocks, prestige, mastery, challenges, new income-multiplier formula |
| `src/server/Services/DataService.luau` | 448 | 12 new `DEFAULT_DATA` fields + nil-safe `applyDefaults` guards only |
| `src/server/Services/BaseService.luau` | 1500 | Integration fixes 8a/8b/8c only (see §6) |
| `src/server/Services/EventService.luau` | 635 | Quest-progress hook only (1 line in `RunEvent`) |
| `src/server/Services/TideService.luau` | 2139 | Quest-progress hook only (flawless-survival, in the survivor loop) |
| `src/server/Services/BossService.luau` | 1074 | Quest-progress hooks only (top-damage + participation, in the death flow) |
| `src/server/Services/DimensionsService.luau` | 899 | Teleport unlock gate + `TeleportDenied`; dimension/chest/checkpoint progress hooks; `_questService` + `SetQuestService` |
| `src/shared/Mutations.luau` | 409 | 9 new fusion recipes for the Wave-1 characters (19 total) |
| `src/shared/Types.luau` | 305 | `CharacterDef.CompanionAbility?` mirror; `PlayerData` Wave-2 fields; `OwnedBrainrot` optional fields |

**Forbidden files untouched by this workstream:** `CHANGELOG.md`,
`FEATURE_CHECKLIST.md`, `README.md`, `QA_TEST_REPORT.md`, `Config.luau`,
`Remotes.luau`, `GameManager.luau`, `Main.server.luau`, `MapBuilder.luau`,
`Characters.luau`, `CharacterModels.luau`, `Powers.luau`,
`AbilityService.luau`, `EconomyService.luau`, all client controllers, and
`~/workspace/your_files/brainrot-battle-arena/` (verified still
`Config.GameVersion = "1.0.2"`). Verified by grep: the string "Workstream C"
appears in `src/` only in the 18 files above. No git was used for this check
(per the task constraint); it rests on this session's own edit record.

## 2. Part 16 classification — every feature

Status key: **F** = Fully implemented and tested · **I** = Implemented but
not runtime tested · **P** = Partially implemented · **N** = Not implemented.
"No runtime test" means: no Studio playtest, no live DataStore round-trip, no
client exists yet for the new remotes. Compile + static harness (§7) is the
only verification.

### Part 6A — LaboratoryService

| Feature | Status | Notes |
|---|---|---|
| Mutate via `MutationService` API | I | Pass-through (`MutateBrainrot`), validation + costs from `MutationService`; no new mutation logic |
| Fuse via `FusionService` API | I | Pass-through (`FuseBrainrot`), recipe-gated by `FusionService`; refund/restore behaviour inherited |
| Evolve (max-level Brainrot + materials → evolved form) | I | Keeps `CharacterId`, sets `Evolved=true`, `EvolutionId`, `EvolvedTrait` (first valid trait the base lacks), `EvolvedFormName`; mutation upgraded to best compatible (or the secret recipe's fixed bonus mutation); income boost flows through existing `Economy.IncomePerSecond` — no income-math edit |
| Evolve visual transform | I | Temporary model at player position + `CharacterModels.PlayTransformEffect(model, "Evolution")` + positional `SpawnEffect` ring/flash + `EventUpdate` banner |
| Trait upgrades | I | Max 3 levels/trait; level 3 sets `Glitched=true` (×2 income via existing Economy path); levels 1–2 cost XP + gems |
| Secret recipes | I | 3 recipes, each gated by a `SecretService` discovery flag: `recipe_void_heart` (void_vulture, needs `rift_whisper`, bonus Void), `recipe_starfall_quokka` (quantum_quokka, needs `skyfall_summit`, bonus Celestial), `recipe_drowned_king` (puddle_professor, needs `puzzle_room`, bonus Ancient) |
| Alternate forms | I | 11 same-rarity pairs (all verified against the 27-character roster); `SwitchAlternateForm` swaps the displayed form |
| Lab state / remote API | I | `GetLabState`, `EvolveBrainrot` remote (Action envelope), `RequestLab` function, `LabUpdate` broadcast — see `docs/REMOTES_NEEDED_C.md` |

### Part 6B — ExpeditionService

| Feature | Status | Notes |
|---|---|---|
| 6 timed expeditions | I | `exp_market_run` 60s/risk 0.05 → `exp_void_expedition` 1800s/risk 0.40; requirements: min level / rarity / trait (Abyssal: Rare+ Water; Skyfall: Epic+ Cosmic; Void: Legendary+ Glitch) |
| Rewards on claim | I | Coins, gems, Mutation Crystals, Chaos Shards, XP, materials; rare discovery grants a random unowned Brainrot of at least the minimum rarity (via `MutationService.CreateInstance` + `DataService.UnlockCharacter`); mastery XP awarded |
| Risk = reduced/no reward, never Brainrot loss | I | Risk roll only scales rewards down; the instance is always returned |
| Brainrot unavailable while away | P | **Known limitation.** Enforced at the expedition API (`GetExpeditions` lists `OnExpedition` ids; `StartExpedition` refuses an already-away instance) and via the `inst.OnExpedition` flag. `BaseService` / `MutationService` / `FusionService` were NOT edited (out of scope) and do not read the flag — Wave 3 UI must hide on-expedition instances from place/fuse/mutate lists. Risk is reduced rewards only; the Brainrot is never lost |
| One active expedition per player | I | Second start is refused while one is running |

### Part 6C — TerritoryService

| Feature | Status | Notes |
|---|---|---|
| 7 capturable territories | I | Plaza (0,3,0) r14, Market (0,3,-60) r12, Lab (-75,3,55) r12, Arena (75,3,55) r14, Rift (-150,3,-150) r12, Abyssal (-150,3,136) r12, Skyfall (150,48,-140) r12; tiers 1–3 pay 5/10/15 coins/s and 10/20/30 XP/min |
| Capture channel (server-timed, contested) | I | 10s channel, position-polled each tick; contested state (any other alive player in radius) freezes progress; channel breaks if the channeler leaves the radius |
| Fair rules | I | 60s per-player cooldown; no captures during an Active tide; capture breaks if the holder leaves (`PlayerRemoving`) or dies (Humanoid death) |
| Bonuses while held | P | **Deliberate deviation from the spec's "income/XP multiplier".** The bonus is a flat tick: `CoinsPerSec` paid straight into Coins via `DataService.AddCoins` (never `BankedIncome`, so it never hits the bank cap) and `XPPerMinute` via `ProgressionService.AddXP` (else `DataService.AddXP`). A multiplier inside `GetIncomePerSec` would have needed a `BaseService` edit beyond the two-integration scope. The flat tick is smaller and safer than a multiplier at top-tier incomes; if the design wants a true multiplier, that is a follow-up `BaseService` edit |
| Territory state / remote API | I | `GetTerritories`, `GetHeldTerritories`, `CaptureTerritory` event, `RequestTerritories` function, `TerritoryUpdate` broadcast to all players |

### Part 6E — SecretService

| Feature | Status | Notes |
|---|---|---|
| 5 hidden secrets | I | `rift_whisper` (stand in the Forbidden Rift zone), `hidden_merchant` (trade with the tide-spawned merchant), `puzzle_room` (collect 3 runes), `secret_sighting` (be near a tide `SecretSighting`), `skyfall_summit` (reach the Skyfall summit). Conditions re-validated server-side at `DiscoverSecret` call time |
| Secrets never listed | I | No `GetSecrets` / `RequestSecrets` listing anywhere (only comments in the file mention the names, to say they do not exist). Only `DiscoverSecret` (one id), `IsDiscovered` (one id), and the id-less `SecretDiscovered` broadcast. Discovery banners never name the secret |
| Hidden merchant | I | Spawned via `NPCService.SpawnQuestGiver` at (-150,3,-138) when a tide rolls `HiddenMerchant` (120s lifetime). `SpawnQuestGiver` previously had no callers (audit §3 F6) — now it has one |
| Puzzle room hooks | I | 3 rune parts in a workspace-root `SecretRunes` folder — deliberately NOT under `ForbiddenRift` (so `QuestService`'s zone centre is untouched) and NOT under `TideChannel` (whose direct children must stay `TidePoint*` markers only) |
| Rare world events / secret creature appearances | I | Consumes the `TideService.GetSecretEncounter()` hook (`HiddenMerchant` / `SecretSighting`); the 2s position poll checks rift/summit/sighting/merchant conditions |
| Unusual NPC interactions | P | The merchant interaction is a discovery trigger, not a shop: no secret shop inventory exists. A merchant shop (spending event tokens / shards) is a Wave 3+ follow-up |

### Part 7 — Achievements, titles, progression

| Feature | Status | Notes |
|---|---|---|
| 24 achievements | I | 12 firsts (`ach_first_buy` … `ach_first_prestige`) + 12 cumulative (`ach_tides_10/25`, `ach_bosses_5`, `ach_boss_top_3`, `ach_fusions_10`, `ach_expeditions_10`, `ach_secrets_3`, `ach_territories_5`, `ach_collection_10/20/27`, `ach_level_50`). Rewards paid exactly once on unlock; `AchievementUnlocked` broadcast + `EventUpdate` banner |
| Single-funnel progress (no double-counting) | I | `QuestService.RecordEvent` is the ONLY place that forwards to achievements/challenges, via `EVENT_KIND_MAP`. Only `survive_tide` maps to `tide_survived` — variant events (`survive_meteor_tide`, `defeat_boss_colossus`) are quest-only. New services call ONLY `ReportProgress`, never `CheckProgress` directly |
| 13 titles | I | `title_tide_survivor`, `title_tide_legend`, `title_boss_slayer`, `title_master_fuser`, `title_evolutionist`, `title_explorer`, `title_secret_keeper`, `title_territory_lord`, `title_reborn`, `title_prestiged`, `title_collector`, `title_completionist`, `title_legend`. Granted + stored in `data.Titles`; `EquippedTitle` stored server-side |
| Title equip | P | Server-side store only (`AchievementService.SetEquippedTitle`). Equip UI is Wave 3; no remote is fired for it yet (see `REMOTES_NEEDED_C.md` §Not requested) |
| Level milestones + rewards | I | Levels 15/20/30/40/50/75/100, tracked in `data.ProgressionMilestones` (claimed once each); milestone XP feeds back into the `AddXP` level-up loop and terminates (each milestone claims once) |
| Collection milestones | I | 10/15/20/27 distinct Brainrots, same claimed-once mechanism |
| World unlocks | I | Abyssal requires Level 5, Skyfall Level 15; unlocks persist in `data.DimensionUnlocks` across rebirth/prestige; player attribute `DimensionUnlocked_<id>` set on unlock and re-applied on rejoin (attributes don't persist). `DimensionsService.TeleportToDimension` reads the attribute first (fast path), else `ProgressionService.CanAccessDimension`; denied teleports broadcast `TeleportDenied` on the existing `DimensionUpdate` name. **When no `ProgressionService` is linked the gate fails OPEN** (Wave 1 free travel preserved) |
| Prestige (past MaxRebirths = 10) | I | Requires 10 rebirths + Level 25 + 250,000 coins + 15 distinct Brainrots. Sets Rebirths to 0, Prestige +1, keeps collection / dimension unlocks / mastery; +50 gems; grants `title_prestiged`; income +5% per prestige rank (`PRESTIGE_INCOME_PER_RANK = 0.05`), folded into `ProgressionService.GetIncomeMultiplier` (`1 + rebirths*0.10 + prestige*0.05 + masteryBonus`). Triggered via the existing `Rebirth` remote with `{Action="Prestige"}` — no new remote |
| Challenge rewards (8) | I | `ch_tides_10`, `ch_tides_25`, `ch_bosses_5`, `ch_expeditions_10`, `ch_fusions_10`, `ch_evolutions_5`, `ch_secrets_3`, `ch_territories_5`, tracked in `data.Challenges`; `ProgressionService.CheckChallenge` called from the `RecordEvent` funnel; reward XP via `AddXP` cannot cycle back into `CheckChallenge` |
| Rare-character mastery | I | Rare+ Brainrots only (rank ≥ 3); thresholds 100/500/1000 mastery XP → +1% income each, max +3% per Brainrot, +15% total, folded into `GetIncomeMultiplier`. Awarded by expeditions and evolutions via `ProgressionService.AwardMastery` |

### Part 8 — QuestService

| Feature | Status | Notes |
|---|---|---|
| 54 quests (was 16) | I | 38 new. Full list by category in §4 |
| Story chain (5, chained) | I | `q_story_1` buy first → `q_story_2` place → `q_story_3` "The Merchant's Whisper" (discover a secret) → `q_story_4` evolve → `q_story_5` survive 3 tides. New `Requires` field: the prerequisite must be CLAIMED before the next can progress |
| Daily (3) + weekly (3) + reset logic | I | Daily reset via existing `data.QuestDay`; weekly reset added via ISO week (`data.QuestWeek`, `os.date("%Y-W%W")`); existing daily logic extended, not duplicated |
| Exploration / dimension quests | I | `q_visit_abyssal`, `q_visit_skyfall`, `q_chest_3` (open 3 dimension chests), `q_checkpoint_1` (Skyfall checkpoint run) — hooks in `DimensionsService` |
| Collection quests | I | `q_own_10/20/27` (27 = all characters) |
| Mutation / fusion quests | I | `q_mutate_5`, `q_evolve_1/3`, `q_fuse_5`, `q_trait_5` — hooks in `LaboratoryService` |
| Survival quests | I | `q_survive_10`, `q_survive_flawless` (survive a tide without being hit once — `TideService` hook), `q_survive_boss_tide` |
| Boss quests | I | `q_defeat_colossus`, `q_defeat_void`, `q_boss_fights_5` — hooks in `BossService` (defeat + per-boss events + top-damage + participation) |
| Combat / raid / defense quests | I | Pre-existing `q_steal_1`, `q_defend_1`, `q_defeat_5/25`, `q_defend_3` retained; `q_defeat_boss` retained. No new combat quests — combat is D's domain and the melee `Attack` / `StealBrainrot` paths still have no client firers |
| Expedition / territory quests | I | `q_expedition_1/5`, `q_territory_1/5` — hooks in the new services |
| Secret quests | I | `q_secret_1/3` — via `discover_secret` |
| Event quests | I | `q_event_3` — hook in `EventService.RunEvent` (every online player) |
| Boss-without-dying quest | P | No dedicated quest. Covered by `q_survive_flawless` (no damage taken in a tide) + the boss-defeat quests; a "defeat a boss while taking no damage" quest would need a per-boss damage check in `BossService` that does not exist |
| Synergy-formation quest | N | Not implemented. No synergy quest exists — synergy tracking belongs to D's domain (`SynergyUpdate`); there is no server-side synergy event for `QuestService` to consume |
| Complete-a-Brainrot-family quest | P | No per-family quests. Covered by collection milestones/quests (`q_own_10/20/27` + `COLLECTION_MILESTONES`); families are not defined anywhere in the shared defs |
| Named-specific-mutation quest | P | No quest requires one named mutation. Covered by count quests (`q_mutate_5`, `q_trait_5`) |

### Wave-1 integration fixes (§8 of the task)

| Fix | Status | Notes |
|---|---|---|
| (a) BaseService companion-income integration | I | See §6 |
| (b) Rebirth income contradiction (+25% vs +10%) | I | See §6 |
| (c) Banked-income cap 10,000 vs top-tier incomes | I | See §6 |
| (d) Fusion recipes for the 9 new Wave-1 characters | I | 9 new recipes (19 total), all inputs/results verified real — see §5 |
| (e) Types.luau CharacterDef mirror sync | I | `CompanionAbility: {Kind: string, Value: number}?` added, mirroring `Characters.CompanionAbilityDef` |

### Explicitly not in this workstream

| Item | Status | Notes |
|---|---|---|
| Studio playtest / screenshots / sealed recording | N | No Studio here. Grok Build must run the playtest |
| Client UI for any C system | N | Wave 3 owns all UI (lab, expeditions, territories, achievements, titles, prestige button) |
| Trading | N | Intentionally omitted (unsafe), unchanged |
| Offline income | N | Not implemented, unchanged |
| Controller input / keyframed animation | N | Not implemented, unchanged |
| New `LightingService` mood work | N | No new moods in C; `LightingService.SetMood` is only consumed by Wave 1 code |
| Merchant shop inventory | N | See §2 Part 6E — discovery trigger only |

## 3. New systems + APIs

All server-authoritative; every handler validates payload shape, sanitizes
ids (`^[%w%-_]+$`, ≤64 chars), rate-limits at 1/s per player, and wraps
cross-service calls in `pcall` so a missing sibling degrades instead of
erroring. New services self-wire by lazy sibling `require` (they cannot rely
on `GameManager.wireCrossLinks`, which this workstream may not edit) — see §8.

- **LaboratoryService** — `Init(dataService?, mutationService?,
  fusionService?)`, `GetLabState(player)`, `EvolveBrainrot(player,
  instanceId)`, `UpgradeTrait(player, instanceId, traitId)`,
  `DiscoverRecipe(player, recipeId)`, `SwitchAlternateForm(player,
  instanceId)`, `MutateBrainrot` / `FuseBrainrot` pass-throughs;
  `SetQuestService` / `SetAchievementService` / `SetProgressionService` /
  `SetSecretService` / `SetMutationService` / `SetFusionService` setters.
- **ExpeditionService** — `Init(dataService?)`, `GetExpeditions(player)`,
  `StartExpedition(player, instanceId, expeditionId)`,
  `ClaimExpedition(player, expeditionId)`.
- **TerritoryService** — `Init(dataService?, map?)`, `GetTerritories()`,
  `GetHeldTerritories(player)`, `CaptureTerritory(player, territoryId)`;
  1s bonus tick while any territory is held.
- **SecretService** — `Init(dataService?, npcService?)`,
  `DiscoverSecret(player, secretId)`, `IsDiscovered(player, secretId)`,
  `GetSecretEncounter()` passthrough to `TideService`.
- **AchievementService** — `Init(dataService?, questService?)`,
  `GetAchievements(player)`, `CheckProgress(player, kind, amount)`,
  `SetProgress(player, kind, id, amount)` (absolute; progress only moves
  up, so rebirth level resets never un-earn), `IsUnlocked(player, id)`,
  `GetTitles(player)`, `SetEquippedTitle(player, titleId)`.

Shared defs (tunables live here, NOT in `Config`):
`LabDefs` (evolve costs Common 500c/10 crystals → Impossible 250,000c/400
crystals; XP/gems rewards per rarity), `ExpeditionDefs` (6 expeditions),
`AchievementDefs` (24 achievements, 13 titles).

## 4. Quest chains added (38 new quests; 54 total)

- **Story (5, chained via `Requires`):** `q_story_1`–`q_story_5` (§2).
- **Daily (3):** `q_daily_earn_10k`, `q_daily_tides_2`, `q_daily_expedition`.
- **Weekly (3):** `q_weekly_earn_50k`, `q_weekly_tides_10`,
  `q_weekly_bosses_3`.
- **Exploration (2):** `q_visit_abyssal`, `q_visit_skyfall`.
- **Secret (2):** `q_secret_1`, `q_secret_3`.
- **Collection (3):** `q_own_10`, `q_own_20`, `q_own_27`.
- **Mutation (5):** `q_mutate_5`, `q_evolve_1`, `q_evolve_3`, `q_fuse_5`,
  `q_trait_5`.
- **Survival (3):** `q_survive_10`, `q_survive_flawless`,
  `q_survive_boss_tide`.
- **Boss (3):** `q_defeat_colossus`, `q_defeat_void`, `q_boss_fights_5`.
- **Combat (1):** `q_defeat_25`.
- **Raid/defense (1):** `q_defend_3`.
- **Expedition (2):** `q_expedition_1`, `q_expedition_5`.
- **Territory (2):** `q_territory_1`, `q_territory_5`.
- **Dimension (2):** `q_chest_3`, `q_checkpoint_1`.
- **Event (1):** `q_event_3`.
- **Retained (16):** `q_buy_first`, `q_place_first`, `q_earn_1000`,
  `q_survive_tide`, `q_earn_5000`, `q_own_5`, `q_discover_epic`,
  `q_visit_rift`, `q_visit_lab`, `q_steal_1`, `q_defend_1`, `q_mutate_1`,
  `q_fuse_1`, `q_defeat_5`, `q_defeat_boss`, `q_survive_meteor`.

All quests pay real rewards (coins/gems/XP/event tokens) on claim through the
existing `ClaimQuest` path. New progress funnel:
`QuestService:ReportProgress(player, kind, id, amount)` maps kind/id → quest
events via `REPORT_PROGRESS_MAP` and calls `RecordEvent` only; `RecordEvent`
is the single funnel that also forwards to achievements/challenges exactly
once (`EVENT_KIND_MAP`). Hook call sites (verified by grep, §7):
`TideService` survivor loop (`tide_flawless`), `BossService` death flow
(`boss_top_damage`, `boss_participated`), `DimensionsService` teleport/chest/
checkpoint (`dimension`), `EventService.RunEvent` (`event`/`participate`),
plus the five new services.

## 5. Achievements, titles, prestige

- **24 achievements** (§2 Part 7): 12 firsts + 12 cumulative; rewards paid
  once on unlock; `AchievementUnlocked` broadcast.
- **13 titles** (§2 Part 7); stored in `data.Titles`, equipped title in
  `data.EquippedTitle` (server-side only; equip UI is Wave 3).
- **Prestige:** after 10 rebirths + Level 25 + 250,000 coins + 15 distinct
  Brainrots → Rebirths reset to 0, Prestige +1, collection / dimension
  unlocks / mastery kept, +50 gems, `title_prestiged`, +5% income per
  prestige rank. Via existing `Rebirth` remote, `{Action="Prestige"}`.
- **Mastery:** Rare+ only; 100/500/1000 XP → +1% income each (max +3% per
  Brainrot, +15% total).
- **Challenges (8):** `ch_tides_10`, `ch_tides_25`, `ch_bosses_5`,
  `ch_expeditions_10`, `ch_fusions_10`, `ch_evolutions_5`, `ch_secrets_3`,
  `ch_territories_5`.
- **Milestones:** levels 15/20/30/40/50/75/100; collection 10/15/20/27.
- **Fusion recipes (19 total):** 10 pre-existing + 9 new for the Wave-1
  characters — ladder: wobble_waffleton+phantom_pancake → prism_penguin;
  turbo_turnip+prism_penguin → neon_narwhal;
  bloop_bloomington+neon_narwhal → reactor_raccoon;
  crumb_comet+reactor_raccoon → gravity_goblin;
  noodle_nebula+gravity_goblin → thunder_tortoise;
  toast_ghost+thunder_tortoise → quantum_quokka;
  disco_dumpling+quantum_quokka → solar_sloth;
  captain_picklebyte+solar_sloth → void_vulture;
  void_vulture+wobble_king → wobble_king (capstone, same-result
  self-fusion). All inputs/results verified against the 27-character roster
  (harness §7); fails-closed — only recipes whose inputs exist.

## 6. The three integration fixes (before / after)

**(a) BaseService companion-income integration.**
Before: no companion hook — `GetIncomePerSec` ignored companions entirely,
so companion `IncomeBonus` (up to +25% from `CompanionService`) did nothing.
After: new `BaseService.SetEconomyService` setter + lazy sibling `require`
of `EconomyService` (needed because `GameManager.wireCrossLinks` shares
`SetEconomyService` but only wires `_optional` services, not core
`BaseService`); one line in `GetIncomePerSec` multiplies by
`EconomyService.GetCompanionIncomeMultiplier(player)` (1 when unwired, max
1.25 when wired). No existing income math changed.

**(b) Rebirth income contradiction.**
Before: `BaseService` fell back to `1 + rebirths * 0.25` (+25%/rebirth) with
a comment falsely calling Config's 0.10 "stale", while
`ProgressionService.GetIncomeMultiplier` used +10% — live behaviour was
+10% when `ProgressionService` was wired, +25% when not (audit §3 F2).
After: Config is the single source of truth. The fallback now reads
`Config.RebirthRequirements.IncomeBonusPerRebirth` with the same +10% step,
plus a +5%/prestige-rank mirror (`ProgressionService.PRESTIGE_INCOME_PER_RANK
= 0.05`). Behaviour is +10%/rebirth on both paths; the stale comment is
corrected. `ProgressionService.GetIncomeMultiplier` is now
`1 + rebirths*0.10 + prestige*0.05 + masteryBonus`.

**(c) Banked-income cap.**
Before: flat `BANKED_CAP = 10000`. Top-tier incomes (Void Vulture 11,000/s,
Wobble King 18,000/s) exceeded the entire cap in under a second — "collect
constantly or lose everything" (audit §3 F11).
After: `BANKED_CAP_BASE = 100000` + `bankedCapFor(player) = 100000 +
Level*5000 + Rebirths*10000 + Prestige*25000`; the bank tick uses it.
Still a real cap, not infinite: a level-1 player caps at 105,000; a
level-25, 10-rebirth player at 325,000. Territory bonuses bypass the cap
entirely (paid straight to Coins, §2 Part 6C).

## 7. Verification

- **Luau compile (`luau-compile`, Luau 0.747): PASS 18/18** — all 8 new
  files + 10 edited files, re-run after the fixes below.
- **Luau strict analysis (`luau-analyze`, `--mode strict`): triaged, not
  clean.** Output is the known noise class from prior QA (missing Roblox
  definitions, `unknown` cascades from untyped `require`d modules — the
  same class already present in pre-existing `BaseService` / `QuestService`
  / `ProgressionService` code) PLUS one real bug, fixed:
  `TerritoryService` declared `resolveQuestService` AFTER `reportProgress`
  used it, so the call resolved to a nil global at runtime when
  `QuestService` was unwired — fixed by moving the resolver above
  `reportProgress` (same ordering as `LaboratoryService` /
  `ExpeditionService`, verified). Two strict-mode sealed-table-literal
  diagnostics in new code (`LabDefs` `GetLabState` entry,
  `TerritoryService.GetTerritories` entry) were fixed with `{[string]: any}`
  annotations. Remaining diagnostics are the accepted noise class:
  `unknown` keys on tables returned by untyped requires
  (`Characters.GetById`, `LabDefs`/`AchievementDefs` via
  `WaitForChild`), `string.format` varargs on `unknown` values, and
  `Vector3` math on `unknown` positions in the pre-existing zone-poll
  shape. No file was rewritten to chase analyze noise; only genuine
  defects were fixed. **Re-run `luau-analyze` after any edit that touches
  these files and re-triage; do not treat a noisy analyze as a compile
  failure.**
- **Static verification harness (Python, read-only, `/tmp/verify_c.py`,
  not kept in the tree): ALL CHECKS PASSED** — 60+ assertions: all 7
  quest-progress hook call sites present with exact payloads; quest count
  = 54; achievement count = 24; titles = 13; expeditions = 6; all 19
  fusion recipes have real inputs/results (against `Characters.luau`);
  all 12 new `DataService` fields present with nil-safe defaults;
  companion hook / rebirth fix / banked-cap fix present in `BaseService`;
  all 13 new remote names absent from `Remotes.luau` and each fired in
  exactly one file; no `EconomyService.AddCoins`/`AddGems` calls in owned
  files; no `Magma`/`Spectral` used as a mutation or recipe in owned files
  (the only mentions are pre-existing comments in `BaseService` documenting
  the old mutation-table drift); "Workstream C" marker only
  in the 18 owned/allowed files; prestige/mastery/challenges/milestones
  present; 5 secret ids present; merchant spawn via `SpawnQuestGiver`;
  3 secret recipes reference real characters + real secrets.
- **Reward API compliance (audit §4f):** coins move via
  `DataService.AddCoins`; gems / Chaos Shards / Mutation Crystals / Event
  Tokens via direct field writes guarded with `tonumber() or 0`; XP via
  `ProgressionService.AddXP` when linked, else `DataService.AddXP`;
  balance push via `EconomyService.NotifyBalance`. No
  `EconomyService.AddCoins`/`AddGems` exists or is called.
- **NOT verified:** Studio playtest, live DataStore round-trip, client
  behaviour for any new remote, or any end-to-end game flow. The harness
  is static only.

## 8. Registration (integrator — GameManager / Main.server, NOT done here)

`GameManager` / `Main.server` were not edited (task constraint). The
integrator must add the five new services to `OPTIONAL_SERVICES` and add a
`loadOptional` branch per name, in this order (after `ProgressionService`):

| Service | Init signature | `loadOptional` branch |
|---|---|---|
| `LaboratoryService` | `Init(dataService?, mutationService?, fusionService?)` | `LaboratoryService.Init(_dataService, _mutationService, _fusionService)` — pass the already-loaded `MutationService` / `FusionService` if available, else `nil` (it lazy-requires them) |
| `ExpeditionService` | `Init(dataService?)` | `ExpeditionService.Init(_dataService)` |
| `TerritoryService` | `Init(dataService?, map?)` | `TerritoryService.Init(_dataService, workspace)` — `map` is optional; when nil the service uses its built-in zone table |
| `SecretService` | `Init(dataService?, npcService?)` | `SecretService.Init(_dataService, _npcService)` |
| `AchievementService` | `Init(dataService?, questService?)` | `AchievementService.Init(_dataService, _questService)` |

Each service's `Init` also self-wires by lazy sibling `require` and calls
the relevant setters itself (`AchievementService.Init` calls
`questService.SetAchievementService(self)` and self-wires to
`ProgressionService.SetAchievementService`), so the game works even if the
integrator only adds the `OPTIONAL_SERVICES` names and the `Init` calls —
but the setters below are NOT covered by `GameManager.wireCrossLinks` and
should be wired explicitly where the integrator can: `QuestService` →
`SetAchievementService`; `ProgressionService` → `SetAchievementService`;
`LaboratoryService` → `SetQuestService` / `SetSecretService` /
`SetMutationService` / `SetFusionService`; `ExpeditionService` →
`SetQuestService`; `TerritoryService` → `SetQuestService`;
`DimensionsService` → `SetQuestService` (new setter added by C);
`SecretService` → `SetQuestService` (lazy internal require covers it).
New remote names to add to `Remotes.luau`: see
`docs/REMOTES_NEEDED_C.md` (13 names).

## 9. Deliberately left undone / known limitations

1. No Studio playtest, no screenshots, no recording, no live DataStore
   round-trip (no Studio here).
2. No client UI for any C system (Wave 3).
3. Expedition "unavailable while away" is enforced at the expedition API
   only; `BaseService` / `MutationService` / `FusionService` do not read
   the `OnExpedition` flag — Wave 3 UI must hide on-expedition instances.
4. Territory bonus is a flat tick, not a multiplier (§2 Part 6C).
5. No merchant shop inventory; the hidden merchant is a discovery trigger
   only.
6. No synergy quest, no per-family quests, no named-mutation quest, no
   dedicated boss-without-dying quest (§2 Part 8).
7. Title equip is server-side storage only; no equip remote yet.
8. `DimensionsService` unlock gate fails OPEN when no `ProgressionService`
   is linked (Wave 1 free travel preserved by design).
9. `SecretService`'s 2s position poll is an extra per-player poll on top
   of `QuestService`'s 5s zone poll; both are cheap distance checks, but a
   future pass could merge them.
10. The `luau-analyze` noise class (§7) is unchanged in kind from Wave 1 —
    it will keep appearing until the shared modules gain type annotations.
