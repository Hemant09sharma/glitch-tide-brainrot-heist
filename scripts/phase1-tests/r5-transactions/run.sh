#!/usr/bin/env bash
# Run every R5-transactions test (refreshes the module copies first).
# Each test file loads the REAL DataService / RaidService with a stubbed
# DataStore API plus GetDataStore outage injection (see r5_env.luau).
# (The R5 mutant controls live in mutant/ and are NOT run here — see
# mutant/run_mutant.sh; they are expected to FAIL their assertions by
# design, i.e. the old behaviour must produce the bad outcome the
# test detects.)
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/run.sh
# Exit 0 iff every test file passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
# Refresh every suite whose copies these tests load.
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r5-transactions/refresh.sh"
fail=0
passed_files=0
total_files=0
# NOTE: this directory is shared with the other R5 workers (e.g. the
# R5-6 test 06_rebirth_prestige.luau). Run ONLY the Worker-A (01 R5-1,
# 02 R5-5), Worker-C (03 R5-3, 04 R5-4) and Worker-D (05 R5-2,
# 07 R5-7) files here; the other workers run their own runners.
for f in "$ROOT"/scripts/phase1-tests/r5-transactions/01_*.luau "$ROOT"/scripts/phase1-tests/r5-transactions/02_*.luau "$ROOT"/scripts/phase1-tests/r5-transactions/03_*.luau "$ROOT"/scripts/phase1-tests/r5-transactions/04_*.luau "$ROOT"/scripts/phase1-tests/r5-transactions/05_*.luau "$ROOT"/scripts/phase1-tests/r5-transactions/07_*.luau; do
	total_files=$((total_files + 1))
	echo "=== $(basename "$f") ==="
	if "$LUNE" run "$f"; then
		echo "--- PASS $(basename "$f")"
		passed_files=$((passed_files + 1))
	else
		echo "--- FAIL $(basename "$f")"
		fail=1
	fi
done
echo "run: $passed_files/$total_files r5-transactions test files passed"

# Static anchors the Lune tests cannot check (client notice wiring
# the R5-1 SaveWarning relies on, plus the R5 source guards):
anchor_fail=0
if ! grep -qF 'SaveWarning = "SaveWarning"' "$ROOT/src/shared/Remotes.luau"; then
	echo "ANCHOR MISSING: SaveWarning remote name in Remotes.luau"
	anchor_fail=1
fi
if ! grep -qF 'fireClient(Remotes.Names.SaveWarning, player, warning)' "$ROOT/src/server/Services/GameManager.luau"; then
	echo "ANCHOR MISSING: GameManager SaveWarning fire on join"
	anchor_fail=1
fi
if ! grep -qF 'function HUDController.ShowSaveWarning' "$ROOT/src/client/Controllers/HUDController.luau"; then
	echo "ANCHOR MISSING: HUDController.ShowSaveWarning"
	anchor_fail=1
fi
if ! grep -qF 'function DataService.RetryLoad' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: DataService.RetryLoad"
	anchor_fail=1
fi
if grep -qF 'loadOk = store == nil' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR VIOLATION: LoadData still treats a missing store as a successful load"
	anchor_fail=1
fi
# R5-5: the no-store branch of InvalidateReturnEscrow must fail
# closed (return false), never report success. The branch is
# identified by its warning text, which must sit next to a false
# return; the Lune test proves the behaviour live.
if ! grep -qF 'datastore unavailable' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: fail-closed 'datastore unavailable' in DataService.luau"
	anchor_fail=1
fi
# R5-3: durable reward voiding independent of the cache (Worker C).
if ! grep -qF 'function DataService.RecordRewardVoidForInstance' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: DataService.RecordRewardVoidForInstance"
	anchor_fail=1
fi
if ! grep -qF 'VoidedRewardInstances' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: VoidedRewardInstances ledger in DataService.luau"
	anchor_fail=1
fi
if ! grep -qF 'function RaidService.RetryPendingVoids' "$ROOT/src/server/Services/RaidService.luau"; then
	echo "ANCHOR MISSING: RaidService.RetryPendingVoids"
	anchor_fail=1
fi
# R5-4: session-lease races (Worker C) — the lease state must be
# queryable, and the old blind-fallback rule must be gone.
if ! grep -qF 'function DataService.GetSessionLeaseState' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: DataService.GetSessionLeaseState"
	anchor_fail=1
fi
if grep -qF 'read does NOT block (it falls back to this server'"'"'s cached lease' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR VIOLATION: DataService still falls back to the cached lease on a failed lease read"
	anchor_fail=1
fi
# R5-2: session-health gates for ownership operations (Worker D).
if ! grep -qF 'checkSessionHealth' "$ROOT/src/server/Services/RaidService.luau"; then
	echo "ANCHOR MISSING: RaidService.checkSessionHealth (R5-2 gate)"
	anchor_fail=1
fi
if ! grep -qF 'function RaidService._TestSetStealChannelHook' "$ROOT/src/server/Services/RaidService.luau"; then
	echo "ANCHOR MISSING: RaidService._TestSetStealChannelHook (R5-2 channel hook)"
	anchor_fail=1
fi
if ! grep -qF 'sessionBlockedReason' "$ROOT/src/server/Services/BaseService.luau"; then
	echo "ANCHOR MISSING: BaseService.sessionBlockedReason (R5-2 gate)"
	anchor_fail=1
fi
if ! grep -qF 'session cannot save: ' "$ROOT/src/server/Services/BaseService.luau"; then
	echo "ANCHOR MISSING: BaseService R5-2 refusal text"
	anchor_fail=1
fi
# R5-7: bounded parallel shutdown hooks (Worker D).
if ! grep -qF 'function DataService.RunShutdownHooks' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: DataService.RunShutdownHooks"
	anchor_fail=1
fi
if ! grep -qF 'function DataService.RunPreSaveHooks' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: DataService.RunPreSaveHooks"
	anchor_fail=1
fi
if ! grep -qF 'function DataService.GetShutdownHookStats' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: DataService.GetShutdownHookStats"
	anchor_fail=1
fi
if ! grep -qF 'DataService.RunShutdownHooks(Players:GetPlayers())' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: BindToClose calling RunShutdownHooks"
	anchor_fail=1
fi
# R5-7: the old BindToClose loop ran every player's hooks inline, one
# after another (sequential for-loop directly calling runPreSaveHooks).
if grep -A1 -F 'for _, player in ipairs(Players:GetPlayers()) do' "$ROOT/src/server/Services/DataService.luau" | grep -qF 'runPreSaveHooks(player)'; then
	echo "ANCHOR VIOLATION: BindToClose still runs the pre-save hooks sequentially"
	anchor_fail=1
fi
if [ "$anchor_fail" -ne 0 ]; then
	echo "run: STATIC ANCHORS FAILED"
	exit 1
fi
echo "run: static anchors OK"

if [ "$fail" -ne 0 ]; then
	echo "run: SOME R5-TRANSACTIONS TESTS FAILED"
	exit 1
fi
echo "run: ALL R5-TRANSACTIONS TESTS PASSED"
