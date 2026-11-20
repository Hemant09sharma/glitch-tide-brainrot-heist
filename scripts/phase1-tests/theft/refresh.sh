#!/usr/bin/env bash
# Refresh the Phase 1 theft-test copies of the REAL service + shared modules.
#
# Copies src/shared/*.luau into scripts/phase1-tests/theft/shared/ and
# the five services under test into scripts/phase1-tests/theft/services/,
# applying ONLY harness-only require patches (the project files are never
# touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   services: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
# (Lune has no `script.Parent` and no ReplicatedStorage; the sibling
# requires inside pcall in the services never fire under Lune because
# `script` is nil, so they need no patch.)
#
# The copies are byte-identical to the sources apart from those require
# lines — the script diffs each copy against its source after patching
# and FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/theft/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/theft"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	# Strip the patched require lines from both sides, then compare.
	# Any remaining difference means the copy diverged from the source.
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' "$src") "$dest" > /tmp/phase1-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-refresh-diff.txt
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
echo "refreshed $count shared modules into scripts/phase1-tests/theft/shared/"

for name in RaidService FusionService MutationService LaboratoryService CarryService; do
	sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' \
		"$SVC_SRC/$name.luau" > "$DEST/services/$name.luau"
	check_copy "$SVC_SRC/$name.luau" "$DEST/services/$name.luau"
done
echo "refreshed 5 service modules into scripts/phase1-tests/theft/services/"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
