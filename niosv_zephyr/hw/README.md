# hw/ — Nios V/g processor subsystem (Phase 1 & 2 - done)

Platform Designer system: Nios V/g + 256 KB on-chip RAM + JTAG UART console,
clocked directly from the board's 25 MHz oscillator (no PLL yet). Memory map
matches `niosv_zephyr/README.md`'s table exactly, taken from Zephyr's
`boards/intel/niosv_g/niosv_g.dts`, so the stock board files need no address
overlay. **Zephyr's `hello_world` boots and prints over the JTAG UART**,
confirmed on real hardware:

```
*** Booting Zephyr OS build v4.4.2 ***
Hello World! niosv_g/niosv_g
```

Builds clean: Fitter successful, ~2,700 ALMs (8%), 132/262 M20K blocks (the
256 KB RAM), all timing slacks positive.

## What it took to get `qsys-generate` to produce real HDL

`qsys-script`'s `save_system` always converts every instance to
`altera_generic_component` in the saved `.qsys` XML - this turned out to be
**completely normal**, not a bug: Intel's own shipped AXC3000 reference
design (`ArrowElectronics/altera_workshops` → `axc3000/NIOSV_lab`, GUI-saved)
has every instance stored the exact same way. The real cause of the earlier
empty-library build failures was two missing generation steps:

1. **`qsys-generate <system>.qsys --synthesis=VHDL` does not cascade into
   each instance's own nested `.ip` file.** Every instance is backed by a
   standalone `ip/niosv_zephyr_sys/niosv_zephyr_sys_<inst>.ip` file - same
   shape as the repo-root build's `ip/pll_100/pll_100.ip`. Each one needs
   its own `qsys-generate <that>.ip --synthesis=VHDL --part=...` pass
   *before* the system-level pass, or its library stays empty.
2. **The generated system's VHDL registers under a library named after the
   system** (`niosv_zephyr_sys`), not `work` - `niosv_zephyr_top.vhd`
   instantiates it with `library niosv_zephyr_sys; ... entity
   niosv_zephyr_sys.niosv_zephyr_sys`, not `entity work.niosv_zephyr_sys`.

## What it took to get it actually running (not just fitting)

A `.sof` that fits clean is not the same as one that boots. Two real,
separate bugs, found by comparing byte-for-byte against Intel's own
`NIOSV_lab` reference design once a bare-metal "write 'A' to the UART in an
infinite loop" test (bypassing Zephyr and everything else) also produced
*zero* output - proving the gap was hardware wiring, not software:

1. **Missing Reset Release IP.** `intel_user_rst_clkgate` (with
   `outputType` set to `Reset Interface`), its `ninit_done` output wired
   alongside the plain external reset into `cpu0`/`ram0`/`uart0`'s reset
   sinks (Platform Designer auto-merges multiple reset sources into one
   sink - no extra glue needed). Critical Warning 20759 ("Use the Reset
   Release IP in Agilex 3 designs to ensure a successful configuration")
   turned out to be **load-bearing, not cosmetic**: without it, the core
   showed as "running" to the JTAG debug module, clocked and fetched
   forever, yet never produced an observable write to the UART, and the
   debug module itself could not halt the hart
   (`Fatal: Hart 0 failed to halt during examine`). With it, both the
   bare-metal poke test and Zephyr immediately start producing output, and
   `openocd`'s halt starts working too (`Examination succeed`).
2. **`cpu0.dm_agent` left unconnected.** The reference wires it from
   *both* `data_manager` and `instruction_manager` at `0x40000` (8 KB
   region) - we'd left it dangling (benign per `qsys-generate`'s own
   warning text, but not what the verified-working reference does). Added
   to match; harmless either way once (1) was fixed, but worth keeping for
   parity with the reference.
3. **`elf2hex`'s default Intel-HEX record length (32 bytes) doesn't match
   Quartus's expectation of one record per 32-bit memory word** - every
   data line triggered a "Width of data items... greater than the memory
   width. Wrapping data items to subsequent addresses" warning (8192 of
   them for a full image), silently scrambling the whole memory. Fixed
   with `-r 4` (4 bytes = one 32-bit word per record). This one only
   matters for the `bake_hex_into_ram.tcl` bring-up helper below, not for
   live `niosv-download`.

## Live JTAG download (the fast path - fixed)

`./download.sh path/to/some.elf` loads an ELF over JTAG and runs it on the
already-configured board - no bitstream rebuild per test:

```
./download.sh ../zephyr/build_hello/zephyr/zephyr.elf
juart-terminal
```

