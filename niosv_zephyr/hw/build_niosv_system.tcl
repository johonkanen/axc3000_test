# ------------------------------------------------------------------------
# Platform Designer system for Zephyr-on-Nios V/g bring-up (Phase 1).
# Memory map matches zephyr/boards/intel/niosv_g/niosv_g.dts exactly, so
# the stock Zephyr board files need no devicetree overlay for addresses
# (clock-frequency does need an overlay - see hw/README.md).
#
#   qsys-script --script=build_niosv_system.tcl
#
# ------------------------------------------------------------------------
package require qsys

create_system {niosv_zephyr_sys}

set_project_property DEVICE        {A3CY100BM16AE7S}
set_project_property DEVICE_FAMILY {Agilex 3}

# ---------------------------------------------------------------- clock / reset fanout
# One clock input (rpll0's outclk3) and one reset input; bridges fan each
# out to the sinks below.
# The system clock is rpll0's outclk3 (niosv_zephyr_top.vhd): ::cpu_mhz,
# set by build_all.sh from CPU_CLOCK_MHZ with qsys-script --cmd (default 120
# MHz) - qsys-script's Tcl does not see environment variables.
set cpu_hz 120000000
if {[info exists ::cpu_mhz]} {
    set cpu_hz [expr {$::cpu_mhz * 1000000}]
}
add_instance cb altera_clock_bridge
set_instance_parameter_value cb EXPLICIT_CLOCK_RATE [expr {double($cpu_hz)}]

add_instance rb altera_reset_bridge
set_instance_parameter_value rb ACTIVE_LOW_RESET 1
add_connection cb.out_clk rb.clk

# Reset Release IP - Intel's own AXC3000 NIOSV_lab reference wires this
# alongside the plain external reset (Platform Designer auto-merges
# multiple reset sources into one sink). Critical Warning 20759 ("Use the
# Reset Release IP in Agilex 3 designs to ensure a successful
# configuration") says this is load-bearing, not cosmetic, on this family.
add_instance rr0 intel_user_rst_clkgate
set_instance_parameter_value rr0 outputType {Reset Interface}

# ---------------------------------------------------------------- Nios V/g core
# Options from build_all.sh (qsys-script --cmd: its Tcl sees no environment):
#   ::small_ocram 1   SMALL_OCRAM=1 - an 8 KB data cache and a 68 KB ram0:
#                     MCUboot's XIP "ROM" (64 KB) + boot information/flags;
#                     every program's data in the HyperRAM behind the cache
#                     (zephyr_overlays/*_small.overlay, niosv_g_small_ocram.conf)
#   ::fpu 1|nodiv     NIOSV_FPU - the F extension (single precision), with or
#                     without the FSQRT/FDIV logic
# (copied into other names: this script runs at global scope, where a
# "set small_ocram 0" would overwrite ::small_ocram itself)
set opt_small_ocram 0
if {[info exists ::small_ocram]} { set opt_small_ocram $::small_ocram }
set opt_fpu 0
if {[info exists ::fpu]} { set opt_fpu $::fpu }

add_instance cpu0 intel_niosv_g
set_instance_parameter_value cpu0 clockFrequency [expr {double($cpu_hz)}]
if {$opt_small_ocram} {
    set_instance_parameter_value cpu0 dataCacheSize   8192
} else {
    set_instance_parameter_value cpu0 dataCacheSize   0
}
if {$opt_fpu != 0} {
    set_instance_parameter_value cpu0 enableFPU True
    if {$opt_fpu == "nodiv"} {
        set_instance_parameter_value cpu0 disableFsqrtFdiv True
    }
}
# 16 KB instruction cache (the largest): Zephyr's code runs from the
# HyperRAM (XIP, see zephyr_overlays/niosv_g_hyperram_xip.overlay), whose
# uncached fetches would be ~1 us each. No data cache by default: data stays
# in on-chip RAM (SMALL_OCRAM=1 moves it to the HyperRAM behind one).
set_instance_parameter_value cpu0 instCacheSize   16384
# With any cache configured, everything outside a peripheral region is
# cacheable - including, for instruction fetches, the debug module: the CPU
# executes the debugger's program buffer from dm_agent (0x40000), and a
# cached copy turns every later debugger memory write / register read into
# stale code (corrupted program loads, "Unexpected read of fp via program
# buffer"). Region A: dm_agent, 0x40000-0x7FFFF. Region B: 0x80000-0xFFFFF,
# timer_sw_agent 0x90000, uart0 0x90078 and the pio_hr_* at 0xA0000.
set_instance_parameter_value cpu0 peripheralRegionABase 0x00040000
set_instance_parameter_value cpu0 peripheralRegionASize 262144
set_instance_parameter_value cpu0 peripheralRegionBBase 0x00080000
set_instance_parameter_value cpu0 peripheralRegionBSize 524288
set_instance_parameter_value cpu0 resetOffset      0
set_instance_parameter_value cpu0 resetSlave       Absolute

