# build_emif_cal.tcl - the EMIF Calibration IP bridge that rpll0's
# dynamic reconfiguration actually goes through. Found via the Agilex 3
# evaluation kit's own working LPDDR4 EMIF example
# (examples/bts_emif/bts_lpddr4_2a), which uses the same emif_io96b_cal
# component to calibrate ITS PLL - this part's package has no HVIO banks,
# so the direct core_avl_* mailbox (gui_en_hvio_reconf, Sec. 6.2 of the
# Clocking and PLL User Guide) is architecturally unusable here; this is
# the Sec. 6.1 "HSIO I/O PLL Reconfiguration using EMIF Calibration IP"
# path instead. See the session's project memory for the full diagnostic
# trail, including a real Questa simulation that confirmed this bridge's
# AXI4-Lite address encoding and register map end to end.
#
# Unlike rpll0 (which has to be a flat .ip - see ip/rpll0/build_rpll0.tcl),
# this IP composes into ~13 sub-modules of its own (a JTAG-Avalon debug
# bridge etc., included even though unused here) and needs to stay a
# wrapped qsys system - that's fine for this IP; wrapping was never what
# broke HVIO placement on rpll0.
#
#   qsys-script --script=build_emif_cal.tcl
#
package require qsys
create_system emif_cal
set_project_property DEVICE A3CY100BM16AE7S
set_project_property DEVICE_FAMILY {Agilex 3}

add_instance cal0 emif_io96b_cal
set_instance_parameter_value cal0 NUM_CALBUS_PLLS 1
set_instance_parameter_value cal0 NUM_CALBUS_PERIPHS 0
set_instance_parameter_value cal0 PORT_S_AXIL_MODE FABRIC

add_interface clk clock sink
set_interface_property clk EXPORT_OF cal0.s0_axi4lite_clk
add_interface reset reset sink
set_interface_property reset EXPORT_OF cal0.s0_axi4lite_rst_n
add_interface s_axil axi4lite slave
set_interface_property s_axil EXPORT_OF cal0.s0_axi4lite
add_interface calbus_pll0 conduit end
set_interface_property calbus_pll0 EXPORT_OF cal0.calbus_pll_0

save_system emif_cal.qsys
