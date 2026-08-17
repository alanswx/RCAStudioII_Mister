# `tools/refemu` — the reference emulator the RTL is checked against

Paul Robson's C emulator for the RCA Studio II, vendored into this repo, plus
the headless front end and loaders added for this project. This is what
`tools/compare-game.sh` diffs the RTL against, and it is the basis of every
accuracy claim in `CLAUDE.md` §9.

```sh
cd tools/refemu && make headless      # -> ./studio2_headless, links libc only
./studio2_headless --help
```

## Why it is vendored rather than left in `refs/`

It used to live only in `refs/rca-studio2/studio2-games/studio2/`, which is
git-ignored — and inside that checkout it was **untracked**, on a clone whose
remote is upstream's (`ajavamind/rca-studio2`) and therefore not pushable. So
the harness behind every accuracy number in this project existed as loose files
on one machine: one `git clean -xfd`, one re-clone or one disk failure from
being gone. It is small (~2,500 lines, 172 KB) and MIT licensed, so the fix is
to keep it next to the RTL it validates. `refs/` stays ignored.

## Licence and provenance

**MIT**, © 2016 paulscottrobson — see `LICENSE`, copied from the upstream repo
(`github.com/paulscottrobson/studio2-games`). Note upstream's caveat: the MIT
grant covers the new work only, not the asmx assembler, the TVOut Arduino
library, the Studio 2 ROM images or the RCA databooks that also live in that
repository.

**One exception, deliberately kept:** `studio2_rom.h` is the RCA Studio II BIOS
as a C array (`_studio2[2048]`), which `cpu.c` copies into memory at reset. It is
RCA's code, *not* covered by the MIT grant above. It is here because `cpu.c` will
not compile without it, and because the same 2 KB is already tracked in this repo
as `rom/studio2.rom` — so vendoring it adds no exposure that did not already
exist. The harness overrides it from a file via `--bios` anyway.

Upstream's other three ROM headers (`studio2.h`, `studio2_bios.h`,
`studio2_game.h`) are the same bytes again in different slices and nothing
includes them, so they are **not** vendored.

Upstream also carries the homebrew games with full 1802 assembly source. Those
are *not* copied here — they stay in `refs/studio2-games/`, since they are test
material rather than harness.

## What was added for this project

Not upstream's work; written here and kept in this copy:

- `headless.c` — the whole batch front end. No SDL: it supplies `main()` and the
  `IF_*` stubs, so the headless build links against libc alone. Screenshot
  capture (PNG/PPM/ASCII), state dumps, an instruction trace, scripted
  keypresses, and the `--frames`/`--shot` options that let it be diffed against
  the Verilator sim.
- The ST2 paged-cartridge loader in `cpu.c`, matching the RTL loader in
  `rtl/rcastudioii.sv`.
- The `headless` target in `makefile`.

## Keeping it honest

The vendored copy was verified byte-identical to the `refs/` original across all
18 retail cartridges before being committed. If it is ever re-synced from
upstream, do that check again — `tools/compare-game.sh` is only meaningful if
this binary behaves the way the recorded scores were measured with.

The CDP1864 colour support described below arrived that way — see
`docs/succession-plan.md` §5 and §6.

## CDP1864 colour machines (`--machine mpt02`)

Added here so the §9 comparison does not go dark when the RTL gains a CDP1864.
Ported from MAME's `cdp1864` (BSD-3-Clause) and Emma 02's machine XML, both
cross-checked against the datasheet — see `docs/succession-plan.md` §6.

```sh
./studio2_headless --machine mpt02 \
  --bios ../../refs/emma_02/data/StudioIII/studio3_pal.bin \
  --frames 260 --press a1@40:20 --shot 250 --ascii \
  ../../refs/emma_02/data/St2/Conic_StudioIII-Cartridges/pinball.st2
```

What `--machine mpt02` changes:

| | Studio II | MPT-02 / Studio III |
|---|---|---|
| Frame | 262 lines, 60 Hz, 128 display | **312 lines, 50 Hz, 192 display** |
| CPU cycles between interrupts | 1876 | **1680** |
| Rows shown | 4× | **6×** (32 × 6 = 192) |
| Display off | `OUT 1` | **`INP 4`** — `OUT 1` steps the background |
| Tone | 555 beeper, gated by Q | `OUT 4` tone latch (not synthesised here) |
| Colour RAM | — | 64 cells behind `$0B00-$0BFF` |

`--bios` is new and is **required** for `mpt02`: this program carries the Studio II
BIOS embedded, and a Studio III cartridge on it draws nothing. The Studio III
image is 4 KB and covers both of that machine's ROM regions (`$0000-$07FF` and
`$0C00-$0FFF`), so the loader steps over the RAM and colour RAM in between.

### Three things measurement settled

- **Use the PAL BIOS.** `studio3_pal.bin` and `victory.rom` run properly;
  `studio3_ntsc.bin` and `studio3.rom` do not — with PAL timing they get as far
  as 175 writes and stall, against 5017 for the PAL image. That is real evidence
  that the NTSC Studio III is a different timing configuration and not merely a
  different ROM, which was an open question in the plan. NTSC support here needs
  its own frame timing, not just `--bios`.
- **64 colour cells is right.** The PAL BIOS writes `$0B00-$0BFF` exactly **64**
  times during init — the number the MAME-derived `{off[7:5], off[2:0]}` index
  implies, arrived at independently.
- **Rows are shown 6×.** Emma's MPT-02 config gives display lines 76 to 267
  inclusive, which is exactly 192, and 192 / 32 logical rows = 6. So the logical
  framebuffer stays 64×32 and only the vertical scale changes.

### State

Working: 12 of the 14 Conic/Studio III cartridges draw, 6 of them in colour
(`pinball` renders a recognisable table — blue field, yellow border and digits,
green and red bumpers, magenta targets, cyan lanes). `baseball` and `biorhythm`
come up blank, almost certainly because they start on a different key rather
than anything to do with the port — the Studio II table has Baseball on `A0`.

Not done: the tone generator is swallowed rather than synthesised, since the
harness only ever diffs frames; NTSC colour machines need their own timing as
above; and none of this is validated against a second emulator yet, which is
what Emma 02 is for.
