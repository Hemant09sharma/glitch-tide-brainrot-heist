# REMOTES WIRED — Wave 3, Workstream E (v1.1)

**Date:** 2026-11-19
**Scope:** every remote name added to `src/shared/Remotes.luau`, every listener wired on the client, every dead path fixed or explicitly left, and the `UsePower` / `SettingsUpdate` / `SynergyUpdate` / `EquipTitle` decisions.
**Verification:** `luau-compile` 19/19 files pass; static checks (a)–(d) in `docs/QA_V11_E.md` §8. No Studio playtest was run or is claimed.

---

## 1. Remotes added to `Remotes.luau` (17 names)

All 17 are in `Names` plus the correct `EVENT_NAMES` / `FUNCTION_NAMES` list. 13 from `REMOTES_NEEDED_C.md`, 3 from `REMOTES_NEEDED_A.md`, 0 from B, 0 from D (B and D needed no new names — verified against their docs).

| # | Name | Kind | Source doc | Client use |
|---|---|---|---|---|
| 1 | `TeleportDimension` | RemoteEvent | A | `DimensionController.Teleport` / `ReturnToHub` fire `{Action="Teleport", DimensionId}` / `{Action="Return"}` |
| 2 | `RequestDimensions` | RemoteFunction | A | `DimensionController.RefreshFromServer` invokes; falls back to shared `Dimensions` module |
| 3 | `DimensionUpdate` | RemoteEvent | A | `DimensionController` listens (Teleported / Returned / TeleportDenied / ChestOpened / ChestDenied / Checkpoint / CheckpointComplete / CheckpointFailed / BossTriggered / BossDenied) |
| 4 | `RequestLab` | RemoteFunction | C | `LaboratoryController.RefreshFromServer` invokes |
| 5 | `LabUpdate` | RemoteEvent | C | `LaboratoryController` listens; refreshes state |
| 6 | `EvolveBrainrot` | RemoteEvent | C | `LaboratoryController` fires the Action envelope: Evolve / UpgradeTrait / DiscoverRecipe / AlternateForm |
| 7 | `RequestExpeditions` | RemoteFunction | C | `ExpeditionController.RefreshFromServer` invokes |
| 8 | `ExpeditionUpdate` | RemoteEvent | C | `ExpeditionController` listens; ready-to-claim banner |
| 9 | `StartExpedition` | RemoteEvent | C | `ExpeditionController` fires `{InstanceId, ExpeditionId}` |
| 10 | `ClaimExpedition` | RemoteEvent | C | `ExpeditionController` fires `{ExpeditionId}` |
| 11 | `RequestTerritories` | RemoteFunction | C | `TerritoryController.RefreshFromServer` invokes |
| 12 | `TerritoryUpdate` | RemoteEvent | C | `TerritoryController` listens (broadcast to all); capture banner |
| 13 | `CaptureTerritory` | RemoteEvent | C | `TerritoryController` fires `{TerritoryId}` |
| 14 | `SecretDiscovered` | RemoteEvent | C | `AchievementController` listens; generic banner only (payload carries no secret id/name) |
| 15 | `RequestAchievements` | RemoteFunction | C | `AchievementController.RefreshFromServer` invokes |
| 16 | `AchievementUnlocked` | RemoteEvent | C | `AchievementController` listens; banner + sound + refresh |
| 17 | `EquipTitle` | RemoteEvent | C (Wave 3 instruction) | `AchievementController` fires `{TitleId}` — **handler pending** (see §4) |

`Main.client.luau` now waits for all 17 names (5 s cap each, warn-only) and `CONTROLLER_ORDER` loads the five new controllers before `CameraController`.

### Names deliberately NOT added (per the REMOTES_NEEDED docs)

| Name | Why not |
|---|---|
| `RequestSecrets` | C explicitly does not request it; secrets are never listed client-side |
| `RequestTitles` / `TitleUpdate` | C: title equip is Wave 3 client UI; server stores Titles + EquippedTitle via `RequestAchievements` |
| `LabFailure` / `ExpeditionFailure` / `TerritoryFailure` | C: not requested; failures surface as "no reply" watchdogs / status text |
| `CompanionUpdate` / `PowerMasteryUpdate` | B: proposed future names, NOT fired by any service — do not add speculatively |
| `SpawnBoss` | D: boss spawning is server-internal; the client only listens to `BossUpdate` |

---

