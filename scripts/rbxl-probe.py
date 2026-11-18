#!/usr/bin/env python3
"""Verify a Rojo-built GlitchTide.rbxl against src/ (v1.1).

Stage 1 probe: parse the rbxl header/chunks (LZ4), list INST classes,
and dump the framing of the first Source PROP chunk so the full
verifier can decode ProtectedString values correctly.
"""
import struct
import sys

import lz4.block

RBXL = sys.argv[1] if len(sys.argv) > 1 else "/tmp/GlitchTide_v11_a.rbxl"

data = open(RBXL, "rb").read()
assert data[:8] == b"<roblox!", data[:8]
version, nclasses, ninstances = struct.unpack_from("<HII", data, 8)
print(f"header: version={version} classes={nclasses} instances={ninstances}")

off = 26
chunks = []
while off < len(data):
    ctype = data[off:off + 4].decode("latin1")
    clen, ulen = struct.unpack_from("<II", data, off + 4)
    raw = data[off + 12:off + 12 + clen]
    if clen == 0 and ulen == 0:
        chunks.append((ctype, b""))
        print(f"chunk {ctype} END")
        break
    if clen == ulen:
        payload = raw
    else:
        payload = lz4.block.decompress(raw, uncompressed_size=ulen)
    assert len(payload) == ulen, (ctype, len(payload), ulen)
    chunks.append((ctype, payload))
    print(f"chunk {ctype} compressed={clen} uncompressed={ulen}")
    off += 12 + clen

# Parse INST chunks
classes = []  # (name, is_service, [referents])
for ctype, payload in chunks:
    if ctype != "INST":
        continue
    p = 0
    (count,) = struct.unpack_from("<i", payload, p); p += 4
    for _ in range(count):
        (ln,) = struct.unpack_from("<I", payload, p); p += 4
        name = payload[p:p + ln].decode(); p += ln
        is_service = payload[p]; p += 1
        (icount,) = struct.unpack_from("<i", payload, p); p += 4
        refs = []
        prev = 0
        for i in range(icount):
            (v,) = struct.unpack_from("<i", payload, p); p += 4
            prev = v if i == 0 else prev + v
            refs.append(prev)
        classes.append((name, is_service, refs))
print(f"\n{len(classes)} classes:")
for i, (name, svc, refs) in enumerate(classes):
    print(f"  [{i}] {name} service={svc} instances={len(refs)}")

# Find a Source PROP chunk and dump its framing
for ctype, payload in chunks:
    if ctype != "PROP":
        continue
    p = 0
    (cid,) = struct.unpack_from("<i", payload, p); p += 4
    (ln,) = struct.unpack_from("<I", payload, p); p += 4
    pname = payload[p:p + ln].decode(); p += ln
    ptype = payload[p]; p += 1
    if pname == "Source":
        print(f"\nSource PROP: class_id={cid} class={classes[cid][0]} type=0x{ptype:02x} "
              f"instances={len(classes[cid][2])} payload_len={len(payload)} remaining={len(payload) - p}")
        print("first 64 bytes after header:", payload[p:p + 64].hex())
        # try: u32 length + bytes
        (ln2,) = struct.unpack_from("<I", payload, p)
        print(f"first u32 length = {ln2}; bytes after: {payload[p + 4:p + 4 + 40]!r}")
        break
