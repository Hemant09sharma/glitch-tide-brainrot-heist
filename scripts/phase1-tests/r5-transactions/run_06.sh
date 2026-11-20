#!/usr/bin/env bash
# Run the R5-6 rebirth/prestige reservation test (refreshes the
# ProgressionService copy first). The R4-transactions, theft,
# persistence and store suites are refreshed by the R4 run script;
# this runner refreshes only the R5-6 copy and relies on the R4
# suites' copies being current (run the R4 suite's run.sh first if
# DataService / RaidService changed).
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/run_06.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/r5-transactions/refresh_06.sh"
"$LUNE" run "$ROOT/scripts/phase1-tests/r5-transactions/06_rebirth_prestige.luau"
