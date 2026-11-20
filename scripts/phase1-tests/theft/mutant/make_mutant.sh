#!/usr/bin/env bash
# Build the R2 mutant controls: copies of the CURRENT fixed RaidService
# with exactly one fix removed each, used as negative controls. Each
# mutant must FAIL its control test — that failure is the expected
# result and proves the test detects the missing fix.
#
#   RaidServiceP4.luau:        placed-preferred steal snapshot restored
#                              (R2-1); the owned (electric) mutation is
#                              overwritten by the stale placed (golden).
#   RaidServiceWatchdog.luau:  the reconcile call in ConfirmDelivery
#                              removed (R2-3); the watchdog leaves the
#                              stale placed copy untouched.
#   RaidServiceR13.luau:       the grant reverted to the old pcall +
#                              warn-only block (R2-4); an AddCoins
#                              failure is swallowed, no pending entry,
#                              delivery still claims success.
#   RaidServiceM5.luau:        thief identity check removed from
#                              ConfirmDelivery (R2-7 M5); a non-thief
#                              reaches the owned-record lookup.
#   RaidServiceM8.luau:        missing-owned-record guard removed from
#                              ConfirmDelivery (R2-7 M8); delivery
#                              proceeds onto a nil record.
#   RaidServiceE2.luau:        share re-derived locally with math.ceil
#                              instead of Economy.StealRewardShare
#                              (R2-7 E2); odd banked amounts lose 1 coin.
#   economy/shared/Economy.luau (with economy/services/RaidService.luau,
#                              a byte-identical copy of the fixed
#                              service): StealRewardShare hard-codes 0.5
#                              instead of Config.StealRewardMultiplier
#                              (R2-7 E1).
#
# The script fails unless every anchor is present exactly once in the
# source and the resulting diff touches ONLY the reverted lines, so a
# mutant can never silently drift from the current service.
# Usage (from the package root):
#   bash scripts/phase1-tests/theft/mutant/make_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SRC="$ROOT/scripts/phase1-tests/theft/services/RaidService.luau"
DEST="$ROOT/scripts/phase1-tests/theft/mutant"
mkdir -p "$DEST"

python3 - "$SRC" "$DEST" <<'PYEOF'
import sys
src_path, dest_dir = sys.argv[1], sys.argv[2]
src = open(src_path).read()

# --- P4: placed-preferred snapshot (R2-1) ---
level_fixed = "\t\tLevel = (stealOwned and tonumber(stealOwned.Level)) or tonumber(placed.Level) or 1,\n"
level_mutant = "\t\tLevel = tonumber(placed.Level) or 1,\n"
assert src.count(level_fixed) == 1, "P4 level line not found exactly once"
mutation_fixed = "\t\tMutation = (stealOwned and stealOwned.Mutation) or placed.Mutation,\n"
mutation_mutant = "\t\tMutation = placed.Mutation or (stealOwned and stealOwned.Mutation or nil),\n"
assert src.count(mutation_fixed) == 1, "P4 mutation line not found exactly once"
glitched_fixed = "\t\tGlitched = (stealOwned ~= nil and stealOwned.Glitched == true) or (stealOwned == nil and placed.Glitched == true),\n"
glitched_mutant = "\t\tGlitched = placed.Glitched == true,\n"
assert src.count(glitched_fixed) == 1, "P4 glitched line not found exactly once"
p4 = src.replace(level_fixed, level_mutant)
p4 = p4.replace(mutation_fixed, mutation_mutant)
p4 = p4.replace(glitched_fixed, glitched_mutant)
open(dest_dir + "/RaidServiceP4.luau", "w").write(p4)
print("mutant written: RaidServiceP4.luau (placed-preferred snapshot)")

# --- Watchdog: reconcile call removed (R2-3) ---
reconcile_fixed = "\treconcilePlacedCopy(thief, instanceId, owned)\n"
assert src.count(reconcile_fixed) == 1, "watchdog reconcile call not found exactly once"
watchdog = src.replace(reconcile_fixed, "\t-- MUTANT (R2-3 control): reconcile call removed.\n")
open(dest_dir + "/RaidServiceWatchdog.luau", "w").write(watchdog)
print("mutant written: RaidServiceWatchdog.luau (reconcile call removed)")

