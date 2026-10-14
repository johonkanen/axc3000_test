# niosv_zephyr - build, flash and update guide

Nios V/g + Zephyr on the Arrow AXC3000 (Agilex 3 `A3CY100BM16AE7S`): the
application runs from the onboard HyperRAM, the board boots from its QSPI
configuration flash, and software is updated over the FTDI serial port
(4.8 MBaud).

## Status (2026-10-14)

| What | Status |
|---|---|
| Hardware build (Nios V/g 120 MHz, HyperRAM, 4.8 MBaud UART, SDM mailbox) | works |
| Boot from flash: SDM -> bitstream -> MCUboot -> app from flash into HyperRAM | works, hardware-verified after power cycle |
| **App update over serial** (`mcuboot/update_app.sh`) | **works** (repeatedly: 1.0.7 -> 1.2.2) |
| Rescue: no valid app -> MCUboot serial recovery takes an upload | works |
| Reset = FPGA reconfiguration from flash (reloads MCUboot) | works |
| RSU status / slot listing over serial (`update_bitstream.py status`) | works |
| **FPGA bitstream update over serial** (`update_bitstream.py program`) | **NOT working** - upload works (125 kB/s), programming into RSU slot P2 fails in libRSU; a failed attempt also left MCUboot slot 0 (0x1000000) erased. Do not use until fixed. |
| First installation of the flash | needs JTAG once (`initial_image.jic`) |

**Board state at the time of writing:** the RSU flash image is intact
(factory + P1 boot), but there is no valid app in the MCUboot slots - MCUboot
waits in serial recovery. Uploads into recovery currently fail and are being
investigated; restore by programming `hw/output_files/niosv_zephyr.sof` over
JTAG and uploading an app (step 6/7), or reprogramming the `.jic` (step 4).

## Prerequisites

- Quartus Prime Pro 26.1.1 at `~/altera_pro/26.1.1` (Platform Designer,
  Questa FSE for simulation), the Nios V tools under `niosv/bin`.
- Zephyr workspace in `niosv_zephyr/zephyr` (v4.4.2) and the Python venv
  `niosv_zephyr/.venv` - see `README.md` "Setup".
- `smpmgr` / `smpclient` in the venv: `pip install smpmgr`.
- Board attached through usbipd (WSL): USB-Blaster III = JTAG + `/dev/ttyUSB0`
  (FTDI UART; user in `dialout`).

All commands below run from `niosv_zephyr/` unless stated; `source
.venv/bin/activate` first.

## 1. MCUboot (runs from the FPGA's on-chip RAM)

```
mcuboot/build_mcuboot.sh            # -> zephyr/build_mcuboot (120 MHz CPU)
```

## 2. Hardware (bitstream, ~30 min)

```
cd hw && ./build_all.sh             # CPU_CLOCK_MHZ=120 default; bakes MCUboot into ram0
```

`build_all.sh` puts `zephyr/build_mcuboot/zephyr/zephyr.elf` into the on-chip
RAM's initial contents. After changing only MCUboot, skip the full build:

```
cd hw && ./update_mcuboot.sh        # ~25 s: update_mif + assembler
```

## 3. Flash images

```
cd hw && ./flash/make_flash_images.sh
#   output_files/initial_image.jic   whole flash, RSU layout (for JTAG)
#   output_files/application.rpd     bitstream as an RSU application image (for serial)
```

Flash layout: `zephyr_overlays/niosv_g_flash_layout.overlay` (BOOT_INFO,
factory 0x210000, SPT/CPB 0x600000, P1 0x800000, P2 0xC00000, MCUboot slots
0x1000000 / 0x1400000).

## 4. First installation (JTAG, once per board)

```
cd hw
quartus_pgm -c 1 -m jtag -o "pvi;output_files/initial_image.jic"
```

Then power-cycle: the board boots the bitstream from flash into MCUboot,
which waits in serial recovery (no app yet). The RSU commands (reset by
reconfiguration, bitstream updates) only work after a boot from flash, not
when the FPGA was configured over JTAG.

## 5. The application

```
cd zephyr
west build -b niosv_g -d build_smp_app ../apps/smp_app -- -DAPP_VERSION=1.0.0
```

`apps/smp_app` is the updatable application: mcumgr (SMP) server on the FTDI
UART. Any app needs, as `apps/smp_app/CMakeLists.txt` and `prj.conf` show:
the overlays `niosv_g_hyperram_xip`, `niosv_g_uart_fifo`, `niosv_g_sdm_qspi`,
`niosv_g_flash_layout`, `niosv_g_bootinfo`, the `zephyr_module`, and
`mcuboot/app_ram_load.conf`. `-DNIOSV_CPU_HZ` must match the hardware's CPU
clock (default 120 MHz).

## 6. First app upload (MCUboot serial recovery)

With no valid app MCUboot waits in recovery:

```
mcuboot/sign_app.sh zephyr/build_smp_app 1.0.0
smpmgr --port /dev/ttyUSB0 --baudrate 4800000 --line-length 4096 --line-buffers 4 --timeout 30 \
    image upload zephyr/build_smp_app/zephyr/zephyr.signed.bin
smpmgr --port /dev/ttyUSB0 --baudrate 4800000 --line-length 4096 --line-buffers 4 --timeout 30 os reset
```

## 7. App updates (serial, through the running app)

```
cd zephyr
west build -d build_smp_app -- -DAPP_VERSION=1.1.0
../mcuboot/update_app.sh build_smp_app 1.1.0
```

Signs, uploads into the slot that is not running, resets (FPGA
reconfiguration from flash); MCUboot boots the newer version.

## 8. Bitstream updates (serial) - NOT WORKING YET

```
python3 mcuboot/update_bitstream.py status
python3 mcuboot/update_bitstream.py program hw/output_files/application.rpd --load   # do not use yet
```

## Debug access (JTAG)

- `hw/download.sh <elf>` - load and run an on-chip-RAM or XIP ELF (word by
  word: the I-cache breaks block writes).
- `juart-terminal` - the JTAG UART console; attach after the program starts;
  output is dropped while no console is attached.

## Pitfalls found on the way

- The Nios V/g is RV32IM - no atomics (`niosv_g_axc3000.overlay` fixes the ISA).
- XIP apps' RAM must not start at address 0 (an object at NULL breaks kernel lists).
- Zephyr's JTAG UART driver hangs without a host - replaced in `zephyr_module`.
- `qsys-script`'s Tcl sees no environment variables (`--cmd`), lacks `file normalize` and `eq`.
- 15 GB RAM: at most two parallel Quartus builds at 6 threads.
