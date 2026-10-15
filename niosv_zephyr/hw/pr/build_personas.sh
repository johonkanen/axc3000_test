#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build_personas.sh - the PR demo's other personas, after the base revision:
#
#   PR_DEMO=1 ./build_all.sh          (hw/: the base revision, persona "blue")
#   pr/build_personas.sh              (this: persona "green")
#
# The base revision's static region (everything but the blinker partition)
# is exported as a finalized snapshot (output_files/static.qdb); each
# persona is a PR implementation revision that imports it and compiles only
# its own entity in the partition (ENTITY_REBINDING). Bitstreams (the SDM
# devices' PR bitstreams are written by the Assembler itself):
#   output_files/niosv_zephyr.sof            the full design, persona blue
#   output_files/niosv_zephyr.blinker.rbf    persona blue, for PR
#   output_files/impl_green.blinker.rbf      persona green, for PR
# A change to the static region means rebuilding every persona.
# ---------------------------------------------------------------------------
set -euo pipefail
HW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HW"
export PATH="$HOME/altera_pro/26.1.1/quartus/bin:$PATH"

[ -f output_files/niosv_zephyr.blinker.rbf ] || {
    echo "no base revision with the PR region - run PR_DEMO=1 ./build_all.sh first" >&2
    exit 1
}

echo "### export the static region (base revision, final snapshot)"
quartus_cdb niosv_zephyr -c niosv_zephyr --export_block root_partition --snapshot final \
    --file output_files/static.qdb --include_sdc_entity_in_partition

echo "### persona green: the impl_green revision"
cat > output_files/impl_green.tcl <<TCL
package require ::quartus::project
project_open niosv_zephyr -revision niosv_zephyr
if {[revision_exists impl_green]} { delete_revision impl_green }
create_revision impl_green -based_on niosv_zephyr
set_current_revision niosv_zephyr
project_close
project_open niosv_zephyr -revision impl_green
set_global_assignment -name REVISION_TYPE PR_IMPL
set_instance_assignment -name QDB_FILE_PARTITION $HW/output_files/static.qdb -to |
set_instance_assignment -name ENTITY_REBINDING blinker_green -to pr_demo.u_blinker
set_global_assignment -name VHDL_FILE $HW/pr/blinker_green.vhd
export_assignments
project_close
TCL
quartus_sh -t output_files/impl_green.tcl
quartus_syn niosv_zephyr -c impl_green
quartus_fit niosv_zephyr -c impl_green
quartus_sta niosv_zephyr -c impl_green
quartus_asm niosv_zephyr -c impl_green

ls -la output_files/niosv_zephyr.sof output_files/niosv_zephyr.blinker.rbf output_files/impl_green.blinker.rbf
