#!/usr/bin/env bash
# Run every Phase 1 persistence test (refreshes the module copies first).
# Each test file loads the REAL DataService (copies under
# persistence/services/) with a stubbed DataStore API.
# Usage (from the package root):
#   bash scripts/phase1-tests/persistence/run.sh
# Exit 0 iff every test file passes. (The R3 mutant controls live in
# mutant/ and are NOT run here — see mutant/run_mutant.sh; they are
# expected to FAIL their assertions by design.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
# The R3-3/4/5 tests also load the REAL RaidService (theft/services
# copies) via persistence_env.newRaidEnv — refresh those copies too
# so the tests can never run a stale RaidService.
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
fail=0
passed_files=0
total_files=0
for f in "$ROOT"/scripts/phase1-tests/persistence/[0-9][0-9]_*.luau; do
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
echo "run: $passed_files/$total_files persistence test files passed"
if [ "$fail" -ne 0 ]; then
	echo "run: SOME PERSISTENCE TESTS FAILED"
	exit 1
fi
echo "run: ALL PERSISTENCE TESTS PASSED"
