#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# VUnit test runner for this repo's VHDL testbenches. Mirrors
# source/hVHDL_memory_library/vunit_run_memory_library.py's convention - see
# that file's own testbenches (e.g. testbench/hyperram/hyperram_axi_tb.vhd)
# for the pattern these ones follow: `generic (runner_cfg : string)`,
# `library vunit_lib; context vunit_lib.vunit_context;`, named tests via
# `if run("name") then ... end if;` inside `while test_suite loop`.
#
#   python3 run.py            # run everything
#   python3 run.py -l         # list the individual tests
#   python3 run.py *priority* # run tests matching a pattern
# ---------------------------------------------------------------------------
from pathlib import Path
from vunit import VUnit

ROOT = Path(__file__).resolve().parent
FP = ROOT / "source/hVHDL_floating_point"

VU = VUnit.from_argv(vhdl_standard="2019")

# float -> fixed-point conversion (uart_bringup addr 56/57/58)
f2f = VU.add_library("float_to_fixed_lib")
f2f.add_source_files(FP / "vhdl2008/float_typedefs_generic_pkg.vhd")
f2f.add_source_files(ROOT / "float_to_fixed.vhd")
f2f.add_source_files(ROOT / "sim/float_to_fixed_tb.vhd")

# FMA pipeline latency, behavioural model (uart_bringup addr 54/55)
fma = VU.add_library("fma_latency_lib")
fma.add_source_files(FP / "vhdl2008/float_typedefs_generic_pkg.vhd")
fma.add_source_files(FP / "vhdl2008/multiply_add_entity.vhd")
fma.add_source_files(FP / "vhdl2008/altera/sim_native_fp32.vhd")
fma.add_source_files(FP / "vhdl2008/altera/multiply_add_arch_agilex.vhd")
fma.add_source_files(ROOT / "sim/fma_latency_tb.vhd")

# Nios V/g <-> HyperRAM AXI4-Lite bridge (niosv_zephyr, Phase 5)
hr_bridge = VU.add_library("hyperram_bridge_lib")
hr_bridge.add_source_files(ROOT / "niosv_zephyr/hw/hyperram_axi4lite_bridge.vhd")
hr_bridge.add_source_files(ROOT / "niosv_zephyr/hw/sim/hyperram_axi4lite_bridge_tb.vhd")

VU.main()
