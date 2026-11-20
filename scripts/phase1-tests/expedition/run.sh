#!/usr/bin/env bash
# Run every Phase 1 expedition test (refreshes the module copies first).
# Refreshes the theft + store copies too: the expedition tests reuse the
# real RaidService / CarryService / MutationService / FusionService via
# harness.newEnv() and the real BaseService via harness.newBaseEnv().
# Usage (from the package root):
#   bash scripts/phase1-tests/expedition/run.sh
# Exit 0 iff every test file passes. (The R2-7 mutant control lives in
# mutant/ and is NOT run here — see mutant/run_mutant.sh; it is
# expected to FAIL the rejection test by design.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/expedition/refresh.sh"
fail=0
for f in "$ROOT"/scripts/phase1-tests/expedition/0*.luau; do
	echo "=== $(basename "$f") ==="
	if "$LUNE" run "$f"; then
		echo "--- PASS $(basename "$f")"
	else
		echo "--- FAIL $(basename "$f")"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run: SOME EXPEDITION TESTS FAILED"
	exit 1
fi
echo "run: ALL EXPEDITION TESTS PASSED"
