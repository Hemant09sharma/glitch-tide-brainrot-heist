# Remotes needed — Workstream B (v1.1)

**Workstream B needs NO new remote names.** Every fire in B's new/changed
code uses a remote that already exists in `Remotes.luau` (and is already
listened to on the client). `Remotes.luau` was NOT edited, per the task
constraints. This file exists so the parent / integrator can verify that
claim and so future work knows exactly which payloads B relies on.

## Existing remotes B fires (all already in Remotes.Names)

| Remote | Fired from | Payload (exact) | Client listener (verified) |
|---|---|---|---|
| `SpawnEffect` | `AbilityService.UsePower` (existing table fire, unchanged) + new positional FX (`ring` / `flash` / `poof`) + `meteor_shower` impacts (existing table fire) | Positional form (NEW, B): `("ring", position, {radius, color})`, `("flash", position, Color3)`, `("poof", position, nil)`. Table form (pre-existing, unchanged): `{type="Power", powerId, player, position}` | `EffectsController.onSpawnEffect` (positional form — handles `ring` / `flash` / `poof` / `glitchAura` / `shake` / `glitch` / `hit` / `ko`). See QA_V11_B §4: the pre-existing TABLE form does not match this handler's signature and may be a silent no-op — B's new FX deliberately uses the positional form |
| `SpawnEffect` | `CompanionService.AnnounceRareAcquisition` | Positional: `("ring", pos, {radius, color})`, `("flash", pos, Color3)`, `("poof", pos, nil)`; Secret/Impossible only, 0.35s later: `("ring", pos, {radius+6, color})`, `("glitchAura", pos, 3)` | Same as above |
| `EventUpdate` | `CompanionService.AnnounceRareAcquisition` | `{EventId="RareAcquisition", Name="<player> acquired <DisplayName> (<Rarity>)!", Phase="Started", Duration=6–15, SoundHook="rare" \| "secret"}` | `HUDController` EventUpdate listener → `ShowEventBanner(text, duration)`. `SoundHook` is an EXTRA field the HUD ignores — it is a hook for the sound workstream (play a rare/secret sting when this payload arrives), not a new remote |
| `PowerUpdate` | `AbilityService.UsePower` (unchanged) | `{PowerId, Cooldown, Remaining}` (now the mastery-reduced effective cooldown) | `AbilityController` (listens, corrects local cooldown display) |
| `PlayerStats` | `AbilityService.UnlockPower` / `PushLoadout` (unchanged) | Unchanged payloads | `AbilityController` / `HUDController` / `ShopController` |

## Existing remotes B reads (no new handler)

| Remote | Read from | Use |
|---|---|---|
| `UseAbility` | `AbilityService.Init` (existing handler, unchanged) | The 5 new playable powers are fired by the client through this remote exactly like the 12 existing ones (`AbilityController.UseSlot` → `UseAbility` with the power id string). Server validation partitions by id: loadout ids → AbilityService, primaries/generics → CombatService. No remote change needed. |

## Optional future names (NOT fired by B — do NOT add until a workstream needs them)

| Name (proposed) | Would be used for | Status |
|---|---|---|
| `CompanionUpdate` | Pushing a player's live companion bonuses to their client for a companion HUD panel | NOT fired anywhere in B. If a UI workstream builds a companion panel, add the name to `Remotes.Names` + `EVENT_NAMES` first, then have `CompanionService` fire it (e.g. on join / on purchase). Until then it must NOT be added speculatively. |
| `PowerMasteryUpdate` | Pushing mastery XP/level per power to the client for a mastery display | NOT fired anywhere in B. Same rule: add only when a UI consumes it; `AbilityService.GetMasteryStateForSave` already exposes the data server-side. |

## Payload conventions B follows (from audit §4a)

- Bare id strings for requests (`UseAbility` takes a power id string).
- `SpawnEffect` positional form for NEW fires: `(effectType: string, position: Vector3, extra: any)` — the form the client handler implements.
- `EventUpdate` banner payload: `{EventId, Name, Phase="Started", Duration}` — the shape `HUDController` already renders; extra fields are ignored by the HUD and available to other client systems.
