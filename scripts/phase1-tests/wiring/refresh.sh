#!/usr/bin/env bash
# Refresh the R2-6 wiring-test copies of the REAL service + shared
# modules (same pattern as scripts/phase1-tests/theft/refresh.sh).
#
# Copies src/shared/*.luau into scripts/phase1-tests/wiring/shared/ and
# GameManager / BaseService / CarryService / ConveyorService into
# scripts/phase1-tests/wiring/services/, applying ONLY harness-only
# require patches (the project files are never touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   service: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
#   service: require(script.Parent:WaitForChild("MapBuilder"))
#            -> require("./MapBuilderStub")   (Lune-only stand-in)
#
# Deliberately NOT patched: GameManager's
# require(script.Parent:WaitForChild("ConveyorService" | "BaseService" |
# "CarryService")) and its loadOptional script.Parent:FindFirstChild —
# the wiring test defines a `script` global whose Parent is the
# module registry, so those lines run EXACTLY as in production
# (that is the point of the test: the real init/wiring path).
# CompanionService.luau and MapBuilderStub.luau in services/ are
# hand-written test stubs, NOT src copies, and are NOT divergence-checked.
#
# The copies are byte-identical to the sources apart from those require
# lines — the script diffs each copy against its source after patching
# and FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/wiring/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/wiring"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	# Strip the patched require lines from both sides, then compare.
	# Any remaining difference means the copy diverged from the source.
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g; s/require\(script\.Parent:WaitForChild\("MapBuilder"\)\)/require(".\/MapBuilderStub")/g' "$src") "$dest" > /tmp/phase1-wiring-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-wiring-refresh-diff.txt
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
echo "refreshed $count shared modules into scripts/phase1-tests/wiring/shared/"

for name in GameManager BaseService CarryService ConveyorService; do
	sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g; s/require\(script\.Parent:WaitForChild\("MapBuilder"\)\)/require(".\/MapBuilderStub")/g' \
		"$SVC_SRC/$name.luau" > "$DEST/services/$name.luau"
	check_copy "$SVC_SRC/$name.luau" "$DEST/services/$name.luau"
done
echo "refreshed 4 service modules into scripts/phase1-tests/wiring/services/"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
