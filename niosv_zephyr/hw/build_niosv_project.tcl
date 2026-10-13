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

# AXC3000 configuration scheme (matches the repo-root uart_bringup build)
set_global_assignment -name USE_CONF_DONE SDM_IO16
set_global_assignment -name USE_INIT_DONE SDM_IO0

# ------------------------------------------------------------ source set
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
foreach inst {cb cpu0 ram0 rb rr0 uart0} {
    set matches [glob -nocomplain $this_file_path/ip/niosv_zephyr_sys/niosv_zephyr_sys_${inst}*/niosv_zephyr_sys_${inst}*.qip]
    if {[llength $matches] != 1} {
        error "expected exactly one generated .qip for instance '$inst', found: $matches"
    }
    set_global_assignment -name QIP_FILE [lindex $matches 0]
}

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

# --------------------------------------------------------------- commit
export_assignments

if {$need_to_close_project} {
    project_close
}
