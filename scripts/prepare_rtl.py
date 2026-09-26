"""
Prepare rtl/ for the Game Bub framework build.

The framework build (build_core.py) compiles every file in rtl/, choosing the
file type by extension. This copies the needed NES_MiSTer sources from the
nes_mister submodule (pinned to a specific upstream commit), applies
nes_mister.patch, and renames files so their types are detected:
.vhd -> .vhdl, and .v -> .sv (Quartus accepts SystemVerilog syntax in .v
files, e.g. nes.v's package import).
The Game Bub glue logic and constraints are copied from hdl/.
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MISTER_DIR = ROOT / "nes_mister"
PATCH = ROOT / "nes_mister.patch"
HDL_DIR = ROOT / "hdl"
RTL_DIR = ROOT / "rtl"

# Sources used from NES_MiSTer.
MISTER_SOURCES = [
    "rtl/regs_savestates.sv",
    "rtl/ppu.sv",
    "rtl/nes.v",
    "rtl/apu.sv",
    "rtl/cart.sv",
    "rtl/cheatcodes.sv",
    "rtl/composite_board.sv",
    "rtl/EEPROM_24C0x.sv",
    "rtl/mappers/FDS.sv",
    "rtl/mappers/generic.sv",
    "rtl/mappers/JYCompany.sv",
    "rtl/mappers/Mapper99.sv",
    "rtl/mappers/misc.sv",
    "rtl/mappers/MMC1.sv",
    "rtl/mappers/MMC2.sv",
    "rtl/mappers/MMC3.sv",
    "rtl/mappers/MMC5.sv",
    "rtl/mappers/Namco.sv",
    "rtl/mappers/Sachen.sv",
    "rtl/mappers/Sunsoft.sv",
    "rtl/mappers/VRC.sv",
    "sys/iir_filter.v",
    # CPU and savestate infrastructure
    "rtl/bus_savestates.vhd",
    "rtl/t65/T65_Pack.vhd",
    "rtl/t65/T65_MCode.vhd",
    "rtl/t65/T65_ALU.vhd",
    "rtl/t65/T65.vhd",
    "rtl/savestates.vhd",
    "rtl/statemanager.vhd",
    # VM2413 (VRC7 audio)
    *[
        f"rtl/SOUND/OPLL/VM2413/{name}.vhd"
        for name in [
            "vm2413", "attacktable", "envelopememory", "feedbackmemory",
            "lineartable", "outputmemory", "phasememory", "registermemory",
            "sinetable", "voicerom", "voicememory", "slotcounter", "controller",
            "envelopegenerator", "phasegenerator", "operator",
            "outputgenerator", "temporalmixer", "opll",
        ]
    ],
    "rtl/SOUND/OPLL/eseopll.vhd",
]

RENAMES = {
    ".vhd": ".vhdl",
    ".v": ".sv",
}


def main() -> None:
    if not (MISTER_DIR / "rtl" / "nes.v").exists():
        sys.exit("NES_MiSTer sources not found: run `git submodule update --init`")

    if RTL_DIR.exists():
        shutil.rmtree(RTL_DIR)
    mister_out = RTL_DIR / "nes_mister"

    for rel in MISTER_SOURCES:
        (mister_out / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(MISTER_DIR / rel, mister_out / rel)
    subprocess.run(
        ["patch", "-p1", "--quiet", "-d", str(mister_out), "-i", str(PATCH)],
        check=True,
    )

    for path in list(mister_out.rglob("*")):
        if path.suffix in RENAMES:
            path.rename(path.with_suffix(RENAMES[path.suffix]))

    glue_out = RTL_DIR / "gamebub"
    glue_out.mkdir(parents=True)
    for path in HDL_DIR.iterdir():
        shutil.copy2(path, glue_out / path.name)

    num_files = sum(1 for p in RTL_DIR.rglob("*") if p.is_file())
    print(f"Prepared {num_files} files in {RTL_DIR}")


if __name__ == "__main__":
    main()
