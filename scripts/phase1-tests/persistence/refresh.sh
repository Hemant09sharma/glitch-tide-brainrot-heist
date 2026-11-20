#!/usr/bin/env bash
# Refresh the Phase 1 persistence-test copies of the REAL DataService +
# shared modules (same pattern as scripts/phase1-tests/theft/refresh.sh).
#
# Copies src/shared/*.luau into scripts/phase1-tests/persistence/shared/
# and src/server/Services/DataService.luau into
# scripts/phase1-tests/persistence/services/, applying ONLY harness-only
# require patches (the project files are never touched):
#   shared:  require(script.Parent.X)            -> require("./X")
#   service: require(ReplicatedStorage:WaitForChild("X"))
#            -> require("../shared/X")
#
# The copies are byte-identical to the sources apart from those require
# lines — the script diffs each copy against its source after patching
# and FAILS if any other line differs, so a test can never silently run
# stale or diverged code. Re-run after any src/ change.
#
# Structural guards for the R3 fix (fail the refresh if the source
# regresses): the sidecar append path must be UpdateAsync-based
# (appendSidecar), the old read-modify-write helper (writeSidecar) and
# the `readSidecar(...) or {}` wipe pattern must be gone, and the read
# must report failure explicitly (readSidecar returns ok, value).
#
# The mutant control (mutant/DataServiceOld.luau) is a STATIC snapshot
# of the pre-R3 DataService and is deliberately NOT refreshed — it is
# the old unsafe behaviour the new tests must catch. See
# mutant/run_mutant.sh.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/persistence/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/persistence"
SHARED_SRC="$ROOT/src/shared"
SVC_SRC="$ROOT/src/server/Services"
mkdir -p "$DEST/shared" "$DEST/services"

fail=0
check_copy() {
	local src="$1" dest="$2"
	# Strip the patched require lines from both sides, then compare.
	# Any remaining difference means the copy diverged from the source.
	if ! diff <(sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g; s/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' "$src") "$dest" > /tmp/phase1-persistence-refresh-diff.txt; then
		echo "DIVERGED: $dest differs from $src beyond the require patch:"
		cat /tmp/phase1-persistence-refresh-diff.txt
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
echo "refreshed $count shared modules into scripts/phase1-tests/persistence/shared/"

sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' \
	"$SVC_SRC/DataService.luau" > "$DEST/services/DataService.luau"
check_copy "$SVC_SRC/DataService.luau" "$DEST/services/DataService.luau"
echo "refreshed DataService into scripts/phase1-tests/persistence/services/"

# R3 structural guards on the REAL source.
anchor_fail=0
for anchor in \
	"local function appendSidecar" \
	"store:UpdateAsync(key, function" \
	"local function readSidecar(store: any, key: string): (boolean, { any }?)" \
	"return false, nil" \
; do
	if ! grep -qF "$anchor" "$SVC_SRC/DataService.luau"; then
		echo "ANCHOR MISSING: $anchor"
		anchor_fail=1
	fi
done
for forbidden in \
	"writeSidecar" \
	"readSidecar(store, key) or {}" \
	"store:SetAsync(key, value)" \
; do
	if grep -qF "$forbidden" "$SVC_SRC/DataService.luau"; then
		echo "ANCHOR VIOLATION: forbidden R3 pattern still present: $forbidden"
		anchor_fail=1
	fi
done
if [ "$anchor_fail" -ne 0 ]; then
	echo "refresh FAILED: R3 anchors missing/violated in src/server/Services/DataService.luau"
	exit 1
fi
echo "refresh OK: R3 anchors present in DataService.luau"

if [ "$fail" -ne 0 ]; then
	echo "refresh FAILED: copies diverged from sources (see above)"
	exit 1
fi
echo "refresh OK: copies match sources apart from require lines"
