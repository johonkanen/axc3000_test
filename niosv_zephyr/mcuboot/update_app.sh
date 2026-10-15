#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_app.sh <zephyr build dir> <version> [port] - update the running
# application over the 12 MBaud FTDI UART (BAUD=<rate> for a board still at
# another rate): sign the build as <version>
# (sign_app.sh), upload it through the running app's mcumgr (SMP) server -
# it goes into the slot that is not running - and reset. The reset
# reconfigures the FPGA from flash (zephyr_module), MCUboot comes back and
# RAM-loads the newer of the two slots. Needs an app with SMP (apps/smp_app).
#
# (When no valid app is in the flash, MCUboot itself waits in serial
# recovery and takes the same upload into slot 0.)
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${1:?usage: update_app.sh <build dir> <version> [port]}"
VERSION="${2:?usage: update_app.sh <build dir> <version> [port]}"
PORT="${3:-/dev/ttyUSB0}"
source "$HERE/../.venv/bin/activate"
# 4 lines of 4 KB per SMP frame: the app (UART_MCUMGR_RX_BUF_COUNT,
# MCUMGR_TRANSPORT_NETBUF_SIZE) and MCUboot (BOOT_LINE_BUFS,
# BOOT_SERIAL_MAX_RECEIVE_SIZE) are sized for it
SMP=(smpmgr --port "$PORT" --baudrate "${BAUD:-12000000}" --line-length 4096 --line-buffers 4 --timeout 30)

"$HERE/sign_app.sh" "$BUILD" "$VERSION"
"${SMP[@]}" image upload "$BUILD/zephyr/zephyr.signed.bin"
"${SMP[@]}" image state-read
"${SMP[@]}" os reset
echo "reset: MCUboot boots the newest image (expect $VERSION)"
