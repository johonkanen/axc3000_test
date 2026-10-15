# Hyperflex and Hyper-Registers on the AXC3000 (Agilex 3)

Research notes, 2026-10-15. Device: Agilex 3 C-Series `A3CY100BM16AE7S`
(speed grade -7), Quartus Prime Pro 26.1.1 at `~/altera_pro/26.1.1`.

## Summary

- Agilex 3 has Hyper-Registers: it uses the second-generation Hyperflex core,
  same as Agilex 5 (Agilex 7 and Stratix 10 use the first generation). It is a
  reduced form with fewer Hyper-Register sites than Stratix 10, but not absent.
- Quartus uses them automatically (Hyper-Retiming in the Fitter's Retime
  stage). The designer's job is to remove what blocks retiming (async resets,
  initial values, preserve attributes, unregistered RAM/DSP boundaries, long
  loops) and to provide pipeline stages the retimer can move.
- The Nios V CPU loops cap it at ~150 MHz here; the gain is in our own VHDL.

## 1. Does Agilex 3 have Hyperflex / Hyper-Registers?

Yes.

- Agilex 3 Device Overview (817231), §3 "Second Generation Hyperflex Core
  Architecture": Hyper-Registers are bypassable registers "distributed
  throughout the FPGA fabric" and "available on every interconnect routing
  segment and at the inputs of all functional blocks". Claims on average 1.9x
  higher core fMAX than previous-generation FPGAs (marketing figure).
- In the second generation Altera reduced the number of registers to improve
  timing-closure time and fabric area.
- Agilex 3 LAB/ALM User Guide (846637): "Hyperflex registers are available in
  ALMs and carry chains", on the synchronous-clear and clock-enable inputs, all
  controlled by Quartus during retiming.
- Evidence from this project's builds (Quartus 26.1.1, A3CY100):
  - every build produces a `*.fit.retime.rpt`;
  - `niosv_zephyr/hw_cpu200/output_files/niosv_zephyr.fit.retime.rpt` lists
    "Bypassed Hyper-Register" sites on R6/C4 routing segments and at
    BLOCK_INPUT_MUX nodes;
  - `quartus_fit --help=fastforward` says the option is "only available for
    device families that support HyperFlex architecture", and the retime report
    points to the Fast Forward report.
- Documentation gap: the Quartus Pro User Guide 25.3 retiming/Fast Forward text
  still names only "Stratix 10, Agilex 7, and Agilex 5"; the Hyperflex
  Handbook's product tags include Agilex 3.

## 2. How Hyper-Registers are used

### Automatic

- **Hyper-Retiming:** the Fitter's Retime stage runs after Place/Route and
  moves ALM registers into Hyper-Registers; a Finalize stage fixes hold. About
  1.1-1.3x gain quoted.
- **Auto-pipelining** ("Enable Auto-Pipelining") is On by default; adds latency
  only where the RTL allows.
- **Reset Sequence Requirement** table: retiming can mean a clock domain needs
  extra reset cycles (the repo's `uart_bringup` build needs 2 extra cycles on
  `pll_100_outclk0`).

### Designer

- **Hyper-Pipelining:** add pipeline stages the retimer spreads through
  routing.
- **Hyper-Optimization:** restructure RTL - pre-computation, splitting loops,
  replacing multicycle paths with registers.

### Restrictions that block retiming (Handbook §6, Table 10)

| Restriction | Note |
|---|---|
| Asynchronous clear or preset | Hyper-Registers have no reset/preset/enable |
| Initial power-up conditions | Agilex Hyper-Registers power up to 1 |
| preserve / dont_touch / dont_merge attributes | |
| Endpoints of SDC exceptions | false path, multicycle |
| CDC registers and synchronizer chains | default chain length 3 |
| Latches, I/O boundaries, partition boundaries | |
| Locally-routed clocks, registers used as clock sources | |
| Loops | register count of a feedback loop cannot change |
| RAM/DSP boundaries | registers do not cross unless Allow RAM Retiming / Allow DSP Retiming (Assignments > Settings > Compiler Settings > Advanced (Fitter) > Register Optimization; QSF `ALLOW_RAM_RETIMING`, `ALLOW_DSP_RETIMING`) |

Limiting reasons in the critical chain report: Insufficient Registers; Short
Path/Long Path; Path Limit (no Hyper-Register sites left); Loops.

### Tools and settings

- **Fast Forward compile** (Compilation Dashboard or `quartus_fit
  --fastforward`) produces "Fast Forward Timing Closure Recommendations"
  reports (Clock Fmax Summary, Fast Forward Details) with step-by-step
  estimated fMAX if you remove restrictions or add N stages.
