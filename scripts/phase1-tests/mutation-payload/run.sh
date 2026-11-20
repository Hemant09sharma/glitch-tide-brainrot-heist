#!/usr/bin/env bash
# Run every Phase 1 mutation-payload test (refreshes the module copies first).
# Usage (from the package root):
#   bash scripts/phase1-tests/mutation-payload/run.sh
# Exit 0 iff every test file passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/mutation-payload/refresh.sh"
fail=0
for f in "$ROOT"/scripts/phase1-tests/mutation-payload/0*.luau; do
	echo "=== $(basename "$f") ==="
	if "$LUNE" run "$f"; then
		echo "--- PASS $(basename "$f")"
	else
		echo "--- FAIL $(basename "$f")"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "run: SOME MUTATION-PAYLOAD TESTS FAILED"
	exit 1
fi
echo "run: ALL MUTATION-PAYLOAD TESTS PASSED"