# ---------------------------------------------------------------- on-chip RAM (256 KB @ 0x0)
add_instance ram0 intel_onchip_memory
set_instance_parameter_value ram0 AXI_interface 1
if {$opt_small_ocram} {
    set_instance_parameter_value ram0 memorySize    69632.0
} else {
    set_instance_parameter_value ram0 memorySize    262144.0
}
set_instance_parameter_value ram0 writable      1

# ---------------------------------------------------------------- JTAG UART console
add_instance uart0 altera_avalon_jtag_uart

# ---------------------------------------------------------------- HyperRAM bring-up status readback
# Read-only windows onto hyperram_axi's calibration/debug outputs (wired in
# niosv_zephyr_top.vhd, synchronised into this CPU clock domain there - the
# core itself runs on the HyperRAM PLL's domain, not this one). No AXI
# traffic to HyperRAM yet - this phase is electrical/calibration bring-up
# only, read by a Zephyr/bare-metal test program over the existing JTAG
# UART, same pattern as every other milestone this project - see
# niosv_zephyr/README.md "Phase 5/6".
add_instance pio_hr_status altera_avalon_pio
set_instance_parameter_value pio_hr_status direction Input
set_instance_parameter_value pio_hr_status width 32

add_instance pio_hr_debug_lo altera_avalon_pio
set_instance_parameter_value pio_hr_debug_lo direction Input
set_instance_parameter_value pio_hr_debug_lo width 32

add_instance pio_hr_debug_hi altera_avalon_pio
set_instance_parameter_value pio_hr_debug_hi direction Input
set_instance_parameter_value pio_hr_debug_hi width 32

add_instance pio_hr_timeouts altera_avalon_pio
set_instance_parameter_value pio_hr_timeouts direction Input
set_instance_parameter_value pio_hr_timeouts width 32

# ---------------------------------------------------------------- HyperRAM memory window
# A 16 MB AXI4-Lite window onto the HyperRAM, for both cpu0 managers (data,
# and instructions to run code from it), exported (m0) to
# niosv_zephyr_top.vhd, where hyperram_axi4lite_bridge adapts it to
# hyperram_axi's native port. The bridge runs on the HyperRAM core's own
# 100 MHz clock (hr_clk_in, rpll0 outclk0) and reset (hr_reset_in, the PLL
# not locked) - Platform Designer inserts the 25 -> 100 MHz clock crossing
# between cpu0.data_manager and it. hyperram_axi holds arw_ready low until
# calibration is done, so software checks hr_status before touching it.
add_instance cb_hr altera_clock_bridge
set_instance_parameter_value cb_hr EXPLICIT_CLOCK_RATE 100000000.0

add_instance rb_hr altera_reset_bridge
set_instance_parameter_value rb_hr ACTIVE_LOW_RESET 1
add_connection cb_hr.out_clk rb_hr.clk

add_instance hr_axi altera_axi_bridge
set_instance_parameter_value hr_axi AXI_VERSION AXI4-Lite
set_instance_parameter_value hr_axi DATA_WIDTH  32
set_instance_parameter_value hr_axi ADDR_WIDTH  24
add_connection cb_hr.out_clk   hr_axi.clk
add_connection rb_hr.out_reset hr_axi.clk_reset

