# CLAUDE.md — RCA Studio II for MiSTer

Guidance for working in this repo. Read this before changing RTL.

---

## 1. What this is

A MiSTer FPGA core for the **RCA Studio II** (1977), an RCA CDP1802 ("COSMAC")
based console with CDP1861 "Pixie" video.

This repo continues and extends earlier work by **Jason Coombes** (original
core), **Flandango** (MiSTer integration), **Alan Steremberg** (2026 CPU/video
and DMA timing work), and **Elle Ball** (2026 controller/profile and input
layout work). The current playable core is a collaborative continuation of that
foundation, not a rewrite from scratch. Credit for the emulators and hardware
references this core is built and checked against is in §11 — read it before
assuming any timing number here was derived from first principles.

**State of the core: playable.** The CPU has the full instruction set the BIOS
needs, interrupts and DMA; the video is a real CDP1861 driven by DMA, not a RAM
scraper. Frames are **pixel-identical to the reference emulator on 18 of 21**
test cases (§9), the built-in BIOS games and controller profiles are in place,
the beeper and RTL ST2 loader are implemented, and the core builds clean in
Quartus with timing closed (§4).

Recent additions that matter for day-to-day use include the OSD-managed joystick
profile system with its Auto/Manual split (the menu shows the detected profile
instead of the word "Auto"), the default 8-way profile,
Gunfighter/8-way/Doodles special cases, the Clear-only profile for digit-entry
software, the memory decode, and config-versioning so old saved menu state does
not silently map to the wrong fields.

What is still missing: **PAL**, and an embedded BIOS. See §6.

Licence: GPL-2.0-or-later (file headers). Note `rtl/reference/cosmac.vhdl` and
its translation `rtl/cosmac.v` are Eric Smith's GPL-3.0 code — compatible with
"GPL-2-or-later", but any release containing them is effectively GPL-3.

---

## 2. Hardware reference (the facts the RTL must match)

Authoritative notes live in `docs/*.txt` (scraped from the classicgaming
Studio 2 tech pages). Summary:

### CPU
- CDP1802 @ **1.7897725 MHz** (3.579545 MHz crystal ÷ 2). MAME uses 1760000 Hz
  for `studio2` because the real clock comes from an RC oscillator, not a crystal.
- **8 clocks per machine cycle**, 2 machine cycles per instruction
  (3 for long branch/skip). So ~110k instructions/sec.
- 16 × 16-bit register file R0–RF; P selects PC, X selects data pointer.
- DMA and interrupt are *bus* operations: they steal machine cycles from the CPU.

### Memory map
```
0000-02FF  ROM        System ROM: CHIP-8 interpreter
0300-03FF  ROM        System ROM: always present
0400-07FF  ROM        Built-in games  (replaced by cartridge when inserted)
0400-07FF  Cartridge  Cartridge games
0800-08FF  RAM        System/program memory
0900-09FF  RAM        Display memory (used as VRAM by software)
0A00-0BFF  Cartridge  Multicart space (rarely used)
0C00-0DFF  RAM/ROM    Mirror of 0800-09FF by default
0E00-0FFF  Cartridge  Multicart space (rarely used)
```
RAM is mirrored everywhere A9=0 and no ROM/cart is decoded (0C00, 1000, 1400, …).
There are only 512 bytes of it, so the mirror address is just A8-A0. The system
ROM is *not* mirrored above `$0FFF`; MAME's `studio2.cpp` maps RAM at
`0x0000-0x01ff` mirrored `0xfc00` across the whole 64K and then installs the ROM
handlers over `$0000-$07FF` alone, which is the same statement. Implemented in
`rtl/rcastudioii.sv`, tested by `tools/memdecode-test.sh`.

### I/O
| Signal  | Meaning |
|---------|---------|
| `INP 1` | Turn display on (CDP1861). BIOS does this via `CALL $0066`. |
| `OUT 1` | Turn display off. |
| `OUT 2` | Low 4 bits = key number (0–9) to scan, latched into a CD4515. |
| `EF1`   | CDP1861 display status — asserted for 4 line-times before the start and before the end of the 128-line display window. |
| `EF3`   | Selected key pressed on **left** keypad (player A). |
| `EF4`   | Selected key pressed on **right** keypad (player B). |
| `Q`     | Beeper on/off. NE555 astable, ~625 Hz nominal, pitch decays ~50% over 0.4 s (the "warpy" power-up sound). |

### Video — this is the part that matters most
The CDP1861 does **not** have its own frame buffer. It asserts `DMA_OUT` and the
**1802** performs 8 DMA-OUT machine cycles per scanline, reading bytes through
**R(0)** and handing them to the 1861, which shifts them out as pixels.
Software sets R(0) in the 60 Hz interrupt handler.

- 64 × 32 logical pixels (each row displayed 4× → 128 active lines).
- 262 lines/frame, ~14 bytes (112 pixel-times) per line, NTSC 60 Hz.
- Display window: lines 64–191 active; interrupt fires ~2 lines before.
- BIOS ISR entry is `$001C`; it sets `R0 = $09xx` and streams `0900-09FF`.

The Studio II BIOS ISR, disassembled from `rom/studio2.rom`:
```
001B: 70           RET            ; end of previous ISR
001C: 22           DEC R2         ; <-- interrupt vector
001D: 78           SAV            ; save T (X,P) to M(R(X))
001E: 22           DEC R2
001F: 73           STXD
0020: C0 00 23     LBR $0023
0023: 7E           SHLC
0024: 52           STR R2
0025: 19           INC R9
0026: F8 09        LDI $09
0028: B0           PHI R0         ; <-- R0 = $09xx, the DMA display pointer
0029: F8 D0        LDI $D0
002B: A8           PLO R8
...  A0 E2 20 A0 E2 20 ...        ; 1861 DMA wait/timing loop
```
**Any correct Studio II core must implement 1802 interrupts, `SAV`, `RET`, and
DMA-OUT cycles.** The current core implements none of them (§6.1).

