# Remotes needed — Workstream C (v1.1)

**Workstream C fires 13 new remote names, all by string name. None exists in
`Remotes.luau` yet, and `Remotes.luau` was NOT edited, per the task
constraints.** Every new service waits up to 10s for its remote to appear
(`task.spawn` + 50 × 0.2s poll) and warns once if it never appears, so a
missing name degrades to "feature silently unavailable" rather than a server
error. Add these 13 names to `Remotes.Names` (and the corresponding
`EVENT_NAMES` / `FUNCTION_NAMES` tables) before Wave 3 builds the client UI;
until then every handler below simply never wires.

## New remotes C fires (add all 13)

### LaboratoryService

| Remote | Kind | Direction | Payload (exact) |
|---|---|---|---|
| `RequestLab` | RemoteFunction | Client → server, returns table | No args. Returns `LaboratoryService.GetLabState(player)`: `{Evolvable: {{InstanceId, CharacterId, Name, Rarity, Level, Mutation, Placed, Evolved, EvolvedTrait, EvolvedFormName, TraitLevels, AlternateForm}}, DiscoveredRecipes: {recipeId...}, Recipes: {{Id, Name, FormName, ResultCharacterId, Cost, BonusMutation, RequiresSecret}}, TraitCosts: {traitId: {Cost, Gems}}}` |
| `LabUpdate` | RemoteEvent | Server → that player | `{Action="LabUpdate", State=<same shape as RequestLab return>}`. Fired after every successful evolve / trait upgrade / recipe discovery / alternate-form switch / mutate / fuse. |
| `EvolveBrainrot` | RemoteEvent | Client → server | Action envelope (single remote, like the existing `Rebirth` remote): `{Action="Evolve", InstanceId}`, `{Action="UpgradeTrait", InstanceId, TraitId}`, `{Action="DiscoverRecipe", RecipeId}`, `{Action="AlternateForm", InstanceId}`. Server rate-limit: 1/s per player. Failures are server `warn`s only — no failure payload is fired (Wave 3 may add one; see §Optional). |

### ExpeditionService

| Remote | Kind | Direction | Payload (exact) |
|---|---|---|---|
| `RequestExpeditions` | RemoteFunction | Client → server, returns table | No args. Returns `ExpeditionService.GetExpeditions(player)`: `{Active: {ExpeditionId, InstanceId, CharacterId, StartedAt, EndsAt, RemainingSeconds} \| nil, Available: {{Id, Name, DurationSeconds, Risk, MinLevel, MinRarity, RequiredTrait, Rewards}}, OnExpedition: {instanceId...}}` |
| `ExpeditionUpdate` | RemoteEvent | Server → that player | `{Action="ExpeditionUpdate", State=<same shape as RequestExpeditions return>, ...extra}`. `extra` may carry `Claimed = {Coins, Gems, ...}` / `Discovered = characterId` on a claim. Fired on start and on claim. |
| `StartExpedition` | RemoteEvent | Client → server | `{InstanceId, ExpeditionId}`. Rate-limit 1/s. |
| `ClaimExpedition` | RemoteEvent | Client → server | `{ExpeditionId}`. Rate-limit 1/s. Rewards are paid server-side on claim; the client learns them from the following `ExpeditionUpdate` + the standard `PlayerStats` push. |

### TerritoryService

| Remote | Kind | Direction | Payload (exact) |
|---|---|---|---|
| `RequestTerritories` | RemoteFunction | Client → server, returns table | No args (player arg ignored). Returns `TerritoryService.GetTerritories()`: array of `{Id, Name, Position={X,Y,Z}, Radius, Tier, CoinsPerSec, XPPerMinute, Holder, HolderUserId, Channeler, ChannelProgress, ChannelSeconds, Contested}`. |
| `TerritoryUpdate` | RemoteEvent | Server → ALL players | `{Action="TerritoryUpdate", Territories=<same array as RequestTerritories return>, ...extra}`. Fired on capture start, capture complete, release, and each bonus tick cycle (1s cadence while any territory is held). |
| `CaptureTerritory` | RemoteEvent | Client → server | `{TerritoryId}`. Starts the 10s channel (server-timed, position-polled). Rate-limit 1/s; per-player capture cooldown 60s. |

### SecretService

| Remote | Kind | Direction | Payload (exact) |
|---|---|---|---|
| `SecretDiscovered` | RemoteEvent | Server → that player | `{Action="SecretDiscovered"}`. **Deliberately carries NO secret id or name** — the client must not learn which secret was found from the payload; the discovery is announced only by a generic banner (see `EventUpdate` below). Server-side only: `SecretService.IsDiscovered(player, secretId)` is the check. |

