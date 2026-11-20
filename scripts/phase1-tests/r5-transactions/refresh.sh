#!/usr/bin/env bash
# Refresh the R5-transactions test copies of the REAL services +
# shared modules (same pattern as scripts/phase1-tests/r4-transactions/refresh.sh).
#
# Copies src/shared/*.luau into scripts/phase1-tests/r5-transactions/shared/
# and DataService into scripts/phase1-tests/r5-transactions/services/,
# applying ONLY harness-only require patches (the project files are never
# touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   service: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
#
# RaidService is loaded from the theft suite's copies (as r4_env does);
# theft/refresh.sh owns those, and run.sh runs it first. The copies
# are byte-identical to the sources apart from those require lines —
# the script diffs each copy against its source after patching and
# FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
#
# Structural guards for the R5 fixes (fail the refresh if the source
# regresses): the R5-1 explicit reload path (RetryLoad), a failed
# GetDataStore no longer counting as a successful load, and the R5-5
# fail-closed escrow invalidation.
#
# The mutant controls (mutant/) are STATIC snapshots built by
# mutant/make_mutant.sh from these copies and are deliberately NOT
# refreshed — they are the old unsafe behaviour the new tests must
# catch. See mutant/run_mutant.sh.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r5-transactions"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	# Strip the patched require lines from both sides, then compare.
	# Any remaining difference means the copy diverged from the source.
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g; s/require\(script\.Parent:WaitForChild\("MapBuilder"\)\)/require(".\/MapBuilderStub")/g' "$src") "$dest" > /tmp/phase1-r5-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-r5-refresh-diff.txt
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

for name in DataService; do
	sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g; s/require\(script\.Parent:WaitForChild\("MapBuilder"\)\)/require(".\/MapBuilderStub")/g' \
		"$SVC_SRC/$name.luau" > "$DEST/services/$name.luau"
	check_copy "$SVC_SRC/$name.luau" "$DEST/services/$name.luau"
done
echo "refreshed 1 service module (DataService) into scripts/phase1-tests/r5-transactions/services/"
# Second DataService instance for the R5-4 two-server test (same
# pattern as r4-transactions/refresh.sh): test 04 loads DataService
# and DataServiceB as two independent module instances (two servers,
# one shared stub store).
cp "$DEST/services/DataService.luau" "$DEST/services/DataServiceB.luau"
echo "refreshed DataServiceB (second copy) into scripts/phase1-tests/r5-transactions/services/"

# R5 structural guards on the REAL sources.
anchor_fail=0
for anchor in \
	"function DataService.RetryLoad" \
	"datastore unavailable" \
	"function DataService.InvalidateReturnEscrow" \
	"function DataService.GetSaveWarning" \
	"SaveWarning" \
	"function DataService.RecordRewardVoidForInstance" \
	"VoidedRewardInstances" \
	"function DataService.GetSessionLeaseState" \
	"RetryPendingVoids" \
	"checkSessionHealth" \
	"sessionBlockedReason" \
	"function RaidService._TestSetStealChannelHook" \
	"function DataService.RunShutdownHooks" \
	"function DataService.RunPreSaveHooks" \
	"function DataService.GetShutdownHookStats" \
; do
	if ! grep -rqF "$anchor" "$SVC_SRC/DataService.luau" "$ROOT/src/server/Services/RaidService.luau" "$ROOT/src/server/Services/BaseService.luau" "$ROOT/src/shared/Remotes.luau" "$ROOT/src/client/Controllers/HUDController.luau"; then
		echo "ANCHOR MISSING: $anchor"
		anchor_fail=1
	fi
done
# The old R5-1 defect: a missing store counted as a successful load.
if grep -qF 'loadOk = store == nil' "$SVC_SRC/DataService.luau"; then
	echo "ANCHOR VIOLATION: LoadData still treats a missing store as a successful load (loadOk = store == nil)"
	anchor_fail=1
fi
# The old R5-4 defect: a failed lease read fell back to the cached
# lease and authorised the write blindly.
if grep -qF 'read does NOT block (it falls back to this server'"'"'s cached lease' "$SVC_SRC/DataService.luau"; then
	echo "ANCHOR VIOLATION: DataService still falls back to the cached lease on a failed lease read"
	anchor_fail=1
fi
if [ "$anchor_fail" -ne 0 ]; then
	echo "refresh FAILED: R5 anchors missing/violated"
	exit 1
fi
echo "refresh OK: R5 anchors present"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
