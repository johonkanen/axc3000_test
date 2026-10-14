#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build_hr_gpio.sh - creates the two GPIO IP variations hyperram_pins.vhd
# uses, so the HyperRAM pins' registers sit in the I/O cells (DDIO). The
# hand-written DDR registers hyperram_pins.vhd used before were never packed
# into the I/O cells: the fit report showed Input/Output/Output Enable
# Register = "no" on every hr_* pin, with the clock used as a data-mux select
# in the fabric.
#
# Already applied and committed - this file is the reproducible record, not
# something build_all.sh re-runs (build_all.sh only qsys-generates the .ip
# files). Run from this directory:
#
#   ./build_hr_gpio.sh
#
# DDIO half order, checked by simulating the generated IP in Questa: the
# LOWER half of din is driven while the clock is high (the first half of
# the cycle), the upper half while it is low; on input the lower half of
# dout is the value captured at the rising edge, the upper half at the
# falling edge.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/sopc_builder/bin:$PATH"

common=(--component-name=altera_gpio --family="Agilex 3" --part=A3CY100BM16AE7S)

# DQ[7:0] + RWDS (bit 8): bidirectional DDIO, input clock (read clock) and
# output clock (core clock) separate, per-bit output enable
ip-deploy "${common[@]}" --output-name=hr_dq_io \
    -cp=PIN_TYPE_GUI=Bidir -cp=SIZE=9 -cp=gui_io_reg_mode=DDIO \
    -cp=gui_separate_io_clks=1 -cp=gui_use_oe=1

# CK: output DDIO on the 270 degree clock
ip-deploy "${common[@]}" --output-name=hr_ck_io \
    -cp=PIN_TYPE_GUI=Output -cp=SIZE=1 -cp=gui_io_reg_mode=DDIO

# CS#, RESET#: no GPIO IP - plain fabric registers on the core clock in
# hyperram_pins.vhd. They share an I/O lane with CK (pins D8/F7 next to D7),
# and one lane's output registers take only one clock: CK's DDIO uses the
# 270 degree clock, so registering CS#/RESET# in the I/O cells on the 0 degree
# clock fails placement ("cannot find routing connectivity" from the IOPLL).