### Cartridge formats
- **`.bin` / `.rom`** — raw dump, loads flat at `$0400`. 512 or 1024 bytes.
- **`.st2`** — paged format with a 256-byte header (`docs/cartridge.txt`):
  ```
  0-3    "RCA2"
  4      total number of 256-byte blocks (incl. header)
  5      format code (1)
  6      video flag: non-zero = non-standard video driver
                     1 = RAM used normally but no scrolling
  8,9    author initials     10,11  dumper initials
  16-25  RCA catalogue code (ASCIIZ)
  32-63  title (ASCIIZ)
  64-127 page address for each following 256-byte block
  256+   block data
  ```
  Valid target pages are `04-07`, `0A-0B`, `0E-0F` in each 4K bank.

---

## 3. Source layout

### Files actually compiled (`files.qip`)
| File | Role |
|------|------|
| `RCAStudioII.sv` | MiSTer `emu` top: hps_io, PLL, OSD config string, video chain (video_mixer + video_freak), on-screen keypad |
| `rtl/rcastudioii.sv` | Core glue: CPU + pixie + memory decode + keypad + joystick profiles + cartridge loader |
| `rtl/cdp1802.v` | The CPU: full BIOS instruction set, interrupts, DMA, machine-cycle timing |
| `rtl/dpram.sv` | Dual-port block RAM — instantiated twice, as the 4 KB ROM/cartridge image and the 512 B RAM |
| `rtl/numstick.sv` | Analog-stick on-screen keypad (Jaguar core's, via ColecoAdam) |
| `rtl/pixie/pixie_video.v` | Thin wrapper |
| `rtl/pixie/cdp1861.v` | The video: a real CDP1861, DMA-fed, no frame buffer |

### Files present but NOT compiled (dead / reference)
`rtl/cosmac.v`, `rtl/dma.v`, `rtl/keypad.v`, `rtl/debounce.v`, `rtl/rom.v`,
`rtl/beep.sv`, `rtl/pixie/pixie_video_old.v`, `rtl/pixie/pixie_dp_*.v{,hdl}`,
`rtl/reference/`.

`rtl/cosmac.v` (Eric Smith's GPL-3 1802, via X-HDL) was once the planned
replacement CPU. It is no longer needed — `rtl/cdp1802.v` now has the
instruction set, interrupts, DMA and cycle timing the BIOS requires. Keep it
only as a cross-reference.

Note `rtl/pixie/cdp1861.v` is the *live* video module; the old
`pixie_video_studioii.v` RAM scraper has been deleted.

### Clocks
`rtl/pll/pll_0002.v`: `outclk_0 = 7.040229 MHz` (`clk_sys`),
`outclk_1 = 42.241379 MHz` (`clk_vid`, now unused). 7.040229 = 4 × 1.760229 MHz.
`RCAStudioII.sv` divides `clk_sys` by 4 into the `ce_pix` enable — the 1.76 MHz
pixel/CPU timebase everything inside `rcastudioii.sv` is gated on. The Verilator
sim ties `ce_pix` high instead (one pixel per clock): frame contents are
identical, the sim is just 4× cheaper per frame. Don't "fix" either side to
match the other.

---

## 4. Build & test

### Quartus
Quartus **17.0.x** only (MiSTer requirement). Project `RCAStudioII.qpf`, top
entity `sys_top` (from `sys/`). Quartus is not installed natively here; it runs
in the `raetro/quartus:mister` Docker image (Quartus 17.0.2):

```sh
tools/quartus-build.sh          # full build -> output_files/RCAStudioII.rbf
tools/quartus-build.sh map      # analysis & synthesis only (~1.5 min)
tools/quartus-build.sh clean
```

Last known-good build: **0 errors**, timing closed (worst setup slack
+0.710 ns), 10,003 ALMs (24 %), 444 kbit of block RAM (8 %), whole flow
~6 minutes. Most of that is the MiSTer
framework — `rcastudioii` itself is ~1,140 ALMs (of which the CPU is ~600) and
`numstick` another ~940. The "19 %" quoted here previously was measured before
numstick landed; a same-day A/B put the memory decode at **+86 ALMs and
+4 kbit** over the pre-decode core, which is just the 512-byte RAM.

**Do not run `quartus_sh --flow compile`.** The image is amd64 under emulation
on Apple Silicon, and the qsf's `NUM_PARALLEL_PROCESSORS ALL` makes Quartus fork
helper processes that crash there — they end up `<defunct>` beside
`[crashreporter]`, and the parent deadlocks forever on named pipes from the dead
helpers at ~4 % CPU. It looks like a slow build but never finishes. The script
passes `--parallel=1` to each stage to avoid this; a healthy build sits at
~100 % CPU.

`RCAStudioII.qsf` needs `PRE_FLOW_SCRIPT_FILE = quartus_sh:sys/build_id.tcl`;
without it synthesis dies on the missing generated `build_id.v`.

### Verilator sims (`verilator/`)
Two targets, both working. `verilator` 5.x and `sdl2` come from Homebrew.

```sh
cd verilator
make            # interactive SDL/ImGui sim -> ./obj_dir/Vtop
make headless   # batch sim                 -> ./obj_dir_headless/Vtop
make clean
```

Both accept `--bios FILE`, `--cart FILE` (raw `.bin`, flat at `$0400`) and
`--press KEY@FRAME[:HOLD]`, where KEY is `0`-`9` optionally prefixed `a`/`b`
for the two keypads. The headless sim adds `--frames`, `--shot`, `--shot-every`,
`--ascii`, `--vram`, `--frame-log`, `--trace-cpu`, `--trace-from`; see `--help`.

```sh
./obj_dir/Vtop --cart "../software/carts/TV Arcade I - Space War (USA).bin" --press a1@40:30
./obj_dir_headless/Vtop --frames 200 --press a5@40:20 --shot 200 --ascii
```

Keyboard in the GUI: **player A = number row `0`-`9`**, **player B =
`P Q W E R T Y U I O`**. With no cart the built-in games start on **3/4/5**;
most cartridges start on **1** or **2**.

**The Makefile does not track RTL edits into `obj_dir`.** If a `.v` change
appears to do nothing, `rm -rf obj_dir obj_dir_headless` and rebuild — this has
silently run stale binaries more than once.

Lint:
```sh
cd verilator && make lint
```

### Loading software
The OSD (`RCAStudioII.sv:206`) exposes:
- `F0,rom` → BIOS, loaded to `$0000`
- `F1,bin` → cartridge, loaded to `$0400`

The BIOS is **not** embedded; it must be loaded from the OSD every boot, and
`rom_loaded` (`RCAStudioII.sv:291`) only latches when `ioctl_index==0 &&
ioctl_addr==100`, so the core is held in reset until a BIOS is loaded.

---

## 5. Reference material on disk

### `refs/` — emulator and HDL references (git-ignored, ~950 MB)
| Path | What | Why it's here |
|------|------|---------------|
| `refs/emma_02/` | **Emma 02** (etxmato) — the definitive CDP1802 multi-system emulator: Studio II/III, Visicom, MPT-02, VIP, Elf. C++/wxWidgets, AGPL-3. | Best behavioural reference. `src/cdp1802.cpp`, `src/video.cpp`. |
| `refs/rca-studio2/` | **ajavamind/rca-studio2** (Andrew Modla, an original RCA game developer). Processing/Java. Claims precise CDP1802 DMA timing, NTSC/PAL. Handles `.st2 .bin .rom .ch8 .c8x .vip .arc .fd2`. | Best reference for *timing* and for the ST2 loader. |
| `refs/cosmac-vhdl/` | **brouhaha/cosmac** — Eric Smith's GPL-3 VHDL 1802 + `pixie/` (a real CDP1861 front/back end) + Elf SoC. | This is where `rtl/cosmac.v` and `rtl/pixie/pixie_dp_*` came from. The upstream is complete; our copies are partial. |
| `refs/AVI1861/` | **dmadole/AVI1861** — drop-in CDP1861 replacement, ATF1504 CPLD (`pld/frame.pld`, `pld/line.pld`). | Cycle-exact 1861 sync/DMA timing from a working hardware replacement. |
| `refs/cosmac_mbc/` | **kanpapa/cosmac_mbc** — COSMAC MicroBoard incl. Pixie video. | Secondary HDL reference. |
| `refs/studio2-games/` | **paulscottrobson/studio2-games** — homebrew Studio II games with full 1802 asm source + `asmx` assembler. | Test material you can rebuild and instrument. |

**MAME is deliberately not cloned here** — use the existing checkout at
`/Users/alans/Documents/development/lbmactwo_MiSTer/mame`. Relevant files:
`src/mame/rca/studio2.cpp`, `src/devices/cpu/cosmac/cosmac.cpp`,
`src/devices/video/cdp1861.cpp`.

### `software/` — test corpus (git-ignored)
| Path | Contents |
|------|----------|
| `software/RCA - Studio II (20200201-121822)/` | No-Intro set, 17 commercial cartridges (zipped) |
| `software/carts/` | Same set, extracted `.bin` (512 / 1024 bytes, load at `$0400`) |
| `software/tosec/RCA Studio 2 [TOSEC]/` | TOSEC 2012-04-23: BIOS + games as `.st2`, `.bin` and `.asm` |
| `software/RCA - Chip-8.zip`, `RCA - Superchip.zip`, `RCA - COMSAC VIP.zip` | CHIP-8 / VIP software |

`rom/studio2.rom` is md5 `b37205bf19b197682f00619d05da194b`, byte-identical to
the TOSEC `RCA Studio II BIOS (1976)(RCA).bin`. Good. `rom/studio2.hex` is the
same 2 KB as space-separated hex text (6144 bytes).

**Suggested smoke-test ladder** (easiest → hardest):
1. `TV School House I (USA).bin` (512 B) — simple, mostly static display.
2. `TV Arcade I - Space War (USA).bin` — needs working keypad + timing.
3. `TV Arcade III - Tennis + Squash (USA).bin` — fast-moving sprites, timing-sensitive.
4. `Space Invaders (2000)(Paul Robson).st2` — homebrew, source in `refs/studio2-games`.
5. Any `.st2` with a non-zero video flag — exercises the paged loader.

---

## 6. Known defects

Most of the original defect list is fixed — see §10 for what changed. What
remains, ordered by impact.

### 6.1 Homebrew flicker -- does not currently reproduce

The previous entry here claimed Paul Robson's homebrew flickered (45 of 101
frames blank on `invaders.st2`) and blamed the missing memory mirroring. Both
halves of that turned out to be wrong, so the entry is kept as a warning rather
than deleted.

Re-measured on 2026-08-15 across all eight homebrew titles, before *and* after
the decode was implemented, the numbers are identical and clean:

    invaders.st2   frames 300-400   0 blank, 53 distinct hashes (it is animating)
    combat/hockey/scramble                   0 blank,  1 hash   (static, correct)

The mirroring argument was also wrong on its own terms: `$0A00` has **A9 = 1**,
so it is cartridge space, not a RAM mirror — the mirror is `$0C00-$0DFF`, where
A9 = 0. If a flicker is seen on hardware, start the trace again from scratch;
do not assume the R(0) story above.

### 6.2 Memory decode -- done (2026-08-15)
Implemented; see §10. `tools/memdecode-test.sh` covers it.

### 6.3 Top level — `RCAStudioII.sv`
- No PAL support, and the BIOS is not embedded (the core is held in reset until
  one is loaded). The rest of the old list — aspect ratio, `CE_PIXEL`, the dead
  `clk_1m76` — is fixed; see §10 (2026-08-14).

### 6.4 Minor
- `sys/` is shared framework code and must not be edited; the remaining Quartus
  warnings (unused SDRAM/SDIO pins, open-drain removal) all originate there and
  are present in every MiSTer core.
- `RCAStudioII.sdc` has no core-specific constraints beyond `derive_pll_clocks`.

---

## 7. Roadmap

### 7.1 Polish
PAL option, embedded BIOS, and any final top-level cleanup around default OSD
behaviour and naming consistency.

### 7.2 Controller/profile parity
The profile system is intentionally explicit and tested across the common
cartridges, but every new title is still a chance to discover a missing special
case. Keep the profile table aligned with the actual manuals and the reference 
emulator.

Once the full software library runs reliably, make a deliberate consolidation
pass: inventory every title's controls, merge profiles that can completely
encompass one another, then reorder the remaining minimal set into a logical
progression. That is the right time to bump the `CONF_STR` version and reorder
its profile entries.

### 7.3 Keep the comparison green
Any RTL change should be re-checked against the reference emulator (§9) before
committing. The regression is cheap — a few seconds per cartridge. Changes that
touch memory should also run `tools/memdecode-test.sh`, which no cartridge in
the corpus can substitute for (§9).

---

## 8. Conventions

- Quartus 17.0.x. Do not edit anything under `sys/` — it is the shared MiSTer
  framework and is overwritten on updates.
- Add new sources to `files.qip` by hand (Quartus writes them into
  `RCAStudioII.qsf` instead; move them). Keep `verilator/Makefile`'s `V_SRC` in
  sync with `files.qip`.
- Keep the PLL in `rtl/pll*`; the framework requires it there.
- Prefer deleting dead code over commenting it out. This tree is already hard to
  read because so much of it is commented-out history — git has that.
- When changing timing or video, state which reference you matched against
  (MAME / Emma 02 / rca-studio2 / AVI1861) in the commit message.

---

## 9. Verifying against the reference emulator

The core is checked frame-by-frame against Paul Robson's C emulator at
`refs/rca-studio2/studio2-games/studio2`, which was extended for this purpose:
an ST2 loader, a headless front end (`headless.c`, no SDL), PNG capture, an
instruction trace and scripted keypresses.

```sh
cd refs/rca-studio2/studio2-games/studio2
make headless          # -> ./studio2_headless   (links libc only)
./studio2_headless --help
```

Both it and the RTL sim take the same `--frames`, `--press KEY@F[:H]`, `--shot`
and `--ascii` options, so a comparison is a plain `diff`. The C emulator renders
32 logical rows; the RTL renders 128 scanlines, so expand each reference row 4x:

```sh
# reference -> 128 lines
./studio2_headless --frames 200 --press a5@40:20 --shot 200 --ascii --quiet \
  | grep -E "^  [.#]+$" | sed 's/^  //' | tr '.' ' ' \
  | awk '{for(i=0;i<4;i++) print}' > /tmp/c.txt

# RTL -> 128 lines
cd ../../../../verilator
./obj_dir_headless/Vtop --frames 200 --press a5@40:20 --shot 200 --ascii \
  | grep -E "^ *[0-9]+ \|" | sed 's/^ *[0-9]* |//; s/|$//' > /tmp/r.txt

diff /tmp/c.txt /tmp/r.txt        # expect no output
```

Current score: **18 / 21 pixel-identical** (3 built-in-game frames + 18
cartridges). The three that differ — `86677b`, `87201`, `Concentration Match` —
render the same structure and the same number of content lines but different
game state, because the BIOS updates an RNG seed in the ISR and any timing
difference deals different cards.

Note on `86677b` and `87201`: the reference emulator renders **full-screen
random noise** for both from the first frame, before any input. They are not
working images there either, so neither side is a reference for the other, and
their output is free to change without that meaning anything. Do not chase them.

**What the frame comparison cannot see.** Nothing in the corpus — 18 retail
cartridges, 8 homebrew, 5 TOSEC `.st2` — reads or writes a RAM mirror, or any
address above `$0FFF`. The whole memory decode is therefore invisible to it:
the old truncate-to-12-bits version scored exactly the same 18/21. That is what
`tools/memdecode-test.sh` is for — a hand-assembled 90-byte native-1802
cartridge that pokes each case and checks the result out of the simulated RAM.
It fails 4 of its 8 checks against the pre-decode core.

**The reference is authoritative for instruction *order*, not for cycle
timing.** Its model gives the CPU zero cycles during all 128 display lines
rather than 6 of every 14, so it runs ~952 instructions/frame where real
hardware (and the RTL) does **1321**. Do not "fix" the RTL to match 952.

For CPU debugging both sims emit the same trace layout; strip the differing
first and last columns to diff them:

```sh
diff <(awk '{$1="";$NF="";print}' c.trace) <(awk '{$1="";$NF="";print}' rtl.trace)
```

Also useful: `tools/emma02.sh` unpacks Emma 02 (the definitive CDP1802
multi-system emulator) from its own installer into `refs/emma_02/dist` with no
build and no system install — handy as a second opinion, and it ships 38 `.st2`
cartridges including an RCA test cart.

---

## 10. What changed

### 2026-08-15 — the Invaders wobble WAS a core bug: fixed-slot shifter vs ISR entry jitter

**This entry supersedes (and reverses) the earlier "the wobble is the game's
own dirty redraw" diagnosis from the same day.** That analysis correctly showed
VRAM clean at every frame boundary and R0 per-line traces identical across
phases, and wrongly concluded the display path was exonerated. Both
observations were true and the conclusion still wrong, because the defect
lived *below* the per-line traces, in sub-line phase:

- The 1802 honours interrupts only at instruction boundaries, so the ISR's
  whole cycle-counted stream lands 0 or 1 machine cycle late depending on
  which instruction the game's main loop was in when INT asserted. Robson's
  2000-build Invaders (md5 350e8332...) drifts across both phases in ~14-frame
  runs; most software sits in one phase forever, which is why 18/21 never saw
  it.
- The 1861's DMA burst therefore latches byte k at hcount 31+8k on some frames
  and 39+8k on others (`--trace-cyc` on line 80 shows it directly). The
  shifter read the line buffer at fixed 32+8k — one pixel of tolerance — so on
  late frames every slot was read 8 px before its byte landed and each line
  displayed the *previous line's* buffer: picture down one scanline, and
  screen row 0 replaying the previous frame's bottom row ($09F8 = the `# #`
  fragment). "The bottom line draws at the top" was literal.
