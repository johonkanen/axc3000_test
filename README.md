# axc3000 — UART bring-up build

Minimal Quartus Prime Pro build for the **Arrow AXC3000** (Agilex 3 `A3CY100BM16AE7S`).

Scope: `source/fpga_communication` (UART + `fpga_interconnect` register
protocol), a **100 MHz IOPLL** (`ip/pll_100`), and one **FP32 fused
multiply-add DSP** (`ip/native_fp32` + `multiply_add(agilex)` — the same
float module `../quartus_pro` / `build_agilex_3` uses). No power stage /
measurements / processors. The full design lives in `../quartus_pro`.

Clocking: 25 MHz `clk_clk` → `pll_100` → 100 MHz `core_clock`; the UART and
register logic run on `core_clock`, held in reset until `locked`.

## Build (run from this directory)

```
quartus_sh  -t build_uart_bringup.tcl
# regenerate IP HDL (only if ip/<name>/<name>/ is missing) - quartus_syn does NOT do this:
qsys-generate ip/pll_100/pll_100.ip       --synthesis=VHDL --part=A3CY100BM16AE7S
qsys-generate ip/native_fp32/native_fp32.ip --synthesis=VHDL --part=A3CY100BM16AE7S
quartus_syn uart_bringup
quartus_fit uart_bringup
quartus_sta uart_bringup
quartus_asm uart_bringup
```

`qsys-generate` lives in `D:\altera_pro\25.3\quartus\sopc_builder\bin`.

Toolchain used: `D:\altera_pro\25.3\quartus\bin64`.

## Program (volatile JTAG load)

```
quartus_pgm -c 1 -m jtag -o "p;output_files/uart_bringup.sof"
```

Use the cable **index** `-c 1`, not a name. Cable is "USB Blaster III [USB-1]".

## Talk to it

100 MHz core clock / `g_clock_divider` (868) = 115200 baud, 32-bit data words.

```
python ../test_hw.py COM6 115200
>>> uart.request_data_from_address(1)   # -> 44252  (0x0000ACDC)
```

| addr | meaning |
|-----:|---------|
| 1 | constant id `0x0000ACDC` (RO) |
| 2 | git hash (RO) |
| 3 | loopback register (R/W) |
| 4 | read strobe counter (RO, ++ per read) |
| 50 | FP32 FMA operand a — `fp32_mult_a` (R/W) |
| 51 | FP32 FMA operand b — `fp32_mult_b` (R/W) |
| 52 | FP32 FMA operand c — `fp32_adder_a` (R/W) |
| 53 | FP32 FMA result `a*b + c` (RO) |

Operands / result are raw IEEE-754 binary32 bit patterns — use `setf`/`getf`
in `test_hw.py`, or `struct.pack('!f', x)`.

## Pinout

From `ArrowElectronics/altera_workshops` → `axc3000/NIOSV_lab/completed_lab/NIOSV_lab.qsf`:

| signal | pin | IO standard |
|--------|-----|-------------|
| `clk_clk` | A7 | 1.3-V LVCMOS (25 MHz) |
| `reset_reset_n` | A12 | 1.3-V LVCMOS (weak pull-up) |
| `uart_rxd` | AG23 | 3.3-V LVCMOS |
| `uart_txd` | AG24 | 3.3-V LVCMOS |

## IP

Only the `.ip` files are committed; regenerate the HDL with `qsys-generate`.

- `ip/pll_100/pll_100.ip` — `altera_iopll`, 25 MHz ref → 100 MHz, `locked`
  used. Created with `ip-deploy` (command in `build_uart_bringup.tcl` header).
- `ip/native_fp32/native_fp32.ip` — `agilex_native_floating_point_dsp`,
  `operation_mode = fp32_mult_add`. Copied verbatim from
  `../quartus_pro/ip/native_fp32/native_fp32.ip` with the device string
  retargeted to `A3CY100BM16AE7S`. Wrapped by
  `source/hVHDL_floating_point/vhdl2008/altera/multiply_add_arch_agilex.vhd`.

## Note

Critical Warning 20759 (missing Reset Release IP) is expected — add the
Reset Release IP for a production build.
