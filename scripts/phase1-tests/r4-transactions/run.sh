#!/usr/bin/env bash
# Run every R4-transactions test (refreshes the module copies first).
# Each test file loads the REAL DataService / RaidService (+ the real
# coin-spending services where the test needs them) with a stubbed
# DataStore API. (The R4 mutant controls live in mutant/ and are NOT
# run here — see mutant/run_mutant.sh; they are expected to FAIL
# their assertions by design, i.e. the old behaviour must produce
# the bad outcome the test detects.)
# Usage (from the package root):
#   bash scripts/phase1-tests/r4-transactions/run.sh
# Exit 0 iff every test file passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-/tmp/lune-0.11.1/lune}"
# Refresh every suite whose copies these tests load.
bash "$ROOT/scripts/phase1-tests/theft/refresh.sh"
bash "$ROOT/scripts/phase1-tests/persistence/refresh.sh"
bash "$ROOT/scripts/phase1-tests/store/refresh.sh"
bash "$ROOT/scripts/phase1-tests/r4-transactions/refresh.sh"
fail=0
passed_files=0
total_files=0
for f in "$ROOT"/scripts/phase1-tests/r4-transactions/[0-9][0-9]_*.luau; do
	total_files=$((total_files + 1))
	echo "=== $(basename "$f") ==="
	if "$LUNE" run "$f"; then
		echo "--- PASS $(basename "$f")"
		passed_files=$((passed_files + 1))
	else
		echo "--- FAIL $(basename "$f")"
		fail=1
	fi
done
echo "run: $passed_files/$total_files r4-transactions test files passed"

# Static anchors the Lune tests cannot check (client code + wiring):
# the SaveWarning remote exists and HUDController handles it; the
# legacy recovery has no remote wiring a client could invoke; no
# direct-assignment coin debit remains anywhere (FusionService was
# the last route; fixed in the R4-3 follow-up).
anchor_fail=0
if ! grep -qF 'SaveWarning = "SaveWarning"' "$ROOT/src/shared/Remotes.luau"; then
	echo "ANCHOR MISSING: SaveWarning remote name in Remotes.luau"
	anchor_fail=1
fi
if ! grep -qF 'FindFirstChild("SaveWarning")' "$ROOT/src/client/Controllers/HUDController.luau"; then
	echo "ANCHOR MISSING: HUDController SaveWarning listener"
	anchor_fail=1
fi
if ! grep -qF 'function HUDController.ShowSaveWarning' "$ROOT/src/client/Controllers/HUDController.luau"; then
	echo "ANCHOR MISSING: HUDController.ShowSaveWarning"
	anchor_fail=1
fi
if grep -qF 'RecoverLegacyRecord' "$ROOT/src/shared/Remotes.luau"; then
	echo "ANCHOR VIOLATION: RecoverLegacyRecord has a remote name (clients must not invoke it)"
	anchor_fail=1
fi
if grep -rn 'RecoverLegacyRecord' "$ROOT/src/server/Services/" | grep -q 'OnServerEvent'; then
	echo "ANCHOR VIOLATION: RecoverLegacyRecord is wired to a remote event"
	anchor_fail=1
fi
# Direct-assignment coin debits (data.Coins = ... - cost) must not
# survive anywhere; refund paths ADD coins back, so they are not
# debits and are not matched by the pattern below.
for f in "$ROOT"/src/server/Services/BaseService.luau \
	"$ROOT"/src/server/Services/ConveyorService.luau \
	"$ROOT"/src/server/Services/EconomyService.luau \
	"$ROOT"/src/server/Services/FusionService.luau \
	"$ROOT"/src/server/Services/LaboratoryService.luau \
	"$ROOT"/src/server/Services/AbilityService.luau \
	"$ROOT"/src/server/Services/RaidService.luau; do
	if grep -n 'data\.Coins = .* - ' "$f" | grep -v 'AddCoins' | grep -q .; then
		echo "ANCHOR VIOLATION: direct-assignment coin debit remains in $f"
		grep -n 'data\.Coins = .* - ' "$f" | grep -v 'AddCoins'
		anchor_fail=1
	fi
done
# Every coin-spending route must judge affordability on spendable
# coins (R4-3). The Conveyor buy's affordability check is only
# statically verifiable under Lune (its position check can never
# pass: Lune's typeof() returns "table" for the harness's mock
# Instances, so itemPos is always nil — see test 10's header note);
# the other routes are proven live in test 10 as well.
for f in "$ROOT"/src/server/Services/BaseService.luau \
	"$ROOT"/src/server/Services/ConveyorService.luau \
	"$ROOT"/src/server/Services/EconomyService.luau \
	"$ROOT"/src/server/Services/FusionService.luau \
	"$ROOT"/src/server/Services/LaboratoryService.luau \
	"$ROOT"/src/server/Services/AbilityService.luau \
	"$ROOT"/src/server/Services/RaidService.luau; do
	if ! grep -q 'GetSpendableCoins' "$f"; then
		echo "ANCHOR MISSING: GetSpendableCoins not used in $f"
		anchor_fail=1
	fi
done
# PlayerRemoving must use the wait-and-retry leave save (R4-8 H).
if ! grep -qF 'SaveData(player, { WaitSeconds = 10, RetryOnce = true })' "$ROOT/src/server/Services/DataService.luau"; then
	echo "ANCHOR MISSING: PlayerRemoving leave save (WaitSeconds=10, RetryOnce=true) in DataService.luau"
	anchor_fail=1
fi
# GameManager must fire the SaveWarning to the client on join (R4-8 J).
if ! grep -qF 'fireClient(Remotes.Names.SaveWarning, player, warning)' "$ROOT/src/server/Services/GameManager.luau"; then
	echo "ANCHOR MISSING: GameManager SaveWarning fire on join"
	anchor_fail=1
fi
if [ "$anchor_fail" -ne 0 ]; then
	echo "run: STATIC ANCHORS FAILED"
	exit 1
fi
echo "run: static anchors OK"

if [ "$fail" -ne 0 ]; then
	echo "run: SOME R4-TRANSACTIONS TESTS FAILED"
	exit 1
fi
echo "run: ALL R4-TRANSACTIONS TESTS PASSED"
