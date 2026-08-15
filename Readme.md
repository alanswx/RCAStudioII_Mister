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

Not yet implemented: full **memory decode/mirroring**, and PAL.

## Installing

Copy a release from `releases/` to `/media/fat/_Console/` on your MiSTer.

The BIOS is **not** embedded. Load it from the OSD each boot:

| OSD slot | File | Loads at |
|----------|------|----------|
| `Load Bios` | `.rom` (2 KB, md5 `b37205bf19b197682f00619d05da194b`) | `$0000` |
| `Load Cartridge` | `.st2`, `.bin`, `.rom` | `.bin`/`.rom` flat at `$0400`; `.st2` paged per its header |

The core is held in reset until a BIOS is loaded.

## Controls

The Studio II has two 10-key keypads. The left one is player A (read through
`EF3`), the right is player B (`EF4`); software scans them by writing the key
number to `OUT 2` and testing the flags — see `docs/keyboard.txt`.

Each keypad is laid out on the host keyboard the way it sits on the console —
a 3x4 block — so the shapes match rather than the digits:

```
   Player A (left)        Player B (right)
    1  2  3                7  8  9
    Q  W  E                U  I  O
    A  S  D                J  K  L
       X                      ,
```

| Keypad key | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Player A** | `1` | `2` | `3` | `Q` | `W` | `E` | `A` | `S` | `D` | `X` |
| **Player B** | `7` | `8` | `9` | `U` | `I` | `O` | `J` | `K` | `L` | `,` |

**CLEAR** — the console reset button every manual asks for — is **F3**, or
**Clear** in the OSD.

With no cartridge, the five BIOS built-in games are selected with keys **1**–**5** on keyboard A — see below.

### Joystick

A gamepad works, but not through a fixed mapping. The Studio II has no joystick —
every game invents its own keypad controls — so Tennis moves the racquet on
**2/8** while using **4/5/6** to pick racquet *size*, and Space War fires on
keypad **A** but steers on keypad **B**. One mapping cannot serve both.

So the core takes a **CRC16 of the cartridge as it loads** and selects a profile
from a table in `rtl/rcastudioii.sv`. Joystick presses are OR'd with the
keyboard, so both work at once.

#### Profiles

| Profile | Up | Down | Left | Right | Fire | Extra |
|---------|----|------|------|-------|------|-------|
| `CROSS` | `2` | `8` | `4` | `6` | `5` | `0` |
| `PADDLE` | `2` | `8` | — | — | — | `0` pause |
| `SPACEWAR` | — | — | `B4` | `B6` | `A2` | — |
| `FREEWAY` | `A2` throttle | `A8` brake | `B4` | `B6` | — | — |
| `BOWLING` | `A2` hook | `A8` hook | — | — | `A5` roll | — |
| `BASEBALL` | `B2` curve | `B8` curve | — | — | `A5` bat / `B5` pitch | — |
| `HOMEBREW` | `2` | `8` | `4` | `6` | `B0` | — |
| `HB2P` | `2` | `8` | `4` | `6` | `0` (own pad) | — |

`CROSS` applies to both keypads (joystick 1 drives keypad B). Every mapping comes
from the RCA manuals, not guesswork.

`CROSS` is also, it turns out, the closest thing to an *official* mapping: the
Soundic **Victory Home TV Programmer** and Hanimex **Jeu TV Programmable** —
both MPT-02 Studio III machines — had detachable keypads that could be swapped
for joysticks, mapped exactly this way: cross on `2/4/6/8`, fire on `5`, and a
second button on `0`. That second button is the gamepad's **Extra**. It only
presses `0` where `0` is documented and harmless — `CROSS`, and `PADDLE` where
`0` pauses Tennis — never in `HOMEBREW`, where `A0` restarts Invaders; bind
B0/A0 directly if a game needs more. `HOMEBREW` is for Paul Robson's games, which
all fire or start on `0`; it is also 8-way — a held diagonal presses the corner
key (`1/3/7/9`), which is how Berzerk moves diagonally. Fire lands on `B0`, never
`A0`, because `A0` restarts Invaders. `HB2P` is the two-player variant (Hockey,
Combat): the plain cross plus fire-on-`0`, on each player's own pad. It is chosen
by CRC only — the OSD override list stops at `Homebrew`.

