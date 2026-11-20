# R3 Repairs Report — GLITCH TIDE: Persistence, Sidecar, Reward and Return-Recovery

**Release:** v1.1.0, Phase 1 + R1 + R2 + R3 (uncommitted working copy)
**Base:** HEAD `6ee6d217019af75f3f0c54357150aad470060aaa` — unchanged by this work
**Date:** 2026-11-19
**Status:** R3-1 through R3-7 fixed at the service level (Lune-verified); R3-8 reviewed, partially fixed, remainder deferred with reasons. No Studio playtest has ever run.

## 0. Basis and honesty notes

- The independent R2 audit (Qwen/Hermes, verdict REJECT) was received as a finding list in the task text. **Its PDF (`AUDIT_REPORT_R2.md`) never arrived on disk** — the whole home directory was searched and it is not there. Every R3 finding below was therefore verified directly against the code before being fixed, not against the PDF's sections. Where the code did not match the audit's description, that is recorded (see R3-3 note on `SaveData`).
- R2-1, R2-2, R2-3, R2-6 and R2-7 are accepted as code-level fixes and were **not** rewritten. R2-4 was only partially fixed; R2-5 was not acceptable — R3 repairs those two areas plus the persistence system around them.
- Nothing was committed, pushed, branched, or published. The committed `GlitchTide.rbxl` was **not** rebuilt (SHA-256 `40f0cf4f…`, 558,606 bytes, before and after). Fresh Rojo builds in this report went to `/tmp` only.
- No economy change was made. The N5 banked-income design note remains a proposal only.
- A test counts as proof only when it reproduces the original failure against the old behaviour (negative control) and passes on the fixed code. Every R3 fix below has both.

## 1. Finding-by-finding status

| Finding | Status | Evidence |
|---|---|---|
| **R3-1 (P0)** — Sidecar read failure can overwrite existing data (`readSidecar` returns nil for empty *and* failed reads; callers use `or {}`) | **FIXED** | `readSidecar` now returns `(ok, value)`; a failed read aborts the append and never writes. `writeSidecar` (read-modify-write + `SetAsync`) deleted. Merge/save handle each sidecar key independently and delete a key only when its load-time read succeeded. Persistence tests 01/02/08 (read failure during escrow/pending append, merge-path read failure). |
| **R3-2 (P1)** — Sidecar appends unsafe across servers (read-modify-write race) | **FIXED** | New `appendSidecar` uses `UpdateAsync` with a pure, deterministic, retry-safe transform; dedupe by stable identity (TxId, else legacy `InstanceId:CreatedAt`); no side effects inside the callback. Persistence tests 05/06 (real interleaved two-server appends, both entries survive) and 07 (dedupe + callback purity). |
| **R3-3 (P1)** — Pending-reward deletion / exactly-once recovery | **FIXED** | Durable transaction IDs (`sr-<user>-<instance>-<unix>-<clockMs>-<counter>`); `data.ProcessedRewardTxns` ledger persisted atomically with the coin change in one profile save (`commitPendingPayment`); deletion results checked and retry state kept until deletion genuinely succeeds. Tests 09/10/11/12. See the correction note below. |
| **R3-4 (P2)** — Accumulated pending-reward double counting (cache accumulates, then sidecar accumulates again: 100 + 150 → 350) | **FIXED** | Semantics decided: **delta model + TxId dedupe**. Each `recordPendingReward` call parks its delta once under its TxId; re-recording the same TxId is a no-op in cache and sidecar. Test 11: 100 + 150 → cache and sidecar exactly 250; recovery pays 250. |
| **R3-5 (P1/P2)** — Rewards when the profile is saveable but every save fails | **FIXED, with one honest open window** | Park-first sidecar + synchronous verified save on the delivery path; `grantStealReward` mints a TxId, records pending, then commits through the verified path. Windows W1–W3 closed (see §4). **W4 remains open:** if the sidecar park itself fails *and* the server crashes before any main save succeeds, the reward exists only in cache and is lost. Cross-key limit stated honestly in §4. |
| **R3-6 (P2)** — ReturnStolen persistence safe | **FIXED, with one honest open window** | Durable return transaction: park → commit → verify. Return parked in the victim's escrow sidecar under a fresh `ReturnTxId`; victim's verified save persists record + placed copy + marker in one `SetAsync`; thief's save is best-effort with rejoin rule (b) as backstop; `_preSaveHookDepth` keeps the leave/shutdown save single-owner. Tests 13–16 + lifecycle 07/08. **Open:** partial-outage loss (W4-analog, confirmed by scratch D4a) and an untested 5-condition duplication residual (see §4). |
| **R3-7 (P3)** — Partial `MutationApplied` data over `BaseUpdate` | **FIXED** | The partial send is deleted outright; `RebuildBase` now fires a full snapshot for placed *and* unplaced mutations. `ApplyBaseUpdate` defensively ignores non-snapshot payloads for state (still forwards them to the shop). Mutation-payload suite 34/34 + 32/32. |
| **R3-8** — Remaining lower-priority risks | **REVIEWED; 3 fixed, rest deferred with reasons** | Fixed: owned-nil/placed-non-nil seed heal + double-charge guard; `reinsertPlacedRecord` ownership guard (fail-closed); per-action 0.25 s throttle. Deferred: legacy escrow records (no admin tool exists), `SaveData` `_saving` timeout, BindToClose budget, further cross-link gaps, R6 crash windows. Detail in §4 and `/tmp/r38_review.md` (worker scratch, not in the tree). |

