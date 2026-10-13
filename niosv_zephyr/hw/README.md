# hw/ — Nios V/g processor subsystem (Phase 1 - done)

Platform Designer system: Nios V/g + 256 KB on-chip RAM + JTAG UART console,
clocked directly from the board's 25 MHz oscillator (no PLL yet). Memory map
matches `niosv_zephyr/README.md`'s table exactly, taken from Zephyr's
`boards/intel/niosv_g/niosv_g.dts`, so the stock board files need no address
overlay. Builds clean: `niosv_zephyr.sof` generated, Fitter successful,
2,741 ALMs (8%), 132/262 M20K blocks (50%, the 256 KB RAM), 2 DSP blocks, all
timing slacks positive (setup +30.5 ns, hold +0.026 ns on `clk_clk`).

## What it took to get `qsys-generate` to produce real HDL

`qsys-script`'s `save_system` always converts every instance to
`altera_generic_component` in the saved `.qsys` XML - this turned out to be
a **red herring, not a bug**: the real cause was two separate gaps.

1. **`qsys-generate <system>.qsys --synthesis=VHDL` does not cascade into
   each instance's own nested `.ip` file.** Every instance (even ones added
   with the simple `add_instance`/`add_connection` API in
   `build_niosv_system.tcl`) gets backed by a standalone
   `ip/niosv_zephyr_sys/niosv_zephyr_sys_<inst>.ip` file - same shape as the
   repo-root build's `ip/pll_100/pll_100.ip`. Each one needs its own
   `qsys-generate <that>.ip --synthesis=VHDL --part=...` pass *before* the
   system-level pass, or its library stays empty (`design library ... does
   not contain primary unit ...`). Confirmed by generating each of the 5
   individually: `cpu0` alone produced 113 files (the real Nios V/g core,
   debug module, and timer sub-blocks).
2. **The generated system's VHDL registers under a library named after the
   system** (`niosv_zephyr_sys`), not `work`. `niosv_zephyr_top.vhd` must
   instantiate it via a `component` declaration, not `entity work.X` (which
   fails with `design library altera_work does not contain primary unit
   niosv_zephyr_sys`).

So the working order is:
```
qsys-script --script=build_niosv_system.tcl
for f in cb cpu0 ram0 rb uart0; do
    qsys-generate ip/niosv_zephyr_sys/niosv_zephyr_sys_$f.ip --synthesis=VHDL --part=A3CY100BM16AE7S
done
qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
```
and the Quartus project needs `QIP_FILE` for the top system's own
`niosv_zephyr_sys/niosv_zephyr_sys.qip` **plus** each instance's
`ip/niosv_zephyr_sys/niosv_zephyr_sys_<inst>/niosv_zephyr_sys_<inst>.qip` -
see `build_niosv_project.tcl`.

The wiring itself (interfaces/parameters introspected live against the
installed IP, base addresses, the IRQ connection direction - `cpu0`'s
`platform_irq_rx` is the connection "start" despite the `_rx` name,
`uart0.irq` is the "end") was validated earlier via `qsys-validate` and real
`qsys-generate` error messages; none of that changed.

## Files

| file | purpose |
|---|---|
| `build_niosv_system.tcl` | `qsys-script` source: builds the Platform Designer system |
| `build_niosv_project.tcl` | `quartus_sh` source: creates the Quartus project, pins, SDC, and all 6 `QIP_FILE`s - mirrors the repo-root `build_uart_bringup.tcl` pattern |
| `niosv_zephyr_top.vhd` | board-level wrapper: `clk_clk` (pin A7) / `reset_reset_n` (pin A12) into the qsys system's `clk_in`/`reset_in` exports, via a `component` instantiation (see above) |
| `niosv_zephyr.sdc` | `create_clock` on `clk_clk` (no PLL to inherit a clock from this time) |
| `ip/niosv_zephyr_sys/niosv_zephyr_sys_{cb,cpu0,ram0,rb,uart0}.ip` | per-instance IP variation files - **committed**, same convention as the repo-root `ip/pll_100/pll_100.ip`. Their generated HDL trees (`ip/niosv_zephyr_sys/niosv_zephyr_sys_<inst>/`) are not. |

Generated output (`niosv_zephyr_sys.qsys`, `niosv_zephyr_sys/`, the per-instance
generated trees, the Quartus project/output files) is **not committed**.
Full rebuild from a clean checkout:

```
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/sopc_builder/bin:$PATH"
qsys-script --script=build_niosv_system.tcl
for f in cb cpu0 ram0 rb uart0; do
    qsys-generate ip/niosv_zephyr_sys/niosv_zephyr_sys_$f.ip --synthesis=VHDL --part=A3CY100BM16AE7S
done
qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
quartus_sh -t build_niosv_project.tcl
quartus_syn niosv_zephyr
quartus_fit niosv_zephyr
quartus_sta niosv_zephyr
quartus_asm niosv_zephyr
```

## Next: Phase 2

Flash `output_files/niosv_zephyr.sof` over JTAG (same cable/`jtagd` setup as
`program.sh`, or adapt it), load Zephyr's `hello_world.elf` with
`niosv-download`, and watch the console with `juart-terminal`.