#### Which cartridges are mapped

| Cartridge | Profile | Start key |
|-----------|---------|-----------|
| TV Arcade I – Space War | `SPACEWAR` | `A1` |
| TV Arcade III – Tennis / Squash | `PADDLE` | `A2` (Tennis) |
| TV Arcade IV – Baseball | `BASEBALL` | `A0` |
| TV Arcade Series – Gunfighter / Moonship Battle | `CROSS` | `A1` |
| TV Arcade Series – Speedway / Tag (USA and Europe) | `CROSS` | `A1` |
| Star Wars | `CROSS` | `A1` |
| Pinball | `CROSS` | `A1` |

Paul Robson's homebrew games are mapped too — both the `.st2` and its flat
`.bin` conversion, which hash differently because the CRC covers the file as
downloaded:

| Homebrew | Profile | Start key |
|----------|---------|-----------|
| Asteroids, Berzerk | `HOMEBREW` | `A5` (starts each level) |
| Invaders, Kaboom, Pacman | `HOMEBREW` | `A0` |
| Scramble | `HOMEBREW` | `A6` (starts each level) |
| Hockey, Combat | `HB2P` | `A1` (game select) |

#### Which are deliberately *not* mapped

Ten cartridges fall through to the `CROSS` default. That is intentional for most
of them, and a joystick simply cannot express what they need:

**Number-entry games** — the input *is* a digit, so a four-way stick has nothing
sensible to say. Use the keypad:

- TV Arcade II – Fun with Numbers (3-digit guesses)
- TV Casino Series – Blackjack (bet `1`–`9`/`0`, hit `1`, double `2`, stand `0`)
- TV Casino Series – TV Bingo
- TV Mystic Series – Biorhythm (birth and start dates)
- TV School House I, and II – Math Fun (arithmetic answers)
- Concentration Match (grid squares chosen by number)

**Unidentified** — no manual and no confirmed controls, so any mapping would be
a guess:

- `86677b (Europe)`, `87201 (Europe)`, Demonstration Cartridge

These three are also the ones whose frames diverge from the reference emulator,
so treat them as untested rather than working.

#### Built-in games

There is no cartridge to CRC, so the five BIOS games are told apart by the key
that starts them — only the first such press after reset counts, since those keys
get reused during play (`A5` rolls the ball in Bowling):

| Game | Start | Profile |
|------|-------|---------|
| Doodles | `A1` | `CROSS` |
| Patterns | `A2` | `CROSS` |
| Freeway | `A3` | `FREEWAY` |
| Bowling | `A4` | `BOWLING` |
| Addition | `A5` | none — the answers are digits |

#### Overriding it

The table can only be as good as its entries, and an unknown cartridge falls back
to `CROSS`, which is a guess. So the OSD has a **Joystick** setting:

`Auto` (default) · `Cross` · `Paddle` · `Space War` · `Freeway` · `Bowling` · `Baseball` · `Homebrew` · `Gunfighter`

`Auto` uses the detection above; anything else forces that profile regardless of
the cartridge. Useful for the unmapped titles, for a homebrew `.st2` the table has
never seen, or simply if you prefer different controls.

#### Start, Select, and the Players setting

**Start** presses the cartridge's start key (the tables above; `A1` for anything
unknown, which is what most cartridges use). **Select** is **CLEAR**, the console
reset — every RCA manual begins "Press CLEAR".

The **Players** OSD setting decides which gamepad drives keypad B's half of the
profile. `1` runs everything from gamepad 0: `SPACEWAR`, `FREEWAY`, `BOWLING`,
`HOMEBREW`, and `GUNFIGHTER` all act as one-player layouts, with the single
stick steering or firing from one side. `2` gives each gamepad its own keypad,
so symmetric profiles like `CROSS`, `PADDLE`, `BASEBALL`, and `HB2P` split
across pads A and B exactly as the cartridge expects. `Auto` (default) keeps
the profile's natural arrangement: one-player layouts are treated as one-player,
while the symmetric layouts stay two-player.

