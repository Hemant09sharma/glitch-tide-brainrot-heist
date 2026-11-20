#!/usr/bin/env bash
# Refresh the R5-6 test copies of the REAL ProgressionService + shared
# modules (same pattern as scripts/phase1-tests/r4-transactions/refresh.sh).
# Copies src/shared/*.luau into scripts/phase1-tests/r5-transactions/shared/
# and src/server/Services/ProgressionService.luau into
# scripts/phase1-tests/r5-transactions/services/, applying ONLY
# harness-only require patches (the project files are never touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   service: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
# The copies are byte-identical to the sources apart from those require
# lines — the script diffs each copy against its source after patching
# and FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/refresh_06.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r5-transactions"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' "$src") "$dest" > /tmp/phase1-r5-06-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-r5-06-refresh-diff.txt
		fail=1
	fi
}

count=0
for f in "$SHARED_SRC"/*.luau; do
	base="$(basename "$f")"
	sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g' "$f" > "$DEST/shared/$base"
	check_copy "$f" "$DEST/shared/$base"
	count=$((count + 1))
done
echo "refreshed $count shared modules into scripts/phase1-tests/r5-transactions/shared/"

sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' \
	"$SVC_SRC/ProgressionService.luau" > "$DEST/services/ProgressionService.luau"
check_copy "$SVC_SRC/ProgressionService.luau" "$DEST/services/ProgressionService.luau"
echo "refreshed ProgressionService into scripts/phase1-tests/r5-transactions/services/"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
