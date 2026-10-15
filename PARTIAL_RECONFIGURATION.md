# Partial reconfiguration on the AXC3000 (Agilex 3)

Research notes, 2026-10-15. Device: Agilex 3 C-Series `A3CY100BM16AE7S`
(speed grade -7), Quartus Prime Pro 26.1.1 at `~/altera_pro/26.1.1`.

## Summary

- Partial reconfiguration (PR) is supported on Agilex 3 C-Series.
- A Nios V in the static region can reconfigure its own FPGA through the
  **Partial Reconfiguration Controller IP** (`altera_s10_pr`). That IP has its
  own path into the SDM and does **not** go through the Mailbox Client IP.
- No SDM command loads a persona from flash. The CPU has to read the persona
  (for example from QSPI via the Mailbox Client) and stream it into the PR IP.
- Not confirmed: whether the no-cost Agilex 3 license allows PR compiles.

## 1. Is PR supported on Agilex 3?

Yes.

- In the Quartus 26.1.1 install, `SUPPORTED_DEVICE_FAMILIES` includes
  "Agilex 3" for all four PR IPs (paths relative to
  `~/altera_pro/26.1.1/ip/altera/`):

  | IP | File |
  |---|---|
  | PR Controller IP | `pgm/pr/altera_s10_pr/altera_s10_pr_hw.tcl:41` |
  | External Configuration Controller IP | `pgm/pr/altera_s10_pr_avst_ctrl/altera_s10_pr_avst_ctrl_hw.tcl:40` |
  | PR Region Controller IP | `eip/altera_pr_region_controller/top/altera_pr_region_controller_hw.tcl:40` |
  | Freeze bridges | `eip/altera_pr_freeze_bridge/*` |

- The Agilex 3 Device Configuration UG (847422, v26.1) has §6.3 "Partial
  Reconfiguration", §4.4 PR guidance and §2.5.3.4 PR pins.
- The PR UG (683834) "What's New" says: "Referenced support for Agilex 3
  devices".
- Contradiction: the older 25.1/25.3 "Getting Started" guide's PR family list
  leaves Agilex 3 out.
- License: no separate PR license is documented; PR is a Quartus Pro feature.
  Could not confirm that the no-cost Agilex 3 license enables PR. A trivial PR
  test compile will settle it.
- Errata: Quartus 23.2-25.1 could cause functional failures after PR on all
  Agilex devices. Fixed in 25.1.1, so 26.1.1 is fine.

## 2. Design flow

PR UG 683834 §2.6, steps 1-9, condensed:

1. Mark a partition as Reconfigurable.
2. Floorplan it with a Logic Lock region set to "Reserved" and "Core-only",
   plus a routing region. The region must not contain I/O, PLLs or clock
   sources.
3. Add the PR Controller IP, the PR Region Controller IP (freeze CSR/control)
   and freeze bridges (Avalon-MM/ST) at the region boundary.
4. Define personas and create one PR implementation revision per persona.
5. Compile the base revision and export the static region as a `.qdb`
   (finalized snapshot).
6. Each implementation revision imports that static `.qdb` and compiles only
   its persona. Every persona must be rebuilt whenever the base changes.

Output files:

