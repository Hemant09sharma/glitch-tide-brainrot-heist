#!/usr/bin/env bash
# Run every R4 negative control against the R3 mutant copies.
# Each control asserts the OLD bad outcome: a control PASSES when
# the mutant reproduces the bug the matching fixed test detects
# (proving the fixed test discriminates), and FAILS when the mutant
# does not reproduce it (the fixed test would pass even against
# broken code — investigate before trusting it).
# The mutants are built by mutant/make_mutant.sh from the current
# fixed copies; they are NOT refreshed (they are the old behaviour
# by construction). The fixed suite is NOT run here — see ../run.sh.
# Usage (from the package root):
#   bash scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
# Exit 0 iff every control passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
# R5-8: the compiler path is configurable like LUNE above — set
# LUAU_COMPILE to point at a luau-compile binary elsewhere; it
# defaults to the /tmp toolchain path when unset.
LUAU_COMPILE="${LUAU_COMPILE:-/tmp/luau-0.747/luau-compile}"
# Refresh the fixed copies the mutants are built from.
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r4-transactions/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r4-transactions/mutant/make_mutant.sh"
# The mutants must still compile (a broken mutant proves nothing).
"$LUAU_COMPILE" "$ROOT/scripts/phase1-tests/r4-transactions/mutant/RaidServiceR3.luau" > /dev/null
"$LUAU_COMPILE" "$ROOT/scripts/phase1-tests/r4-transactions/mutant/DataServiceR3.luau" > /dev/null
echo "mutant compile OK"
fail=0
passed_files=0
total_files=0
for f in "$ROOT"/scripts/phase1-tests/r4-transactions/mutant/m[0-9][0-9]_*.luau; do
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
echo "run_mutant: $passed_files/$total_files negative controls passed"
if [ "$fail" -ne 0 ]; then
	echo "run_mutant: SOME NEGATIVE CONTROLS FAILED (the matching fixed test may not discriminate)"
	exit 1
fi
echo "run_mutant: ALL NEGATIVE CONTROLS PASSED (old behaviour reproduced as expected)"
