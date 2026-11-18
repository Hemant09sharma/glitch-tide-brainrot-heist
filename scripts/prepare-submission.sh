#!/usr/bin/env bash
# prepare-submission.sh — one command that runs every package check and
# then main.ts, the way the grader runs it.
#
# Stages: package validator, screenshot validator, 50-check Python
# harness, 33-check Lune harness (refreshed first), then main.ts with
# MAKEFUN_OUTPUT_DIR=out. Each stage prints PASS/FAIL/PENDING; a
# summary is printed at the end and the script exits non-zero if any
# stage failed. Two stages are EXPECTED to be pending/blocked until the
# Studio work is done (no PLAY.json, no screenshots): main.ts then
# refuses to write a dossier and exits 1 — that is correct behaviour,
# not a broken script. Run from the package root:
#   bash scripts/prepare-submission.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

declare -A status
run_stage() {
    local name="$1"; shift
    echo "=== $name ==="
    if "$@"; then
        status["$name"]="PASS"
    else
        status["$name"]="FAIL"
    fi
    echo
}

run_stage "validate-package" python3 scripts/validate-package.py
run_stage "validate-screenshots" python3 scripts/validate-screenshots.py
run_stage "harness-python (50 checks)" python3 scripts/harness-python.py
run_stage "harness-lune refresh" bash scripts/harness-lune/refresh.sh
# Lune 0.11.1: prefer one on PATH, then ~/.local/bin, then a copy in
# /tmp; as a last resort download the official release asset
# (lune-0.11.1-linux-x86_64.zip, verified against the GitHub release
# listing 2026-11-19) into ${TMPDIR:-/tmp}/gt-lune-0.11.1. No hardcoded
# worker-specific /tmp paths: on a clean machine this still works.
LUNE="$(command -v lune || true)"
for candidate in "$HOME/.local/bin/lune" /tmp/lune-0.11.1/lune; do
    if [ -z "$LUNE" ] && [ -x "$candidate" ]; then LUNE="$candidate"; fi
done
if [ -z "$LUNE" ] && command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    LUNE_DIR="${TMPDIR:-/tmp}/gt-lune-0.11.1"
    if [ ! -x "$LUNE_DIR/lune" ]; then
        mkdir -p "$LUNE_DIR"
        curl -sSL -o "$LUNE_DIR/lune.zip" \
            "https://github.com/lune-org/lune/releases/download/v0.11.1/lune-0.11.1-linux-x86_64.zip" \
            && unzip -o -q "$LUNE_DIR/lune.zip" -d "$LUNE_DIR" || true
    fi
    [ -x "$LUNE_DIR/lune" ] && LUNE="$LUNE_DIR/lune"
fi
if [ -n "$LUNE" ]; then
    run_stage "harness-lune (33 checks)" "$LUNE" run scripts/harness-lune/main.luau
else
    echo "=== harness-lune (33 checks) ==="
    echo "SKIP: no lune 0.11.1 found (not on PATH, not in /tmp). Download"
    echo "it from github.com/lune-org/lune/releases/tag/v0.11.1 and re-run."
    status["harness-lune (33 checks)"]="FAIL"
    echo
fi
run_stage "main.ts" env MAKEFUN_OUTPUT_DIR=out node main.ts

echo "=== SUMMARY ==="
overall=0
for name in "validate-package" "validate-screenshots" "harness-python (50 checks)" \
            "harness-lune refresh" "harness-lune (33 checks)" "main.ts"; do
    printf '%-28s %s\n' "$name" "${status[$name]}"
    [ "${status[$name]}" = "PASS" ] || overall=1
done
if [ "$overall" -eq 0 ]; then
    echo "All stages passed. out/dossier.json is written."
else
    echo "Some stages did not pass. Until PLAY.json and 3-4 genuine"
    echo "screenshots exist, validate-screenshots and main.ts are"
    echo "EXPECTED to fail — that is the honest pending state, not a"
    echo "broken package. Any other FAIL above is a real defect: fix it"
    echo "and re-run this script."
fi
exit "$overall"
