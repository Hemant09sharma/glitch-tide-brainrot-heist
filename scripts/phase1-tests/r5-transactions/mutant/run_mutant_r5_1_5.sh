#!/usr/bin/env bash
# Run the R5-1 + R5-5 negative controls (Worker A): build/guard the
# pre-fix mutant, then run m01_r5_1_old_logic.luau (old code wipes the
# genuine profile) and m02_r5_5_old_logic.luau (old code returns
# success during a GetDataStore outage and duplicates the Brainrot).
# Each control asserts the OLD bad outcome; exit 0 iff both controls
# pass (i.e. the old code really does the bad thing, proving the
# fixed tests discriminate).
# NOTE: this directory is shared with the other R5 workers (their
# runner is mutant/run_mutant.sh for R5-6). This runner runs ONLY
# the Worker-A controls.
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_1_5.sh"
fail=0
for f in m01_r5_1_old_logic.luau m02_r5_5_old_logic.luau; do
	echo "=== $f ==="
	if "$LUNE" run "$ROOT/scripts/phase1-tests/r5-transactions/mutant/$f"; then
		echo "--- PASS $f"
	else
		echo "--- FAIL $f"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run_mutant_r5_1_5: SOME NEGATIVE CONTROLS FAILED"
	exit 1
fi
echo "run_mutant_r5_1_5: ALL NEGATIVE CONTROLS PASSED"
