# build_rpll0.tcl - how rpll0.ip was derived from the repo-root's own
# proven, hardware-verified ip/pll_100/pll_100.ip (copied in as a starting
# point, not hand-typed from scratch, same convention as
# ip/hpll0/modify_upstream.tcl): add a second output clock and turn on
# dynamic IOSSM reconfiguration. Already applied and committed - this file
# is the reproducible record, not something build_all.sh re-runs.
#
# Deliberately a FLAT .ip, not wrapped in its own Platform Designer
# "system" - same convention pll_100.ip/hpll0.ip already use, and
# simplest given the PLL's own reconfiguration ports (pll_calbus/
# pll_calbus_readdata) are plain native ports regardless, no system-level
# export needed to reach them.
#
# gui_en_iossm_reconf, NOT gui_en_hvio_reconf: this part's package
# (M16A) has zero HVIO banks at all (confirmed from Intel's own pin-
# information table for A3CY100B) - the HVIO reconfiguration mailbox
# (Sec. 6.2 of the Clocking and PLL User Guide, doc 847921) is
# architecturally unusable here, which is what the "no routing
# connectivity between the IOPLL and destination CORE_LOGIC" Fitter error
# an earlier session hit was actually reporting - not a cascading or
# qsys-wrapping problem (both were tried and ruled out). The correct
# mechanism for an HSIO-bank part like this one is Sec. 6.1, "Implementing
# HSIO I/O PLL Reconfiguration using EMIF Calibration IP" -
# gui_en_iossm_reconf exposes the matching pll_calbus/pll_calbus_readdata
# ports, bridged to a plain AXI4-Lite slave by a separate emif_io96b_cal
# instance (see ip/emif_cal/build_emif_cal.tcl). Found via the Agilex 3
# evaluation kit's own working LPDDR4 EMIF example, and confirmed
# end-to-end: Fitter places+routes clean, and a real Questa simulation of
# the AXI4-Lite path did a correct, byte-exact read-modify-write round
# trip on a live PLL register. See the session's project memory for the
# full diagnostic trail.
#
#   cp ../../../../ip/pll_100/pll_100.ip rpll0.ip
#   qsys-script --script=build_rpll0.tcl
#
package require qsys
load_system rpll0.ip
set_instance_parameter_value pll_100 gui_number_of_clocks 2
set_instance_parameter_value pll_100 gui_output_clock_frequency1 100.0
set_instance_parameter_value pll_100 gui_en_iossm_reconf true
save_system rpll0.ip
