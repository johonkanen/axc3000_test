#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# make_flash_images.sh [sof] - the flash files for the board's 32 MB QSPI
# configuration flash (Remote System Update layout, see
# zephyr_overlays/niosv_g_flash_layout.overlay for the whole map):
#
#   output_files/initial_image.jic   the whole RSU flash: BOOT_INFO, the
#       factory image (0x200000) and P1 (0x800000) both = this bitstream,
#       the SPT/CPB tables; P2 empty. Program once over JTAG:
#         quartus_pgm -c 1 -m jtag -o "pvi;output_files/initial_image.jic"
#       (this erases what the flash held; the MCUboot slots at 0x1000000+
#       are left as they were only if the programmer does not erase them)
#   output_files/application.rpd     this bitstream as an RSU application
#       image, for updating P1/P2 (over the UART, by the application)
#
# Default sof: output_files/niosv_zephyr.sof - built with MCUboot in ram0
# (build_all.sh), so the flash boots straight into MCUboot.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW="$HERE/.."
SOF="$(realpath "${1:-$HW/output_files/niosv_zephyr.sof}")"
OUT="$HW/output_files"
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$PATH"

sed -e "s|@SOF@|$SOF|g" -e "s|@OUT@|$OUT|g" "$HERE/initial_image.pfg.in" > "$OUT/initial_image.pfg"
quartus_pfg -c "$OUT/initial_image.pfg"
quartus_pfg -c "$SOF" "$OUT/application.rpd" -o mode=ASX4 -o bitswap=ON
ls -la "$OUT/initial_image.jic" "$OUT/initial_image_jic.map" "$OUT/application.rpd"
