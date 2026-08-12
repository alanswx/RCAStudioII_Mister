#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Measure which keys each cartridge responds to, and emit the markdown table in
# Readme.md. Uses the reference emulator (fast); the RTL sim gives the same
# answers but is slower.
#
#   tools/probe-keys.sh > /tmp/table.md
#
# "Starts with"  = key that first puts pixels on screen.
# "Responds to"  = key that changes the frame hash at 400 frames, given the
#                  start key was pressed first.
# This says which keys are live, NOT what they do -- the RCA manuals are not
# included with the dumps, so per-key meanings are deliberately not claimed.
# ---------------------------------------------------------------------------
# For each cartridge: find which key starts it, then which keys do something during play.
R=/Users/alans/Documents/development/RCAStudioII_Mister
E="$R/refs/rca-studio2/studio2-games/studio2/studio2_headless"
cd "$R/refs/rca-studio2/studio2-games/studio2" || exit 1

hashof() { "$E" "$@" 2>/dev/null | grep -o "final hash [0-9A-F]*" | awk '{print $3}'; }

for c in "$R"/software/carts/*.bin; do
  b=$(basename "$c" .bin)
  # 1. which key starts it (produces any lit pixels by frame 160)?
  starts=""
  for k in 1 2 3 4 5 6 7 8 9 0; do
    n=$("$E" --frames 160 --press a$k@40:30 --shot 160 --ascii --quiet --outdir /tmp/pz "$c" 2>/dev/null | grep -cE "^  .*#")
    [ "${n:-0}" -gt 0 ] && starts="$starts$k"
  done
  s0=${starts:0:1}
  if [ -z "$s0" ]; then echo "$b|(none)|(none)|(none)"; continue; fi
  # 2. with that start key held early, which keys change the outcome by frame 400?
  base=$(hashof --frames 400 --press a$s0@40:30 "$c")
  actA=""; actB=""
  for k in 1 2 3 4 5 6 7 8 9 0; do
    h=$(hashof --frames 400 --press a$s0@40:30 --press a$k@200:40 "$c")
    [ "$h" != "$base" ] && actA="$actA$k"
    h=$(hashof --frames 400 --press a$s0@40:30 --press b$k@200:40 "$c")
    [ "$h" != "$base" ] && actB="$actB$k"
  done
  echo "$b|$starts|${actA:-none}|${actB:-none}"
done
