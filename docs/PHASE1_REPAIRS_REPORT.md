# GLITCH TIDE v1.1.0 — Phase 1 Repairs: Independent Final Validation Report

**Validator:** independent agent (did not implement any Phase 1 work).
**Date:** 2026-11-19 (IST). **Base:** local HEAD `6ee6d21` — verified with
`git rev-parse HEAD` at start and again at end; HEAD unchanged, no commits created.
**Scope:** only `~/workspace/your_files/glitch-tide-v1.1/`. No Roblox publish, no
GitHub push, no commits. No source edits were made by this validator (zero
analysis errors required a fix — see §4).

**Verdict in one line:** all three targeted Lune suites re-run green
(103 + 59 + 63 checks), both existing harnesses green (70 + 40), compile
68/68 + 54/54, Rojo ×2 byte-identical, place verified 68/68 — **but P1-14 is
only partially fixed**: the RETURN path preserves fields, the DELIVERY path
still loses `BankedIncome`/`PlacedAt` (known open item, confirmed accurate
below). Nothing Studio-only is claimed as verified.

**Addendum — R1 fixed after this report (2026-11-19, user decision):**
direct snapshot writes in `RaidService.ConfirmDelivery` (no accessor).
P1-14 is now **fully fixed** — see §1 P1-14 and §4 R1. The verdict above
and its suite counts describe the pre-R1 state; the R1 regression tests
(`store/02_delivery`, theft `04`) were extended and re-run green after
the fix (see the R1 report delivered with the fix).

**Finding-ID mapping note:** the original Phase 1 finding texts are not in
this tree; the IDs below are mapped from the task brief plus the test-file
headers (`scripts/phase1-tests/quest/main.luau`, `theft/0*.luau`,
`store/0*.luau`) and in-code `(P0-4)` / `(P1-2)` / `(P1-14)` tags.

---

## 1. Finding-by-finding status

| Finding | Status | Evidence |
|---|---|---|
| **P0-1** — Quest claim payload mismatch: client fired bare `questId`, server `onClaim` expected an envelope (or vice versa), so claims never landed | **FIXED** | `src/client/Controllers/QuestController.luau:275` now fires `{ Action = "ClaimQuest", QuestId = id }`; `src/server/Services/QuestService.luau:638-641` `onClaim` accepts the envelope AND the legacy bare string, ignores anything else. Quest tests P0-1a (envelope), P0-1b (legacy), P0-1c (bad payloads rejected, no reward) + duplicate-claim sections — all inside the 59/59 quest run. |
| **P0-2** — `RecordEvent` calls `forwardProgress` before its definition (forward-reference), erroring under `--!strict` | **FIXED** | `src/server/Services/QuestService.luau:336` `EVENT_KIND_MAP`, `:353` `forwardProgress`, `:376` `RecordEvent` (call at `:415`) — all defined above first use. HEAD-baseline `luau-analyze --mode=strict` reported `Unknown global 'forwardProgress'` at HEAD `QuestService.luau:372` + `FunctionUnused` for `forwardProgress`; current tree reports **zero** occurrences of the name in analysis output. Quest test §P0-2 + 59/59. |
| **P0-3** — Theft/delivery integrity: stolen instances duplicable / losable across steal → deliver / return (fuse-then-return, double return, double delivery, consumption mid-transit) | **FIXED** (Lune-verified; live multi-player behaviour is Studio-only, see §5) | `InTransit` flag `src/shared/Types.luau:182`; guards `FusionService.luau:193`, `MutationService.luau:468`, `LaboratoryService.luau:396/510/657`, `CarryService.luau:153`; `RaidService.luau` rewrite — full snapshot at steal (`:1300-1315`), exactly-once `ReturnStolen` (`:901-1015`, no-recreate at `:927-939`), `ConfirmDelivery` verifies ownership before committing (`:1041-1095`, owned-record check at `:1047-1050`), `PollInTransit` watchdog (`:773-856`). Theft suite 103/103 (files 01–08) + store `02_delivery.luau` 27/27. |
| **P0-4** — No way to un-place a Brainrot back into inventory (no `StoreBrainrot`, no STORE button) | **FIXED** (Lune-verified; button click-through is Studio-only, see §5) | `BaseService.StoreBrainrot` `src/server/Services/BaseService.luau:1234-1310` + remote handler `onStoreBrainrot` `:1539-1600`; `StoreBrainrot` remote `src/shared/Remotes.luau:35,206`; STORE button `src/client/Controllers/BaseController.luau:255-280`. Store suite `01_store.luau` 36/36. |
| **P1-1** — In-transit / on-expedition instances could still be consumed or carried (fuse / mutate / evolve / trait / lab / carry) | **FIXED** | Guards listed under P0-3 (same sites). Theft `01_fuse_in_transit.luau` 9/9, `02_guards_in_transit.luau` 15/15, `05_expedition_guards.luau` 12/12. Carry guard checks the live owned record as well as the passed table (`CarryService.luau:147-175`). |
| **P1-2** — `PlaceBrainrot` confirmed the stolen delivery BEFORE validation, so a failed placement consumed the transit / paid the reward | **FIXED** | `src/server/Services/BaseService.luau:1018-1156`: all validation (slot, ownership, already-placed, carry, plot, pedestal, distance `:1118-1130`) runs first; `ConfirmDelivery` is called only at `:1133-1146` (comment at `:1131` states the order). Failed placement returns before confirming, transit stays live, no reward. Store `02_delivery.luau` 27/27, incl. out-of-range delivery failing without confirming. |
| **P1-14** — Returning a stolen Brainrot lost the placed copy's fields (banked income, placement time, evolution/traits) | **FIXED** (return path in Phase 1; delivery path in the post-Phase-1 R1 fix, §4 R1) | **Return path — FIXED:** snapshot captures every field (`RaidService.luau:1300-1315`, incl. `BankedIncome`, `PlacedAt`, `Evolved*`, `TraitLevels` copied not aliased); restore via preferred `reinsertPlacedFull` (`:395-421`, tops up evolution/trait fields dropped by `PlaceBrainrot`'s fixed-field table) or local `reinsertPlaced` (`:302-391`) with an explicit duplicate guard (`:327-333`, "never insert a second placed copy"). Theft `06a` 7/7 (preferred path) + `06b` 7/7 (local fallback). **Delivery path — FIXED:** `ConfirmDelivery` writes the snapshot onto the thief's owned record before clearing `InTransit` (Level/Mutation/Glitched/Evolved/TraitLevels verbatim; `BankedIncome` = floored banked − paid share via shared `Economy.StealRewardShare`; `PlacedAt = os.time()`, restarting the 120 s window intentionally); `PlaceBrainrot` builds the delivered copy from that updated record. Store `02_delivery` + theft `04` regression tests green. |

