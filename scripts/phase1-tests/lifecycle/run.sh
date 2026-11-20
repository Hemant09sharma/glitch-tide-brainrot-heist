#!/usr/bin/env bash
# Run every Phase 1 lifecycle test (refreshes the module copies first).
# Refreshes the theft copies too: the lifecycle tests load the real
# RaidService / CarryService / MutationService via harness.newEnv(),
# which requires theft/services/.
# Usage (from the package root):
#   bash scripts/phase1-tests/lifecycle/run.sh
# Exit 0 iff every test file passes. (The R2-5 mutant control lives in
# mutant/ and is NOT run here — see mutant/run_mutant.sh; it is
# expected to FAIL the rejoin-ownership test by design.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/lifecycle/refresh.sh"
fail=0
for f in "$ROOT"/scripts/phase1-tests/lifecycle/0*.luau; do
	echo "=== $(basename "$f") ==="
	if "$LUNE" run "$f"; then
		echo "--- PASS $(basename "$f")"
	else
		echo "--- FAIL $(basename "$f")"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run: SOME LIFECYCLE TESTS FAILED"
	exit 1
fi
echo "run: ALL LIFECYCLE TESTS PASSED"
