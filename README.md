# NES core for Game Bub

A port of [NES_MiSTer](https://github.com/MiSTer-devel/NES_MiSTer) to the
[Game Bub](https://gamebub.net/) handheld, built with the Game Bub framework
(firmware v1.1). It runs as an SD card core.

## Install

Requires a rev 4 device, and Game Bub firmware with SD card core support
(v1.1). Upstream v1.1.0-beta1 doesn't list SD card cores; use
[v1.1-beta-fork-rc1](https://github.com/danisla/gamebub/releases/tag/v1.1-beta-fork-rc1),
which is v1.1.0-beta1 with the fix.

Download the core zip from the [latest
release](https://github.com/danisla/gamebub-nes/releases/latest) and unzip it
into `/cores/` on the SD card. Or copy `core/NES/` to `/cores/NES/`, along
with the bitstream built for your device (`nes_rev4.bit`, see below). NES /
Famicom then appears in the core list. ROMs are `.nes` files; battery saves
are stored next to the ROM as `.sav`.

## Layout

* `nes_mister/`: NES_MiSTer, as a submodule (pinned).
* `nes_mister.patch`: compatibility fixes for Vivado, applied at build time.
* `hdl/`: Game Bub glue: wrapper (`nes_gamebub.sv`), SDRAM controller,
  constraints.
* `src/main/scala/nes/`: the Chisel core (clocks, host interface, video).
* `framework/`: the Game Bub framework (unmodified).
* `core/NES/`: SD card core definition (`core.json`, `files.json`,
  `settings.json`).

## Build

Requires Vivado (tested with 2026.1), Java, Python 3 and `patch`.

```
git submodule update --init
python3 scripts/prepare_rtl.py
./framework/mill root.buildCore --target gamebub_rev4
```

The bitstream is written to
`build/nes.HandheldNes-gamebub_rev4/nes.HandheldNes-gamebub_rev4.bit`.
Copy it to the SD card as `/cores/NES/nes_rev4.bit`.

## Not supported

FDS, NSF, PAL/Dendy, savestates, cheats, Zapper and other expansion devices.

## License

GPL-3.0 (see `LICENSE`), like NES_MiSTer. The framework in `framework/` is
licensed separately (see `framework/LICENSE`).
