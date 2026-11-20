#!/usr/bin/env bash
# R2-5 mutant control: rebuild the mutant from the current fixed
# service, then run the SAME rejoin-ownership assertions against it.
# The mutant must FAIL its assertions — that failure is the expected
# result and proves the test detects the missing fix.
# Exit 0 iff the mutant run FAILS as expected; exit 1 if the mutant
# unexpectedly passes (that control would be blind).
# Usage (from the package root):
#   bash scripts/phase1-tests/lifecycle/mutant/run_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/lifecycle/refresh.sh"
bash "$ROOT/scripts/phase1-tests/lifecycle/mutant/make_mutant.sh"
fail=0
for f in "$ROOT"/scripts/phase1-tests/lifecycle/mutant/0*_control.luau; do
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
echo "run_mutant: ALL R2-5 MUTANT CONTROLS VALID (mutant failed as expected)"
