#!/usr/bin/env bash
# Build tools/mame-roms/studio2.zip from rom/studio2.rom.
#
# MAME's studio2 driver wants the BIOS as the four original 512-byte mask ROMs.
# Our rom/studio2.rom is the straight concatenation of them, so we just split
# it and verify each part against MAME's expected CRC32 before zipping.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/rom/studio2.rom"
OUT="$ROOT/tools/mame-roms"

[[ -f "$SRC" ]] || { echo "error: $SRC not found" >&2; exit 1; }
mkdir -p "$OUT"

python3 - "$SRC" "$OUT" <<'PY'
import sys, zlib, os, zipfile
src, out = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
if len(data) != 0x800:
    sys.exit(f"error: expected a 2048 byte BIOS, got {len(data)}")

parts = [("84932.ic11", 0x000, 0x283b7e65),
         ("84933.ic12", 0x200, 0xa396b77c),
         ("85456.ic13", 0x400, 0xd25cf97f),
         ("85457.ic14", 0x600, 0x74aa724f)]

bad = False
blobs = {}
for name, off, want in parts:
    blob = data[off:off + 0x200]
    crc = zlib.crc32(blob) & 0xffffffff
    ok = crc == want
    bad |= not ok
    blobs[name] = blob
    print(f"  {name}  crc {crc:08x}  expected {want:08x}  {'ok' if ok else 'MISMATCH'}")

if bad:
    sys.exit("error: BIOS does not match MAME's studio2 ROM set")

path = os.path.join(out, "studio2.zip")
with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
    for name, _, _ in parts:
        z.writestr(name, blobs[name])
print(f"wrote {path}")
PY
