#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run Emma 02 (etxmato) as a reference Studio II for the MiSTer core.
#
# Emma 02 is the definitive CDP1802 multi-system emulator and is the reference
# CLAUDE.md points at for *behaviour*.  We do not build it: refs/emma_02 ships
# a prebuilt macOS installer, and this script unpacks that installer into
# refs/emma_02/dist without touching /Applications or /usr/local.
#
# The shipped binary is Emma 02 v1.47, x86_64 -- it runs under Rosetta.  Two of
# its dylib references are unusable on this machine and get patched on first
# extract (see prepare_app below).
#
# Examples
#   tools/emma02.sh                      # BIOS only, built-in games
#   tools/emma02.sh --list               # list the .st2 corpus Emma ships
#   tools/emma02.sh --cart invaders.st2  # a cart from Emma's own data dir
#   tools/emma02.sh --cart "software/carts/TV School House I (USA).bin"
#   tools/emma02.sh --gui                # full launcher GUI instead of -c
#
# Emma 02 is interactive: it opens a "Studio II" window.  Useful keys once it
# is up -- 'g' starts/continues, F1..F4 open the debugger/trace windows.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/refs/emma_02/emma_02_x64_osx_10.10.pkg"
DIST="$ROOT/refs/emma_02/dist"
APP="$DIST/Emma 02.app"
RES="$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/Emma 02"
LIBS="$DIST/libs"
FW="$DIST/frameworks"

CART=""
GUI=0
TIMEOUT="${EMMA_TIMEOUT:-0}"      # 0 = run until the user quits

# --- unpack + patch, once -------------------------------------------------
prepare_app() {
    [[ -x "$BIN" ]] && return 0

    [[ -f "$PKG" ]] || { echo "error: $PKG missing" >&2; exit 1; }
    echo "== first run: unpacking Emma 02 into refs/emma_02/dist =="
    rm -rf "$DIST"; mkdir -p "$DIST/xar"
    ( cd "$DIST/xar" && xar -xf "$PKG" )

    # main app
    mkdir -p "$DIST/payload"
    ( cd "$DIST/payload" && cat "$DIST/xar/Emma_02_Main_Files.pkg/Payload" \
        | gzip -dc | cpio -i 2>/dev/null )
    mv "$DIST/payload/Applications/Emma 02.app" "$APP"

    # libserialport ships in its own sub-package; SDL2 as a framework
    mkdir -p "$LIBS" "$FW" "$DIST/dep"
    ( cd "$DIST/dep" && cat "$DIST/xar/libserialport.pkg/Payload" \
        | gzip -dc | cpio -i 2>/dev/null )
    cp "$DIST/dep/usr/local/lib/libserialport.0.dylib" "$LIBS/"
    ( cd "$DIST/dep" && cat "$DIST/xar/SDL2-2.05.pkg/Payload" \
        | gzip -dc | cpio -i 2>/dev/null )
    cp -R "$DIST/dep/Library/Frameworks/SDL2.framework" "$FW/" 2>/dev/null || true

    # Two load commands are unusable as shipped:
    #   libserialport -> hardcoded /usr/local/lib (we do not install there)
    #   libcurl       -> the *developer's* build tree, /Users/etxmato/...
    # Repoint both, then ad-hoc re-sign (install_name_tool breaks the sig).
    install_name_tool -change "/usr/local/lib/libserialport.0.dylib" \
        "$LIBS/libserialport.0.dylib" "$BIN" 2>/dev/null
    install_name_tool -change \
        "/Users/etxmato/workspace/curl-7.83.1/build-osx/artifacts/lib/libcurl.4.dylib" \
        "/usr/lib/libcurl.4.dylib" "$BIN" 2>/dev/null
    codesign -f -s - "$APP" >/dev/null 2>&1

    rm -rf "$DIST/xar" "$DIST/payload" "$DIST/dep"
    echo "   ok -> $APP"
}

# --- args -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cart)    CART="$2"; shift 2 ;;
        --gui)     GUI=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --list)    prepare_app; echo "Emma 02 bundled Studio II software:"
                   for f in "$RES/data/Studio2/"*.st2; do
                       [[ -e "$f" ]] && printf '   %s\n' "$(basename "$f")"
                   done
                   exit 0 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "error: unknown option $1" >&2; exit 1 ;;
    esac
done

prepare_app

# --- cartridge ------------------------------------------------------------
# Emma keeps the selected cart in its ini, not on the command line (the -st
# flag only exists in the v2.00 source, not in this 1.47 build).  So point
# [Studio2]/St2_File at the file and [Dir/Studio2]/St2_File at its directory.
CART_DIR=""; CART_FILE=""
if [[ -n "$CART" ]]; then
    if [[ -f "$CART" ]]; then
        CART_DIR="$(cd "$(dirname "$CART")" && pwd)/"
        CART_FILE="$(basename "$CART")"
    elif [[ -f "$ROOT/$CART" ]]; then
        CART_DIR="$(cd "$(dirname "$ROOT/$CART")" && pwd)/"
        CART_FILE="$(basename "$CART")"
    elif [[ -f "$RES/data/Studio2/$CART" ]]; then
        CART_DIR="$RES/data/Studio2/"
        CART_FILE="$CART"
    else
        echo "error: cartridge not found: $CART" >&2
        echo "       try: tools/emma02.sh --list" >&2
        exit 1
    fi
fi

cat > "$RES/emma_02.ini" <<EOF
DataDir=$RES/data/
[Studio2]
Main_Rom_File=studio2.rom
St2_File=$CART_FILE
Zoom=3.00
Clock_Speed=1.76
Volume=25
Lsb=0
Msb=0
MultiCart=0
DisableSystemRom=0
[Dir/Studio2]
Main_Rom_File=Studio2/
St2_File=${CART_DIR:-Studio2/}
EOF

# --- launch ---------------------------------------------------------------
export DYLD_FRAMEWORK_PATH="$FW"

ARGS=( -p -u -v )
[[ $GUI -eq 0 ]] && ARGS+=( -c Studio2 )      # -c skips the launcher GUI

echo "== Emma 02 reference run =="
echo "   cart : ${CART_FILE:-<none, built-in games>}"
echo "   mode : $([[ $GUI -eq 1 ]] && echo 'launcher GUI' || echo 'direct Studio II')"
echo

cd "$RES"
if [[ "$TIMEOUT" != "0" ]] && command -v timeout >/dev/null 2>&1; then
    exec timeout -s KILL "$TIMEOUT" "$BIN" "${ARGS[@]}"
else
    exec "$BIN" "${ARGS[@]}"
fi
