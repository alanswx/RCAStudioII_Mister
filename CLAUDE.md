# CLAUDE.md — RCA Studio II for MiSTer

Guidance for working in this repo. Read this before changing RTL.

---

## 1. What this is

A MiSTer FPGA core for the **RCA Studio II** (1977), an RCA CDP1802 ("COSMAC")
based console with CDP1861 "Pixie" video.

Originally written by **Jason Coombes** (JasonA-dev) from June 2022, with MiSTer
framework integration by **Flandango**. The 2026 interrupt/DMA/timing and video
work is by **Alan Steremberg**. Credit for the emulators and hardware references
this core is built and checked against is in §11 — read it before assuming any
timing number here was derived from first principles.

**State of the core: playable.** The CPU has the full instruction set the BIOS
needs, interrupts and DMA; the video is a real CDP1861 driven by DMA, not a RAM
scraper. Frames are **pixel-identical to the reference emulator on 18 of 21**
test cases (§9), and the core builds clean in Quartus with timing closed (§4).

What is still missing: **sound** (`Q` is unused), the **ST2 cartridge loader**
in RTL, proper **memory decode/mirroring**, and PAL. See §6.

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
| `RCAStudioII.sv` | MiSTer `emu` top: hps_io, PLL, OSD config string, video out |
| `rtl/rcastudioii.sv` | Core glue: CPU + pixie + RAM + keypad |
| `rtl/cdp1802.v` | The CPU: full BIOS instruction set, interrupts, DMA, machine-cycle timing |
| `rtl/dpram.sv` | Dual-port block RAM |
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
`outclk_1 = 42.241379 MHz` (`clk_vid`). 7.040229 = 4 × 1.760229 MHz.
`RCAStudioII.sv` divides `clk_sys` by 4 into `clk_1m76` — which
`rcastudioii.sv` then never uses.

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

Last known-good build: **0 errors**, timing closed (worst slack +0.423 ns),
19 % of ALMs, 7 % of block RAM, whole flow ~6 minutes.

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

### 6.1 No memory decode
A single 4 KB dpram backs everything. The address is truncated to `ram_a[11:0]`,
ROM and RAM share the array, and the only protection is `cpu_wr` allowing writes
in `$800-$9FF`. The documented mirroring is not implemented, and the cartridge
windows `$0A00-$0BFF`, `$0C00-$0DFF` and `$0E00-$0FFF` are not decoded.

### 6.2 Top level — `RCAStudioII.sv`
- `VIDEO_ARX`/`VIDEO_ARY` are 0; should be 4:3 with the usual status-bit
  selector (the correct version is commented out immediately above).
- `CLK_VIDEO = clk_vid` (42.24 MHz) with `CE_PIXEL = 1'b1`, but the 1861
  produces pixels in the 7.04 MHz `clk_sys` domain. `CE_PIXEL` must pulse once
  per real pixel, or `CLK_VIDEO` should come from `clk_sys`.
- `clk_1m76` is assigned in an `always` block but declared `wire`, and nothing
  consumes it. `rcastudioii.sv` still takes `clk_1m76`/`clk_vid` inputs it never
  uses.
- No PAL support, no aspect/scanline options, no `Clear` button in the OSD, and
  the BIOS is not embedded (the core is held in reset until one is loaded).

### 6.3 Keypad mapping
PS/2 scancode only, no joystick/gamepad support. The
mapping is a straight number-row / `P Q W E R T Y U I O` split rather than the
3x4 keypad layout MAME uses.

### 6.4 Minor
- `sys/` is shared framework code and must not be edited; the remaining Quartus
  warnings (unused SDRAM/SDIO pins, open-drain removal) all originate there and
  are present in every MiSTer core.
- `RCAStudioII.sdc` has no core-specific constraints beyond `derive_pll_clocks`.

---

## 7. Roadmap

### 7.1 Memory decode
Split ROM / cart / RAM with the documented mirroring and add the `$0A00-$0BFF`,
`$0C00-$0DFF` and `$0E00-$0FFF` cartridge windows.

### 7.2 Polish
Aspect ratio, `CE_PIXEL`, joystick mapping, PAL option, embedded BIOS.

### 7.3 Keep the comparison green
Any RTL change should be re-checked against the reference emulator (§9) before
committing. The regression is cheap — a few seconds per cartridge.

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

## 10. What changed (2026-08-12)

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

## 11. Credit where it is due

The core is Jason Coombes' (JasonA-dev, June 2022 - March 2025) — the first
CDP1802 and CDP1861 Verilog, the keypad, the memory map and the Verilator
harness. Flandango did the MiSTer framework integration and early Pixie work.
Everything in §10 is a modification of their design, not a rewrite from scratch:
the module boundaries, the `files.qip` layout and the sim structure are theirs.

The accuracy work depends entirely on other people's emulators:

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
