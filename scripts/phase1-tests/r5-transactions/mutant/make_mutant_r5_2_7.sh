#!/usr/bin/env bash
# Build / guard the R5-2 + R5-7 "old behaviour" mutants for the
# negative controls (Worker D).
#
# mutant/RaidServiceR5Pre2.luau is a STATIC snapshot of the PRE-R5-2
# RaidService, taken verbatim from the refreshed theft/services copy
# with ONLY the harness require patch applied (its requires resolve
# to ../shared, i.e. r5-transactions/shared, from mutant/). It holds
# the Worker-C R5-3/R5-4 code but no session-health gates.
# mutant/BaseServiceR5Pre2.luau is a STATIC snapshot of the PRE-R5-2
# BaseService, taken verbatim from the refreshed store/services copy
# (its ../shared requires likewise resolve to r5-transactions/shared,
# and its ./MapBuilderStub require resolves to mutant/MapBuilderStub).
# mutant/DataServiceR5Pre7.luau is a STATIC snapshot of the PRE-R5-7
# DataService, taken verbatim from the refreshed r5/services copy.
# All three snapshots are deliberately NOT rebuilt from src/ on every
# run: the R5-2/R5-7 fixes restructure the gated paths (a verbatim
# revert would be fragile), so the snapshots are created once and
# then GUARDED — this script verifies the old behaviour is still
# present and the fix is still absent, and FAILS loudly otherwise,
# so a mutant can never silently drift into testing the fixed code.
#
# Behaviour of this script:
#   * If a snapshot does not exist yet: copy it from the refreshed
#     suite copy — but ONLY if that copy still contains the old
#     behaviour (anchors below). If the source was already fixed,
#     there is no old behaviour to snapshot and the script fails
#     instead of snapshotting fixed code.
#   * If it already exists: verify the anchors still hold; never
#     overwrite it.
#
# The mutant control tests (m05_r5_2_old_logic.luau,
# m07_r5_7_old_logic.luau, run by run_mutant_r5_2_7.sh) assert the
# OLD bad outcomes against these copies: if a control passes, the
# corresponding fixed test genuinely detects the bug; if a control
# fails, the fixed test would pass even against broken code.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_2_7.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r5-transactions/mutant"
RAID_OLD="$DEST/RaidServiceR5Pre2.luau"
RAID_SRC="$ROOT/scripts/phase1-tests/theft/services/RaidService.luau"
BASE_OLD="$DEST/BaseServiceR5Pre2.luau"
BASE_SRC="$ROOT/scripts/phase1-tests/store/services/BaseService.luau"
DS_OLD="$DEST/DataServiceR5Pre7.luau"
DS_SRC="$ROOT/scripts/phase1-tests/r5-transactions/services/DataService.luau"
mkdir -p "$DEST"

fail=0
check_old_raid() {
	local file="$1"
	# R5-2 old behaviour: no session-health gate helpers at all.
	if grep -qF 'checkSessionHealth' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-2 fix (checkSessionHealth)"
		fail=1
	fi
	if grep -qF 'function RaidService._TestSetStealChannelHook' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-2 fix (_TestSetStealChannelHook)"
		fail=1
	fi
	# The snapshot must still be the post-Worker-C code (R5-3/R5-4
	# present), not an ancient copy: the control isolates the R5-2
	# delta only.
	if ! grep -qF 'function RaidService.RetryPendingVoids' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file lacks the R5-3 code (RetryPendingVoids) — not the pre-R5-2 snapshot"
		fail=1
	fi
}

check_old_base() {
	local file="$1"
	# R5-2 old behaviour: no session-health gate helper, no refusal text.
	if grep -qF 'sessionBlockedReason' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-2 fix (sessionBlockedReason)"
		fail=1
	fi
	if grep -qF 'session cannot save: ' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-2 fix (refusal text)"
		fail=1
	fi
}

check_old_ds() {
	local file="$1"
	# R5-7 old behaviour: BindToClose runs the pre-save hooks inline,
	# one player after another (sequential for-loop directly calling
	# runPreSaveHooks).
	if ! grep -A1 -F 'for _, player in ipairs(Players:GetPlayers()) do' "$file" | grep -qF 'runPreSaveHooks(player)'; then
		echo "MUTANT ANCHOR FAILED: $file lacks the old sequential BindToClose hook loop"
		fail=1
	fi
	# The R5-7 fixes must be absent.
	if grep -qF 'function DataService.RunShutdownHooks' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-7 fix (RunShutdownHooks)"
		fail=1
	fi
	if grep -qF 'function DataService.RunPreSaveHooks' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-7 fix (RunPreSaveHooks)"
		fail=1
	fi
	if grep -qF 'function DataService.GetShutdownHookStats' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-7 fix (GetShutdownHookStats)"
		fail=1
	fi
}

if [ ! -f "$RAID_OLD" ]; then
	echo "mutant RaidServiceR5Pre2.luau does not exist; snapshotting the pre-fix copy"
	check_old_raid "$RAID_SRC"
	if [ "$fail" -ne 0 ]; then
		echo "make_mutant_r5_2_7 FAILED: source no longer contains the old behaviour — refusing to snapshot fixed code"
		exit 1
	fi
	cp "$RAID_SRC" "$RAID_OLD"
	echo "snapshotted $RAID_SRC -> $RAID_OLD"
else
	echo "mutant RaidServiceR5Pre2.luau already exists; verifying anchors (never overwriting)"
	check_old_raid "$RAID_OLD"
fi

if [ ! -f "$BASE_OLD" ]; then
	echo "mutant BaseServiceR5Pre2.luau does not exist; snapshotting the pre-fix copy"
	check_old_base "$BASE_SRC"
	if [ "$fail" -ne 0 ]; then
		echo "make_mutant_r5_2_7 FAILED: source no longer contains the old behaviour — refusing to snapshot fixed code"
		exit 1
	fi
	cp "$BASE_SRC" "$BASE_OLD"
	echo "snapshotted $BASE_SRC -> $BASE_OLD"
else
	echo "mutant BaseServiceR5Pre2.luau already exists; verifying anchors (never overwriting)"
	check_old_base "$BASE_OLD"
fi

if [ ! -f "$DEST/MapBuilderStub.luau" ]; then
	echo "MUTANT MISSING: $DEST/MapBuilderStub.luau does not exist (the BaseService snapshot requires ./MapBuilderStub from mutant/)"
	fail=1
fi

if [ ! -f "$DS_OLD" ]; then
	echo "mutant DataServiceR5Pre7.luau does not exist; snapshotting the pre-fix copy"
	check_old_ds "$DS_SRC"
	if [ "$fail" -ne 0 ]; then
		echo "make_mutant_r5_2_7 FAILED: source no longer contains the old behaviour — refusing to snapshot fixed code"
		exit 1
	fi
	cp "$DS_SRC" "$DS_OLD"
	echo "snapshotted $DS_SRC -> $DS_OLD"
else
	echo "mutant DataServiceR5Pre7.luau already exists; verifying anchors (never overwriting)"
	check_old_ds "$DS_OLD"
fi

if [ "$fail" -ne 0 ]; then
	echo "make_mutant_r5_2_7 FAILED"
	exit 1
fi
echo "make_mutant_r5_2_7 OK: old-behaviour anchors present, fixes absent"
