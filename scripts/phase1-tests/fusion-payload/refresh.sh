#!/usr/bin/env bash
# Refresh the Phase 1 fusion-payload test copies of the REAL service +
# shared modules (same pattern as scripts/phase1-tests/mutation-payload/refresh.sh).
#
# The tests in this directory load the real services through the shared
# harness (H.newEnv -> theft/services/FusionService, H.newBaseEnv ->
# store/services/BaseService), so this script delegates to those two
# refresh scripts instead of maintaining a third copy set — a third
# copy would drift. It also verifies the test's own source-shape reads
# (src/server/Services/FusionService.luau, src/client/Controllers/
# ShopController.luau, src/client/Controllers/BaseController.luau) exist.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/fusion-payload/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
for f in src/server/Services/FusionService.luau src/server/Services/BaseService.luau src/client/Controllers/ShopController.luau src/client/Controllers/BaseController.luau; do
	if [ ! -f "$ROOT/$f" ]; then
		echo "refresh FAILED: missing $f"
		exit 1
	fi
done
echo "refresh OK: theft + store copies match sources apart from require lines"
