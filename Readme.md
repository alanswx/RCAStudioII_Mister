# RCA Studio II for MiSTer

A MiSTer FPGA core for the **RCA Studio II** (1977) — the RCA CDP1802
("COSMAC") based console with CDP1861 "Pixie" video.

![status](https://img.shields.io/badge/status-playable-brightgreen)

## Status

Playable. The CDP1802 has the full instruction set the BIOS needs, interrupts
and DMA, and runs at machine-cycle timing. The video is a real CDP1861. No frame buffer, 
fed by DMA through `R(0)` exactly as the hardware does.

The beeper and the RTL ST2 cartridge loader are both implemented and used in
practice. Output is **pixel-identical to a reference emulator on 18 of 21 test
frames**. The three that differ are memory/dice games whose BIOS-updated RNG
seed diverges, not rendering faults.

The address bus is decoded properly: ROM, cartridge and the 512 bytes of RAM are
separate, and the RAM mirrors appear where the hardware puts them.

Still missing: an embedded BIOS. (Not PAL — the Studio II was NTSC-only.)

## Installing

Copy a release from `releases/` to e.g. `/media/fat/_Console/` on your MiSTer.

Firmware is not embedded. Place the RCA Studio BIOS (2 KB, md5 
`b37205bf19b197682f00619d05da194b`) in `/media/fat/games/RCA-StudioII` (assuming SD 
card). Name it `boot.rom` to have it load automatically, or load it manually from 
the OSD. 

| OSD slot | File | Loads at |
|----------|------|----------|
| `Load Cartridge` | `.st2`, `.bin`, `.rom` | `.bin`/`.rom` at `$0400`; `.st2` paged by header |
| `Load Firmware` | `.bin`, `.rom` | `$0000` |


The core is held in reset until a BIOS is loaded.

## Controls

The Studio II has two 10-key keypads. In the official documentation, they are referred
to as "Keyboards". "Keypad" is used here to avoid confusion with the usual modern usage.
Keypad A is on the left (read through `EF3`), the right is keypad B (`EF4`); software 
scans them by writing the key number to `OUT 2` and testing the flags. See `docs/keyboard.txt`.

Each keypad is laid out to correspond with the existing jzIntv "[keyhack](https://forums.atariage.com/applications/core/interface/file/attachment.php?id=484005)" 
keypad-to-keyboard mapping. Seemed better to use this than invent a new one.

```
   Keypad A (left)        Keypad B (right)
    1  2  3                7  8  9
    Q  W  E                U  I  O
    A  S  D                J  K  L
       X                      ,
```

The original jzIntv keyhack layout this is based on can be seen here:  
![jzIntv keyhack.txt layout](https://media.invisioncic.com/r322239/monthly_01_2017/post-46336-0-51390500-1483262333_thumb.png).

In table form:

| Key | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Keypad A** | `1` | `2` | `3` | `Q` | `W` | `E` | `A` | `S` | `D` | `X` |
| **Keypad B** | `7` | `8` | `9` | `U` | `I` | `O` | `J` | `K` | `L` | `,` |

**CLEAR** is **F3**, or **Clear** in the OSD. Roughly equivalent to "reset" on other 
consoles. Select on the joystick is always Clear. 

The core attempts to maintain Pixie video timing to avoid television signal dropouts
during Clear events.

### Joystick

By default, keypad controls are dynamically mapped to gamepads on a per-game basis. The core 
takes a CRC16 of the cartridge as it loads and selects a profile from a table in 
`rtl/rcastudioii.sv`. Joystick and keyboard inputs accepted simultaneously.

#### Profiles

| Profile | Up | Down | Left | Right | Fire | Extra | Start | Select |
|---------|----|------|------|-------|------|-------|-------|--------|
| `CROSS` | `2` | `8` | `4` | `6` | `5` | `0` | `A1` / `A2` | `CLEAR` |
| `SPACEWAR` | — | — | `B4` | `B6` | `A2` | — | `A1` | `CLEAR` |
| `FREEWAY` | `A2` | `A8` | `B4` | `B6` | — | — | `A3` | `CLEAR` |
| `BOWLING` | `A2` | `A8` | — | — | `A5` | — | `A4` | `CLEAR` |
| `BASEBALL` | `B2` | `B8` | — | — | `A5` / `B5` | — | `A0` | `CLEAR` |
| `HOMEBREW` | `2` | `8` | `4` | `6` | `B0` | — | `A0` / `A5` / `A6` | `CLEAR` |
| `HB2P` | `2` | `8` | `4` | `6` | `0` | — | `A1` | `CLEAR` |
| `GUNFIGHTER` | `B2` | `B8` | `B4` | `B6` | `B5` | `B0` | `A1` | `CLEAR` |
| `8WAY` | `2` | `8` | `4` | `6` | `5` | `0` | `A1` | `CLEAR` |
| `DOODLES` | `B2` | `B8` | `B4` | `B6` | `B5` | `B0` | `A1` / `A2` | `CLEAR` |
| `PADDLE` | `B2` | `B8` | `B4` | `B6` | `B5` | — | `A1` | `CLEAR` |
| `CLEAR_ONLY` | — | — | — | — | — | — | — | `CLEAR` |
| `NONE` | — | — | — | — | — | — | `A1` | `CLEAR` |

`CROSS` is the standard 2/4/6/8 cross with fire on `5` and extra on `0`. It matches the official MPT-02 joystick layout and applies to both keypads.

`SPACEWAR`, `FREEWAY`, and `BOWLING` are asymmetric one-player layouts, with the relevant inputs split across keypad A/B as shown above. `BASEBALL` uses a bat on A and pitch/curve on B. 

`HOMEBREW` is Paul Robson’s 8-way layout; fire is on `B0`, and diagonals use `1/3/7/9` to match the corner keys. `HB2P` is the two-player homebrew variant with fire on `0` on each player’s own pad.

`GUNFIGHTER` is a full cross with fire on `5`; in one-player mode it collapses onto keypad B, while two-player mode splits across A and B. `8WAY` is `CROSS` plus diagonals (`1/3/7/9`). `DOODLES` uses the same idea but sends everything to keypad B only.

`PADDLE` is single-player and keypad-B-only. It maps racquet movement to `B2`/`B8`, and the left, Fire, and right buttons to the setup choices `B4`, `B5`, and `B6`, respectively.
`PADDLE` is single-player and keypad-B-only, for **Squash** on the TV Arcade III
cartridge. It maps racquet movement to `B2`/`B8`, and the left, Fire, and right
buttons to the setup choices `B4`, `B5`, and `B6`, respectively.

> **\* Tennis/Squash gives you Squash, not Tennis.** The cartridge holds both.
> Tennis is two-player and starts on `A2`; Squash is one-player and starts on
> `A1`. `PADDLE` is keypad-B-only and one-player, and Start presses `A1`, so a
> single gamepad plays **Squash** properly rather than half of Tennis. Use the
> keyboard (or two pads with `Mapping: Manual` and `Cross`) if you want Tennis.

`CLEAR_ONLY` leaves the gamepad's Select button available for **CLEAR**, but
disables all controller-driven keypad presses; keyboard, on-screen numstick, and
direct key bindings still work.

`NONE` is `CLEAR_ONLY` plus `A1` on Start. works well in conjunction with numstick 
so the game can be started using the Start button.

#### Which cartridges are mapped

Built-in BIOS games are detected by the first key pressed after reset:

| Game | Start | Profile |
|------|-------|---------|
| Doodles | `A1` | `DOODLES` |
| Patterns | `A2` | `DOODLES` |
| Bowling | `A4` | `BOWLING` |
| Freeway | `A3` | `FREEWAY` |
| Addition | `A5` | `CLEAR_ONLY` |

| Cartridge | Profile | Start key |
|-----------|---------|-----------|
| TV Arcade I – Space War | `SPACEWAR` | `A1` |
| TV Arcade III – Tennis / Squash | `PADDLE` | `A1` |
| TV Arcade IV – Baseball | `BASEBALL` | `A0` |
| TV Arcade Series – Gunfighter / Moonship Battle | `GUNFIGHTER` | `A1` |
| TV Arcade Series – Speedway / Tag | `CROSS` | `A1` |
| Star Wars | `CROSS` | `A1` |
| Pinball | `CROSS` | `A1` |

Paul Robson’s homebrew games are mapped too:

| Homebrew | Profile | Start key |
|----------|---------|-----------|
| Asteroids, Berzerk | `HOMEBREW` | `A5` |
| Invaders, Kaboom, Pacman | `HOMEBREW` | `A0` |
| Scramble | `HOMEBREW` | `A6` |
| Hockey, Combat | `HB2P` | `A1` |

Other entries may be populated here as they are confirmed mapped correctly:

| Homebrew | Profile | Start key |
|----------|---------|-----------|
| Flappy Pixel | `8WAY` | `A1` |

The following titles use `CLEAR_ONLY` because they require numerical input
rather than directional input. Use the keyboard, numstick, or manual mapping.

- TV Arcade II – Fun with Numbers
- TV Casino Series – Blackjack
- TV Casino Series – TV Bingo
- TV Mystic Series – Biorhythm
- TV School House I
- TV School House II – Math Fun
- Concentration Match

Demonstration Cartridge autoplays a short point-of-sale animation and doesn't
accept input other than Clear.

#### Mapping: Auto or Manual

On `Auto` the core automatically loads the mapping associated with the game, then
writes back the loaded profile it detected into the OSD menu. The Joystick option
will be grayed out but still updates to reflect your current profile.
On `Manual` you can select any mapping from the Joystick field.

#### Start, Select, and the Players setting

**Start** presses the cartridge’s start key from the table above. **Select** is the console’s **CLEAR** reset.

The **Players** setting decides which gamepad drives the B-side of a profile:

- `1` = gamepad 0 handles everything
- `2` = two-sided profiles split across the gamepads; profiles marked `1P` stay on gamepad 0
- `Auto` = use the profile’s default layout

| Profile | Default |
|---------|---------|
| `SPACEWAR` | `1P` |
| `FREEWAY` | `1P` |
| `BOWLING` | `1P` |
| `HOMEBREW` | `1P` |
| `CROSS` | `2P` |
| `BASEBALL` | `2P` |
| `HB2P` | `2P` |
| `GUNFIGHTER` | `1P` |
| `8WAY` | `1P` |
| `DOODLES` | `1P` |
| `PADDLE` | `1P` |
| `CLEAR_ONLY` | n/a |

The keyboard, on-screen numstick, and direct per-key bindings still work alongside the profile; a mapped joystick press and a pressed key can both act at once.

#### Binding any key directly

The button list also carries **A0–A9** and **B0–B9** — all twenty keypad keys as
individual buttons, plus Select for CLEAR (21 inputs). None of them has a
default binding, so they are inert until you map one in *Define buttons*; after
that they work on top of whatever profile is active. 

It isn't recommended to map both the automap buttons and the keys manually as it 
seems to cause potential issues, but it hasn't been exhaustively tested, so YMMV.

#### On-screen keypad (analog sticks)

The OSD's **Stick Keypad** setting (`Off` · `Pad A` · `Pad B`) overlays the
Jaguar core's numstick, via the Coleco Adam: nudge the **right stick** for a
1–9 grid, the **left stick** for `0`, hold ~half a second and the key is
pressed. Nudge the right stick and release for `5`. 

When using the 2 players option, each player's numstick affects their respective 
keypad.

#### Adding a cartridge

Use
```sh
tools/cart-crc.sh "software/carts/Some Game.bin"
```
to generate the hash to be used in the `cart_crc` case in `rtl/rcastudioii.sv`.

### Per-cartridge

"Starts with" is the key that first puts something on screen; 
"responds to" lists keys that demonstrably change the game state afterwards.

Each cartridge was run in the simulator and every key tried; see 
`tools/probe-keys.sh`. Further corrections have been made manually.

| Cartridge | Starts with | Keypad A responds to | Keypad B responds to |
|-----------|-------------|----------------------|----------------------|
| Concentration Match (Europe) | `any` | `1 2 3 4 5 6 7 8 9` | `1 2 3 4 5 6 7 8` |
| Demonstration Cartridge (USA) | — | — | — |
| Pinball (Europe) | `1 2` | — | `1` |
| Speedway + Tag (Europe) | `1 2` | `2 4 6 8` | `2 4 6 8` |
| Star Wars (Europe) | `1 2 3` | `1 2 3` | `1 2 3` |
| TV Arcade I - Space War (USA) | `1 3` | `2` | — |
| TV Arcade II - Fun with Numbers (USA) | `1 2 3` | — | `1 2 3 4 5 6 7 8` |
| TV Arcade III - Tennis + Squash (USA) | `1 2` | — | `4 5 6` |
| TV Arcade IV - Baseball (USA) | `0` | `5` | `2 5 8` |
| TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe) | `1 2 3` | `2 4 5 6 8` | `2 4 5 6 8` |
| TV Arcade Series - Speedway + Tag (USA) | `1 2` | `2 4 6 8` | `2 4 6 8` |
| TV Casino Series - Blackjack (USA) | `1 2` | — | `0` |
| TV Casino Series - TV Bingo (USA, Europe) | `1 2` | `1` | — |
| TV Mystic Series - Biorhythm (USA, Europe) | `0` | — | `1 2 3 4 5 6 7 8 0` |
| TV School House I (USA) | `any` | `1 2 3 4 5 6 7 8 9` | — |
| TV School House II - Math Fun (USA, Europe) | `1 2` | `1 2 3 4 5` | — |

### How to play

Instructions below are from the original RCA manuals — the text ones at
[Digit Press](https://www.digitpress.com/library/manuals/rcastudio2/index.html)
and the scanned ones in `docs/*.zip`.

Manuals are in `docs/` as PDFs and scan zips.

#### Resident games (no cartridge)

Five games are resident in the RCA Studio II BIOS ROM image.

| Game | Select | Controls |
|------|--------|----------|
| **Doodles** | **A1** | Keyboard B moves the dot per the arrows on the panel. **B5** leaves a trail as you "write"; **B0** leaves none. Retrace to erase. |
| **Patterns** | **A2** | Screen stays dark; keyboard B "writes" per the panel arrows. Memory holds 130 moves — after 130 the pattern auto-repeats, and for fewer, **B0** starts the repeat cycle. |
| **Bowling** | **A3** | **A5** rolls straight, **A2** hooks left (up), **A8** hooks right (down). Strike scores 20 (`ST-20`), spare 15 (`SP-15`). Player 2 then uses keyboard B. |
| **Freeway** | **A4** | **B4**/**B6** steer left/right, **A2** throttle, **A8** brake. Avoid the computer car for two minutes; distance travelled shows at the end. |
| **Addition** | **A5** | Add the three digits shown and press the total on either keyboard within five seconds. Faster answers score more, max 11 a set; a wrong answer locks you out of that set. 20 sets. |

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

#### Star Wars

**CLEAR**, then on keyboard A: **1** one player, **2** two players, **3**
advanced one player (the computer scores automatically once it has escaped).
Then answer `SPEED 1 2 3?` — **1** slow, **2** medium, **3** fast. In one-player
games use keyboard A; in two-player either keyboard may pick the speed, and
whichever one does starts as the chaser.

Steer with **2/4/6/8** on your own keyboard. The catch is that the mapping
**inverts with your role**: when you are being chased (you are the small ship)
**2** is up, **8** down, **4** left, **6** right; when you are the pursuer (you
are the viewfinder) **2** moves the enemy *down*, **8** up, **4** right, **6**
left. First to destroy nine ships wins.

#### TV Arcade II — Fun with Numbers

**CLEAR**, then key **1** on keyboard A. A Mastermind variant: the computer picks
a secret 3-digit number and you get 20 guesses, entered **on keyboard B**.

Turns left show at the lower left, your guess right-of-centre, and the clue at
the lower right — briefly, so read it quickly. Clues total 000–006: `000` no
digit correct, `001` a digit correct but misplaced, `002` one correct and placed
(or two correct but both misplaced), `006` you got it. Digits can repeat, and
`0` counts.

#### TV Mystic Series — Biorhythm

**CLEAR**, then key **0** on keyboard A. Enter the birth date on keyboard B,
then the start date on keyboard B.

#### TV Casino Series — Blackjack

Key **1** for one player, **2** for two. One player uses keyboard B; two players
use both.

When **BET** appears, press **1**–**9** to bet $1–$9, or **0** for $10. When
**CUT** appears, **0** cuts the deck. In play: **1** hits (up to five extra
cards), **2** doubles — double the bet, exactly one more card — and **0** stands.

Dealer draws on 16 or less and stands on 17, except a soft 17. A natural
blackjack pays 2 to 1, an ordinary win 1 to 1, a tie returns your bet.

## Accuracy

Checked against captures of real hardware in `refvideo/`:

- **Speed** — beep length is a CPU-timed loop, so it measures CPU speed directly.
  Real hardware's Star Wars beeps are 115–130 ms; this core's are 117 ms.
- **Beeper pitch** — 547 Hz, measured from the spectrum of a direct capture
  (545–549 Hz across every beep) rather than taken from the hardware notes,
  whose component values do not give a sane frequency.
- Frames are pixel-identical to a reference emulator on 18 of 21 test cases.

## Known issues

- Analog and direct video don't work.

Note: Studio II was not released in PAL territories. PAL implementation is tied to
Studio III (color) implementation (this work is ongoing).

## Building

Quartus **17.0.x** only. If you do not have it installed, the build runs in the
`raetro/quartus:mister` container:

```sh
tools/quartus-build.sh          # full build -> output_files/RCAStudioII.rbf
tools/quartus-build.sh map      # analysis & synthesis only
tools/quartus-build.sh clean
```

Last known-good build: **0 errors**, 10,003 ALMs (24 %), 444 kbit of block RAM (8 %), timing closed with +0.710 ns worst-case slack.

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
  from the classicgaming Studio 2 technical pages, scanned cartridge manuals
  (`*.zip`), and the RCA Model 18V100 service manual, which has the console
  block diagram, the CLEAR button and the clock-adjustment procedure.

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
  reference-emulator comparison harness; and the 2026 timing/video work that
  brought the core to its current playable state (August 2026).
- **Elle Ball** ([@meauxdal](https://github.com/meauxdal)) — profile automapping 
  work, hash table refactor, logical 3x4 keypad layout, OSD layout and logic 
  tuning, extensive software testing (August 2026).

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
- **ubersaurus** — invaluable insights, documentation, rare archives and more.

## Licence

GPL-2.0-or-later; see the file headers. Note `rtl/cosmac.v` and
`rtl/reference/cosmac.vhdl` are Eric Smith's GPL-3.0 code — compatible with
"GPL-2-or-later", but any release containing them is effectively GPL-3. They are
reference only and are not compiled into the core.