- Fix (rtl/pixie/cdp1861.v): read the buffer one machine cycle later
  (ACTIVE_START 32→40, DE follows, HSync moved to 105..111 to stay in
  blanking). Both phases now render identically; the real 1861 shifts bytes
  out as DMA delivers them, so on silicon the late phase is an 8-px horizontal
  nudge a CRT hides — the fixed window one cycle later gives the same
  tolerance with zero jitter. A burst can still theoretically land two cycles
  late ([40+]); no known software does.

Verified: A/B old-vs-new RTL over 5 built-ins, 18 retail carts, 15 homebrew
`.st2` and the 2013 Invaders rebuild — byte-identical everywhere except the
2000 Invaders (73 of 74 late frames are exactly the old frame shifted up one
scanline; fragment frames 76→0, topmost content row constant) and **Combat**,
whose diffs have the same one-scanline-shift signature: Elle's reported Combat
jitter was this same bug. memdecode test passes. New sim flag `--trace-vwr`
logs CPU writes to the display page's top/bottom rows with the writing PC
(`VWR_ALL=1` env widens it to the whole page).

Also learned the hard way: this build starts/restarts on **B0**, not A0 —
keysend keycode 51 (comma) on the MiSTer, `--press b0@F` in the sims. A0 does
nothing at the game-over "00000" screen.

