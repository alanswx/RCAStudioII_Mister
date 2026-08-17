# Where this core goes next — the COSMAC machine succession

Written 2026-08-17. Companion to `CLAUDE.md` §7 (Roadmap). This is about which
*machines* to add after the Studio II, in what order, and what software we
already hold to test each one with.

The short version: **the CPU-side contract does not change.** MAME drives the
CDP1864 with the same three signals our CDP1861 already produces — `INT`,
`DMA_OUT`, `EFx` — into the same 1802 inputs. Every successor below reuses the
1802, the DMA-driven video model, the cartridge loader, the keypad scanning and
the profile system. What changes is the video chip, the memory map, and colour.
That makes these much cheaper than "a new core" suggests.

---

## 1. The lineage

```
  FRED / FRED II / FRED III        1971-75   Weisbecker prototypes, pre-silicon
        |
  RCA Studio II                    1977      <-- this core. CDP1861, mono, NTSC
        |
        +-- Toshiba Visicom COM-100  1978    Japan. Colour, own memory map
        |
        +-- RCA Studio III           1978    CDP1864: colour + tone, PAL & NTSC
        |        |
        |        +-- Soundic Victory MPT-02        (Austria)
        |        +-- Hanimex MPT-02                (France)
        |        +-- Mustang 9016 Telespiel        (Germany)
        |        +-- Sheen M1200 Micro Computer    (Australia)
        |        +-- Conic M-1200
        |        +-- Academy Apollo 80             (Germany)
        |
        +-- RCA Studio IV            1977    Prototype. Colour, 192-line mode
        |
  RCA COSMAC VIP                     1977    Sibling, not successor: same
                                             CDP1861, CHIP-8 in ROM
```

MAME puts Studio II, Visicom and the six MPT-02 badges in **one driver**
(`src/mame/rca/studio2.cpp`), which is the strongest signal about how close
they are. The six MPT-02 badges are one implementation — build the machine
once and six entries light up.

---

## 2. Order of work, cheapest useful first

### 2.0 PAL (prerequisite, already on the roadmap)

Not a new machine, but it gates two of them: Studio III shipped in PAL, and the
MPT-02 badges were European and Australian. We already hold `studio3_pal.bin`
and PAL builds of Studio IV and Studio 2020. Doing PAL first means the successor
work is not blocked on it later. This is `CLAUDE.md` §7.1 and stays first.

### 2.1 MPT-02 / Victory family — the big unlock

**Six machines for one implementation.** Needs:

| Piece | Effort | Notes |
|---|---|---|
| CDP1864 video | the bulk of it | Replaces the 1861. Same `INT`/`DMA_OUT`/`EFx` contract to the CPU, so our DMA and interrupt plumbing is unchanged |
| Colour output | moderate | Our chain is 1bpp mono (`video` → white). The 1864 fetches R/G/B from colour RAM per DMA byte; the mixer path has to widen |
| Memory map | small | ROM `$0000-$07FF`, RAM `$0800-$09FF`, **colour RAM `$0B00-$0B3F`**, **ROM `$0C00-$0FFF`**. Our decode already handles `$0C00-$0DFF` as cart-or-mirror, so this is an extension of work already done |
| CDP1864 tone | small | The 1864 has its own tone generator; the 555 beeper goes away |
| PAL | see 2.0 | |

References: `refs/rca-studio2/Documents/cdp1864.pdf` (datasheet) and MAME's
`src/devices/sound/cdp1864.cpp`. Note MAME files it under *sound* — it is a
combined video+sound part.

Pleasing continuity: our `CROSS` joystick profile is already the MPT-02
joystick layout (cross on 2/4/6/8, fire 5, second button 0), taken from the
MPT-02's own swappable controller. The controller work is done before the
machine arrives.

### 2.2 Visicom COM-100

Toshiba's Japanese variant. Smaller than MPT-02 but a genuinely different
memory map, so it does not fall out of 2.1 for free:

