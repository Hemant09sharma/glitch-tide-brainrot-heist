#!/usr/bin/env bash
# Build the R2-7 mutant: a copy of the CURRENT ExpeditionService with
# the InTransit guards removed (eligibility filter + StartExpedition
# rejection), used as a negative control. The helpers and the defensive
# claim path stay — only the two guards go, so the mutant is exactly
# "the fix, minus the fix".
#
# The script fails unless BOTH guards are present in the source and
# the resulting diff touches ONLY those lines, so the mutant can never
# silently drift from the current service.
# Usage (from the package root):
#   bash scripts/phase1-tests/expedition/mutant/make_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SRC="$ROOT/scripts/phase1-tests/expedition/services/ExpeditionService.luau"
DEST="$ROOT/scripts/phase1-tests/expedition/mutant/ExpeditionService.luau"
mkdir -p "$(dirname "$DEST")"
python3 - "$SRC" "$DEST" <<'PYEOF'
import sys
src_path, dest_path = sys.argv[1], sys.argv[2]
src = open(src_path).read()

elig_fixed = "\t\t\t\t\tif type(inst) == \"table\" and inst.Placed ~= true and inst.OnExpedition ~= true and inst.InTransit ~= true then"
elig_mutant = "\t\t\t\t\tif type(inst) == \"table\" and inst.Placed ~= true and inst.OnExpedition ~= true then"
assert src.count(elig_fixed) == 1, "eligibility guard not found exactly once"
mutant = src.replace(elig_fixed, elig_mutant)

guard_block = (
    "\t-- R2-2 / P0-3: a stolen Brainrot in transit must never start an\n"
    "\t-- expedition. The record sits in the thief's OwnedInstances with\n"
    "\t-- InTransit = true, so FindInstance above returns it — without\n"
    "\t-- this check the thief could lock the victim's Brainrot behind an\n"
    "\t-- Active entry the victim cannot claim. This check runs before\n"
    "\t-- ANY mutation below (no Active entry, no flag set, no rewards).\n"
    "\tif inst.InTransit == true then\n"
    "\t\treturn false, \"instance is in transit and cannot be sent on an expedition\"\n"
    "\tend\n"
)
assert mutant.count(guard_block) == 1, "StartExpedition guard block not found exactly once"
mutant = mutant.replace(guard_block, "")
open(dest_path, "w").write(mutant)
print("mutant written: eligibility filter + StartExpedition InTransit rejection removed")
PYEOF
# Prove the mutant differs from the fixed service ONLY in those guards.
if ! diff "$SRC" "$DEST" > /tmp/phase1-expedition-mutant-diff.txt; then
	echo "--- mutant diff vs fixed service (must be only the two guards) ---"
	cat /tmp/phase1-expedition-mutant-diff.txt
fi
removed=$(grep -c "InTransit" "$DEST" || true)
echo "mutant still mentions InTransit $removed times (claim path + helper comments only)"
if grep -q "instance is in transit and cannot be sent" "$DEST"; then
	echo "make_mutant FAILED: StartExpedition rejection still present"
	exit 1
fi
if grep -q "inst.InTransit ~= true" "$DEST"; then
	echo "make_mutant FAILED: eligibility InTransit filter still present"
	exit 1
fi
echo "make_mutant OK"
