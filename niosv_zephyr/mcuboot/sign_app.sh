#!/usr/bin/env bash
# sign_app.sh <zephyr build dir> [version] - an MCUboot RAM-load image from
# an app built with mcuboot/app_ram_load.conf: <build>/zephyr/zephyr.signed.bin,
# loaded by MCUboot to 0x01000000 (the HyperRAM's code half). Key: MCUboot's
# development key (root-rsa-2048.pem) - replace it for anything real.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NZ="$HERE/.."
BUILD="$(realpath "${1:?usage: sign_app.sh <build dir> [version]}")"
VERSION="${2:-0.0.0+0}"
source "$NZ/.venv/bin/activate"
python3 "$NZ/zephyr/bootloader/mcuboot/scripts/imgtool.py" sign \
    --key "$NZ/zephyr/bootloader/mcuboot/root-rsa-2048.pem" \
    --header-size 0x200 --align 1 --slot-size 0x400000 \
    --load-addr 0x01000000 --version "$VERSION" \
    "$BUILD/zephyr/zephyr.bin" "$BUILD/zephyr/zephyr.signed.bin"
python3 "$NZ/zephyr/bootloader/mcuboot/scripts/imgtool.py" verify \
    --key "$NZ/zephyr/bootloader/mcuboot/root-rsa-2048.pem" "$BUILD/zephyr/zephyr.signed.bin"