### Known open item — VERIFIED ACCURATE (not re-fixed, per brief)

The claim is accurate in full, confirmed against the code (not just the
tests):

- Steal snapshot **does** capture the fields: `RaidService.luau:1312-1315`
  (`PlacedAt = tonumber(placed.PlacedAt) or os.time()`,
  `BankedIncome = tonumber(placed.BankedIncome) or 0`) into `_inTransit`.
- The snapshot lives **only** in `RaidService._inTransit` (`:79`); there is
  no accessor — `BaseService` cannot read it (stated in the code comment at
  `BaseService.luau:1163-1171`).
- `ConfirmDelivery` (`RaidService.luau:1041-1095`) never writes snapshot
  fields onto the owned record: it only clears `owned.InTransit = nil`
  (`:1054`), clears the transit entry, pays the reward from
  `record.BankedIncome`, and unlocks the character. The owned record's own
  `BankedIncome`/`PlacedAt` are untouched.
- `PlaceBrainrot` builds the delivered copy from the **owned** record
  (`BaseService.luau:1172-1173`: `BankedIncome = tonumber(owned.BankedIncome)
  or 0`, `PlacedAt = tonumber(owned.PlacedAt) or os.time()`), and the moved
  owned record carries neither field in the normal flow (income accrues on
  the placed copy, not the owned record).
