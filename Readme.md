# RCA Studio II for MiSTer

A MiSTer FPGA core for the **RCA Studio II** (1977) — the RCA CDP1802
("COSMAC") based console with CDP1861 "Pixie" video.

![status](https://img.shields.io/badge/status-playable-brightgreen)

## Status

Playable. The CDP1802 has the full instruction set the BIOS needs, interrupts
and DMA, and runs at true machine-cycle timing. The video is a real CDP1861 —
no frame buffer, fed by DMA through `R(0)` exactly as the hardware does.

Output is **pixel-identical to a reference emulator on 18 of 21 test frames**.
The three that differ are memory/dice games whose BIOS-updated RNG seed
diverges, not rendering faults.

Not yet implemented: **sound**, the **`.st2` cartridge loader** (raw `.bin`
only), full **memory decode/mirroring**, and PAL.

## Installing

Copy a release from `releases/` to `/media/fat/_Console/` on your MiSTer.

The BIOS is **not** embedded. Load it from the OSD each boot:

| OSD slot | File | Loads at |
|----------|------|----------|
| `Load Bios` | `.rom` (2 KB, md5 `b37205bf19b197682f00619d05da194b`) | `$0000` |
| `Load Cartridge` | `.bin` (512 or 1024 bytes) | `$0400` |

The core is held in reset until a BIOS is loaded.

## Controls

The Studio II has two 10-key keypads.

| | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Player A** | `0` | `1` | `2` | `3` | `4` | `5` | `6` | `7` | `8` | `9` |
| **Player B** | `P` | `Q` | `W` | `E` | `R` | `T` | `Y` | `U` | `I` | `O` |

With no cartridge the BIOS built-in games start on **3**, **4** or **5**. Most
cartridges start on **1** or **2**.

## Building

Quartus **17.0.x** only. If you do not have it installed, the build runs in the
`raetro/quartus:mister` container:

```sh
tools/quartus-build.sh          # full build -> output_files/RCAStudioII.rbf
tools/quartus-build.sh map      # analysis & synthesis only
tools/quartus-build.sh clean
```

Resource use is modest: 19 % of ALMs, 7 % of block RAM, 3 of 6 PLLs, timing
closed with +0.423 ns worst-case slack.

## Simulators

Two Verilator sims live in `verilator/` — an interactive SDL/ImGui one and a
headless one used for regression testing. Both take the same options.

```sh
cd verilator
make            # interactive -> ./obj_dir/Vtop
make headless   # batch       -> ./obj_dir_headless/Vtop

./obj_dir/Vtop --cart "../software/carts/TV Arcade I - Space War (USA).bin" --press a1@40:30
./obj_dir_headless/Vtop --frames 200 --press a5@40:20 --shot 200 --ascii
```

`--press KEY@FRAME[:HOLD]` scripts a keypress; `KEY` is `0`-`9`, optionally
prefixed `a`/`b` to pick the keypad. The headless sim also does PNG capture,
CPU instruction tracing and VRAM dumps — see `--help`.

## Documentation

- `CLAUDE.md` — the working document: hardware reference the RTL must match,
  source layout, build notes, remaining defects, roadmap, and how the core is
  verified against a reference emulator.
- `docs/` — hardware notes (memory map, I/O, video, cartridge format) scraped
  from the classicgaming Studio 2 technical pages.

## Credits

### Core

- **Jason Coombes** ([@JasonA-dev](https://github.com/JasonA-dev)) — original
  author and by far the largest contributor. Created the core in June 2022 and
  developed it through March 2025: the first CDP1802 and CDP1861 Verilog, the
  keypad, the memory map and the Verilator simulation harness this work builds
  on.
- **Flandango** ([@Flandango](https://github.com/Flandango)) — MiSTer framework
  compatibility and early Pixie video work (September 2022).
- **Alan Steremberg** ([@alanswx](https://github.com/alanswx)) — 1802
  interrupts, DMA and machine-cycle timing; the DMA-driven CDP1861; the
  reference-emulator comparison harness (August 2026).

### Emulators and hardware references

This core would not be correct without other people's work. In particular:

- **Paul Robson** — his C Studio II emulator (`refs/studio2-games`, 2013) is the
  reference the RTL is checked against frame by frame, and the source of the
  homebrew test software. The ST2 loader and headless harness added for this
  project are extensions of his emulator.
- **Curt Coder** and the **MAME team** — MAME's `cdp1861` device and `studio2`
  driver (BSD-3-Clause). The 1861's scanline windows and, critically, the
  free-running DMA cadence the BIOS interrupt routine synchronises against were
  taken from `cdp1861.cpp`; without it the display could not lock.
- **Marcel van Tongeren** ([Emma 02](https://www.emma02.hobby-site.com/)) — the
  definitive CDP1802 multi-system emulator, used as an independent second
  opinion, and the source of a large `.st2` test corpus.
- **Andrew Modla** ([@ajavamind](https://github.com/ajavamind)) — `rca-studio2`,
  documenting precise CDP1802 DMA timing.
- **Eric Smith** ([@brouhaha](https://github.com/brouhaha)) — his GPL-3 COSMAC
  VHDL 1802 and Pixie implementation, long the reference for a correct 1802.
- **dmadole** — AVI1861, a CPLD drop-in replacement for the 1861, useful as
  cycle-exact hardware truth.
- **kanpapa** — `cosmac_mbc`, a COSMAC MicroBoard with Pixie video.
- The **classicgaming Studio 2 technical pages** (via the Internet Archive), the
  source of everything in `docs/`.

## Licence

GPL-2.0-or-later; see the file headers. Note `rtl/cosmac.v` and
`rtl/reference/cosmac.vhdl` are Eric Smith's GPL-3.0 code — compatible with
"GPL-2-or-later", but any release containing them is effectively GPL-3. They are
reference only and are not compiled into the core.