- Command-line stages: `quartus_fit --retime`, `--finalize`.
- QSF names in the 26.1.1 binaries:

  | QSF | Purpose |
  |---|---|
  | `ALLOW_REGISTER_RETIMING` | |
  | `ALLOW_HYPER_REGISTER_RETIMING` | |
  | `HYPER_RETIMER_FAST_FORWARD_ADD_PIPELINING_MAX` | |
  | `HYPER_RETIMER_FAST_FORWARD_ASYNCH_CLEAR` | emulates removing async clears |
  | `HYPER_RETIMER_FAST_FORWARD_USER_PRESERVE_RESTRICTION` | |
  | `HYPER_RETIMER_FAST_FORWARD_RAM_BLOCKS` | |
  | `HYPER_RETIMER_FAST_FORWARD_DSP_BLOCKS` | |
  | `HYPER_RETIMER_FAST_FORWARD_ON_HIERARCHY` | |

- Design Assistant HRR (Hyper-Retimer Readiness) rules flag restrictions
  before compile.

### The project's failing 200 MHz Nios V build (`hw_cpu200`)

- CPU clock (outclk3) limited by **Insufficient Registers**.
- "Not fully registered RAM": the `ram0` M20K output goes unregistered into the
  `mm_interconnect` read mux ("insert more pipeline stages after the RAM
  block").
- "Node uses an asynchronous clear port" on
  `cpu0|hart|core_inst|D_instr_word[15]`.
- Achieved fMAX 158.6 MHz on the 200 MHz target vs 150.26 MHz in the 150 MHz
  build (Slow 0C model).

## 3. Typical fMAX

Agilex 3 Device Data Sheet 848370, Memory Block Specifications (web version
4/28/2025; the 2025.08.11 revision updated these tables - re-check):

| Block | -6S | -7S |
|---|---|---|
| M20K single-port / simple dual-port | 550 MHz | 465 MHz |
| MLAB | 469 MHz | 400 MHz |
| M20K true dual-port | 335 MHz | 280 MHz |
| ECC 512x32, no pipeline | 330 MHz | 280 MHz |
| ECC 512x32, with optional pipeline | 550 MHz | 465 MHz |

- DSP block and clock-tree fMAX tables exist in 848370 but could not be
  opened - unverified.
- Product briefs quote "345 MHz fabric speed" (geomean of 45 QoR designs,
  speed grade not stated).
- Altera OpenCores benchmark: up to 62% higher fMAX than Lattice Certus-N2
  (vendor claim, no absolute MHz).
- Practical expectations for -7S (**estimates, not data-sheet values**):
  - well-pipelined fabric logic (no async resets, 1-2 LUT levels): roughly
    300-400 MHz;
  - the M20K ceiling of ~465 MHz caps memory-heavy pipelines;
  - soft CPUs and Avalon/AXI interconnects with long muxes and feedback loops
    land around 150 MHz.
- Limits: -7 is the slowest grade; loops can't be retimed; RAM/DSP
  boundaries; async resets in IP you don't control; routing distance between
  hard blocks.

## 4. VHDL coding guidelines

- **Reset:** synchronous or none on datapath registers, `rst` not in the
  sensitivity list:

  ```vhdl
  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ...
      end if;
      ...
    end if;
  end process;
  ```

  Reset only control and valid bits; let data pipelines naturally reset and
  qualify outputs with a valid bit. Bring the async reset in through a
  synchronizer, then duplicate and pipeline the synchronous reset tree
  (Handbook §3.2.1.4).
- **No initial values** on pipeline registers (avoid
  `signal x : ... := '0'`).
- **Pipeline depth as generics:** `generic (G_PIPE : natural := 2)` and
  `type pipe_t is array (0 to G_PIPE-1) of std_logic_vector(...)` as a shift
  register with no reset and no enable. Put the stages before or after the
  logic so the retimer can redistribute them.
- **Avoid wide clock-enable fan-outs** (Hyper-Registers have no enable, though
  2nd-gen Hyperflex registers sit on ALM sclr/ena inputs).
- **No preserve/keep/dont_merge** on pipeline registers.
- **Block RAM:** register outputs (`outdata_reg_b = "CLOCK1"`) plus one fabric
  stage after the RAM. **DSP:** use the IP's input, pipeline and output
  registers.
- **Feedback loops:** keep them short; loop unrolling or pre-computation.
- **CDC:** dedicated synchronizers plus a fabric stage on either side.

## What this means for this project

- The Nios V CPU clock is limited to ~150 MHz by its loops. The 200 MHz build
  (`hw_cpu200`) reached 158.6 MHz: Insufficient Registers, the unregistered
  `ram0` M20K output into the interconnect read mux, and an async clear in the
  CPU core. Most of that is inside Altera IP; Hyper-Retiming will not push the
  CPU much further.
- The gain is in our own VHDL in `niosv_zephyr/hw` (HyperRAM controller,
  UART, future datapaths):
  - synchronous or no resets on datapath registers, reset only control/valid;
  - no initial values on pipeline registers;
  - pipeline depth as a generic so stages can be added without rewriting;
  - registered RAM outputs plus one fabric stage;
  - run a Fast Forward compile (`quartus_fit --fastforward`) to see where each
    clock domain's limit is and what removing a restriction or adding stages
    would give.
- Check the Reset Sequence Requirement table in each `*.fit.retime.rpt`:
  retimed domains may need extra reset cycles (as `uart_bringup` does on
  `pll_100_outclk0`).

## Sources

### Local evidence (paths checked to exist)

- `niosv_zephyr/hw_cpu200/output_files/niosv_zephyr.fit.retime.rpt` - Bypassed
  Hyper-Register sites, 200 MHz build limiting reasons.
- `output_files/uart_bringup.fit.retime.rpt` - Reset Sequence Requirement (2
  extra cycles on `pll_100_outclk0`).
- `~/altera_pro/26.1.1/quartus/bin/quartus_fit --help=fastforward` - Fast
  Forward option, HyperFlex-only.

### Opened and resolving

- https://docs.altera.com/r/docs/683353/current - Hyperflex Architecture High-Performance Design Handbook, v25.1.1; tags include Agilex 3/5.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/hyperflex-architecture-rtl-design-guidelines - RTL guidelines chapter.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/removing-asynchronous-resets - why async resets block retiming; partial-reset patterns.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/initial-conditions-and-hyper-registers - power-up behaviour.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/retiming-through-rams-and-dsps - Allow RAM/DSP Retiming.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/retiming-restrictions-and-workarounds - restriction table, critical chains.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/compiling-hyperflex-architecture-designs - Retime stage, Fast Forward, Hyper-Aware flow.
- https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/design-example-walk-through - Median Filter example.
- https://docs.altera.com/r/docs/817231/current/agilextm-3-fpgas-and-socs-device-overview - Agilex 3 Device Overview.
- https://docs.altera.com/r/docs/817231/current/agilextm-3-fpgas-and-socs-device-overview/second-generation-hyperflex-core-architecture?contentId=qDcmjWlnk1bQmvajokgaFg - Agilex 3 Hyperflex section.
- https://docs.altera.com/r/docs/762191/current/agilex-5-fpgas-and-socs-device-overview/second-generation-hyperflex-core-architecture?contentId=AzcwWNi~_loaZmcc~7wPRg - same for Agilex 5.
- https://docs.altera.com/r/docs/683236/25.3/quartus-prime-pro-edition-user-guide/fast-forward-compilation-flow - Fast Forward flow.
- https://docs.altera.com/r/docs/683236/25.3/quartus-prime-pro-edition-user-guide/step-1-run-register-retiming - register retiming.
- https://go.altera.com/agilex3-fpga-opencores-benchmark - Agilex 3 vs Certus-N2 white paper (vendor).

### Found but not opened

intel.com docs pages now 301-redirect to a 404 handler; the shortened paths
below are as given in the research and are not complete URLs.

- intel.com/.../848370/current/memory-block-specifications.html - Agilex 3 Data Sheet M20K/MLAB fMAX (numbers from search snippet).
- intel.com/.../846637/current/register.html - Agilex 3 LAB/ALM guide, Hyperflex registers (docs.altera.com/r/docs/846637/current returned 404).
- intel.com/.../849313/25-1/... - Agilex 3 Variable Precision DSP User Guide.
- intel.com/.../836192/current/use-the-fast-forward-compilation-flow.html - AN 1016 Timing Closure Methodology Quick Reference.
- intel.com/.../683369/current/hyper-retimer-restrictions.html - AN 919, Design Assistant HRR rules.
- https://resources.altera.com/quartushelp/20.3/da_rules/hrr_10101.htm - HRR-10101 "Asynchronous Clears" rule.
- https://community.altera.com/discussions/quartus-prime/quartus-warning-res-50005/313193 - forum thread on avoiding async resets (returned 403).
- https://www.intel.com/content/www/us/en/content-details/652828/introduction-to-hyper-optimization.html - training asset.
- https://speakerdeck.com/fixstars/shi-jian-de-fpgakai-fa-semina-vol-dot-11 - Fixstars (Japanese), Agilex design at 848 MHz and 98% utilization; third-party.
- Altera eLearning courses (free on-demand; search the code in the Altera
  training catalog):

  | Code | Course | Length |
  |---|---|---|
  | FPGA_OS10IHYPRET | Introduction to Hyper-Retiming | 16 min |
  | FPGA_OS10EHYPRET | Eliminating Barriers to Hyper-Retiming | 35 min |
  | FPGA_OS10FFC | Fast Forward Compile | 30 min |
  | FPGA_OS10TOOLS | Hyper-Aware Design Flow | 24 min |
  | FPGA_OS10HYPOPT | Hyper-Optimization | 22 min |
  | FPGA_OHYPPRECOMP | Pre-Computation | 29 min |
  | FND-07 | Hyperflex Optimization Workshop | instructor-led, likely paid |

- No independent blog post with before/after Hyper-Retiming measurements on
  Agilex 3/5 found.

### Not confirmed

- M20K/MLAB fMAX numbers (from a search snippet of the 4/28/2025 data sheet;
  the 2025.08.11 revision changed these tables).
- DSP block and clock-tree fMAX on Agilex 3.
- The -7S fabric fMAX ranges in §3 are estimates.
