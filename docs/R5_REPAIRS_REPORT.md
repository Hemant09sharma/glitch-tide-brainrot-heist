# R5 Repairs Report — GLITCH TIDE: Profile Destruction (R5-1) + Fail-Open Escrow Invalidation (R5-5)

**Release:** v1.1.0, Phase 1 + R1 + R2 + R3 + R4-core + R5 (uncommitted working copy)
**Scope of this report:** begun by Worker A (R5-1, R5-5, §§0–6); extended by Worker C (§§7–9, R5-3/R5-4), Worker D (§§10–12, R5-2/R5-7) and Worker E (§13, R5-8); closed by the R5 docs closer (§14, R5-6; line-number refresh throughout; §1 table). All rows R5-1..R5-8 are now documented — no stubs remain.
**Base:** HEAD `6ee6d21` — unchanged by this work
**Date:** 2026-11-20
**Status:** R5-1 and R5-5 fixed at the service level (Lune-verified, negative-controlled). No Studio playtest has ever run.

## 0. Basis and honesty notes

- The R4 audit file (`AUDIT_REPORT_R4.md`) never arrived on disk; both findings below were verified directly against the code before being fixed, following the finding descriptions in the task. No audit details were invented.
- Nothing was committed, pushed, branched, or published. The committed `GlitchTide.rbxl` was **not** rebuilt (SHA-256 `40f0cf4f…`, 558,606 bytes, verified unchanged before and after — see §3). Fresh Rojo builds in this report went to `/tmp/r5a-build-{a,b}.rbxl` only. No R5 ZIP was built (the coordinator packages it).
- No economy change was made by Worker A. The N5 banked-income design remains a proposal only. `src/shared/Economy.luau` was **not** edited by Worker A.
- `RaidService.luau` was **not** edited by Worker A: R5-5 required no change there (ConfirmDelivery already fails closed — verified end-to-end, see §1). `ProgressionService.luau` was **not** touched by Worker A (another worker owns it — R5-6, see §14). At round level this 'not edited' claim is Worker-A-scoped only: `RaidService.luau` WAS edited in R5 by Worker C (R5-3 reward voids, §7) and Worker D (R5-2 session-health gates, §10).
- A test counts as proof only when it reproduces the original failure against the old behaviour (negative control) and passes on the fixed code. Both R5 fixes below have both, run in that order: failing tests first (old code), then the fix, then the same tests green, then the mutant controls. The negative controls live in `scripts/phase1-tests/r5-transactions/mutant/` and assert the OLD bad outcome; both pass (see §3).
- Toolchain note: `/tmp` had been wiped at the start of this work, so Lune 0.11.1, Luau 0.747 (`luau-ubuntu.zip` — the `luau-0.747-linux.zip` asset name 404s) and Rojo 7.7.1 (tag `v7.7.1`, not `7.7.1`) were re-downloaded from GitHub releases to `/tmp/lune-0.11.1/`, `/tmp/luau-0.747/`, `/tmp/rojo-7.7.1/`.
- Shared-directory note: `scripts/phase1-tests/r5-transactions/` is shared with the other R5 workers (the R5-6 worker's `06_rebirth_prestige.luau`, `refresh_06.sh`, `run_06.sh`, `services/ProgressionService.luau` and `mutant/ProgressionServiceOld.luau` + `m01_rebirth_prestige_old.luau` were already there). This worker's files are namespaced to avoid collisions: `run.sh` runs ONLY `01_*`/`02_*` (not 06); the mutant scripts are `make_mutant_r5_1_5.sh` / `run_mutant_r5_1_5.sh` (the shared `make_mutant.sh` / `run_mutant.sh` are the R5-6 worker's and were not touched). This worker's `refresh.sh` copies only DataService + the shared modules (identical content to the R5-6 copy of `shared/`). The R5-6 test was re-run after this worker's DataService change and still passes 70/70 (see §3).

## 1. Finding-by-finding status (Worker A)

| Finding | Status | Evidence |
|---|---|---|
| **R5-1 (P0)** — GetDataStore failure treated as a successful load → default profile becomes saveable → store recovers → SaveData overwrites the genuine profile with defaults | **FIXED** | `LoadData` no longer treats a missing store as success: `loadOk` starts `false` and is true only when a store was obtained AND its `GetAsync` genuinely succeeded; `_loadFailed[player] = (not loadOk)`. The success path (lease + sidecar merge + daily bonus) moved verbatim into `finishSuccessfulLoad`, shared with the new explicit reload path `DataService.RetryLoad(player)`: it re-attempts the load and ONLY on a genuine successful load replaces the cache, clears `_loadFailed`, acquires the lease, merges sidecars and applies the bonus; any failure leaves the cache untouched and the session unsaveable; a healthy session is a no-op (returns the cached data — re-reading would discard in-session progress). `SaveData` already refused on `_loadFailed`, and `GetSaveWarning` already reports `load_failed` — both now trigger for a GetDataStore failure with no further change (GameManager fires the warning on join; HUD banner is the existing R4-8 path). Test 01 (24/24); mutant m01 (5/5) wipes the profile under the old code (5000 → 150 coins, keepsake gone). |
| **R5-2 (P0)** — Block ownership operations in unhealthy sessions: check BOTH thief and victim save/session status before a theft, delivery or place/store; reject steals from or into load-failed, contested or session-lost profiles; recovery paths stay ungated | **FIXED** | `sessionBlockedReason` / `verifySessionLease` (stored-lease proof) / `checkSessionHealth` gate RaidService StealBrainrot (gates #1/#2) and ConfirmDelivery (before the escrow invalidation), plus BaseService Place/Store gates. Test 05 (77/77); mutant m05 (18/18) loses the instance under the old code. Decision item (Worker A §C) CLOSED: load-failed delivery refused, no tombstone, victim recovers via escrow, exactly 1 owner. See §10. |
| **R5-3 (P1)** — Durable reward voiding independent of cache state: a void must not depend on the reward being in the in-memory PendingRewards table; a voided delivery must never receive a reward | **FIXED** | Instance tombstone `void-inst-<InstanceId>` parked in the thief's pending sidecar by `DataService.RecordRewardVoidForInstance` (plus per-TxId voids when TxIds are known); `mergeSidecars` refuses every reward entry for a voided instance; `voidPendingRewardsForInstance` returns `(voided, durable)` and an unpersistable void stays pending for retry (`RetryPendingVoids`) with the recovery reported remaining, not resolved. Test 03 (40/40); mutant m03 (6/6) pays the voided reward under the old code. See Worker-C section §7 below. |
| **R5-4 (P1)** — Session lease races: cached-lease extension without ownership proof; no revalidation after the _saving wait or before SetAsync retries; failed lease read falling back to the cached lease | **FIXED** | Stored-lease verification on every check; failed reads resolved by an atomic UpdateAsync proof (this server proves ownership, another live owner proves loss, a failed proof refuses that attempt only); cached expiry extended only on a result confirming this server; post-wait + per-attempt revalidation in `SaveData`; `GetSessionLeaseState` exposes the contested state. Test 04 (32/32); mutant m04 (12/12) overwrites the newer profile under the old code. See Worker-C section §8 below. |
| **R5-5 (P2)** — Fail-open escrow invalidation: `InvalidateReturnEscrow()` returns success when GetDataStore fails to provide a usable store | **FIXED** | The no-store branch now fails closed: `(false, false, "datastore unavailable", nil)` instead of `(true, false, nil, nil)`. A missing store is not an empty sidecar — the victim's sidecar may hold a stale return this server cannot see. `ConfirmDelivery` needed NO change: its `invalidateStaleReturnEscrow` wrapper already returns `(false, reason)` when the invalidation fails, and `ConfirmDelivery` already returns `(false, "delivery escrow invalidation unavailable")` with transit live and no reward — verified end-to-end in test 02 §A. The post-yield ownership revalidation (`_inTransit` + ownership re-check after the invalidation) is untouched and is proven preserved by test 02 §D (a return landing mid-invalidation via the stub's `_beforeCommit` hook still wins: `"theft resolved during delivery"`). Test 02 (36/36 — rewritten by Worker D for the healthy-thief flow; was 35/35 pre-rewrite); mutant m02 (6/6) returns success during the outage, commits the delivery, and ends with 2 owners under the old code. |
| **R5-6 (P2)** — Reservation-blind Rebirth/Prestige: the direct-assign coin reset wipes a pending reward's reserved coins inside its verified-save window, and the requirement is judged on the raw balance | **FIXED** | `ProgressionService.luau` only (+65/−4): `reservedCoins` / `spendableCoins` / `resetCoins` (StartingCoins + reserved); Rebirth and Prestige judge the requirement on spendable coins and reset via `resetCoins`. Test 06 (70/70); mutant m01 (26/26) wipes/eats the reward under the old code. Pre-fix reproduction: 56 passed, 14 failed (of 70). No economy values changed. See §14. |
| **R5-7 (P2)** — Unbounded sequential pre-save hooks in BindToClose (~42 simulated seconds for six players in a degraded store, before the parallel save phase) | **FIXED** | `RunShutdownHooks` (one task per player, bounded 10 s budget) + per-player serialised `runPreSaveHooks` + `RunPreSaveHooks` / `GetShutdownHookStats`; BindToClose uses the bounded phase. Test 07 (37/37 — new parallel total 16 s for 1/6/12 players vs old sequential 42 s / 84 s); mutant m07 (21/21) blows the budget under the old code. See §11. |
| **R5-8 (P2)** — Stale mutant-builder anchors (theft R13, lifecycle sidecar, r4 R4-4/R4-7) aborting the negative controls; hardcoded luau-compile path in the r4 mutant runner | **FIXED** | Anchors re-anchored to the current source in the theft, lifecycle and r4-transactions builders; `LUAU_COMPILE` env-configurable in the r4 runner. Theft 7/7 controls valid, lifecycle 1/1, r4 7/7, expedition + persistence + all r5 runners green. See §13. |

**Round-level note (R5 docs closer, 2026-11-20).** Final verified round totals: **1447 checks, 0 failed** (Worker-D/E figures); Rojo ×2 byte-identical, SHA `1bf97d32…`, 676,532 bytes; luau-compile src **68/68** + tests **284/284**. These supersede the earlier per-worker snapshots in this report (§3: 1260 checks, Rojo SHA `1ae1ae4b…`, 657,789 bytes, tests 270/270; §9: 1332 checks, Rojo SHA `9532f52b…`, 667,530 bytes, tests 276/276) — those tables are kept as historical records of what each worker ran, not as the round totals. §§12–13 carry the final figures.

## 2. Files changed (Worker A)

`git diff --stat HEAD` is not attributable per round (HEAD predates Phase 1 + R1 + R2 + R3 + R4 + R5, all uncommitted); R5 attribution below is by code tags and the line ranges in the current source. The pre-fix source is preserved verbatim as the mutant snapshot `scripts/phase1-tests/r5-transactions/mutant/DataServiceR4.luau`; `diff` of current `src/server/Services/DataService.luau` against it (modulo the require patch) is exactly the two changes below.

| File | R5 change (line ranges in the current source) |
|---|---|
| `src/server/Services/DataService.luau` | R5-1: `attemptLoad` 1876 (factored GetAsync retry loop, shared by LoadData + RetryLoad), `finishSuccessfulLoad` 1913 (lease + merge + bonus, moved verbatim from LoadData), `LoadData` 1984 (`loadOk` starts false; `_loadFailed = (not loadOk)`; early return on failed load), `RetryLoad` 2037 (explicit reload path; `(true, data)` iff healthy and saveable, else `(false, reason)`). R5-5: `InvalidateReturnEscrow` 1479, no-store branch returns `(false, false, "datastore unavailable", nil)` at 1491 (+ doc-comment correction). No other function in the file was touched. |
| `src/server/Services/RaidService.luau` | **Not edited.** R5-5 required no change: `invalidateStaleReturnEscrow` + `ConfirmDelivery` already fail closed on an invalidation failure, and the post-yield revalidation is intact. |
| `src/shared/Economy.luau` | **Not edited.** |

Untracked (new in R5, Worker A): `docs/R5_ACCEPTANCE_CHECKLIST.md` (this worker's rows filled; other rows stubs), `docs/R5_REPAIRS_REPORT.md` (this file), and the test suite under `scripts/phase1-tests/r5-transactions/`:
- `scripts/phase1-tests/r5-transactions/` — new suite: `r5_env.luau` (GetDataStore outage injection + unloaded-pair fixtures), `01_r5_1_profile_destruction.luau`, `02_r5_5_fail_open_escrow.luau`, `run.sh` (runs 01/02 only — the directory is shared), `refresh.sh` (DataService + shared copies, R5 structural anchors), `services/DataService.luau` (refreshed copy), `shared/` (15 modules, refreshed copies), `mutant/` (Worker-A files only: `DataServiceR4.luau` static pre-fix snapshot, `m01_r5_1_old_logic.luau`, `m02_r5_5_old_logic.luau`, `make_mutant_r5_1_5.sh`, `run_mutant_r5_1_5.sh`).

## 3. Validation — every command run and its actual result (Worker-A snapshot — historical; final round totals in the note after §1)

### Failing-first reproduction (before the fix, against the then-current source)

| Command | Result |
|---|---|
| `/tmp/lune-0.11.1/lune run scripts/phase1-tests/r5-transactions/01_r5_1_profile_destruction.luau` | **3 passed, 6 failed (of 9)** — checks 02/03/04 (saveable, no `load_failed` reason, no SaveWarning), 07 (no RetryLoad), 08 (SaveData lands after recovery), 09 (stored profile wiped: **storedCoins=150**, keepsake gone). The Qwen wipe, reproduced. |
| `/tmp/lune-0.11.1/lune run scripts/phase1-tests/r5-transactions/02_r5_5_fail_open_escrow.luau` | **20 passed, 15 failed (of 35)** — check 01 (invalidation claims success during the outage), 04 (delivery commits during the outage), 05/06 (transit cleared, reward pending), 09 (recovery retry: "not carrying that Brainrot" — already delivered), 11/12/14 (no tombstone, no live-ledger marking), 17/18 (thief's post-recovery save lands, stored key holds the copy), 19/20/22/23/24 (victim rejoin resurrects the copy; **total owners = 2**). Checks 25–30 (post-yield revalidation) and 31–35 (direct invalidation with the store up) already passed on the old code — the defect is only the no-store path. |

### New suite + negative controls (after the fix)

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/r5-transactions/run.sh` | **2/2 files, 59 checks, 0 failed** — 01 R5-1 24/24; 02 R5-5 35/35; static anchors OK (SaveWarning remote + GameManager fire + HUD ShowSaveWarning + RetryLoad present + `loadOk = store == nil` absent + `datastore unavailable` present). |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh` | **2/2 negative controls passed** — m01 5/5 (old code: outage load saveable, no SaveWarning, no RetryLoad, post-recovery SaveData lands, stored profile wiped 5000 → 150 coins, keepsake gone), m02 6/6 (old code: invalidation claims success during the outage, delivery commits, thief's post-recovery save lands, stored key holds the copy, victim rejoin resurrects it, **2 owners**). Each control asserts the OLD bad outcome; a control passing proves the matching fixed test discriminates. |
| `bash scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_1_5.sh` | **OK: mutant guarded** (static pre-fix snapshot; anchors verified — old behaviour present, fixes absent; refuses to snapshot fixed code). |

### Existing suites (all re-run after the R5 edits; no test weakened or deleted)

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/persistence/run.sh` | **16/16 files, 273 checks**, exit 0 |
| `bash scripts/phase1-tests/r4-transactions/run.sh` | **10/10 files, 222 checks, 0 failed**; static anchors OK |
| `bash scripts/phase1-tests/theft/run_all.sh` | **191/191**, 14 files, exit 0 |
| `bash scripts/phase1-tests/store/run.sh` | **72/72**, exit 0 |
| `bash scripts/phase1-tests/quest/run.sh` | **59/59**, exit 0 (run with `/tmp/lune-0.11.1` on PATH — pre-existing script quirk) |
| `bash scripts/phase1-tests/expedition/run.sh` | **46/46**, exit 0 |
| `bash scripts/phase1-tests/wiring/run.sh` | **10/10**, exit 0 |
| `bash scripts/phase1-tests/lifecycle/run.sh` | **126/126**, 8 files, exit 0 |
| `bash/scripts/phase1-tests/mutation-payload/run.sh` | **66 checks (34 + 32)**, exit 0 |
| `bash scripts/phase1-tests/fusion-payload/run.sh` | **66 checks (44 + 22)**, exit 0 |
| `bash scripts/phase1-tests/r5-transactions/run_06.sh` (other worker's R5-6 test, re-run as a courtesy after this worker's DataService change) | **70/70**, exit 0 |
| **Total suite checks (existing + R4 + R5-Worker-A + R5-6)** | **1260, 0 failed** (1131 baseline + 59 R5-1/R5-5 + 70 R5-6) |
| `python3 scripts/harness-python.py` | **70/70**, exit 0 |
| `bash scripts/harness-lune/refresh.sh && /tmp/lune-0.11.1/lune run scripts/harness-lune/main.luau` | **40/40**, exit 0 |
| `luau-compile` all `src/**/*.luau` | **68/68**, 0 failures |
| `luau-compile` all `scripts/phase1-tests/**/*.luau` | **270/270**, 0 failures (was 244 in R4; +26: 7 Worker-A r5 files + 15 r5 shared copies + 4 R5-6 files) |
| Rojo 7.7.1 build ×2 into `/tmp/r5a-build-{a,b}.rbxl` | **Byte-identical**, SHA-256 `1ae1ae4b9e0fc7513ec7ff2ba29876b1dd0cc68f317d7d8bb8ca2eac4c6b4072`, 657,789 bytes each (larger than R4's 654,450 because it includes the R5 DataService changes + the other worker's in-progress ProgressionService changes) |
| `python3 scripts/verify-rbxl.py /tmp/r5a-build-a.rbxl` | **8 PASS, 0 failed** |
| `sha256sum GlitchTide.rbxl` (before and after) | `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`, 558,606 bytes — **unchanged** |

Note on the total: the 1131 baseline (R4 report) counts existing + R4 + fusion-payload checks. This round adds the 59 Worker-A R5 checks (01: 24 + 02: 35) and the other worker's 70 R5-6 checks, which run in the same shared tree: 1131 + 59 + 70 = **1260**. The per-suite rows above are the authoritative figures.

### Refresh / drift checks
Every `refresh.sh` run in this round (theft, persistence, store, r4-transactions, r5-transactions, harness-lune) exits 0: copies match sources apart from require lines. No drift. The r5 `refresh.sh` anchors (RetryLoad present, `loadOk = store == nil` absent, `datastore unavailable` present) pass on the fixed source and demonstrably fail on the pre-fix source (observed during the failing-first run).

### What each harness does and does NOT test
- **Python harness (70):** read-only regex/JSON checks over `src/` — cannot execute Luau or prove runtime behaviour.
- **Lune harness (40):** executes only the pure-logic shared modules — no service modules, no DataStore, no remotes.
- **Phase 1 suites:** execute the real service modules under Lune with stubbed Roblox globals, fake players/data, no real remotes, no real DataStore, no latency.
- **R5-transactions suite (new):** loads the actual current `DataService` + `RaidService` with the same stubbed DataStore plus GetDataStore outage injection (`r5_env.setDataStoreOutage` — the `GetDataStore` closure errors while the flag is set; `store:seed`/`store:peek` bypass it, exactly as the real DataStore keeps its data while the API handle is unavailable). One modelling limit matters for both R5 tests: `DataService` caches a successful store handle for the life of the module (`_store`), so a GetDataStore outage can only be simulated BEFORE the first successful `getStore()` call in a Lune process — each test file therefore runs its outage phase first. That matches production (a server that never obtained a store), but a mid-session loss of an already-cached handle cannot occur in either.
- **No Studio playtest, no real production DataStore test** is claimed anywhere in this report.

## 4. Design notes (Worker A)

### R5-1: a missing store is a failed load, full stop
The old `loadOk = store == nil` treated "no store" as "Studio, nothing to fail". That was wrong in both cases it covers: in a live server `GetDataStore` only returns nil when it errored (outage), and in Studio it only returns nil when API access is off (in which case the real profile is equally unread). There is no legitimate "no store, load anyway" case — Studio WITH API access returns a real store. The fix therefore makes no Studio exception: any `GetDataStore` failure is a failed load. Consequences, all intended: the session is unsaveable (`IsSaveable` false, `SaveData` refuses — that refusal predates R5 and is now reachable for this failure mode), the daily bonus is skipped (it previously fired on the unread profile), and `GetSaveWarning` reports `load_failed` so the existing GameManager → `SaveWarning` remote → HUD banner path notifies the player. The only caller-visible new API is `RetryLoad`; `LoadData`'s contract is unchanged for every load that actually reads the store (verified by the untouched persistence/r4/theft suites).

### R5-1: RetryLoad semantics
- Only acts on a failed-load session. A healthy session is a no-op `(true, cached data)` — re-reading would discard in-session progress. A never-loaded player is `(false, "no_cache")`.
- On failure the cache is untouched. In particular a `RetryLoad` during an ongoing outage returns `(false, "datastore_unavailable")` without touching anything.
- On success it runs the SAME `finishSuccessfulLoad` as a fresh join (lease acquire → sidecar merge → daily bonus), so recovery cannot diverge from join behaviour. If the lease is contested elsewhere it returns `(false, "session_contested")` — the session stays unsaveable, correctly.
- It discards in-session unsaved progress by design (the genuine profile is the authority). It must not be called while the session holds unpersisted theft state: the in-transit/delivered record lives in the cache and would be replaced by the stored profile. The safe recovery order is: `RetryLoad` BEFORE any theft in the recovered session, or rejoin (which reloads the same way). GameManager does not call `RetryLoad` today — there is no in-session caller yet; rejoin is the existing recovery path and `RetryLoad` is the explicit API for one.

### R5-5: fail closed, and what "empty" means
`InvalidateReturnEscrow` now has exactly three outcomes: `(true, false)` — the escrow was READ and holds nothing stale for the instance (a real empty sidecar); `(true, true, staleTxIds)` — a tombstone was parked; `(false, ...)` — the invalidation could not be proven, including an unavailable store. The old no-store branch returned the first outcome without reading anything — that is the fail-open, and it is gone. No `RunService:IsStudio()` carve-out was added: the API cannot distinguish "Studio with API access off" from "live-server outage", and the task requires failure whenever the invalidation cannot be performed.

## 5. Remaining risks and follow-ups — stated plainly (Worker A)

1. **R5-1 × R4-1 (loss, not duplication):** a delivery committed in-memory in a load-failed session can never persist (R5-1: the session can never save), yet its tombstone permanently supersedes the victim's escrow backstop. If both players rejoin before any successful thief save, the instance has **0 owners** (test 02 §C asserts 0, not 2). The pre-existing R6 rule (an unpersisted delivery is voided on rejoin and the victim recovers) is NOT honoured in this corner, because the tombstone blocks the escrow path. Fix options for the coordinator: (a) gate `ConfirmDelivery` on thief saveability when a stale escrow exists for the instance (refuse the delivery, keep the transit live — the thief can re-steal after `RetryLoad`, and the victim recovers via escrow); (b) leave it as the honest outage cost. NOT implemented here — it changes delivery semantics beyond the R5-5 task, and needs a product decision.
2. **Pending reward for an undurable delivery (R4-4 policy interaction):** a recovery delivery in a load-failed session parks its reward pending (sidecar + cache). On the thief's rejoin the pending entry merges and `RecoverPendingRewards` would pay it, even though the delivered Brainrot never persisted — the R4-4 policy ("reward eligibility follows the delivery transaction's durable fate") has no void for this case, because no durable theft record exists for the reconciler to void. Needs a coordinator decision; deliberately NOT asserted in test 02.
3. **SaveWarning banner staleness after RetryLoad:** a successful `RetryLoad` clears `GetSaveWarning`, but nothing re-fires to clear the HUD banner mid-session — GameManager fires `SaveWarning` only on join, and DataService has no remote-fire path. Follow-up (GameManager-owned, out of this worker's scope): after a successful `RetryLoad`, fire the `SaveWarning` remote with nil (HUD `ShowSaveWarning(nil)` hides the banner) or add a recovery signal.
4. **Studio with API access off:** loads now fail (warning shown, unsaveable) instead of silently playing on defaults, and deliveries are refused. Saves there were already no-ops, so no persisted data is affected; Studio with API access enabled is unaffected. If the Studio dev experience needs in-memory deliveries without a store, that is a product decision — it would reintroduce exactly the fail-open R5-5 closes, so it should not be a silent carve-out.
5. **`PERSISTENCE_DESIGN_NOTE.md` not updated by this worker** (outside the assigned edit scope): §5a should gain the R5-5 fail-closed rule (unavailable store ⇒ `(false, "datastore unavailable")`) and §6 the R5-1 rule (missing store ⇒ failed load) + the `RetryLoad` contract. Coordinator's call.
6. **R6 save reliability is NOT claimed fixed** (unchanged): a crash after an in-memory commit but before any save still loses the commit for non-ledgered state (up to one 60 s autosave interval).
7. **No Studio playtest or real production DataStore test** has been run against any of this. All verification is Lune/harness-level with a stubbed DataStore API that models the contract. Studio-only tests still required (from the R4 report, still open): load-failed client notice live (banner appears, stays, no overwrite on rejoin) — now also: banner clears after an in-session recovery, if follow-up (3) is implemented.

## 6. Studio-only tests still required (Worker A additions; R4's list of 19 still stands)

1. Load-failed client notice live, with the R5-1 change: block the profile key (or disable API access) and confirm the red `SaveWarning` banner appears on join, stays visible, and no progress from that session overwrites the genuine profile on rejoin — including when the store recovers mid-session and the player keeps playing without rejoining (SaveData must still refuse until an explicit reload).
2. In-session recovery live: after the store recovers, drive `RetryLoad` (server console) and confirm the genuine profile loads, the session becomes saveable, and the banner clears (once follow-up §5.3 lands).
3. Delivery during a store outage live: with the DataStore API down from server start, confirm a delivery is refused, the thief keeps carrying, and after recovery the retry succeeds with exactly one owner — and no duplicate after both players rejoin.

---

## 7. Worker C — R5-3 (P1): durable reward voiding independent of cache state

### The defect, reproduced first

Qwen's exact reproduction: a reward exists in the pending sidecar; its read fails during rejoin; the Brainrot is returned to the victim; the void function finds no in-memory `PendingRewards` entry and returns; the sidecar later becomes readable; the reward gets paid even though the delivery was voided. Pre-fix reproduction (test 03 run against the pre-fix code): 24/40 passed; the discriminators failed exactly as expected, including check 08 — the old code paid the voided reward (paid=1, total=300, thief coins 100300).

### What changed

`src/server/Services/RaidService.luau`:

- `voidPendingRewardsForInstance(player, instanceId)` (line 2762) — rewritten. There is **no early return when the cache has no entry**: it records `VoidedRewardTxns` + `VoidedRewardInstances` in the thief's loaded data, removes any pending entry, and returns `(voidedTxIds, durable)`. New local helper `persistVoid(player, instanceId, txIds)` (line 2727): leg 1 = park the void tombstone via `DataService.RecordRewardVoidForInstance` (or the per-TxId fallback for an older DataService); leg 2 = a main-profile save persisting the void ledgers (also run after a successful park, as a second leg; skipped inside the pre-save hook when `_preSaveHookDepth > 0`, where the coordinated leave save is the single save owner). **Durable iff either leg landed.** On failure the void is recorded in the new module table `_pendingVoids[player][instanceId]` (line 115) and a loud warning is emitted.
- `RaidService.RetryPendingVoids(player)` (line 2846) → `(parkedNow, stillPending)`, retrying with the same stable identifiers. Called before any payment in `RecoverPendingRewards` (line 2599), at the start of `RecoverOnRejoin` (line 3163), and in `HandlePlayerLeaving` (line 2878 — placed **inside** the `_preSaveHookDepth` region on purpose, so the retry's save leg is skipped and the hook never saves; the coordinated leave save persists the ledgers).
- `RecoverStaleTransit` rules (b) (line 3018), (d)-online (line 3116) and (d)-offline (line 3132) now check durability: if the void is not durable, the instance counts as `remaining` (not `resolved`). `commitPendingPayment` (line 678) also refuses TxIds of a voided instance (defence in depth).

`src/server/Services/DataService.luau`:

- `DataService.RecordRewardVoidForInstance(player, instanceId, txIds?)` (line 1591) — parks an instance-level tombstone `{Voided=true, VoidInstance=true, TxId="void-inst-<instanceId>"}` in the thief's pending sidecar, plus per-TxId void entries for TxIds known from the cache or a best-effort sidecar read (a failed read never fails the void). The tombstone's TxId is stable, so re-parks are idempotent via `appendSidecar` dedupe. Returns `(true, voidedTxIds)` iff the tombstone landed; `(false, knownTxIds, err)` otherwise.
- `mergeSidecars` (line 1156; void handling lines ~1257–1361) processes tombstones **first**: records `data.VoidedRewardInstances[instanceId]`, drops all TxIds of that instance out of in-cache pending entries (recording each in `VoidedRewardTxns`), and refuses every reward entry for the instance on any later merge (recording its TxId voided). New ledger `VoidedRewardInstances`, guarded in `applyDefaults` (line 298; ledger guard ~378).

### Design decisions

- The void does **not** depend on the in-memory `PendingRewards` table or on a successful pending-sidecar read. The durable source chosen is the pending sidecar itself (the tombstone is written into it), with the thief's main profile (`VoidedRewardInstances` / `VoidedRewardTxns` ledgers) as the second leg.
- A failed `RecordRewardVoidSidecar` / tombstone park is checked: if the void cannot be persisted, the recovery step is **not** silently finished — the instance is reported `remaining` and the void is kept pending for retry (`_pendingVoids` + `RetryPendingVoids`).
- In §B of test 03 the thief's per-key SetAsync failure is deliberately kept armed during `RetryPendingVoids`, so the retry's durability comes only from the tombstone park and the tombstone stays observable in the sidecar; the wrapper is restored after §B.
- **Independent re-read catch (fixed before delivery):** the first placement of the `RetryPendingVoids` call in `HandlePlayerLeaving` sat *before* the `_preSaveHookDepth` increment, so `persistVoid`'s save leg would have saved inside the leave hook, violating the single-saver rule. It was moved inside the hook region (line 2878); all suites were re-run green after the move.

### Validation

- New test `scripts/phase1-tests/r5-transactions/03_r5_3_durable_reward_voiding.luau` — **40/40**: §A Qwen repro (pending read fails at rejoin, void with no cache entry, sidecar readable later → 0 paid); §B void UpdateAsync fails AND fallback save fails → `remaining==1`, retry lands tombstone; §C main-profile save fails after the void → tombstone leg alone refuses on next merge; §D repeated recovery/reload → 0 paid, exactly 1 tombstone, exactly 1 voided TxId; §E successful save persists the void ledger and deletes the sidecar, ledger alone still refuses.
- Negative control `scripts/phase1-tests/r5-transactions/mutant/m03_r5_3_old_logic.luau` (against the pre-fix `mutant/RaidServiceR4.luau` snapshot) — **6/6**: old `RaidService` pays the voided reward (paid=1, total=300, coins 100300), parks no tombstone, has no `RetryPendingVoids`.

### Remaining limits (R5-3)

1. **W4-analog (narrowed, not closed):** if the tombstone park fails AND the fallback main-profile save fails AND the server crashes before any retry succeeds, the void exists only in memory (`_pendingVoids` is in-memory only) and the sidecar reward entry can pay on rejoin — durability needs at least one key to accept a write.
2. **Residual crash window (pre-existing R4-4 shape, narrowed not closed):** a crash between `ReturnStolen`'s thief save (which persists the still-pending entry) and the void park would leave the pending entry in the main key; the void's own save leg closes the common case, but the window is not eliminated.
3. A void is recorded only when recovery resolves back to the victim; a void recorded while the return itself keeps failing is never attempted (R4-4 rule unchanged).

## 8. Worker C — R5-4 (P1): session lease races

### The defects, reproduced first

Four defects, all reproduced against the pre-fix code (test 04 run against the pre-fix code: 13/32 passed; failures were the lease-race overwrites plus missing-new-API guards): (1) `refreshSessionLease` extended the LOCAL cached expiry even when the stored lease belonged to another server (the `UpdateAsync` result was never checked); (2) `SaveData` checked the lease only BEFORE the `_saving` wait, so a lease lost DURING the wait still let the save land; (3) `SaveData` never revalidated before `SetAsync` retries; (4) a failed lease read fell back to the cached lease and authorised the write blindly (the R4 partition limit).

### What changed — `src/server/Services/DataService.luau`

- `acquireSessionLease(player)` (line 453) now returns `(acquired, result)` where result is the post-update lease value. New helper `tryAcquireLease` (line 497) wraps it and marks the session lost when the result proves another live owner; used in both re-acquire branches.
- `checkSessionLease(player)` (line 544) — **the exact rule:** ownership is verified against the STORED lease on every check; a stale cached lease never authorises a write. Stored lease names another live server → sticky `_sessionLost`, refuse. Stored lease names this server (live) → proceed, cache synced from the read. Stored lease missing/expired/corrupt, or no live cached lease → (re)acquire via `UpdateAsync`. **Failed read → atomic proof:** run the same conditional `UpdateAsync`; its result names the owner — this server proves ownership (save proceeds; the R4 test-06 healthy-owner case, now proven instead of assumed), another live owner proves loss (sticky `_sessionLost`), an `UpdateAsync` failure proves nothing and refuses THIS save attempt only (no sticky flag; recorded in the new `_leaseCheckUnverified` table, line 143, cleared in `PlayerRemoving`). This narrows the R4 fallback — it is not a blind fallback to the cache.
- `refreshSessionLease(player)` (line 620) — rewritten, returns boolean; the local cached expiry is extended ONLY when the `UpdateAsync` result actually confirms this server owns the lease; if the result names another live owner it records the observed lease, marks `_sessionLost`, and does not extend; a failed call extends nothing.
- `SaveData(player, opts)` (line 2078) — revalidates the lease AFTER the `_saving` wait (line ~2144), and immediately before EVERY `SetAsync` attempt in the retry loop (line ~2160, clearing `_saving` on refusal).
- New `DataService.GetSessionLeaseState(player)` (line 703) → `{Owned, Contested, Lost, ServerId, LeaseExpiresAt, LastLeaseCheckFailed}` for R5-2 gates/diagnostics; `Owned` is a local view only and never authorises a write by itself.

### Design notes

- The R4 fallback ("failed lease read does not block") is narrowed, not deleted: the healthy-owner case still proceeds, but only after the proof `UpdateAsync` returns this server's lease. R4 test 06's final check still passes 18/18 through the proof path.
- In test 04 §A check 02 captures the stored value inside the hook (`takeoverStoredCoins`), because by the time `SaveData` returns the stale save may already have overwritten it.
- Test 04's mutant control loads the CURRENT `services/DataServiceB.luau` for server B (B's acquire/save path is identical in both versions; only server A's stale saves are under test) — documented in the control's header.
- No suite asserts exact `SaveData` call counts (only `appendSidecar` paths assert `GetAsync==0`), so the extra lease checks per save are safe (verified by the call-count/failure-injection audit done before coding).

### Validation

- New test `scripts/phase1-tests/r5-transactions/04_r5_4_session_lease_races.luau` — **32/32**: §A lease expires during a `SaveData` wait, real server-B takeover mid-wait via `_TestSetWaitHook`, stale save refused, newer profile (10000) survives; §B lease `GetAsync` fails while B owns the lease → refused; §C legitimate handover A→B→A, losing server cannot keep saving; §D mid-save takeover via `_beforeCommit`: in-flight save lands (TOCTOU, documented), refresh does NOT extend local expiry and marks lost, later save stays refused even on a failed read; §E crash/expiry recovery; §F healthy owner's save preserved under a failed read (proof `UpdateAsync` ran, delta=2); §G per-retry revalidation via a wrapped `SetAsync` (lease lost between attempts → no retry write, `SetAsync` delta=0); §H never-loaded player reports not-owned/not-contested/not-lost.
- Negative control `scripts/phase1-tests/r5-transactions/mutant/m04_r5_4_old_logic.luau` (against `mutant/DataServiceR4.luau`) — **12/12**: old `DataService` overwrites the newer profile in all four scenarios (mid-wait takeover, failed read under another owner, retry without revalidation, stale extended cache authorising a later blind write) and has no `GetSessionLeaseState`.

### Remaining limits (R5-4) — the exact partition boundary

1. **Exact partition boundary:** when the stored-lease read fails AND the proof `UpdateAsync` also fails, the save is refused for that attempt only and the session is NOT poisoned — the next save re-checks from scratch. Two servers can therefore both be refused (safe) but never both authorised on a failed check; complete cross-server guarantees still require live multi-server behaviour, which is unproven (simulation only: two module instances sharing one stub store). During a total DataStore outage, saves pause until the store recovers — liveness, not safety, is what the partition costs.
2. **TOCTOU:** a lease taken over DURING a `SetAsync` commit (after the last pre-attempt check) still lets that one write land; the post-save refresh then marks the session lost so the NEXT save refuses (test 04 §D).
3. No Studio playtest or real production DataStore test was run for any of this.

## 9. Worker-C combined validation (2026-11-20) (historical snapshot — final round totals in the note after §1)

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/r5-transactions/run.sh` | **4/4 files passed, static anchors OK** (01/02 Worker-A + 03 40/40 + 04 32/32) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh` | **m03 6/6, m04 12/12, ALL NEGATIVE CONTROLS PASSED** |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh` | ALL NEGATIVE CONTROLS PASSED (Worker-A controls re-run after the DataService changes) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant.sh` | 70 passed, 0 failed (of 70) |
| `bash scripts/phase1-tests/r4-transactions/run.sh` | 10/10 files, static anchors OK, ALL PASSED (222 checks) |
| `bash scripts/phase1-tests/persistence/run.sh` | 16/16 files, ALL PASSED (273 checks) |
| `bash scripts/phase1-tests/theft/run_all.sh` | ALL THEFT TESTS PASSED (191 checks) |
| `bash scripts/phase1-tests/store/run.sh` | ALL STORE TESTS PASSED (72 checks) |
| `bash scripts/phase1-tests/quest/run.sh` | 59 checks passed |
| `bash scripts/phase1-tests/expedition/run.sh` | ALL PASSED (46 checks) |
| `bash scripts/phase1-tests/lifecycle/run.sh` | ALL PASSED (126 checks) |
| `bash scripts/phase1-tests/mutation-payload/run.sh` | ALL PASSED (66 checks) |
| `bash scripts/phase1-tests/fusion-payload/run.sh` | ALL PASSED (66 checks) |
| `bash scripts/phase1-tests/r5-transactions/run.sh` re-run after the hook fix | 4/4 + anchors OK; r4/persistence/theft + both mutant runners re-run green |
| `python3 scripts/harness-python.py` | **70 passed, 0 failed (of 70)** |
| Lune harness refresh + `lune run scripts/harness-lune/main.luau` | **40 passed, 0 failed (of 40)** |
| luau-compile over all `src/**/*.luau` | **68/68, 0 failures** |
| luau-compile over all `scripts/phase1-tests/**/*.luau` | **276/276, 0 failures** (270 baseline + 6 new Worker-C files) |
| Rojo 7.7.1 build ×2 to `/tmp/r5c-build-a.rbxl` / `/tmp/r5c-build-b.rbxl` | byte-identical, SHA `9532f52b134b05a4b6326ff1aec58aaadc9ee2630f1940400479586e0b0f25d0`, 667,530 bytes |
| `python3 scripts/verify-rbxl.py /tmp/r5c-build-a.rbxl` | 8 PASS, 0 failed |
| `git rev-parse HEAD` | `6ee6d217019af75f3f0c54357150aad470060aaa` (unchanged) |
| `sha256sum GlitchTide.rbxl` | `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`, 558,606 bytes (unchanged) |

Total check count after Worker C: **1332 checks, 0 failed** (1131 R4 baseline + 70 R5-6 + 59 R5-1/R5-5 + 72 R5-3/R5-4). No ZIP was built by this worker (coordinator packages). No Studio playtest or live DataStore test was run. Economy untouched. `ProgressionService.luau` and `BaseService.luau` untouched.

## 10. Worker D — R5-2 (P0): block ownership operations in unhealthy sessions

**The defect (Qwen, verified against code).** A contested thief could steal from a healthy victim; the victim's removal saved; the thief could not save; the instance disappeared when the thief left. The same shape produced contested-victim duplication and load-failed thief loss. The pre-fix reproduction (test 05 failing-first, 2026-11-20): 29 passed, 47 failed (of 76) — including check 44, "both rejoin: exactly ONE owner — count=0", and checks 46–49, the contested-thief delivery succeeding.

**The gate.** `src/server/Services/RaidService.luau`: `sessionBlockedReason()` (line 823), `verifySessionLease()` (855), `checkSessionHealth()` (876), `RaidService._TestSetStealChannelHook()` (895). Two signals, in order. (1) Local: the R5-4 reason API `GetSaveBlockedReason()` — load_failed / session_contested / session_lost — checked first, no DataStore traffic. The check reads that API ONLY, not the `IsSaveable` boolean: for the real DataService the two are exactly equivalent (same three flags — `GetSaveBlockedReason` DataService.luau:721, `IsSaveable` :2240), so nothing is lost in production; the distinction matters only for a DataService WITHOUT the reason API, which falls back healthy (the established fallback). That fallback is load-bearing: theft test 11 §B monkey-patches a bare `IsSaveable = false` with no reason API, and lifecycle test 06's stub has `IsSaveable` + `setSaveable` and no reason API — both model the R2-4/R3-5 reward-pending behaviour (delivery succeeds, reward recorded pending, recovery pays exactly once on rejoin), which R5-2 does not ask to change. An early version of this gate consulted `IsSaveable` as a fallback and broke both suites (theft 11 checks 13/14/17, lifecycle 06 checks 01/02/04/05/07–10); narrowing the local check to the reason API restored both suites green with ZERO change to production behaviour (real DataService). (2) Stored: a proof against the STORED lease via the existing public `DataService.AcquireSessionLease()` — a conditional UpdateAsync that keeps a live foreign lease and returns false for it, re-acquires/heartbeats our own lease, never overwrites another server's. Fail-closed: an errored or refused probe refuses the operation. One UpdateAsync per party per check, at commit points only (steals are already rate-limited and cooldown-gated, so the extra write is bounded).

**Where the gate sits.** `StealBrainrot`: gate #1 just before the channel setup (line 3444) — after CarryService validation, BEFORE `_pairCooldowns` is set and the "Started" alert fires, so a refused steal burns no cooldown; gate #2 post-channel (3547), after the `IsProtected` re-check, before `removePlaced` — the 3 s channel yields, so either party's lease can be taken over mid-channel and the pre-channel check is stale by then. A new test-only hook, `_TestSetStealChannelHook` (called once per channel iteration, pcall-guarded, following the `DataService._TestSetWaitHook` precedent), lets the suite take the thief's lease mid-channel. `ConfirmDelivery`: the gate (2403) runs BEFORE the escrow invalidation, for the thief and for the victim when online — a refused delivery parks no tombstone. Recovery paths are deliberately UNGATED: `ReturnStolen`, `RecoverStaleTransit`, `RecoverOnRejoin`, `RecoverPendingRewards` must still run in unhealthy sessions, because they RESTORE ownership — blocking them would strand or destroy the Brainrot the gate exists to protect (test 05 §E/§F prove the return and the leave hook still work for unsaveable thieves). `src/server/Services/BaseService.luau`: `sessionBlockedReason()` (229, LOCAL-only — placing/storing your own Brainrot transfers nothing between players, so the worst case of a stale local view is a lost placement, not a lost/duplicated instance; the stored probe is reserved for the steal/delivery commit points), PlaceBrainrot gate (1129, after the whole-record reinsert early return — the recovery restore stays exempt), StoreBrainrot gate (1354). `GameManager.luau` was NOT touched: `BindToClose`/`runPreSaveHooks` live in DataService (verified before editing). `ProgressionService.luau` was NOT touched. The economy was NOT changed. No lease/void logic was touched (R5-3/R5-4 code only called, never edited).

**Decision item (Worker A §C) — CLOSED.** A delivery committed in-memory in a load-failed session can never persist, yet its R4-1 tombstone permanently supersedes the victim's escrow backstop — if both rejoin first, the instance has 0 owners (old test 02 §C asserted 0, not 2). The general thief gate closes it: the delivery is refused, the transit stays live, no reward is paid, NO tombstone parks — the victim recovers via the escrow, exactly 1 owner, not 0 (test 05 §E). The gate covers every unsaveable thief, not only the stale-escrow case: without a stale escrow the same loss happens (the victim's removal saved, the thief's delivery never persists).

**Test 02 rewrite (consequence of the gate).** `02_r5_5_fail_open_escrow.luau` is rewritten for a HEALTHY thief (36/36, was 35/35): the old §A stole and delivered with a load-failed thief, which the gate now refuses at both points. Two subtleties found while rewriting. (1) `getStore()` CACHES a successful store handle for the life of the server (only failures are uncached), so a GetDataStore outage introduced AFTER healthy loads is invisible — the §A outage checks now run BEFORE any load, and the end-to-end delivery-blocked proof moved to a new §A2: the store is up (gate passes) but ONLY the victim's escrow key fails its UpdateAsync (`failUpdateAsyncForKey`, 2 attempts = `appendSidecar`'s retry count) — the delivery is refused `"delivery escrow invalidation unavailable"` with transit live, no reward, no tombstone. (2) §B's reward is now PAID (100000 → 100300, pending 0 — healthy thief), the thief's save lands, the stored key holds the delivered copy; §C both rejoin → exactly 1 owner (the thief). The R5-5 row in `docs/R5_ACCEPTANCE_CHECKLIST.md` still carries Worker A's old §B/§C wording ("thief save still refuses", "total 0") — that row is Worker A's to update; this section is the authoritative record of the change. Mutant m02 was updated to load the pre-R5-2 `RaidServiceR4` (`raidPath="./mutant/RaidServiceR4"`) as well as `DataServiceR4`: with the current RaidService the old DataService defect is unreachable end-to-end (the steal is refused first), so the control must isolate BOTH old modules; it still passes 6/6 (fail-open invalidation, delivery commits during the outage, both own the instance after rejoin).

**§D interleaving shift (known limitation, found by the rewrite).** The stub's one-shot `_beforeCommit` hook fires on the FIRST UpdateAsync after arming — since R5-2 that is the gate's lease probe, which runs BEFORE the invalidation read, not during the tombstone append. So in test 02 §D the return now lands before the read, and the fresh return REPLACES the stale entry in the escrow list (both share the legacy sidecar identity `legacy:<instanceId>:0` — the return record carries `ReturnTxId` but no `TxId`). The invalidation read therefore sees only the fresh return, and the tombstone supersedes the FRESH transaction, not the stale one. The return still wins the delivery (checks 29–31 pass), and the victim still holds the Brainrot in memory — but the tombstone now also supersedes the victim's fresh-return backstop, so a crash before the victim's save would leave the rejoin without the escrow copy. The normal path is proven: the victim's leave save lands the returned Brainrot durably (new §D check, `SaveData(victim) == true` + stored key holds it). The residual needs a crash before the save AND a failed leave save. Fixing it properly needs a time-ordered invalidation (the tombstone must name only returns that existed when the delivery started) — that is a DataService schema/API change, out of this worker's scope; flagged here as future work, not silently absorbed. The §D checks assert the new behaviour honestly rather than the old one.

**Other limitations.** A failed lease probe does NOT set the sticky `_sessionLost` flag (only `tryAcquireLease`/`checkSessionLease` set flags) — the next `SaveData` sets it, so a refused operation's session is flagged on the next save, not immediately. The post-channel refusal leaves the 60 s steal cooldown standing (as for a failed channel); the pre-channel refusal burns nothing. The gate's local check is reason-API-only (see above) — broad in production, permissive for API-less stubs by design.

## 11. Worker D — R5-7 (P2): bound shutdown recovery hooks

**The defect (Qwen, reproduced exactly).** The old `BindToClose` ran every player's pre-save hooks inline, one after another: ~42 simulated seconds for six players in a degraded-store scenario, before the parallel save phase. Failing-first test 07 (2026-11-20): 24 passed, 7 failed (of 31) — the arithmetic checks passed on both old and new code (the discrimination is sum vs max, as designed); only the missing-API and serialisation checks failed. The probe measured the real per-player costs: 1 DataStore call per `HandlePlayerLeaving` run (carrying thief or pending-reward player), 5 calls per `SaveForShutdown` — so the degraded model (7 s per hook-path call, 9 s per degraded single save) gives sequential 6 players = 42 s (Qwen's measurement, reproduced exactly) and 12 players = 84 s.

**The fix.** `src/server/Services/DataService.luau`: `runPreSaveHooks()` (line 204) is now per-player serialised — if a hook run for a player is already in flight, a second caller waits (bounded, `HOOK_WAIT_SECONDS = 5`) and then returns `false` WITHOUT re-running (the in-flight run already owns the recovery; two concurrent `HandlePlayerLeaving` runs could both see the same `_inTransit` entry and both call `ReturnStolen` on it); returns `true` iff the hooks ran here. `DataService.RunPreSaveHooks()` (229) exposes the synchronous per-player unit. `DataService.RunShutdownHooks()` (246) spawns one task per player and waits at most `SHUTDOWN_HOOK_BUDGET_SECONDS = 10`, returning `{attempted, spawned, completed}`; a player whose hooks never complete in the budget is warned about, never silently claimed done (their save still runs afterwards and the rejoin reconciler covers an unrecovered record). `DataService.GetShutdownHookStats()` (273) reports the last run. `BindToClose` (1782; `RunShutdownHooks` call 1794) replaces its sequential loop with `RunShutdownHooks`, then `SaveAllForShutdown` (unchanged, 25 s wait), then lease release. Expected degraded total ≈ 16 s (7 s slowest hook + 9 s slowest save), inside the ~30 s budget. `RaidService.HandleShutdown` was deliberately left sequential — it is not on the BindToClose path, and lifecycle test `02_shutdown_in_transit.luau` asserts its synchronous return value (parallelising it via `task.spawn` would return 0 under Lune); documented here as a residual, not an oversight.

**Limitations.** The two hard caps sum to 35 s (10 s hooks + 25 s saves) vs Roblox's ~30 s force-close — in the pathological both-phases-saturated case the tail (lease release; leases self-expire in 90 s) can be cut. A player carrying 2+ Brainrots at shutdown can exceed the 10 s hook budget (their save + the rejoin reconciler cover it). `task.spawn` is discarded by the harness stub and `task.wait` returns at once, so wall-clock shutdown timing cannot be measured here — no Studio shutdown timing is claimed (same honesty note as R4-8 test 07).

## 12. Worker-D combined validation (2026-11-20)

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/r5-transactions/run.sh` | **6/6 files passed, static anchors OK** (01 24/24, 02 36/36 rewritten, 03 40/40, 04 32/32, 05 77/77, 07 37/37) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_2_7.sh` | **m05 18/18, m07 21/21, ALL NEGATIVE CONTROLS PASSED** (make_mutant_r5_2_7 guards the three static snapshots: old-behaviour anchors present, fixes absent) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh` | ALL NEGATIVE CONTROLS PASSED (m01 5/5, m02 6/6 with RaidServiceR4 — see §10) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh` | ALL NEGATIVE CONTROLS PASSED (m03 6/6, m04 12/12) |
| `bash scripts/phase1-tests/r5-transactions/run_06.sh` | 70 passed, 0 failed (of 70) |
| `bash scripts/phase1-tests/r4-transactions/run.sh` | 10/10 files, static anchors OK, ALL PASSED |
| `bash scripts/phase1-tests/persistence/run.sh` | 16/16 files, ALL PASSED |
| `bash scripts/phase1-tests/theft/run_all.sh` | ALL THEFT TESTS PASSED (191 checks) |
| `bash scripts/phase1-tests/store/run.sh` | ALL STORE TESTS PASSED (72 checks) |
| `bash scripts/phase1-tests/quest/run.sh` (with `LUNE=/tmp/lune-0.11.1/lune`; the script defaults to bare `lune`, which is not on PATH here) | ALL 59 CHECKS PASSED |
| `bash scripts/phase1-tests/expedition/run.sh` | ALL PASSED (46 checks) |
| `bash scripts/phase1-tests/lifecycle/run.sh` | ALL PASSED (126 checks) |
| `bash scripts/phase1-tests/wiring/run.sh` | 10 passed, 0 failed (of 10) |
| `bash scripts/phase1-tests/mutation-payload/run.sh` | ALL PASSED (66 checks) |
| `bash scripts/phase1-tests/fusion-payload/run.sh` | ALL PASSED (66 checks) |
| `python3 scripts/harness-python.py` | **70 passed, 0 failed (of 70)** |
| `lune run scripts/harness-lune/main.luau` | **40 passed, 0 failed (of 40)** |
| luau-compile over all `src/**/*.luau` (plain invocation; `--mode null` is not accepted by this binary) | **68/68, 0 failures** |
| luau-compile over all `scripts/phase1-tests/**/*.luau` | **284/284, 0 failures** (276 baseline + 8: test 05, test 07, m05, m07, and the 4 mutant snapshots — see note) |
| Rojo 7.7.1 build ×2 to `/tmp/rojo-a.rbxl` / `/tmp/rojo-b.rbxl` | byte-identical, SHA `1bf97d320c98c6b96f471d7b97bbc676ef77147f2f8c0cd1408161178d369f66`, 676,532 bytes |
| `python3 scripts/verify-rbxl.py /tmp/rojo-a.rbxl` | 8 PASS, 0 failed |
| `git rev-parse HEAD` | `6ee6d217019af75f3f0c54357150aad470060aaa` (unchanged) |
| `sha256sum GlitchTide.rbxl` | `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`, 558,606 bytes (unchanged) |

Note on the test-compile count: 284 files vs the Worker-C baseline of 276 — the +8 is test 05, test 07, m05, m07, and the 4 mutant snapshots (`RaidServiceR5Pre2`, `BaseServiceR5Pre2`, `DataServiceR5Pre7`, `MapBuilderStub`). Total check count after Worker D: **1447 checks, 0 failed** (1332 after Worker C + 77 R5-2 + 37 R5-7 + 1 net from the test-02 rewrite, 35 → 36). No ZIP was built by this worker (coordinator packages). No Studio playtest or live DataStore test was run. Economy untouched. `ProgressionService.luau` and `GameManager.luau` untouched by this worker (GameManager verified untouched: BindToClose lives in DataService). `BaseService.luau` touched ONLY for the R5-2 gates (Worker C's "untouched" note above no longer holds for it).

## 13. Worker E — R5-8 (P2): repair validation infrastructure

### The defects, reproduced first

All three Qwen findings reproduced exactly before any fix, by running each mutant builder/runner from the current working copy:

| Runner | Before (exact failure) |
|---|---|
| `bash scripts/phase1-tests/theft/mutant/make_mutant.sh` | `AssertionError: R13 grant block not found exactly once` (P4 + Watchdog mutants written, then abort; `run_mutant.sh` exit 1) |
| `bash scripts/phase1-tests/lifecycle/mutant/make_mutant.sh` | `AssertionError: sidecar block not found exactly once` (`run_mutant.sh` exit 1) |
| `bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh` | `make_mutant FAILED: R4-4 void call (rule b): anchor matched 0 times, expected 1: '\n\t\t\t\tvoidPendingRewardsForInstance(player, instanceId)'` (exit 1); plus the runner hardcodes `/tmp/luau-0.747/luau-compile` on two lines |

The audit covered EVERY mutant builder/runner in the tree, not just the three named: theft (`make_mutant.sh`, `run_mutant.sh`), expedition (`make_mutant.sh`, `run_mutant.sh`), lifecycle (`make_mutant.sh`, `run_mutant.sh`), persistence (`run_mutant.sh` — static snapshot, no builder), r4-transactions (`make_mutant.sh`, `run_mutant.sh`), r5-transactions (`make_mutant.sh`, `make_mutant_r5_1_5.sh`, `make_mutant_r5_3_4.sh`, `make_mutant_r5_2_7.sh`, `run_mutant.sh`, `run_mutant_r5_1_5.sh`, `run_mutant_r5_3_4.sh`, `run_mutant_r5_2_7.sh`). Baseline for the un-named ones: expedition make/run green (control valid — mutant fails the rejection test as expected, 2 passed / 4 failed of 6), persistence run green (all 4 controls valid), all four r5 runners green (m01/m02, m03/m04, m05/m07, rebirth 26/26). The r5 make scripts are static-snapshot guards (they verify old-behaviour anchors in the frozen snapshots and never rebuild), so they needed no anchor change.

### What changed — one anchor per stale site

`scripts/phase1-tests/theft/mutant/make_mutant.sh` — R13 anchor re-anchored. R4-1 changed the grant call to pass the delivery TxId as a 5th argument (`grantStealReward(thief, instanceId, record.CharacterId, reward, deliveryTxId)`) and added the two R4-1 comment lines inside the `if reward > 0 then` block, so the R2-era anchor (bare 4-arg call, no comment) matched 0 times. The mutant replacement is unchanged (the old pcall + warn-only block, no pending entry, delivery claims success); only the anchor follows the current source shape. Verified the new anchor matches exactly once before editing.

`scripts/phase1-tests/lifecycle/mutant/make_mutant.sh` — sidecar anchor (e) re-anchored. R4-2 changed the park from the R3 unconditional pcall to a result-capturing pcall (`local okCall, stored = pcall(...)`, `parked = okCall and stored == true`, warn on failure), so the R3-era anchor matched 0 times. The mutant still removes the park entirely, restoring the old unsafe behaviour (a reward recorded while the session cannot persist dies with the cache). The replacement keeps `local parked = false` so the `ParkedTxns[id] = parked` bookkeeping below still resolves (the id lands unparked, exactly as a failed park would); only the sidecar write itself is gone. Anchors (a)–(d) still matched and were not touched.

`scripts/phase1-tests/r4-transactions/mutant/make_mutant.sh` — two re-anchors, both found by this audit (the R4-4 one is the reported failure; R4-7 surfaced only after R4-4 was fixed, when the build reached it). R4-4: R5-3 rewrote `voidPendingRewardsForInstance` to return `(voidedTxIds, durable)`, and each of the three `RecoverStaleTransit` call sites now captures the result (`local _voidedB/D/E, voidDurableB/D/E = ...`) and counts the recovery `remaining` when the void is not durable — so the R4-era bare-call anchors matched 0 times. Deleting ONLY the call line would leave `voidDurableB/D/E` as nil reads, which would count every voided recovery `remaining` — that is NOT the R3 behaviour (R3 counted each voided recovery `resolved` and left the reward payable). So each revert removes the void call AND its R5-3 durability branch, restoring the plain `resolved += 1` of the R3 code. The `must_absent` sanity needles were updated to the new identifiers (`voidDurableB/D/E` absent; the three call lines absent). R4-7: R5-4 changed the signature to `local function acquireSessionLease(player: Player): (boolean, any)`; the mutant still returns `true` unconditionally (result nil) — every caller only reads the result when the acquire FAILED, so `return true` keeps the last-write-wins behaviour. The R4-1/R4-2/R4-3/R4-8 anchors were verified still matching and were not touched.

`scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh` — configurable compiler path. The two hardcoded `/tmp/luau-0.747/luau-compile` invocations are now `"$LUAU_COMPILE" ...` with `LUAU_COMPILE="${LUAU_COMPILE:-/tmp/luau-0.747/luau-compile}"` at the top, the same `${VAR:-default}` pattern the file already uses for `LUNE`. A repo-wide grep confirms these were the ONLY `luau-compile` hardcodes in `scripts/phase1-tests/` (`LUNE` was already env-configurable everywhere); no `run.sh`/`refresh.sh` file invokes `luau-compile`, so none needed changing. The default is unchanged, so existing invocations behave identically.

### The controls still detect the old broken behaviour

Each repaired runner was re-run, and each control was checked against the pre-fix snapshot behaviour it is meant to catch (step 4 of the loop):

- Theft 03 (R13): the mutant fails 4 of 6 checks as expected — warn-only grant fires (`[RaidService] Steal reward payment failed for Thief955`), delivery status is `nil` (not `reward_pending`), no pending entry is recorded, recovery pays 0 (coins stay 100000). The fixed test 11 scenario A passes on the fixed service.
- Lifecycle 01: the mutant fails as expected — the rejoin reconciler resolves nothing (the victim still has no copy, the thief's saved record is still flagged InTransit).
- R4 m04 (R4-4): the mutant passes 5/5 asserting the old outcome — the voided delivery's reward is STILL paid (paid=1, total=300, thief 100300) and the victim also recovers the Brainrot (reward farming reproduced).
- R4 m06 (R4-7): the mutant passes — the lease never contends (last-write-wins).

### Failure-path verification (mandatory)

- Builder failure path: a scratch copy of the theft builder + services under `/tmp/r58-failtest/` (NOT in the tree) with the R13 anchor broken (`deliveryTxId` renamed in the grant call) → exit 1, `AssertionError: R13 grant block not found exactly once`. The tree was verified untouched afterwards (0 occurrences of the broken anchor in the tree).
- Runner failure path: in the baseline, both `theft/mutant/run_mutant.sh` and `r4-transactions/mutant/run_mutant.sh` exited 1 when their `make_mutant.sh` failed (both call the builder unguarded under `set -euo pipefail`, so a build failure aborts the runner before any control runs).
- Configurable-path failure path: `LUAU_COMPILE=/tmp/does-not-exist/luau-compile` → exit 127, loud `No such file or directory` naming the binary at the compile step (line 28); `LUAU_COMPILE=/tmp/r58-luau-compile-copy` (a copy of the real binary) → exit 0, 7/7.

### Checklist fix (same worker): R5-5 row wording

Worker D reported the R5-5 checklist row still carried Worker A's pre-rewrite §B/§C wording after test 02 was rewritten (02 is now 36/36 with shifted §D interleaving). The row's test-case description and actual-result cell now match the current test file (`scripts/phase1-tests/r5-transactions/02_r5_5_fail_open_escrow.luau`, re-read for this fix): §A outage is DataService-level only, before any load; §A2 is the end-to-end fail-closed proof with the store up (escrow-key-only UpdateAsync failure); §B reward is PAID (100000 → 100300), the thief's save lands, the stored key holds the copy; §C both rejoin → exactly 1 owner, the thief (not 0, not 2); §D asserts the R5-2 interleaving shift honestly (the tombstone supersedes the FRESH return, victim's leave save lands it). Evidence values are Worker A/D's as re-run by this worker (test 02 36/36, mutant m02 6/6 — unchanged); the pre-fix reproduction (15/35) is now attributed to the pre-rewrite test; the 0-owner limit is recorded as CLOSED by the R5-2 gate (test 05 §E) instead of open. The R5-8 row is filled, and the Worker-D final-gate note about the stale row is updated.

### Validation — every command run and its actual result

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/theft/mutant/run_mutant.sh` | **exit 0 — ALL 7 CONTROLS VALID** (01–07 each failed as expected) |
| `bash scripts/phase1-tests/lifecycle/mutant/run_mutant.sh` | **exit 0 — CONTROL VALID** (01 failed as expected) |
| `bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh` | **exit 0 — 7/7 negative controls passed** (m01–m07, incl. m04 R4-4 + m06 R4-7) |
| `bash scripts/phase1-tests/expedition/mutant/run_mutant.sh` | **exit 0 — CONTROL VALID** (mutant fails the rejection test as expected) |
| `bash scripts/phase1-tests/persistence/mutant/run_mutant.sh` | **exit 0 — ALL R3 MUTANT CONTROLS VALID** |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh` | **ALL NEGATIVE CONTROLS PASSED** (m01 5/5, m02 6/6) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh` | **ALL NEGATIVE CONTROLS PASSED** (m03 6/6, m04 12/12) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_2_7.sh` | **ALL NEGATIVE CONTROLS PASSED** (m05 18/18, m07 21/21) |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant.sh` | **26 passed, 0 failed (of 26)** |
| `bash scripts/phase1-tests/r5-transactions/run.sh` | **6/6 files passed** (01 24/24, 02 36/36, 03 40/40, 04 32/32, 05 77/77, 07 37/37) |
| `bash scripts/phase1-tests/r5-transactions/run_06.sh` | **70 passed, 0 failed (of 70)** |
| `bash scripts/phase1-tests/theft/run_all.sh` | **ALL THEFT TESTS PASSED (191 checks)** |
| `bash scripts/phase1-tests/lifecycle/run.sh` | **ALL LIFECYCLE TESTS PASSED (126 checks)** |
| `bash scripts/phase1-tests/persistence/run.sh` | **ALL PERSISTENCE TESTS PASSED (273 checks)** |
| `bash scripts/phase1-tests/r4-transactions/run.sh` | **ALL R4-TRANSACTIONS TESTS PASSED (222 checks)** |
| `bash scripts/phase1-tests/store/run.sh` | **ALL STORE TESTS PASSED (72 checks)** |
| `bash scripts/phase1-tests/quest/run.sh` (LUNE on PATH) | **ALL 59 CHECKS PASSED** |
| `bash scripts/phase1-tests/expedition/run.sh` | **ALL PASSED (46 checks)** |
| `bash scripts/phase1-tests/wiring/run.sh` | **10 passed, 0 failed (of 10)** |
| `bash scripts/phase1-tests/mutation-payload/run.sh` | **ALL PASSED (66 checks)** |
| `bash scripts/phase1-tests/fusion-payload/run.sh` | **ALL PASSED (66 checks)** |
| `python3 scripts/harness-python.py` | **70 passed, 0 failed (of 70)** |
| `bash scripts/harness-lune/refresh.sh && /tmp/lune-0.11.1/lune run scripts/harness-lune/main.luau` | **40 passed, 0 failed (of 40)** |
| `luau-compile` all `src/**/*.luau` | **68/68, 0 failures** |
| `luau-compile` all `scripts/phase1-tests/**/*.luau` | **284/284, 0 failures** |
| `git rev-parse HEAD` | `6ee6d217019af75f3f0c54357150aad470060aaa` (unchanged) |
| `sha256sum GlitchTide.rbxl` | `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`, 558,606 bytes (unchanged) |

Total check count after Worker E: **1447 checks, 0 failed** (unchanged from Worker D — no test was added, removed, weakened, or reworded by this worker except the R5-5 checklist prose; the mutant files are regenerated by the repaired builders). No ZIP was built by this worker (coordinator packages). No Studio playtest or live DataStore test was run. Economy untouched. No `src/` file touched; no non-mutant test file touched.

### Remaining limitations (Worker E)

1. **Partial writes on builder abort (pre-existing, not changed):** a builder writes each mutant as it goes, so a later anchor failure leaves the earlier mutants refreshed and the later ones stale on disk (observed in the scratch failure test: P4/Watchdog written, then the R13 abort). The runner aborts before any control runs, so nothing is silently skipped — but a failed build leaves a mixed old/new mutant set until the next successful build. Making builders atomic (build to a temp dir, move on success) is future work, not done here.
2. **Parallel-runner race (observed during this work, not a tree defect):** two mutant runners run concurrently race on the shared `services/` + `shared/` copies their `refresh.sh` steps rewrite — a refresh read mid-write reports `DIVERGED` and fails. All results above were obtained from strictly sequential runs; do not run two phase1 runners in parallel.
3. **The R4-4 revert is R3-shaped, not R5-3-shaped:** the mutant removes the void call AND its durability branch. It therefore does not test the R5-3 durability-check code itself — that code is covered by the R5-3 fixed test (03) and its mutant (m03), not by the R4 controls.
4. No Studio playtest or real production DataStore test was run for any of this.

## 14. R5 docs closer — R5-6 (P2): reservation-aware Rebirth/Prestige

(This section was missing from the report entirely — the R5-6 row was a stub in the checklist and no §14 existed — although the work was done and passing. Filled 2026-11-20 by the R5 docs closer from the verified evidence below; no code was changed in this pass.)

### The defect

`ProgressionService.Rebirth` and `ProgressionService.Prestige` reset coins with a direct assignment, `data.Coins = Config.StartingCoins or 100`, with no regard for the R4-3 coin reservation. A pending steal-reward commit (`RaidService.commitPendingPayment`) credits the reward and reserves it (`DataService.ReserveCoins`) for the duration of its verified save. If Rebirth/Prestige fires inside that save window, the reset wipes the reserved reward coins out of the balance while the reservation record still holds them:

- save SUCCEEDS → the reservation is released, the commit reports paid, and the 300-coin reward is simply gone (wiped);
- save FAILS → the rollback releases the reservation and then subtracts exactly 300 from a balance of 100, which clamps at 0: the rollback eats the reset's StartingCoins, the entry is restored, and the retry pays the reward on top of a zeroed balance (final 300 instead of StartingCoins + 300 = 400).

The same direct reset also lets a player buy a rebirth with coins that are not spendable yet: a 100100 balance with 300 reserved passes the raw 100000-coin requirement even though only 99800 is spendable.

### What changed — `src/server/Services/ProgressionService.luau` only (+65/−4)

- New helpers (lines 337–367): `reservedCoins(player)` (337) reads `DataService.GetReservedCoins` (pcall-guarded, floor 0); `spendableCoins(player, data)` (349) reads `DataService.GetSpendableCoins`, falling back to the raw balance; `resetCoins(player)` (366) returns `(Config.StartingCoins or 100) + reservedCoins(player)` — the balance a Rebirth/Prestige reset lands on. Both helpers fall back to the raw balance when DataService has no reservation API (stub DataServices in other suites), preserving the old behaviour there.
- `ProgressionService.Rebirth(player)` (824): the coin requirement is judged on `spendableCoins` (836); the reset is `data.Coins = resetCoins(player)` (861).
- `ProgressionService.Prestige(player)` (941): the coin requirement is judged on `spendableCoins` (953); the reset is `data.Coins = resetCoins(player)` (975).

No economy values changed: costs, rewards, gems, slots and multipliers are untouched. No other file was changed for R5-6 (`git diff --stat HEAD` shows only `ProgressionService.luau`, 65 insertions, 4 deletions).

### Validation

| Command | Result |
|---|---|
| `bash scripts/phase1-tests/r5-transactions/run_06.sh` | **70 passed, 0 failed (of 70)** — L1 Rebirth during a FAILING reward save (rollback exact, recovery pays once, final 100 + 300 = 400); L2 Rebirth during a SUCCEEDING reward save (reward survives the reset, 400 not 100, recovery pays nothing more); L3 Prestige during a FAILING reward save (same accounting as L1, prestige economy intact); L4 Rebirth REFUSED while only reserved coins push the balance over the 100000 requirement (spendable 99800 < 100000); L5 legitimate economy unchanged with no reservation open (plain Rebirth/Prestige costs, rewards, slots, multipliers, requirement gates). The reward save window is entered exactly as in production: the Rebirth/Prestige call runs inside a SetAsync hook on the thief's main key, after the reward credit + reservation and before the save lands. |
| `bash scripts/phase1-tests/r5-transactions/mutant/run_mutant.sh` | **26 passed, 0 failed (of 26)** — negative control `m01_rebirth_prestige_old.luau` against the pre-fix `mutant/ProgressionServiceOld.luau` (built from git HEAD by `mutant/make_mutant.sh`): L1/L3 rollback clamps at 0 (final 300, not 400; at hook time the reservation, 300, is larger than the balance, 100 — the R4-3 invariant balance ≥ reserved violated); L2 reward wiped outright (balance 100, stored 100, recovery pays 0); L4 old raw-balance check ACCEPTS the rebirth on 99800 spendable, then the rollback zeroes it; L5 plain rebirth succeeds on the old code too, as expected. |
| Pre-fix reproduction (R5 docs closer, 2026-11-20) | Fixed test `06_rebirth_prestige.luau` run against the pre-fix service: **56 passed, 14 failed (of 70)** — the 14 failures are exactly the reservation legs (L1/L2/L3/L4); L5 passes on both old and new code, as designed. |
| Full round | Test 06 + mutant are included in the final round totals (1447 checks, 0 failed — see the round-level note after §1). `bash scripts/phase1-tests/r5-transactions/run.sh` re-run after this docs-only pass: 6/6 files green (see checklist verification). |

### Remaining limits (R5-6)

1. The helpers fall back to the raw balance for a DataService without the reservation API, so the fix is active only where the real DataService is wired; stub-DataService suites keep the old behaviour by design.
2. No Studio playtest or real production DataStore test was run for any of this.
