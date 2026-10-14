# Timing constraints for niosv_zephyr_top.
#
# clk_clk, the board's 25 MHz oscillator: rpll0's reference, and the clock of
# the PLL reconfiguration path (emif_cal, hyperram_pll_reconfig). The PLL
# IP's generated SDC (read before this file) already creates its clock, as
# u_rpll|pll_100_refclk, and rpll0's output clocks - a create_clock here
# would only be ignored.

derive_clock_uncertainty

# Three asynchronous groups - every crossing between them is synchronised:
#   pll_100_refclk (clk_clk)  PLL reconfiguration (dps_shift/_enable from
#                             the HyperRAM core: 2-3 flop synchronisers)
#   outclk3                   niosv_zephyr_sys, CPU_CLOCK_MHZ (status words:
#                             double-flop; hr_axi: Platform Designer's
#                             clock-crossing FIFO, with its own SDC)
#   outclk0/1/2               the HyperRAM core, read clock and CK - one
#                             frequency, fixed phases, synchronous to each
#                             other (hyperram_pins' clock_rd -> clock_0
#                             transfer is a real timed path)
# Without this, a CPU clock other than 100 MHz turns those crossings into
# bogus synchronous paths (e.g. 150 -> 100 MHz with a 3.3 ns relationship).
set_clock_groups -asynchronous \
    -group [get_clocks {u_rpll|pll_100_refclk}] \
    -group [get_clocks {u_rpll|pll_100_outclk3}] \
    -group [get_clocks {u_rpll|pll_100_outclk0 u_rpll|pll_100_outclk1 u_rpll|pll_100_outclk2}]

# Asynchronous pins - no external timing relationship (uart_rxd goes
# through the receiver's two-flop synchroniser; uart_txd's timing is the bit
# time, microseconds)
set_false_path -from [get_ports reset_reset_n]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]