### 2026-08-15 — the Cx row decoded as all-long-branch (Race), and Elle's list

Elle's problem list was Combat, Hockey, Scramble, Race. Triage against MAME:

- **Race (Andy Modla)** was a real CPU bug. The Cx decode treated the whole row
  as long branch, but N2=1 is the long-skip family (reference cosmac.vhdl):
  C4 NOP, C5-C7/CC-CF conditional long skips -- 3 cycles, P moves by 0 or 2,
  the operand bytes are never read. Race's custom ISR at $0F00 executes C4, so
  the "NOP" jumped to whatever two bytes followed and the machine ended up
  executing open bus. Fixed with a LSKIP state; the ??00 condition base is IE
  when N3 is set, per the reference, giving CC (LSIE) skip-if-IE. Race now
  shows its title and starts on B0-pad key 2, matching MAME. No retail or
  Robson title uses the skip family, which is why 18/21 never saw it.
- **Hockey works and always did** -- its start is two-step: game select (1-4 on
  pad A) *then* an option key (8 or 9). hockey.txt only documents the first
  step; every single-key probe misses it. Traced the scan loops to find the
  8/9 wait at $0434.
- **Combat and Scramble** respond correctly in sim (Combat: code then B0;
  Scramble: 6 starts each level) and are frame-identical to the verified
  corpus copies. The reported flicker/stalling is consistent with the
  pre-DMA-fix builds they were observed on; retest on current.
