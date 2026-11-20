#!/usr/bin/env bash
# Run the R5-6 negative control: builds the pre-fix mutant from git
# HEAD, then runs m01_rebirth_prestige_old.luau, which asserts the
# OLD bad outcomes. Exit 0 iff the control passes (i.e. the old code
# really does wipe / eat the reserved reward coins).
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/run_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/r5-transactions/mutant/make_mutant.sh"
"$LUNE" run "$ROOT/scripts/phase1-tests/r5-transactions/mutant/m01_rebirth_prestige_old.luau"