#### Binding any key directly

The button list also carries **A0–A9** and **B0–B9** — all twenty keypad keys as
individual buttons, plus Select for CLEAR (21 inputs). None of them has a
default binding, so they are inert until you map one in *Define buttons*; after
that they work on top of whatever profile is active. This is the escape hatch
when a profile does not fit: bind exactly the keys the game wants to whatever
buttons you like, no keyboard needed.

#### On-screen keypad (analog sticks)

The OSD's **Stick Keypad** setting (`Off` · `Pad A` · `Pad B`) overlays the
Jaguar core's numstick, via the Coleco Adam: nudge the **right stick** for a
1–9 grid, the **left stick** for `0`, hold ~half a second and the key is
pressed. Presses land on the keypad the OSD names. The sticks belong to
gamepad 0, except that Pad B in a two-player game belongs to gamepad 1. It is
the slowest input, but reaches every key with no keyboard and no setup —
number-entry games included.

#### Adding a cartridge

```sh
tools/cart-crc.sh "software/carts/Some Game.bin"
```
then add one line to the `cart_crc` case in `rtl/rcastudioii.sv`.

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
| Speedway + Tag (Europe) | `1 2` | `2 4 6 8` | `2 4 6 8` |
| Star Wars (Europe) | `1 2 3` | `1 2 3` | `1 2 3` |
| TV Arcade I - Space War (USA) | `1 3` | `2` | — |
| TV Arcade II - Fun with Numbers (USA) | `1 2 3` | — | `1 2 3 4 5 6 7 8` |
| TV Arcade III - Tennis + Squash (USA) | `1 2` | — | `4 5 6` |
| TV Arcade IV - Baseball (USA) | `0` | — | `2 5 8` |
| TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe) | `1 2 3` | — | `2 5 8` |
| TV Arcade Series - Speedway + Tag (USA) | `1 2` | `2 4 6 8` | `2 4 6 8` |
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

Manuals are in `docs/` as PDFs and scan zips. Cartridges with **no** manual
available — Pinball, TV Bingo, Concentration Match, TV School House I and II,
and the unidentified `86677b`/`87201` — are only in the measured table above.

Every manual begins **"Press CLEAR"**. CLEAR is the Studio II's console reset
button (see `docs/RCA_Studio_II_Service_Manual.pdf`, Figure 1); press **F3**, or
use **Clear** in the OSD.

Movement is the keypad cross on both keyboards: **2** up, **8** down, **4**
left, **6** right, **5** fire.

#### Built-in games (no cartridge)

Five games live in the BIOS. From `docs/RCA_Studio_II_Service_Manual.pdf` (pages
7–8), which uses them as the console's self-test. Press **CLEAR** first, then:

| Game | Select | Controls |
|------|--------|----------|
| **Doodles** | A **1** | Keyboard B moves the dot per the arrows on the panel. **B5** leaves a trail as you "write"; **B0** leaves none. Retrace to erase. |
| **Patterns** | A **2** | Screen stays dark; keyboard B "writes" per the panel arrows. Memory holds 130 moves — after 130 the pattern auto-repeats, and for fewer, **B0** starts the repeat cycle. |
| **Freeway** | A **3** | **B4**/**B6** steer left/right, **A2** throttle, **A8** brake. Avoid the computer car for two minutes; distance travelled shows at the end. |
| **Bowling** | A **4** | **A5** rolls straight, **A2** hooks left (up), **A8** hooks right (down). Strike scores 20 (`ST-20`), spare 15 (`SP-15`). Player 2 then uses keyboard B. |
| **Addition** | A **5** | Add the three digits shown and press the total on either keyboard within five seconds. Faster answers score more, max 11 a set; a wrong answer locks you out of that set. 20 sets. |

These match what the core does: A2 correctly shows a dark screen, A1 puts a
single dot at the lower left, and A4/A5 draw the bowling and score displays.

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
- **Elle Ball** ([@meauxdal](https://github.com/meauxdal)) — the 3x4 keypad
  layout, so the host keys sit the way the console's keypads do (August 2026).
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
