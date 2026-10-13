# hw/ — Nios V/g processor subsystem (Phase 1)

Platform Designer system: Nios V/g + 256 KB on-chip RAM + JTAG UART console,
clocked directly from the board's 25 MHz oscillator (no PLL yet). Memory map
matches `niosv_zephyr/README.md`'s table exactly, taken from Zephyr's
`boards/intel/niosv_g/niosv_g.dts`, so the stock board files need no address
overlay.

## Status: wiring designed and validated, generation blocked

The architecture below is real - introspected against the actual installed
IP (`intel_niosv_g`, `intel_onchip_memory`, `altera_avalon_jtag_uart`,
`altera_clock_bridge`, `altera_reset_bridge`) via `qsys-script`'s
`get_instance_parameters`/`get_instance_interfaces`, and the connections
were corrected against real `qsys-generate` errors (see `build_niosv_system.tcl`'s
comment on the IRQ connection - `cpu0.platform_irq_rx`/`uart0.irq`'s role
names are the reverse of what their names suggest). `qsys-validate` passes
clean.

**But this Quartus 26.1.1 Linux install cannot turn that `.qsys` into real
HDL.** `qsys-script`'s `save_system` unconditionally rewrites every instance
to `altera_generic_component` in the saved XML - confirmed with a
single-component (`altera_clock_bridge`) isolation test, so it's not about
component complexity or our specific wiring. `qsys-generate --synthesis=VHDL`
then produces a top-level file whose `library niosv_zephyr_sys_<instance>`
use-clauses point at libraries nothing was ever written into (`design
library ... does not contain primary unit ...`), because a generic
component has no backing HDL unless one is explicitly attached via
`add_instantiation_hdl_file`.

Tried and ruled out:
- `package require qsys 20.1` vs plain `package require qsys` (API version)
- `QSYS_ROOTDIR` pointed at a stale `26.1` instead of `26.1.1` (fixed it
  regardless, no change)
- `reload_ip_catalog` before `create_system`
- `--quartus-project`/`--rev` attached (real device context) for both
  `qsys-script` and `qsys-generate`
- `validate_instance` before save
- `qsys-generate --upgrade-ip-cores` as a pre-pass
- `reload_component_footprint <inst>` on a reloaded system (reports
  success, re-saves as generic anyway)
- `save_composed_hw_tcl_as_qsys` instead of `save_system` (errors: `null`)

The saved XML does carry an `<originalModuleInfo><className>` (e.g.
`altera_clock_bridge`, version `19.2.0`) and a sibling per-instance `.ip`
file (`ip/<system>/<system>_<inst>.ip`) with the real parameterization, so
the information isn't lost - but nothing in the CLI tools I tried will
consume it to re-resolve a generic instance back to its real component for
generation. This looks like a genuine limitation/bug in headless
*origination* of a brand-new system via `qsys-script` in this specific
build (26.1.1), not in editing/regenerating an already-GUI-saved one.

**Next step**: needs a real Platform Designer GUI session once - either
open Platform Designer on the Windows-side Quartus Pro 26.1.1 install and
run `build_niosv_system.tcl` there (File menu → System Scripting → Run
Script…, or paste at a Tcl console), or open the broken generated
`niosv_zephyr_sys.qsys` and use the documented per-instance "generic
component → right-click → fix from IP Catalog" recovery. Either should
produce a `.qsys` that resolves normally; from there headless
`qsys-generate`/`quartus_syn`/`fit`/`sta`/`asm` should work exactly like
the repo-root `uart_bringup` build does today.

## Files

| file | purpose |
|---|---|
| `build_niosv_system.tcl` | `qsys-script` source: builds the Platform Designer system (the actual design, re-run this after a GUI fix if you re-derive it) |
| `build_niosv_project.tcl` | `quartus_sh` source: creates the Quartus project, pins, SDC - mirrors the repo-root `build_uart_bringup.tcl` pattern |
| `niosv_zephyr_top.vhd` | board-level wrapper: `clk_clk` (pin A7) / `reset_reset_n` (pin A12) straight into the qsys system's `clk_in`/`reset_in` exports |
| `niosv_zephyr.sdc` | `create_clock` on `clk_clk` (no PLL to inherit a clock from this time) |

Generated output (`niosv_zephyr_sys.qsys`, `niosv_zephyr_sys/`, the Quartus
project files) is **not committed** - regenerate with:

```
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/sopc_builder/bin:$PATH"
quartus_sh -t build_niosv_project.tcl
qsys-script --quartus-project=niosv_zephyr --rev=niosv_zephyr --script=build_niosv_system.tcl
qsys-generate --quartus-project=niosv_zephyr --rev=niosv_zephyr niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
quartus_syn niosv_zephyr
quartus_fit niosv_zephyr
quartus_sta niosv_zephyr
quartus_asm niosv_zephyr
```

(currently fails at `quartus_syn` for the reason above.)