### R3-3 correction note — the audit's SaveData claim did not match the code
The task stated `SaveData()` checks the `pcall` success of a function that calls `deleteSidecar` but ignores the boolean it returns. Reading the current code showed that bug exists only in the **old** code (preserved in `mutant/DataServiceOld.luau`, ~lines 710–716), not in the current code: the R2-era `SaveData` already checks `deleteSidecar`'s boolean per key and keeps the retry flag until deletion genuinely succeeds. The remaining R3-3 hole was the missing processed/paid marker, which is what was fixed (TxId ledger + `commitPendingPayment`). The mutant control 03 proves the old shape fails and the new shape holds.

### R3-1 note — GetAsync outage vs UpdateAsync
With the append path moved to `UpdateAsync`, a `GetAsync` outage no longer fails an append at all (there is no separate read in the path) — the append succeeds with the old entry intact. The tests assert the protected invariant (old entry intact) and cover the failure mode that can occur in the new path (`UpdateAsync` failing → `false`, nothing touched).

## 2. Files changed

`git diff --stat HEAD`: **19 tracked files, +3273/−212→−265 cumulative** (Phase 1 + R1 + R2 + R3; HEAD predates all of them, so R3-only attribution below is by code tags and worker records, not by git).

| File | R3 change |
|---|---|
| `src/server/Services/DataService.luau` | R3-1: `readSidecar` → `(ok, value)`; `writeSidecar` deleted; per-key merge/save/delete handling. R3-2: `appendSidecar` via `UpdateAsync`, identity dedupe. R3-3: `ProcessedRewardTxns` guard, `sidecarIdentity`, TxId-aware merge, per-key delete flags. R3-6: `ParkReturnEscrow`, `mergeEscrowRecord` marker-skip/record, `ReturnedTxns` guard. |
| `src/server/Services/RaidService.luau` | R3-3/4/5: `newRewardTxId`, `legacyRewardTxId`, `ensureProcessedLedger`, `commitPendingPayment`, rewritten `recordPendingReward` (delta-per-recording, park-first), rewritten `grantStealReward` (mint → record → verified commit), rewritten `RecoverPendingRewards`. R3-6: `newReturnTxId`, `ensureReturnedLedger`, `buildReturnEscrowRecord`, `parkReturnEscrow`, `ReturnStolen` park→commit→verify, `_preSaveHookDepth`, `ReturnStolen` returns durability. R3-8 residuals: local reinsert guard (return path only), `reconcilePlacedCopy` Mutation fallback. |
| `src/server/Services/MutationService.luau` | R3-7: deleted `MutationApplied` partial send + unused `fireClient`; `RebuildBase` fires for placed and unplaced. R3-8: seed mirror heals placed `Mutation` onto fresh owned records; narrow double-charge guard. |
| `src/server/Services/BaseService.luau` | R3-8: `reinsertPlacedRecord` ownership guard (fail-closed); per-action 0.25 s throttle; `Action` envelopes return before the throttle. |
| `src/client/Controllers/BaseController.luau` | R3-7: `ApplyBaseUpdate` ignores non-snapshot payloads for state, still forwards to shop; extracted `notifyShop`. |
| `src/shared/Economy.luau` | **Not edited in R3.** `StealRewardShare` remains the single share computation (verified unchanged by diff vs HEAD). |

