#!/usr/bin/env bash
# Build the R2-5 mutant control: a copy of the CURRENT fixed
# RaidService with the lifecycle fix removed, used as a negative
# control. The mutant must FAIL its control test — that failure is the
# expected result and proves the test detects the missing fix.
#
#   RaidServiceLifecycle.luau: the OLD behaviour restored:
#     * no StolenFromUserId / Stolen* fields stamped at steal time
#       (no durable owner identity);
#     * no pre-save hook registration — a direct PlayerRemoving
#       connection instead (DataService saves before the return);
#     * RecoverStaleTransit gutted (rejoin resolves nothing);
#     * ReturnStolen victim-offline branch restored to DESTROY the
#       record (the old victim-left behaviour);
#     * no pending-reward sidecar write in recordPendingReward.
#
# The script fails unless every anchor is present exactly once in the
# source and the resulting diff touches ONLY the reverted lines, so a
# mutant can never silently drift from the current service.
# Usage (from the package root):
#   bash scripts/phase1-tests/lifecycle/mutant/make_mutant.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SRC="$ROOT/scripts/phase1-tests/lifecycle/services/RaidService.luau"
DEST="$ROOT/scripts/phase1-tests/lifecycle/mutant"
mkdir -p "$DEST"

python3 - "$SRC" "$DEST" <<'PYEOF'
import sys
src_path, dest_dir = sys.argv[1], sys.argv[2]
src = open(src_path).read()
mut = src

# --- (a) No durable owner identity at steal time ---
stamp_fixed = (
    "\tmovedRecord.StolenFromUserId = victim.UserId\n"
    "\tmovedRecord.StolenSlot = tonumber(placed.Slot) or 0\n"
    "\tmovedRecord.StolenPlacedAt = tonumber(placed.PlacedAt) or os.time()\n"
    "\tmovedRecord.StolenBankedIncome = tonumber(placed.BankedIncome) or 0\n"
)
assert mut.count(stamp_fixed) == 1, "stamping block not found exactly once"
mut = mut.replace(stamp_fixed, "\t-- MUTANT (R2-5 control): no durable theft identity stamped.\n")

# --- (b) RecoverStaleTransit gutted ---
start_marker = "function RaidService.RecoverStaleTransit(player: Player): (number, number)"
end_marker = "\n-- RecoverOnRejoin(player):"
start = mut.index(start_marker)
end = mut.index(end_marker)
body = mut[start:end]
assert "StolenFromUserId" in body, "stale-transit body does not reference the owner id"
stub = (
    start_marker + "\n"
    "\t-- MUTANT (R2-5 control): rejoin reconciliation removed.\n"
    "\treturn 0, 0\n"
    "end\n"
)
mut = mut[:start] + stub + mut[end:]

# --- (c) No pre-save hook: direct PlayerRemoving connection ---
hook_fixed = """	local hooked = false
	if _dataService and type(_dataService.RegisterPreSaveHook) == "function" then
		local okHook = pcall(function()
			hooked = _dataService.RegisterPreSaveHook(RaidService.HandlePlayerLeaving) == true
		end)
		hooked = okHook and hooked
	end
	if not hooked then
		warn("[RaidService] No DataService pre-save hook; using direct PlayerRemoving fallback (save ordering uncoordinated)")
		Players.PlayerRemoving:Connect(function(player)
			RaidService.HandlePlayerLeaving(player)
		end)
	end"""
assert mut.count(hook_fixed) == 1, "hook-registration block not found exactly once"
hook_mutant = """	-- MUTANT (R2-5 control): direct PlayerRemoving connection —
	-- the old uncoordinated ordering (DataService saves first).
	Players.PlayerRemoving:Connect(function(player)
		_channels[player] = nil
		_rate[player] = nil
		RaidService.DropStolen(player)
	end)"""
mut = mut.replace(hook_fixed, hook_mutant)

# --- (d) Victim-offline destroy restored in ReturnStolen ---
escrow_fixed = """		if not victimOnline then
			-- R2-5: the victim is offline. NEVER move the record into
			-- the victim's (unreachable / reload-only) cache — that
			-- write would never persist — and NEVER destroy it (the
			-- old victim-left behaviour deleted the victim's Brainrot
			-- outright). Escrow it durably for the victim's rejoin;
			-- when no escrow exists (older DataService / write
			-- failure) keep the transit entry AND the InTransit flag
			-- so a later rejoin can still retry the return.
			if tryEscrowReturn(thief, victim.UserId, instanceId, owned, record) then
				return true
			end
			warn("[RaidService] ReturnStolen: victim offline and escrow unavailable for "
				.. tostring(instanceId) .. "; transit kept for retry")
			return false
		end"""
