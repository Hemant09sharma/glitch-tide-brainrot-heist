#!/usr/bin/env bash
# Build the R4 "old behaviour" mutants for the negative controls.
# The mutants are STATIC snapshots of the pre-R4 (R3) behaviour,
# built from the current FIXED service copies by reverting exactly
# the R4 changes under test — they are deliberately NOT refreshed
# (refresh.sh only refreshes the fixed copies). Each revert is
# anchored on exact source text and FAILS the build if the anchor
# does not match exactly once, so a mutant can never silently drift
# into testing the fixed code (or into a broken file).
#
# mutant/RaidServiceR3.luau — from theft/services/RaidService.luau:
#   R4-1: ConfirmDelivery no longer invalidates stale return
#         escrow (no tombstone, no fail-closed delivery).
#   R4-2: recordPendingReward ignores the park result (parked is
#         assumed true) and RetryPendingParks is a no-op.
#   R4-3: commitPendingPayment has no coin reservation (plain
#         AddCoins(-payable) rollback with the zero clamp).
#   R4-4: RecoverStaleTransit never voids pending rewards.
# mutant/DataServiceR3.luau — from r4-transactions/services/DataService.luau:
#   R4-7: acquireSessionLease always succeeds (no lease contention;
#         last-write-wins).
#   R4-8: SaveData drops after ONE wait (no RetryOnce second wait);
#         SaveAllForShutdown saves sequentially (no spawned fan-out).
#
# The mutant control tests (mutant/m*.luau, run by
# mutant/run_mutant.sh) assert the OLD bad outcome against these
# copies: if a control passes, the corresponding fixed test
# genuinely detects the bug; if a control fails, the fixed test
# would pass even against broken code.
#
# Usage (from the package root):
#   bash scripts/phase1-tests/r4-transactions/mutant/make_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEST="$ROOT/scripts/phase1-tests/r4-transactions/mutant"
SRC_RAID="$ROOT/scripts/phase1-tests/theft/services/RaidService.luau"
SRC_DS="$ROOT/scripts/phase1-tests/r4-transactions/services/DataService.luau"
cp "$SRC_RAID" "$DEST/RaidServiceR3.luau"
cp "$SRC_DS" "$DEST/DataServiceR3.luau"
python3 - "$DEST/RaidServiceR3.luau" "$DEST/DataServiceR3.luau" <<'PYEOF'
import sys

def fail(msg):
    print("make_mutant FAILED: " + msg)
    sys.exit(1)

def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def replace_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        fail("%s: anchor matched %d times, expected 1: %r" % (what, n, old[:100]))
    return text.replace(old, new, 1)

def find_line(lines, pred, what):
    hits = [i for i, l in enumerate(lines) if pred(l)]
    if len(hits) != 1:
        fail("%s: matched %d lines, expected 1" % (what, len(hits)))
    return hits[0]

def delete_span(text, start_pred, end_pred, what, include_end=True):
    """Delete lines[start..end]. end_pred finds the end line; when
    include_end is False the end line itself is kept."""
    lines = text.split("\n")
    start = find_line(lines, start_pred, what + " (start)")
    end = None
    for j in range(start, len(lines)):
        if end_pred(lines[j]):
            end = j
            break
    if end is None:
        fail(what + ": end anchor not found")
    if not include_end:
        end -= 1
    if end < start:
        fail(what + ": empty span")
    return "\n".join(lines[:start] + lines[end + 1:])

raid_path, ds_path = sys.argv[1], sys.argv[2]
raid = read(raid_path)
ds = read(ds_path)

# --- R4-1: drop the R4-1 comment (up to but not including the
# deliveryTxId mint, which grantStealReward still needs).
raid = delete_span(
    raid,
    lambda l: l == "\t-- R4-1: invalidate any stale return escrow for this instance",
    lambda l: l == "\tlocal deliveryTxId = newRewardTxId(thief, instanceId)",
    "R4-1 comment",
    include_end=False,
)
# Drop the invalidation call + fail-closed return + post-yield
# re-verification (invOk line through the re-verify block's end).
lines = raid.split("\n")
inv = find_line(lines, lambda l: l.startswith("\tlocal invOk, invReason = invalidateStaleReturnEscrow("), "R4-1 invOk")
ret = None
for j in range(inv, len(lines)):
    if lines[j] == "\t\treturn false, \"theft resolved during delivery\"":
        ret = j
        break
if ret is None:
    fail("R4-1 re-verify return not found")
