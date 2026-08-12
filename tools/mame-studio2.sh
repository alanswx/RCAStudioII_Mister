#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run the RCA Studio II in MAME as a golden reference for the MiSTer core.
#
# MAME itself is NOT vendored here -- we reuse the checkout/binary that already
# lives outside this repo. Override with MAME_BIN if yours is elsewhere.
#
# Examples
#   tools/mame-studio2.sh --frames 300 --shot 60,120,299
#   tools/mame-studio2.sh --cart "software/carts/TV Arcade I - Space War (USA).bin" \
#                         --frames 400 --shot-every 100 --dump 399 --vram
#   tools/mame-studio2.sh --press a1@90 --frames 200 --shot 199
#
# Output lands in tools/mame-work/snap/studio2/*.png and tools/mame-work/dump.txt
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAME_BIN="${MAME_BIN:-/Users/alans/Documents/development/lbmactwo_MiSTer/mame0283-arm64/mame}"
WORK="$ROOT/tools/mame-work"
ROMS="$ROOT/tools/mame-roms"

if [[ ! -x "$MAME_BIN" ]]; then
    echo "error: MAME binary not found at $MAME_BIN" >&2
    echo "       set MAME_BIN=/path/to/mame" >&2
    exit 1
fi
if [[ ! -f "$ROMS/studio2.zip" ]]; then
    echo "error: $ROMS/studio2.zip missing -- run tools/make-mame-roms.sh" >&2
    exit 1
fi

CART=""
export S2_FRAMES=300 S2_SHOTS="" S2_SHOT_EVERY=0
export S2_DUMPS="" S2_DUMP_EVERY=0 S2_DUMP_FILE="$WORK/dump.txt"
export S2_VRAM=0 S2_PRESS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cart)       CART="$2"; shift 2 ;;
        --frames)     S2_FRAMES="$2"; shift 2 ;;
        --shot)       S2_SHOTS="$2"; shift 2 ;;
        --shot-every) S2_SHOT_EVERY="$2"; shift 2 ;;
        --dump)       S2_DUMPS="$2"; shift 2 ;;
        --dump-every) S2_DUMP_EVERY="$2"; shift 2 ;;
        --dump-file)  S2_DUMP_FILE="$2"; shift 2 ;;
        --vram)       S2_VRAM=1; shift ;;
        --press)      S2_PRESS="${S2_PRESS:+$S2_PRESS,}$2"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "error: unknown option $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$WORK/snap" "$WORK/cfg" "$WORK/nvram"
rm -rf "$WORK/snap/studio2"

ARGS=( -rompath "$ROMS"
       -homepath "$WORK"
       -snapshot_directory "$WORK/snap"
       -cfg_directory "$WORK/cfg"
       -nvram_directory "$WORK/nvram"
       -inipath "$WORK"
       -pluginspath "$WORK"
       studio2
       -video none -sound none -nothrottle -skip_gameinfo
       -autoboot_script "$ROOT/tools/studio2_probe.lua" )

if [[ -n "$CART" ]]; then
    [[ -f "$CART" ]] || { echo "error: cartridge not found: $CART" >&2; exit 1; }
    ARGS+=( -cart "$CART" )
fi

echo "== MAME reference run =="
echo "   cart   : ${CART:-<built-in games>}"
echo "   frames : $S2_FRAMES   shots: ${S2_SHOTS:-none}/every ${S2_SHOT_EVERY}"
echo "   dumps  : ${S2_DUMPS:-none}/every ${S2_DUMP_EVERY} -> $S2_DUMP_FILE"
echo

"$MAME_BIN" "${ARGS[@]}"

echo
echo "snapshots:"
ls -1 "$WORK/snap/studio2" 2>/dev/null | sed 's/^/   /' || echo "   (none)"
[[ -s "$S2_DUMP_FILE" ]] && echo "state dump: $S2_DUMP_FILE"