- Documented evidence in tests: `scripts/phase1-tests/store/02_delivery.luau`
  checks **14** ("delivered owned record carries no BankedIncome to
  preserve", `BankedIncome=nil`) and **15** ("delivered placed copy
  BankedIncome is 0, not the victim's 500", `BankedIncome=0`) — both PASS,
  asserting current behaviour as a known limit, not as a fix.
- Consequence: a delivered stolen Brainrot loses its victim-side banked
  income (the thief is still paid the steal reward from the snapshot, so
  the income is not duplicated — it is destroyed on the victim side and
  re-created as reward) and its `PlacedAt` resets to now (re-arming the
  120 s recently-placed protection window). Fixing it needs a design
  decision the brief does not settle (accessor on `RaidService` vs writing
  snapshot fields onto the owned record in `ConfirmDelivery`); not done here.

---

## 2. Exact files changed vs HEAD `6ee6d21`

`git diff --stat` at end of validation (HEAD still `6ee6d21`):

```
 scripts/harness-lune/shared/Remotes.luau          |   4 ++++
 scripts/harness-lune/shared/Types.luau            |   6 ++++++
 src/client/Controllers/BaseController.luau        |  38 +-
 src/client/Controllers/InteractionController.luau |  13 +-
 src/client/Controllers/QuestController.luau       |   2 +-
 src/server/Services/BaseService.luau              | 226 +++++++++---
 src/server/Services/CarryService.luau             |  41 ++-
 src/server/Services/FusionService.luau            |  12 +
 src/server/Services/LaboratoryService.luau        |  24 ++
 src/server/Services/MutationService.luau          |  26 +-
 src/server/Services/QuestService.luau             | 100 +++---
 src/server/Services/RaidService.luau              | 403 +++++++++++++++++++---
 src/shared/Remotes.luau                           |   4 +
 src/shared/Types.luau                             |   6 +
 14 files changed, 749 insertions(+), 156 deletions(-)
```

Plus untracked `scripts/phase1-tests/` (new test tree, 54 `.luau` files) and
this report (`docs/PHASE1_REPAIRS_REPORT.md`, new).

**Note on the file count:** at task start `git status` showed **13** modified
files (745 insertions). The 14th file,
`scripts/harness-lune/shared/Remotes.luau` (+4), appeared during *this*
validation: running the instructed Lune harness (`bash
scripts/harness-lune/refresh.sh`) regenerates its `shared/` copies from the
changed `src/shared/Remotes.luau`. It is a derived copy, not an
implementation-agent change and not a hand edit — the refresh script's
divergence check passed (exit 0), so the copy matches `src/` apart from the
harness-only require patch. Same applies to
`scripts/harness-lune/shared/Types.luau` (was already modified at task start).

**No file outside the implementation agents' allowed lists is modified.**
Allowed: the 12 `src/` files above + `scripts/harness-lune/shared/Types.luau`
(derived copy) + new `scripts/phase1-tests/`. Nothing else in the tree
changed. No commits created. The v1.0.2 backup
`~/workspace/your_files/brainrot-battle-arena/` is untouched (HEAD
`76f1930`, `git status` clean, no file modified after 2026-11-19 05:00).

### Diff summary per file

- `src/shared/Types.luau` (+6): `InTransit: boolean?` added to
  `OwnedBrainrot` with a comment stating the while-true lock contract.
- `src/shared/Remotes.luau` (+4): `StoreBrainrot` added to `Remotes.Names`,
  to the event-name list, and to the client-firer comment.
- `src/server/Services/RaidService.luau` (+403/−~150, the rewrite):
  `_inTransit` snapshot table; full snapshot at steal incl. banked income /
  placed-at / evolution / trait levels; `ReturnStolen` exactly-once with
  no-recreate-on-consumed-record, victim-offline destroy-instead-of-keep
  branch, retry-safe move-back; `ConfirmDelivery` ownership verification
  before commit (transit cleared before reward); `reinsertPlacedFull` /
  `reinsertPlaced` with duplicate guards; `PollInTransit` watchdog
  (BaseService + direct-data delivery detection, 2 s grace, drop detection);
  `moveOwnedRecord` returns the moved record so the flag lands on the exact
  record; steal rollback if the ownership transfer fails.
- `src/server/Services/BaseService.luau` (+226): `PlaceBrainrot` reordered
  (all validation before `ConfirmDelivery`), stolen branch resolves by exact
  `InstanceId` with no mint fallback, placed copy preserves
  `owned.BankedIncome`/`owned.PlacedAt` when present; new `StoreBrainrot`
  with write-back (Level/Glitched/Mutation-fill-in/BankedIncome/PlacedAt/
  evolution fields) + rejection paths; whole-record `reinsertPlacedRecord`
  shape (duplicate-aware); `onStoreBrainrot` remote handler.
- `src/server/Services/QuestService.luau` (+100/−~): `EVENT_KIND_MAP` +
  `forwardProgress` moved above `RecordEvent`; `RecordEvent` is the single
  funnel (forward once per event, push once if changed); `onClaim` accepts
  envelope + legacy bare string; `ClaimQuest` validates via sanitize +
  `_byId`, duplicate-claim check before reward with flag set before grants,
  XP via `ProgressionService.AddXP` with an inline-loop fallback that
  mirrors its rewards (per the code comment).
- `src/server/Services/CarryService.luau` (+41): file-scope
  `_companionService` declared at `:29` (was referenced but never declared —
  the `applyCarrySpeed` bug), assigned at `:424`; `transitLocked` helper and
  guards in pickup paths checking both the passed table and the live owned
  record.
- `src/server/Services/FusionService.luau` (+12): `InTransit` /
  `OnExpedition` rejection for both inputs before consuming.
- `src/server/Services/LaboratoryService.luau` (+24): same guards in
  evolve, trait-upgrade, and alternate-form paths.
- `src/server/Services/MutationService.luau` (+26/−): `InTransit` /
  `OnExpedition` guard in `MutateBrainrot`; `GetInstances` now matches
  placed copies by `InstanceId` instead of `CharacterId` (`:277-283`) and
  no longer overwrites `inst.Mutation` with `"glitched"` (sets
  `Glitched = true` only).
- `src/client/Controllers/QuestController.luau` (1 line): `Claim` fires
  `{ Action = "ClaimQuest", QuestId = id }` instead of the bare id.
- `src/client/Controllers/InteractionController.luau` (+13/−2):
  forward declarations `local promptFor` / `local showPrompt` at `:91-92`;
  the definitions below assign to those locals (`promptFor = function…`,
  `showPrompt = function…`) instead of `local function`.
- `src/client/Controllers/BaseController.luau` (+38/−): STORE button per own
  placed Brainrot in the placed list, firing the `StoreBrainrot` remote.

---

## 3. Every test command run and its actual result

Toolchain (re-downloaded during this validation because `/tmp` had been
wiped; the pre-existing `/tmp/luau-tools` 0.700 and `/tmp/lune-0.11.1` were
present and used where the brief names them, except where noted):

- Lune **0.11.1** — `/tmp/lune-0.11.1/lune` (`lune --version` → `lune 0.11.1`).
- Luau **0.747** — freshly downloaded `luau-ubuntu.zip` from
  `luau-lang/luau` releases, extracted to `/tmp/luau-0.747/`
  (`luau`, `luau-analyze`, `luau-ast`, `luau-compile`).
- Rojo **7.7.1** — freshly downloaded
  `rojo-7.7.1-linux-x86_64.zip` from `rojo-rbx/rojo` releases
  (the first attempt with the wrong asset name `rojo-linux.zip` 404'd;
  correct asset found via the GitHub releases API), extracted to
  `/tmp/rojo-7.7.1/rojo` (`rojo --version` → `Rojo 7.7.1`).

### 3.1 Targeted Phase 1 suites (re-run from a clean state, not trusted)

| Command | Exit | Result |
|---|---|---|
| `bash scripts/phase1-tests/theft/run_all.sh` (refreshes copies, runs `01`–`08`) | 0 | **103 passed, 0 failed** — 01: 9, 02: 15, 03: 16, 04: 11, 05: 12, 06a: 7, 06b: 7, 07: 18, 08: 8. Matches the claimed 103. `run_all: ALL THEFT TESTS PASSED`. Full log: `/tmp/phase1-theft.log`. |
| `LUNE=/tmp/lune-0.11.1/lune bash scripts/phase1-tests/quest/run.sh` (quest `run.sh` defaults `LUNE=lune`, not on PATH, so the path was passed explicitly) | 0 | **59 passed, 0 failed** — `ALL 59 CHECKS PASSED`. Matches the claimed 59. Full log: `/tmp/phase1-quest.log`. |
| `bash scripts/phase1-tests/store/run.sh` (refreshes theft + store copies, runs `01`–`02`) | 0 | **63 passed, 0 failed** — `01_store`: 36, `02_delivery`: 27. Matches the claimed 36+27. `run: ALL STORE TESTS PASSED`. Full log: `/tmp/phase1-store.log`. |

The refresh scripts' divergence checks passed in every run (copies match
`src/` apart from the require patches), so the suites ran the real current
sources, not stale copies.

### 3.2 Existing harnesses

| Command | Exit | Result |
|---|---|---|
| `python3 scripts/harness-python.py` | 0 | **70 passed, 0 failed (of 70)**. Full log: `/tmp/phase1-py.log`. |
| `bash scripts/harness-lune/refresh.sh && /tmp/lune-0.11.1/lune run scripts/harness-lune/main.luau` | 0 | **40 passed, 0 failed (of 40)**. Full log: `/tmp/phase1-luneharness.log`. (Side effect: regenerated `scripts/harness-lune/shared/Remotes.luau` — see §2 note.) |

### 3.3 Luau compile (Luau 0.747)