if lines[ret + 1] != "\tend":
    fail("R4-1 re-verify end not found")
raid = "\n".join(lines[:inv] + lines[ret + 2:])

# --- R4-2: ignore the park result; RetryPendingParks is a no-op.
raid = replace_once(
    raid,
    "\t\tparked = okCall and stored == true",
    "\t\tparked = true -- MUTANT (R3): the park result is ignored",
    "R4-2 park result",
)
raid = replace_once(
    raid,
    "function RaidService.RetryPendingParks(player: Player): (number, number)\n",
    "function RaidService.RetryPendingParks(player: Player): (number, number)\n\t-- MUTANT (R3): no park retry — the failed park is never retried.\n\tif true then\n\t\treturn 0, 0\n\tend\n",
    "R4-2 RetryPendingParks",
)

# --- R4-3: no coin reservation in commitPendingPayment. Delete the
# reserve block (comment through the closing end of the
# ReserveCoins if), keeping the reserveKey/reserved locals defined
# (as false) so the downstream `if reserved then` checks resolve.
lines = raid.split("\n")
cstart = find_line(lines, lambda l: l == "\t-- R4-3: reserve the credited amount before the save can yield.", "R4-3 reserve comment")
cend = None
for j in range(cstart, len(lines)):
    if lines[j] == "\tfor txId, delta in pairs(toMark) do":
        cend = j
        break
if cend is None:
    fail("R4-3 reserve end (toMark loop) not found")
raid = "\n".join(
    lines[:cstart]
    + ["\tlocal reserveKey = \"reward:\" .. instanceId", "\tlocal reserved = false -- MUTANT (R3): no reservation"]
    + lines[cend:]
)

# --- R4-4: RecoverStaleTransit never voids pending rewards (remove
# the three call sites; the helper itself stays, unused).
# R5-8 re-anchor: R5-3 rewrote voidPendingRewardsForInstance to
# return (voidedTxIds, durable), and each call site now captures the
# result and counts the recovery `remaining` when the void is not
# durable. The R4-era bare-call anchors therefore match 0 times.
# Deleting ONLY the call line would leave `voidDurableB/D/E` as
# nil reads, which would count every recovery `remaining` — that is
# NOT the R3 behaviour (R3 counted each voided recovery resolved
# and left the reward payable). So each revert removes the void
# call AND its R5-3 durability branch, restoring the plain
# `resolved += 1` of the R3 code.
raid = replace_once(
    raid,
    "\t\t\t\tlocal _voidedB, voidDurableB = voidPendingRewardsForInstance(player, instanceId)\n"
    "\t\t\t\t_inTransit[instanceId] = nil\n"
    "\t\t\t\tif player.Character then\n"
    "\t\t\t\t\tplayer.Character:SetAttribute(\"CarryingStolen\", \"\")\n"
    "\t\t\t\tend\n"
    "\t\t\t\tif voidDurableB then\n"
    "\t\t\t\t\tresolved += 1\n"
    "\t\t\t\telse\n"
    "\t\t\t\t\tremaining += 1\n"
    "\t\t\t\tend\n",
    "\t\t\t\t_inTransit[instanceId] = nil\n"
    "\t\t\t\tif player.Character then\n"
    "\t\t\t\t\tplayer.Character:SetAttribute(\"CarryingStolen\", \"\")\n"
    "\t\t\t\tend\n"
    "\t\t\t\tresolved += 1 -- MUTANT (R3): no void; the recovery counts resolved\n",
    "R4-4 void call (rule b)",
)
raid = replace_once(
    raid,
    "\t\t\t\t\t\t\tlocal _voidedD, voidDurableD = voidPendingRewardsForInstance(player, instanceId)\n"
    "\t\t\t\t\t\t\tif voidDurableD then\n"
    "\t\t\t\t\t\t\t\tresolved += 1\n"
    "\t\t\t\t\t\t\telse\n"
    "\t\t\t\t\t\t\t\tremaining += 1\n"
    "\t\t\t\t\t\t\tend\n",
    "\t\t\t\t\t\t\tresolved += 1 -- MUTANT (R3): no void; the recovery counts resolved\n",
    "R4-4 void call (rule d online)",
)
raid = replace_once(
    raid,
    "\t\t\t\t\t\t\tlocal _voidedE, voidDurableE = voidPendingRewardsForInstance(player, instanceId)\n"
    "\t\t\t\t\t\t\tif voidDurableE then\n"
    "\t\t\t\t\t\t\t\tresolved += 1\n"
    "\t\t\t\t\t\t\telse\n"
    "\t\t\t\t\t\t\t\tremaining += 1\n"
    "\t\t\t\t\t\t\tend\n",
    "\t\t\t\t\t\t\tresolved += 1 -- MUTANT (R3): no void; the recovery counts resolved\n",
    "R4-4 void call (rule d offline)",
)

