#!/usr/bin/env bash
# R3 mutant controls: run the SAME assertions as the fixed-code tests
# against the PRE-R3 DataService (mutant/DataServiceOld.luau — a static
# snapshot of the old unsafe code: readSidecar returning nil on failure
# + `or {}` + SetAsync writeSidecar; deliberately NOT refreshed).
# Each mutant run must FAIL its assertions — that failure is the
# expected result and proves the test detects the missing fix.
# Exit 0 iff ALL mutant runs FAIL as expected; exit 1 if any mutant
# unexpectedly passes (that control would be blind).
# Usage (from the package root):
#   bash scripts/phase1-tests/persistence/mutant/run_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
fail=0
for f in "$ROOT"/scripts/phase1-tests/persistence/mutant/0*_control.luau; do
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
echo "run_mutant: ALL R3 MUTANT CONTROLS VALID (all mutant runs failed as expected)"
