#!/usr/bin/env bash
# Phase 1 quest tests (P0-1, P0-2, duplicate claims). Self-contained;
# no dependency on scripts/phase1-tests/harness.luau.
# Usage (from the package root):  bash scripts/phase1-tests/quest/run.sh
# Requires: lune 0.11.1 on PATH (or set LUNE=/path/to/lune).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LUNE="${LUNE:-lune}"
cd "$ROOT"
"$LUNE" run scripts/phase1-tests/quest/main.luau
