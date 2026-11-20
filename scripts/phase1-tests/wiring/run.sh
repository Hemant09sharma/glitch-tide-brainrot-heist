#!/usr/bin/env bash
# Run the R2-6 production-wiring test (refreshes the module copies first).
# Usage (from the package root):
#   bash scripts/phase1-tests/wiring/run.sh
# Exit 0 iff the test passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
bash "$ROOT/scripts/phase1-tests/wiring/refresh.sh"
"$LUNE" run "$ROOT/scripts/phase1-tests/wiring/01_production_companion_wiring.luau"
