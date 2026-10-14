# Agilex 3 dynamic I/O PLL reconfiguration (phase shift at runtime)

How to get a runtime-adjustable, non-zero phase shift out of an
`altera_iopll` on Agilex 3 - specifically on the AXC3000's part,
`A3CY100BM16AE7S` (M16A package). Working, hardware-confirmed reference
implementation: `niosv_zephyr/hw/` - `ip/rpll0/`, `ip/emif_cal/`,
`hyperram_pll_reconfig.vhd`, wired up in `niosv_zephyr_top.vhd`.

## The one decision that matters: HVIO vs HSIO

The Agilex 3 Clocking and PLL User Guide (Intel/Altera doc 847921)
describes **two unrelated reconfiguration mechanisms**, and picking the
wrong one wastes a lot of time (it did, the first time around on this
project) because both *look* plausible from the IP parameter editor and
only fail at the Fitter stage, with a misleading error.

Check which one applies **before** touching the PLL's parameters, by
looking up the target part/package in Intel's own pin-information table
(`docs.altera.com`, resource varies by part - search "pin information
for the Agilex 3 <part>" - e.g. resource 851506 for `A3CY100B`). It lists
every bank by type (`HSIO` or `HVIO`) and how many pins of each exist per
package:

- If your part's **package has HVIO banks** → Sec. 6.2, "Implementing
  HVIO I/O PLL Reconfiguration." PLL parameter: `gui_en_hvio_reconf`.
  Direct Avalon-MM-style mailbox (`core_avl_*` ports), no bridge IP
  needed.
- If it **doesn't** (true for M16A, the AXC3000's package - zero HVIO
  banks at all) → Sec. 6.1, "Implementing HSIO I/O PLL Reconfiguration
  using EMIF Calibration IP." PLL parameter: `gui_en_iossm_reconf`.
  Needs a separate bridge IP (`emif_io96b_cal`) to reach it from an
  AXI4-Lite master - see below.

**Symptom of picking the wrong one:** `gui_en_hvio_reconf=true` generates
fine and even looks right in simulation of the PLL alone, but
`quartus_fit` fails with:

```
Error (175006): There is no routing connectivity between the IOPLL and destination CORE_LOGIC
```

on *every* candidate placement site, regardless of cascading, qsys
wrapping, or how many output clocks are used - because the feature
genuinely doesn't exist on that package, and nothing about the error
message says so directly. Don't chase cascading, clock network
topology, or qsys wrapping as the fix once you see this error - check
the pin table first.

A useful tell if you're not sure yet which family a given part belongs
to for IP-support purposes: check `altera_iopll`'s generated port
comment after turning a candidate reconfig parameter on - it says which
upstream block the mailbox talks to ("AVL interface ... from IOSSM" for
the HSIO/IOSSM path).

## The HSIO/IOSSM path (what M16A/A3CY100 actually needs)

### 1. PLL side

On the `altera_iopll` instance (same IP used for any plain fixed PLL -
clone an existing proven one rather than hand-typing a new instance from
scratch):

```tcl
set_instance_parameter_value <inst> gui_en_iossm_reconf true
```

This exposes two new ports, with no other parameter changes needed and
no cascading/qsys-wrapping required - keep the PLL a flat `.ip`, same
convention as any other plain PLL in this repo:

```
pll_calbus          : in  std_logic_vector(57 downto 0)
pll_calbus_readdata : out std_logic_vector(31 downto 0)
```

