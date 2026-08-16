#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Directed test for the memory decode in rtl/rcastudioii.sv.
#
# None of the commercial or homebrew software in software/ or refs/ touches the
# RAM mirrors, so the frame comparison in §9 cannot tell a correct decode from
# the old truncate-to-12-bits one. This builds a tiny native-1802 cartridge that
# pokes every case and checks the result out of the simulated RAM.
#
#   tools/memdecode-test.sh
#
# Expected behaviour (docs/memorymap.txt, and MAME's studio2.cpp, which maps
# 512 bytes of RAM at 0x0000-0x01ff mirrored 0xfc00 and then installs ROM over
# $0000-$07ff only):
#
#   $0CF0 write  -> RAM $08F0        the documented $0C00-$0DFF mirror
#   $19F0 write  -> RAM $09F0        RAM answers wherever A9 = 0
#   $0DF0 read   -> RAM $09F0
#   $0A00 read   -> open bus         A9 = 1, no cartridge paged there
#   $0000 read   -> system ROM       still ROM, obviously
#   $1000 read   -> RAM $0800        ROM is NOT mirrored above $0FFF
#   $1200 read   -> open bus         A9 = 1
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL="$ROOT/verilator/obj_dir_headless/Vtop"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

[[ -x "$RTL" ]] || { echo "error: build the RTL sim: (cd verilator && make headless)" >&2; exit 1; }

# Hand-assembled, because it is 90 bytes and the point is to have no build step.
# The cartridge starts with the usual two-byte CHIP-8 "call machine code" word
# that every Studio II native program uses (see refs/studio2-games).
python3 - "$TMP/memtest.bin" <<'EOF'
import sys
LDI = lambda v: [0xF8, v]
def PHI(n): return [0xB0 | n]
def PLO(n): return [0xA0 | n]
def LDN(n): return [0x00 | n]
def STR(n): return [0x50 | n]
def INC(n): return [0x10 | n]
def ptr(n, hi, lo): return LDI(hi) + PHI(n) + LDI(lo) + PLO(n)

code  = [0x04, 0x02]                          # $0400: CHIP-8 "call machine code at $0402"
code += ptr(6, 0x08, 0xF1)                    # R6 = $08F1, where the read results go
code += ptr(7, 0x08, 0x00) + LDI(0x3C) + STR(7)   # seed RAM $0800 = $3C
code += ptr(7, 0x0C, 0xF0) + LDI(0xA5) + STR(7)   # write $A5 through the $0C00 mirror
code += ptr(7, 0x19, 0xF0) + LDI(0x5A) + STR(7)   # write $5A through the $1900 mirror
for hi, lo in ((0x0D, 0xF0), (0x0A, 0x00), (0x00, 0x00), (0x10, 0x00), (0x12, 0x00)):
    code += ptr(7, hi, lo) + LDN(7) + STR(6) + INC(6)
code += ptr(7, 0x08, 0xFF) + LDI(0xEE) + STR(7)   # "the program got this far" marker
here = 0x400 + len(code)
code += [0x30, here & 0xFF]                   # branch to self

assert len(code) <= 0x400, len(code)
open(sys.argv[1], 'wb').write(bytes(code) + bytes(0x400 - len(code)))
EOF

"$RTL" --bios "$ROOT/rom/studio2.rom" --cart "$TMP/memtest.bin" \
       --frames 30 --dump 29 --vram --dump-file "$TMP/dump.txt" --quiet >/dev/null 2>&1

byte() {  # $1 = address, e.g. 08F0
    local row=${1:0:3}0 col=$(( 16#${1:3:1} ))
    awk -v r="  ${row}: " -v c="$col" \
        'index($0,r)==1 { print toupper($(c+2)); exit }' "$TMP/dump.txt"
}

rom0=$(python3 -c "print('%02X' % open('$ROOT/rom/studio2.rom','rb').read(1)[0])")

fail=0
check() {  # $1=label $2=addr $3=expected
    local got; got=$(byte "$2")
    if [[ "$got" == "$3" ]]; then
        printf "  ok    %-34s \$%s = %s\n" "$1" "$2" "$got"
    else
        printf "  FAIL  %-34s \$%s = %s, expected %s\n" "$1" "$2" "${got:-??}" "$3"
        fail=1
    fi
}

echo "memory decode:"
check "program ran to completion"      08FF EE
check "write via \$0CF0 mirror"         08F0 A5
check "write via \$19F0 mirror"         09F0 5A
check "read via \$0DF0 mirror"          08F1 5A
check "read \$0A00 (A9=1, open bus)"    08F2 FF
check "read \$0000 (system ROM)"        08F3 "$rom0"
check "read \$1000 (RAM, not ROM)"      08F4 3C
check "read \$1200 (A9=1, open bus)"    08F5 FF

exit $fail
