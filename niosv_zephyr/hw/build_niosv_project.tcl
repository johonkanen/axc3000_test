# ------------------------------------------------------------------------
# Quartus Prime Pro project script - Nios V/g + Zephyr bring-up (Phase 1)
# Target board: Arrow AXC3000 (Agilex 3 A3CY100BM16AE7S)
#
# Build (run every command from this directory, or just run build_all.sh):
#     qsys-script --script=build_niosv_system.tcl
#     qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
#     quartus_sh    -t build_niosv_project.tcl
#     quartus_syn niosv_zephyr
#     quartus_fit niosv_zephyr
#     quartus_sta niosv_zephyr
#     quartus_asm niosv_zephyr
#
# The single qsys-generate above regenerates every instance (cb/cpu0/ram0/
# rb/rr0/uart0) itself - no separate per-instance pass is needed. See the
# QIP_FILE discovery below for why that still needs a glob instead of a
# fixed path.
#
# No programming yet - Phase 1 only proves the hardware compiles. Phase 2
# flashes it and loads Zephyr's hello_world over JTAG with niosv-download.
# ------------------------------------------------------------------------

package require ::quartus::project

variable this_file_path [file dirname [file normalize [info script]]]

set need_to_close_project 0

if {[is_project_open]} {
    if {[string compare $quartus(project) "niosv_zephyr"]} {
        puts "Project niosv_zephyr is not open"
        exit 1
    }
} else {
    if {[project_exists niosv_zephyr]} {
        project_open -revision niosv_zephyr niosv_zephyr
    } else {
        project_new -revision niosv_zephyr niosv_zephyr
    }
    set need_to_close_project 1
}

# ---------------------------------------------------------------- device
set_global_assignment -name FAMILY "Agilex 3"
set_global_assignment -name DEVICE A3CY100BM16AE7S
set_global_assignment -name TOP_LEVEL_ENTITY niosv_zephyr_top
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 26.1.1
set_global_assignment -name LAST_QUARTUS_VERSION "26.1.1 Pro Edition"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0
set_global_assignment -name MAX_CORE_JUNCTION_TEMP 100
set_global_assignment -name ERROR_CHECK_FREQUENCY_DIVISOR 256
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2019
set_global_assignment -name OPTIMIZATION_MODE BALANCED
set_global_assignment -name BOARD default

# optional cap on cores per build, for running several builds in parallel
# (build_all.sh's NUM_PARALLEL_PROCESSORS env var) - set here rather than
# via a separate `quartus_sh --tcl_eval` post-step, because --tcl_eval
# turns out to be a restricted command dispatcher, not a real Tcl
# interpreter ("invalid command name package"/"invalid command name
# project_open" - it doesn't even have `package require` available).
if {[info exists ::env(NUM_PARALLEL_PROCESSORS)]} {
    set_global_assignment -name NUM_PARALLEL_PROCESSORS $::env(NUM_PARALLEL_PROCESSORS)
}

# AXC3000 configuration scheme (matches the repo-root uart_bringup build)
set_global_assignment -name USE_CONF_DONE SDM_IO16
set_global_assignment -name USE_INIT_DONE SDM_IO0

# ------------------------------------------------------------ source set
# hyperram_axi's own dependencies, in compile order (package before body):
# a dual-port RAM (vhdl2008/, the synthesis "rtl" architecture - its "sim"
# one is for testbenches only) and the HyperRAM command/record package,
# from source/hVHDL_memory_library (a submodule, see repo-root README).
set MEMLIB $this_file_path/../../source/hVHDL_memory_library
set_global_assignment -name VHDL_FILE $MEMLIB/vhdl2008/dp_ram_w_configurable_records.vhd
set_global_assignment -name VHDL_FILE $MEMLIB/vhdl2008/arch_rtl_dp_ram_w_configurable_records.vhd
set_global_assignment -name VHDL_FILE $MEMLIB/hyperram/hyperram_pkg.vhd
set_global_assignment -name VHDL_FILE $MEMLIB/hyperram/hyperram_axi.vhd
set_global_assignment -name VHDL_FILE $this_file_path/hyperram_pins.vhd
set_global_assignment -name VHDL_FILE $this_file_path/hyperram_pll_reconfig.vhd
set_global_assignment -name VHDL_FILE $this_file_path/niosv_zephyr_top.vhd