## 2. Listeners wired (client, this workstream)

| Remote | Listener | What it does |
|---|---|---|
| `BossUpdate` | `HUDController` | Boss health bar (`SetBoss`), spawn banner + boss sound, death banner + victory sound. Payload `{Event, BossId, BossName, Arena, Active, Health, MaxHealth, Phase}` |
| `DimensionUpdate` | `DimensionController` | All 10 actions (see §1 row 3); updates region via `HUDController.SetRegion`, banners, sounds |
| `LabUpdate` | `LaboratoryController` | Merges new lab state, clears pending watchdogs, refreshes panel |
| `ExpeditionUpdate` | `ExpeditionController` | Updates state; ready-to-claim banner + sound when a trip finishes |
| `TerritoryUpdate` | `TerritoryController` | Updates list; capture banner + sound when the local player gains a territory |
| `AchievementUnlocked` | `AchievementController` | Banner + achievement sound + refresh |
| `SecretDiscovered` | `AchievementController` | Generic mysterious banner only — never a secret id/name (the payload carries none) |
| `EventUpdate` (existing) | `HUDController` | **New:** `SoundHook` field (`"rare"` / `"secret"`) now plays via `SoundController.PlaySoundHook` |
| `GlitchTideUpdate` (existing) | `HUDController` | **New:** D's `Stage` / `StageName` / `Announcement` fields now surface in the tide stage line (`SetTideStage`) |
| `GlitchTideUpdate` (existing) | `EffectsController` | **Fixed:** reads capitalized `Phase` / `TimeLeft` (was lowercase-only, matched nothing); stage 3 plays the siren cue |
| `DamageNumber` (existing) | `EffectsController` + `HUDController` | **Fixed:** both now accept the server's table form `{target, amount, isCrit, isHeal}` (was positional-only) |
| `SpawnEffect` (existing) | `EffectsController` | **Fixed:** accepts BOTH forms — positional `(string, Vector3, extra)` and table `{type, position, ...}` incl. all D table types (TideSiren, TideClimax, BossShockwave, BossVoidBolt, BossVoidZone, BossTeleport, GlitchTeleport, SecretEncounter, Starfall, MeteorFallout, Power/Ability, …); unknown table types with a position degrade to a visible ring + burst |
| `StealAlert` (existing) | `InteractionController` (new) + `BaseController` (fixed) | InteractionController: thief-side watchdog + prompts. BaseController: victim-side banner, now parsing the real payload `{Thief, ThiefUserId, Victim, CharacterId, Phase}` + Lockdown variant (was reading `ThiefName`/`CharacterName`/`BrainrotName`, which do not exist) |
| `PlayerStats` (existing) | `HUDController` | Unchanged; the dead 5 s polling fallback and the dead `FireServer("GetStats")` were removed (see §3) |
| `RequestEvents` (new caller) | `HUDController` | Invokes on Init and every 60 s; shows the active event so a mid-event joiner sees it |

---

## 3. Dead paths fixed (audit F1)

