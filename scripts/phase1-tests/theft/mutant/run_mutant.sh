#!/usr/bin/env bash
# R2 mutant controls (P4, watchdog, R13, M5, M8, E1, E2): rebuild the mutants from the
# current fixed service, then run the SAME assertions against each. Each
# mutant must FAIL its assertions — that failure is the expected result
# and proves the test detects the missing fix.
# Exit 0 iff ALL SEVEN mutant runs FAIL as expected; exit 1 if any
# mutant unexpectedly passes (that control would be blind).
# Usage (from the package root):
#   bash scripts/phase1-tests/theft/mutant/run_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/theft/mutant/make_mutant.sh"
fail=0
for f in "$ROOT"/scripts/phase1-tests/theft/mutant/0*_control.luau; do
	echo "=== $(basename "$f") (expected to FAIL) ==="
	set +e
	"$LUNE" run "$f"
	status=$?
	set -e
	if [ "$status" -eq 0 ]; then
		echo "--- UNEXPECTED PASS $(basename "$f") — the mutant satisfied the test; the control is blind"
		fail=1
	else
		echo "--- MUTANT CONTROL VALID $(basename "$f") — mutant failed as expected (exit $status)"
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run_mutant: SOME MUTANT CONTROLS ARE BLIND"
	exit 1
fi
echo "run_mutant: ALL R2 MUTANT CONTROLS VALID (all seven mutants failed as expected)"
