#!/usr/bin/env python3
"""GLITCH TIDE make.fun package validator (stdlib only, read-only).

Validates the make.fun COMPETITION PACKAGE tree
(glitch-tide-final-candidate/), NOT the development game tree. Run from
the competition package root:
    python3 scripts/validate-package.py
Exit 0 only if every check passes. The two EXPECTED failures of a
not-yet-submittable package (no PLAY.json, <3 screenshots) are reported
as PENDING, not PASS, so a green run never hides them.

Tree guard (added in the v1.1 release cleanup): if the make.fun package
markers (main.ts, vendor/makefun-roblox.ts) are absent at the tree root,
this script prints a clear message and exits 2 without running any
check, instead of failing misleadingly against a game tree. For the
development game tree use scripts/harness-python.py,
scripts/harness-lune/, and scripts/verify-rbxl.py instead.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
passes, fails, pending = [], [], []


def check(name, ok, detail=""):
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" -- {detail}" if detail else ""))


def note(name, detail=""):
    pending.append(name)
    print(f"PENDING  {name}" + (f" -- {detail}" if detail else ""))


def read(p):
    return (SRC / p).read_text(errors="replace")


# --- Tree guard (v1.1 cleanup) -------------------------------------------
# This validator is for the make.fun COMPETITION PACKAGE tree only. The
# markers below exist only there; a development game tree (this repo)
# has neither main.ts nor vendor/makefun-roblox.ts. Without this guard,
# running the validator here fails checks that can never pass in a game
# tree (48-file count, PLAY.json.template, vendor file) and produces a
# misleading FAIL report. Stop early with an explanation instead.
_MARKERS = (ROOT / "main.ts", ROOT / "vendor" / "makefun-roblox.ts")
if not all(m.exists() for m in _MARKERS):
    print("NOT A COMPETITION PACKAGE TREE — validator not run.")
    print("  This script validates the make.fun competition package in")
    print("  glitch-tide-final-candidate/ (it needs main.ts and")
    print("  vendor/makefun-roblox.ts at the tree root).")
    print(f"  You ran it in: {ROOT}")
    print("  For this development game tree use instead:")
    print("    python3 scripts/harness-python.py   (static checks)")
    print("    bash scripts/harness-lune/refresh.sh && "
          "lune run scripts/harness-lune/main.luau")
    print("    python3 scripts/verify-rbxl.py       (src-to-place matching)")
    sys.exit(2)


# 1. Package shape
luau = sorted(SRC.rglob("*.luau"))
check("src/ holds 48 Luau files", len(luau) == 48, f"found {len(luau)}")
check("no .md files under src/ (docs stay out of the Rojo tree)",
      not list(SRC.rglob("*.md")))
# One dot-name is allowed: src/map/.gitkeep keeps the empty Workspace
# dir tracked. It is safe because main.ts copies src/ with a
# notDotted filter, so it never reaches /output (verified by the
# fixture runs of main.ts). Anything else dot-named would fail.
dot_src = [str(p.relative_to(SRC)) for p in SRC.rglob("*")
           if p.name.startswith(".") and str(p.relative_to(SRC)) != "map/.gitkeep"]
dot_shots = [p.name for p in (ROOT / "screenshots").rglob("*") if p.name.startswith(".")]
check("no unexpected dot-names under src/ or screenshots/ (map/.gitkeep only)",
      not dot_src and not dot_shots, f"src: {dot_src} screenshots: {dot_shots}")
check("src/map exists (Workspace target of default.project.json)",
      (SRC / "map").is_dir())
shots = [p for p in (ROOT / "screenshots").glob("*") if p.is_file()]
non_images = [p.name for p in shots
              if p.suffix.lower() not in (".png", ".jpg", ".jpeg")]
check("screenshots/ holds image files only (a non-image file breaks buildDossier)",
      not non_images, f"non-image files: {non_images}" if non_images else "clean")

# 2. Rojo project
try:
    proj = json.loads((ROOT / "default.project.json").read_text())
    check("default.project.json valid JSON", True, f"name={proj.get('name')}")
    check("project.json uses $className (not $class)",
          "$className" in proj["tree"] and "$class" not in proj["tree"])
    check("StarterGui is a direct DataModel child -> src/client/ui (v1.0.2)",
          proj["tree"].get("StarterGui", {}).get("$path") == "src/client/ui")
    sps = proj["tree"]["StarterPlayer"]["StarterPlayerScripts"]
    check("StarterPlayerScripts is exactly Main + Controllers",
          set(sps) == {"Main", "Controllers"}
          and sps["Main"].get("$path") == "src/client/Main.client.luau"
          and sps["Controllers"].get("$path") == "src/client/Controllers")
    check("Workspace maps to src/map", proj["tree"]["Workspace"].get("$path") == "src/map")
except Exception as e:
    check("default.project.json readable", False, str(e))

# 3. game.rbxl
rbxl = ROOT / "game.rbxl"
check("game.rbxl exists", rbxl.exists())
if rbxl.exists():
    data = rbxl.read_bytes()
    check("game.rbxl is a binary Roblox place (<roblox! magic)",
          data[:8] == b"<roblox!")
    check("game.rbxl <= 32 MiB (gate cap)", len(data) <= 32 * 1024 * 1024,
          f"{len(data)} bytes")
    print(f"INFO  game.rbxl sha256: {hashlib.sha256(data).hexdigest()}")

# 4. Vendor file (kit hash from kit.json, roblox-brainrot-01-kit)
KIT_VENDOR_SHA = "0add43584f2037edee560834c3d04c05c092071eb0007856e8ff199eb5c6f550"
vf = ROOT / "vendor" / "makefun-roblox.ts"
check("vendor/makefun-roblox.ts exists", vf.exists())
if vf.exists():
    check("vendor/makefun-roblox.ts byte-identical to the kit",
          hashlib.sha256(vf.read_bytes()).hexdigest() == KIT_VENDOR_SHA,
          f"sha256={hashlib.sha256(vf.read_bytes()).hexdigest()[:16]}...")

# 5. Game content (same checks the v1.0.2 QA harness ran)
cfg = read("shared/Config.luau")
check("Config.GameVersion is 1.0.2", '"1.0.2"' in cfg)
chars_src = read("shared/Characters.luau")
roster = sorted(set(re.findall(r'(?<![A-Za-z])Id\s*=\s*"([a-z0-9_]+)"', chars_src)))
check("roster has 18 characters", len(roster) == 18, f"found {len(roster)}")
m = re.search(r'Config\.RarityWeights\s*=\s*\{(.*?)\n\}', cfg, re.S)
weights = dict(re.findall(r'(\w+)\s*=\s*([0-9.]+)', m.group(1))) if m else {}
check("RarityWeights sum to 1.0", abs(sum(map(float, weights.values())) - 1.0) < 1e-9,
      f"sum={sum(map(float, weights.values()))} over {len(weights)} tiers")
check("MaxBasePlots == MaxPlayers == 12",
      "Config.MaxBasePlots = 12" in cfg and "Config.MaxPlayers = 12" in cfg)
check("canonical keybinds Q/F/R/E/G in Config",
      all(s in cfg for s in ['"Q"', '"F"', '"R"', '"E"', '"G"']))
italian = ["Tung Tung", "Tralalero", "Bombardiro", "Chimpanzini", "Lirili", "Ballerina"]
found_italian = [n for n in italian if n.lower() in "".join(
    p.read_text(errors="replace") for p in luau).lower()]
check("no copyrighted Italian Brainrot names in src/", not found_italian,
      f"found: {found_italian}" if found_italian else "clean")
todo = [str(p) for p in luau if re.search(r'TODO|FIXME|STUB', p.read_text(errors="replace"))]
check("no TODO/FIXME/STUB markers in src/", not todo, f"found in: {todo}" if todo else "")

# 6. Entry-point files
check("main.ts exists at package root", (ROOT / "main.ts").exists())
main_ts = (ROOT / "main.ts").read_text(errors="replace")
check("main.ts copies screenshots image-by-image, never the whole dir",
      "cpSync(join(here, 'screenshots')" not in main_ts
      and "for (const shot of screenshots)" in main_ts,
      "whole-dir screenshots copy would let a non-image file break buildDossier")
check("LICENSE exists at package root", (ROOT / "LICENSE").exists())
check("README.md exists at package root", (ROOT / "README.md").exists())
readme = (ROOT / "README.md").read_text(errors="replace")
check("README carries the make.fun competition badge (RULES repo_readme)",
      "https://make.fun/badge/roblox-brainrot-01.svg" in readme)
check("harness files present (scripts/harness-python.py + harness-lune/)",
      (ROOT / "scripts" / "harness-python.py").exists()
      and (ROOT / "scripts" / "harness-lune" / "main.luau").exists()
      and (ROOT / "scripts" / "harness-lune" / "refresh.sh").exists())
check("capture guide lives in docs/ (screenshots/ holds images only)",
      (ROOT / "docs" / "SCREENSHOT_CAPTURE_GUIDE.md").exists()
      and not (ROOT / "screenshots" / "SCREENSHOT_CAPTURE_GUIDE.md").exists())

# 7. Honestly-pending inputs (PENDING, never PASS)
if (ROOT / "PLAY.json").exists():
    check("PLAY.json present with real ids (post-publish only)", False,
          "PLAY.json exists — verify its ids are real before submitting")
else:
    note("PLAY.json missing (expected until publishing)",
         "fill PLAY.json.template with real place_id/universe_id after publishing")
shots = [p for p in (ROOT / "screenshots").glob("*")
         if p.suffix.lower() in (".png", ".jpg", ".jpeg") and p.is_file()]
if 3 <= len(shots) <= 4:
    check("screenshots/ holds 3-4 images", True, f"found {len(shots)}")
else:
    note("screenshots/ holds 0-2 images (gate needs 3-4 real Studio captures)",
         f"found {len(shots)}")

print(f"\n{len(passes)} passed, {len(fails)} failed, {len(pending)} pending")
sys.exit(1 if fails else 0)