Note: `luau-compile --mode=null …` is a wrong invocation (rejected:
`Unrecognized option '--mode=null'`, and bare `null` is treated as a
filename). The bare per-file form used by prior QA (`/tmp/luau-compile
<file>`) was used instead.

| Command | Exit | Result |
|---|---|---|
| `/tmp/luau-0.747/luau-compile <file>` for each of the 68 `src/**/*.luau` files | 0 per file | **68/68 PASS, 0 failures.** |
| Same, for each of the 54 `scripts/phase1-tests/**/*.luau` files | 0 per file | **54/54 PASS, 0 failures.** |

### 3.4 Static analysis (`luau-analyze`, Luau 0.747)

No `.luaurc` exists in the tree and no Roblox type definitions are
available, so standalone `luau-analyze` reports heavy **environmental
noise** (unknown Roblox globals/types: `game`, `script`, `task`, `warn`,
`workspace`, `Player`, `Color3`, `Vector3`, `Instance`, `RemoteEvent`,
`Enum`, `UDim2`, …; unknown `require` paths). That noise is pre-existing
and identical in kind at HEAD. The analysis below is therefore reported as
a **before/after comparison on the named errors plus a scan for any new
user-defined unknown global**, not as a raw error count.

| Command | Result |
|---|---|
| `luau-analyze --mode=strict --formatter=gnu <12 changed src files>` (current) | 1,088 diagnostic lines. **Zero** occurrences of `_companionService`, `promptFor`, `showPrompt`, `forwardProgress`. Every remaining `Unknown global` is a Roblox built-in (incl. `Vector2`, which the first grep filter missed). |
| Same command on HEAD versions (copied via `git show HEAD:<path>` into `/tmp/phase1-head/`, analysed there — uncommitted work never stashed or touched) | 1,054 diagnostic lines, **including the three named errors**: `showPrompt` ×6 unknown-global (`InteractionController.luau:385,388,405,408,412,414` at HEAD) + `promptFor` ×1 (`:388`) + 2 `LocalShadow` warnings; `_companionService` ×2 (`CarryService.luau:152-153` at HEAD); `forwardProgress` ×1 (`QuestService.luau:372` at HEAD) + `FunctionUnused` for `forwardProgress`. |
| Whole-tree `--mode=strict` (all 68 `src/` files) | 7,111 diagnostic lines; all `Unknown global` hits are Roblox built-ins (full breakdown in `/tmp/phase1-analyze-all-strict.log`). |
| Whole-tree default (nonstrict) | 6,727 diagnostic lines; `Unknown global` breakdown: `Color3` 1029, `Enum` 691, `Vector3` 636, `UDim2` 536, `CFrame` 414, `Instance` 340, `task` 277, `game` 155, `warn` 141, `script` 95, `workspace` 63, `Vector2` 30, `UDim` 29, `NumberRange`/`NumberSequence` 12 each, `ColorSequenceKeypoint`/`NumberSequenceKeypoint` 9/16, `TweenInfo` 13, `RaycastParams` 6, `BrickColor` 2, `ColorSequence` 7, `Workspace` 1 — **no user-defined name anywhere**. |

**Before/after per file (strict, current vs HEAD):** `BaseController`
170 vs 163, `InteractionController` 110 vs 118, `QuestController` 103 vs
103, `BaseService` 175 vs 157, `CarryService` 117 vs 118, `FusionService`
28 vs 28, `LaboratoryService` 81 vs 81, `MutationService` 44 vs 45,
`QuestService` 74 vs 76, `RaidService` 101 vs 87, `Remotes` 17 vs 17,
`Types` 10 vs 10. The increases in `BaseService` (+18), `RaidService`
(+14) and `BaseController` (+7) are entirely the same environmental
classes (more `warn`/`Player`/`Vector3`/`RemoteEvent` mentions in new
code). A message-multiset diff confirms **no new error kind** in any
changed file except the items classified below.

**Named-error verification — all three GONE:**
- CarryService `_companionService` in `applyCarrySpeed`: GONE. The name is
  now a file-scope local (`CarryService.luau:29`), used at `:170-171`,
  assigned at `:424`.
- InteractionController `promptFor` / `showPrompt`: GONE. Forward
  declarations at `:91-92`, assignments at `:427` / `:461`.
- QuestService `forwardProgress`: GONE. Defined at `:353`, above
  `RecordEvent` at `:376`.

**Remaining new-in-current diagnostics, classified (no fix needed, no edit made):**
- `BaseService.luau:1158-1188` — "Value of type `{ [string]: any }?` could
  be nil" ×7. Analyzer cannot narrow `owned` after its nil-check; the code
  nil-checks `owned` before use (`:1150-1153`). Runtime-safe; strict-mode
  noise. **Environmental — not fixed.**
- `InteractionController.luau:707` — "Cannot call a value of the union
  type" ×1 (`showPrompt("💡 " .. hint)`). Strict-mode artifact of the
  forward-declared function type; `showPrompt` is assigned before `Init`
  runs. **Environmental — not fixed.**
- `MutationService.luau` — `InstanceId`-keyed table-shape errors ×6,
  replacing the HEAD `CharacterId`-keyed equivalents ×7 (same class,
  re-keyed by the InstanceId-matching fix). **Pre-existing pattern — not fixed.**
- `RaidService.luau:1190` — `LocalShadow: Variable 'reason' shadows
  previous declaration at line 1163` ×1 (the same lint existed at HEAD at
  `:928`). Cosmetic lint only. **Pre-existing pattern — not fixed.**
- `CarryService.luau:287` — "Expected this to be" ×1: same class and count
  as HEAD (pre-existing `unknown`-type fallout from unresolvable requires).
  **Environmental — not fixed.**

**Analysis errors fixed by this validator: none.** No real
implicit-global / forward-reference error remains, so no code edit was made.

### 3.5 Rojo build ×2 (Rojo 7.7.1)