- On SDM devices the Assembler writes the persona `.rbf` automatically ("You do
  not need to separately generate these files").
- The base `.sof`/`.pof`/RSU image carries the default persona.
- `.pmsf` merging applies only to Arria 10 / Cyclone 10 GX.

Limits: up to 32 PR regions with the compatibility check on; hierarchical PR
goes up to 6 levels.

## 3. Delivering the bitstream at runtime

### Internal host: PR Controller IP

`altera_s10_pr`, Avalon-ST or Avalon-MM, 32/64-bit, max 200 MHz. It wraps
`altera_config_stream_endpoint` (`intel_pr_mailbox_wrapper`), a dedicated
config stream into the SDM. It is not the Mailbox Client IP.

Avalon-MM register map (word offsets, from the unencrypted
`pgm/pr/altera_pr_mm/altera_pr_mm.sv.terp`):

| Offset | Function |
|---|---|
| 0 | bitstream data (write) |
| 1 | CSR: bit 0 start PR, [4:2] status, bit 4 IRQ, bit 5 clear IRQ |
| 2 | version |
| 3, 4 | SDM firmware handshake / response |
| 5-A | cycle counters |

Status codes:

| Status | Meaning |
|---|---|
| 001 | busy |
| 010 | in progress |
| 011 | success |
| 100 | PR_ERROR |
| 110 | incompatible bitstream |

Nios V driver loop: write start, poll status, write `.rbf` words to offset 0
(`waitrequest` back-pressures), poll for 011.

Static-region rule: the Nios, its memory, its interconnect and the PR IP must
all sit in the static region. The guide warns improper PR can corrupt static
logic or the config clock, so reset the PR IP before nCONFIG.

### Other hosts

| Host | Path |
|---|---|
| JTAG | Quartus Programmer |
| External host | External Configuration Controller IP plus PR_REQUEST/DONE/ERROR pins; data over AVST or AS depending on MSEL |
| HPS (Agilex 5/7, not on A3CY100) | SDM mailbox commands RECONFIG 0x06, RECONFIG_DATA 0x08, RECONFIG_STATUS 0x09; SDM reads buffers by DMA |

The Agilex 3 fabric mailbox command table (UG 847422 §5.3.1) lists no PR
command (only RSU_* and QSPI_*), so the Mailbox Client is not the PR path.

## 4. Storing personas in QSPI

- No SDM command loads a PR persona from flash; the internal host must supply
  the data.
- The persona `.rbf` can be stored in a spare QSPI area outside the RSU
  partitions, read through QSPI_READ via the Mailbox Client and streamed to the
  PR IP. The PR IP back-pressures, so a full buffer isn't strictly needed.
- Recommendation (unverified): copy the whole persona into HyperRAM first, then
  stream it. The SDM may refuse or stall QSPI mailbox commands while a PR
  operation is active, and a stalled stream mid-PR is risky.
- Personas are tied to the base build by the PR ID compatibility check. An RSU
  update of the static image needs matching rebuilt personas stored alongside
  it.

## 5. Examples and drivers

- AN 953 (PR) and AN 954 (hierarchical PR) target Agilex F-Series (Agilex 7)
  and use JTAG/Programmer. There is an F-Series external-host example using the
  External Configuration Controller IP.
- No Agilex 5/3 Design Store or GitHub example with a Nios V internal host
  found, and no Zephyr PR driver.
- Linux: a June 2026 patch series (Adrian Ng Ho Yin) adds fpga-mgr PR for
  Agilex 5 HPS via stratix10-svc. HPS-only, doesn't apply here.
- A Zephyr driver would be small and custom: CSR polling plus a word-write
  loop, with freeze control through the Region Controller CSR.

## 6. Practical gotchas

- Freeze sequence:
  1. write freeze_req to the Region Controller;
  2. wait for freeze_status/ack from the persona;
  3. run PR;
  4. assert the region reset;
  5. unfreeze.
- Freeze bridges keep Nios bus transactions into the region from hanging. Never
  let the CPU access the region during PR.
- Error recovery (Agilex only, UG §3.2.5): on PR_ERROR or incompatible status,
  keep writing until the rest of the bitstream has drained from the pipeline,
  then retry. The UG doesn't say what state the region is in after an error -
  treat it as invalid until a good persona loads. The static region is meant to
  keep running.
- Security: the authentication/encryption sections cover only Stratix 10 /
  Agilex 7. The compatibility check (`ENABLE_PR_POF_ID`) must stay on for
  authentication.
- The Reset Release IP is only needed for full configuration, not PR.
- Resources: the A3CY100 is small; region planning needs routing margin; the PR
  IP, Region Controller and freeze bridges cost static-region logic; timing
  closure per persona inside a fixed static region.
- PR duration and bitstream size scale with region area; no Agilex 3 figures
  published.

## What this means for this project

- **PR path:** the Partial Reconfiguration Controller IP, not our Mailbox
  Client. The Mailbox Client stays for QSPI/RSU; the PR IP is added next to it.
- **Static region:** the Nios V, its memory, the interconnect, the PR IP, the
  HyperRAM controller and the UART must all be in the static region. Only the
  reconfigurable datapath goes into the PR region, behind freeze bridges.
- **Persona storage:** free QSPI flash from `0x1800000` up in this project's
  layout:

  | Offset | Use |
  |---|---|
  | `0x800000` | RSU P1 |
  | `0xC00000` | RSU P2 |
  | `0x1000000` | MCUboot slot 0 |
  | `0x1400000` | MCUboot slot 1 |
  | `0x1800000`+ | free - persona `.rbf` files |

  Read a persona with QSPI_READ through the Mailbox Client, buffer it in
  HyperRAM, then stream it into the PR IP (avoids QSPI mailbox traffic during
  an active PR operation).
- **Versioning:** personas must be rebuilt whenever the static (base) revision
  changes. An RSU update of the base image (`update_bitstream.py program`)
  needs matching personas written alongside it, otherwise the compatibility
  check rejects them (status 110).
- **First step:** a trivial PR test compile (one small reconfigurable
  partition, two personas) to confirm the Agilex 3 license allows PR, before
  any driver or flash-layout work.

## Sources

### Local (Quartus 26.1.1 IP sources, all paths checked to exist)

Under `/home/jari/altera_pro/26.1.1/ip/altera/`:

- `pgm/pr/altera_s10_pr/altera_s10_pr_hw.tcl` - PR Controller IP, family list.
- `pgm/pr/altera_pr_mm/altera_pr_mm.sv.terp` - Avalon-MM register map and status codes.
- `pgm/pr/altera_pr_stream/altera_pr_stream_hw.tcl` - Avalon-ST variant.
- `pgm/pr/intel_pr_mailbox_wrapper/` - config stream endpoint into the SDM.
- `pgm/pr/altera_s10_pr_avst_ctrl/altera_s10_pr_avst_ctrl_hw.tcl` - External Configuration Controller IP.
- `eip/altera_pr_region_controller/` - PR Region Controller IP (freeze control).
- `eip/altera_pr_freeze_bridge/` - Avalon-MM/ST freeze bridges.

### Web

- PR UG 683834 (25.1), TOC: https://docs.altera.com/r/docs/683834/current
- PR UG §2.4 internal host PR: https://docs.altera.com/r/docs/683834/25.1/quartus-prime-pro-edition-user-guide-partial-reconfiguration/internal-host-partial-reconfiguration?contentId=Ixfiv2loOEoEUgRTNxUoCg
- PR UG §3.2 PR Controller IP: https://docs.altera.com/r/docs/683834/25.1/quartus-prime-pro-edition-user-guide-partial-reconfiguration/partial-reconfiguration-controller-ip?contentId=Il6Rhycd1GYwLgwV~TnCGg
- PR UG error recovery: https://docs.altera.com/r/docs/683834/25.1/quartus-prime-pro-edition-user-guide-partial-reconfiguration/pr-error-recovery?contentId=3RUDLTFwY2G0Pimvp_3Jbw
- PR UG bitstream compatibility checking: https://docs.altera.com/r/docs/683834/25.1/quartus-prime-pro-edition-user-guide-partial-reconfiguration/partial-reconfiguration-bitstream-compatibility-checking?contentId=QeOz145oSYNTteWK2Cmc4Q
- PR UG generating PR bitstream files: https://docs.altera.com/r/docs/683834/25.1/quartus-prime-pro-edition-user-guide-partial-reconfiguration/generating-pr-bitstream-files?contentId=5jkOo1VkdDE8JEIjbEwagg
- Agilex 3 Device Configuration UG 847422 §6.3 PR: https://docs.altera.com/r/docs/847422/26.1/device-configuration-user-guide-agilextm-3-fpgas-and-socs/partial-reconfiguration?contentId=D~OBg67PY3rNv4LkaAXg0g
- UG 847422 §4.4 PR guidance: https://docs.altera.com/r/docs/847422/26.1/device-configuration-user-guide-agilextm-3-fpgas-and-socs/guidance-when-using-partial-reconfiguration-pr?contentId=KEcgcucb2gkVJXSsYGeekQ
- UG 847422 §5.3.1 operation commands (no PR command): https://docs.altera.com/r/docs/847422/26.1/device-configuration-user-guide-agilextm-3-fpgas-and-socs/operation-commands?contentId=eHArUtppMg19XnkfnPlnCA
- Getting Started guide, PR family list without Agilex 3: https://www.intel.com/content/www/us/en/docs/programmable/683463/25-3/partial-reconfiguration-design.html
- PR errata (Quartus 23.2-25.1): https://intel.com/content/www/us/en/support/programmable/articles/000088734.html
- TF-A SDM mailbox command codes: https://github.com/ARM-software/arm-trusted-firmware/blob/master/plat/intel/soc/common/include/socfpga_mailbox.h
- AN 953, PR reference design (Agilex F-Series): https://www.intel.com/content/www/us/en/docs/programmable/683849/21-1/reference-design-walkthrough.html
- AN 954, hierarchical PR reference design: https://www.intel.com/content/www/us/en/docs/programmable/683687/21-1/reference-design-walkthrough.html
- Linux Agilex 5 HPS PR patches: https://lwn.net/Articles/1078949/

### Not confirmed

- Whether the no-cost Agilex 3 license enables PR.
- Whether the SDM stalls or refuses QSPI mailbox commands during an active PR
  operation (reason for the HyperRAM buffering recommendation).
- Region state after a PR error.
- PR duration and persona size on Agilex 3.