# --- R4-7: the lease never contends.
# R5-8 re-anchor: R5-4 changed the signature to return
# (boolean, any) — the acquire result is now a pair. The mutant
# still returns true unconditionally (result nil); every caller
# only reads the result when the acquire FAILED, so `return true`
# keeps the last-write-wins behaviour.
ds = replace_once(
    ds,
    "local function acquireSessionLease(player: Player): (boolean, any)\n",
    "local function acquireSessionLease(player: Player): boolean\n\t-- MUTANT (R3): no session lease; last-write-wins.\n\tif true then\n\t\treturn true\n\tend\n",
    "R4-7 acquireSessionLease",
)

# --- R4-8: SaveData drops after ONE wait (no RetryOnce branch).
ds = replace_once(
    ds,
    "\t\tif retryOnce then\n"
    "\t\t\twarn(string.format(\n"
    "\t\t\t\t\"[DataService] Save for %s still waiting after %ds; retrying the wait once (leave path)\",\n"
    "\t\t\t\tplayer.Name, waitSeconds))\n"
    "\t\t\tif not waitForSaving(waitSeconds) then\n"
    "\t\t\t\twarn(\"[DataService] Save dropped for \" .. player.Name\n"
    "\t\t\t\t\t.. \": another save stayed in flight through both waits\")\n"
    "\t\t\t\treturn false\n"
    "\t\t\tend\n"
    "\t\telse\n"
    "\t\t\twarn(\"[DataService] Save dropped for \" .. player.Name\n"
    "\t\t\t\t.. \": another save stayed in flight for \" .. tostring(waitSeconds) .. \"s\")\n"
    "\t\t\treturn false\n"
    "\t\tend\n",
    "\t\twarn(\"[DataService] Save dropped for \" .. player.Name\n"
    "\t\t\t.. \": another save stayed in flight for \" .. tostring(waitSeconds) .. \"s\")\n"
    "\t\treturn false\n",
    "R4-8 RetryOnce branch",
)
# --- R4-8: SaveAllForShutdown saves sequentially (no fan-out).
ds = replace_once(
    ds,
    "\t\t_shutdownStats.spawned += 1\n\t\ttask.spawn(function()",
    "\t\t-- MUTANT (R3): sequential saves, no spawned fan-out.\n\t\t(function()",
    "R4-8 fan-out spawn",
)
ds = replace_once(
    ds,
    "\t\t\t_shutdownStats.completed = done\n\t\t\t_shutdownStats.saved = saved\n\t\tend)\n\tend",
    "\t\t\t_shutdownStats.completed = done\n\t\t\t_shutdownStats.saved = saved\n\t\tend)()\n\tend",
    "R4-8 fan-out close",
)

write(raid_path, raid)
write(ds_path, ds)

# Sanity: every reverted behaviour must be gone from the mutants.
def must_absent(path, needle, what):
    text = read(path)
    if needle in text:
        fail("mutant %s still contains %s: %r" % (path, what, needle[:80]))

must_absent(raid_path, "invalidateStaleReturnEscrow(victim, victimUserId", "R4-1 call")
must_absent(raid_path, "parked = okCall and stored == true", "R4-2 park check")
must_absent(raid_path, "ReserveCoins(player, reserveKey, payable)", "R4-3 reserve")
must_absent(raid_path, "voidDurableB", "R4-4 void durability (b)")
must_absent(raid_path, "voidDurableD", "R4-4 void durability (d online)")
must_absent(raid_path, "voidDurableE", "R4-4 void durability (d offline)")
must_absent(raid_path, "voidPendingRewardsForInstance(player, instanceId)\n\t\t\t\t_inTransit", "R4-4 void call (b)")
must_absent(raid_path, "local _voidedD, voidDurableD", "R4-4 void call (d online)")
must_absent(raid_path, "local _voidedE, voidDurableE", "R4-4 void call (d offline)")
must_absent(ds_path, "retrying the wait once (leave path)", "R4-8 retry")
must_absent(ds_path, "_shutdownStats.spawned += 1", "R4-8 fan-out")
print("make_mutant OK: mutants built")
PYEOF
