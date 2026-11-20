#!/usr/bin/env bash
# Run the R5-3 + R5-4 negative controls (Worker C): build/guard the
# pre-fix mutants, then run m03_r5_3_old_logic.luau (old code pays
# the voided reward once the sidecar becomes readable) and
# m04_r5_4_old_logic.luau (old code overwrites the newer profile in
# every lease-loss scenario). Each control asserts the OLD bad
# outcome; exit 0 iff both controls pass (i.e. the old code really
# does the bad thing, proving the fixed tests discriminate).
# NOTE: this directory is shared with the other R5 workers (their
# runners are mutant/run_mutant.sh for R5-6 and
# mutant/run_mutant_r5_1_5.sh for R5-1/R5-5). This runner runs ONLY
# the Worker-C controls.
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
# Refresh the copies the controls load (the mutant snapshots
# themselves are static and are NOT refreshed).
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r5-transactions/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_3_4.sh"
fail=0
for f in m03_r5_3_old_logic.luau m04_r5_4_old_logic.luau; do
	echo "=== $f ==="
	if "$LUNE" run "$ROOT/scripts/phase1-tests/r5-transactions/mutant/$f"; then
		echo "--- PASS $f"
	else
		echo "--- FAIL $f"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run_mutant_r5_3_4: SOME NEGATIVE CONTROLS FAILED"
	exit 1
fi
echo "run_mutant_r5_3_4: ALL NEGATIVE CONTROLS PASSED"