`pll_calbus[57:0]` bit layout (from the IP's own `altera_iopll_init.tcl`):
`[31:0]`=write data, `[53:32]`=address (22 bits), `[54]`=read, `[55]`=write,
`[56]`=clk, `[57]`=rst_n. You never drive this bus directly by hand -
wire it straight to the bridge IP below.

### 2. Bridge IP: `emif_io96b_cal`

A separate IP (`ip/altera/emif_io96b/ip_cal/` in the Quartus
installation) translates a plain AXI4-Lite slave into this calibration
bus. **Not** `emif_ph2_cal`, a similarly-named but different IP family
that does not support Agilex 3 at all (its `qsys-generate` fails outright
with "Component ... does not support selected device family Agilex 3" -
confirmed by trying it). `emif_io96b_cal` is the one Intel's own Agilex 3
evaluation kit uses to calibrate its LPDDR4 EMIF's PLL
(`examples/bts_emif/` in the dev kit package) - if in doubt which IP
family applies to a given part, check what the matching evaluation kit's
own EMIF example uses.

Build it as its own small wrapped qsys system (unlike the PLL, this one
*does* need wrapping - it composes into ~13 sub-modules of its own, e.g.
a JTAG-Avalon debug bridge, included even when unused):

```tcl
add_instance cal0 emif_io96b_cal
set_instance_parameter_value cal0 NUM_CALBUS_PLLS 1
set_instance_parameter_value cal0 NUM_CALBUS_PERIPHS 0
set_instance_parameter_value cal0 PORT_S_AXIL_MODE FABRIC
```

Gotchas on these parameters, found the hard way:
- `PORT_S_AXIL_MODE`'s real Tcl enum value is `FABRIC` - not the GUI
  display string `"Connect to Fabric"`, not `PORT_S_AXIL_MODE_FAB`. Both
  of those get rejected at generation time with "out of range" or
  "undefined enum" errors. Find the real enum keys in the IP's own
  `enum_defs/dropdowns.tcl` if a different parameter ever needs this.
- `NUM_CALBUS_PLLS=1` is enough for a single PLL - its base address on
  the calibration bus is then **0** (see "Register map" below).
- `save_system` writes a **persistent per-instance `.ip` file**
  alongside the `.qsys` (e.g. `ip/emif_cal/ip/emif_cal/emif_cal_cal0.ip`).
  This file matters - it holds the resolved parameterization. Deleting
  it (easy to do by mistake when cleaning up generated build output,
  since it lives inside an `ip/` subdirectory that otherwise holds
  throwaway generated trees) makes a later `qsys-generate` on the
  `.qsys` silently produce an empty top-level stub with no real
  calibration logic inside - **no error, just wrong**. If it's ever
  missing, regenerate with `qsys-script --script=build_emif_cal.tcl`
  (needs a scratch Quartus project first:
  `quartus_sh --prepare -f "Agilex 3" -d <part> <name>`).

Export/wire:
- `cal0.s0_axi4lite_clk` / `s0_axi4lite_rst_n` / `s0_axi4lite` (the
  AXI4-Lite slave) → your own reconfiguration master logic.
- `cal0.calbus_pll_0` (a conduit) → the PLL's `pll_calbus` /
  `pll_calbus_readdata`, directly, in the top-level VHDL (not through a
  qsys connection - the PLL stays a separate flat `.ip`).

### 3. Register map (same for HVIO and HSIO - only the bridge differs)

Table 21 in the Clocking and PLL User Guide, "Address Bus and Data Bus
Settings":

| address | field | meaning |
|---|---|---|
| `0x10` | data`[0]` | enable registers for read-modify-write (write once, early) |
| `0x5C + 4*N` | whole 32-bit word | C-counter N's divide/phase register |
| ... | data`[7:0]` | high_count |
| ... | data`[30:23]` | low_count |
| ... | data`[18:11]` | "Counter Preset" - coarse phase steps, default 1 = no shift |
| ... | data`[21:19]` | **"Phase Mux Preset" - the dynamic phase shift field, 0-7, each 1/8 VCO period. This is the one to touch.** |
| ... | data`[31]` | odd division enable |
| ... | data`[8]` | bypass enable |

Read-modify-write to touch only the phase field - leave Counter Preset
and everything else exactly as `qsys-generate` already programmed it.

**No PLL reset/recalibrate step needed for a phase-only change** - and
in fact doing one is actively wrong, not just redundant:
- The guide's own intro text (Sec. 6.1/6.2) says recalibration is
  required after a reconfiguration that changes the *output frequency*,
  explicitly **not** for "clock gating or dynamic phase shift
  reconfiguration."
- Sec. 3.3 says resetting the PLL **undoes** any dynamic phase shift
  already applied, restoring the C counters' originally-programmed
  phase. If you reset after setting the phase, you lose it.

### 4. AXI4-Lite address encoding for the HSIO/IOSSM path specifically

`s0_axi4lite_awaddr`/`araddr[26:0]`:

```
[23:21] = fixed 3'b101
[20:13] = "I/O PLL Base Address" = 0  (the only PLL on this calibration bus)
[7:0]   = the register address from the table above (e.g. 0x5C)
```

i.e. `awaddr = 0xA00000 + <register address>`.

The base-address field (`[20:13]`) isn't spelled out anywhere in plain
text in the doc for the single-PLL case - this was confirmed by
simulation (see below), not derived from documentation. If you ever add
a second PLL or peripheral to the same calibration bus
(`NUM_CALBUS_PLLS`/`NUM_CALBUS_PERIPHS` > the ones you already have),
re-verify this - don't assume base address 0 still applies to every
instance.

This is a **plain, standard single-beat AXI4-Lite master** - full
awvalid/awready, wvalid/wready, bvalid/bready (write), arvalid/arready,
rvalid/rready (read) handshaking, nothing more exotic. Much simpler than
the HVIO mailbox's protocol (which needs a fixed 5-cycle preamble +
10-cycle transaction + 5-cycle idle gap per access, with no
`waitrequest` to poll - see the HVIO section of the same guide if that
path ever applies to a different part/package).

### Confirming it before trusting it on real hardware

Simulate the actual generated `altera_iopll` + `emif_io96b_cal` pair
(Questa/ModelSim - the encrypted device-library models involved can't be
read as plain source, and Quartus's own Fitter success only proves
placement, not correct register behavior). A clean check: read a live
C-counter register, confirm the decoded fields match documented
defaults, then do a real read-modify-write on just the phase field and
read it back - every other field should come back byte-for-byte
unchanged, and the phase field should show the new value. If that round
trip is clean, the address encoding and register map are both right.

(If Questa reports `License Issue: Invalid host` when trying to actually
run a simulation under WSL2 with a `usbipd`-style setup, that's a
licensing/environment problem unrelated to this PLL work - the license
file is typically node-locked to a MAC address; check
`~/.altera.quartus/questa_lic.dat`'s `HOSTID=` entries against this
machine's real MAC from `ip link show`, and re-issue the license from
Quartus's own license manager GUI if they don't match.)

## What doesn't work / isn't the problem (don't re-litigate these)

- **PLL-to-PLL cascading** is not required for dynamic reconfiguration
  of either kind, and the Agilex 3 fabric-feeding I/O PLL in an HVIO
  block doesn't support cascading at all regardless (Sec. 2.2.10).
  Cascading and the reconfiguration mailbox/bridge are unrelated IP
  features.
- **Wrapping the PLL in its own Platform Designer "system"** (instead of
  a flat `.ip`) is not what causes the HVIO Fitter error either - a flat
  `.ip` with `gui_en_hvio_reconf=true` fails identically to a wrapped
  one. The bridge IP (`emif_io96b_cal`) *does* need to be a wrapped
  system, though - that's unrelated and fine.
- **Direct DPS ports** (`gui_en_dps_ports` on `altera_iopll`) crash
  `qsys-generate` outright on this Quartus/Agilex 3 combination - not a
  usable path either way.