```
$0000-$07FF  ROM          $1000-$10FF  RAM
$0800-$0FFF  cartridge    $1100-$11FF  colour RAM 0
                          $1300-$13FF  colour RAM 1
```

Two colour planes rather than the 1864's palette. **No ST2 support** — MAME
notes this explicitly, so the cartridge loader needs a raw path.

### 2.3 Studio III proper

The RCA-badged CDP1864 machine the MPT-02s derive from. Once 2.1 exists this is
close to a BIOS swap plus whatever differences the test cartridge exposes. We
hold `studio3_ntsc.bin` and `studio3_pal.bin`.

### 2.4 Studio IV (prototype)

Now unusually well-documented for us, because the technical archive turned up
**Weisbecker's own typed I/O spec** (`docs/rca-technical/Studio II III IV/
IMG_0353.JPG`, 7-20-77) — see `CLAUDE.md` §2.1. It gives the whole port map:
`61` tone, `62` key select, `63` output port, `64` TV control (RGB background,
spot map, TV on/off, **192-vs-128 lines**), `65` DMA-out, `6B` input port, and
"TV off after reset". Plus his colour-chip sketch (`IMG_1535.JPG`).

Software here is BASIC/system images rather than cartridges, so it is a
different kind of target — closer to a computer than a console.

### 2.5 COSMAC VIP — sibling, and the biggest software payoff

Not a successor, but worth ranking because it **reuses our CDP1861 unchanged**.
It is a single-board computer: hex keypad, cassette, CHIP-8 interpreter in ROM.
The video is already built. Against that, it needs a keypad/cassette UI that
has nothing to do with the console work, and CHIP-8 emulators are abundant, so
the novelty is lower even though the file count is enormous.

---

## 3. Software we already hold

### Studio II — very well covered (this core)

| Set | Count | Where |
|---|---|---|
| No-Intro retail `.bin` | 18 | `software/carts/` |
| Public domain, committed | 48 | `pd_software/` |
| TOSEC `.st2` / `.bin` | 8 / 6 | `software/tosec/` |
| Paul Robson homebrew, **with asm source** | 8 | `refs/studio2-games/Games/` |
| Emma 02: cartridges / homebrew / Sarnoff | 11 / 15 / 7 | `refs/emma_02/data/St2/StudioII-*` |

### Studio III / MPT-02 family — enough to develop against

| Set | Count | Where |
|---|---|---|
| Conic/Studio III cartridges | 14 | `refs/emma_02/data/St2/Conic_StudioIII-Cartridges/` |
| Conic/Studio III homebrew | 1 | `.../Conic_StudioIII-Homebrew/` |
| Conic/Studio III Sarnoff Collection | 4 | `.../Conic_StudioIII-Sarnoff-Collection/` |
| BIOS: `studio3_ntsc.bin`, `studio3_pal.bin`, `chip8.bin` | 6 | `refs/emma_02/data/StudioIII/` |
| BIOS: `victory.rom`, `studio3.rom` | 5 | `refs/emma_02/data/Victory/` |
| **`RCA_TEST_CARTRIDGE_TESTER1.st2`** | 1 | `refs/emma_02/data/StudioIII/` — a real test cartridge, the best possible bring-up target |

The Conic set is the same catalogue as the Studio II one (pinball, speedway,
spacewar, tennis, star-wars, baseball…) rebuilt for colour, so **the same game
can be diffed across both machines** — a strong accuracy check that does not
exist for any other target here.

### Visicom

| Set | Count | Where |
|---|---|---|
| Cartridges | 6 | `refs/emma_02/data/St2/Visicom-Cartridges/` |
| BIOS `visicom.rom` | 1 | `refs/emma_02/data/Visicom/` |

### Studio IV / Studio 2020

| Set | Count | Where |
|---|---|---|
| Studio IV V2/V3 NTSC+PAL, `am4kbas` BASIC, super-chip | 12 | `refs/emma_02/data/StudioIV/` |
| Studio 2020 NTSC + PAL | 2 | `refs/emma_02/data/Studio2020/` |

### Adjacent, if the family is ever widened

| Machine | Count | Where |
|---|---|---|
| COSMAC VIP programs | 47 | `refs/emma_02/data/Vip/` (+7 VipII) |
| CHIP-8 / SCHIP programs | 410 | `refs/emma_02/data/Chip-8/` |
| FRED I / I.5 | 78 | `refs/emma_02/data/FRED1*/` |
| Coin Arcade (`.arc`, `.fd2`) | 11 | `refs/emma_02/data/CoinArcade/` |

Everything under `refs/` and `software/` is git-ignored; `pd_software/` is the
only set committed to the repo.

---

## 4. What to settle before starting

- **How to expose multiple machines.** One core with a machine selector, or
  separate `.rbf` per machine? Affects the OSD, the config string, and how the
  BIOS is chosen. Decide before writing the 1864, not after.
- **Colour in the video chain.** Widening past 1bpp touches `video_mixer` setup
  and the sim's frame grabber and ASCII output, which currently assume one bit
  per pixel. The §9 comparison harness needs a colour-aware mode or the whole
  regression stops working for the new machines.
- **What the reference emulator becomes.** Settled — see §5.

---

## 5. The reference emulator: extend Robson, don't adopt Emma 02

The §9 comparison diffs against Paul Robson's C Studio II emulator, which knows
nothing about the CDP1864 — so the harness goes dark exactly when the colour
machines arrive. Two obvious ideas, both investigated 2026-08-17, both rejected:

### Making Emma 02 the harness — no

Not an effort question. Emma's emulation is structurally welded to wxWidgets:

```
class Video : public wxFrame        // the video emulation IS a GUI window
class Pixie : public Video
void Video::drawPoint(wxCoord x, wxCoord y) { gc->DrawRectangle(x,y,0,0); }
```

Every pixel is painted straight into a wx device context. **There is no
framebuffer array to read back** — nothing to capture, hash or diff without
replacing the drawing substrate across 183 files and 135k lines. The entry point
is `IMPLEMENT_APP(Emu1802)` on `wxApp`; the `wxCmdLineParser` in there is
argument parsing inside the GUI, not a batch mode. And `Cdp1802 : public
IoDevice, public Memory, public Sound` means the CPU inherits memory and sound,
so a single machine does not lift out cleanly either.

### Porting Emma's code into Robson — blocked, and the wrong donor

Emma's file headers, on both Marcel van Tongeren's code and Michael H Riley's
1802:

> *This software may not be used in commercial applications without express
> written permission from the author.*

A non-commercial clause is an **additional restriction, which the GPL forbids**,
so it cannot be combined into this GPL-2-or-later project. The repo also ships
`agpl-3.0.txt`, which contradicts the headers — a real ambiguity that would need
Marcel's clarification. Do not assume the AGPL file governs.

### What to do instead: MAME's 1864 into Robson

| | Licence | Size | Fit |
|---|---|---|---|
| MAME `cdp1864.cpp`/`.h` | **BSD-3-Clause** (Curt Coder) | 638 lines | The same authority we already matched the 1861 against |
| Robson `studio2/` | **MIT** | 2,524 lines, no deps | Already extended with our `headless.c`; video is `CPU_GetScreenMemoryAddress()` into emulated RAM — the same DMA-reads-RAM model as the RTL |

Both permissive, both compatible, and the donor is the source our 1861 timing
already came from. Task #11.

**State this caveat with any accuracy claim.** If both the RTL and the reference
emulator derive from MAME's 1864, the comparison verifies *"the RTL matches our
C port of MAME"*, not that the model is independently right. It still catches
RTL timing, DMA and state-machine bugs — which is most of what the harness has
ever actually caught — but it is a weaker claim than the Studio II 18/21, where
Robson's emulator was written independently of MAME. Emma 02 stays as the
independent second opinion for eyeball checks; `tools/emma02.sh` already unpacks
it for that.