- The library's five other titles (Climber, computer, outbreak, rocket,
  tv-arcade-2012) are blank here and show uniform garbage in MAME's studio2
  too -- likely Studio III / different-hardware or key-dependent; unresolved,
  but not obviously a core defect.

### 2026-08-15 — DMA honoured at instruction boundaries only (the real flicker)

There are two builds of Paul Robson's Invaders in circulation; the one in
`software/` runs clean, the other (user library, 756/1024 payload bytes differ)
blanked 26 of every 28 frames in this core while MAME ran it clean. The chain:
the game waits on the ISR frame counter in a 6-cycle loop, so the interrupt
entry phase drifts each frame; the CPU was inserting the 1861's DMA burst
*mid-instruction* (between S0 and S1), which for some phases put the burst one
machine cycle early relative to the BIOS ISR's cycle-counted `PLO R0/SEX/DEC`
display loop — its `GLO R0` then sampled the row pointer before the line's
burst instead of after, R(0) rewound to $0900 every line, and the frame showed
whatever was at $0900 for a frame the game never drew into. VRAM was fine the
whole time.

A real 1802 honours DMA and interrupts only *between* instructions
(`rtl/reference/cosmac.vhdl` `state_fetch` → always `state_execute`; MAME's
cosmac does the same). Fixed in `rtl/cdp1802.v` (FETCH no longer yields to DMA;
`resume_exec` deleted) with the matching 1861 change: `DMAO` now stays asserted
until its 8 cycles are actually serviced rather than for a positional window,
dropping at the 7th acknowledge because the CPU commits one more cycle after
the request falls — holding it a cycle longer ran 9 cycles/line and R(0)
drifted +1 a line (Doodles lost its dot; that is the symptom to check).