| Command | Exit | Result |
|---|---|---|
| `/tmp/rojo-7.7.1/rojo build -o /tmp/phase1-build-a.rbxl` | 0 | Built. 570,965 bytes. |
| `/tmp/rojo-7.7.1/rojo build -o /tmp/phase1-build-b.rbxl` | 0 | Built. 570,965 bytes. |
| `sha256sum` both + `cmp` | — | **Byte-identical.** SHA-256 `d49941d354c313a33ac20f01eb34c05ee2bde620023b94ef49614505e7a2cba8` for both. (Differs from the committed v1.1 rbxl, 558,606 bytes / SHA `40f0cf4f…` — expected, since `src/` changed; the committed `GlitchTide.rbxl` was NOT rebuilt or committed by this validator.) |

### 3.6 Place verification

| Command | Exit | Result |
|---|---|---|
| `python3 scripts/verify-rbxl.py /tmp/phase1-build-a.rbxl` | 0 | **0 failed.** `rbxl magic header` PASS; `header counts sane` (classes=10, instances=76); `chunk stream parses` (26 chunks); **68 Source values in place**; **every src file present byte-identical in place** (missing=[], extra=[], dups=[]); script counts **66 ModuleScript + 1 LocalScript + 1 Script**. The built place's script bytes match the **current working-copy sources**, not stale copies. Full log: `/tmp/phase1-verify.log`. |

### 3.7 Guard check

- `git rev-parse HEAD` → `6ee6d217019af75f3f0c54357150aad470060aaa` at start
  and end. **No commits created.**
- `git status --short` at end: the same 13 modified files as at start, plus
  `scripts/harness-lune/shared/Remotes.luau` (derived copy regenerated by
  the instructed Lune-harness run — see §2) and untracked
  `scripts/phase1-tests/` + this report. No other file modified.
- Backup `~/workspace/your_files/brainrot-battle-arena/`: HEAD `76f1930`,
  `git status` clean, untouched.

### 3.8 Spot-checks (code read directly, not test output alone)

| Check | Verdict | Location |
|---|---|---|
| (a) `ReturnStolen` no-recreate when the owned record is gone | **CONFIRMED** | `src/server/Services/RaidService.luau:927-939` — `owned == nil` → clear `_inTransit`, clear `CarryingStolen`, warn "no placed copy recreated", `return false`. Exactly-once: entry cleared only after commit (`:979`); a second call finds no record and returns false (`:902-904`). Retried returns are idempotent: local `reinsertPlaced` refuses a second placed copy (`:327-333`) and shape-2 `reinsertPlacedRecord` returns the existing copy (`BaseService.luau:963-966`). |
| (b) `PlaceBrainrot` validation-before-`ConfirmDelivery` + `InstanceId` resolution | **CONFIRMED** | `src/server/Services/BaseService.luau:1018-1156`. Stolen branch resolves by exact `InstanceId` (`:1068-1077`), "never by CharacterId, and never mint a fallback"; all validation incl. distance (`:1118-1130`) precedes `ConfirmDelivery` (`:1133-1146`); on failure it returns before confirming. |
| (c) `StoreBrainrot` write-back + rejection paths | **CONFIRMED** | `src/server/Services/BaseService.luau:1234-1310`. Rejections: invalid player/instance, no base, not-your-base (`OwnerUserId` defence-in-depth, `:1255-1262`), not placed, not owned, `InTransit`, `OnExpedition`. Write-back at `:1285-1300` (Level, Glitched, Mutation fill-in only, BankedIncome/PlacedAt conditional, evolution fields if present). Caveat: write-back happens **before** `RemovePlaced` commits — see §4 R10. |
| (d) `onClaim` legacy-string acceptance + `QuestId` validation | **CONFIRMED** | `src/server/Services/QuestService.luau:631-652`. Envelope `{Action="ClaimQuest", QuestId}` at `:638-639`, legacy bare string at `:640-641`, anything else ignored. Validation inside `ClaimQuest` (`:530-556`): sanitize + `_byId` lookup ("invalid quest id" / "unknown quest"), `Claimed` check (`:548`) with flag set (`:556`) **before** any reward is granted. |
| (e) `forwardProgress` placement above `RecordEvent` | **CONFIRMED** | `src/server/Services/QuestService.luau:336` (`EVENT_KIND_MAP`), `:353` (`forwardProgress`), `:376` (`RecordEvent`, call at `:415`). |

Also spot-confirmed: `GetInstances` InstanceId matching
(`MutationService.luau:277-283`); the glitched-mutation clobber fix
(`Mutation` no longer overwritten with `"glitched"`); `QuestController`
envelope fire (`QuestController.luau:275`); STORE button
(`BaseController.luau:255-280`); `StoreBrainrot` remote
(`Remotes.luau:35,206`); `CarryService` companion fix
(`:29` declaration, `:170-171` use, `:424` assignment); steal snapshot
fields (`RaidService.luau:1300-1315`).

---

## 4. Remaining suspected / unverified risks

**R1 — FIXED (post-Phase-1 decision, direct snapshot writes).** The user
chose direct snapshot writes inside `RaidService.ConfirmDelivery` (no
accessor). `ConfirmDelivery` now writes the snapshot onto the thief's
owned record before clearing `InTransit`: Level, Mutation, Glitched,
Evolved fields and TraitLevels (copied) verbatim; `BankedIncome` =
floored banked − the share already paid, computed by the new shared
`Economy.StealRewardShare` (the same single computation `StealReward`
uses — no second formula; fixture 500 → 250 paid, 250 retained);
`PlacedAt = os.time()` at delivery — a new placement in the thief's
base, so the 120-second protection window restarts, intentionally, not
data loss. `PlaceBrainrot` builds the delivered copy from the updated
owned record (its `ConfirmDelivery` call already precedes the copy
build, and `owned` is re-resolved after it). Regression tests:
`store/02_delivery` Pair A (remainder 250 on owned + placed, PlacedAt
= delivery time, TraitLevels survive, failed delivery writes nothing)
and Pair B (direct confirm + repeated confirm is a no-op), theft `04`
(direct + watchdog delivery, repeated confirm pays/writes nothing).
Return path unaffected. Studio-only to verify any fix end-to-end.

