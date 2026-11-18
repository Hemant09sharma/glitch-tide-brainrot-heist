#!/usr/bin/env bash
# Refresh the Lune harness's copies of the shared modules.
#
# Copies src/shared/*.luau into scripts/harness-lune/shared/ and applies
# the harness-only require patch (require(script.Parent.X) ->
# require("./X")); the project files are never touched. Run before
# `lune run scripts/harness-lune/main.luau` (and re-run after any
# src/shared/ change — a stale copy fails loudly: main.luau asserts
# GameVersion 1.0.2, so a version drift is caught, not hidden).
#
# Usage (from the package root):
#   bash scripts/harness-lune/refresh.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/src/shared"
DEST="$ROOT/scripts/harness-lune/shared"
mkdir -p "$DEST"
rm -f "$DEST"/*.luau
count=0
for f in "$SRC"/*.luau; do
    base="$(basename "$f")"
    # Harness-only patch: Lune has no `script.Parent`; relative require.
    sed -E 's/require\(script\.Parent\.([A-Za-z_]+)\)/require(".\/\1")/g' "$f" > "$DEST/$base"
    count=$((count + 1))
done
echo "refreshed $count shared modules into scripts/harness-lune/shared/ (harness-only require patch applied)"
echo "source hashes (verify against src/shared/ after any game change):"
(cd "$SRC" && sha256sum *.luau | sort) | sed 's/^/  src: /'
(cd "$DEST" && sha256sum *.luau | sort) | sed 's/^/  harness: /'
