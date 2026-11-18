# QA — Workstream B (v1.1): BRAINROTS + POWERS + COMPANIONS

**Workstream:** B — `src/shared/Characters.luau`, `CharacterModels.luau`,
`Powers.luau`, `Synergies.luau`, `src/server/Services/AbilityService.luau`,
`EconomyService.luau` (income hook only), `src/client/Controllers/AnimationController.luau`;
new `src/shared/Companions.luau`, `src/server/Services/CompanionService.luau`.
**Date:** 2026-11-19. **Method:** static verification only — `luau-compile`
(Luau 0.747, `/tmp/luau-bin/luau-compile`), `luau-analyze` (AnimationController),
and a Python static harness (`/tmp/verify_b.py`, 69 checks). **No Studio
playtest was run; no DataStore round-trip; nothing here claims live behaviour.**

**Workspace caveat (read first):** `~/workspace/your_files/glitch-tide-v1.1/`
and `~/workspace/your_files/brainrot-battle-arena/` are symlinks to the SAME
directory (`~/workspace/goals/glitch-tide-brainrot-heist-the-memeverse/files/brainrot-battle-arena`,
same inode). There is no separate v1.1 copy on disk — this work landed in the
shared tree. The v1.0.2 original survives only in the v1.0.2 ZIPs. The task's
"do not touch brainrot-battle-arena" instruction cannot be satisfied
independently of editing glitch-tide-v1.1 while the two paths resolve to one
directory; the parent orchestrator should re-point one of the symlinks (or
materialise a real copy) before the next workstream. No forbidden *file* was
edited: `CHANGELOG.md`, `FEATURE_CHECKLIST.md`, `README.md`,
`QA_TEST_REPORT.md`, `Config.luau`, `Remotes.luau`, `GameManager.luau`,
`Main.server.luau`, `DataService.luau`, `TideService.luau`,
`MapBuilder.luau` and every other workstream's file were not touched by B
(`Config.luau`'s 21:32 mtime is another parallel workstream's edit, not B's).

**Audit read:** `docs/AUDIT_V1_1.md` was read before finishing. Its
corrections were applied: (1) each new playable power has BOTH a def in
`Powers.PlayablePowers` AND an effect branch in `AbilityService` (verified
by harness check `all-playable-have-branches`); (2) the companion income
hook uses the real path — `EconomyService` has no `AddCoins`/`AddGems` API,
coins move via `DataService.AddCoins`, income is computed only in
`BaseService.GetIncomePerSec`, so the hook is a multiplier getter and the
one-line `BaseService` integration is documented as pending (§ Integration
pending); (3) service registration is documented as
`OPTIONAL_SERVICES` entry + a per-name `loadOptional` branch (audit §4c),
GameManager not edited; (4) the dead `Attack` / `StealBrainrot` client paths
(audit F1) are noted in § Cross-workstream findings for the UI/multiplayer
workstream — B does not assume any combat firer exists beyond the verified
`AbilityController → UseAbility` path.

## 1. Feature classification (Part 16)

### 1.1 Roster: 18 → 27 Brainrots
**Fully implemented and tested** (static). 9 new original characters, one
per tier from Common to Secret (no new Impossible — the Wobble King stays
the sole Impossible):

| Id | Name | Rarity | Cost | Income/s | Primary (Q) | CompanionAbility |
|---|---|---|---|---|---|---|
| `phantom_pancake` | Phantom Pancake | Common | 250 | 7 | `phantom_flip` | TideProtection 0.05 |
| `prism_penguin` | Prism Penguin | Uncommon | 550 | 12 | `prism_shatter` | RareDetection 0.05 |
| `neon_narwhal` | Neon Narwhal | Rare | 2000 | 50 | `neon_sonar` | IncomeBonus 0.05 |
| `reactor_raccoon` | Reactor Raccoon | Epic | 7000 | 130 | `reactor_overload` | MutationBonus 0.10 |
| `gravity_goblin` | Gravity Goblin | Legendary | 18000 | 300 | `gravity_well` | CarrySpeed 0.10 |
| `thunder_tortoise` | Thunder Tortoise | Mythic | 50000 | 900 | `thunder_shell` | TideProtection 0.15 |
| `quantum_quokka` | Quantum Quokka | Divine | 150000 | 2800 | `quantum_leap` | RareDetection 0.15 |
| `solar_sloth` | Solar Sloth | Celestial | 300000 | 5500 | `solar_flare` | IncomeBonus 0.15 |
| `void_vulture` | Void Vulture | Secret | 600000 | 11000 | `void_screech` | RaidDetection 0.20 |

Every entry is complete (Id, Name, DisplayName, Rarity, Cost,
IncomePerSec inside the documented rarity band, Description, Health /
Speed / Damage, AbilityId, DefenseTrait, Traits from the 8 valid values,
Color / AccentColor, Scale, MutationCompatibility from the 12 real
mutation Ids, Personality, UnlockCondition, BuildSpec with a NEW BodyShape).
6 existing characters also gained a CompanionAbility (`wobble_waffleton`
IncomeBonus 0.05, `turbo_turnip` CarrySpeed 0.05, `moon_mochi`
TideProtection 0.10, `zap_zucchini` MutationBonus 0.05, `glitchy_goose`
RareDetection 0.10, `caramel_crab` RaidDetection 0.15). Suggested concepts
Chrono Croissant, Cyber Chameleon and Meteor Mantis were NOT used — 9
additions already cover every tier Common→Secret; the three are free for
a later workstream. No copied existing Brainrot characters, no copyrighted
Italian names, no `tung_tung`.
**Harness:** roster 27, unique Ids, all 27 AbilityIds resolve in Powers,
all incomes in-band, all Traits / MutationCompatibility values valid,
all 27 BodyShapes have a builder.

### 1.2 Procedural models (CharacterModels.luau)
**Implemented but not runtime tested.** 9 new builder branches
(Pancake, PrismPenguin, Narwhal, Raccoon, Goblin, Tortoise, Quokka,
Sloth, Vulture), each with a distinct silhouette, face, proportions,
accessories and materials; Parts only, zero external asset IDs.
All 27 models (18 existing + 9 new) now get rarity presentation in
`Build()`: a rarity-coloured neon trim ring sized by tier, floating
rarity gems for Epic+ (1–5 by tier), a PointLight for Divine+, and a
second wider ring for Secret / Impossible. 4 existing builders got a
small visible accessory upgrade (Waffle syrup drip, Turnip racer brows
+ sweat drop, Dumpling second disco-light ring, Goose glitch shards).
`CharacterModels.GetRarityPresentation(rarity)` exposes the table.
Transform hooks: `PlayTransformEffect(model, kind)` (particle burst in
the accent colour + 0.4s flash + `TransformKind` attribute) and
`ApplyFusionTransform(model)` for MutationService / FusionService to
call. **Not runtime tested:** no Studio render — ring/gem/light
placement is by the same coordinates the existing builders use, but
visual overlap on the smallest models (Pancake, Goblin) is unverified
in-game.

### 1.3 Character animation (AnimationController.luau)
**Implemented but not runtime tested.** Full set now exists:
idle / walk / run (walk-rate scales with Speed; waddle / heavy / zoom
walk styles) / jump / land (airborne-transition squash + `PlayLand`) /
dance (`PlayDance`, 2s) / celebrate (`PlayCelebrate`, 2.5s + slow spin) /
attack (existing sweep, plus morph lunge) / damage (`PlayDamage`, 0.35s
flinch / jitter) / rare-discovery (`PlayRareDiscovery`, 3s celebrate +
flash via EffectsController when present). Per-character profiles are
derived from the def (`deriveProfile`: Personality keywords → IdleStyle
wobble / float / bounce / glitch / calm / menace and DanceStyle spin /
bounce / sway / glitch; Speed / Scale tune bob and walk rates).
Morphed models (no Motor6D joints) are now actually animated: `StepMorph`
drives whole-model bob / roll / yaw as root-CFrame DELTAS only (tracked
`lastBobY/lastRoll/lastYaw`), so the animation cannot fight walking,
teleporting or the camera snap. Mutation / fusion transforms:
`PlayMutationTransform` / `PlayFusionTransform`, plus automatic pickup
of the `TransformKind` attribute stamped by
`CharacterModels.PlayTransformEffect`. All pre-existing public API is
preserved (`PlayAttack`, `PlayJump`, `PlaySpawnSpin`, `SetCarrying`,
`IsCarrying`, `Stop`, `Step`, `Init`). **Not runtime tested:** no Studio
session; the delta technique is standard but the per-frame CFrame writes
have not been observed against the camera watchdog or the carry pose.

### 1.4 Rare presentation
**Implemented but not runtime tested.** `CompanionService.AnnounceRareAcquisition(player, characterId, position?)`
(Epic+ only): positional `SpawnEffect` fires — `ring` (radius scaled by
tier: 8→26 studs) + `flash` in the rarity colour + `poof`, and for
Secret / Impossible a second larger ring + `glitchAura` 0.35s later —
plus an `EventUpdate` banner (`{EventId="RareAcquisition", Name,
Phase="Started", Duration=6–15s}`) that HUDController already shows via
`ShowEventBanner`, with a `SoundHook` payload field (`"rare"` / `"secret"`)
for the sound workstream. Secret / Impossible: bigger ring, 12s / 15s
banner. Rarity presentation on the model itself is §1.2. Market lighting
hooks: NOT implemented as a new system — the tide storm lighting and
`EffectsController` glitch aura already exist; B fires the existing
`glitchAura` effect type for top tiers rather than inventing a lighting
API it does not own. **Not runtime tested:** banner text / ring sizes
unverified in-game; `ConveyorService.announceRare` already announces
Epic+ conveyor spawns, so a rare acquisition announced twice (conveyor
+ acquisition) is possible — the two messages differ in wording.

### 1.5 Powers — 12 existing playable powers improved
**Implemented but not runtime tested.** Every successful `UsePower` now
also fires positional `SpawnEffect` FX in the power's colour — `ring`
(radius = the power's Radius, min 5) + `flash` for damage powers,
`ring` + `poof` for utility powers — the positional form
`EffectsController.onSpawnEffect` actually handles (see § Cross-workstream
findings for why the pre-existing table payload is left untouched).
Responsiveness: no cooldown or validation change for the 12 (their
shared cooldowns are untouched); the FX fire is the improvement, plus
mastery cooldown reduction (§1.6) applies to them too.

### 1.6 Powers — 5 new playable powers
**Implemented but not runtime tested.** All five have a def in
`Powers.PlayablePowers` AND a fully-wired effect branch in
`AbilityService.applyEffect`, server-validated through the existing
`UsePower` path (unlocked + equipped + cooldown + alive + 0.25s rate
limit). Cooldowns ≥ 10s everywhere:

| Power | Cooldown | Duration | Cost (coins) | Effect (server-side) |
|---|---|---|---|---|
| `time_rewind` | 20s | 3s | 5000 | Restores health + position from the ~3s-old snapshot (0.5s snapshot ring buffer, 7 entries, started in `Init`); cannot rewind death; fails cleanly with no snapshot |
| `meteor_shower` | 18s | 3s | 4500 | 5 pastry meteors over 3s at random points in the 10-stud radius; each deals 1/5 of the 45 damage to enemies within 3 studs + knockback |
| `void_dash` | 10s | 0.5s | 3500 | Blink up to 14 studs (ground raycast required, else the use fails and no cooldown is charged); 0.7 transparency while dashing; 15 damage to enemies within 3 studs of the path |
| `gravity_crush` | 22s | 2s | 5500 | 40 damage + drag toward the player + WalkSpeed 0 for 2s to every enemy in 7 studs |
| `dimensional_prison` | 25s | 5s | 6000 | Cages the nearest enemy within 12 studs: WalkSpeed 0 + JumpPower 0 for 5s inside a 4-wall neon cage (Debris-cleaned); 10 damage on capture; fails cleanly with no target in range |

All 17 playable powers verified to have a branch (harness
`all-playable-have-branches`). All cooldowns in `Powers.luau` are ≥ 3s
(minimum in the file is 4s). Canonical keybinds untouched (Q primary /
F Slam / R Heal / E Interact / G Drop / 1/2/3 loadout).

### 1.7 New character primaries (9)
**Implemented but not runtime tested.** Each new character's Q primary
has a def in `Powers.LIST` (Key Q, cooldown 6–9s). No `CombatService`
edit was needed or made: `CombatService.onUseAbility` is generic — it
applies the def's damage in the def's radius plus secondary effects
from the `Effect` string (`KNOCKBACK_EFFECTS` / `SLOW_EFFECTS` /
`STUN_EFFECTS` tables + the `SpeedBoost` / `GlitchTeleport` specials).
All 9 new primaries use Effect strings already in those tables
(Bounce, RingBlast, Splash, Explosion, Shock, GlitchTeleport, Dazzle,
Haunt) — verified by harness against the live tables, all 27 primaries
recognised. They therefore get damage + knockback / slow / stun through
the same path as the existing primaries (e.g. `noodle_whip` / `zap_bolt`
have no special branch either). No primary has bespoke behaviour beyond
the generic path — that matches the existing design, and is stated here
so it is not mistaken for per-primary custom code.

### 1.8 Power mastery / upgrade paths
**Implemented but not runtime tested.** `Powers` exposes
`MASTERY_MAX_LEVEL = 5`, `MASTERY_XP_PER_LEVEL = {100, 250, 500, 1000, 2000}`,
`GetMasteryLevel(xp)`, `GetMasteryDamageMultiplier(level)` (+5%/level),
`GetMasteryCooldownMultiplier(level)` (−2%/level). `AbilityService`
awards +10 XP per successful use, mirrors XP into
`data.PowerMastery` (a lazily-added save field, same pattern as
`AbilityLoadout`/`UnlockedPowers` — survives `DataService` saves without
editing DataService), applies +damage and −cooldown in `UsePower`, and
floors every effective cooldown at 3s (`MIN_COOLDOWN_SECONDS`).
Public API: `GetMasteryXP`, `GetMasteryLevel`,
`GetMasteryStateForSave(player)` / `LoadMasteryState(player, data)`.
No client UI shows mastery yet (AbilityController is another workstream's
file) — levels affect combat silently until a UI reads the API.

### 1.9 Companion abilities (Part 6D)
**Implemented but not runtime tested** (server logic complete; two of
the six bonuses need a one-line read in another workstream's file —
see § Integration pending). New shared `Companions.luau` (kind table,
per-kind total caps, pure `ComputeBonuses(ownedIds)`) + new server
`CompanionService.luau` (`Init(dataService?, economyService?)`).
A companion is any OWNED Brainrot with a `CompanionAbility` field
(15 characters carry one: the 9 new + 6 existing). Bonuses re-derive
from live owned data on every call — no stale cache. Persistence is
in-memory + `GetStateForSave(player)` / `LoadState(player, data)`
(snapshot only; DataService not edited, no new DataStore key).

**Balance table** (no single companion above 0.20 for any bonus;
totals capped — stacking can reach the cap, never exceed it):

| Kind | What it does | Per-companion max | Total cap | How it is applied |
|---|---|---|---|---|
| IncomeBonus | +% base income | 0.15 | 0.25 | `EconomyService.GetCompanionIncomeMultiplier` → BaseService (pending, § Integration) |
| TideProtection | Chance per tide hit to take no tide damage | 0.15 | 0.20 | `CompanionService.IsTideProtected(player)` — TideService calls per damage tick |
| RareDetection | Boosts Epic+ rarity weight on conveyor rolls | 0.15 | 0.20 | `GetRareWeightMultiplier(player, rarity)` — 1 + bonus for rank ≥ 4, 1 otherwise; ConveyorService can multiply its effective weights |
| CarrySpeed | Adds to carry speed multiplier (base 0.6) | 0.10 | 0.15 | `GetCarrySpeedMultiplier(player)` — 0.6 + bonus, capped 0.75; CarryService can read it instead of flat Config value |
| RaidDetection | Extra raid-warning lead time | 0.20 | 0.25 | `GetRaidWarningSeconds(player)` — bonus × 30s, max 7.5s; RaidService can add to steal-alert lead time |
| MutationBonus | +% to mutation income multipliers | 0.10 | 0.15 | `GetMutationIncomeBonus(player)` — MutationService can add to `Mutations.GetMultiplier` |

**Worked example:** owning all 15 companion characters gives raw
IncomeBonus 0.05+0.05+0.15 = 0.25 (capped at 0.25), TideProtection
0.10+0.05+0.15 = 0.30 → capped 0.20, RareDetection 0.10+0.05+0.15 = 0.30
→ capped 0.20, CarrySpeed 0.05+0.10 = 0.15 (at cap), RaidDetection
0.15+0.20 = 0.35 → capped 0.25, MutationBonus 0.05+0.10 = 0.15 (at cap).

### 1.10 Synergies
**Fully implemented and tested** (static). 3 new synergies the expanded
roster can trigger: Storm Front (3× Electric, +20%), Void Court
(Glitch + Ancient, +25%), Rainbow Reef (Water + Cosmic, +20%).
13 synergies total; all use only the 8 valid traits.

## 2. Integration pending (NOT B's files — do not mistake for done)

1. **Companion income → banked income.** `EconomyService.GetCompanionIncomeMultiplier(player)`
   exists and is verified, but `BaseService.GetIncomePerSec` does not call
   it — `BaseService` has no `SetEconomyService` setter, so the hook cannot
   reach its income math without a BaseService edit. Required (BaseService
   workstream): add `BaseService.SetCompanionService(svc)` (or an
   economy-service setter) and one line in `GetIncomePerSec` beside the
   synergy/event lines: `total *= EconomyService.GetCompanionIncomeMultiplier(player)`
   — via `DataService.AddCoins` is NOT the path (income banks through the
   1s tick; audit §4f). Until then the companion IncomeBonus is computed
   and exposed but NOT applied to banked income.
2. **CompanionService registration.** GameManager NOT edited. Required
   (GameManager workstream): add `"CompanionService"` to
   `OPTIONAL_SERVICES` (after `"AbilityService"`) AND a per-name branch in
   `loadOptional` (audit §4c): `service.Init(_dataService, _economyService)`.
   Note: the generic fallback branch would also pass the right first two
   arguments, but the explicit branch is the documented pattern — do not
   rely on the fallback + no-arg retry. `CompanionService.Init` also calls
   `EconomyService.SetCompanionService(self)` when the economy service
   exposes it, so no `wireCrossLinks` entry is needed.
3. **Companion hooks in other services (all documented, none edited).**
   TideService: call `CompanionService.IsTideProtected(player)` per tide
   damage tick. ConveyorService: multiply effective rarity weights by
   `CompanionService.GetRareWeightMultiplier(player, rarity)` when rolling
   for a player. CarryService: use `GetCarrySpeedMultiplier(player)` in
   place of flat `Config.CarrySpeedMultiplier`. RaidService: add
   `GetRaidWarningSeconds(player)` to steal-alert lead time.
   MutationService: add `GetMutationIncomeBonus(player)` to mutation
   income. Until those calls land, TideProtection / RareDetection /
   CarrySpeed / RaidDetection / MutationBonus are computed and exposed
   but not consumed — only IncomeBonus has a consumer path at all (§1
   above), and it is also pending.
4. **Mastery UI.** No client surface shows mastery XP/levels yet.
   AbilityController (another workstream) can read
   `AbilityService.GetMasteryLevel` via a `PowerUpdate` payload addition
   or a new RemoteFunction — B fires nothing new for it.
5. **Rare-acquisition trigger.** `AnnounceRareAcquisition` is callable by
   any service that grants a character (EconomyService.BuyCharacter /
   ConveyorService.BuyItem are the natural callers — both other files).
   Nothing calls it today, so no rare-acquisition banner fires yet; the
   conveyor's own `announceRare` still covers conveyor spawns.

## 3. Verification executed

| # | Check | Tool / result |
|---|---|---|
| V1 | luau-compile, all 9 B files | PASS 9/9 (Luau 0.747) |
| V2 | luau-compile, whole `src/` tree (51 files incl. other workstreams' new files) | PASS 51/51, 0 failures |
| V3 | luau-analyze, AnimationController | PASS — zero non-noise diagnostics (noise = missing Roblox globals only) |
| V4 | Python static harness `/tmp/verify_b.py` (69 checks) | PASS 69/69 after one harness-bug fix (the first run's `primary-effects-recognised` failure was the harness splitting on the type annotation's `}`; re-parsed against the live tables: all 27 primaries recognised) |
| V5 | Roster / bands / AbilityIds / Traits / Mutations / BodyShapes / companion caps / cooldowns ≥ 3s / playable branches / no `rbxassetid` / no `tung_tung` | PASS (inside V4) |
| V6 | Forbidden files untouched | PASS — CHANGELOG / FEATURE_CHECKLIST / README / QA_TEST_REPORT / Config / Remotes / GameManager / Main.server / DataService / TideService / MapBuilder mtimes predate B's session (Config.luau's 21:32 mtime is another parallel workstream's edit) |
| V7 | v1.0.2 fixes preserved | PASS by inspection — B edited no file that carries a v1.0.2 fix except by additive changes inside its own files; keybinds, camera, fusion, rebirth and remote-contract code untouched |

**NOT executed (no Studio in this workspace):** any playtest, screenshot,
live DataStore round-trip, multi-client check, performance measurement,
or observation of the new models / animations / powers / banners in-game.
Grok Build must run these before calling any of §1 "implemented" items
proven.

## 4. Cross-workstream findings (for the parent / other workstreams)

- **Audit F1 (confirmed, not B's to fix):** `Attack` (melee) and
  `StealBrainrot` server handlers have NO client `FireServer` anywhere —
  melee combat and stealing are dead paths. B's new primaries do NOT
  depend on `Attack` (they fire via `UseAbility`, verified wired), but
  any claim that the new characters are "combat-ready" in melee is false
  until the UI/multiplayer workstream adds an Attack firer.
- **`SpawnEffect` payload mismatch (pre-existing, affects B's FX):**
  `EffectsController.onSpawnEffect` expects positional
  `(effectType: string, position: Vector3, extra: any)`, but
  `AbilityService`, `CombatService` and `BossService` fire a single TABLE
  payload (`{type="Power", ...}`). B's new FX (power ring/flash/poof,
  rare-acquisition ring/flash/poof/glitchAura) deliberately uses the
  positional form the client handles; the pre-existing table fires are
  left as-is (v1.0.2 behaviour) but may be silent no-ops client-side —
  the effects workstream should reconcile the two conventions (one
  canonical payload shape, both sides).
- **Audit F2 (rebirth income +10% vs +25%):** live behaviour depends on
  load order. It changes the value of every income bonus in §1.9 by up
  to 2.5× depending on wiring — the rebirth owner should pick one source
  of truth before income numbers are tuned further.
- **Audit F11 (banked-income cap):** `BANKED_CAP = 10,000` vs
  `wobble_king` 18,000/s base — and now `void_vulture` 11,000/s,
  `solar_sloth` 5,500/s. High-tier owners lose banked income in ~1s
  unless they collect constantly. The cap (or the new top-tier incomes)
  needs a balance decision before the Secret/Celestial tier is playable.
- **`Types.luau` mirror drift:** `Types.CharacterDef` does not list the
  new optional `CompanionAbility` field and its BodyShape comment still
  lists 18 shapes. Runtime-harmless (Characters.luau owns its own type),
  but the types owner should sync it.
- **No fusion recipes for the 9 new characters** (`Mutations.luau` is not
  a B file): new characters can neither be fused nor be fusion results
  until recipes are added. `FusionService` rejects unknown pairs by
  design, so this fails closed.

## 5. Deliberately left undone

- Chrono Croissant / Cyber Chameleon / Meteor Mantis (suggested concepts
  not used — 9 additions already cover Common→Secret; no new Impossible).
- Fusion recipes for new characters (needs `Mutations.luau` — not owned).
- `Types.luau` CharacterDef mirror sync (not owned).
- Companion HUD panel / mastery UI (client controllers not owned).
- Market lighting system (no new lighting API invented; existing
  `glitchAura` / tide storm lighting reused).
- Any Studio playtest, screenshot, recording, publish or submission.
- No new remote names were needed (see `docs/REMOTES_NEEDED_B.md`).

## 6. Files changed / added (line counts are current totals)

| File | Lines before → after | Change |
|---|---|---|
| `src/shared/Characters.luau` | 714 → 1020 | +9 characters, CompanionAbility type + field, 6 existing companions, `GetCompanionAbility` |
| `src/shared/CharacterModels.luau` | 593 → 952 | +9 builders, rarity presentation for all 27, 4 existing-builder upgrades, transform effects |
| `src/shared/Powers.luau` | 526 → 730 | +9 primaries, +5 playable powers, mastery helpers |
| `src/shared/Synergies.luau` | 180 → 205 | +3 synergies (13 total) |
| `src/shared/Companions.luau` | — → 179 | NEW shared companion data + caps + `ComputeBonuses` |
| `src/server/Services/AbilityService.luau` | 792 → 1167 | 5 new power branches, mastery, snapshot loop, per-power FX |
| `src/server/Services/EconomyService.luau` | 290 → 326 | Income hook only: `SetCompanionService` + `GetCompanionIncomeMultiplier`; every existing method + signature intact |
| `src/server/Services/CompanionService.luau` | — → 374 | NEW service (see §1.9) |
| `src/client/Controllers/AnimationController.luau` | 315 → 770 | Per-character profiles, morph animation, full animation set, transform hooks |
| `docs/QA_V11_B.md` | — | This file |
| `docs/REMOTES_NEEDED_B.md` | — | Remote inventory (no new names needed) |
