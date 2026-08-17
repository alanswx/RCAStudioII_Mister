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

### 2.0 PAL is *not* a prerequisite — it belongs to the CDP1864

An earlier draft of this plan (and `CLAUDE.md` §7.1 before it) had "add PAL"
as step zero, gating everything else. **That was wrong, and checking the
documentation is what caught it.**

There was no PAL Studio II. The CDP1861 is an NTSC part with no PAL mode
anywhere: MAME's `cdp1861.h` hard-codes `TOTAL_SCANLINES = 262` and mentions
neither PAL nor 312 nor 50 Hz; Emma 02 ships four Studio II configs
(`standard`, `multicart`, `chip8`, `test-cartridge`) and **not one of them is
PAL**; the AVI1861 hardware replacement has no PAL either. Adding a "PAL Studio
II" would be inventing a machine — and because Studio II games time themselves
off the 60 Hz interrupt, a 50 Hz mode would also slow every one of them by 17%.
MiSTer's scaler already handles PAL *displays* without touching core timing.

PAL arrives **with the CDP1864**, where it is native rather than optional — the
part is literally titled "COS/MOS PAL Compatible Color TV Interface" and MAME's
`cdp1864.h` hard-codes `TOTAL_SCANLINES = 312`. So PAL is not a step; it is part
of §2.1, and §2.1 is no longer blocked by anything.

It is per machine, not a global toggle:

| Machine | Field rate |
|---|---|
| Studio II | NTSC only |
| Studio III | **both** — Emma has paired `*-ntsc.xml` / `*-pal.xml` for every variant, and separate `studio3_ntsc.bin` / `studio3_pal.bin` |
| Soundic Victory MPT-02, Hanimex, Mustang 9016, Sheen M1200, Academy Apollo 80, Trevi M1200 | PAL |
| **Conic M-1200** | **NTSC** — the one NTSC badge in an otherwise PAL family |

Open questions to settle during §2.1 rather than guess at now:

- MAME models the 1864 as PAL-only, but Emma models an NTSC Studio III and an
  NTSC Conic M-1200. Different part, different crystal, or just a different
  config? Nobody's notes here say.
- The 1864 has **192 visible lines** against the 1861's 128, yet the MPT-02 runs
  Studio II software that only ever fills 32 rows. What the extra window does in
  practice is a bring-up question for the test cartridge.
- MAME's `SCANLINE_DISPLAY_START = 60; // ???` is flagged uncertain *by MAME*.
  Do not treat it as gospel; check it against the datasheet timing pages and the
  RCA test cartridge.

### 2.1 MPT-02 / Victory family — the big unlock

**Six machines for one implementation.** Needs:

| Piece | Effort | Notes |
|---|---|---|
| CDP1864 video | the bulk of it | Replaces the 1861. Same `INT`/`DMA_OUT`/`EFx` contract to the CPU, so our DMA and interrupt plumbing is unchanged |
| Colour output | moderate | Our chain is 1bpp mono (`video` → white). The 1864 fetches R/G/B from colour RAM per DMA byte; the mixer path has to widen |
| Memory map | small | ROM `$0000-$07FF`, RAM `$0800-$09FF`, **colour RAM 64 cells mirrored across `$0B00-$0BFF`** (§6), **ROM `$0C00-$0FFF`**. Our decode already handles `$0C00-$0DFF` as cart-or-mirror and 512 bytes mirrored across a wide window, so this is an extension of work already done |
| CDP1864 tone | small | The 1864 has its own tone generator; the 555 beeper goes away |
| PAL | see 2.0 | |

References: `refs/rca-studio2/Documents/cdp1864.pdf` (datasheet — distilled into
§6) and MAME's `src/devices/sound/cdp1864.cpp`. Note MAME files it under
*sound* — it is a combined video+sound part.

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

### Porting Emma's 1864 into Robson — the wrong donor, technically

**Licensing is not the blocker.** Emma's headers carry a non-commercial clause
(and the repo ships a contradictory `agpl-3.0.txt`), but the harness is a local
debugging artefact that is never distributed: GPL obligations attach to
distribution, private modification is explicitly permitted, and a hobby core is
not a "commercial application". `refs/` is git-ignored, so none of it can reach
the repo by accident. If the harness ever *is* released, revisit this.

The real blocker is that **there is no CDP1864 in Emma to take.** It is not a
module — there is no `cdp1864.cpp`, and no `Pixie1864` class. The 1864 is
configuration state (`CDP1864Configuration`) threaded through the generic
`Pixie` class alongside the 1861 and 1862, driven by XML, and `Pixie` is:

- 1,682 lines, inheriting `Video : public wxFrame`
- 40 calls into the `p_Main` global and **81** into `p_Computer`

So "port Emma's 1864" means lifting the generic Pixie, its XML configuration
machinery, and two application-wide singletons. Compare MAME's `cdp1864.cpp`:
638 self-contained lines with exactly the interface we need
(`int_cb`, `dma_out_cb`, `efx_cb`, `rdata/bdata/gdata_cb`).

