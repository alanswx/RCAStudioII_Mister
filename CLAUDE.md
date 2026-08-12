# CLAUDE.md — RCA Studio II for MiSTer

Guidance for working in this repo. Read this before changing RTL.

---

## 1. What this is

A MiSTer FPGA core for the **RCA Studio II** (1977), an RCA CDP1802 ("COSMAC")
based console with CDP1861 "Pixie" video. The repo started from the MiSTer
template core, so `Readme.md` is still the *template's* readme — it describes
the framework, not this core. Ignore it.

**State of the core: early prototype.** It builds and puts a picture on screen,
but large parts of the machine are unimplemented or stubbed. See §6.

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
| `rtl/cdp1802.v` | The CPU **in use** — minimal, incomplete (§6.1) |
| `rtl/dpram.sv` | Dual-port block RAM |
| `rtl/pixie/pixie_video.v` | Thin wrapper |
| `rtl/pixie/pixie_video_studioii.v` | The video **in use** — a RAM scraper, not a 1861 (§6.2) |

### Files present but NOT compiled (dead / reference)
`rtl/cosmac.v`, `rtl/cdp1861.v`, `rtl/dma.v`, `rtl/keypad.v`, `rtl/debounce.v`,
`rtl/rom.v`, `rtl/beep.sv`, `rtl/pixie/pixie_video_old.v`,
`rtl/pixie/pixie_dp_*.v{,hdl}`, `rtl/reference/`.

`rtl/cosmac.v` is the important one: an X-HDL translation of Eric Smith's
`cosmac.vhdl`, a **complete and correct** 1802 with the full instruction set,
interrupts and DMA. It is instantiated only inside a comment block in
`rtl/rcastudioii.sv:186-203`. See §7.1.

### Clocks
`rtl/pll/pll_0002.v`: `outclk_0 = 7.040229 MHz` (`clk_sys`),
`outclk_1 = 42.241379 MHz` (`clk_vid`). 7.040229 = 4 × 1.760229 MHz.
`RCAStudioII.sv` divides `clk_sys` by 4 into `clk_1m76` — which
`rcastudioii.sv` then never uses.

---

## 4. Build & test

### Quartus
Quartus **17.0.x** only (MiSTer requirement). Project `RCAStudioII.qpf`.
Top entity is `sys_top` (from `sys/`). Not installed on this machine.

### Verilator sim (`verilator/`)
```sh
cd verilator && make          # builds obj_dir/Vtop, an ImGui/SDL2 sim
```
`verilator` 5.x and `sdl2` are installed via Homebrew here.

**The sim build is currently broken** — fix these first:
- `verilator/Makefile:59,62` — `\` followed by a TAB on the `cdp1861.v` and
  `dma.v` lines kills the line continuation → `commands commence before first
  target`.
- `verilator/sim.v:59-60` — `reg key_strobe;` then `wire key_strobe = …`,
  a duplicate declaration; verilator errors out.
- The `V_SRC` list names `cdp1861.v`, `dma.v`, `rom.v`, which are not part of
  the design and should be dropped to match `files.qip`.

Lint the design directly (this works today):
```sh
verilator --lint-only -Wall --top-module rcastudioii \
  rtl/rcastudioii.sv rtl/cdp1802.v rtl/dpram.sv \
  rtl/pixie/pixie_video_studioii.v rtl/pixie/pixie_video.v
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

Ordered by impact. File:line references are to the current tree.

### 6.1 CPU — `rtl/cdp1802.v`

**Interrupts and DMA do not exist.** `INTERRUPT`, `DMA_IN` and `DMA_OUT` states
are declared (`:95-97`) but nothing ever assigns them to `state_n` — the
transitions are commented out at `:174-181`. Their case bodies (`:199-211`,
`:359-414`) contain only commented-out reference code. Consequences:
- The 60 Hz ISR at `$001C` never runs.
- `IE` (`:82`) is never initialised or set; it is only ever cleared, in
  unreachable code.
- `SC` (`:59`) only ever takes `00` (fetch) and `01` (execute); the 1861 can
  never see a DMA or interrupt state code.
- `T` (`:114`) is written but never read back — `RET`/`SAV` need it.

**Missing / wrong instructions**, all falling through to the `default` arm at
`:257` (a harmless read of `M(R(X))`):
| Opcode | Mnemonic | Status |
|--------|----------|--------|
| `00` | `IDL` | decoded as `LDN R0` — wrong |
| `70` | `RET` | not implemented; flagged `unsupported` (`:291`). **Used by the BIOS ISR.** |
| `71` | `DIS` | not implemented |
| `78` | `SAV` | not implemented. **Used by the BIOS ISR.** |
| `79` | `MARK` | not implemented |
| `68` | (reserved on 1802) | decoded as `INP 0` and *writes* `M(R(X))` |

