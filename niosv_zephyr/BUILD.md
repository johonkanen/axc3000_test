# niosv_zephyr - build, flash and update guide

Nios V/g + Zephyr on the Arrow AXC3000 (Agilex 3 `A3CY100BM16AE7S`): the
application runs from the onboard HyperRAM, the board boots from its QSPI
configuration flash, and software is updated over the FTDI serial port
(12 MBaud, the FTDI chip's maximum).

## Status (2026-10-14)

| What | Status |
|---|---|
| Hardware build (Nios V/g 120 MHz, HyperRAM, 12 MBaud UART, SDM mailbox) | works |
| Boot from flash: SDM -> bitstream -> MCUboot -> app from flash into HyperRAM | works, hardware-verified after power cycle |
| **App update over serial** (`mcuboot/update_app.sh`) | **works** (repeatedly: 1.0.7 -> 1.2.2) |
| Rescue: no valid app -> MCUboot serial recovery takes an upload | works |
| Reset = FPGA reconfiguration from flash (reloads MCUboot) | works |
| RSU status / slot listing over serial (`update_bitstream.py status`) | works |
| **FPGA bitstream update over serial** (`update_bitstream.py program`) | **works** (uniLibRSU): 1.6 MB upload at ~125 kB/s, program + verify into P2 12 s, reconfiguration from P2 boots MCUboot and the app; reset restarts from P2. Not yet tested: power-up boot from P2, fallback from a failing image |
| First installation of the flash | needs JTAG once (`initial_image.jic`) |

**Board state at the time of writing:** running from P2 (highest priority;
P1 next, factory last), app 1.3.0 in MCUboot slot 1, 1.2.3 in slot 0.

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

Options (environment variables of `build_all.sh`):

| Option | Effect |
|---|---|
| `CPU_CLOCK_MHZ=120` | the CPU clock (any divisor of the PLL's 2400 MHz VCO); 150 closes, 200 does not |
| `SMALL_OCRAM=1` | an 8 KB data cache and a 68 KB on-chip RAM (MCUboot's 64 KB XIP code + boot information at 0x10000); all data - MCUboot's and the application's - in the HyperRAM behind the cache. 79 instead of 164 M20K. Needs the matching software: `SMALL_OCRAM=1 mcuboot/build_mcuboot.sh` (-> `build_mcuboot_small`, which `build_all.sh` then bakes in) and the application built with `-DSMALL_OCRAM=1`. **Never mix**: a normal application on this hardware has no RAM. |
| `NIOSV_FPU=1` / `nodiv` | the Nios V/g FPU (RISC-V F, single precision), with / without FSQRT and FDIV in hardware (nodiv: the compiler's software routines). Zephyr would need `CONFIG_FPU` and an `rv32imf` ISA in `niosv_g_axc3000.overlay` (not done). |

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
smpmgr --port /dev/ttyUSB0 --baudrate 12000000 --timeout 30 \
    image upload zephyr/build_smp_app/zephyr/zephyr.signed.bin
smpmgr --port /dev/ttyUSB0 --baudrate 12000000 --timeout 30 os reset
```

## 7. App updates (serial, through the running app)

```
cd zephyr
west build -d build_smp_app -- -DAPP_VERSION=1.1.0
../mcuboot/update_app.sh build_smp_app 1.1.0
```

Signs, uploads into the slot that is not running, resets (FPGA
reconfiguration from flash); MCUboot boots the newer version.

Throughput at 12 MBaud: application update (100 KB) about 2.5 s with `update_app.sh`;
bitstream upload 152 kB/s (base64 and a round trip per frame dominate, not the line
rate). `update_bitstream.py --small program ...` uses 1 KB frames, for a board whose
UART FIFO is still 2 KB (bitstreams before the 16 KB FIFOs).

## 8. Bitstream updates (serial)

```
cd hw && ./flash/make_flash_images.sh && cd ..       # -> output_files/application.rpd
.venv/bin/python3 mcuboot/update_bitstream.py status
.venv/bin/python3 mcuboot/update_bitstream.py program hw/output_files/application.rpd --load
.venv/bin/python3 mcuboot/update_bitstream.py load N   # reconfigure from slot N now
```

`program` uploads the image into a HyperRAM buffer, programs it into the RSU
slot that is not running (P1/P2; the factory image is never written),
verifies it and makes it the highest priority - the SDM boots it at every
configuration from flash, and falls back to the next slot / the factory image
if it fails. `--load` reconfigures from it right away. The bitstream carries
MCUboot (on-chip RAM), which then boots the app from its flash slots as
before. The library is Altera's uniLibRSU (`zephyr_module/lib/unilibrsu`); its
flash layer refuses writes outside the RSU tables and P1/P2.

## 9. Partial reconfiguration demo

```
cd hw && PR_DEMO=1 ./build_all.sh && pr/build_personas.sh && cd ..   # ~7 + ~4 min
west build -b niosv_g -d build_smp_pr ../apps/smp_app -- -DAPP_VERSION=1.7.0 -DPR_DEMO=1
.venv/bin/python3 mcuboot/update_bitstream.py pr hw/output_files/impl_green.blinker.rbf
.venv/bin/python3 mcuboot/update_bitstream.py pr hw/output_files/niosv_zephyr.blinker.rbf
```

The PR_DEMO hardware adds a PR region with an LED blinker (blue in the base
`.sof`, green in `impl_green`) and the PR controller at `0xD0000`; `pr`
uploads a persona and programs it into the region while everything else
keeps running. Build `-DPR_DEMO=1` apps only for PR_DEMO hardware.
Details and numbers: `../PARTIAL_RECONFIGURATION.md` section 7.

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
