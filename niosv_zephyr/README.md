# niosv_zephyr — Zephyr on a Nios V/g soft core (Agilex 3 / AXC3000)

Separate from the UART bring-up design in the repo root: this is a Nios V/g
Platform Designer system + Zephyr RTOS, not Linux (Nios V has no MMU/S-mode,
so Linux is off the table on this core - see repo history / session notes).

## Layout

| path | contents |
|------|----------|
| `zephyr/` | west workspace (zephyrproject), pinned to **v4.4.2**. **Not committed** - see Setup. |
| `.venv/` | Python 3.12 venv for west/Zephyr. **Not committed.** |
| `hw/` | Platform Designer system + Quartus project/build scripts for the Nios V/g processor subsystem. Phase 1, not started yet. |
| `zephyr-revision.txt` | `west list` output - exact pinned commit of every module, for reproducing the workspace. |

## Phases

- [x] Phase 0 - toolchain (`west`, Zephyr SDK, zephyrproject workspace in `zephyr/`) - **done, verified with a real build**
- [ ] Phase 1 - minimal Nios V/g Platform Designer system in `hw/`, memory map matched to the addresses below
- [ ] Phase 2 - first boot on hardware: flash with `niosv-download`, console via `juart-terminal`
- [ ] Phase 3 (stretch) - wire Nios V/g as a second Avalon-MM master into the existing `fpga_communications` register block so Zephyr can drive the FP32 FMA / PWM registers
- [ ] Phase 4 (stretch) - swap the JTAG UART console for the board's real RS-232 pins (AG23/AG24), if a Zephyr driver exists for Intel's Avalon UART

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
