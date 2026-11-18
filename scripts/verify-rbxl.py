#!/usr/bin/env python3
"""Verify a Rojo-built GlitchTide.rbxl against src/ (v1.1).

Checks:
  1. rbxl header + chunk structure parse cleanly (16-byte chunk headers:
     signature, compressed length, uncompressed length, reserved u32;
     chunk data is a raw LZ4 block, or stored raw when lengths are equal).
  2. Every Source value in the place matches exactly one src/*.luau file
     byte-for-byte, with no missing, extra, or duplicated sources
     (68/68 for v1.1).
  3. Script counts by class: 66 ModuleScript + 1 LocalScript + 1 Script.

The instance hierarchy (StarterGui as a direct DataModel child, MainMenu
exactly once, StarterPlayerScripts = Main + Controllers, empty
Workspace) is verified separately via `rojo serve` /show-instances,
because the rbxl INST referent encoding is not reimplemented here.
Run:  python3 scripts/verify-rbxl.py [path/to/GlitchTide.rbxl]
Exit 0 iff all checks pass.
"""
import hashlib
import pathlib
import struct
import sys

import lz4.block

RBXL = sys.argv[1] if len(sys.argv) > 1 else "GlitchTide.rbxl"
ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

failed = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" -- {detail}" if detail else ""))
    if not ok:
        failed.append(name)


data = open(RBXL, "rb").read()
check("rbxl magic header", data[:8] == b"<roblox!", data[:8])
version, nclasses, ninstances = struct.unpack_from("<HII", data, 14)
check("rbxl header counts sane", nclasses == 10 and ninstances == 76,
      f"classes={nclasses} instances={ninstances}")


def chunks():
    off = 32
    while off < len(data):
        ctype = data[off:off + 4].decode("latin1")
        clen, ulen, _extra = struct.unpack_from("<III", data, off + 4)
        raw = data[off + 16:off + 16 + clen]
        if ctype.startswith("END"):
            break
        payload = raw if clen == ulen else lz4.block.decompress(raw, uncompressed_size=ulen)
        yield ctype, payload
        off += 16 + clen


sources = []  # (classId, source bytes)
chunk_count = 0
for ctype, p in chunks():
    chunk_count += 1
    if ctype != "PROP":
        continue
    try:
        cid, = struct.unpack_from("<i", p, 0)
        ln, = struct.unpack_from("<I", p, 4)
        pname = p[8:8 + ln].decode()
    except Exception:
        continue
    if pname != "Source":
        continue
    q = 9 + ln
    while q < len(p):
        (sl,) = struct.unpack_from("<I", p, q)
        q += 4
        sources.append((cid, p[q:q + sl]))
        q += sl

check("rbxl chunk stream parses", chunk_count == 26, f"chunks={chunk_count}")
check("68 Source values in place", len(sources) == 68, f"found {len(sources)}")

src_files = {str(f.relative_to(SRC)): f.read_bytes() for f in sorted(SRC.rglob("*.luau"))}
src_hashes = {hashlib.sha256(c).hexdigest(): rel for rel, c in src_files.items()}
place_hashes = {hashlib.sha256(v).hexdigest() for _, v in sources}
missing = [rel for rel, c in src_files.items()
           if hashlib.sha256(c).hexdigest() not in place_hashes]
extra = [(cid, len(v)) for cid, v in sources
         if hashlib.sha256(v).hexdigest() not in src_hashes]
from collections import Counter
dups = [n for n in Counter(hashlib.sha256(v).hexdigest() for _, v in sources).values() if n > 1]
check("every src file present byte-identical in place", not missing, f"missing={missing}")
check("no place Source matches no src file", not extra, f"extra={extra}")
check("no duplicated Source values", not dups, f"dups={dups}")

by_class = Counter(cid for cid, _ in sources)
check("script counts by class (66 ModuleScript + 1 LocalScript + 1 Script)",
      by_class.get(0) == 66 and by_class.get(6) == 1 and by_class.get(2) == 1,
      f"by_class={dict(by_class)}")

print(f"\n{len(failed)} failed")
sys.exit(1 if failed else 0)