Untracked (new in R3): `docs/R3_REPAIRS_REPORT.md` (this file), `docs/PERSISTENCE_DESIGN_NOTE.md`, and test suites under `scripts/phase1-tests/`:
- `scripts/phase1-tests/persistence/` — new suite, 16 test files (01–16) + `datastore_stub.luau`, `persistence_env.luau`, `run.sh`, `refresh.sh`, `mutant/` (4 controls).
- `scripts/phase1-tests/mutation-payload/` — new suite, 2 test files + `run.sh`, `refresh.sh`.
- `scripts/phase1-tests/lifecycle/07_return_persistence.luau`, `08_return_residuals.luau`; `lifecycle/mutant/make_mutant.sh` anchor (e) updated to the R3 code shape and the mutant rebuilt; `lifecycle_data.luau` `simulateLoad` updated to model the R3 TxId-dedup merge.
- `scripts/phase1-tests/theft/` tests 09–13, `10`, `11` (R2) unchanged by R3; persistence tests 06/07 expectations updated by the R3-4 semantics change (documented, not regressions).

## 3. Validation — every command run and its actual result

All counts below were independently re-run by a validator agent that edited nothing, and (for the lifecycle mutant fix) re-run again by the coordinator after the fix.

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/theft/run_all.sh` | **191/191**, 14 files, exit 0 |
| `bash scripts/phase1-tests/store/run.sh` | **72/72**, exit 0 |
| `bash scripts/phase1-tests/quest/run.sh` | **59/59**, exit 0 |
| `bash scripts/phase1-tests/expedition/run.sh` | **46/46**, exit 0 |
| `bash scripts/phase1-tests/wiring/run.sh` | **10/10**, exit 0 |
| `bash scripts/phase1-tests/lifecycle/run.sh` | **126/126**, 8 files, exit 0 |
| `bash scripts/phase1-tests/persistence/run.sh` | **16/16 files, 273 checks**, exit 0 |
| `bash scripts/phase1-tests/mutation-payload/run.sh` | **66 checks (34 + 32)**, exit 0 |
| **Total suite checks** | **843, 0 failed** |
| `python3 scripts/harness-python.py` | **70/70**, exit 0 |
| `bash scripts/harness-lune/refresh.sh && lune run scripts/harness-lune/main.luau` | **40/40**, exit 0 |
| `luau-compile` all `src/**/*.luau` | **68/68**, 0 failures |
| `luau-compile` all `scripts/phase1-tests/**/*.luau` | **197/197**, 0 failures |
| Rojo 7.7.1 build ×2 into `/tmp` | **Byte-identical**, SHA-256 `25db61afe9236538670c4d7ba1ece8e4cbc166a9da19eb8531372fb577446dec`, 624,476 bytes each |
| `python3 scripts/verify-rbxl.py /tmp/r3-build-a.rbxl` | **8 PASS, 0 failed** (68/68 sources byte-identical in place) |
| `sha256sum GlitchTide.rbxl` (before and after) | `40f0cf4f…`, 558,606 bytes — **unchanged** |

### Negative controls (mutants) — all valid

| Control | Result |
|---|---|
| Theft mutants (`theft/mutant/run_mutant.sh`) | **7/7 valid** (mutants fail as expected) |
| Expedition mutant (`expedition/mutant/run_mutant.sh`) | **1/1 valid** |
| Persistence mutants (`persistence/mutant/run_mutant.sh`) | **4/4 valid** — 01/02 (old `or {}` wipe + old race lose), 03 (no deletion retry; old merge re-pays a processed transaction), 04 (old combine merges two TxIds / replay accumulates) |
| Lifecycle mutant (`lifecycle/mutant/run_mutant.sh`) | **Valid** — 0/4 as expected (`run_mutant: ALL R2-5 MUTANT CONTROLS VALID`). **Note:** this control was broken by the R3 `recordPendingReward` reshape (anchor (e) matched 0 times; the script aborted before running). Fixed during validation: anchor (e) updated to the R3 unconditional-delta shape, mutant rebuilt, control re-run valid, lifecycle suite still 126/126. |

### Refresh / drift checks
Every `refresh.sh` (7 phase1-tests suites + harness-lune) exits 0: "copies match sources apart from require lines". No drift. Quest suite has no `refresh.sh` (hand-written stubs — pre-existing).

### What each harness does and does NOT test
- **Python harness (70):** read-only regex/JSON checks over `src/` — cannot execute Luau or prove runtime behaviour, ordering, or exactly-once semantics.
- **Lune harness (40):** executes only the pure-logic shared modules — no service modules, no DataStore, no remotes.
- **Phase 1/R2 suites (theft/store/quest/expedition/wiring/lifecycle/mutation-payload):** execute the real service modules under Lune with stubbed Roblox globals, fake players/data, no real remotes, no real DataStore, no latency.
- **Persistence suite (new):** loads the **actual** current `DataService` (and, via `newRaidEnv`, the real `RaidService`/`MutationService`/`CarryService`) with a stubbed DataStore API — injectable per-operation/per-key failures, optimistic-retry `UpdateAsync` with version counters, race-window hooks, callback-purity enforcement. It models the DataStore contract; real Roblox contention/latency and real cross-server behaviour are **not** tested.
- **No Studio playtest, no real production DataStore test** is claimed anywhere in this report.

### Bugs found by the tests during R3 (and fixed)
- `RecoverPendingRewards` counted a dropped already-processed entry as paid (using the entry's `Amount`). `commitPendingPayment` now returns `(boolean, amountActuallyPaid)`; recovery counts only coins actually paid.
- `ReturnStolen` returned `true` on a failed victim save (caught by test 15 D1a); it now returns durability.
- The `reinsertPlaced` ownership guard initially broke theft test 07 scenario D (steal-rollback must still restore the placed copy after a sabotaged transfer); scoped to the return fallback path via `enforceOwnership`.

## 4. Remaining risks — stated plainly

### Open durability windows (the honest limits)
- **R3-5 W4 (loss):** if the sidecar park itself fails (`UpdateAsync` outage) *and* the server crashes before any main-profile save succeeds, the reward exists only in cache and is lost. Durability needs at least one of the two keys to accept a write. It degrades safely (pay proceeds, sync save verified, on save failure the entry stays pending for retry — lost only on a crash, not on save failure alone).
- **R3-5 W5 (cross-key limit):** coin change + processed marker are atomic *only within the main profile key* (one `SetAsync`). The sidecar is a separate key; there is no moment both change atomically. A stale sidecar entry can linger after a durable pay (neutralised by the `ProcessedRewardTxns` check on re-merge, deleted on the next load + save). Two servers writing the same player's main key can still last-write-win (pre-existing DataStore limitation, unchanged). The `ProcessedRewardTxns` ledger is never pruned (one small entry per paid reward).
- **R3-6 W4-analog (loss, confirmed by scratch D4a):** escrow park fails *and* victim's save fails *and* the thief-side deletion persists (thief save/autosave/leave-save) *and* a crash before any retry → 0 owners. Needs a partial outage (victim key + escrow fail, thief key succeeds); in a total outage all saves fail, so the thief's stored `InTransit` copy survives and rule (d) recovers.
- **R3-6 residual D (duplication, untested, 5 conditions):** victim's save fails, the Brainrot is re-stolen and delivered, the victim leaves/crashes before ANY victim save lands the marker, the victim rejoins — the merge then applies the stale escrow entry (no marker in the key to invalidate it) and the delivered copy duplicates. Proposed follow-up (not implemented): invalidate the victim's escrow entry at delivery time.
- **R6 save reliability is NOT claimed fixed.** Delivery saves are observed and warned on, but crash windows remain: a crash after commit but before any save still loses the in-memory commit for non-ledgered state (ordinary earnings, XP, unlocks — up to one 60 s autosave interval). The reconciler voids an unpersisted delivery conservatively (victim gets the Brainrot back, thief keeps nothing) and a delivered-but-unsaved steal reward is lost, never re-minted. That is the conservative exactly-once choice, not a durability guarantee.
- **Load-failed durability hole:** sidecars mitigate but do not eliminate it — a crash between sidecar merge and a successful save re-merges safely, but a player who never achieves a successful load still has no durable record. `_loadFailed` sessions play on defaults with saves refused by design (protects the real save); a player who plays a full session on a failed load loses everything earned in that session — only a server `warn`, no client-facing notice (product decision).
- **Policy split (flagged, not fixed):** when *every* save fails, the delivery itself is voided on rejoin (R2 rule: no durable proof → no ownership) while the reward is still recovered exactly once. Paying a reward for a voided delivery is the specified R3-5 outcome; whether that policy is desirable is a product call.
- **Cost note:** every healthy delivery now does a sidecar `UpdateAsync` (park-first) plus a *synchronous* `SaveData` on the delivery path (previously fire-and-forget). Required to know the save succeeded at delivery time; production latency impact not measured.
- **TxId uniqueness across servers is probabilistic** (per-server counter + timestamps), not cryptographic. Cross-server behaviour unproven (two servers, same player).
- **Rule (e) legacy records:** flagged `InTransit` records with no recorded owner stay flagged forever pending manual recovery — deliberate, rather than deleting or granting them. No admin recovery tool exists anywhere in the tree.

### Deferred from R3-8 (with reasons)
- **Legacy escrow records (no `StolenFromUserId`)** — Low, deferred: fix belongs in `RaidService`/`DataService` and there is no safe automatic resolution (guessing an owner risks granting stolen goods). Needs an admin recovery tool (takes `userId, instanceId`, clears the flag after an operator confirms ownership), which does not exist.
- **`SaveData()` `_saving` timeout** — Medium, deferred: 5 s wait then the save is *dropped*; on leave the cache is cleared anyway, so up to ~60 s of progress can be lost when a slow autosave overlaps a leave. Fix (wait longer / retry once after the flag clears on the leave path) lives in `DataService` and was out of R3's file scope for that worker; do NOT "fix" it by removing the `_saving` guard (that reintroduces the R2 double-save race).
- **BindToClose sequential-save budget** — Medium, deferred: healthy store ≈2–8 s for 12 players, but a degraded store burns ~9 s/player in sleeps alone, blowing the ~30 s budget after ~3 players. Fix: concurrent saves (`task.spawn` per player) and/or skip the 5 s `_saving` wait on the shutdown path when an in-flight save already covers that player.
- **Core-service cross-link gaps (beyond R2-6)** — Medium/Low, deferred: `NPCService.SetCombatService` never called and `CombatService` never initialised (NPCs never deal damage); `EnvironmentService.SetEventMode` never called (event lighting stuck on Normal); `RaidService.SetGate` never called, no gate remote (gates always open); `AbilityService.SetLoadout` has no server caller/remote (loadouts unchangeable). Each needs its owning service + `GameManager`.
- **ShopController / FusionService partial (same bug class as R3-7)** — deferred: `ShopController.OnBaseUpdate` still does `baseState = data` unconditionally, and `FusionService` still sends a `FusionResult` partial through `BaseUpdate`. `BaseController`'s new guard forwards partials to the shop, so the fuse watchdog still clears, but the shop's own state can still be corrupted by the partial. Needs the FusionService/ShopController owners.
- **RaidService local reinsert fallback** — now guarded (R3-6, return path only); the steal-rollback path intentionally passes `enforceOwnership = false` (theft test 07 scenario D requires restoring a placed copy after a sabotaged transfer deleted the owned record).
- **Lifecycle fake park half** — the fake's `RecordPendingRewardSidecar` still dedups by `InstanceId` and combines amounts, while the real R3-2 park dedups by TxId. No existing test exercises a second recording for the same instance, so the suite stays green, but the park half of the fake is still old-model. `simulateLoad` was updated to the R3 merge; the park half was left as a known fidelity gap.
- **Lifecycle mutant control caveat:** control `01_mutant_control` fails on ownership assertions driven by anchors (a)–(d), not by anchor (e) — no mutant control directly asserts the missing sidecar park (test 06 covers the sidecar on the fixed code only). Anchor (e)'s role is keeping the mutant a faithful old-behaviour reversion.

## 5. Studio-only tests still required (none verified here)

1. Claim UI end-to-end (from Phase 1): click Claim, reward lands once, button updates, rejected claim shows a reason.
2. STORE button click-through; rapid place→store and collect→store vs the per-action throttle.
3. Live steal → delivery → return with two real clients: carry slowdown + companion bonus, delivery at pedestal, exactly one instance total; death/drop return with all fields; victim offline mid-theft.
4. Camera / pedestal distance in a real place: `PLACE_DISTANCE = 12` against real pedestals; out-of-range delivery rejection while visibly too far.
5. DataStore round-trip: claim, steal/deliver, store, then rejoin — committed state persisted, no duplicate/lost instance after rejoin. **This is the Studio test that matters most for R3** (real `UpdateAsync` contention, real `SetAsync`/`RemoveAsync` failure modes, real `BindToClose` timing).
6. 12-player behaviour: concurrent steals/returns, poll timing under load, rate limits under real latency; BindToClose budget with 12 players under a degraded store.
7. `PollInTransit` timing: 5 s cadence, 2 s grace, delivery detection vs `PlaceBrainrot`'s own confirm; no stranded carry visual.
8. Companion carry speed live: 16 × 0.75 = 12 wired vs 16 × 0.6 = 9.6 unwired.
9. Quest push delivery: client receives exactly the pushes sent.
10. Delivered-copy fields after theft: banked income and `PlacedAt` surviving live steal → delivery.
11. Mutation mirror live: two same-character instances, one placed + glitched — right instance flagged, real mutation never clobbered.
12. Mutation visual re-apply via `RebuildBase` after `MutateBrainrot`, and the watchdog-reconciled model's appearance (harness-observable only as fields/rebuild counts).
13. Throttle behaviour by firing remotes: Collect then Store within 250 ms — both must land (per-action throttle).
14. Leave-save under a slow store: leave during a slow autosave and confirm no silent progress loss (R3-8 §2).
15. Cross-server: same player, two servers (not possible to test meaningfully in Studio alone — needs a live multi-server scenario).
16. `FusionResult` partial through `BaseUpdate`: fuse and confirm the shop's base state is not corrupted (R3-7 residual).
17. NPC combat, event lighting, gates, and loadout changes live (R3-8 wiring gaps, if those follow-ups are ever implemented).
