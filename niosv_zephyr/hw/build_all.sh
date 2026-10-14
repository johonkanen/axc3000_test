#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build_all.sh - the full niosv_zephyr/hw build pipeline in one command:
# qsys-script, the top-level qsys-generate (which regenerates every
# instance itself - no separate per-instance pass needed, see
# build_niosv_project.tcl's header), then quartus_sh/syn/fit/sta/asm.
# Relocatable - everything resolves relative to
# this script's own directory, so copying the whole hw/ directory (e.g. via
# new_variant.sh) and running this from the copy just works, with no shared
# state between copies (no license contention either - this box runs in
# Quartus's LICENSE_FREE_MODE). That's what makes building several hardware
# variants in parallel straightforward:
#
#   ./new_variant.sh hyperram_experiment
#   (cd ../hw_hyperram_experiment && ./build_all.sh) &
#   ./build_all.sh &
#   wait
#
# Each quartus_fit uses every core it can find by default; set
# NUM_PARALLEL_PROCESSORS to cap that (useful so N parallel builds don't
# all fight over the same cores):
#
#   NUM_PARALLEL_PROCESSORS=8 ./build_all.sh
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/sopc_builder/bin:$PATH"

step() { echo; echo "########## $* ##########"; }

step "clean previously-generated output"
# qsys-generate's incremental reuse of existing generated content can land
# on stale library names/hashes that no longer match a freshly-regenerated
# top-level system file ("design library ... does not contain primary
# unit ..." even though generation itself reported success) - start from
# nothing every time rather than risk that.
rm -rf niosv_zephyr_sys.qsys niosv_zephyr_sys ip/niosv_zephyr_sys/niosv_zephyr_sys_*/ \
       ip/niosv_zephyr_sys/niosv_zephyr_sys_*_[0-9]*.ip \
       ip/rpll0/rpll0 ip/rpll0/dni ip/rpll0/qdb ip/rpll0/db ip/rpll0/incremental_db \
       ip/emif_cal/emif_cal ip/emif_cal/ip/emif_cal/emif_cal_cal0/ \
       ip/emif_cal/ip/emif_cal/emif_cal_cal0_*/ ip/emif_cal/ip/emif_cal/emif_cal_cal0_[0-9]*.ip \
       ip/emif_cal/dni ip/emif_cal/qdb ip/emif_cal/db ip/emif_cal/incremental_db \
       output_files db incremental_db dni qdb *.qws *.qpf *.qsf

step "qsys-script: build the Platform Designer system"
qsys-script --script=build_niosv_system.tcl

step "qsys-generate: the top system (regenerates every instance itself)"
qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S

step "qsys-generate: rpll0 (standalone flat .ip, dynamically-reconfigurable HSIO/IOSSM PLL)"
qsys-generate ip/rpll0/rpll0.ip --synthesis=VHDL --part=A3CY100BM16AE7S

step "qsys-generate: emif_cal (AXI4-Lite bridge to rpll0's calibration bus)"
qsys-generate ip/emif_cal/emif_cal.qsys --synthesis=VHDL --part=A3CY100BM16AE7S

step "quartus_sh: create/update the project"
# NUM_PARALLEL_PROCESSORS (if set) is read and applied inside
# build_niosv_project.tcl itself - see its header for why not here.
quartus_sh -t build_niosv_project.tcl

step "quartus_syn"
quartus_syn niosv_zephyr

step "quartus_fit"
quartus_fit niosv_zephyr

step "quartus_sta"
quartus_sta niosv_zephyr

step "quartus_asm"
quartus_asm niosv_zephyr

step "DONE - output_files:"
ls -la output_files/
