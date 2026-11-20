#!/usr/bin/env bash
# Build / guard the R5-1 + R5-5 "old behaviour" mutant for the
# negative controls.
#
# mutant/DataServiceR4.luau is a STATIC snapshot of the PRE-R5
# DataService (the working copy before the R5-1/R5-5 fixes), taken
# verbatim from the refreshed r5-transactions/services copy with ONLY
# the harness require patch applied. It is deliberately NOT rebuilt
# from src/ on every run: the R5 fixes restructure LoadData (a
# verbatim revert would be fragile), so the snapshot is created once
# and then GUARDED — this script verifies the old behaviour is still
# present and the fix is still absent, and FAILS loudly otherwise,
# so a mutant can never silently drift into testing the fixed code.
#
# Behaviour of this script:
#   * If DataServiceR4.luau does not exist yet: copy it from
#     services/DataService.luau — but ONLY if that copy still
#     contains the old behaviour (anchors below). If the source was
#     already fixed, there is no old behaviour to snapshot and the
#     script fails instead of snapshotting fixed code.
#   * If it already exists: verify the anchors still hold; never
#     overwrite it.
#
# The mutant control tests (m01_r5_1_old_logic.luau,
# m02_r5_5_old_logic.luau, run by run_mutant_r5_1_5.sh) assert the
# OLD bad outcomes against this copy: if a control passes, the
# corresponding fixed test genuinely detects the bug; if a control
# fails, the fixed test would pass even against broken code.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_1_5.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r5-transactions/mutant"
SRC="$ROOT/scripts/phase1-tests/r5-transactions/services/DataService.luau"
MUTANT="$DEST/DataServiceR4.luau"
mkdir -p "$DEST"

fail=0
check_old() {
	local file="$1"
	# R5-1 old behaviour: a missing store counts as a successful load.
	if ! grep -qF 'loadOk = store == nil' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file lacks the old 'loadOk = store == nil'"
		fail=1
	fi
	# R5-5 old behaviour: no store -> fail-open success in
	# InvalidateReturnEscrow (the branch just above the escrow read).
	if ! grep -qF 'return true, false, nil, nil' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file lacks the old fail-open InvalidateReturnEscrow return"
		fail=1
	fi
	# The fixes must be absent.
	if grep -qF 'function DataService.RetryLoad' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-1 fix (RetryLoad)"
		fail=1
	fi
	if grep -qF 'datastore unavailable' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-5 fix ('datastore unavailable')"
		fail=1
	fi
}

if [ ! -f "$MUTANT" ]; then
	echo "mutant DataServiceR4.luau does not exist; snapshotting the pre-fix copy"
	check_old "$SRC"
	if [ "$fail" -ne 0 ]; then
		echo "make_mutant_r5_1_5 FAILED: source no longer contains the old behaviour — refusing to snapshot fixed code"
		exit 1
	fi
	cp "$SRC" "$MUTANT"
	echo "snapshotted $SRC -> $MUTANT"
else
	echo "mutant DataServiceR4.luau already exists; verifying anchors (never overwriting)"
	check_old "$MUTANT"
fi

if [ "$fail" -ne 0 ]; then
	echo "make_mutant_r5_1_5 FAILED"
	exit 1
fi
echo "make_mutant_r5_1_5 OK: old-behaviour anchors present, fixes absent"
