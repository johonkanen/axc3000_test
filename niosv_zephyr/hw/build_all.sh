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
#
# CPU_CLOCK_MHZ (default 120) sets the Nios V/g clock - rpll0's outclk3, any
# integer divisor of its 2400 MHz VCO (25, 100, 120, 150, 200, ...):
#
#   CPU_CLOCK_MHZ=150 ./build_all.sh
# The Zephyr build must match: -DNIOSV_CPU_HZ=150000000 (default 120 MHz,
# see apps/niosv_cpu_clock.cmake).
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
       ip/hr_gpio/hr_dq_io ip/hr_gpio/hr_ck_io \
       ip/rpll0/build_rpll0.qpf ip/rpll0/build_rpll0.qsf bake_hex_into_ram.qpf bake_hex_into_ram.qsf \
       output_files db incremental_db dni qdb *.qws *.qpf *.qsf

export CPU_CLOCK_MHZ="${CPU_CLOCK_MHZ:-120}"   # 150 also closes, by 0.1 ns; 200 fails
echo "CPU clock: $CPU_CLOCK_MHZ MHz"

step "qsys-script: build the Platform Designer system"
qsys-script --cmd="set ::cpu_mhz $CPU_CLOCK_MHZ" --script=build_niosv_system.tcl

# MCUboot in ram0's initial contents, so the bitstream boots into it
# (mcuboot/build_mcuboot.sh builds it). MCUBOOT_ELF= (empty) leaves ram0 blank.
MCUBOOT_ELF="${MCUBOOT_ELF-$HERE/../zephyr/build_mcuboot/zephyr/zephyr.elf}"
if [ -n "$MCUBOOT_ELF" ]; then
    if [ ! -f "$MCUBOOT_ELF" ]; then
        echo "ERROR: MCUBOOT_ELF $MCUBOOT_ELF not found (mcuboot/build_mcuboot.sh, or MCUBOOT_ELF= for none)" >&2
        exit 1
    fi
    step "MCUboot into ram0's initial contents ($MCUBOOT_ELF)"
    mkdir -p output_files
    QUARTUS_ROOTDIR="$HOME/altera_pro/26.1.1/quartus" \
    "$HOME/altera_pro/26.1.1/niosv/bin/elf2hex" -i "$MCUBOOT_ELF" -o "$HERE/output_files/mcuboot.hex" \
        -b 0x0 -e 0x3FFFF -w 32 -r 4 --little-endian-mem
    qsys-script --system-file=niosv_zephyr_sys.qsys --cmd="set HEX_FILE $HERE/output_files/mcuboot.hex" \
        --script=bake_hex_into_ram.tcl
fi

step "qsys-generate: the top system (regenerates every instance itself)"
qsys-generate niosv_zephyr_sys.qsys --synthesis=VHDL --part=A3CY100BM16AE7S

step "qsys-script: rpll0's CPU clock output (outclk3 = $CPU_CLOCK_MHZ MHz)"
(cd ip/rpll0 && qsys-script --cmd="set ::cpu_mhz $CPU_CLOCK_MHZ" --script=build_rpll0.tcl)

step "qsys-generate: rpll0 (standalone flat .ip, dynamically-reconfigurable HSIO/IOSSM PLL)"
qsys-generate ip/rpll0/rpll0.ip --synthesis=VHDL --part=A3CY100BM16AE7S
# the CPU clock really is what was asked for (a silent fallback to the
# default once cost a whole round of builds)
if ! grep -q "output_clock_frequency3\" value=\"${CPU_CLOCK_MHZ}.0 MHz\"" ip/rpll0/rpll0/rpll0.xml; then
    echo "ERROR: rpll0 outclk3 is not ${CPU_CLOCK_MHZ} MHz:" >&2
    grep -o 'output_clock_frequency3" value="[^"]*"' ip/rpll0/rpll0/rpll0.xml >&2 || true
    exit 1
fi

step "qsys-generate: emif_cal (AXI4-Lite bridge to rpll0's calibration bus)"
qsys-generate ip/emif_cal/emif_cal.qsys --synthesis=VHDL --part=A3CY100BM16AE7S

step "qsys-generate: the HyperRAM pins' GPIO IP (I/O-cell DDIO)"
for g in hr_dq_io hr_ck_io; do
    qsys-generate ip/hr_gpio/$g.ip --synthesis=VHDL --part=A3CY100BM16AE7S
done

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