Verified: the whole corpus — 5 built-ins, 8 homebrews in both formats — is
**pixel-identical to the pre-fix RTL** at the test frames, the memory-decode
directed test passes, and the second Invaders build goes from 328 blank frames
of 540 to zero, matching MAME. Diagnosed with three new headless-sim tools:
`--trace-r0` (per-scanline R0/DMAO/INT), `--trace-cyc FROM:TO` (per-machine-
cycle state/register-writeback), and `--swap FILE@FRAME` (mid-run cartridge
load, like an OSD swap).

### 2026-08-15 (OSD shows the detected profile)

**"Auto" is gone from the Joystick list.** It was a value inside the profile
enum, which meant the menu could tell you the core was auto-detecting but never
*what it had detected*. Now there are two rows: `Mapping` (Auto/Manual, bit 6)
and `Joystick` (the profile itself, bits 5:2, no Auto entry). On Auto the core
pushes the detected profile into bits 5:2 through hps_io's `status_set`, so the
row reads "Gunfighter" after Gunfighter loads; on Manual the row is the user's,
and it starts from whatever was last detected rather than a stale value.

Freeing value 0 from meaning "auto" also makes every one of the 16 encodings
selectable, `MAP_NONE` included — it is listed as "None" and differs from
"Clear-only" in that Start still works.

The write-back is one pulse at startup and per change (new detection, or
Manual→Auto), delayed ~0.3 s past the end of the download so `map_profile` has
settled and the HPS is no longer busy. Deliberately *not* a retry loop that
pushes until the row agrees: that would fight the user if they scrolled the row,
and would pulse forever on a Main that ignores `status_set`. Shape copied from the NES core
(`status_in`/`statusUpdate`) and Apple IIgs (`status_mirror`). A dropped pulse
only leaves the row stale — nothing about the mapping itself depends on it,
because the core plays from `auto_profile` directly.

CONF_STR bumped `v2` → `v3`, since bit 6 is new and bits 5:2 changed meaning.

**Verified in sim, with one gap.** For five cartridges, `Manual` + the detected
profile number gives byte-identical frames to `Auto` (the override path reaches
the mapping and agrees with detection), and `Auto` vs `Clear-only` differs on
Gunfighter and Star Wars (the pad is genuinely driving input). **The `status_set`
write-back itself is not simulated** — Verilator has no HPS — so that the OSD
row actually updates needs checking on hardware.

### 2026-08-15 (memory decode)

**The core finally decodes its address bus.** Everything used to come out of one
4 KB dpram with the address truncated to `ram_a[11:0]`: ROM and RAM shared the
array, `$1000` read the system ROM, the documented `$0C00-$0DFF` mirror did not
exist, and a write outside `$0800-$09FF` was silently dropped. Now:

- The ROM/cartridge image and the 512 bytes of RAM are separate arrays, so a
  cartridge can no longer be written over.
- RAM answers wherever **A9 = 0** and nothing else is decoded — `$0800-$09FF`,
  `$0C00-$0DFF`, `$1000-$11FF`, `$1400-$15FF` and so on up through 64K, at
  `A8-A0` inside the 512 bytes.
- The system ROM is decoded at `$0000-$07FF` in the first 4 K bank only, and is
  not mirrored above `$0FFF`.
- `$0A00-$0BFF` / `$0E00-$0FFF` are cartridge windows; `$0C00-$0DFF` is the RAM
  mirror unless the cartridge pages ROM over it. The `.st2` loader records which
  of pages `$0A-$0F` it actually filled, which is what makes that distinction —
  `asteroids`, `berzerk`, `pacman` and `scramble` page `$0C/$0D`, the other four
  homebrew do not and get the mirror.
- Undecoded space (A9 = 1 with no cartridge) reads back `$00`.

Matched against **MAME** `src/mame/rca/studio2.cpp`, which states the same rule
in its header comment and implements it as `map(0x0000, 0x01ff).mirror(0xfc00).ram()`
plus ROM handlers installed over `$0000-$07FF` alone. MAME returns `$FF` for
undecoded space (`unmap_value_high`); this core returns `$00` instead, matching
the C reference emulator's flat array so the §9 frame comparison stays honest,
and giving a blank scanline rather than a white one if a DMA wanders.

Verified three ways: `tools/memdecode-test.sh` (new, 8 directed checks, 4 of
which fail on the old core); the §9 comparison unchanged at 18/21; and an
A/B of every image in the corpus — 5 built-in games, 18 retail cartridges,
8 homebrew `.st2`, 8 TOSEC `.st2`, four frames each — byte-identical before and
after except `86677b` and `87201`, which render noise in the reference emulator
too. The `.st2` == `.bin` equivalence for the five TOSEC titles that exist in
both formats still holds.

Also here: `tools/compare-game.sh` could not run its no-cartridge (`-`) case on
macOS, because bash 3.2 treats an empty array expansion under `set -u` as an
unbound variable.

### 2026-08-14 (beta-tester round)

**The machine ran 4× too fast on hardware.** `ce_pix` — the 1.76 MHz timebase
the whole core is gated on — was tied high in the FPGA top, so the console ran
at 7.04 MHz: 240 Hz frames, 4× game speed, 4× beeper pitch. The Verilator
regression never saw it because the sim ties `ce_pix` high on purpose and
frame-relative behaviour is unchanged. The top now divides clk_sys by 4
(sim output verified bit-identical before/after). This is the likely root of
most beta-tester complaints, "homebrew not working properly" included.

**Real video chain.** `CLK_VIDEO = clk_sys` with `CE_PIXEL` from `video_mixer`
(GAMMA=1, scandoubler for 31 kHz analog when forced) into `video_freak`:
aspect-ratio OSD options (4:3 default, full-screen, custom) and the four
integer-scaling modes. Native output is 64×128 in a 112×262 frame at 15.7 kHz /
59.98 Hz.

