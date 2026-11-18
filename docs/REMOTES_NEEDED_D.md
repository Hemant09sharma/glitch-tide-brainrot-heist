# REMOTES NEEDED — Workstream D (GLITCH TIDE v1.1: Event + Bosses + Combat)

**Rule followed:** `Remotes.luau` was NOT edited (owned by another workstream).
Every remote fired by Workstream D already exists in `Remotes.Names` and is
created by `Remotes.CreateRemotes`. **No new remote name needs to be created.**

## Newly fired (existing name, previously fired by no service)

| Remote | Fired by (v1.1 D) | Payload | Client listener |
|---|---|---|---|
| `BossUpdate` | `BossService.broadcastBossUpdate` — on spawn (`"Spawned"`), phase change (`"Phase"`), every 2s during a fight (`"Health"`), death (`"Defeated"`) | `{Event, BossId, BossName, Arena, Active, Health, MaxHealth, Phase}` | **NONE YET — later workstream.** Audit §4j: boss announces currently go via `SpawnEffect`/`WaveUpdate`, not `BossUpdate`. Those two paths are kept (see below), so the game plays identically until a client listens to `BossUpdate`. Do NOT remove the `SpawnEffect`/`WaveUpdate` boss announces when adding the listener. |

## Already-fired remotes with NEW payload fields (v1.1 D)

No new names; clients that ignore unknown fields are unaffected.

| Remote | New fields (v1.1 D) | Fired by |
|---|---|---|
| `GlitchTideUpdate` | `Stage` (1–10), `StageName`, `Announcement`, `EscapeRoutes` (`{{Position={x,y,z}, Radius, Kind}}`, stage 5 only), `WavePosition` (already sent in v1.0.2), `CoopBonus`, `Survivors`, `RewardMultiplier` | `TideService.broadcast` / `broadcastStage` |
| `EventUpdate` | `SecretEncounter` (`"HiddenMerchant"` / `"SecretSighting"`, tide secret roll), `Announcement` (stage-5 warning) | `TideService` (stage 5 + `rollSecretEncounter`) |
| `TideSurvivor` | `CoopBonus` (bool), `SecretEncounter` (kind or nil) | `TideService` (end of tide) |
| `WaveUpdate` | `BossActive` (bool), `BossName` (string or nil), `BossId` (boss spawn/defeat) | `WaveService.broadcast`, `BossService` |
| `SpawnEffect` | New `type` values: `TideSiren`, `TideClimax`, `TideSurf` (per-player), `TideShelters`, `RiskZones`, `ToxicPools`, `SlowFields`, `GlitchBarriers`, `GlitchTeleport` (per-player), `SecretEncounter` (`kind`, `variation`), `Starfall`, `MeteorFallout`, `BossTeleport`, `BossTeleportArrive`, `BossVoidBolt` (`target`), `BossVoidZone`, `BossGlitchNova`, `BossVoidNova`; boss effects now also carry `bossId` | `TideService`, `BossService` |
| `PlayerStats` | `TideExclusive` (granted Brainrot Id or nil, survivor payout) | `TideService` |

## Remotes deliberately NOT used / NOT needed

- No new `RemoteEvent` / `RemoteFunction` is needed for any D feature.
- `BossUpdate` is fired **by string name** (`fireAll("BossUpdate", …)`) rather
  than `_names.BossUpdate`, with a comment at the call site — because
  `Remotes.luau` is frozen for this workstream. A later cleanup may switch it
  to `_names.BossUpdate`; the name is identical either way.
- No handler (server `OnServerEvent` / `OnServerInvoke`) was added for any
  remote. All D traffic is server → client broadcast, plus the existing
  `ForceStart` / `SpawnBoss` Lua call paths (no remote involved).

## Notes for the UI / multiplayer workstream (from audit §3 F1)

- **StealBrainrot has no client `FireServer` call anywhere in `src/client/`.**
  `RaidService` owns a full server-side steal flow, but no UI, panel, prompt
  or keybind ever fires the remote, so stealing is currently a dead path.
  This is NOT a Workstream D file and was not changed here — flagged for the
  UI/multiplayer workstream to wire (likely a steal prompt/panel).
- Same finding, same status: melee **`Attack`** has a server handler in
  `CombatService` and no client firer anywhere. Melee combat is likewise
  unreachable from the UI today.
- `RequestCollection` / `RequestEvents` are wired server-side but have no
  client caller (audit §4a) — unchanged by this workstream.
