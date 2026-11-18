# REMOTES NEEDED — Workstream A (v1.1)

New remote names DimensionsService expects. This file is a REQUEST,
not an implementation: `Remotes.luau` is owned by another workstream
and was NOT edited here. Until the names below exist in `Remotes.luau`
(`Names` + `EVENT_NAMES` / `FUNCTION_NAMES` + `CreateRemotes`), the
features that use them degrade as described — nothing here crashes.

Convention reminder (audit §4a): add the name to `Remotes.Names`
FIRST, with the wiring-status comment updated in the same change.

## 1. TeleportDimension — RemoteEvent (server handler)

- **Purpose:** client-initiated dimension travel (a future Dimension
  panel / keybind). The ProximityPrompts are the primary path today
  and work without this remote.
- **Client → server payload:**
  - `{ Action = "Teleport", DimensionId = "abyssal" | "skyfall" }`
  - `{ Action = "Return" }`
- **Server behaviour (already implemented in DimensionsService):**
  DimensionsService polls for this remote for up to 10s after Init
  and connects `OnServerEvent` when it appears. The handler enforces
  the same validation as the prompts (portal proximity, hub-only
  origin, 3s cooldown, not while carrying) plus `BurstLimit(5, 5)`.
  No reply payload — the client learns the result from the
  DimensionUpdate broadcast (see §3).
- **Status without it:** prompt-only travel. The service warns once
  at Init: "[DimensionsService] TeleportDimension remote not
  available".

## 2. RequestDimensions — RemoteFunction (server handler)

- **Purpose:** client pulls the dimension list (names, descriptions,
  moods, chest rewards, checkpoint limits) for a future Dimension
  panel / HUD region indicator.
- **Client → server:** `InvokeServer()` with no arguments.
- **Server reply (already implemented):**
  `DimensionsService.GetDimensions()` — an array of
  `{ Id, DisplayName, Description, LightingMood,
  ExclusiveCharacterId, HubPortalPosition, SpawnPosition,
  CheckpointTimeLimit, CheckpointRewardCoins,
  CheckpointRewardXP, Chests = { { Name, Title, Coins, XP } } }`.
- **Status without it:** no client can list dimensions. The service
  warns once at Init.

## 3. DimensionUpdate — RemoteEvent (server broadcast, no handler)

- **Purpose:** server → client notifications for everything
  DimensionsService does, so a future HUD/controller can show it.
- **Payloads (all fired via `Remotes.FireClient` with the string name,
  so today they are silent no-ops — no client listens yet):**
  - `{ Action = "Teleported", Dimension = id, DisplayName = ... }`
  - `{ Action = "Returned", Dimension = "hub" }`
  - `{ Action = "TeleportDenied", Reason = string }`
  - `{ Action = "ChestOpened", Chest = name, Title = ..., Coins = n, XP = n }`
  - `{ Action = "ChestDenied", Reason = string }`
  - `{ Action = "Checkpoint", Index = n, Total = 4 }`
  - `{ Action = "CheckpointComplete", ElapsedSeconds = n, Coins = n, XP = n, FirstCompletion = bool }`
  - `{ Action = "CheckpointFailed", Reason = "time", ElapsedSeconds = n, TimeLimit = n }`
  - `{ Action = "BossTriggered", Dimension = "abyssal" }`
  - `{ Action = "BossDenied", Reason = string }`
- **Status without it:** all of the above are silent. Gameplay still
  works (rewards are granted server-side; the player just gets no
  toast/banner). A client controller for these payloads is future
  work for another workstream — not this one.

## Deliberately NOT requested

- No new RemoteFunction for teleport results (DimensionUpdate covers it).
- No `BossUpdate` use: BossService announces via `SpawnEffect` /
  `WaveUpdate` and `BossUpdate` is an orphan (audit §4a). The altar
  trigger does not change that.
- No trading remotes: trading is intentionally omitted (audit §4a).