**`WAIT_N` polarity is inverted.** The header comment (`:29-33`) and the
datasheet both say Clear=1/Wait=1 → Run. The commit block at `:321` gates all
execution on `if (!WAIT_N && CLEAR_N)` — i.e. it runs only when `WAIT_N` is
*low*, which the same file calls "Pause". `rcastudioii.sv:147` hardwires
`WAIT_N = 1'b0`, so the CPU runs by accident. The `CLEAR_N && WAIT_N` arm at
`:421` is dead.

**Coding issues:**
- `:167,172,201,205,209` — non-blocking `<=` to `SC` inside a combinational
  `always @*`, and `SC` is not assigned on every path → inferred latch and
  sim/synth mismatch.
- `:231` — `always @(state, I, N)` has an incomplete sensitivity list; the block
  also reads `Rrd`, `P`, `X`, `ram_q`. Use `always @*`.
- `:85` — `state` is flopped both synchronously and asynchronously
  (verilator `SYNCASYNCNET`).
- `:196,343,360,388,418,422` — `$display` in synthesizable always blocks.
- Roughly a third of the file is commented-out VHDL/C++ transliterations.

**No cycle accuracy.** One `clk_sys` edge per state, so ~2 clocks per
instruction at 7.04 MHz ≈ 3.5 M instr/s, versus ~110 k instr/s on real
hardware — about **32× too fast**. `TPA`/`TPB` are commented out (`:132-148`,
`:75-76`) despite commit `98b800a` claiming to add them.

### 6.2 Video — `rtl/pixie/pixie_video_studioii.v`

**It is not a CDP1861.** It ignores the CPU entirely and continuously scrapes
`$0900-$09FF` into a private `frame_buffer[256]` (`:126-137`) over a second
dpram port. Consequences:
- `DMAO` is generated (`:99`) but the CPU cannot act on it, so no DMA-OUT cycles
  ever occur and the CPU never loses the ~35 % of machine cycles the real one
  spends on display DMA. Game timing is wrong even ignoring §6.1.
- The display base address is hardwired to `$0900` (`:56`) instead of following
  `R(0)`. Software that scrolls by adjusting R(0) — which `docs/cartridge.txt`
  explicitly calls out ("top of screen at `$0900+RB.0`") — will not scroll.
  Cartridges with a non-zero ST2 video flag cannot work at all.
- `SC_fetch`/`SC_execute`/`SC_dma`/`SC_interrupt` (`:107-113`) are set but never
  cleared, so all four latch high after the first few cycles. `DMA_xfer` is
  computed from `SC_dma` and then never used.

**Display enable is bypassed.** `rcastudioii.sv:67-68` hardwires
`.disp_on(1'b1), .disp_off(1'b0)`, so `INP 1` / `OUT 1` do nothing and the
display can never be turned off. The `io_n[0]` version is commented out
directly above.

**Sync generation is ad-hoc.** `HSync` is a hardcoded window at horizontal
counter 108–111 (`:300`); `VSync` at lines 252–262 (`:297`); `EFx` and `INT`
windows (`:294-295`) are approximations rather than the datasheet's 4-line
display-status pulses. `end_addr`, `hsync_pixel`, `vsync_line` are declared and
unused. Six `tmp_*` registers are dead.

### 6.3 System glue — `rtl/rcastudioii.sv`

- **No memory decode.** A single 4 KB dpram backs everything (`:232-244`).
  Address is truncated to `ram_a[11:0]`, ROM and RAM live in the same array, and
  the only protection is `cpu_wr` allowing writes in `$800-$9FF` (`:231`). The
  documented mirroring is not implemented; cartridge regions `$0A00-$0BFF` and
  `$0E00-$0FFF` are not decoded.
- **The cartridge loader ignores the ST2 format.** `:235` does
  `ioctl_addr[11:0] + 12'h0400`, a flat copy. `.st2` files load with their
  256-byte header at `$0400` and every block at the wrong page. Only raw `.bin`
  works — and the OSD only offers `F1,bin`, so `.st2` cannot even be selected.
- **No sound.** `Q` (`:137`) is unused; `rtl/beep.sv` is never instantiated;
  `RCAStudioII.sv:188-190` ties `AUDIO_L`/`AUDIO_R`/`AUDIO_S` to 0.
- `:93` — `keylatch = cpu_dout[3:0]` is a blocking assignment in a clocked
  block, and the qualifier `io_n[1] && io_out` is a bit test, so it also latches
  on `OUT 3`, `OUT 6`, `OUT 7`. Should be `io_n == 3'd2`.
- `:133` — `EF = {playerB[keylatch], playerA[keylatch], 1'b1, EFx}` indexes a
  10-bit vector with a 4-bit latch; keys `10-15` read out of range. `EF[1]`
  (EF2) is tied high, fine, but the whole expression needs a range guard.