# --- R13: warn-only grant restored (R2-4) ---
# R5-8 re-anchor: R4-1 changed the grant call to pass the delivery
# TxId (5th arg) and added the comment lines inside the block, so
# the R2-era anchor (bare grantStealReward call, no comment) no
# longer matches. The mutant still restores the same old behaviour
# (pcall + warn-only, no pending entry, delivery claims success);
# only the anchor follows the current source shape.
grant_fixed = (
    "\tlocal reward = Economy.StealReward(record.CharacterId, tonumber(record.BankedIncome) or 0)\n"
    "\tlocal rewardStatus: string? = nil\n"
    "\tif reward > 0 then\n"
    "\t\t-- R4-1: the grant reuses the delivery TxId minted above, so\n"
    "\t\t-- the tombstone and the reward name the same transaction.\n"
    "\t\tlocal paid, status = grantStealReward(thief, instanceId, record.CharacterId, reward, deliveryTxId)\n"
    "\t\tif not paid then\n"
    "\t\t\trewardStatus = status\n"
    "\t\tend\n"
    "\tend\n"
)
grant_mutant = (
    "\tlocal reward = Economy.StealReward(record.CharacterId, tonumber(record.BankedIncome) or 0)\n"
    "\tlocal rewardStatus: string? = nil\n"
    "\tif reward > 0 then\n"
    "\t\tlocal ok = pcall(function()\n"
    "\t\t\t_dataService.AddCoins(thief, reward)\n"
    "\t\tend)\n"
    "\t\tif not ok then\n"
    "\t\t\twarn(\"[RaidService] Steal reward payment failed for \" .. thief.Name)\n"
    "\t\tend\n"
    "\tend\n"
)
assert src.count(grant_fixed) == 1, "R13 grant block not found exactly once"
r13 = src.replace(grant_fixed, grant_mutant)
open(dest_dir + "/RaidServiceR13.luau", "w").write(r13)
print("mutant written: RaidServiceR13.luau (warn-only grant restored)")

# --- M5: thief identity check removed (R2-7) ---
m5_fixed = "\tif not record or record.Thief ~= thief then\n"
m5_mutant = "\tif not record then -- MUTANT (M5 control): thief identity check removed.\n"
assert src.count(m5_fixed) == 1, "M5 identity guard not found exactly once"
m5 = src.replace(m5_fixed, m5_mutant)
open(dest_dir + "/RaidServiceM5.luau", "w").write(m5)
print("mutant written: RaidServiceM5.luau (thief identity check removed)")

# --- M8: missing-owned-record guard removed (R2-7) ---
m8_fixed = (
    "\tlocal owned = findOwnedRecord(thief, instanceId)\n"
    "\tif not owned then\n"
    "\t\treturn false, \"instance record missing\"\n"
    "\tend\n"
)
m8_mutant = (
    "\tlocal owned = findOwnedRecord(thief, instanceId)\n"
    "\t-- MUTANT (M8 control): missing-owned-record guard removed; delivery proceeds on a nil record.\n"
)
assert src.count(m8_fixed) == 1, "M8 owned guard not found exactly once"
m8 = src.replace(m8_fixed, m8_mutant)
open(dest_dir + "/RaidServiceM8.luau", "w").write(m8)
print("mutant written: RaidServiceM8.luau (missing-owned-record guard removed)")

# --- E2: share re-derived locally with ceil (R2-7) ---
e2_fixed = "\tlocal paidShare = Economy.StealRewardShare(record.CharacterId, banked)\n"
e2_mutant = "\tlocal paidShare = math.ceil(banked * Config.StealRewardMultiplier) -- MUTANT (E2 control): locally re-derived share with ceil instead of the single Economy.StealRewardShare floor computation.\n"
assert src.count(e2_fixed) == 1, "E2 paidShare line not found exactly once"
e2 = src.replace(e2_fixed, e2_mutant)
open(dest_dir + "/RaidServiceE2.luau", "w").write(e2)
print("mutant written: RaidServiceE2.luau (share re-derived with ceil)")

# --- E1: hard-coded 0.5 share in Economy (R2-7) ---
# The mutant Economy lives in mutant/economy/shared/ with a full copy
# of the shared modules and a copy of the fixed RaidService in
# mutant/economy/services/, so the mutant service's
# require("../shared/Economy") resolves to the mutant Economy.
import os, shutil
eco_dir = os.path.join(dest_dir, "economy")
eco_shared = os.path.join(eco_dir, "shared")
eco_services = os.path.join(eco_dir, "services")
os.makedirs(eco_shared, exist_ok=True)
os.makedirs(eco_services, exist_ok=True)
theft_dir = os.path.dirname(dest_dir)
for f in sorted(os.listdir(os.path.join(theft_dir, "shared"))):
    if f.endswith(".luau"):
        shutil.copy(os.path.join(theft_dir, "shared", f), os.path.join(eco_shared, f))
