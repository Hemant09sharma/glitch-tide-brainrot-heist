#!/usr/bin/env bash
# Build the R5-6 negative control: ProgressionServiceOld.luau is the
# PRE-FIX ProgressionService taken verbatim from git HEAD (the old
# direct-reset behaviour: `data.Coins = Config.StartingCoins or 100`
# in Rebirth/Prestige, raw-balance requirement check), with ONLY the
# harness require patch applied (ReplicatedStorage requires ->
# ../shared requires). The mutant control
# (m01_rebirth_prestige_old.luau) asserts the OLD bad outcomes
# against it; it passes only if the old code really wipes / eats the
# reserved reward coins, proving the fixed test discriminates.
# Fails if HEAD's file already contains the fix (then there is no old
# behaviour to control against) or if the anchors do not match.
# Usage (from the package root):
#   bash scripts/phase1-tests/r5-transactions/mutant/make_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r5-transactions/mutant"
mkdir -p "$DEST"
git -C "$ROOT" show "HEAD:src/server/Services/ProgressionService.luau" \
	| sed -E 's/require\(ReplicatedStorage:WaitForChild\("([A-Za-z_]+)"\)\)/require("..\/shared\/\1")/g' \
	> "$DEST/ProgressionServiceOld.luau"

fail=0
# The old direct resets must be present exactly twice (Rebirth + Prestige).
count=$(grep -cF 'data.Coins = Config.StartingCoins or 100' "$DEST/ProgressionServiceOld.luau" || true)
if [ "$count" != "2" ]; then
	echo "MUTANT ANCHOR FAILED: expected 2 direct resets, found $count"
	fail=1
fi
# The fix must be absent: no reservation-aware helpers or API use.
for anchor in "resetCoins" "spendableCoins" "GetReservedCoins" "GetSpendableCoins"; do
	if grep -qF "$anchor" "$DEST/ProgressionServiceOld.luau"; then
		echo "MUTANT ANCHOR FAILED: old copy contains fix marker: $anchor"
		fail=1
	fi
done
if [ "$fail" -ne 0 ]; then
	echo "make_mutant FAILED"
	exit 1
fi
echo "mutant OK: ProgressionServiceOld.luau built from HEAD (2 direct resets, no fix markers)"
