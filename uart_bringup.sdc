# Timing constraints for the AXC3000 UART bring-up build.
#
# The 25 MHz input clock and the 100 MHz core_clock are both created by
# the SDC that Platform Designer generates alongside pll_100 and pulls in
# automatically - do not create_clock / derive_pll_clocks here (Agilex 3
# does not support derive_pll_clocks).

derive_clock_uncertainty

# Asynchronous pins - no external timing relationship
set_false_path -from [get_ports reset_reset_n]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]
