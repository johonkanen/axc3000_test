# niosv_zephyr — Zephyr on a Nios V/g soft core (Agilex 3 / AXC3000)

Separate from the UART bring-up design in the repo root: this is a Nios V/g
Platform Designer system + Zephyr RTOS, not Linux (Nios V has no MMU/S-mode,
so Linux is off the table on this core - see repo history / session notes).

## Layout

| path | contents |
|------|----------|
| `zephyr/` | west workspace (zephyrproject), pinned to **v4.4.2**. **Not committed** - see Setup. |
| `.venv/` | Python 3.12 venv for west/Zephyr. **Not committed.** |
| `hw/` | Platform Designer system + Quartus project/build scripts for the Nios V/g processor subsystem. Phases 1 & 2, **done** - Zephyr boots on real hardware. |
| `zephyr_overlays/` | devicetree overlays applied at `west build` time: `niosv_g_hyperram.overlay` (the HyperRAM as a `zephyr,memory-region`), `niosv_g_hyperram_xip.overlay` (code in the HyperRAM), `niosv_g_uart_fifo.overlay` (the FTDI UART). The CPU clock comes from `apps/niosv_cpu_clock.cmake` (`-DNIOSV_CPU_HZ`, default 120 MHz). |
| `zephyr_module/` | out-of-tree Zephyr module `axc3000`: `<axc3000/hyperram.h>` - waits for the HyperRAM calibration at boot, `HYPERRAM_SECTION` for static data, `hyperram_heap` (a `k_heap` on the rest). |
| `apps/` | Zephyr apps: `hyperram_status` (calibration status), `hyperram_memtest` (raw 16 MB test), `hyperram_zephyr` (Zephyr using the HyperRAM via the module). |
| `zephyr-revision.txt` | `west list` output - exact pinned commit of every module, for reproducing the workspace. |

## Phases

