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

# The UART's reset synchroniser (niosv_zephyr_top.vhd uart_reset): cleared
# asynchronously by sys_reset_n (the PLL's lock and reset logic, on its
# reference clock), released through its own two flops on cpu_clk - the
# asynchronous clear's timing to cpu_clk is what the synchroniser is for.
set_false_path -from [get_clocks {u_rpll|pll_100|tennm_ph2_iopll|ref_clk0}] \
    -to [get_registers {uart_reset_sync[*]}]

# Asynchronous pins - no external timing relationship (uart_rxd goes
# through the receiver's two-flop synchroniser; uart_txd's timing is the bit
# time, microseconds)
set_false_path -from [get_ports reset_reset_n]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]

# ---------------------------------------------------------------- HyperRAM pins
# CK: hyperram_pins' CK DDIO on outclk2 (270 deg) drives '0' in the clock's
# high half and CK_enable in its low half, so CK rises at outclk2's falling
# edge - 2.5 ns, the middle of the first data half (outclk0's DDIO: hi half
# 0-5 ns, lo half 5-10 ns) - and falls at 7.5 ns, the middle of the second.
create_generated_clock -name hr_ck -invert \
    -source [get_pins {u_rpll|pll_100|tennm_ph2_iopll|out_clk[2]}] [get_ports hr_clk]

# Write data and its mask (DQ, RWDS out): DDR, centre-aligned to CK, the
# memory's input setup/hold. PLACEHOLDER values - 1.0 ns each, conservative
# for 100 MHz; replace with the W957D8NBRA4I data sheet's tIS/tIH (HyperBus
# parts are around 0.5-0.6 ns at 166-200 MHz).
set hr_tis 1.0
set hr_tih 1.0
set hr_out [get_ports {hr_dq[*] hr_rwds}]
set_output_delay -clock hr_ck -max $hr_tis $hr_out
set_output_delay -clock hr_ck -min [expr {-$hr_tih}] $hr_out
set_output_delay -clock hr_ck -clock_fall -max $hr_tis $hr_out -add_delay
set_output_delay -clock hr_ck -clock_fall -min [expr {-$hr_tih}] $hr_out -add_delay
# the rising half is taken by CK's rising edge, the falling half by its falling
set_false_path -setup -rise_from [get_clocks {u_rpll|pll_100_outclk0}] -fall_to [get_clocks hr_ck]
set_false_path -setup -fall_from [get_clocks {u_rpll|pll_100_outclk0}] -rise_to [get_clocks hr_ck]
set_false_path -hold  -rise_from [get_clocks {u_rpll|pll_100_outclk0}] -rise_to [get_clocks hr_ck]
set_false_path -hold  -fall_from [get_clocks {u_rpll|pll_100_outclk0}] -fall_to [get_clocks hr_ck]

# The output enables (DQ/RWDS bus turnaround): they switch only while CK is
# stopped - on for a command before CK's first edge, off after its last -
# so no CK edge ever samples their transition.
set_false_path -from [get_keepers {u_hyperram_pins|u_dq|*|oe_path*}] -to $hr_out

# CS# and RESET#: no single-cycle relationship to CK - hyperram_core takes
# CS# low a whole cycle before CK starts and high after it has stopped
# (tCSS/tCSH of many ns), RESET# is static for microseconds.
set_false_path -to [get_ports {hr_csn hr_resetn}]

# Read data (DQ, RWDS in): captured by the read clock outclk1, whose phase
# the calibration sets at run time anywhere within a period (52 ps steps,
# hyperram_core's relative phase) - a static input delay against one fixed
# phase would mean nothing. The capture DDIO -> outclk0 transfer inside the
# FPGA stays timed (above: outclk0/1 in one group); the calibration tests
# the whole chain at every step and keeps to the middle of what passes.
set_false_path -from [get_ports {hr_dq[*] hr_rwds}]
