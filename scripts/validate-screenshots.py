#!/usr/bin/env python3
"""Validate screenshots/ for the GLITCH TIDE make.fun entry.

Checks the official gate rules (RULES.txt, "screenshots" row):
  * 3 to 4 images in screenshots/
  * each a regular file named with letters, digits and . _ -
    (1 to 128 characters, not starting with . or -)
  * PNG or JPEG, whole/parseable
  * at most 256 KiB
  * long side at most 1280 px, short side at least 480 px
  * 16:9 aspect (RULES.txt prose, e.g. 1280x720) — WARNING only, not a
    FAIL: the gate's screenshots row does not list aspect, so a
    non-16:9 shot fails the prose but not the row; fix it anyway.
  * NO non-image file may sit in screenshots/: buildDossier counts
    every file there as a screenshot image and refuses one that is
    neither PNG nor JPEG, so even a documentation file breaks the
    submission. (The capture guide lives in docs/, not screenshots/.)
    Any non-image entry is a FAIL, whatever its name.

Stdlib only: PNG dimensions are read from the IHDR chunk and JPEG
dimensions from the SOF marker, by hand. No Pillow needed.

Usage: python3 scripts/validate-screenshots.py
Run from the package root (the directory containing screenshots/).
Exits 0 on overall PASS, 1 on FAIL.
"""

import os
import re
import struct
import sys

MAX_BYTES = 256 * 1024          # 256 KiB
MAX_LONG_SIDE = 1280
MIN_SHORT_SIDE = 480
MIN_COUNT = 3
MAX_COUNT = 4
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def png_dimensions(path):
    """Return (width, height) for a PNG, or None if not a whole PNG."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 8 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    # Walk chunks; IHDR must be first and holds width/height.
    off = 8
    while off + 8 <= len(data):
        (length,) = struct.unpack(">I", data[off:off + 4])
        ctype = data[off + 4:off + 8]
        if ctype == b"IHDR":
            if length < 8 or off + 8 + length + 4 > len(data):
                return None
            width, height = struct.unpack(">II", data[off + 8:off + 16])
            return (width, height)
        if ctype == b"IEND":
            return None
        # length + type(4) + data + crc(4); guard against corrupt lengths
        if length > len(data):
            return None
        off += 8 + length + 4
    return None


def jpeg_dimensions(path):
    """Return (width, height) for a JPEG, or None if not a whole JPEG."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 2 or data[:2] != b"\xff\xd8":
        return None
    # Must end with EOI for a "whole" file.
    if len(data) < 2 or data[-2:] != b"\xff\xd9":
        return None
    off = 2
    while off + 4 <= len(data):
        if data[off] != 0xFF:
            return None
        marker = data[off + 1]
        # Standalone markers with no length field.
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7 or marker == 0x01:
            off += 2
            continue
        if off + 4 > len(data):
            return None
        (length,) = struct.unpack(">H", data[off + 2:off + 4])
        if length < 2 or off + 2 + length > len(data):
            return None
        # SOF0/1/2 (baseline/extended/progressive); skip DHT/JPGn etc.
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            if length < 7:
                return None
            height, width = struct.unpack(
                ">HH", data[off + 5:off + 9])
            return (width, height)
        off += 2 + length
    return None


def image_dimensions(path):
    """Return (format, width, height) or (None, None, None)."""
    dims = png_dimensions(path)
    if dims is not None:
        return ("PNG", dims[0], dims[1])
    dims = jpeg_dimensions(path)
    if dims is not None:
        return ("JPEG", dims[0], dims[1])
    return (None, None, None)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    shot_dir = os.path.join(root, "screenshots")
    failures = []

    if not os.path.isdir(shot_dir):
        print("FAIL: screenshots/ directory does not exist")
        print("OVERALL: FAIL")
        return 1

    entries = sorted(os.listdir(shot_dir))
    # Every entry counts: buildDossier treats every non-dot file under
    # screenshots/ as a screenshot image, so a non-image file fails
    # below (it is neither a whole PNG nor a whole JPEG). There is no
    # exemption any more — the capture guide lives in docs/.
    files = entries

    print(f"screenshots/: {len(files)} file(s)")

    if len(files) < MIN_COUNT:
        print(f"FAIL: count {len(files)} < {MIN_COUNT} "
              f"(need {MIN_COUNT}-{MAX_COUNT} screenshots)")
        failures.append("count")
    elif len(files) > MAX_COUNT:
        print(f"FAIL: count {len(files)} > {MAX_COUNT} "
              f"(need {MIN_COUNT}-{MAX_COUNT} screenshots)")
        failures.append("count")
    else:
        print(f"PASS: count {len(files)} within {MIN_COUNT}-{MAX_COUNT}")

    for name in files:
        path = os.path.join(shot_dir, name)
        problems = []
        if not os.path.isfile(path):
            print(f"FAIL: {name}: not a regular file")
            failures.append(name)
            continue
        if not NAME_RE.match(name) or name.startswith((".", "-")):
            problems.append(
                "bad filename (1-128 chars of letters/digits/._-, "
                "not starting with . or -)")
        size = os.path.getsize(path)
        if size > MAX_BYTES:
            problems.append(
                f"size {size} bytes > {MAX_BYTES} bytes (256 KiB)")
        fmt, width, height = image_dimensions(path)
        if fmt is None:
            problems.append("not a whole/parseable PNG or JPEG "
                            "(any non-image file in screenshots/ breaks "
                            "buildDossier — move it to docs/)")
        else:
            long_side = max(width, height)
            short_side = min(width, height)
            if long_side > MAX_LONG_SIDE:
                problems.append(
                    f"long side {long_side}px > {MAX_LONG_SIDE}px")
            if short_side < MIN_SHORT_SIDE:
                problems.append(
                    f"short side {short_side}px < {MIN_SHORT_SIDE}px")
            # 16:9 is RULES prose, not a gate-row rule: warn, do not fail.
            if width * 9 != height * 16:
                print(f"WARNING: {name}: {width}x{height} is not 16:9 "
                      f"(RULES.txt wants 16:9, e.g. 1280x720)")
        if problems:
            print(f"FAIL: {name}: " + "; ".join(problems))
            failures.append(name)
        else:
            print(f"PASS: {name}: {fmt} {width}x{height}, "
                  f"{size} bytes (<= 256 KiB)")

    if failures:
        print("OVERALL: FAIL")
        return 1
    print("OVERALL: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