- [x] Phase 0 - toolchain (`west`, Zephyr SDK, zephyrproject workspace in `zephyr/`) - **done, verified with a real build**
- [x] Phase 1 - minimal Nios V/g Platform Designer system in `hw/`, memory map matched to the addresses below - **done: `niosv_zephyr.sof` builds clean (~2,700 ALMs, all timing slacks positive), see `hw/README.md`**
- [x] Phase 2 - first boot on hardware - **done: Zephyr's `hello_world` boots and prints `*** Booting Zephyr OS build v4.4.2 ***` / `Hello World! niosv_g/niosv_g` over the JTAG UART.** Took two real hardware bugs to get here (missing Reset Release IP, an `elf2hex` record-length mismatch) plus a `libncursesw` library conflict in `niosv-download` itself - all fixed, see `hw/README.md`. `hw/download.sh` now loads and runs an ELF over JTAG without reflashing, for fast iteration.
- [ ] Phase 3 (stretch) - wire Nios V/g as a second Avalon-MM master into the existing `fpga_communications` register block so Zephyr can drive the FP32 FMA / PWM registers
- [x] Phase 4 - the FTDI serial port (AG23/AG24, `/dev/ttyUSB0` on the host) at 4.8 MBaud: `hw/uart/` (own VHDL: block-RAM FIFOs of 2 KB each way, 8N1 with a fractional bit time - exact 4.8 MBaud at any CPU clock - AXI4-Lite registers at `0xB0000`, interrupts on RX level / RX idle timeout / TX space; VUnit `hw/sim/uart_axi4lite_tb.vhd`), Zephyr driver `zephyr_module/drivers/serial/uart_axc3000.c` (`axc3000,uart-fifo`, `zephyr_overlays/niosv_g_uart_fifo.overlay`). `apps/uart_fifo_test` + `host_echo_test.py`: interrupt-driven echo, 4.8 MBaud full duplex, verified on hardware - the board side takes the full line rate both ways (10 MB, no overrun); the host side (FTDI through usbipd into WSL) loses a few bytes per MB only when both directions run back to back at 100 %, none at 450 kB/s (94 %). Keep `printk` (the JTAG UART) off the hot path - its driver waits for FIFO room with interrupts locked. No hardware flow control: the AXC3000 schematic does not route the FTDI's RTS/CTS to the FPGA - a protocol on top must pace itself (or leave a little headroom, as 450 kB/s does).
- [x] CPU clock, default **120 MHz**: `CPU_CLOCK_MHZ=N hw/build_all.sh` (rpll0 outclk3, any divisor of 2400 MHz), Zephyr `-DNIOSV_CPU_HZ=` (`apps/niosv_cpu_clock.cmake`). Timing: 100 MHz +2.0 ns, 120 MHz +1.0 ns (+0.96 with the UART), 150 MHz +0.01 ns (+0.11 with the UART), 200 MHz fails (-1.3 ns, no boot). On hardware: 150 MHz runs XIP from HyperRAM (CRC-32 of 64 KB 35 ms vs 211 ms at 25 MHz) and the UART; 120 MHz both too (43 ms).
- [x] HyperRAM as a data window: the onboard 16 MB HyperRAM at `0x01000000` on Nios V/g's data bus (`hr_axi` AXI4-Lite bridge in `niosv_zephyr_sys`, 100 MHz HyperRAM clock domain, -> `hw/hyperram_axi4lite_bridge.vhd` -> `source/hVHDL_memory_library`'s `hyperram_axi`). `apps/hyperram_memtest` passes on hardware: data/address bus, byte/halfword strobes, full 16 MB pattern + inverted (~2.5 MB/s write, ~2.2 MB/s read, uncached single-word accesses through a 25 MHz CPU). Pins: `docs/hyperram_pinout.md`.
- [x] Zephyr uses the HyperRAM: `zephyr_overlays/niosv_g_hyperram.overlay` + `zephyr_module/` (see Layout). `apps/hyperram_zephyr` passes on hardware: a 1 MB static buffer in the `HYPERRAM` section, 15 MB `hyperram_heap` alloc/free, memcpy on-chip RAM <-> HyperRAM, two preempting threads on HyperRAM blocks. An app opts in from its CMakeLists.txt (`EXTRA_DTC_OVERLAY_FILE`, `EXTRA_ZEPHYR_MODULES` - see `apps/hyperram_zephyr/CMakeLists.txt`) and needs `CONFIG_SYS_HEAP_AUTO=y` (the 256 KB on-chip RAM makes Zephyr default to small-only heaps, capped at 256 KB; the module fails the build otherwise). Build: `west build -b niosv_g -d build_hr_zephyr ../apps/hyperram_zephyr` from `zephyr/`.
- [x] Phase 5 - Zephyr executes from the HyperRAM (`CONFIG_XIP`): `zephyr_overlays/niosv_g_hyperram_xip.overlay` makes the first 8 MB the "flash" (code + rodata; `.data` copied to on-chip RAM at boot, `.bss`/stacks/kernel in on-chip RAM), the upper 8 MB stay the `HYPERRAM` region + heap. Hardware: `cpu0.instruction_manager` also on `hr_axi`, 16 KB instruction cache, peripheral regions for the debug module and peripherals (see `hw/build_niosv_system.tcl`), `hyperram_axi4lite_bridge` takes any number of reads in flight. `apps/hyperram_zephyr` built with `-DHYPERRAM_XIP=1` passes on hardware; a CPU-bound loop runs as fast as from on-chip RAM (CRC-32 of 64 KB: 211 ms both; 2728 ms without the I-cache). Load with `hw/download.sh` (handles the entry point and the I-cache - see `hw/README.md`). Not persistent: the HyperRAM is written over JTAG; a stand-alone boot would need a boot copier from flash (as Arrow's `niosv_qspi_hyperram_refdes` has).
- [x] Boot from flash, application updates over the 4.8 MBaud UART: the board's 32 MB QSPI configuration flash holds an RSU image (`hw/flash/make_flash_images.sh` -> `initial_image.jic`, programmed once over JTAG: BOOT_INFO, factory image 0x210000, RSU tables, application image P1 0x800000) of a bitstream with MCUboot in its on-chip RAM (`build_all.sh` bakes `zephyr/build_mcuboot`; `hw/update_mcuboot.sh` swaps a rebuilt one in, ~25 s). MCUboot (`mcuboot/`, RAM-load) copies the newer of two flash slots (0x1000000 / 0x1400000) into the HyperRAM and runs it. `mcuboot/update_app.sh <build> <version>` signs an app, uploads it through the running app's mcumgr server (`apps/smp_app`) and resets - the reset reconfigures the FPGA from flash (SDM `RSU_IMAGE_UPDATE`, zephyr_module), MCUboot comes back and boots the new version. With no valid app MCUboot waits in serial recovery and takes the same upload. Flash access: `zephyr_module` driver `axc3000,sdm-qspi` through the SDM mailbox (`hw` mbox0) - read 1.5 MB/s, write 790 KB/s. Gotchas: XIP apps' RAM must not start at 0 (an object at NULL breaks kernel lists - `niosv_g_hyperram_xip.overlay` starts it at 0x100); the SDM answers RSU commands only after a boot from flash, not when JTAG-configured.
- [x] FPGA bitstream updates over the UART: `mcuboot/update_bitstream.py program hw/output_files/application.rpd --load` - the running app (`apps/smp_app`, SMP group 64, `zephyr_module/src/rsu_mgmt.c`) programs the RSU application image into the idle slot (P1/P2) with Altera's uniLibRSU (`zephyr_module/lib/unilibrsu`, MIT-0), verifies it, makes it the highest priority and reconfigures from it. Open: power-up from the updated slot and the SDM's fallback from a failing image are not tested yet.
- [x] HyperRAM timing (2026-10-15): the read errors (~13% wrong bytes after some FPGA loads, which made MCUboot erase app slots) came from the PLL's dynamic phase shift being *relative*, not absolute as the calibration assumed - each change of the phase field moves outclk1 from where it is, only a change by -1 is exact (one 52 ps step earlier; +1 changes slip a VCO period), and a write takes ~5 us (simulated with the generated PLL + EMIF calibration IP). hyperram_core's new relative mode (`g_phase_steps => 192`) walks the read clock down a step at a time through a whole 10 ns period, waits for each write (`hyperram_pll_reconfig` `dps_done`), tests both input orders with long and short reads, and takes the middle of the widest passing window; under 1 ns (`g_min_window => 19`) fails it. On the board: windows of 78-104 steps (4.1-5.4 ns), memory test 5 rounds 0 errors, flash -> HyperRAM copies exact. SDC for the HyperRAM pins (`hr_ck`, DDR output delays - tIS/tIH are 1 ns placeholders until the W957D8NBRA4I data sheet's values are in).
- [ ] Then: put the patched MCUboot (XIP from on-chip RAM 0x0-0xFFFF, warm reboot, keeps failed slots - `mcuboot/patches/`) into a bitstream (`hw/update_mcuboot.sh`, `hw/flash/make_flash_images.sh`, `update_bitstream.py program`), and test cold boots (FPGA reconfiguration) repeatedly: app boots every time, no slot erased. Warm reboot (mcumgr reset -> MCUboot without FPGA reload, 1.8 s) is tested only with a JTAG-loaded MCUboot so far.
- [ ] Then: application updates without any reboot - Zephyr LLEXT loadable modules (fixed base firmware with kernel, drivers, update service; app logic as modules uploaded into HyperRAM and swapped at run time).
- [ ] After Phase 5: remove the Platform Designer-generated HyperRAM glue (`hr_axi` AXI bridge, its auto-inserted clock crossing / burst adapters, `cb_hr`/`rb_hr`, the `pio_hr_*` status PIOs) and redo it in hand-written VHDL with VUnit tests.

## Setup (Phase 0)

The `zephyr/` west workspace is not committed - it's a multi-repo checkout
(zephyr + ~60 modules) plus the SDK, too large and not ours to version.
Re-create it with:

```
# Zephyr v4.4.2's CMake requires Python >= 3.12 (find_package(Python3) fails
# on 3.10/3.11 with "Found unsuitable version"). Use a 3.12 interpreter for
# the venv - this box already had one at ~/.local/bin/python3.12.
~/.local/bin/python3.12 -m venv .venv
source .venv/bin/activate
pip install -U pip west

mkdir -p zephyr && cd zephyr
west init -m https://github.com/zephyrproject-rtos/zephyr --mr main .
west update
cd zephyr && git checkout v4.4.2 && cd ..   # pin to a stable release, not main
west update                                  # re-sync modules to v4.4.2's manifest
west zephyr-export
west packages pip --install
west sdk install -t riscv64-zephyr-elf       # was already installed at ~/zephyr-sdk-1.0.1 on this box
```

Pinned revisions: `zephyr-revision.txt` (`west list` output).

## Board target

Confirmed via `west boards | grep -i nios`: **`niosv_m`** and **`niosv_g`**
both exist upstream. Using `niosv_g` (full target `niosv_g/niosv_g`) per the
original plan.

Sanity-built clean with the Zephyr SDK:
```
west build -b niosv_g zephyr/samples/hello_world
```
→ `zephyr.elf`, RAM: 17968 B / 256 KB (6.85%).

## Phase 1 target: the memory map Zephyr expects

From `zephyr/boards/intel/niosv_g/niosv_g.dts` + `dts/riscv/niosv/niosv-g.dtsi`.
Lay out the Platform Designer system to match these addresses so the stock
board files work unmodified - diverging means a custom board overlay instead:

| region | base | size / regs | notes |
|---|---|---|---|
| `sram0` | `0x00000` | `0x40000` (256 KB) | on-chip RAM, `mmio-sram` |
| `mtimer` | `0x90000` / `0x90008` | 8 B `mtime` / 8 B `mtimecmp` | `riscv,machine-timer` - standard RISC-V CLINT layout, IRQ 7 on the core-local interrupt controller |
| `uart0` | `0x90078` | 8 B | `altr,jtag-uart` (Altera JTAG UART IP, not 16550), IRQ 16, console |

CPU node: `riscv,isa-extensions = "i","m","a","zicsr","zifencei"` (matches
Nios V/g's RV32IMA), default `clock-frequency = 50000000` (board-level
override - we can clock it from our existing `pll_100` instead and set the
DT clock-frequency to match, rather than needing exactly 50 MHz).
