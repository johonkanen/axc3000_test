# axc3000 — UART bring-up build

Minimal Quartus Prime Pro build for the **Arrow AXC3000** (Agilex 3 `A3CY100BM16AE7S`).

Scope: a UART + `fpga_interconnect` register block, a **100 MHz IOPLL**
(`ip/pll_100`), and one **FP32 fused multiply-add DSP** (`ip/native_fp32`
+ `multiply_add(agilex)` — the same `hVHDL_floating_point` module the full
design uses). No power stage / measurements / processors.

Clocking: 25 MHz `clk_clk` → `pll_100` → 100 MHz `core_clock`; the UART and
register logic run on `core_clock`, held in reset until `locked`.

## Sources

`source/` holds three submodules and three vendored files:

| path | origin | pinned |
|------|--------|--------|
| `source/hVHDL_uart` | `hVHDL/hVHDL_uart` | `ec5a265` |
| `source/hVHDL_fpga_interconnect` | `hVHDL/hVHDL_fpga_interconnect` | `e5db290` |
| `source/hVHDL_floating_point` | `hVHDL/hVHDL_floating_point` | `2dac722` |
| `source/fpga_communication/*.vhd` | vendored from `johonkanen/fpga_communication` `3079c3c` | — |

## Build (run from this directory)

```
git submodule update --init
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
python test_uart.py [COM6] [115200]
```

`test_uart.py` is self-contained (needs only `pip install pyserial`) and
exercises every register - id, git hash, loopback, read counter, the FP32
FMA, the float→fixed converter (incl. a run-time radix sweep), and the 4
PWM duty registers. Exit status 0 = all passed.

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
| 54 | measured FMA pipeline latency, core-clock edges (RO) |
| 55 | write → run the FMA latency probe (WO) |
| 56 | float→fixed input — fp32 bit pattern (R/W) |
| 57 | fixed-point result = `trunc(float · 2^radix)` (RO, signed) |
| 58 | float→fixed radix (R/W, default 10) |
| 60 | PWM0 duty count, 0..1024 — `mkr_d4` (RO) |
| 61 | PWM1 duty count, 0..1024 — `mkr_d5` (RO) |
| 62 | PWM2 duty count, 0..1024 — `mkr_d6` (RO) |
| 63 | PWM3 duty count, 0..1024 — `mkr_d7` (RO) |
| 64 | PWM0 duty ratio as a float `[0,1]` — fp32 (R/W) |
| 65 | PWM1 duty ratio as a float `[0,1]` — fp32 (R/W) |
| 66 | PWM2 duty ratio as a float `[0,1]` — fp32 (R/W) |
| 67 | PWM3 duty ratio as a float `[0,1]` — fp32 (R/W) |

FMA operands / result and the addr 56 input are raw IEEE-754 binary32 bit
patterns — use `struct.pack('!f', x)` / `struct.unpack`.

**Float→fixed** (addr 56/57/58): write an fp32 bit pattern to addr 56 and a
radix to addr 58; read `trunc(float · 2^radix)` back from addr 57 as a
signed 32-bit int (at radix 10 a float in `[0,1]` maps to `[0, 1024]`). One
converter instance handles any radix — verified on hardware at radix
0/8/9/10/11/12/14.

Implemented by the local **`float_to_fixed.vhd`** — the
`hVHDL_floating_point` denormalise-then-take-the-mantissa algorithm wrapped
as an entity in the `multiply_add` style: `float_to_fixed_pkg` provides the
input/output records, `create_float_to_fixed_typeref`,
`request_float_to_fixed`, `get_fixed_result` / `float_to_fixed_is_ready`,
and a separate `fp32_to_hfloat` glue function. The hfloat reference type
(`floatref`, default `hfloat32`) and the pipeline depth (`g_stages`,
default 2) are entity generics; the radix travels in the request record.
`sim/float_to_fixed_tb.vhd` covers it.

> The library's generic `denormalizer_generic_pkg` does **not** synthesise
> correctly on Quartus Pro 25.3 — it drops the mantissa shift and returns
> the raw mantissa (`1.0 → 2²³` on hardware), though it simulates fine
> under nvc. The cause is `self.<field>'attr` reads on an unconstrained
> **record subprogram formal**, which Quartus evaluates as 0. `float_to_fixed`
> takes the mantissa width from the `floatref` **generic** and the stage
> count from `g_stages`, so no attribute is read off a formal.
> (`fp32_to_hfloat` must return a *constrained* subtype for the same
> reason — an unconstrained function result loses its bounds passing
> through `request_float_to_fixed`'s `hfloat_record` formal.)

**FMA latency**: the probe (addr 55/54) measures **3 core-clock edges**
input→result on hardware, matching the behavioural `sim_native_fp32.vhd`
model in `hVHDL_floating_point`. `native_fp32.ip` enables the mult/adder
input registers, the `adder_input` register (`adder_input_clken = 0`), and
the output register. `sim/fma_latency_tb.vhd` runs the identical probe
against the model. (With `adder_input` disabled the hardware measures 2.)

**PWM from a float** (addr 64–67 → 60–63): write a duty ratio in `[0,1]` as
an fp32 to addr 64+ch; a per-channel `float_to_fixed` converts it at radix
10 to a 0–1024 duty count (period = 1024), which addr 60+ch reads back. So
`0.25` gives exactly a 25 % duty cycle on the scope. Values are clamped to
`[0, 1]`; `float_to_fixed` truncates (`0.15 → 153/1024`). Resets to
0.1 / 0.2 / 0.3 / 0.4.

100 MHz core clock / 1024 → **97.66 kHz**, **centre-aligned** (triangle
carrier — all four pulses centred on the same instant). Outputs on MKR
`D4`–`D7` (`AF19` / `AG20` / `AK19` / `AJ19`).

Scoped on an Analog Discovery Pro 3450: all four channels 97.66 kHz,
centre-aligned; writing 0.15 / 0.35 / 0.60 / 0.85 to addr 64–67 gives
measured scope duties 0.147 / 0.349 / 0.599 / 0.849, and a 0→1 sweep of
one channel tracks the written float with ≤ 0.25 % error.

## Pinout

From `ArrowElectronics/altera_workshops` → `axc3000/NIOSV_lab/completed_lab/NIOSV_lab.qsf`:

| signal | pin | IO standard |
|--------|-----|-------------|
| `clk_clk` | A7 | 1.3-V LVCMOS (25 MHz) |
| `reset_reset_n` | A12 | 1.3-V LVCMOS (weak pull-up) |
| `uart_rxd` | AG23 | 3.3-V LVCMOS |
| `uart_txd` | AG24 | 3.3-V LVCMOS |

Arduino MKR header (J1/J2) pin map: [docs/mkr_pinout.md](docs/mkr_pinout.md).

## IP

Only the `.ip` files are committed; regenerate the HDL with `qsys-generate`.

- `ip/pll_100/pll_100.ip` — `altera_iopll`, 25 MHz ref → 100 MHz, `locked`
  used. Created with `ip-deploy` (command in `build_uart_bringup.tcl` header).
- `ip/native_fp32/native_fp32.ip` — `agilex_native_floating_point_dsp`,
  `operation_mode = fp32_mult_add`, device `A3CY100BM16AE7S`. Wrapped by
  `source/hVHDL_floating_point/vhdl2008/altera/multiply_add_arch_agilex.vhd`.

## Note

Critical Warning 20759 (missing Reset Release IP) is expected — add the
Reset Release IP for a production build.
