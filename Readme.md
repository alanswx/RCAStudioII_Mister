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

Not yet implemented: **sound**, the **CLEAR key** (every cartridge manual starts
"Press CLEAR" — it is the Studio II's hardware reset), the **`.st2` cartridge
loader** (raw `.bin` only), full **memory decode/mirroring**, and PAL.

## Installing

Copy a release from `releases/` to `/media/fat/_Console/` on your MiSTer.

The BIOS is **not** embedded. Load it from the OSD each boot:

| OSD slot | File | Loads at |
|----------|------|----------|
| `Load Bios` | `.rom` (2 KB, md5 `b37205bf19b197682f00619d05da194b`) | `$0000` |
| `Load Cartridge` | `.bin` (512 or 1024 bytes) | `$0400` |

The core is held in reset until a BIOS is loaded.

## Controls

The Studio II has two 10-key keypads. The left one is player A (read through
`EF3`), the right is player B (`EF4`); software scans them by writing the key
number to `OUT 2` and testing the flags — see `docs/keyboard.txt`.

| | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Player A** | `0` | `1` | `2` | `3` | `4` | `5` | `6` | `7` | `8` | `9` |
| **Player B** | `P` | `Q` | `W` | `E` | `R` | `T` | `Y` | `U` | `I` | `O` |

With no cartridge the BIOS built-in games start on **3**, **4** or **5**.

### Per-cartridge

Original RCA manuals are not included with the dumps, so the table below is
**measured, not documented**: each cartridge was run in the simulator and every
key tried. "Starts with" is the key that first puts something on screen;
"responds to" lists keys that demonstrably change the game state afterwards. It
tells you which keys are live, **not what they do** — that would need the
manuals, and guessing would be worse than saying so.

Regenerate it with `tools/probe-keys.sh`.

| Cartridge | Starts with | Player A responds to | Player B responds to |
|-----------|-------------|----------------------|----------------------|
| 86677b (Europe) | `any` | — | — |
| 87201 (Europe) | `any` | — | — |
| Concentration Match (Europe) | `any` | `1 2 3 4 5 6 7 8 9` | `1 2 3 4 5 6 7 8` |
| Demonstration Cartridge (USA) | `any` | — | — |
| Pinball (Europe) | `1 2` | — | `1` |
| Speedway + Tag (Europe) | `1 2` | `2 4 8` | `2 4 8` |
| Star Wars (Europe) | `1 2 3` | `1 2 3` | `1 2 3` |
| TV Arcade I - Space War (USA) | `1 3` | `2` | — |
| TV Arcade II - Fun with Numbers (USA) | `1 2 3` | — | `1 2 3 4 5 6 7 8` |
| TV Arcade III - Tennis + Squash (USA) | `1 2` | — | `4 5 6` |
| TV Arcade IV - Baseball (USA) | `0` | — | `2 5 8` |
| TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe) | `1 2 3` | — | `2 5 8` |
| TV Arcade Series - Speedway + Tag (USA) | `1 2` | `2 4 8` | `2 4 8` |
| TV Casino Series - Blackjack (USA) | `1 2` | — | `0` |
| TV Casino Series - TV Bingo (USA, Europe) | `1 2` | `1` | — |
| TV Mystic Series - Biorhythm (USA, Europe) | `0` | — | `1 2 3 4 5 6 7 8 0` |
| TV School House I (USA) | `any` | `1 2 3 4 5 6 7 8 9` | — |
| TV School House II - Math Fun (USA, Europe) | `1 2` | `1 2 3 4 5` | — |

Notes on the measurements:

- `any` means the cartridge draws regardless of which key is pressed — these are
  demos or menu-driven titles rather than games with a start button.
- A dash means no key changed the outcome in the window tested. That can mean
  the title genuinely ignores that keypad, or that it needs a longer or
  different input sequence than the probe used.
- `86677b`, `87201` and `Demonstration Cartridge` show no response on either
  keypad; the first two are also the cartridges whose frames differ from the
  reference emulator (see below), so treat them as untested rather than working.

### How to play