- `:47` — `reg [1:0] SC = 2'b10;` gives an initial value to a net driven by a
  module output port.
- `:22-23` — `clk_1m76` and `clk_vid` are inputs that are never used.
- Keyboard mapping is PS/2 scancode only (`:102-124`); no joystick/gamepad
  support, no `Clear`/reset key, and the mapping is a straight `1-0` / `Q-P`
  row split rather than the 3×4 keypad layout MAME uses.
- ~120 of 337 lines are commented-out dead code.

### 6.4 Top level — `RCAStudioII.sv`

- `:202-203` — `VIDEO_ARX = 0; VIDEO_ARY = 0`. Should be 4:3, with the usual
  status-bit selector (the correct version is commented out immediately above).
- `:331-332` — `CLK_VIDEO = clk_vid` (42.24 MHz) with `CE_PIXEL = 1'b1`, but the
  pixie produces pixels and syncs in the 7.04 MHz `clk_sys` domain. `CE_PIXEL`
  must pulse once per real pixel on `CLK_VIDEO`. Either drive `CLK_VIDEO` from
  `clk_sys`, or generate a ÷6 pixel enable.
- `:266-279` — `clk_1m76` is assigned in an `always` block but declared `wire`
  at `:257`; it is also never consumed.
- No PAL support, no aspect/scanline options, no `Clear` button in the OSD.

### 6.5 Project hygiene
- `Readme.md` is still the MiSTer template readme.
- `RCAStudioII.sdc` has no core-specific constraints beyond `derive_pll_clocks`.
- `verilator/sim.vcd` (3.9 MB) is committed.
- `.gitignore` covers neither `refs/` nor `software/`.

---

## 7. Suggested roadmap

Do these in order; each one unblocks the next.

### 7.1 Replace the CPU with `rtl/cosmac.v`
Highest leverage change in the repo. `rtl/cosmac.v` already has the complete
instruction set, `IE`/`T`, interrupt and DMA state handling, and correct `SC`
encoding. Compare against `refs/cosmac-vhdl/cosmac.vhdl` (the upstream VHDL) —
the X-HDL translation needs review, particularly around `X`/`Z` literals in the
opcode `parameter`s, which do not mean "don't care" in Verilog comparisons.

Its bus is *not* 1802-pin-compatible: 1 clock per machine cycle, separate
`data_in`/`data_out`, non-multiplexed address. That is fine for us — just run it
from a machine-cycle clock enable rather than from `clk_sys` directly.

The commented-out instantiation at `rtl/rcastudioii.sv:186-203` is a starting
point but has `.int_req(INT_N)` wired to a signal that does not exist and
`.wait_req(wait_req)` undeclared.

### 7.2 Build a real CDP1861
Port `refs/cosmac-vhdl/pixie/` (front end / back end / frame buffer) — the
partial Verilog translations in `rtl/pixie/pixie_dp_*.v` are already there and
unused. Cross-check timing against `refs/AVI1861/pld/{frame,line}.pld` and
`mame/src/devices/video/cdp1861.cpp`.

The front end must assert `DMAO` and consume the bytes the *CPU* delivers during
DMA-OUT cycles, driven by `SC == 2'b10`. Delete the RAM-scraping path.

### 7.3 Machine-cycle timing
Run the CPU from a clock enable at 1.7897725 MHz ÷ 8 = 223.7 kHz machine cycles
(or divide `clk_sys`/32 for 220 kHz). Once DMA steals cycles, game speed should
fall into place. Validate against `refs/rca-studio2`, which documents its DMA
timing model.

### 7.4 Proper memory decode
Split ROM / cart / RAM into separate blocks with the documented mirroring, and
add the `$0A00-$0BFF` / `$0E00-$0FFF` cartridge windows.

### 7.5 ST2 cartridge loader
Parse the header during `ioctl_download`: read the block count at offset 4 and
the page table at 64-127, then write each 256-byte block to
`page[i] << 8`. Add `F1,st2,bin,rom` to `CONF_STR`. Reference implementations:
`refs/rca-studio2/Studio2/code/` and `refs/emma_02/src/`.

### 7.6 Sound
Wire `Q` to a tone generator. `rtl/beep.sv` exists; the authentic version is an
NE555 astable whose pitch decays ~50 % over 0.4 s after `Q` rises. MAME just
uses a fixed beeper — the decay is what makes it sound like a Studio II.

### 7.7 Fix the verilator sim, then keep it green
Fix `Makefile` / `sim.v` (§4), drop the non-design files from `V_SRC`, and add
a headless regression: run each cart in `software/carts/` for N frames and hash
the framebuffer. That is the only practical way to catch regressions without
Quartus.

### 7.8 Polish
Aspect ratio, `CE_PIXEL`, joystick mapping, PAL option, OSD reset, embedded
BIOS, and a real `Readme.md`.

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
