#!/usr/bin/env bash
# Print the CRC16-CCITT of a cartridge, matching the one rtl/rcastudioii.sv
# computes during ioctl_download. Use it to add a cartridge to the joystick
# mapping table (the case statement on cart_crc).
#
#   tools/cart-crc.sh software/carts/*.bin
set -euo pipefail
for f in "$@"; do
  python3 - "$f" <<'PY'
import sys,os
b=open(sys.argv[1],'rb').read(); c=0xFFFF
for x in b:
    c ^= x<<8
    for _ in range(8):
        c = ((c<<1)^0x1021)&0xFFFF if c&0x8000 else (c<<1)&0xFFFF
print(f"16'h{c:04X}  // {os.path.basename(sys.argv[1])}  ({len(b)} bytes)")
PY
done
