#!/usr/bin/env bash
# Build / guard the R5-3 + R5-4 "old behaviour" mutants for the
# negative controls (Worker C).
#
# mutant/DataServiceR4.luau is a STATIC snapshot of the PRE-R5
# DataService (shared with the Worker-A controls): it holds the old
# lease code (failed lease read falls back to the cached lease, the
# refresh extends the local expiry without checking the UpdateAsync
# result, SaveData checks the lease only before the _saving wait).
# mutant/RaidServiceR4.luau is a STATIC snapshot of the PRE-R5-3
# RaidService, taken verbatim from the refreshed theft/services
# copy with ONLY the harness require patch applied (its requires
# resolve to ../shared, i.e. r5-transactions/shared, from mutant/).
# Both snapshots are deliberately NOT rebuilt from src/ on every
# run: the R5 fixes restructure the void and the lease check (a
# verbatim revert would be fragile), so the snapshots are created
# once and then GUARDED — this script verifies the old behaviour is
# still present and the fix is still absent, and FAILS loudly
# otherwise, so a mutant can never silently drift into testing the
# fixed code.
#
# Behaviour of this script:
#   * If RaidServiceR4.luau does not exist yet: copy it from
#     theft/services/RaidService.luau — but ONLY if that copy still
#     contains the old behaviour (anchors below). If the source was
#     already fixed, there is no old behaviour to snapshot and the
#     script fails instead of snapshotting fixed code.
#   * If it already exists: verify the anchors still hold; never
#     overwrite it.
#   * DataServiceR4.luau must already exist (created by the
#     Worker-A make_mutant_r5_1_5.sh); verify its old-lease anchors.
#
# The mutant control tests (m03_r5_3_old_logic.luau,
# m04_r5_4_old_logic.luau, run by run_mutant_r5_3_4.sh) assert the
# OLD bad outcomes against these copies: if a control passes, the
# corresponding fixed test genuinely detects the bug; if a control
# fails, the fixed test would pass even against broken code.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_3_4.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r5-transactions/mutant"
DS_OLD="$DEST/DataServiceR4.luau"
RAID_OLD="$DEST/RaidServiceR4.luau"
RAID_SRC="$ROOT/scripts/phase1-tests/theft/services/RaidService.luau"
mkdir -p "$DEST"

fail=0
check_old_ds() {
	local file="$1"
	# R5-4 old behaviour: a failed lease read does NOT block (it
	# falls back to this server's cached lease).
	if ! grep -qF 'read does NOT block (it falls back to this server'"'"'s cached lease' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file lacks the old fail-open lease-read fallback"
		fail=1
	fi
	# The R5-4 fixes must be absent.
	if grep -qF 'function DataService.GetSessionLeaseState' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-4 fix (GetSessionLeaseState)"
		fail=1
	fi
	if grep -qF 'RecordRewardVoidForInstance' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-3 fix (RecordRewardVoidForInstance)"
		fail=1
	fi
	if grep -qF 'VoidedRewardInstances' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-3 fix (VoidedRewardInstances)"
		fail=1
	fi
}

check_old_raid() {
	local file="$1"
	# R5-3 old behaviour: the void returns early when the cache
	# holds no PendingRewards entry for the instance.
	if ! grep -qF 'local entry = data.PendingRewards[instanceId]' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file lacks the old void cache-entry lookup"
		fail=1
	fi
	# The R5-3 fixes must be absent.
	if grep -qF 'RetryPendingVoids' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-3 fix (RetryPendingVoids)"
		fail=1
	fi
	if grep -qF 'VoidedRewardInstances' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-3 fix (VoidedRewardInstances)"
		fail=1
	fi
	if grep -qF 'RecordRewardVoidForInstance' "$file"; then
		echo "MUTANT ANCHOR FAILED: $file already contains the R5-3 fix (RecordRewardVoidForInstance)"
		fail=1
	fi
}

if [ ! -f "$DS_OLD" ]; then
	echo "MUTANT MISSING: $DS_OLD does not exist (create it with make_mutant_r5_1_5.sh first)"
	exit 1
fi
echo "mutant DataServiceR4.luau exists; verifying old-lease anchors (never overwriting)"
check_old_ds "$DS_OLD"

if [ ! -f "$RAID_OLD" ]; then
	echo "mutant RaidServiceR4.luau does not exist; snapshotting the pre-fix copy"
	check_old_raid "$RAID_SRC"
	if [ "$fail" -ne 0 ]; then
		echo "make_mutant_r5_3_4 FAILED: source no longer contains the old behaviour — refusing to snapshot fixed code"
		exit 1
	fi
	cp "$RAID_SRC" "$RAID_OLD"
	echo "snapshotted $RAID_SRC -> $RAID_OLD"
else
	echo "mutant RaidServiceR4.luau already exists; verifying anchors (never overwriting)"
	check_old_raid "$RAID_OLD"
fi

if [ "$fail" -ne 0 ]; then
	echo "make_mutant_r5_3_4 FAILED"
	exit 1
fi
echo "make_mutant_r5_3_4 OK: old-behaviour anchors present, fixes absent"