shutil.copy(os.path.join(theft_dir, "services", "RaidService.luau"),
            os.path.join(eco_services, "RaidService.luau"))
eco_src = open(os.path.join(eco_shared, "Economy.luau")).read()
e1_fixed = "\treturn math.floor(banked * Config.StealRewardMultiplier)\n"
e1_mutant = "\treturn math.floor(banked * 0.5) -- MUTANT (E1 control): hard-coded 0.5, ignores Config.StealRewardMultiplier.\n"
assert eco_src.count(e1_fixed) == 1, "E1 share line not found exactly once in Economy"
eco_src = eco_src.replace(e1_fixed, e1_mutant)
open(os.path.join(eco_shared, "Economy.luau"), "w").write(eco_src)
print("mutant written: economy/shared/Economy.luau (hard-coded 0.5 share)")
PYEOF

# Prove each RaidService mutant differs from the fixed service ONLY in
# its reverted lines.
for name in P4 Watchdog R13 M5 M8 E2; do
	if ! diff "$SRC" "$DEST/RaidService$name.luau" > "/tmp/phase1-theft-mutant-$name-diff.txt"; then
		echo "--- mutant diff vs fixed service: RaidService$name.luau ---"
		cat "/tmp/phase1-theft-mutant-$name-diff.txt"
	fi
done
# Prove the E1 economy mutant differs from the fixed shared modules
# ONLY in the hard-coded share line, and its RaidService copy is
# byte-identical to the fixed one.
if ! diff "$ROOT/scripts/phase1-tests/theft/shared/Economy.luau" "$DEST/economy/shared/Economy.luau" > "/tmp/phase1-theft-mutant-E1-diff.txt"; then
	echo "--- mutant diff vs fixed Economy: economy/shared/Economy.luau ---"
	cat "/tmp/phase1-theft-mutant-E1-diff.txt"
fi
for f in "$ROOT"/scripts/phase1-tests/theft/shared/*.luau; do
	base="$(basename "$f")"
	[ "$base" = "Economy.luau" ] && continue
	if ! cmp -s "$f" "$DEST/economy/shared/$base"; then
		echo "make_mutant FAILED: economy/shared/$base differs from the fixed shared copy"
		exit 1
	fi
done
if ! cmp -s "$SRC" "$DEST/economy/services/RaidService.luau"; then
	echo "make_mutant FAILED: economy/services/RaidService.luau differs from the fixed service copy"
	exit 1
fi
# Guards: the mutants must no longer contain the fixed code.
if grep -q "stealOwned and stealOwned.Mutation) or placed.Mutation" "$DEST/RaidServiceP4.luau"; then
	echo "make_mutant FAILED: P4 mutant still has the owned-authoritative snapshot"
	exit 1
fi
if grep -q "reconcilePlacedCopy(thief, instanceId, owned)" "$DEST/RaidServiceWatchdog.luau"; then
	echo "make_mutant FAILED: watchdog mutant still calls the reconcile"
	exit 1
fi
if grep -q "grantStealReward(thief, instanceId" "$DEST/RaidServiceR13.luau"; then
	echo "make_mutant FAILED: R13 mutant still grants through the ledger path"
	exit 1
fi
if grep -q "record.Thief ~= thief" "$DEST/RaidServiceM5.luau"; then
	echo "make_mutant FAILED: M5 mutant still checks the thief identity"
	exit 1
fi
if grep -q 'return false, "instance record missing"' "$DEST/RaidServiceM8.luau"; then
	echo "make_mutant FAILED: M8 mutant still guards the missing owned record"
	exit 1
fi
if grep -q "Economy.StealRewardShare(record.CharacterId, banked)" "$DEST/RaidServiceE2.luau"; then
	echo "make_mutant FAILED: E2 mutant still calls the single share computation"
	exit 1
fi
if grep -q "banked \* Config.StealRewardMultiplier" "$DEST/economy/shared/Economy.luau"; then
	echo "make_mutant FAILED: E1 mutant Economy still reads Config.StealRewardMultiplier"
	exit 1
fi
echo "make_mutant OK"
