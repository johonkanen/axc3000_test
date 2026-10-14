#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_mcuboot.sh [mcuboot elf] - put a rebuilt MCUboot into the compiled
# design's on-chip RAM contents without recompiling: elf2hex, overwrite the
# hex the ram0 IP was generated with, quartus_cdb --update_mif, quartus_asm.
# Minutes instead of a full build_all.sh. Needs a completed build_all.sh
# that baked MCUboot in (it did unless MCUBOOT_ELF= was empty).
# Then flash/make_flash_images.sh for the flash files.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
ELF="$(realpath "${1:-$HERE/../zephyr/build_mcuboot/zephyr/zephyr.elf}")"
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$PATH"
export QUARTUS_ROOTDIR="$HOME/altera_pro/26.1.1/quartus"

COPY=$(ls ip/niosv_zephyr_sys/niosv_zephyr_sys_ram0_*/intel_onchip_memory_*/synth/mcuboot.hex)
"$HOME/altera_pro/26.1.1/niosv/bin/elf2hex" -i "$ELF" -o output_files/mcuboot.hex \
    -b 0x0 -e 0x3FFFF -w 32 -r 4 --little-endian-mem
cp output_files/mcuboot.hex "$COPY"
quartus_cdb niosv_zephyr -c niosv_zephyr --update_mif
quartus_asm niosv_zephyr -c niosv_zephyr
echo "MCUboot from $ELF is in output_files/niosv_zephyr.sof"