### AchievementService

| Remote | Kind | Direction | Payload (exact) |
|---|---|---|---|
| `RequestAchievements` | RemoteFunction | Client → server, returns table | No args. Returns `AchievementService.GetAchievements(player)`: `{Achievements: {{Id, Name, Description, Kind, Target, Progress, Unlocked, Reward}}, Titles: {titleId...}, EquippedTitle: string \| nil}`. |
| `AchievementUnlocked` | RemoteEvent | Server → that player | `{Action="AchievementUnlocked", Id, Name, Reward={Coins?, Gems?, ...}, Title=titleId \| nil}`. Fired exactly once per achievement per player (unlock is persisted in `data.Achievements`). |

## Existing remotes C reuses (already in Remotes.Names — do NOT re-add)

| Remote | Fired from | Payload (exact) | Client listener (verified) |
|---|---|---|---|
| `SpawnEffect` | `LaboratoryService.playEvolveEffect` (evolve transform) + `SecretService` (discovery burst) | Positional form: `("ring", position, {radius, color})`, `("flash", position, Color3)`, `("poof", position, nil)` — the form `EffectsController.onSpawnEffect` implements (same as B) | `EffectsController.onSpawnEffect` |
| `EventUpdate` | `LaboratoryService` (evolve banner), `ExpeditionService` (expedition complete / discovery banner), `AchievementService` (unlock banner, fired to ALL players), `SecretService` (generic discovery banner) | `{EventId, Name, Phase="Started", Duration=6}` — the shape `HUDController` already renders. Secret banners NEVER name the secret: `Name="<player> discovered something hidden!"` | `HUDController` EventUpdate listener → `ShowEventBanner` |
| `PlayerStats` | All C reward paths (via `EconomyService.NotifyBalance` / `DataService` pushes, unchanged) | Unchanged payloads | `HUDController` / `ShopController` |
| `BaseUpdate` | `LaboratoryService` mutate/fuse pass-throughs (via `MutationService` / `FusionService`, unchanged) | Unchanged payloads | Existing base UI |
| `QuestUpdate` | `QuestService` (unchanged; C's new quests flow through the same push) | Unchanged payloads | Existing quest UI |
| `DimensionUpdate` | `DimensionsService.fireUpdate` (unchanged) | **Teleport-denied payload rides this existing name**: the same `{Action="TeleportDenied", DimensionId, Reason}` table C's unlock gate fires when a locked dimension is requested. No new name needed. | `DimensionsController` (Wave 1) |
| `Rebirth` | `ProgressionService` (unchanged remote) | **Prestige rides this existing remote**: `{Action="Prestige"}` envelope, alongside the existing `{Action="Rebirth"}`. No new name needed. | Existing rebirth UI (Wave 3 must add a Prestige button that fires the same remote with `Action="Prestige"`) |

## Explicitly NOT requested (do NOT add)

| Name (proposed) | Why not |
|---|---|
| `RequestSecrets` | Listing secrets would defeat the point. Secrets are discoverable only by doing the hidden thing; the server exposes only `IsDiscovered(player, secretId)` (one id at a time, server-side) and the id-less `SecretDiscovered` broadcast. Same rule as B's "optional future names": do not add speculatively. |
| `RequestTitles` / `EquipTitle` / `TitleUpdate` | Title equip is Wave 3 client UI; the server stores `Titles` + `EquippedTitle` and exposes them through the existing `RequestAchievements` return. If Wave 3 needs a dedicated equip remote it should add `EquipTitle` then, with payload `{TitleId}`. |
| `LabFailure` / `ExpeditionFailure` / `TerritoryFailure` | C's handlers currently only server-`warn` on failure. If Wave 3 wants client-visible failure toasts, add one generic `ActionFailed` remote (payload `{Action, Reason}`) rather than three separate names. |
| `CompanionUpdate` / `PowerMasteryUpdate` | B's proposed future names — still not fired by C. |

## Payload conventions C follows (from audit §4a + B's doc)

- Bare id strings for simple requests; `{Action=...}` envelopes for multi-action remotes (`EvolveBrainrot`, and the pre-existing `Rebirth` pattern prestige reuses).
- `SpawnEffect` positional form for NEW fires: `(effectType: string, position: Vector3, extra: any)` — the form the client handler implements.
- `EventUpdate` banner payload: `{EventId, Name, Phase="Started", Duration}` — extra fields are ignored by the HUD.
- Every C handler validates the payload is a table, sanitizes ids (`^[%w%-_]+$`, ≤64 chars, via the `SecurityService` path when present), and rate-limits at 1/s per player.
