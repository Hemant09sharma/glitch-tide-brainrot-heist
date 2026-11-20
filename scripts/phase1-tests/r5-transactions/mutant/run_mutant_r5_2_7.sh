#!/usr/bin/env bash
# Run the R5-2 + R5-7 negative controls (Worker D): build/guard the
# pre-fix mutants, then run m05_r5_2_old_logic.luau (old code loses
# the instance in every unhealthy-session scenario: 0 owners after
# both rejoin, and a load-failed place succeeds) and
# m07_r5_7_old_logic.luau (old code has no bounded hook-phase API
# and its sequential hooks cost 42 s for 6 players / 84 s for 12,
# blowing the ~30 s shutdown budget). Each control asserts the OLD
# bad outcome; exit 0 iff both controls pass (i.e. the old code
# really does the bad thing, proving the fixed tests discriminate).
# NOTE: this directory is shared with the other R5 workers (their
# runners are mutant/run_mutant.sh for R5-6,
# mutant/run_mutant_r5_1_5.sh for R5-1/R5-5 and
# mutant/run_mutant_r5_3_4.sh for R5-3/R5-4). This runner runs ONLY
# the Worker-D controls.
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_2_7.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
# Refresh the copies the controls load (the mutant snapshots
# themselves are static and are NOT refreshed).
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r5-transactions/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_2_7.sh"
fail=0
for f in m05_r5_2_old_logic.luau m07_r5_7_old_logic.luau; do
	echo "=== $f ==="
	if "$LUNE" run "$ROOT/scripts/phase1-tests/r5-transactions/mutant/$f"; then
		echo "--- PASS $f"
	else
		echo "--- FAIL $f"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run_mutant_r5_2_7: SOME NEGATIVE CONTROLS FAILED"
	exit 1
fi
echo "run_mutant_r5_2_7: ALL NEGATIVE CONTROLS PASSED"