assert mut.count(escrow_fixed) == 1, "escrow block not found exactly once"
destroy_mutant = """		if not victimOnline then
			-- MUTANT (R2-5 control): old victim-left behaviour —
			-- the record is DESTROYED instead of escrowed.
			destroyOwnedRecord(thief, instanceId)
			_inTransit[instanceId] = nil
			if thief and thief.Character then
				thief.Character:SetAttribute("CarryingStolen", "")
			end
			warn("[RaidService] Victim left mid-theft; stolen instance "
				.. tostring(instanceId) .. " destroyed instead of kept by the thief")
			return true
		end"""
mut = mut.replace(escrow_fixed, destroy_mutant)

# --- (e) No pending-reward sidecar write ---
# R5-8 re-anchor: R4-2 changed the park from the R3 unconditional
# pcall to a result-capturing pcall (okCall/stored -> `parked`, with
# a warn when the park fails). The mutant removes the park
# entirely, restoring the old unsafe behaviour: a reward recorded
# while the session cannot persist dies with the cache. The
# replacement keeps `local parked = false` so the ParkedTxns
# bookkeeping below still resolves (the id lands unparked, exactly
# as a failed park would); only the sidecar write itself is gone.
sidecar_fixed = """\tlocal parked = false
\tif _dataService and type(_dataService.RecordPendingRewardSidecar) == "function" then
\t\tlocal deltaEntry = {
\t\t\tTxId = id,
\t\t\tInstanceId = instanceId,
\t\t\tCharacterId = characterId,
\t\t\tAmount = delta,
\t\t\tReason = reason,
\t\t\tCreatedAt = os.time(),
\t\t}
\t\tlocal okCall, stored = pcall(function()
\t\t\treturn _dataService.RecordPendingRewardSidecar(player, deltaEntry)
\t\tend)
\t\tparked = okCall and stored == true
\t\tif not parked then
\t\t\twarn("[RaidService] Pending-reward sidecar park FAILED for " .. player.Name
\t\t\t\t.. " (" .. tostring(instanceId) .. ", TxId " .. tostring(id)
\t\t\t\t.. "); the reward stays pending in cache and the park will be retried on recovery")
\t\tend
\tend"""
assert mut.count(sidecar_fixed) == 1, "sidecar block not found exactly once"
mut = mut.replace(sidecar_fixed, "\tlocal parked = false -- MUTANT (R2-5 control): no pending-reward sidecar write.")

open(dest_dir + "/RaidServiceLifecycle.luau", "w").write(mut)
print("mutant written: RaidServiceLifecycle.luau (old lifecycle behaviour)")
PYEOF

# Prove the mutant differs from the fixed service ONLY in its reverted lines.
if ! diff "$SRC" "$DEST/RaidServiceLifecycle.luau" > "/tmp/phase1-lifecycle-mutant-diff.txt"; then
	echo "--- mutant diff vs fixed service: RaidServiceLifecycle.luau ---"
	cat "/tmp/phase1-lifecycle-mutant-diff.txt"
fi
# Guards: the mutant must no longer contain the fixed code.
if grep -q "movedRecord.StolenFromUserId" "$DEST/RaidServiceLifecycle.luau"; then
	echo "make_mutant FAILED: mutant still stamps StolenFromUserId"
	exit 1
fi
if grep -q "RegisterPreSaveHook(RaidService.HandlePlayerLeaving)" "$DEST/RaidServiceLifecycle.luau"; then
	echo "make_mutant FAILED: mutant still registers the pre-save hook"
	exit 1
fi
if grep -q "tryEscrowReturn(thief, victim.UserId" "$DEST/RaidServiceLifecycle.luau"; then
	echo "make_mutant FAILED: mutant still escrows offline-victim returns"
	exit 1
fi
if grep -q "RecordPendingRewardSidecar(player, deltaEntry)" "$DEST/RaidServiceLifecycle.luau"; then
	echo "make_mutant FAILED: mutant still writes the pending-reward sidecar"
	exit 1
fi
echo "make_mutant OK"