# ---------------------------------------------------------------- FTDI UART window
# uart/uart_axi4lite.vhd (in niosv_zephyr_top.vhd) behind an exported
# AXI4-Lite manager at 0xB0000 - inside peripheral region B (uncached) - in
# the CPU clock domain (no clock crossing), and its interrupt into the CPU
# through an IRQ bridge (platform IRQ 1, Zephyr IRQ 17).
add_instance uart_axi altera_axi_bridge
set_instance_parameter_value uart_axi AXI_VERSION AXI4-Lite
set_instance_parameter_value uart_axi DATA_WIDTH  32
set_instance_parameter_value uart_axi ADDR_WIDTH  8

add_instance uart_irq altera_irq_bridge
set_instance_parameter_value uart_irq IRQ_WIDTH 1

# ---------------------------------------------------------------- SDM mailbox (QSPI flash)
# The configuration QSPI flash belongs to the SDM; the FPGA reaches it only
# through SDM mailbox commands (QSPI_OPEN/READ/WRITE/ERASE/CLOSE, and the
# RSU commands). At 0xC0000, inside peripheral region B (uncached), platform
# IRQ 2 (Zephyr IRQ 18). Same parameters as Arrow's niosv_qspi_hyperram_refdes.
add_instance mbox0 intel_mailbox_client

# ---------------------------------------------------------------- HyperRAM PLL + reconfig
# rpll0 (the HyperRAM clock PLL) and the emif_io96b_cal bridge it needs
# for dynamic phase-shift reconfiguration both live OUTSIDE this system
# entirely, instantiated directly in niosv_zephyr_top.vhd - see that
# file's header for the full story (nesting a PLL as a plain Qsys
# instance in here hit a Fitter placement failure). See ip/rpll0/ and
# ip/emif_cal/ for how each is generated, and the session's project
# memory for the diagnostic trail.

# ---------------------------------------------------------------- clock fanout
add_connection cb.out_clk cpu0.clk
add_connection cb.out_clk ram0.clk1
add_connection cb.out_clk uart0.clk
add_connection cb.out_clk pio_hr_status.clk
add_connection cb.out_clk pio_hr_debug_lo.clk
add_connection cb.out_clk pio_hr_debug_hi.clk
add_connection cb.out_clk pio_hr_timeouts.clk
add_connection cb.out_clk uart_axi.clk
add_connection cb.out_clk uart_irq.clk
add_connection cb.out_clk mbox0.in_clk

# ---------------------------------------------------------------- reset fanout
add_connection rb.out_reset cpu0.reset
add_connection rb.out_reset ram0.reset1
add_connection rb.out_reset uart0.reset
add_connection rb.out_reset pio_hr_status.reset
add_connection rb.out_reset pio_hr_debug_lo.reset
add_connection rb.out_reset pio_hr_debug_hi.reset
add_connection rb.out_reset pio_hr_timeouts.reset
add_connection rb.out_reset uart_axi.clk_reset
add_connection rb.out_reset uart_irq.clk_reset
add_connection rb.out_reset mbox0.in_reset

add_connection rr0.ninit_done cpu0.reset
add_connection rr0.ninit_done ram0.reset1
add_connection rr0.ninit_done uart0.reset
add_connection rr0.ninit_done pio_hr_status.reset
add_connection rr0.ninit_done pio_hr_debug_lo.reset
add_connection rr0.ninit_done pio_hr_debug_hi.reset
add_connection rr0.ninit_done pio_hr_timeouts.reset
add_connection rr0.ninit_done uart_axi.clk_reset
add_connection rr0.ninit_done uart_irq.clk_reset
add_connection rr0.ninit_done mbox0.in_reset

# ---------------------------------------------------------------- memory map
add_connection cpu0.instruction_manager ram0.s1
add_connection cpu0.data_manager        ram0.s1
set_connection_parameter_value cpu0.data_manager/ram0.s1 baseAddress 0x00000000

add_connection cpu0.data_manager uart0.avalon_jtag_slave
set_connection_parameter_value cpu0.data_manager/uart0.avalon_jtag_slave baseAddress 0x00090078

add_connection cpu0.data_manager cpu0.timer_sw_agent
set_connection_parameter_value cpu0.data_manager/cpu0.timer_sw_agent baseAddress 0x00090000