# ------------------------------------------------------------------- IP
# The top system's own interconnect glue...
set_global_assignment -name QIP_FILE $this_file_path/niosv_zephyr_sys/niosv_zephyr_sys.qip
# ...plus each instance's own generated .qip. qsys-generate on the system
# file regenerates every instance itself, but under its own disambiguating
# suffix that increments on every single invocation (niosv_zephyr_sys_cb,
# then _cb_1, _cb_2, ... - confirmed by direct experiment, not documented
# anywhere found) independently of any separate per-instance qsys-generate
# pass. Hardcoding the unsuffixed name here is what silently went stale
# ("design library ... does not contain primary unit ...") once that
# counter had ticked past 0 from earlier builds in the same environment.
# Discover whatever suffix actually exists on disk right now instead of
# assuming one. build_all.sh cleans ip/niosv_zephyr_sys/niosv_zephyr_sys_*/
# before every regenerate, so exactly one match per instance is expected.
foreach inst {cb cpu0 ram0 rb rr0 uart0 pio_hr_status pio_hr_debug_lo pio_hr_debug_hi pio_hr_timeouts} {
    set matches [glob -nocomplain $this_file_path/ip/niosv_zephyr_sys/niosv_zephyr_sys_${inst}*/niosv_zephyr_sys_${inst}*.qip]
    if {[llength $matches] != 1} {
        error "expected exactly one generated .qip for instance '$inst', found: $matches"
    }
    set_global_assignment -name QIP_FILE [lindex $matches 0]
}

# ------------------------------------------------------- HyperRAM PLL + reconfig bridge
# Both live outside niosv_zephyr_sys entirely (see niosv_zephyr_top.vhd's
# header). rpll0 is a flat .ip (like ip/pll_100/pll_100.ip), not a qsys
# system, so no suffix-discovery glob is needed for it, same as pll_100's
# own IP_FILE reference in the repo-root build. gui_en_iossm_reconf (not
# gui_en_hvio_reconf - this part's package has no HVIO banks at all) is
# the dynamic-reconfiguration path, bridged to a plain AXI4-Lite slave by
# emif_cal (ip/emif_cal/emif_cal.qsys, an emif_io96b_cal instance) - that
# IP DOES compose into a real qsys system of its own (~13 sub-modules),
# so it needs the suffix-discovery glob, same pattern as
# niosv_zephyr_sys's own instances above.
set_global_assignment -name IP_FILE $this_file_path/ip/rpll0/rpll0.ip

set_global_assignment -name QIP_FILE $this_file_path/ip/emif_cal/emif_cal/emif_cal.qip
set emif_cal_cal0_matches [glob -nocomplain $this_file_path/ip/emif_cal/ip/emif_cal/emif_cal_cal0*/emif_cal_cal0*.qip]
if {[llength $emif_cal_cal0_matches] != 1} {
    error "expected exactly one generated .qip for emif_cal's internal cal0, found: $emif_cal_cal0_matches"
}
set_global_assignment -name QIP_FILE [lindex $emif_cal_cal0_matches 0]

# ---------------------------------------------------------- constraints
set_global_assignment -name SDC_FILE $this_file_path/niosv_zephyr.sdc

# ------------------------------------------------------------------ pins
# Same clk/reset pins as the repo-root uart_bringup design - see its
# README pinout table / ArrowElectronics/altera_workshops NIOSV_lab.qsf.
# No other board pins: the JTAG UART needs none, it rides the JTAG chain.
set_location_assignment PIN_A7  -to clk_clk       -comment IOBANK_3A_B
set_location_assignment PIN_A12 -to reset_reset_n -comment IOBANK_3A_B

set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to clk_clk       -entity niosv_zephyr_top
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to reset_reset_n -entity niosv_zephyr_top
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to reset_reset_n -entity niosv_zephyr_top

# AXC3000 onboard HyperRAM - board-verified pinout from the official xSPI
# reference design; see docs/hyperram_pinout.md for the source and the
# INPUT_DELAY_CHAIN note (its one hardware-proven timing choice, reused
# here since this design has no working dynamic calibration yet).
set_location_assignment PIN_D7 -to hr_clk
set_location_assignment PIN_D8 -to hr_csn
set_location_assignment PIN_A6 -to hr_rwds
set_location_assignment PIN_F7 -to hr_resetn
set_location_assignment PIN_C3 -to hr_dq[0]
set_location_assignment PIN_C2 -to hr_dq[1]
set_location_assignment PIN_B4 -to hr_dq[2]
set_location_assignment PIN_B6 -to hr_dq[3]
set_location_assignment PIN_D3 -to hr_dq[4]
set_location_assignment PIN_A4 -to hr_dq[5]
set_location_assignment PIN_B3 -to hr_dq[6]
set_location_assignment PIN_C6 -to hr_dq[7]

set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_clk
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_csn
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_rwds
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_resetn
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[0]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[1]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[2]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[3]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[4]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[5]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[6]
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to hr_dq[7]
set_instance_assignment -name INPUT_DELAY_CHAIN 24 -to hr_dq*


# --------------------------------------------------------------- commit

export_assignments

if {$need_to_close_project} {
    project_close
}