**R2 — `rateOk` shared bucket (QuestService).** CONFIRMED in code:
`QuestService.luau:157-173` — the fallback path ignores the `key` argument
and uses a single `_rate[player]` timestamp for every rate-limited action.
A claim within 1 s of any other rate-limited call by that player is
rejected (and vice versa). Only mitigated if `Security.RateLimit` exists
and honours keys. Pre-existing pattern, not introduced by Phase 1.

**R3 — No client feedback on rejected claims.** CONFIRMED:
`onClaim` (`QuestService.luau:645-652`) silently returns on rate-limit or
failed claim; the only signal is a server-side `warn`. A player whose
claim is rejected (rate-limit, goal not met, already claimed) sees the
client's generic "Claiming reward — waiting…" status and a refresh 1.5 s
later, with no reason shown. Client-visible; needs a client status push to
fix.

**R4 — Double push on two-event `ReportProgress`.** CONFIRMED as real but
minor: `ReportProgress` (`QuestService.luau:520-524`) calls `RecordEvent`
once per mapped event, and each `RecordEvent` calls `pushProgress` when
progress changed (`:415-418`). One `ReportProgress` mapping to two events
(e.g. `defeat_boss_colossus` → `defeat_boss` + `defeat_boss_colossus`) sends
**two** `QuestUpdate` pushes for one boss kill. Achievement/challenge
forwarding is still exactly once — `defeat_boss_colossus` has no
`EVENT_KIND_MAP` entry, so only `defeat_boss` forwards (quest test asserts
this, 1 call) — but the push count for the two-event case is **not**
asserted by any test. Cosmetic duplicate traffic, not a correctness bug.

**R5 — `ClaimQuest` fallback XP loop.** Present in code
(`QuestService.luau:~575-595`): when `ProgressionService` is not linked,
an inline loop pays level-up rewards and claims to match
`ProgressionService` exactly (per its comment). That equivalence was **not**
verified against `ProgressionService` in this pass — if the canonical
rewards change, the fallback drifts silently. Also two accounting paths:
the linked path goes through `_dataService.AddCoins`, the fallback writes
`data.Coins` directly.

**R6 — Fire-and-forget `SaveData`.** CONFIRMED: `task.spawn(pcall(
_dataService.SaveData…))` in `ClaimQuest` (`QuestService.luau:~595-599`),
`ConfirmDelivery` (`RaidService.luau:~1080-1085`), and steal. If the server
crashes between commit and save, the in-memory commit is lost: a claimed
quest reverts to unclaimed (re-claimable, not double-paid — safe direction),
but a delivered theft reverts in DataStore to the pre-steal state while the
players' live session already moved on (thief keeps the brainrot in memory
until rejoin). Pre-existing pattern.

**R7 — `PollInTransit` delivery/return race.** Assessed, largely
defensible, residual narrow case remains. `ConfirmDelivery` is safe under
double-call: the transit entry is cleared **before** the reward is paid
(`RaidService.luau:1053-1075`), so a second call returns false
(`:1043`) and cannot double-pay. In the normal flow the poll can only
observe a placed copy *after* `PlaceBrainrot` already confirmed (the copy
is inserted after `ConfirmDelivery`), so the poll's out-of-band confirm is
a redundant net, not a live race. Residual: if a placed copy ever appears
via another writer, the poll confirms without clearing CarryService carry
state (see R8). **Studio-only to fully verify** (5 s poll timing, real
characters).

**R8 — Stranded stolen carry after out-of-band confirmation.** Code-plausible,
narrow: `ConfirmDelivery` clears only the `CarryingStolen` attribute, not
CarryService carried state; `PlaceBrainrot` clears the carry itself via
`ClearCarried` after placement, so the normal flow is fine. A poll-driven
confirm (R7 residual) could leave the thief visually carrying an instance
whose delivery already committed. Dropping it then routes through
`DropStolen` → `ReturnStolen` → no transit → false, so no duplication, but
the carry desync itself is untested. **Studio-only.**

**R9 — Store `OwnerUserId` defence-in-depth is inert when data has no
owner.** CONFIRMED (`BaseService.luau:1255-1262`): the check only fires
when `base.OwnerUserId` is a non-zero number. Real enforcement is the
`findPlaced` lookup in the caller's own base (`:1264-1267`) — correct, but
the comment's "defence in depth" adds nothing for ownerless data. No hole
found; the lookup is the enforcement.

**R10 — Store write-back asymmetry.** CONFIRMED, narrow:
`StoreBrainrot` mutates the owned record (`BaseService.luau:1285-1300`)
**before** calling `RemovePlaced` (`:1301`). If `RemovePlaced` returned
nil, the function reports failure ("brainrot not placed") while the owned
record has already been mutated. In practice `RemovePlaced` re-resolves the
same data and the same placed record found one line earlier, so failure
requires the record to vanish mid-call; still, the write-back is not
transactional with the removal.

**R11 — Shared 0.25 s rate-limit throttle (BaseService).** CONFIRMED,
pre-existing (present at HEAD, same lines): `MIN_CALL_INTERVAL = 0.25`
(`BaseService.luau:41`) with a single `_lastCall[player]` (`:176-184`)
shared across **all** BaseService remotes (`PlaceBrainrot`,
`StoreBrainrot`, `CollectIncome`, etc., `:1474-1540`). A STORE click within
0.25 s of any other BaseService call is rejected server-side with no
client-visible reason (same silent pattern as R3). Rapid legitimate play
(place then immediately store, collect then store) can hit it.

**R12 — Lune `typeof` Vector3 harness limitation.** CONFIRMED, documented
in the harness itself (`scripts/phase1-tests/harness.luau:23-29`): Lune
0.11.1's `typeof` ignores the `__type` metamethod, so any game code
branching on `typeof(x) == "Vector3"` cannot be exercised by these suites.
The Phase 1 code paths tested here do not branch on `typeof(Vector3)`,
but the limitation bounds what the suites can prove about distance/
position code in general.

