#!/usr/bin/env bash
# Run every Phase 1 theft test (refreshes the module copies first).
# Usage (from the package root):
#   bash scripts/phase1-tests/theft/run_all.sh
# Exit 0 iff every test file passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
# R2: tests 09/10 load the REAL BaseService via H.newBaseEnv, so the
# store copies must be fresh too — otherwise they could run stale.
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
fail=0
# Glob *.luau (not 0*.luau): tests 10/11 must run too. Mutant controls
# live in theft/mutant/ and are never picked up here.
for f in "$ROOT"/scripts/phase1-tests/theft/*.luau; do
	echo "=== $(basename "$f") ==="
	if "$LUNE" run "$f"; then
		echo "--- PASS $(basename "$f")"
	else
		echo "--- FAIL $(basename "$f")"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run_all: SOME TESTS FAILED"
	exit 1
fi
echo "run_all: ALL THEFT TESTS PASSED"