**Input, per the beta testers' list.** Start presses the cartridge's start key
(per-CRC, from the manuals in the Readme; A1 default), Select is CLEAR. A
Players setting (Auto/1/2) picks which stick drives keypad B's half of split
profiles; permanently one-player profiles stay on gamepad 0 — Auto reproduces
the previously verified behaviour exactly. The J list
now carries A0–A9/B0–B9 as default-unbound buttons for direct custom mapping.
The homebrew `tennis.st2` uses its single-player keypad-B `MAP_PADDLE` profile,
which is distinct from the retail Tennis/Squash `MAP_CROSS` profile:
up/down are B2/B8, and left/Fire/right select racket sizes B4/B5/B6.
The Jaguar core's numstick (via ColecoAdam, `rtl/numstick.sv`) gives an
analog-stick on-screen keypad, OSD-selected onto pad A or B; left row reduced
to the single "0" the Studio II has. All equivalences verified in sim
(stick == matching keypress, byte-identical frames).

**Homebrew mapped, but not yet reliable on hardware.** The profiles cover all
8 Paul Robson games (both `.st2` and `.bin`, including page `$0C/$0D` games),
but Combat and Hockey show flicker/jitter, Scramble does not progress reliably,
and Invaders has minor flicker. Resolving these homebrew issues is the next major
core priority. They all fire/start on `0`, so the profiles are `MAP_HOMEBREW`
(8-way pad A with corner keys on diagonals for Berzerk, fire on B0 — never A0,
which restarts Invaders) and `MAP_HB2P` (Hockey/Combat: cross + own-pad 0). The
profile field is 4 bits internally; the OSD override stays 3.

**Extra button (MPT-02).** The Soundic/Hanimex MPT-02 Studio III machines had
swappable joysticks with the official mapping: cross on 2/4/6/8, fire 5, second
button 0. Fire/Extra mirror that; Extra presses same-pad 0 in CROSS
only (0 pauses Tennis) — never HOMEBREW, where A0 restarts Invaders. J-list
bits: 4=Fire 5=Extra 6=Start 7=Select, A0..A9=17:8, B0..B9=27:18.

**OSD fixed.** The Joystick option did nothing because `J1,Fire;` sat mid-list:
Main's menu draw pass skips `J` entries but its selection pass counts anything
`>= 'A'`, so every row after it acted on the previous entry. Non-OSD entries
(`J`/`jn`/`V`) must be last, per the docs.

### 2026-08-12

**Joystick support, mapped per cartridge.** A CRC16 of the image is taken during
`ioctl_download` and looked up at the end of the transfer to pick one of six
profiles. This is necessary rather than ornamental: the Studio II has no
joystick, so each game chose its own keys -- Tennis moves the racquet on 2/8 but
uses 4/5/6 for racquet size, and Space War fires on keypad A while steering on
keypad B. Presses are OR'd with the keyboard. Unknown cartridges get `CROSS`.

The five BIOS built-ins have no cartridge to CRC, so they are told apart by the
key that starts them (A1 Doodles, A2 Patterns, A3 Freeway, A4 Bowling, A5
Addition), latching on the first press after reset only -- those keys are reused
during play. An OSD "Joystick" setting overrides the whole thing, since the table
can only be as good as its entries.

Eight cartridges are mapped explicitly; ten are deliberately left on the default
because they are number-entry games a stick cannot drive, or are unidentified.
See the Readme for the breakdown and the reasoning.

Verified by equivalence rather than inspection: driving the stick produces
byte-identical frames to the matching keypress and both differ from no input,
including the asymmetric Space War case where fire lands on keypad A and steering
on keypad B.

**3x4 keypad layout** contributed by Elle Ball (@meauxdal), cherry-picked from
their fork -- no PR was opened. Player A's layout matches the C reference
emulator's table exactly, which helps the comparison harness.


**Sound.** The beeper is implemented: a square wave gated by the 1802's Q line,
with the pitch decay `docs/sound.txt` describes (NE555 astable whose control pin
sits on a 10uF cap, drooping to about half pitch over ~0.4s -- the "warpy"
power-up sound). ~625Hz fresh, ~312Hz fully decayed, recharging whenever Q drops.
MAME uses a flat 300Hz beeper and marks the discrete circuit unimplemented, so
this follows the hardware description instead.

Q itself was verified against the reference emulator before wiring anything up,
by logging every edge in both (`--trace-q`, in both simulators). On the built-in
Addition game they agree on edge count, on beep durations (3, 3, 2 frames) and
exactly on the third beep's frames; the small offset on the first two is the
usual instruction-rate phase difference. Measured output is ~580-600Hz.


**ST2 cartridge loader, in RTL.** `rtl/rcastudioii.sv` now parses the paged
`.st2` format during `ioctl_download`, so it works on the FPGA and not just in a
host-side loader. Triggered purely by the `RCA2` magic in the first four bytes —
the OSD extension index is deliberately not used, since a valid `.st2` always
carries the magic and going on the magic alone means a mis-named file still
loads. `CONF_STR` is `"F1,ST2BINROM"` so the browser offers all three. The page table at header offsets 64-127 is
latched into a 64-byte array as it streams past, then each 256-byte block is
written to `page << 8`.

Page validity follows the C reference, **not** `docs/cartridge.txt`: reject only
the system ROM (`$00-$03`) and RAM (`$08-$09`) pages, plus `$00` as the unused
marker. `$0C`/`$0D` are legal — `race.st2` pages ROM over the default RAM mirror
there.

Verified the strongest way available: for the five TOSEC titles that exist in
both formats, loading the `.st2` gives **byte-identical output to the `.bin`**.
The `.bin` regression is unchanged at 18/21.


