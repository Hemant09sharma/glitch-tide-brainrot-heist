#!/usr/bin/env bash
# Refresh the R4-transactions test copies of the REAL services +
# shared modules (same pattern as scripts/phase1-tests/theft/refresh.sh).
#
# Copies src/shared/*.luau into scripts/phase1-tests/r4-transactions/shared/
# and the R4-owned services into scripts/phase1-tests/r4-transactions/services/,
# applying ONLY harness-only require patches (the project files are never
# touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   service: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
#   service: require(script.Parent:WaitForChild("MapBuilder"))
#            -> require("./MapBuilderStub")   (Lune-only stand-in, copied
#              from the store suite; the real MapBuilder builds plots
#              from Workspace parts)
#
# Services copied here (the ones the R4 tests load directly):
#   DataService, RaidService, BaseService, EconomyService,
#   ConveyorService, LaboratoryService, AbilityService.
# DataServiceB.luau is a SECOND copy of the same DataService source —
# the R4-7 two-server test loads DataService and DataServiceB as two
# independent module instances (two servers, one shared stub store).
# The theft / persistence / store suites' own refresh scripts own
# their copies; this script refreshes ONLY the r4-transactions copies
# (run.sh runs the other refresh scripts first).
#
# The copies are byte-identical to the sources apart from those require
# lines — the script diffs each copy against its source after patching
# and FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
#
# Structural guards for the R4 fixes (fail the refresh if the source
# regresses): GUID TxIds, the delivery tombstone, the park-retry ledger,
# the coin reservation, the session lease, the void ledger, the
# shutdown fan-out, and the legacy admin recovery.
#
# The mutant controls (mutant/) are STATIC snapshots built by
# mutant/make_mutant.sh from these copies and are deliberately NOT
# refreshed — they are the old unsafe behaviour the new tests must
# catch. See mutant/run_mutant.sh.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/r4-transactions/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r4-transactions"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	# Strip the patched require lines from both sides, then compare.
	# Any remaining difference means the copy diverged from the source.
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g; s/require\(script\.Parent:WaitForChild\("MapBuilder"\)\)/require(".\/MapBuilderStub")/g' "$src") "$dest" > /tmp/phase1-r4-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-r4-refresh-diff.txt
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
echo "refreshed $count shared modules into scripts/phase1-tests/r4-transactions/shared/"

for name in DataService RaidService BaseService EconomyService ConveyorService LaboratoryService AbilityService; do
	sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g; s/require\(script\.Parent:WaitForChild\("MapBuilder"\)\)/require(".\/MapBuilderStub")/g' \
		"$SVC_SRC/$name.luau" > "$DEST/services/$name.luau"
	check_copy "$SVC_SRC/$name.luau" "$DEST/services/$name.luau"
done
# Second DataService instance for the R4-7 two-server test.
cp "$DEST/services/DataService.luau" "$DEST/services/DataServiceB.luau"
# Second RaidService instance for the R4-6 two-server TxId test
# (two module instances = two servers: each has its own TxId
# counter starting at 0, so any distinctness across them must come
# from the GUID, not the counter).
cp "$DEST/services/RaidService.luau" "$DEST/services/RaidServiceB.luau"
echo "refreshed 7 service modules (+ DataServiceB, RaidServiceB) into scripts/phase1-tests/r4-transactions/services/"

# MapBuilderStub: hand-written Lune stand-in, copied from the store suite.
cp "$ROOT/scripts/phase1-tests/store/services/MapBuilderStub.luau" "$DEST/services/MapBuilderStub.luau"
echo "refreshed MapBuilderStub into scripts/phase1-tests/r4-transactions/services/"

# R4 structural guards on the REAL sources.
anchor_fail=0
for anchor in \
	"GenerateGUID" \
	"local function newGuid" \
	"function DataService.InvalidateReturnEscrow" \
	"SupersedesReturnTxIds" \
	"function RaidService.RetryPendingParks" \
	"ParkedTxns" \
	"function DataService.ReserveCoins" \
	"GetSpendableCoins" \
	"SESSION_LEASE_TTL" \
	"function DataService.AcquireSessionLease" \
	"VoidedRewardTxns" \
	"function DataService.SaveAllForShutdown" \
	"function RaidService.RecoverLegacyRecord" \
	"SetLegacyRecoveryOperators" \
	"function DataService.GetSaveWarning" \
	"SaveWarning" \
; do
	if ! grep -rqF "$anchor" "$SVC_SRC/DataService.luau" "$SVC_SRC/RaidService.luau" "$ROOT/src/shared/Remotes.luau" "$ROOT/src/client/Controllers/HUDController.luau"; then
		echo "ANCHOR MISSING: $anchor"
		anchor_fail=1
	fi
done
# The old R3 probabilistic TxId shape must be gone from RaidService.
if grep -qF 'string.format("sr-%d-%s-%d-%d-%d"' "$SVC_SRC/RaidService.luau"; then
	echo "ANCHOR VIOLATION: old probabilistic reward TxId format still present in RaidService.luau"
	anchor_fail=1
fi
if grep -qF 'string.format("rt-%d-%s-%d-%d-%d"' "$SVC_SRC/RaidService.luau"; then
	echo "ANCHOR VIOLATION: old probabilistic return TxId format still present in RaidService.luau"
	anchor_fail=1
fi
if [ "$anchor_fail" -ne 0 ]; then
	echo "refresh FAILED: R4 anchors missing/violated"
	exit 1
fi
echo "refresh OK: R4 anchors present"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
