#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# download.sh - load an ELF onto the running Nios V/g over JTAG and run it,
#               without rebuilding/reflashing the .sof. The board must
#               already be configured with niosv_zephyr.sof (program it
#               once per hardware change with quartus_pgm, see README.md).
#
#   ./download.sh path/to/zephyr.elf
#   ./download.sh ../zephyr/build_hello/zephyr/zephyr.elf
#
# Console: juart-terminal (same JTAG cable, no extra setup).
# ---------------------------------------------------------------------------
set -euo pipefail

ELF="${1:?usage: download.sh <path-to-elf>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$HERE/gdb-wrapper:$HOME/altera_pro/26.1.1/niosv/bin:$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/linux64/oocd/openocd/bin:$PATH"

exec niosv-download --use_openocd --prefix riscv64-zephyr-elf --go --reset "$ELF"