**CLEAR key.** Added, mapped to **F1** and an OSD "Clear" button, folded into
`reset` (which drives the 1802's `CLEAR_N`). `docs/RCA_Studio_II_Service_Manual.pdf`
Figure 1 shows it as a console pushbutton between the two keypads, and the test
procedure on page 5 — "press and hold Clear... release Clear" — confirms it is a
momentary reset, which is what this implements. Note this does **not** change
simulator behaviour: both sims already reset at power-on, so scripted sequences
were never missing a CLEAR. It matters on real hardware and in the GUI sim, where
there was previously no way to reset without reloading the core.

The same manual settles a timing question: the Studio II clock is a **slug-tuned
RC oscillator**, adjusted by eye for "zero waveform drift" against the 60 Hz line
(§13, Figure 33). There is no exact crystal frequency, which is why MAME uses a
round 1760000 Hz.

The core went from "puts a picture on screen but most of the machine is
stubbed" to pixel-identical output. Briefly, so the history is not lost:

**CPU.** Interrupts never fired, for four stacked reasons: the transition into
`INTERRUPT` was commented out; the commented test used `INT_N == 1` though it is
active low; `IE` was never initialised (reset leaves it 1); and the `INTERRUPT`
state never set `X=2`/`P=1`. `WAIT_N`'s run/pause test was inverted and only
worked because the glue tied it low. `RET`, `DIS`, `SAV`, `MARK` were missing and
`IDL` decoded as `LDN R0` — the BIOS ISR uses `RET` and `SAV` every frame, and
`RET` was flagged `unsupported`. `SC` was driven with `<=` inside `always @*`
and unassigned on most paths, inferring a latch, so the 1861 could never see a
DMA or interrupt state code.

**Timing.** The CPU ran one state per `clk_sys` (~16x too many instructions per
frame) and `EXECUTE2` made every memory-reading instruction 3 machine cycles
instead of 2, so the ISR's cycle-counting DMA sync loop could never lock. It now
runs from a machine-cycle enable with 2-cycle instructions and lands on 1321
instructions between interrupts, matching hardware.

**Video.** `pixie_video_studioii.v` was not a 1861 at all — it ignored the CPU
and scraped `$0900-$09FF` over a second dpram port, so DMA never stole cycles
and the display base was hardwired. `rtl/pixie/cdp1861.v` replaces it: no frame
buffer, DMA-driven, timing matched to MAME's `cdp1861` including the
free-running DMA cadence the ISR synchronises against. Uniform pixel counters
fixed a 74-pixel-wide active window (the old state machine bumped the horizontal
counter from seven places and stalled); frames are now exactly 64x128. `INP 1` /
`OUT 1` actually enable the display, and `INT`/`EF1` are gated on it.

**Glue.** `SC` was a `reg` with an initialiser while driven by the CPU's output
port, so the video saw a constant "DMA" state code. The keypad latch used a bit
test so it also latched on `OUT 3/6/7`, with a blocking assignment; `EF` indexed
the 10-bit player vectors with a 4-bit latch, reading past the end for keys
10-15.

**Build.** The `.qsf` was missing the `build_id.tcl` pre-flow hook, so synthesis
could not start. Four core-specific Quartus warnings were cleared (undriven
`cpu_din` and `LED_USER`, dead `mem_r`, a `casez` overlap). The SDL sim had never
built on macOS: unquoted `-CFLAGS`, missing SDL2/OpenGL2 ImGui backends, a
Verilator-4 `verilated_heavy.h`, a `NONE` macro colliding with
`VerilatedTraceSigDirection::NONE`, internal signals needing `rootp->`, and
`VGA_WIDTH` of 128 against a 64-pixel display — which is why it looked like
garbage.

---

## 12. Credit

Jason Coombes is the original author and primary contributor by far. He
created the original CDP1802 and CDP1861 Verilog, the keypad scheme, the memory 
map, and the initial Verilator harness. Flandango handled MiSTer framework 
integration and early Pixie work. This repo is an extension of their work and 
deeply depends on it.

Alan Steremberg and Elle Ball carried the later 2026 timing, video, 
controller/profile, and OSD work that brought the core to its current playable 
state. 

Recent accuracy refinement work heavily references the following projects:

| Who | What | How it was used here |
|-----|------|----------------------|
| **Paul Robson** | C Studio II emulator, `refs/studio2-games` (2013) | The frame-by-frame reference (§9). The ST2 loader and headless harness added there are extensions of his code. Also the homebrew test software. |
| **Curt Coder** / MAME | `cdp1861.cpp`, `studio2.cpp` (BSD-3-Clause) | Scanline windows, and the free-running DMA cadence (`2*8` start, `8*8` active, `6*8` wait) the BIOS ISR synchronises against. Without this the display cannot lock — it was the last blocker. |
| **Marcel van Tongeren** | Emma 02 | Independent second opinion; `tools/emma02.sh` unpacks it. Ships 38 `.st2` carts including an RCA test cartridge. |
| **Andrew Modla** | `ajavamind/rca-studio2` | CDP1802 DMA timing documentation. |
| **Eric Smith** | `brouhaha/cosmac` VHDL 1802 + Pixie (GPL-3) | The long-standing reference for a correct 1802; `rtl/cosmac.v` is its X-HDL translation. |
| **dmadole** | AVI1861 CPLD 1861 replacement | Cycle-exact hardware truth for 1861 sync/DMA. |
| **kanpapa** | `cosmac_mbc` | Secondary HDL reference. |

`docs/` is scraped from the classicgaming Studio 2 technical pages (via the
Internet Archive).

When changing timing or video, say which reference you matched against in the
commit message — MAME, Emma 02, rca-studio2 or AVI1861 (§8).