| # | Dead path | Fix |
|---|---|---|
| 1 | `Attack` — server handler in `CombatService`, no client firer | `AbilityController.Attack()` added: left-click (`UserInputService.InputBegan`, MouseButton1, `gameProcessed=false`) + touch-only ATTACK button; 0.45 s client cooldown matching the server; swing sound + `AnimationController.PlayAttack` locally. Fires with no payload (server ignores it) |
| 2 | `StealBrainrot` — server handler in `RaidService`, no client firer | `InteractionController` steal scan + firer: cached `Placed_<InstanceId>` scan inside the existing 0.25 s loop (cache refreshes every 5 s), own instances excluded, victim resolved via nearest `OwnerSign` ("BASE n\n\<ownerName\>") within 25 studs or nearest other player within 30 studs; fires `{VictimUserId, InstanceId}`; client debounce 1 s + 60 s per-victim cooldown; 5 s watchdog (server sends no failure payload) |
| 3 | `RequestCollection` — server handler in `ProgressionService`, no client caller | `CollectionController.RefreshFromServer` now invokes it and merges `Discovered` ids; `RequestShop` Owned flags remain as a fallback merge |
| 4 | `RequestEvents` — server function, no client caller | `HUDController` invokes on Init + every 60 s (see §2) |
| 5 | `BossUpdate` — fired by `BossService`, no client listener | `HUDController` listener added (see §2) |
| 6 | `GetStats` via `PlayerStats` event — `HUDController:1145` fired `FireServer("GetStats")` on a RemoteEvent with no handler | Removed. The server pushes `PlayerStats` on join and on every change; nothing needs asking for |
| 7 | `GetStats` via `PlayerStats` function — `CharacterSelectController` invoked it as a RemoteFunction | Removed (same reason as #6) |
| 8 | `GetBase` via `RequestBase` event — `BaseController:327` and `ShopController:751` fired `FireServer("GetBase")` on a RemoteFunction | Removed in both. `RequestBase` is a function; the function branch was already the live path |
| 9 | `RequestQuests` event branch — `QuestController` fired it as a RemoteEvent | Removed. `RequestQuests` is a RemoteFunction; only the function branch remains |
| 10 | `SpawnEffect` table form — servers fire tables, `EffectsController` only handled positional | Fixed (see §2) |
| 11 | `DamageNumber` table form — server fires a table, `EffectsController` + `HUDController` only handled positional | Fixed (see §2) |
| 12 | `GlitchTideUpdate` capital keys — server sends `Phase`/`TimeLeft`, `EffectsController` only read lowercase | Fixed (see §2) |
| 13 | `StealAlert` payload — `BaseController` read fields that do not exist, so the banner always showed "Someone" / "a Brainrot" | Fixed (see §2); character name resolved via the shared `Characters` catalogue |
| 14 | `EventUpdate` SoundHook — B's rare-acquisition banner carries `SoundHook` ("rare"/"secret") with no client consumer | Wired to `SoundController.PlaySoundHook` in the HUD listener |

---

## 4. Deliberately left unwired / handler-pending (with reasons)

### `UsePower` — STAYS UNWIRED (decision, do not re-litigate silently)
`AbilityService.UsePower` is a Lua method reached ONLY through the `UseAbility` handler (id-partitioned). There is no server handler for a `UsePower` remote event. Firing it would hit nothing and duplicate the entry point. `UseAbility` is the single power path; `UsePower` stays a defined-but-never-fired name in `Remotes.luau` as documentation of the decision.

### `SettingsUpdate` — STAYS UNWIRED (decision)
No server settings store exists and no `DataService` field stores settings. Mute / master / SFX / music volumes are client-local in `SoundController` (M key + MainMenu Settings steppers). Firing `SettingsUpdate` would be a silent no-op dressed as a sync. No server `SoundService` was created — every sound is a client-side one-shot triggered by a broadcast the client already receives. If a server settings store is ever added, the client side is already split (`SetVolume` / `SetSFXVolume` / `SetMusicVolume` / `SetMuted`) and can be synced then.

### `SynergyUpdate` — STAYS RESERVED
No service fires it; synergy is folded silently into income. Verified by grep 2026-11-19: zero references in `src/` outside `Remotes.luau`. Do NOT fake it.

### `EquipTitle` — DEFINED, CLIENT FIRES IT, SERVER HANDLER PENDING
Added per `REMOTES_NEEDED_C.md`'s explicit Wave-3 instruction (`{TitleId}` payload). `AchievementService.SetEquippedTitle(player, titleId)` EXISTS server-side but NO remote handler calls it (verified by grep 2026-11-19). The client Equip button fires the remote AND keeps the choice local-only (title shows as equipped in the panel and in the HUD title slot for this session), with an in-panel warning that says so plainly. **Equips do NOT persist across sessions until the handler is wired.**
Integrator step (one handler, the rest of the path already exists) — in `AchievementService`'s remote table add:
```lua
["EquipTitle"] = function(player, payload)
	AchievementService.SetEquippedTitle(player, payload.TitleId)
end
```

### `PowerMasteryUpdate` / `CompanionUpdate` — NOT ADDED
B's rule: add only when a UI consumes a fired value. Nothing fires them. Mastery is displayed from the documented formula + session-only use counts (see `docs/QA_V11_E.md` §6); companion abilities are shown from the shared `Characters` catalogue (`CompanionAbility` on character cards).

### Trading remotes (`TradeRequest` / `TradeAccept` / `TradeCancel`) — DEFINED, NEVER FIRED
Trading is intentionally omitted (unsafe). The names stay defined in `Remotes.luau` as reserved; no client firer or listener exists.

---

## 5. Fired-but-undefined / defined-but-never-fired audit (2026-11-19)

- **Server-referenced names not in `Remotes.luau`:** none. Every `Remotes.Names.X` used in `src/server/` exists in `Remotes.luau`.
- **Client-fired names without a server handler:** exactly one — `EquipTitle` (see §4). Every other client `FireServer` / `InvokeServer` name resolves to a server handler via `Remotes.Names.X` (`CombatService`, `RaidService`, `BaseService`, `CarryService`, `ConveyorService`, `EconomyService`, `QuestService`, `MutationService`, `FusionService`, `CharacterService`, `DimensionsService`, `LaboratoryService`, `ExpeditionService`, `TerritoryService`, `ProgressionService`, `EventService`, `AchievementService`).
- **Defined but never referenced in `src/`:** `SynergyUpdate` (reserved, §4) and `TradeAccept` / `TradeCancel` / `TradeRequest` (trading omitted, §4).
- **`rbxassetid://` in `src/`:** zero uses — only two comment mentions in `SoundController.luau` explaining why no ID is invented. No invented asset IDs anywhere.

---

## 6. New client controllers (all in `src/client/Controllers/`, all `Init()`-loaded by `Main.client.luau`)

| Controller | Lines | Remotes used |
|---|---|---|
| `PanelKit.luau` (library, no `Init()` — the extra-loader skips it) | 280 | Shared helpers: `GetRemote`, `FireServerChecked`, `InvokeChecked`, `Listen`, `MakeButton` (always connects `MouseButton1Click`), `Debounce`, `PlaySound`, `ShowBanner`, `OpenController`, `RarityColor`, `CharacterName`, `FormatCoins`, `FormatDuration` |
| `DimensionController.luau` | 411 | `RequestDimensions`, `TeleportDimension`, `DimensionUpdate`, `PlayerStats` (level display only) |
| `LaboratoryController.luau` | 848 | `RequestLab`, `LabUpdate`, `EvolveBrainrot`, `MutateBrainrot`, `FuseBrainrot`, `RequestBase` |
| `ExpeditionController.luau` | 378 | `RequestExpeditions`, `ExpeditionUpdate`, `StartExpedition`, `ClaimExpedition` |
| `TerritoryController.luau` | 290 | `RequestTerritories`, `TerritoryUpdate`, `CaptureTerritory` |
| `AchievementController.luau` | 411 | `RequestAchievements`, `AchievementUnlocked`, `SecretDiscovered`, `EquipTitle` |

Every fire in the new controllers is debounced (`PanelKit.Debounce` / `FireServerChecked`) and every panel refreshes on open + on its server push only — no polling loops (except the HUD's 60 s `RequestEvents` refresh and the expedition 1 s countdown tick, which runs only while that panel is open and a trip is active).

---

## 7. Server return-shape corrections found while wiring (server code wins over the docs)

| Doc claim | Actual server return | Client consequence |
|---|---|---|
| `REMOTES_NEEDED_C.md`: `GetLabState` returns `Recipes` / `TraitCosts` | Returns only `{Evolvable, Evolved, DiscoveredRecipes, MaxLevel}` | Costs/recipes come from shared `LabDefs` client-side (`GetEvolveCost`, `GetTraitUpgradeCost`, `GetSecretRecipes`, `GetAlternateForm`) |
| `REMOTES_NEEDED_C.md`: `GetExpeditions` returns `{Active, Available, OnExpedition}` | Returns `{Definitions, Active, Completed, Eligible}` (`Eligible[expeditionId]` = instance ids) | Expedition panel reads `Eligible`; the on-expedition rule excludes the single `Active.InstanceId` |
| `REMOTES_NEEDED_C.md`: title equip needs a new remote | `AchievementService.SetEquippedTitle` exists; only the remote handler is missing | `EquipTitle` added; handler-pending (see §4) |

---

## 8. What Wave 3 E did NOT do

- No server service file was edited (services are done; read-only for this workstream). No `SoundService` was created.
- No Studio playtest was run; no runtime success is claimed. All verification is static (`luau-compile`, `luau-analyze`, greps) plus the web-verified sound inventory in `docs/QA_V11_E.md` §5.
- No `rbxassetid://` IDs were invented; five sound slots stay unassigned by design.
- `CameraController`'s camera logic was not touched (verified by grep: binds on `CharacterAdded` + `Character` property change + CurrentCamera change, Custom + live Humanoid, 0.5 s watchdog, teleport snap).
