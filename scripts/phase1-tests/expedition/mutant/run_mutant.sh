#!/usr/bin/env bash
# R2-7 mutant control (P3): rebuild the mutant from the current fixed
# service, then run the SAME rejection assertions against it. The mutant
# must FAIL those assertions (it starts the expedition with the stolen
# record) — that failure is the expected result and proves the test
# detects the missing guard.
# Exit 0 iff the mutant run FAILS as expected; exit 1 if the mutant
# unexpectedly passes (the control would be blind).
# Usage (from the package root):
#   bash scripts/phase1-tests/expedition/mutant/run_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/expedition/refresh.sh"
bash "$ROOT/scripts/phase1-tests/expedition/mutant/make_mutant.sh"
echo "=== mutant/01_mutant_control.luau (expected to FAIL) ==="
set +e
"$LUNE" run "$ROOT/scripts/phase1-tests/expedition/mutant/01_mutant_control.luau"
status=$?
set -e
if [ "$status" -eq 0 ]; then
	echo "run_mutant: UNEXPECTED PASS — the mutant satisfied the rejection test; the control is blind"
	exit 1
fi
echo "run_mutant: MUTANT CONTROL VALID — mutant failed the rejection test as expected (exit $status)"