**R13 — `ConfirmDelivery` reward failure is silent and unretried.**
`RaidService.luau:1069-1078`: if `AddCoins` fails, the delivery still
commits and only a server `warn` is emitted — the thief keeps the
Brainrot but loses the steal reward. Narrow; no retry path.

**R14 — `ReturnStolen` victim-offline destroy path.** Deliberate design,
flagged for awareness: if the victim left mid-theft and the move-back
fails, the instance is **destroyed** from the thief
(`RaidService.luau:950-962`) rather than kept. The comment states the
intent (a thief must never keep stolen goods for free). A transient
move failure while the victim's data is merely unloading would still
destroy the instance. **Studio-only to verify the failure mode.**

**R15 — `StoreBrainrot` Glitched write-back assumes sync.**
`owned.Glitched = placed.Glitched == true` (`BaseService.luau:1290`)
unconditionally overwrites the owned flag from the placed copy. The code
comment claims `UpgradeBrainrot` keeps both copies in sync; that sync was
not re-verified here. If a placed copy ever goes stale, a store could
clear a real `Glitched = true`. **Studio-only.**

**R16 — New strict-analysis noise, classified not fixed** (§3.4):
`BaseService` "could be nil" ×7 (nil-check present, runtime-safe),
`InteractionController:707` union-call artifact, `MutationService`
re-keyed table-shape errors, `RaidService:1190` `LocalShadow 'reason'`
(pre-existing pattern, moved line). None is a runtime defect; all are
strict-mode-without-Roblox-definitions artifacts.

**R17 — What the suites cannot see (scope limits, not bugs):** the Lune
suites run real service modules but with stubbed Roblox globals, fake
players/data, and no latency — they cannot catch real-`Instance`
behaviour, remote serialization, DataStore failures, cross-server
effects, or timing races between the 5 s poll and player actions. See §5.

---

## 5. Studio-only tests still required

None of the following was verified here; each needs a real Studio place
with real players (Grok Build):

1. **Claim UI end-to-end:** click Claim in the quest UI; verify the reward
   lands once, the button state updates, and a rejected claim (double-click,
   rate-limit, goal not met) shows the player a reason (R3).
2. **STORE button click-through:** click STORE on a placed Brainrot; verify
   it leaves the base, income stops, and it can be re-placed; rapid
   place→store and collect→store sequences against the 0.25 s shared
   throttle (R11).
3. **Live steal → delivery → return with real players:** full loop with two
   clients — steal, carry (slowdown + companion bonus in the live game),
   deliver at the pedestal, verify one instance total; thief death and
   manual drop returning the instance with all fields; victim offline
   mid-theft (R14).
4. **Camera / pedestal distance in a real place:** `PLACE_DISTANCE = 12`
   against real pedestal positions and character movement; out-of-range
   delivery rejection with the player visibly too far.
5. **DataStore round-trip:** claim a quest, steal/deliver, store a
   Brainrot, then rejoin — verify the committed state persisted (R6) and
   no duplicate or lost instance appears after a rejoin.
6. **12-player behaviour:** concurrent steals/returns, poll timing under
   load, rate-limit behaviour under real latency.
7. **PollInTransit timing:** 5 s watchdog cadence, 2 s grace after steal,
   delivery detection vs `PlaceBrainrot`'s own confirm (R7/R8); confirm no
   stranded carry visual after a poll-driven confirm.
8. **Companion carry speed live:** `applyCarrySpeed` with a real companion
   wired (16 × 0.75 = 12) vs unwired (16 × 0.6 = 9.6).
9. **Quest push delivery:** verify the client receives exactly the pushes
   the server sends, including the two-event `ReportProgress` double push
   (R4), and that the quest list refreshes.
10. **Delivered-copy fields after the R1 fix** (fix applied post-Phase-1;
    Lune-verified, Studio still to confirm live): banked income
    remainder (250 of 500) and `PlacedAt` = delivery time surviving a
    live steal → delivery.
11. **Mutation mirror live:** two same-character instances, one placed +
    glitched — verify the right instance is flagged and a real mutation is
    never clobbered.

---

## 6. What each harness does and does NOT test

### Python harness — `scripts/harness-python.py` (70 checks)
- **Does:** read-only regex/JSON checks over `src/` and docs — roster
  counts, version strings, remote lists, wiring patterns, sound hygiene,
  doc existence. Fast, deterministic, no Roblox needed.
- **Does NOT:** execute any Luau; cannot test runtime behaviour, ordering,
  exactly-once semantics, remote wiring at runtime, DataStore, types, or
  anything that only happens when code runs. A passing check means "the
  pattern is present in the text", not "the behaviour is correct".

### Lune harness — `scripts/harness-lune/main.luau` (40 checks)
- **Does:** execute the 14 shared modules' **pure logic** under Lune with
  stubbed Roblox globals (`game`, `Color3`, `Enum`, `Vector3`, `BrickColor`,
  `CFrame`, `Instance`); verifies defs, economy math, roster, tide
  variants, remotes list, etc.
- **Does NOT:** execute any service module (`QuestService`, `TideService`,
  `ProgressionService` need live Roblox services and are explicitly out of
  scope), any client controller, DataStore, Remotes, or Players. No real
  `Vector3` semantics (`typeof` limitation, R12).

### Phase 1 targeted suites — `scripts/phase1-tests/{theft,quest,store}/`
- **Do:** execute the **real** service modules (`RaidService`,
  `FusionService`, `MutationService`, `LaboratoryService`, `CarryService`,
  `BaseService`, `QuestService`) under Lune, loaded from require-patched
  copies that `refresh.sh` divergence-checks against `src/` on every run —
  so the suites test the actual current sources. They test logic, ordering
  (validation before confirm), exactly-once semantics, guards, and field
  preservation with fake players/data.
