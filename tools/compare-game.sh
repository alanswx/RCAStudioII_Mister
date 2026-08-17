#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive the RTL sim and the reference C emulator with an identical input
# sequence and diff every captured frame.
#
#   tools/compare-game.sh <cart|-> <frames> <shots> [--press K@F[:H] ...]
#
#   <cart>    path to a .bin, or "-" for the BIOS built-in games
#   <frames>  how long to run
#   <shots>   comma separated frame numbers to compare
#
# Example
#   tools/compare-game.sh "software/carts/Pinball (Europe).bin" 400 120,200,300,400 \
#       --press a1@40:20 --press a2@150:10 --press a5@250:10
#
# The reference renders 32 logical rows; the RTL renders 128 scanlines, so each
# reference row is expanded 4x before diffing.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The reference emulator is vendored at tools/refemu (MIT, see its README). The
# old location under the git-ignored refs/ is still accepted so an existing
# checkout keeps working, but tools/refemu is the copy that ships with the repo.
REF="$ROOT/tools/refemu/studio2_headless"
[[ -x "$REF" ]] || REF="$ROOT/refs/rca-studio2/studio2-games/studio2/studio2_headless"
RTL="$ROOT/verilator/obj_dir_headless/Vtop"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

[[ -x "$REF" ]] || { echo "error: build the reference: (cd tools/refemu && make headless)" >&2; exit 1; }
[[ -x "$RTL" ]] || { echo "error: build the RTL sim: (cd verilator && make headless)" >&2; exit 1; }

CART="$1"; FRAMES="$2"; SHOTS="$3"; shift 3
PRESS=( "$@" )

cart_ref=(); cart_rtl=()
if [[ "$CART" != "-" ]]; then
    [[ -f "$ROOT/$CART" ]] && CART="$ROOT/$CART"
    [[ -f "$CART" ]] || { echo "error: cart not found: $CART" >&2; exit 1; }
    cart_ref=( "$CART" ); cart_rtl=( --cart "$CART" )
fi

shot_args=(); IFS=',' read -ra SL <<< "$SHOTS"
for f in "${SL[@]}"; do shot_args+=( --shot "$f" ); done

echo "cart   : $([[ "$CART" == "-" ]] && echo '<built-in games>' || basename "$CART")"
echo "input  : ${PRESS[*]:-<none>}"
echo "frames : $FRAMES   compared at: $SHOTS"
echo

# Each emulator prints its captured frames in shot order; split them into per-shot files.
# ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": macOS ships bash 3.2, where an
# empty array expansion under `set -u` is an unbound-variable error, which is
# exactly the "-" (no cartridge, built-in games) case.
"$REF" --frames "$FRAMES" ${PRESS[@]+"${PRESS[@]}"} "${shot_args[@]}" --ascii --quiet --outdir "$TMP" ${cart_ref[@]+"${cart_ref[@]}"} 2>/dev/null \
  | grep -E "^  [.#]+$" | sed 's/^  //' | tr '.' ' ' | awk '{for(i=0;i<4;i++) print}' > "$TMP/ref.txt"
# the RTL sim defaults to ../rom/studio2.rom, which is relative to verilator/
"$RTL" --bios "$ROOT/rom/studio2.rom" --frames "$FRAMES" ${PRESS[@]+"${PRESS[@]}"} "${shot_args[@]}" --ascii --outdir "$TMP" --prefix r ${cart_rtl[@]+"${cart_rtl[@]}"} 2>/dev/null \
  | grep -E "^ *[0-9]+ \|" | sed 's/^ *[0-9]* |//; s/|$//' > "$TMP/rtl.txt"

nref=$(wc -l < "$TMP/ref.txt"); nrtl=$(wc -l < "$TMP/rtl.txt")
nshots=${#SL[@]}
if [[ $nref -ne $((128*nshots)) || $nrtl -ne $((128*nshots)) ]]; then
    echo "warning: expected $((128*nshots)) lines each, got ref=$nref rtl=$nrtl" >&2
fi

fail=0
for i in "${!SL[@]}"; do
    s=$(( i*128 + 1 )); e=$(( (i+1)*128 ))
    sed -n "${s},${e}p" "$TMP/ref.txt" > "$TMP/a"
    sed -n "${s},${e}p" "$TMP/rtl.txt" > "$TMP/b"
    lit_a=$(grep -c '#' "$TMP/a"); lit_b=$(grep -c '#' "$TMP/b")
    if diff -q "$TMP/a" "$TMP/b" >/dev/null 2>&1; then
        printf "  frame %-6s MATCH      (%s content lines)\n" "${SL[$i]}" "$lit_a"
    else
        d=$(diff "$TMP/a" "$TMP/b" | grep -c '^[<>]')
        printf "  frame %-6s DIFFER     ref=%s rtl=%s content lines, %s diff lines\n" \
               "${SL[$i]}" "$lit_a" "$lit_b" "$d"
        fail=1
    fi
done
exit $fail