add_connection cpu0.data_manager pio_hr_status.s1
set_connection_parameter_value cpu0.data_manager/pio_hr_status.s1 baseAddress 0x000A0000
add_connection cpu0.data_manager pio_hr_debug_lo.s1
set_connection_parameter_value cpu0.data_manager/pio_hr_debug_lo.s1 baseAddress 0x000A0010
add_connection cpu0.data_manager pio_hr_debug_hi.s1
set_connection_parameter_value cpu0.data_manager/pio_hr_debug_hi.s1 baseAddress 0x000A0020
add_connection cpu0.data_manager pio_hr_timeouts.s1
set_connection_parameter_value cpu0.data_manager/pio_hr_timeouts.s1 baseAddress 0x000A0030

add_connection cpu0.data_manager mbox0.avmm
set_connection_parameter_value cpu0.data_manager/mbox0.avmm baseAddress 0x000C0000

add_connection cpu0.data_manager uart_axi.s0
set_connection_parameter_value cpu0.data_manager/uart_axi.s0 baseAddress 0x000B0000

add_connection cpu0.data_manager hr_axi.s0
set_connection_parameter_value cpu0.data_manager/hr_axi.s0 baseAddress 0x01000000
# the instruction side too, to execute from the HyperRAM - both managers
# merge onto hr_axi's one port (hyperram_axi4lite_bridge's data side)
add_connection cpu0.instruction_manager hr_axi.s0
set_connection_parameter_value cpu0.instruction_manager/hr_axi.s0 baseAddress 0x01000000

# ---------------------------------------------------------------- debug module
# Intel's own AXC3000 NIOSV_lab reference (ArrowElectronics/altera_workshops)
# wires dm_agent from BOTH masters at 0x40000 - we'd left it unconnected,
# matching the "cpu0.dm_agent is not connected" warning being benign per
# qsys-generate, but the reference's wiring is the one actually verified
# working on this board, so match it.
add_connection cpu0.data_manager        cpu0.dm_agent
add_connection cpu0.instruction_manager cpu0.dm_agent
set_connection_parameter_value cpu0.data_manager/cpu0.dm_agent        baseAddress 0x00040000
set_connection_parameter_value cpu0.instruction_manager/cpu0.dm_agent baseAddress 0x00040000

# ---------------------------------------------------------------- platform interrupt (uart0 -> local IRQ 16)
# Despite the _rx name, cpu0.platform_irq_rx is the connection's "start"
# role and uart0.irq is "end" for add_connection purposes here - qsys-generate
# errors ("Illegal connection start/end") if given the intuitive order.
add_connection cpu0.platform_irq_rx uart0.irq
set_connection_parameter_value cpu0.platform_irq_rx/uart0.irq irqNumber 0
add_connection cpu0.platform_irq_rx uart_irq.sender0_irq
set_connection_parameter_value cpu0.platform_irq_rx/uart_irq.sender0_irq irqNumber 1
add_connection cpu0.platform_irq_rx mbox0.irq
set_connection_parameter_value cpu0.platform_irq_rx/mbox0.irq irqNumber 2

# ---------------------------------------------------------------- system boundary exports
add_interface clk_in clock sink
set_interface_property clk_in EXPORT_OF cb.in_clk

add_interface reset_in reset sink
set_interface_property reset_in EXPORT_OF rb.in_reset

add_interface hr_status conduit end
set_interface_property hr_status EXPORT_OF pio_hr_status.external_connection
add_interface hr_debug_lo conduit end
set_interface_property hr_debug_lo EXPORT_OF pio_hr_debug_lo.external_connection
add_interface hr_debug_hi conduit end
set_interface_property hr_debug_hi EXPORT_OF pio_hr_debug_hi.external_connection
add_interface hr_timeouts conduit end
set_interface_property hr_timeouts EXPORT_OF pio_hr_timeouts.external_connection

add_interface hr_clk_in clock sink
set_interface_property hr_clk_in EXPORT_OF cb_hr.in_clk
add_interface hr_reset_in reset sink
set_interface_property hr_reset_in EXPORT_OF rb_hr.in_reset
add_interface hr_axi axi4lite start
set_interface_property hr_axi EXPORT_OF hr_axi.m0

add_interface uart_axi axi4lite start
set_interface_property uart_axi EXPORT_OF uart_axi.m0
add_interface uart_irq interrupt receiver
set_interface_property uart_irq EXPORT_OF uart_irq.receiver_irq

save_system {niosv_zephyr_sys.qsys}
