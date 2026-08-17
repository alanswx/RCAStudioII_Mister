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

Planned next: a CDP1864 port from MAME (BSD-3-Clause) so the colour machines
have a reference too — see `docs/succession-plan.md` §5 and task #11.