Instructions below are from the original RCA manuals — the text ones at
[Digit Press](https://www.digitpress.com/library/manuals/rcastudio2/index.html)
and the scanned ones in `docs/*.zip`. Nothing here is guessed.

Scans for **Fun with Numbers, Math Fun, Biorhythm and Star Wars** are in `docs/`
but are not written up yet; consult them directly, or use the measured table
above.

All four manuals begin **"Press CLEAR"**. CLEAR is the Studio II's hardware
reset — this core does not implement it yet (see Known gaps), so use the OSD
reset or restart the core instead.

Movement is the keypad cross on both keyboards: **2** up, **8** down, **4**
left, **6** right, **5** fire.

#### TV Arcade III — Tennis / Squash

| | |
|---|---|
| **Tennis** (2 players) | Keyboard A key **2** |
| **Squash** (1 player) | Keyboard A key **1** |

Setup, in order: each player picks racquet size on their own keyboard —
**4** small, **5** medium, **6** large — then player A picks ball speed:
**7** slow, **8** normal, **9** fast.

In play: **2** moves your racquet up, **8** down. **0** pauses and resumes.
First to 21, winning by two; if tied at 21 play continues until someone leads
by two or reaches 200. Squash ends at 200.

#### Speedway / Tag

| | |
|---|---|
| **Speedway** | Keyboard A key **1** |
| **Tag** | Keyboard A key **2** |

Both games, both keyboards: **2** up, **8** down, **4** left, **6** right.

*Speedway* — two players race nine laps. Hitting a wall or the other car slows
you down; first to nine laps wins. *Tag* — 10 points a tag, and whoever is "it"
swaps after each tag or after about ten seconds. Players wrap around the screen
edges, so keep moving. Winner is whoever leads after two minutes, or first to
300. Player A is a dash, player B an asterisk.

#### TV Arcade Series — Gunfighter / Moonship Battle

| | |
|---|---|
| **Gunfighter** | key **1** one player, **2** two players |
| **Moonship Battle** | key **3** |

*Gunfighter* — **2** up, **8** down, **5** fires. A quick tap fires one fast
bullet; holding it fires two slower ones. The cactus gives cover, but you have
to leave it to shoot. Two minutes, most hits wins. In two-player, keyboard A is
the left gunfighter and B the right.

*Moonship Battle* — move with the direction keys, fire with **5**. Your rocket
always fires in the direction you last moved. Each ship starts with 100 energy
units: 1 per 10 positions moved, 1 to fire, 5 for being hit or colliding. The
game ends when a ship runs out of energy.

#### TV Arcade I — Space War

Two games. **CLEAR**, then:

| | |
|---|---|
| **Horizontal Intercept** | Keyboard A key **1** |
| **Vertical Intercept** (1–2 players) | key **3** |

*Horizontal Intercept* — spaceships fly across at various heights and speeds.
Fire with **2** on keyboard A; steer the rocket with **4** (left) and **6**
(right) on keyboard B. You get 20 rockets; rockets remaining show at the lower
left, score at the lower right.

*Vertical Intercept* — an enemy ship moves vertically at screen centre, trying
to reach the top marker; after eight touches the game ends. Each player fires
from their own launcher with key **3** on their keyboard, scoring 10 a hit. A
hit reverses the ship's direction, so hitting it on the way up prolongs the
game. Holding the fire key versus tapping it changes the missile's trajectory.

#### TV Arcade IV — Baseball

**CLEAR**, then key **0**. Player A bats first, player B pitches, and the
keyboards **swap roles between the top and bottom of each inning**.

| Role | Keys |
|------|------|
| Batter | **5** swings |
| Pitcher | **5** straight, **2** inside curve, **8** outside curve |

For a change-up (slow pitch), hold the pitch key about ¼ second before
releasing. You cannot see the difference between a straight ball and a curve,
but curves are harder to hit well — and if the batter doesn't swing, a curve is
more likely to be called a ball, a straight pitch a strike. The computer calls
balls and strikes. Hit type shows in the lower left: `F` foul, `1` single,
`2` double, `3` triple, `H` home run, `W` walk, `O` out.

#### TV Casino Series — Blackjack

Key **1** for one player, **2** for two. One player uses keyboard B; two players
use both.

When **BET** appears, press **1**–**9** to bet $1–$9, or **0** for $10. When
**CUT** appears, **0** cuts the deck. In play: **1** hits (up to five extra
cards), **2** doubles — double the bet, exactly one more card — and **0** stands.

Dealer draws on 16 or less and stands on 17, except a soft 17. A natural
blackjack pays 2 to 1, an ordinary win 1 to 1, a tie returns your bet.

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
