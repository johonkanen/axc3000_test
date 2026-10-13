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
# One external 25 MHz pin, one external reset pin; bridges fan each out to
# the three sinks below. No PLL yet - 25 MHz is plenty for a first boot.
add_instance cb altera_clock_bridge
set_instance_parameter_value cb EXPLICIT_CLOCK_RATE 25000000.0

add_instance rb altera_reset_bridge
set_instance_parameter_value rb ACTIVE_LOW_RESET 1
add_connection cb.out_clk rb.clk

# ---------------------------------------------------------------- Nios V/g core
add_instance cpu0 intel_niosv_g
set_instance_parameter_value cpu0 clockFrequency 25000000.0
set_instance_parameter_value cpu0 dataCacheSize   0
set_instance_parameter_value cpu0 instCacheSize   0
set_instance_parameter_value cpu0 resetOffset      0
set_instance_parameter_value cpu0 resetSlave       Absolute

# ---------------------------------------------------------------- on-chip RAM (256 KB @ 0x0)
add_instance ram0 intel_onchip_memory
set_instance_parameter_value ram0 AXI_interface 1
set_instance_parameter_value ram0 memorySize    262144.0
set_instance_parameter_value ram0 writable      1

# ---------------------------------------------------------------- JTAG UART console
add_instance uart0 altera_avalon_jtag_uart

# ---------------------------------------------------------------- clock fanout
add_connection cb.out_clk cpu0.clk
add_connection cb.out_clk ram0.clk1
add_connection cb.out_clk uart0.clk

# ---------------------------------------------------------------- reset fanout
add_connection rb.out_reset cpu0.reset
add_connection rb.out_reset ram0.reset1
add_connection rb.out_reset uart0.reset

# ---------------------------------------------------------------- memory map
add_connection cpu0.instruction_manager ram0.s1
add_connection cpu0.data_manager        ram0.s1
set_connection_parameter_value cpu0.data_manager/ram0.s1 baseAddress 0x00000000

add_connection cpu0.data_manager uart0.avalon_jtag_slave
set_connection_parameter_value cpu0.data_manager/uart0.avalon_jtag_slave baseAddress 0x00090078

add_connection cpu0.data_manager cpu0.timer_sw_agent
set_connection_parameter_value cpu0.data_manager/cpu0.timer_sw_agent baseAddress 0x00090000

# ---------------------------------------------------------------- platform interrupt (uart0 -> local IRQ 16)
# Despite the _rx name, cpu0.platform_irq_rx is the connection's "start"
# role and uart0.irq is "end" for add_connection purposes here - qsys-generate
# errors ("Illegal connection start/end") if given the intuitive order.
add_connection cpu0.platform_irq_rx uart0.irq
set_connection_parameter_value cpu0.platform_irq_rx/uart0.irq irqNumber 0

# ---------------------------------------------------------------- system boundary exports
add_interface clk_in clock sink
set_interface_property clk_in EXPORT_OF cb.in_clk

add_interface reset_in reset sink
set_interface_property reset_in EXPORT_OF rb.in_reset

save_system {niosv_zephyr_sys.qsys}
