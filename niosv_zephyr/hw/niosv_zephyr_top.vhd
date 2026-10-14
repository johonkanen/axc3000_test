-- ------------------------------------------------------------------------
-- niosv_zephyr_top - board-level wrapper around the Platform Designer
-- system (niosv_zephyr_sys.qsys: Nios V/g + 256 KB on-chip RAM + JTAG UART)
-- plus a standalone HyperRAM bring-up block (Phase 5/6, electrical and
-- calibration-only so far - see niosv_zephyr/README.md).
--
-- The HyperRAM core (source/hVHDL_memory_library's hyperram_axi) is not
-- yet wired onto Nios V/g's bus: its AXI3 port is tied off (arw_valid='0')
-- below. This phase only proves the physical pins, clocking and the
-- core's own calibration self-test work on real silicon; status/debug is
-- read back by Nios V/g over four read-only PIO registers
-- (pio_hr_status/_debug_lo/_debug_hi/_timeouts, exported from
-- niosv_zephyr_sys as hr_status/hr_debug_lo/hr_debug_hi/hr_timeouts), via
-- a plain double-flop synchroniser into the 25 MHz Nios V domain - fine
-- for diagnostics polled by software, not a tight real-time path.
--
-- Clocking: ONE PLL (rpll0), instantiated directly here rather than folded
-- into niosv_zephyr_sys.qsys (nesting it there is what broke placement -
-- see below). rpll0 is a standalone, dynamically-reconfigurable I/O PLL
-- (gui_en_iossm_reconf=true), refclk'd straight from the board's 25 MHz
-- oscillator (clk_clk) - the same net uart_bringup_top.vhd's pll_100
-- already uses. A flat .ip (ip/rpll0/rpll0.ip, built from pll_100.ip -
-- see build_rpll0.tcl), not a Platform Designer "system".
--
-- Three 100 MHz outputs, all from the 2400 MHz VCO:
--   outclk0 (C0)  0 deg    hyperram_core's clock, CS#/RESET# and DQ/RWDS
--                          output registers - never reconfigured
--   outclk1 (C1)  0 deg    the read clock (DQ/RWDS input DDIO), its phase
--                          swept at runtime by the core's calibration
--                          through hyperram_pll_reconfig.vhd
--   outclk2 (C2)  270 deg  the CK pin's DDIO ("the inverted 90 degree
--                          clock" the core expects) - a static, compile-time
--                          phase (it does apply: the IP sets C2's Counter
--                          Preset to 19, 7500 ps), never reconfigured
-- Writing a counter's phase moves only that counter's output.
--
-- Reconfiguration path: rpll0's pll_calbus/pll_calbus_readdata ports go
-- to emif_cal (ip/emif_cal/emif_cal.qsys, a wrapped qsys system around an
-- emif_io96b_cal instance), which bridges them to a plain AXI4-Lite slave
-- that hyperram_pll_reconfig.vhd drives directly - Sec. 6.1 "Implementing
-- HSIO I/O PLL Reconfiguration using EMIF Calibration IP" of the Agilex 3
-- Clocking and PLL User Guide (847921), not Sec. 6.2's HVIO mailbox. This
-- part's package (M16A) has zero HVIO banks at all (confirmed from
-- Intel's own pin-information table for A3CY100B), so gui_en_hvio_reconf
-- and the direct core_avl_* mailbox an earlier version of this file used
-- are architecturally unusable here - every Fitter error chasing that
-- path ("no routing connectivity between the IOPLL and destination
-- CORE_LOGIC", reproduced identically whether cascaded behind an upstream
-- PLL, standalone, or qsys-wrapped) was Quartus correctly reporting that
-- the feature doesn't exist on this package, not a wiring mistake.
-- gui_en_iossm_reconf is the sibling parameter for the HSIO/IOSSM path
-- instead, found via the Agilex 3 evaluation kit's own working LPDDR4
-- EMIF example (which calibrates its PLL through the same emif_io96b_cal
-- component). Confirmed end to end, not guessed: Fitter places+routes
-- clean, and a Questa simulation of the AXI4-Lite path did a correct,
-- byte-exact read-modify-write round trip on a live PLL register. See
-- the session's project memory for the full diagnostic trail.
-- ------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.hyperram_pkg.all;

-- Platform Designer registers each generated SYSTEM under a library named
-- after the system, not "work" - a plain `entity work.<name>` instantiation
-- fails to resolve ("design library altera_work does not contain primary
-- unit ..."). rpll0 is a flat .ip rather than a system, so it doesn't need
-- (or get) its own library - component style instead, below. emif_cal is
-- a real system (emif_io96b_cal composes into ~13 sub-modules of its own),
-- so it does need one.
library niosv_zephyr_sys;
library emif_cal;

entity niosv_zephyr_top is
    port (
        clk_clk       : in std_logic;  -- 25 MHz board oscillator, pin A7
        reset_reset_n : in std_logic;  -- board reset, active low, pin A12

        -- AXC3000 onboard HyperRAM (128 Mb/16 MB, x8) - see
        -- docs/hyperram_pinout.md for the pin table and its source.
        hr_clk      : out   std_logic;
        hr_csn      : out   std_logic;
        hr_resetn   : out   std_logic;
        hr_rwds     : inout std_logic;
        hr_dq       : inout std_logic_vector(7 downto 0)
    );
end entity niosv_zephyr_top;

architecture rtl of niosv_zephyr_top is

    -- rpll0 - a clone of ip/pll_100/pll_100.ip (see ip/rpll0/rpll0.ip),
    -- with a second output clock and gui_en_iossm_reconf added. Component
    -- style, like pll_100's own usage in uart_bringup_top.vhd - a
    -- standalone flat .ip, not a qsys system.
    component rpll0 is
        port (
            refclk              : in  std_logic := 'X';
            locked              : out std_logic;
            rst                 : in  std_logic := 'X';
            pll_calbus          : in  std_logic_vector(57 downto 0) := (others => 'X');
            pll_calbus_readdata : out std_logic_vector(31 downto 0);
            outclk_0            : out std_logic;
            outclk_1            : out std_logic;
            outclk_2            : out std_logic
        );
    end component rpll0;

    signal rpll_rst     : std_logic;
    signal rpll_locked : std_logic;
    signal rpll_clk0, rpll_clk1, rpll_clk2 : std_logic;
    signal hyperram_reset : boolean;

    signal rpll_calbus          : std_logic_vector(57 downto 0);
    signal rpll_calbus_readdata : std_logic_vector(31 downto 0);

    signal axil_awaddr  : std_logic_vector(26 downto 0);
    signal axil_awvalid : std_logic;
    signal axil_awready : std_logic;
    signal axil_araddr  : std_logic_vector(26 downto 0);
    signal axil_arvalid : std_logic;
    signal axil_arready : std_logic;
    signal axil_wdata   : std_logic_vector(31 downto 0);
    signal axil_wvalid  : std_logic;
    signal axil_wready  : std_logic;
    signal axil_rresp   : std_logic_vector(1 downto 0);
    signal axil_rdata   : std_logic_vector(31 downto 0);
    signal axil_rvalid  : std_logic;
    signal axil_rready  : std_logic;
    signal axil_bresp   : std_logic_vector(1 downto 0);
    signal axil_bvalid  : std_logic;
    signal axil_bready  : std_logic;

    signal phase_shift : pll_phase_shift_record;

    signal fpga_out : hyperram_ddr_fpga_out_record;
    signal fpga_in  : hyperram_ddr_fpga_in_record;

    signal hr_status_bits  : std_logic_vector(31 downto 0);
    signal hr_debug_bits   : std_logic_vector(63 downto 0);
    signal hr_timeouts_cnt : unsigned(15 downto 0);

    -- plain double-flop synchronisers, clock_0 domain -> the 25 MHz Nios V
    -- domain (clk_clk, which cb/rb pass through unchanged). Diagnostics
    -- only, polled by software - not claiming per-bit atomicity.
    signal status_sync_0, status_sync_1       : std_logic_vector(31 downto 0) := (others => '0');
    signal debug_lo_sync_0, debug_lo_sync_1   : std_logic_vector(31 downto 0) := (others => '0');
    signal debug_hi_sync_0, debug_hi_sync_1   : std_logic_vector(31 downto 0) := (others => '0');
    signal timeouts_sync_0, timeouts_sync_1   : std_logic_vector(31 downto 0) := (others => '0');

begin

    rpll_rst       <= not reset_reset_n;
    hyperram_reset <= (rpll_locked /= '1');

    u_rpll : component rpll0
        port map (
            refclk              => clk_clk,
            rst                 => rpll_rst,
            locked              => rpll_locked,
            outclk_0            => rpll_clk0,
            outclk_1            => rpll_clk1,
            outclk_2            => rpll_clk2,

            pll_calbus          => rpll_calbus,
            pll_calbus_readdata => rpll_calbus_readdata
        );

    u_emif_cal : entity emif_cal.emif_cal
        port map (
            clk_clk       => clk_clk,
            reset_reset_n => reset_reset_n,

            calbus_pll0_calbus          => rpll_calbus,
            calbus_pll0_calbus_readdata => rpll_calbus_readdata,

            s_axil_awaddr  => axil_awaddr,
            s_axil_awvalid => axil_awvalid,
            s_axil_awready => axil_awready,
            s_axil_araddr  => axil_araddr,
            s_axil_arvalid => axil_arvalid,
            s_axil_arready => axil_arready,
            s_axil_wdata   => axil_wdata,
            s_axil_wvalid  => axil_wvalid,
            s_axil_wready  => axil_wready,
            s_axil_rresp   => axil_rresp,
            s_axil_rdata   => axil_rdata,
            s_axil_rvalid  => axil_rvalid,
            s_axil_rready  => axil_rready,
            s_axil_bresp   => axil_bresp,
            s_axil_bvalid  => axil_bvalid,
            s_axil_bready  => axil_bready,
            s_axil_awprot  => (others => '0'),
            s_axil_arprot  => (others => '0'),
            s_axil_wstrb   => (others => '1')
        );

    u_rpll_reconfig : entity work.hyperram_pll_reconfig
        port map (
            clock      => clk_clk,
            reset      => rpll_rst,
            pll_locked => rpll_locked,

            axil_awaddr  => axil_awaddr,
            axil_awvalid => axil_awvalid,
            axil_awready => axil_awready,
            axil_araddr  => axil_araddr,
            axil_arvalid => axil_arvalid,
            axil_arready => axil_arready,
            axil_wdata   => axil_wdata,
            axil_wvalid  => axil_wvalid,
            axil_wready  => axil_wready,
            axil_rdata   => axil_rdata,
            axil_rvalid  => axil_rvalid,
            axil_rready  => axil_rready,
            axil_bvalid  => axil_bvalid,
            axil_bready  => axil_bready,

            dps_shift        => phase_shift.shift,
            dps_shift_enable => phase_shift.shift_enable
        );

    u_hyperram_pins : entity work.hyperram_pins
        port map (
            clock_0  => rpll_clk0,
            clock_ck => rpll_clk2,
            clock_rd => rpll_clk1,
            fpga_out => fpga_out,
            fpga_in  => fpga_in,
            hr_clk    => hr_clk,
            hr_csn    => hr_csn,
            hr_resetn => hr_resetn,
            hr_rwds   => hr_rwds,
            hr_dq     => hr_dq
        );

    u_hyperram_axi : entity work.hyperram_axi
        port map (
            clock => rpll_clk0,
            reset => hyperram_reset,

            arw_valid => '0',
            arw_ready => open,
            arw_addr  => (others => '0'),
            arw_id    => (others => '0'),
            arw_len   => (others => '0'),
            arw_size  => "000",
            arw_burst => "00",
            arw_write => '0',

            w_valid => '0',
            w_ready => open,
            w_data  => (others => '0'),
            w_strb  => (others => '0'),
            w_last  => '0',

            b_valid => open,
            b_ready => '0',
            b_id    => open,

            r_valid => open,
            r_ready => '0',
            r_data  => open,
            r_id    => open,
            r_resp  => open,
            r_last  => open,

            calibration_done   => open,
            calibration_passed => open,
            status             => hr_status_bits,
            read_timeouts      => hr_timeouts_cnt,
            debug              => hr_debug_bits,

            phase_shift        => phase_shift,
            phase_shift_output => 0,
            fpga_out           => fpga_out,
            fpga_in            => fpga_in
        );

    sync : process(clk_clk)
    begin
        if rising_edge(clk_clk) then
            status_sync_0   <= hr_status_bits;
            status_sync_1   <= status_sync_0;
            debug_lo_sync_0 <= hr_debug_bits(31 downto 0);
            debug_lo_sync_1 <= debug_lo_sync_0;
            debug_hi_sync_0 <= hr_debug_bits(63 downto 32);
            debug_hi_sync_1 <= debug_hi_sync_0;
            timeouts_sync_0 <= std_logic_vector(resize(hr_timeouts_cnt, 32));
            timeouts_sync_1 <= timeouts_sync_0;
        end if;
    end process;

    u_sys : entity niosv_zephyr_sys.niosv_zephyr_sys
        port map (
            clk_in_clk       => clk_clk,
            reset_in_reset_n => reset_reset_n,
            hr_status_export   => status_sync_1,
            hr_debug_lo_export => debug_lo_sync_1,
            hr_debug_hi_export => debug_hi_sync_1,
            hr_timeouts_export => timeouts_sync_1
        );

end architecture rtl;
