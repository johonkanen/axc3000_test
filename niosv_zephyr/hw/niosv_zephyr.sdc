# Timing constraints for the Nios V/g + Zephyr bring-up build.
#
# No PLL in this system yet (Phase 1) - clk_clk feeds the Nios V/g core
# directly through the Platform Designer clock bridge, so (unlike
# uart_bringup.sdc) there is no Platform-Designer-generated SDC fragment
# to inherit a create_clock from. Declare it explicitly.

create_clock -name clk_clk -period 40.000 [get_ports clk_clk]   ;# 25 MHz

derive_clock_uncertainty

# Asynchronous pin - no external timing relationship
set_false_path -from [get_ports reset_reset_n]
