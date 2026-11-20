# GLITCH TIDE — R2 Repairs Report (final verification)

**Date:** 2026-11-19 (IST). **HEAD:** `6ee6d21` (Release cleanup follow-up).
**Scope:** final verification of the R2 repair bundle (R2-1…R2-7) plus the
R2-7 mutant controls added in this pass. All R2 work is **uncommitted** in
`~/workspace/your_files/glitch-tide-v1.1/`; no commits, pushes, publishing,
or `GlitchTide.rbxl` rebuild were made in this pass, and no final R2 ZIP
was built (packaging is the parent's job).

**How this report was produced:** this worker re-ran every suite and
harness from a clean state, re-ran every mutant control, refreshed every
test copy from current `src/` and checked for drift, rebuilt with Rojo
twice, and spot-checked the workers' claimed anchors in the actual source
(the claims in §1 were verified, not trusted blindly). **No Studio
playtest has ever run; nothing in this report claims Studio behaviour as
verified.** Every check below is a Lune / Python / Luau / Rojo check on
this machine.

**Tools used:** Lune 0.11.1 (`/tmp/lune-0.11.1/lune`), Luau 0.700
(`/tmp/luau-tools/luau-compile` — the pre-existing tools dir; the 0.747
build cited in the Phase 1 report is gone with the earlier `/tmp` wipe),
Rojo 7.7.1 (freshly downloaded this pass from
`rojo-rbx/rojo` releases, `rojo-7.7.1-linux-x86_64.zip`, to
`/tmp/rojo-7.7.1/rojo`; `rojo --version` → `Rojo 7.7.1`).

---

## 1. Finding-by-finding status

### R2-1 — Stale placed copy overwrites a paid mutation at delivery (N1)

**FIXED.** `StealBrainrot`'s snapshot now takes Level / Mutation / Glitched
from the **owned** record; the placed copy is only a fallback when the
owned record has none (`src/server/Services/RaidService.luau:2074-2077`,
verified in source). `MutateBrainrot` syncs the matching placed copy's
Mutation in the same call and rebuilds the base when BaseService is linked
(`MutationService.SetBaseService`, auto-wired by GameManager's cross-link
pass). Evidence: `theft/10_stale_mutation.luau` 21/21 — mutate placed golden
wobble to electric, steal with a hand-staled placed copy, deliver; income
40/s (electric), not 50/s (golden). Mutant control P4 (placed-preferred
snapshot restored) fails the same assertions as expected — delivered copy
is golden, income 50/s (§3.6).

### R2-2 — In-transit Brainrot can be sent on an expedition (P3)

**FIXED.** `ExpeditionService.GetExpeditions` filters `InTransit`
(`ExpeditionService.luau:324`, verified), `StartExpedition` rejects
in-transit instances (`:401`), `ClearOrphanedExpeditionFlag` +
`HasActiveExpedition` helpers exist, and `ClaimExpedition` is defensive
(`:492`). Evidence: `expedition/01_expedition_in_transit.luau` 46/46.
Mutant control P3 (guard removed) fails the rejection assertions as
expected — the in-transit Brainrot appears in the eligible list and the
start is accepted (§3.6). The `ReturnStolen` orphan-flag auto-clear
(RaidService calls `ClearOrphanedExpeditionFlag` when wired, with an
inline victim-data fallback) is covered by the same file's Pairs 3–4.

### R2-3 — Watchdog delivery leaves a stale placed copy (N6 / R8)

**FIXED.** `reconcilePlacedCopy` is called inside `ConfirmDelivery`
(`RaidService.luau`, verified by the watchdog mutant anchor: exactly one
call site), rewrites an existing placed copy from the just-updated owned
record, syncs `owned.Placed` / `Slot`, clears the thief's carry state,
and rebuilds the base. No-op on the normal `PlaceBrainrot` path (no placed
copy exists yet there). Evidence: `theft/09_watchdog_reconcile.luau`
21/21 — stale placed copy + `PollInTransit`, second watchdog run pays
nothing twice, store afterwards keeps values. Mutant control (reconcile
call removed) fails as expected — placed copy stays Level 1 / Mutation
nil / BankedIncome 0, `owned.Placed` unsynced (§3.6).

### R2-4 — Steal-reward failure is silent and unretried (R13)

**FIXED.** The grant goes through `grantStealReward`
(`RaidService.luau:480`, verified); on failure (unsaveable session or
`AddCoins` failure) the reward is recorded in `data.PendingRewards`
keyed by InstanceId (`:426-449`, verified) and `ConfirmDelivery` returns
`(true, "reward_pending")` instead of claiming success.
`RecoverPendingRewards` pays each entry exactly once (entry deleted only
after a successful `AddCoins`), is wired on `PlayerAdded` in
`RaidService.Init` as a backstop, and is idempotent. Evidence:
`theft/11_pending_reward.luau` 24/24 — injected `AddCoins` failure,
unsaveable session, healthy control. Mutant control R13 (old pcall +
warn-only grant restored) fails as expected — status `nil` instead of
`"reward_pending"`, nothing recorded pending (§3.6). **Residual:** the
pending entry itself lives in the session cache; see §4, "load-failed
durability hole" (addressed by R2-5 sidecars, not eliminated).

### R2-5 — Lifecycle: leave / shutdown / rejoin handling of in-transit thefts

**FIXED (Lune-verified; save reliability NOT claimed fixed — see §4 R6).**
`DataService` owns save-on-leave/shutdown with `RegisterPreSaveHook`
(`DataService.luau:98`, verified); GameManager's own `onPlayerRemoving`
and its `BindToClose` are **removed** (comment at
`GameManager.luau:315-328`, verified — no handler remains there). Durable
theft-identity fields on the record (`StolenFromUserId` / `StolenSlot` /
`StolenPlacedAt` / `StolenBankedIncome`); escrow
(`Brainrot_Escrow_<UserId>`, `RaidService.luau:647-703`, verified) for
victim-offline returns; `RecoverStaleTransit` / `RecoverOnRejoin` with the
deterministic rules (a)–(e) (see §4, rule (e)); sidecars for pending
rewards; `GameManager.onPlayerAdded` calls `RecoverOnRejoin` canonically,
`RaidService.Init` backstop stays. Evidence: `lifecycle/` 83/83 across 6
files (§3.1). Mutant control (lifecycle) fails as expected — rejoin
resolves 0 stale records, victim's placed copy unrestored (§3.6).

### R2-6 — Companion service never wired to CarryService (core-services wireAll gap)

**FIXED.** Root cause found by the worker: core services never get the
`wireAll` pass. Fix is an explicit `CarryService.SetCompanionService`
block in `GameManager.wireCrossLinks` (`GameManager.luau:573-582`,
verified, +13 lines). Evidence: `wiring/01_production_companion_wiring.luau`
10/10 — and the test **failed pre-fix**, i.e. it detects the missing
wiring rather than passing vacuously. **Residual:** the underlying
`wireAll` gap for core services is still there — this fix is a targeted
explicit block, not a general `wireAll` for core services (§4).

### R2-7 — Mutant / negative controls (this pass)

**FIXED (complete).** Four new controls were added in this pass (M5, M8,
E1, E2) alongside the pre-existing P3, P4, watchdog, R13 controls. All
**nine** controls (the eight named in the brief plus the R2-5 lifecycle
control) were rebuilt from the current fixed source with diff-verified
minimal changes and re-run; **every mutant failed its assertions as
expected** (§3.6). Two new positive suite tests were added to cover the
new assertions on fixed code: `theft/12_config_driven_share.luau` (9/9)
and `theft/13_share_rounding_conservation.luau` (7/7); the M5/M8 control
assertions were additionally run against the **fixed** service (temp
copies, deleted afterwards) and pass 8/8 and 5/5, proving the controls
are not vacuously failing.

- **M5** — thief identity check in `ConfirmDelivery` (`if not record or
  record.Thief ~= thief`). Control `theft/mutant/04_mutant_control.luau`:
  victim and bystander rejected with `"not carrying that Brainrot"`;
  planted-duplicate scenario proves the guard is the only thing stopping
  a non-thief completing a delivery. Mutant failed as expected: clean
  state gives `"instance record missing"` instead of the identity
  reason, and the impostor with a planted duplicate **completes the
  delivery** (paid 300 coins, record rewritten to Level 5, real thief
  then locked out).
- **M8** — missing-owned-record guard in `ConfirmDelivery`. Control
  `theft/mutant/05_mutant_control.luau`: record removed mid-transit;
  fixed code rejects cleanly with `"instance record missing"`, pays
  nothing, transit stays live (restore the record → delivery succeeds,
  pays exactly once). Mutant failed as expected: `attempt to index nil
  with 'Level'` at the first snapshot write.
- **E1** — hard-coded 0.5 share vs `Config.StealRewardMultiplier`.
  Control `theft/mutant/06_mutant_control.luau` + mutant Economy in
  `theft/mutant/economy/` (full shared-module copy + byte-identical
  RaidService copy; only the share line differs). Sets the multiplier to
  0.25 and 0.75 and asserts direct share/reward and a real delivery
  split follow the config (500 banked at 0.25 → 125 paid / 375 retained).
  Mutant failed as expected: share stays 250 at both settings, delivery
  pays 300 / retains 250.
- **E2** — duplicated share formula / rounding. Control
  `theft/mutant/07_mutant_control.luau`: mutant re-derives the share
  locally with `math.ceil`. With odd banked income (501) the mutant
  retains 250 instead of 251 and breaks conservation (250 + 250 ≠ 501);
  the test failed exactly on the retained/conservation checks.

### N5 — Banked-income design note

**NOTE ONLY — behaviour unchanged.** `docs/N5_BANKED_INCOME_DESIGN_NOTE.md`
(documents, does not change, the finding that the live income tick banks
into player-level `data.BankedIncome` only; per-placed `BankedIncome`
never accrues in live play, so the 500 → 250/250 steal split exists today
only in test fixtures). Recommends option **(A)** (accrue per placed
Brainrot) over (B) (take the share from player-level unclaimed bank),
**conditionally**: measure steal success rate, median unclaimed bank at
steal time, and time-since-last-collect first; do not implement on fixture
numbers alone. No code was changed for this note; no option is approved.

---

## 2. Files changed

`git status` / `git diff --stat` vs HEAD `6ee6d21` (cumulative Phase 1 +
R1 + R2 — all uncommitted; the per-finding split is in §1 and the workers'
summaries, the diff itself does not separate the phases):

```
 scripts/harness-lune/shared/Economy.luau          |   19 +-
 scripts/harness-lune/shared/Remotes.luau          |    4 +
 scripts/harness-lune/shared/Types.luau            |    6 +
 src/client/Controllers/BaseController.luau        |   38 +-
 src/client/Controllers/InteractionController.luau |   13 +-
 src/client/Controllers/QuestController.luau       |    2 +-
 src/server/Services/BaseService.luau              |  227 +++-
 src/server/Services/CarryService.luau             |   41 +-
 src/server/Services/DataService.luau              |  363 +++++-
 src/server/Services/ExpeditionService.luau        |  125 +-
 src/server/Services/FusionService.luau            |   12 +
 src/server/Services/GameManager.luau              |   76 +-
 src/server/Services/LaboratoryService.luau        |   24 +
 src/server/Services/MutationService.luau          |   83 +-
 src/server/Services/QuestService.luau             |  100 +-
 src/server/Services/RaidService.luau              | 1266 +++++++++++++++++++--
 src/shared/Economy.luau                           |   19 +-
 src/shared/Remotes.luau                           |    4 +
 src/shared/Types.luau                             |    6 +
 19 files changed, 2216 insertions(+), 212 deletions(-)
```

Untracked (new files, 3 top-level entries):

- `docs/PHASE1_REPAIRS_REPORT.md` — Phase 1 report (+ R2-bundle addendum).
- `docs/N5_BANKED_INCOME_DESIGN_NOTE.md` — N5 note (see §1).
- `scripts/phase1-tests/` — 171 files total, all untracked: `harness.luau`,
  theft (14 test files + 5 service copies + 15 shared copies + `mutant/`
  with 7 control files, 6 mutant RaidServices and `economy/` with 15
  mutant shared modules + 1 RaidService copy), store, quest, expedition,
  wiring, lifecycle suites with their service/shared copies and mutant
  dirs, and one `refresh.sh` / `run*.sh` per suite.

**R2-7 additions in this pass (new files under `scripts/phase1-tests/theft/`):**

- `12_config_driven_share.luau` (E1 positive, 9 checks),
  `13_share_rounding_conservation.luau` (E2 positive, 7 checks).
- `mutant/04_mutant_control.luau` (M5), `mutant/05_mutant_control.luau`
  (M8), `mutant/06_mutant_control.luau` (E1), `mutant/07_mutant_control.luau`
  (E2); mutant services `RaidServiceM5.luau`, `RaidServiceM8.luau`,
  `RaidServiceE2.luau`, and `mutant/economy/{services,shared}/` (E1).
- `mutant/make_mutant.sh` extended (M5/M8/E2 RaidService mutants + E1
  economy mutant; every anchor asserted present exactly once; diffs
  printed and guards check the fixed code is gone), `mutant/run_mutant.sh`
  updated (7 controls, was 3).

**No game source was edited in this pass** (read-only on `src/`; no
verification run exposed a bug needing a fix). One guard fix was made to
`make_mutant.sh` itself during this pass: the E1 guard grepped for
`Config.StealRewardMultiplier`, which also appears in the mutant's own
comment — it now greps for the code pattern
`banked * Config.StealRewardMultiplier`.

---

## 3. Validation — every command run and its actual result

All commands run from the package root
`~/workspace/your_files/glitch-tide-v1.1/` unless noted. Full logs in
`/tmp/r2-*.log` (ephemeral; `/tmp` is wiped on VM restart).

### 3.1 Targeted suites (full re-runs)

| Command | Exit | Result |
|---|---|---|
| `bash scripts/phase1-tests/theft/run_all.sh` | 0 | **191 passed, 0 failed (13 files).** 01: 9, 02: 15, 03: 16, 04: 17, 05: 12, 06a: 7, 06b: 7, 07: 18, 08: 8, 09: 21, 10: 21, 11: 24, 12: 9 (new), 13: 7 (new). Was 175 before this pass; +16 from the two new E1/E2 tests. `run_all: ALL THEFT TESTS PASSED`. |
| `bash scripts/phase1-tests/store/run.sh` | 0 | **72 passed, 0 failed.** 01: 36, 02: 36. `run: ALL STORE TESTS PASSED`. |
| `LUNE=/tmp/lune-0.11.1/lune bash scripts/phase1-tests/quest/run.sh` | 0 | **59 passed, 0 failed.** `ALL 59 CHECKS PASSED`. |
| `bash scripts/phase1-tests/expedition/run.sh` | 0 | **46 passed, 0 failed** (single file `01_expedition_in_transit`). `run: ALL EXPEDITION TESTS PASSED`. |
| `bash scripts/phase1-tests/wiring/run.sh` | 0 | **10 passed, 0 failed.** |
| `bash scripts/phase1-tests/lifecycle/run.sh` | 0 | **83 passed, 0 failed (6 files).** 01: 14, 02: 11, 03: 18, 04: 17, 05: 9, 06: 14. `run: ALL LIFECYCLE TESTS PASSED`. |

Suite total this pass: **191 + 72 + 59 + 46 + 10 + 83 = 461 checks, 0 failed.**

### 3.2 Harnesses

| Command | Exit | Result |
|---|---|---|
| `python3 scripts/harness-python.py` | 0 | **70 passed, 0 failed (of 70).** |
| `bash scripts/harness-lune/refresh.sh && /tmp/lune-0.11.1/lune run scripts/harness-lune/main.luau` | 0 | **40 passed, 0 failed (of 40).** |

### 3.3 Static compilation (`luau-compile`, Luau 0.700)

| Command | Result |
|---|---|
| `luau-compile` over each of the 68 `src/**/*.luau` files | **68 files, 0 failures.** |
| `luau-compile` over each `scripts/phase1-tests/**/*.luau` + `scripts/harness-lune/**/*.luau` file | **170 files, 0 failures.** (Includes the 7 mutant controls, 6 mutant RaidServices, and the 16 mutant-economy files.) |

### 3.4 Rojo build (7.7.1, twice, into `/tmp`)

| Command | Exit | Result |
|---|---|---|
| `/tmp/rojo-7.7.1/rojo build -o /tmp/r2-build-a.rbxl` | 0 | Built. 599,209 bytes. SHA-256 `350ffe3940d929f1ddb6cf6d7108861068ee08c8814bf4b134137201fafe9c36`. |
| `/tmp/rojo-7.7.1/rojo build -o /tmp/r2-build-b.rbxl` | 0 | Built. 599,209 bytes. Same SHA-256. `cmp` confirms **byte-identical**. |

(Grew from the Phase 1 build's 570,965 bytes — expected: R2 added the
lifecycle/escrow/recovery code, pending-reward ledger, expedition guards
and wiring.)

### 3.5 `verify-rbxl.py` against the `/tmp` build

`python3 scripts/verify-rbxl.py /tmp/r2-build-a.rbxl` — exit 0,
**8 PASS, 0 failed**: magic header, header counts sane (10 classes, 76
instances), chunk stream parses (26 chunks), **68 Source values in place**,
every src file present byte-identical in place (missing=[]), no extra
place Source (extra=[]), no duplicated Source values (dups=[]), script
counts by class (66 ModuleScript + 1 LocalScript + 1 Script).

### 3.6 Tree `GlitchTide.rbxl` unchanged

`sha256sum GlitchTide.rbxl` →
`40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`,
**558,606 bytes** — identical to the pre-R2 value. The tree's rbxl still
holds pre-Phase-1 sources; rebuild with Rojo before any Studio test.

### 3.7 Stale-source drift check

Every suite's `refresh.sh` plus the Lune harness `refresh.sh` were run
individually (each refreshes its copies from current `src/` and fails if
any copy differs beyond the documented require patches):

| Refresh | Exit | Result |
|---|---|---|
| `scripts/phase1-tests/theft/refresh.sh` | 0 | 15 shared + 5 services refreshed; `refresh OK: copies match sources apart from require lines`. |
| `scripts/phase1-tests/store/refresh.sh` | 0 | 15 shared + BaseService refreshed; OK. |
| `scripts/phase1-tests/expedition/refresh.sh` | 0 | 15 shared + ExpeditionService refreshed; OK. |
| `scripts/phase1-tests/wiring/refresh.sh` | 0 | 15 shared + 4 services refreshed; OK. |
| `scripts/phase1-tests/lifecycle/refresh.sh` | 0 | 15 shared + RaidService refreshed; lifecycle anchors present in DataService / GameManager; OK. |
| `scripts/harness-lune/refresh.sh` | 0 | 15 shared refreshed; OK. (Its log prints src vs harness SHA-256s that differ for the patched files — that is the documented harness-only require patch, not drift; the script's own divergence check passed.) |

**Drift found: none.** Every copy the suites ran against is byte-identical
to `src/` apart from the documented require patches. Two caveats:
(a) the quest suite has no `refresh.sh` — it is self-contained with
hand-written stubs (`quest/stubs/{Characters,Economy,Remotes,state}.luau`)
that are **not** divergence-checked against `src/`; a stub drifting from
the real module would not be caught by a refresh. (b) The mutant files
are rebuilt from the current fixed copies by `make_mutant.sh` on every
mutant run (anchor count == 1 asserted), so they cannot silently drift
either.

### 3.8 Mutant / negative controls — all 9

| Control | Runner | Result | How the mutant failed (expected) |
|---|---|---|---|
| P4 (R2-1) | `theft/mutant/run_mutant.sh` | **VALID** (mutant failed, exit 1) | Delivered placed copy golden (not electric), income 50/s (not 40/s). |
| Watchdog (R2-3) | same | **VALID** | Placed copy unreconciled: Level 1 / Mutation nil / BankedIncome 0; `owned.Placed` unsynced. |
| R13 (R2-4) | same | **VALID** | Status `nil` instead of `"reward_pending"`; nothing recorded pending. |
| **M5** (new) | same | **VALID** | Victim/bystander get `"instance record missing"` instead of `"not carrying that Brainrot"`; impostor with a planted duplicate **completes the delivery** (paid 300, record Level 5, real thief then locked out). |
| **M8** (new) | same | **VALID** | `attempt to index nil with 'Level'` at the first snapshot write (mutant RaidService line 1430). |
| **E1** (new) | same | **VALID** | Share stays 250 at multiplier 0.25 and 0.75; delivery pays 300 / retains 250. |
| **E2** (new) | same | **VALID** | Retained 250 instead of 251; conservation 250 + 250 ≠ 501. |
| P3 (R2-2) | `expedition/mutant/run_mutant.sh` | **VALID** (2 passed, 4 failed of 6) | In-transit Brainrot appears in the eligible list; start accepted, Active entry created, flags changed. |
| R2-5 lifecycle | `lifecycle/mutant/run_mutant.sh` | **VALID** (0 passed, 4 failed of 4) | Rejoin resolves 0 stale records; victim's placed copy unrestored; thief keeps the flagged record. |

`theft/mutant/run_mutant.sh` exit 0: `run_mutant: ALL R2 MUTANT CONTROLS
VALID (all seven mutants failed as expected)`. Expedition and lifecycle
runners each exit 0 with their control valid. Positive-control check:
the M5/M8 assertions run against the fixed service pass 8/8 and 5/5;
E1/E2 positives are suite tests 12 (9/9) and 13 (7/7) on fixed code.

---

## 4. Remaining suspected / unverified risks (consolidated)

Status updates to the Phase 1 risk list (R1–R17, `docs/PHASE1_REPAIRS_REPORT.md` §4),
plus the risks the R2 workers reported:

- **R1 — FIXED** (delivery-path remainder write; see §1 / Phase 1 report §4).
- **R13 — FIXED by R2-4** (pending-reward ledger + `RecoverPendingRewards`;
  §1). The warn-only grant is gone.
- **R6 — NOT FIXED, not claimed fixed.** Fire-and-forget `SaveData`
  persists: `ConfirmDelivery`'s delivery saves are now `task.spawn` +
  observed (a failed save warns naming both accounts) instead of silent,
  but a crash before *any* save persists the delivery is still possible.
  The rejoin rule voids an unpersisted delivery rather than granting it
  (safe direction), and the leave/shutdown saves are backstops — but save
  reliability itself is unchanged. A crash window that strands a delivery
  remains possible, now visible in logs instead of silent.
- **Load-failed durability hole — ADDRESSED BY SIDECARS, NOT ELIMINATED.**
  In a load-failed session the pending-reward entry itself lived in the
  unsaveable cache, so a leave before a successful load lost the entry
  too. R2-5 adds DataStore sidecars for pending rewards (and escrow for
  victim-offline returns), which give the entry a durable home outside
  the session cache — but a sidecar write can itself fail, and a crash
  between the in-memory commit and the sidecar write still loses the
  reward. The ledger makes the failure visible and recoverable in-session
  / on a saveable rejoin; full durability is not proven.
- **Crash windows (general).** Every commit-then-save ordering in the
  theft path (steal, delivery, return, escrow) has a window where a crash
  loses the in-memory commit. Recovery rules (a)–(e) are designed to
  resolve each window deterministically on rejoin, but the windows
  themselves are inherent to the async-save design.
- **Rule (e) — legacy flagged records need manual recovery.** A stale
  `InTransit` record with **no recorded owner** (pre-R2-5, before
  `StolenFromUserId` existed) is kept flagged and warned — never deleted
  (that loses the instance) and never granted (that gives stolen goods
  away). Such an instance has **no automatic resolution path**; it sits
  flagged until someone recovers it manually. Pre-R2-5 saves that
  persisted a theft will hit this.
- **Cross-server behaviour UNPROVEN.** Nothing in these suites exercises
  two servers: a thief and victim on different servers, a victim
  rejoining a different server mid-theft, or escrow/sidecar reads across
  servers. The escrow and sidecar keys are per-UserId DataStore keys, so
  cross-server recovery is *designed* in, but it has never been executed.
- **Core-services `wireAll` gap — PARTIALLY ADDRESSED.** R2-6 fixed the
  one observed symptom (CompanionService) with an explicit block in
  `wireCrossLinks`. The underlying gap — core services never get the
  `wireAll` pass — is still there; any future cross-link added the same
  way would need another explicit block, and a missing one would fail
  silently the same way (the wiring test only covers the companion link).
- **Mutation visual re-apply — Studio-only.** `MutateBrainrot` syncs the
  placed copy and calls `RebuildBase`, and `BaseController` has no
  `MutationApplied` handler (the 3D model is built server-side from
  `placed.Mutation`), so the display *should* update — but no test here
  renders a model. Live visual confirmation needs Studio (§5).
- **R2 — QuestService `rateOk` shared bucket.** Unchanged by R2:
  one `_rate[player]` timestamp shared across every rate-limited action.
- **R3 — No client feedback on rejected claims.** Unchanged: silent
  return + server `warn` only.
- **R4 — Double push on two-event `ReportProgress`.** Unchanged, cosmetic.
- **R5 — `ClaimQuest` fallback XP loop equivalence to
  `ProgressionService` unverified.** Unchanged.
- **R7 / R8 — `PollInTransit` race / stranded carry.** Largely defensible
  (double-call safe; poll confirm is a redundant net in the normal flow);
  residual narrow case (placed copy appearing via another writer; carry
  desync after a poll-driven confirm) still Studio-only.
- **R9 — Store `OwnerUserId` defence-in-depth inert for ownerless data.**
  Unchanged; the `findPlaced` lookup is the real enforcement.
- **R10 — Store write-back before `RemovePlaced` commits.** Unchanged;
  not transactional.
- **R11 — Shared 0.25 s BaseService throttle.** Unchanged, pre-existing.
- **R12 — Lune `typeof` Vector3 limitation.** Unchanged; bounds what the
  suites can prove about distance/position code.
- **R14 — `ReturnStolen` victim-offline destroy path.** Deliberate design
  (thief never keeps stolen goods for free), but a transient move failure
  while the victim's data is merely unloading would still destroy the
  instance. R2-5's escrow is the mitigation for the offline case; the
  destroy-on-move-failure branch still exists. Studio-only to verify.
- **R15 — `StoreBrainrot` Glitched write-back assumes sync.** Unchanged;
  the `UpgradeBrainrot` sync it relies on was not re-verified.
- **R16 — Strict-analysis noise.** Classified, not fixed; no runtime defect.
- **R17 — Suite scope limits.** Lune suites run real service modules with
  stubbed Roblox globals, fake players/data, no latency, no real
  `Instance`s, no DataStore, no cross-server effects, no 5 s poll timing
  (watchdog invoked manually). Anything in §5 remains unverified.

---

## 5. Studio-only tests still required

None of the following was verified here; each needs a real Studio place
with real players (Grok Build). Carried forward from Phase 1 §5, plus R2
additions marked (R2):

1. Claim UI end-to-end (R3): rejected claim shows the player a reason.
2. STORE button click-through; rapid place→store / collect→store against
   the 0.25 s throttle (R11).
3. Live steal → delivery → return with two real clients; thief death and
   manual drop returning the instance with all fields; victim offline
   mid-theft (R14).
4. Camera / pedestal distance in a real place (`PLACE_DISTANCE = 12`);
   out-of-range delivery rejection.
5. DataStore round-trip: claim, steal/deliver, store, rejoin — committed
   state persisted (R6), no duplicate/lost instance after rejoin.
6. 12-player behaviour: concurrent steals/returns, poll timing under load.
7. `PollInTransit` timing: 5 s cadence, 2 s grace, delivery detection vs
   `PlaceBrainrot`'s own confirm (R7/R8); no stranded carry visual after
   a poll-driven confirm.
8. Companion carry speed live: `applyCarrySpeed` with a real companion
   wired (16 × 0.75 = 12) vs unwired (16 × 0.6 = 9.6) — **(R2)** this is
   the live check for the R2-6 wiring fix.
9. Quest push delivery, including the two-event double push (R4).
10. Delivered-copy fields after the R1 fix: banked remainder (250 of 500)
    and `PlacedAt` = delivery time surviving a live steal → delivery.
11. Mutation mirror live: two same-character instances, one placed +
    glitched — right instance flagged, real mutation never clobbered.
12. **(R2)** Mutation visual re-apply: mutate a placed Brainrot live and
    confirm the 3D model / income display updates (placed-copy sync +
    `RebuildBase`).
13. **(R2)** Watchdog live: leave a stolen Brainrot placed without
    delivering (e.g. via the poll path) and confirm the placed copy is
    reconciled from the owned record in the live game.
14. **(R2)** Pending-reward rejoin: force a grant failure (or unsaveable
    session), leave, rejoin — confirm the reward is recovered exactly
    once via `RecoverPendingRewards` / sidecar.
15. **(R2)** Leave / shutdown / rejoin lifecycle: thief leaves mid-theft,
    victim leaves mid-theft, server shutdown mid-theft, victim-offline
    escrow + rejoin — confirm exactly one owner afterwards and no
    duplicated or destroyed instance; confirm a legacy (pre-R2-5)
    flagged record stays flagged for manual recovery (rule (e)).
16. **(R2)** Expedition after return: steal, return, then send the
    victim's Brainrot on an expedition — confirm no lockout (orphan-flag
    auto-clear, wired and fallback paths).
17. **(R2)** Cross-server: victim rejoins a *different* server mid-theft
    and confirms escrow/sidecar recovery works there.

---

## 6. Bottom line

- R2-1…R2-7 are all **fixed and Lune-verified** in this pass; N5 is a
  design note with behaviour unchanged.
- **461 suite checks + 70 Python + 40 Lune harness checks, 0 failed.**
  `luau-compile`: 68 src + 170 test files, 0 failures. Rojo 7.7.1 builds
  twice byte-identical (SHA-256
  `350ffe3940d929f1ddb6cf6d7108861068ee08c8814bf4b134137201fafe9c36`,
  599,209 bytes). `verify-rbxl.py`: 0 failed, 68/68 sources
  byte-identical in the place.
- **All 9 mutant controls valid** (P4, watchdog, R13, M5, M8, E1, E2,
  P3, lifecycle) — each mutant failed its assertions in the intended way.
- **No drift:** every test copy matches current `src/` apart from
  documented require patches (quest stubs excepted — not refresh-checked).
- **Tree `GlitchTide.rbxl` unchanged** (SHA-256
  `40f0cf4fd5bdf630687ebd4d3f0f9ae5ef849894697ebc3d6e4d27933d1b3af0`,
  558,606 bytes) — rebuild with Rojo before any Studio test.
- **Not fixed / not proven, stated plainly:** R6 save reliability;
  load-failed durability (sidecars mitigate, not eliminate); rule-(e)
  legacy records need manual recovery; cross-server behaviour unproven;
  core-services `wireAll` gap only patched for the companion link; all
  §5 Studio-only tests still outstanding. No Studio behaviour is claimed
  verified anywhere in this report.