`download.sh` drives OpenOCD directly (`openocd-cfg-gen`, then one `mww`
per word of every loadable ELF segment, a read-back compare, `fence.i`
through the debug program buffer, `pc` = the ELF's entry point, `resume`)
rather than `niosv-download`. Three reasons, all from the instruction cache
or XIP:

- **block memory writes drop words with the I-cache on.** OpenOCD's
  `load_image`/`write_memory` (and `niosv-download`'s GDB `load`, which
  uses the same path) write through the debug module's auto-repeating
  program-buffer loop; with the I-cache configured, some writes are lost and
  the rest of the block lands shifted down a word (`write_memory 0x3f100 32
  {0xa0 .. 0xa7}` reads back `0xa0 0xa1 0xa3 0xa4 0xa6 0xa7 ..`). Single
  `mww` writes and every read are fine, so the image is written word by word
  (~3 KB/s - 45 s for 15 KB) and verified by reading it back;
- `niosv-download` has no `fence.i` step, so the CPU would run whatever its
  I-cache still holds of the previous program;
- an XIP build's entry point is in the HyperRAM (`0x01000000`), not at the
  reset vector, and is taken from the ELF header here.

Also from the I-cache: the debug module (`dm_agent`, `0x40000`) and the
peripherals must be inside Nios V/g *peripheral regions* (uncached) once
any cache is configured - see `build_niosv_system.tcl`. Arrow's
`niosv_qspi_hyperram_refdes` does the same (its regions cover its
peripherals and debug module).

Earlier history: `niosv-download --use_openocd`'s GDB step failed with a
`libncursesw` symbol-version conflict (its launcher sets `LD_LIBRARY_PATH`
to Quartus's `qcore/linux64/`, too old for the Zephyr SDK's gdb).
`gdb-wrapper/riscv64-zephyr-elf-gdb` strips `LD_LIBRARY_PATH` for the one
`exec` of the real gdb - still useful for interactive GDB sessions with the
Quartus tools on `PATH`.

## Bring-up without live JTAG download: baking a program into `ram0`

Superseded by `download.sh` above for day-to-day iteration - kept as a
fallback (e.g. for a non-volatile/no-JTAG-host boot, or if the download
path breaks again on a different machine):

`bake_hex_into_ram.tcl` patches an already-built system's `ram0` instance
to load its initial contents from a `.hex` file instead of starting blank,
so the core boots straight into a program on FPGA configuration - no
debug-module halt needed at all:

```
# convert the ELF, 4-byte (one 32-bit word) Intel-HEX records - see bug (3) above:
elf2hex -i path/to/some.elf -o hello_world.hex -b 0x0 -e 0x3FFFF -w 32 -r 4 --little-endian-mem

qsys-script --script=build_niosv_system.tcl                          # fresh clean system first
qsys-script --system-file=niosv_zephyr_sys.qsys --script=bake_hex_into_ram.tcl
qsys-generate ip/niosv_zephyr_sys/niosv_zephyr_sys_ram0.ip --synthesis=VHDL --part=A3CY100BM16AE7S
qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
# then the usual quartus_sh/syn/fit/sta/asm, quartus_pgm, juart-terminal
```

This mutates `ip/niosv_zephyr_sys/niosv_zephyr_sys_ram0.ip` to point at an
**absolute, machine-specific path** - never commit it in that state. The
committed `.ip` files are always the clean, blank-RAM baseline; re-run
`bake_hex_into_ram.tcl` locally whenever you want to test a program this
way, and regenerate clean (`build_niosv_system.tcl` alone, no bake step)
before committing.

## Files

| file | purpose |
|---|---|
| `build_niosv_system.tcl` | `qsys-script` source: builds the Platform Designer system |
| `build_niosv_project.tcl` | `quartus_sh` source: creates the Quartus project, pins, SDC, and all `QIP_FILE`s - mirrors the repo-root `build_uart_bringup.tcl` pattern |
| `niosv_zephyr_top.vhd` | board-level wrapper: `clk_clk` (pin A7) / `reset_reset_n` (pin A12) into the qsys system's `clk_in`/`reset_in` exports |
| `niosv_zephyr.sdc` | `create_clock` on `clk_clk` (no PLL to inherit a clock from this time) |
| `download.sh` | load + run an ELF over JTAG without reflashing (OpenOCD, word-by-word + verified, `fence.i`, starts at the ELF entry - XIP too) - the normal day-to-day iteration path |
| `gdb-wrapper/riscv64-zephyr-elf-gdb` | GDB with Quartus's `LD_LIBRARY_PATH` stripped (the `libncursesw` conflict) - for interactive debugging |
| `bake_hex_into_ram.tcl` | fallback bring-up helper - see above. Not part of the normal build. |
| `ip/niosv_zephyr_sys/niosv_zephyr_sys_{cb,cpu0,ram0,rb,rr0,uart0,pio_hr_status,pio_hr_debug_lo,pio_hr_debug_hi,pio_hr_timeouts}.ip` | per-instance IP variation files - **committed**, same convention as the repo-root `ip/pll_100/pll_100.ip`. Their generated HDL trees (`ip/niosv_zephyr_sys/niosv_zephyr_sys_<inst>/`) are not. |
| `hyperram_pins.vhd` | HyperRAM DDIO pin-level wiring (CK/CSn/RESETn/RWDS/DQ) - see `docs/hyperram_pinout.md` |
| `hyperram_pll_reconfig.vhd` | AXI4-Lite master FSM that drives `rpll0`'s dynamic phase shift through `emif_cal` - see `docs/agilex3_dynamic_pll_reconfig.md` for the full mechanism |
| `ip/rpll0/rpll0.ip` | the HyperRAM clock PLL - flat `.ip`, `gui_en_iossm_reconf=true` |
| `ip/emif_cal/emif_cal.qsys` + `ip/emif_cal/ip/emif_cal/emif_cal_cal0.ip` | the AXI4-Lite-to-calibration-bus bridge (`emif_io96b_cal`) `rpll0`'s reconfiguration goes through - **both files matter**, see `docs/agilex3_dynamic_pll_reconfig.md` |

Generated output (`niosv_zephyr_sys.qsys`, `niosv_zephyr_sys/`, the per-instance
generated trees, the Quartus project/output files, any `.hex`) is **not
committed**. Full rebuild from a clean checkout:

```
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/sopc_builder/bin:$PATH"
qsys-script --script=build_niosv_system.tcl
for f in cb cpu0 ram0 rb rr0 uart0 pio_hr_status pio_hr_debug_lo pio_hr_debug_hi pio_hr_timeouts; do
    qsys-generate ip/niosv_zephyr_sys/niosv_zephyr_sys_$f.ip --synthesis=VHDL --part=A3CY100BM16AE7S
done
qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
qsys-generate ip/rpll0/rpll0.ip --synthesis=VHDL --part=A3CY100BM16AE7S
qsys-generate ip/emif_cal/emif_cal.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
quartus_sh -t build_niosv_project.tcl
quartus_syn niosv_zephyr
quartus_fit niosv_zephyr
quartus_sta niosv_zephyr
quartus_asm niosv_zephyr
```

(Or just run `./build_all.sh`, which does all of the above plus the
generated-output cleanup each build needs.)

This produces a clean, blank-RAM `.sof` - program it once, then use
`download.sh` for every test after that.

## Programming and console

```bash
quartus_pgm -c 1 -m jtag -o "p;output_files/niosv_zephyr.sof"   # once per hardware change
./download.sh path/to/some.elf                                  # every test after that
juart-terminal   # no board pins needed - rides the same JTAG cable as program.sh
```

## Phase 5/6: HyperRAM bring-up and dynamic PLL phase shift

Adds the AXC3000's onboard HyperRAM (pins, clocking, calibration-only so
far - no AXI traffic wired to Nios V/g yet). `rpll0` clocks the HyperRAM
CK pin and read-capture domain; its read-capture phase needs to be swept
at runtime by `hyperram_axi`'s own calibration logic, which the
compile-time PLL phase-shift parameter can't do on this Quartus/Agilex 3
combination. `hyperram_pll_reconfig.vhd` + `ip/emif_cal/` solve that -
see `docs/agilex3_dynamic_pll_reconfig.md` for the full mechanism and why
it needs to go through an AXI4-Lite bridge rather than a direct mailbox.

**Confirmed working on real hardware:** the reconfiguration mechanism
itself runs clean - `hyperram_axi`'s calibration sweep completes with
zero bus timeouts, meaning the AXI4-Lite RMW path through `emif_cal` to
`rpll0`'s calibration bus doesn't hang or break anything on silicon.

**Not yet passing:** none of the 8 phase candidates `hyperram_axi` tries
currently pass its own HyperRAM read-back self-test (`pio_hr_status`
reads back `calibrated=1, passed=0`, polled via
`niosv_zephyr/apps/hyperram_status`). Not yet root-caused whether this is
a pre-existing electrical/pinout issue or something in how the phase
shift lands on real hardware - see project memory for where to pick this
up.

## Next: Phase 3 (stretch)

Wire Nios V/g as a second Avalon-MM master into the existing
`fpga_communications` register block so Zephyr can drive the FP32 FMA / PWM
registers from software.
