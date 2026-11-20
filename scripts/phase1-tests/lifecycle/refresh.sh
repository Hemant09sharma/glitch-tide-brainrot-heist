#!/usr/bin/env bash
# Refresh the Phase 1 lifecycle-test copies of the REAL RaidService +
# shared modules (same pattern as scripts/phase1-tests/theft/refresh.sh).
#
# Copies src/shared/*.luau into scripts/phase1-tests/lifecycle/shared/
# and src/server/Services/RaidService.luau into
# scripts/phase1-tests/lifecycle/services/, applying ONLY harness-only
# require patches (the project files are never touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   service: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
# (The sibling requires inside pcall in RaidService never fire under
# Lune because `script` is nil, so they need no patch.)
#
# The copies are byte-identical to the sources apart from those require
# lines — the script diffs each copy against its source after patching
# and FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
#
# NOTE: the lifecycle tests load RaidService through harness.newEnv(),
# which requires the THEFT copies (theft/services/); run.sh refreshes
# those too. The lifecycle/services copy exists so the mutant builder
# (mutant/make_mutant.sh) can derive the old-behaviour control from
# the current fixed service.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/lifecycle/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/lifecycle"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	# Strip the patched require lines from both sides, then compare.
	# Any remaining difference means the copy diverged from the source.
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' "$src") "$dest" > /tmp/phase1-lifecycle-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-lifecycle-refresh-diff.txt
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
echo "refreshed $count shared modules into scripts/phase1-tests/lifecycle/shared/"

sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' \
	"$SVC_SRC/RaidService.luau" > "$DEST/services/RaidService.luau"
check_copy "$SVC_SRC/RaidService.luau" "$DEST/services/RaidService.luau"
echo "refreshed RaidService into scripts/phase1-tests/lifecycle/services/"

# Structural guard for the parts of the fix Lune cannot execute: the
# REAL DataService.luau and GameManager.luau must carry the lifecycle
# anchors (pre-save hook registry run before the leave save, single
# shutdown saver in DataService, canonical rejoin call in
# GameManager.onPlayerAdded, no second save-on-leave in GameManager).
anchor_fail=0
for anchor in \
	"function DataService.RegisterPreSaveHook" \
	"runPreSaveHooks(player)" \
	"RecoverOnRejoin(player)" \
; do
	if ! grep -qF "$anchor" "$SVC_SRC/DataService.luau" && ! grep -qF "$anchor" "$SVC_SRC/GameManager.luau"; then
		echo "ANCHOR MISSING: $anchor (not in DataService.luau or GameManager.luau)"
		anchor_fail=1
	fi
done
if grep -q "Players.PlayerRemoving:Connect(onPlayerRemoving)" "$SVC_SRC/GameManager.luau"; then
	echo "ANCHOR VIOLATION: GameManager still connects its own PlayerRemoving save handler"
	anchor_fail=1
fi
if grep -q "game:BindToClose" "$SVC_SRC/GameManager.luau"; then
	echo "ANCHOR VIOLATION: GameManager still has its own BindToClose"
	anchor_fail=1
fi
if [ "$anchor_fail" -ne 0 ]; then
	echo "refresh FAILED: lifecycle anchors missing in src/"
	exit 1
fi
echo "refresh OK: lifecycle anchors present in DataService.luau / GameManager.luau"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