- **Do NOT:** run in Studio; no real Roblox `Instance`s, characters, or
  physics; no real remotes (handlers are invoked directly); no DataStore
  (fake `SaveData`/`GetData`); no network latency; no concurrent real
  players; no 5 s poll timing (the watchdog is invoked manually). Anything
  in §5 remains unverified by these suites.

---

## Appendix — commands & artefacts

- Theft log `/tmp/phase1-theft.log`, quest log `/tmp/phase1-quest.log`,
  store log `/tmp/phase1-store.log`, Python log `/tmp/phase1-py.log`, Lune
  harness log `/tmp/phase1-luneharness.log`, compile logs
  `/tmp/phase1-compile-src.log` (first invocation only; superseded by the
  per-file runs), analysis logs `/tmp/phase1-analyze-{strict,head,current-src,
  all-strict,all-nonstrict}.log`, Rojo logs `/tmp/phase1-rojo-{a,b}.log`,
  verify log `/tmp/phase1-verify.log`.
- Fresh builds: `/tmp/phase1-build-a.rbxl`, `/tmp/phase1-build-b.rbxl`
  (byte-identical, SHA-256
  `d49941d354c313a33ac20f01eb34c05ee2bde620023b94ef49614505e7a2cba8`).
- HEAD baseline copies: `/tmp/phase1-head/` (12 files, via `git show`).
- Checks **not run / failed: none.** Every required check ran and passed,
  except the known open item (R1), which is a missing fix, not a failed
  check. No Studio-only behaviour is reported as verified.
  (Addendum: R1 was fixed after this report — see the verdict addendum,
  §1 P1-14 and §4 R1.)

---

## Addendum — R2 bundle (2026-11-19, uncommitted; HEAD still 6ee6d21)

RaidService bundle R2-1 (N1 stale mutation), R2-3 (N6/R8 watchdog
reconcile), R2-4 (R13 reward-failure ledger), plus the R2 ReturnStolen
orphan-expedition-flag auto-clear. No commits, pushes, publishing, or
`GlitchTide.rbxl` rebuild. No Studio playtest; no Studio behaviour is
reported as verified.

- **R2-1:** `StealBrainrot` snapshot now takes Level / Mutation /
  Glitched from the OWNED record (placed copy only a fallback when the
  owned record has none). `MutateBrainrot` syncs the matching placed
  copy's Mutation in the same call and rebuilds the base models when
  BaseService is linked (`MutationService.SetBaseService`, auto-wired by
  GameManager's cross-link pass). Client evidence: `BaseController` has
  NO handler for the `MutationApplied` payload (it never branches on
  `Action`); the 3D model is built server-side from `placed.Mutation`,
  so the placed-copy sync + `RebuildBase` is what updates the display.
  Test: `theft/10_stale_mutation.luau` (21 checks) — mutate placed
  golden wobble to electric, steal with a hand-staled placed copy,
  deliver; income 40/s (electric) vs 50/s (golden).
- **R2-3:** reconcile lives INSIDE `ConfirmDelivery`
  (`reconcilePlacedCopy`, no-op when no placed copy exists yet — the
  normal `PlaceBrainrot` path rejects "already placed" at
  `BaseService.luau:1100` before calling `ConfirmDelivery` at :1142 and
  builds the copy at :1176). It rewrites the existing placed copy from
  the updated owned record, syncs `owned.Placed` / `Slot`, clears the
  thief's carry state, and rebuilds the base. Test:
  `theft/09_watchdog_reconcile.luau` (21 checks) — stale placed copy +
  `PollInTransit`, then a second watchdog run (no duplicate, no second
  reward), then store with values intact, plus a normal-path scenario.
- **R2-4:** what can actually fail — `DataService.AddCoins` essentially
  never throws (cache mutation, no throwing calls); the real failure is
  persistence (load failed → `_loadFailed` → `SaveData` refuses, so
  coins paid into the phantom cache vanish on leave). Fix: `IsSaveable`
  accessor on DataService (only DataService change); grant goes through
  `grantStealReward` — unsaveable or AddCoins failure records
  `data.PendingRewards[InstanceId] = {Amount, CharacterId, Reason,
  CreatedAt}` and `ConfirmDelivery` returns `(true, "reward_pending")`
  instead of claiming success. `RecoverPendingRewards(player)` pays
  each entry once (entry deleted only after a successful `AddCoins`),
  is wired on `PlayerAdded` in `RaidService.Init` as a backstop, and is
  idempotent. Test: `theft/11_pending_reward.luau` (24 checks) — injected
  AddCoins failure + unsaveable session + healthy control.
- **ReturnStolen orphan clear:** after the return commits,
  `ExpeditionService.ClearOrphanedExpeditionFlag` is called when wired
  (`RaidService.SetExpeditionService`, auto-wired by GameManager), with
  an inline victim-data check as the fallback; never touches a live
  expedition. Expedition test `01_expedition_in_transit.luau` updated:
  Pair 3 now asserts the victim is NOT locked out after `ReturnStolen`
  (fallback path); new Pair 4 covers the wired-helper path. 46 checks.
- **Mutant controls** (`theft/mutant/run_mutant.sh`): P4
  (placed-preferred snapshot), watchdog (reconcile call removed), R13
  (warn-only grant) — all three fail their control tests as expected
  (exit 0 iff all fail as expected).
- **Validation:** theft 175 checks (11 files), store 72, expedition 46,
  quest 59 — all green. `luau-compile` 0 failures on all changed/new
  files. Harness note: `AddCoins` stub now returns the new balance (as
  the real `DataService.AddCoins` does); `H.newEnv` accepts
  `opts.raidPath` for the mutant controls.
- **Remaining risk:** in a load-failed session the pending-reward entry
  itself lives in the unsaveable cache, so a leave before a successful
  load loses the entry too — the ledger makes the failure visible and
  recoverable in-session / on a saveable rejoin, but full durability for
  that case would need a separate DataStore sidecar key (follow-up for
  the lifecycle worker, not built here).
