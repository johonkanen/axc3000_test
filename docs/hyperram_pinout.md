# AXC3000 onboard HyperRAM pinout

FPGA-pin assignments for the onboard 128 Mb (16 MB) HyperRAM 2.1 x8 pSRAM on
the Arrow AXC3000 (Agilex 3 `A3CY100BM16AE7S`).

Source: `ArrowElectronics/refdes-agilex3`, tag `QPDS26.1_REL_AGILEX3_REFDES`,
`axc3000/niosv_qspi_hyperram_refdes/sources/axc3000_pin_assignment.tcl` - the
official reference design's own pin constraints, so this is board-verified,
not inferred from a schematic.

All HyperRAM I/O sits in **Bank 3A (nominal 1.2 V)** → use
`IO_STANDARD "1.3-V LVCMOS"` (same convention this repo already uses for
`clk_clk`/`reset_reset_n`, also in Bank 3A - "1.3-V" is Quartus's closest
declared standard, not a hardware voltage change).

| signal | pin | notes |
|--------|-----|-------|
| `HR_CLK` | D7 | single-ended - no CK# pin is routed |
| `HR_CSn` | D8 | chip select |
| `HR_RWDS` | A6 | read/write data strobe |
| `HR_HRESETn` | F7 | reset |
| `HR_DQ[0]` | C3 | |
| `HR_DQ[1]` | C2 | |
| `HR_DQ[2]` | B4 | |
| `HR_DQ[3]` | B6 | |
| `HR_DQ[4]` | D3 | |
| `HR_DQ[5]` | A4 | |
| `HR_DQ[6]` | B3 | |
| `HR_DQ[7]` | C6 | |

The reference design also sets `INPUT_DELAY_CHAIN 24` on all `HR_DQ*` pins
(`set_instance_assignment -name INPUT_DELAY_CHAIN 24 -to HR_DQ* -entity
axc3000_top`) - a tuned input delay, presumably for read-capture timing.
`niosv_zephyr/hw` does **not** use it: that delay was tuned for the
reference design's own controller, and `hyperram_core` captures DQ and RWDS
with the same read clock, so a delay on DQ alone only adds DQ-to-RWDS skew.
It also kept the DQ input DDIO out of the I/O cells (on Agilex 3 an input
delay chain needs the GPIO IP's separate "DDIO with delay" mode).

`HR_CSn`/`HR_HRESETn` (D8/F7) share an I/O lane with `HR_CLK` (D7). One
lane's output registers take a single clock, so with CK's DDIO on the 270°
clock, CS#/RESET# cannot also be I/O-cell registers on the 0° clock (the
Fitter reports "cannot find routing connectivity" from the IOPLL); they are
fabric registers instead.

`CLK_25M_C` is pinned at `A7` in the same file - the same pin this repo
already uses for `clk_clk`, confirming it's the same 25 MHz board
oscillator net, not a separate HyperRAM-specific clock source.

## QSF snippet

```tcl
set_location_assignment PIN_A6  -to HR_RWDS
set_location_assignment PIN_F7  -to HR_HRESETn
set_location_assignment PIN_D8  -to HR_CSn
set_location_assignment PIN_C3  -to HR_DQ[0]
set_location_assignment PIN_C2  -to HR_DQ[1]
set_location_assignment PIN_B4  -to HR_DQ[2]
set_location_assignment PIN_B6  -to HR_DQ[3]
set_location_assignment PIN_D3  -to HR_DQ[4]
set_location_assignment PIN_A4  -to HR_DQ[5]
set_location_assignment PIN_B3  -to HR_DQ[6]
set_location_assignment PIN_C6  -to HR_DQ[7]
set_location_assignment PIN_D7  -to HR_CLK

set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_RWDS
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_HRESETn
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_CSn
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[0]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[1]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[2]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[3]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[4]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[5]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[6]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_DQ[7]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to HR_CLK
set_instance_assignment -name INPUT_DELAY_CHAIN 24 -to HR_DQ*
```

## Note on the reference design's own HyperRAM controller

The official reference design (`niosv_qspi_hyperram_refdes`) drives these
pins with **Synaptic Labs' licensed xSPI memory controller IP**, not
Intel's bundled Octal-SPI "Flash Interface IP" and not
`source/hVHDL_memory_library`'s `hyperram_axi` (which this repo uses
instead - see its README). The reference design's build prerequisites list
a Synaptic Labs trial/paid license as required; this repo's pin data above
is reusable regardless of which controller drives it, but `hyperram_axi`
has not been hardware-validated against this specific part (it was tested
against a Winbond W959D8NFYA, a different, larger, two-die part) or these
specific pins.
