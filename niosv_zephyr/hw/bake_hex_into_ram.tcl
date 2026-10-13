# ------------------------------------------------------------------------
# Phase 2 bring-up helper: bake a .hex image into ram0's initial contents,
# so the core boots straight into it on FPGA configuration - no JTAG
# download/debug-module halt needed. Use this only while niosv-download's
# debug-module halt path is broken (see niosv_zephyr/hw/README.md); once
# live download works, build_niosv_system.tcl's plain ram0 (blank, zero-
# filled) is the right default again.
#
#   qsys-script --script=build_niosv_system.tcl          # fresh system first
#   qsys-script --system-file=niosv_zephyr_sys.qsys --script=bake_hex_into_ram.tcl
#   qsys-generate ip/niosv_zephyr_sys/niosv_zephyr_sys_ram0.ip --synthesis=VHDL --part=A3CY100BM16AE7S
#   qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S
#   (then the usual quartus_sh/syn/fit/sta/asm)
#
# Set HEX_FILE before running, e.g.:
#   qsys-script --system-file=niosv_zephyr_sys.qsys --cmd="set HEX_FILE {hello_world.hex}" --script=bake_hex_into_ram.tcl
# ------------------------------------------------------------------------
package require qsys

if {![info exists HEX_FILE]} {
    set HEX_FILE {hello_world.hex}
}

load_component ram0
set_component_parameter_value useNonDefaultInitFile {1}
# initializationFileName resolves relative to the *component's own*
# install dir (ip/altera/intel_onchip_memory/) unless abs_path is set -
# "No such file .../ip/altera/intel_onchip_memory/hello_world.hex"
# otherwise, even though generation still reports success.
set_component_parameter_value abs_path {1}
set_component_parameter_value initializationFileName [pwd]/$HEX_FILE
set_component_parameter_value copyInitFile {1}
save_component

save_system {niosv_zephyr_sys.qsys}