**Emma is still useful here, as data rather than code.** Its XML machine configs
are a port spec with no extraction problem at all —
`refs/emma_02/data/Xml/Conic/soundic_victory_mpt-02.xml` gives the MPT-02's tone
port (`OUT 4`, agreeing with MAME's `mpt02_io_map`), the full RGB palette
including the four background colours, and the colour RAM range. Use it to
cross-check the port.

The apparent Emma-vs-MAME disagreement over the colour RAM range turned out not
to be one — see §6.

### What to do instead: MAME's 1864 into Robson

| | Licence | Size | Fit |
|---|---|---|---|
| MAME `cdp1864.cpp`/`.h` | BSD-3-Clause (Curt Coder) | **638 self-contained lines** | Clean device interface; the same authority we already matched the 1861 against |
| Robson `studio2/` | MIT | 2,524 lines, no deps | Already extended with our `headless.c`; video is `CPU_GetScreenMemoryAddress()` into emulated RAM — the same DMA-reads-RAM model as the RTL |

Chosen on extractability, not licence — though it happens that both are
permissive, which keeps the option of releasing the harness open. Task #11.

**State this caveat with any accuracy claim.** If both the RTL and the reference
emulator derive from MAME's 1864, the comparison verifies *"the RTL matches our
C port of MAME"*, not that the model is independently right. It still catches
RTL timing, DMA and state-machine bugs — which is most of what the harness has
ever actually caught — but it is a weaker claim than the Studio II 18/21, where
Robson's emulator was written independently of MAME. Emma 02 stays as the
independent second opinion for eyeball checks; `tools/emma02.sh` already unpacks
it for that.

---

## 6. CDP1864 spec, from the datasheet

`refs/rca-studio2/Documents/cdp1864.pdf` is a scan with no text layer — render it
before searching: `pdftoppm -r 150 -jpeg cdp1864.pdf out`. Page 5 (sheet 89) is
the functional description of the terminals and answers most design questions.
**Settle conflicts here first**, rather than picking between emulators.

### Chip-level facts

| | |
|---|---|
| Part | "COS/MOS **PAL Compatible** Color TV Interface" — PAL is native, not an afterthought |
| Clock | **1.75 MHz** crystal (matches MAME's `1.75_MHz_XTAL` for both CPU and CTI) |
| Colour | Programmable **1-of-8 dot colours** plus **1-of-4 background colours** |
| Resolution | Bit-mapped, max **192 vertical × 64 horizontal** |
| `INLACE` | high = 625 lines/frame interlaced; low = **312 lines/frame non-interlaced** |
| Tone | 256 tones, **107 Hz – 13672 Hz**, from a programmable divider |
| `BURST` | 4.57 µs pulse on each h-sync back porch (blanked for 24 lines during v-sync) |
| `ALT` | toggles at each h-sync, driving PAL phase alternation |

### The port map, straight from the datasheet

- **`N0`** with `MRD`+`TPB` steps the background colour, and `N0·TPB` enables
  INTERRUPT and DMA. The datasheet spells out the opcodes: "a **61** instruction
  would step the background color, and a **61 or 69** instruction would enable
  the INTERRUPT and DMA requests."
- **`N2`** with `MRD`+`TPB` loads the tone-generator latch, and disables INT/DMA:
  "a **64** instruction would result in data being loaded into the tone-divider
  latch, while a **6C** instruction would disable the INTERRUPT and DMA requests."

So `OUT 4` is the tone latch and `OUT 1` steps the background — which is what
both MAME's `mpt02_io_map` and Emma's `soundic_victory_mpt-02.xml`
(`<out type="tone">4</out>`) already say. Three sources agree.

- **`EF`** emits two pulses per field, each four horizontal lines wide: one
  starting four lines before the display, one four lines before it ends. That is
  the same shape as the 1861's `EF1`, so **our existing EF model carries over**.
- **`CON` (Color On)** is "connected to the gated `MWR` signal of the color
  memory" — writing to colour RAM is what switches colour on. MAME fakes this
  with `m_cti->con_w(0); // HACK` on every DMA; worth doing properly.
- **`RDATA`/`GDATA`/`BDATA`** "carry color information from the color RAM…
  latched concurrent with the latching of the luminance information from the
  data bus during the display interval". Colour is fetched **in parallel with
  each DMA luminance byte**, not on a separate pass.

### The colour RAM range: not a conflict

Emma declares `0xb00-0xbff`, MAME maps `0x0b00-0x0b3f`. The datasheet does not
adjudicate, because colour RAM size is a *board* choice, not a chip one — the
"typical color system" figure just shows a CDP1822 (256×4) as the colour map.

MAME's DMA handler shows what the MPT-02 board actually does:

```c
uint8_t addr = ((offset & 0xe0) >> 2) | (offset & 0x07);   // = {offset[7:5], offset[2:0]}
m_color = m_color_ram[addr];
```

A **6-bit index — 64 distinct cells.** With 8 bytes per 64-pixel row and 32
rows, `offset[2:0]` is the column and `offset[7:3]` the row; MAME keeps only
`offset[7:5]`, so colour is one cell per **8 columns × 4-row group**.

That makes the two descriptions the same hardware: 64 bytes of storage inside a
decoded window of one page, i.e. **mirrored four times across `$0B00-$0BFF`** —
exactly the window-versus-storage distinction we just implemented for the Studio
II's 512 bytes of RAM (CLAUDE.md §10, 2026-08-15). Emma names the window, MAME
names the storage. Implement 64 cells, mirror them across the page, and both are
satisfied.

### Method note

This is the general rule for the successor work: where two emulators disagree,
go to `refs/rca-studio2/Documents/`, `docs/rca-technical/` and the datasheets
before choosing. Every conflict hit so far — open bus `$00` vs `$FF`, the keypad
strobe, the built-in game order, and this one — was settled by paper, and in two
cases the paper contradicted what the RTL already did.
