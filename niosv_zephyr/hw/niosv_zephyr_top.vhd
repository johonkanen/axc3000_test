-- ------------------------------------------------------------------------
-- niosv_zephyr_top - board-level wrapper around the Platform Designer
-- system (niosv_zephyr_sys.qsys: Nios V/g + 256 KB on-chip RAM + JTAG UART)
-- plus a standalone HyperRAM bring-up block (Phase 5/6, electrical and
-- calibration-only so far - see niosv_zephyr/README.md).
--
-- The HyperRAM (source/hVHDL_memory_library's hyperram_axi) is a 16 MB
-- window at 0x01000000 on both Nios V/g managers (data, and instructions -
-- Zephyr can execute from it): niosv_zephyr_sys
-- exports an AXI4-Lite manager (hr_axi, already crossed into the 100 MHz
-- HyperRAM clock domain by Platform Designer), and hyperram_axi4lite_bridge
-- adapts it to hyperram_axi's native port (32-bit transfers into its 64-bit
-- beats). Platform Designer merges both managers onto hr_axi, so the
-- bridge's own instruction-side port is unused (tied off).
-- Calibration status/debug is read back by Nios V/g over four read-only PIO
-- registers
-- (pio_hr_status/_debug_lo/_debug_hi/_timeouts, exported from
-- niosv_zephyr_sys as hr_status/hr_debug_lo/hr_debug_hi/hr_timeouts), via
-- a plain double-flop synchroniser into the Nios V (cpu_clk) domain - fine
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
-- Four outputs, all from the 2400 MHz VCO:
--   outclk0 (C0)  0 deg    hyperram_core's clock, CS#/RESET# and DQ/RWDS
--                          output registers - never reconfigured
--   outclk1 (C1)  0 deg    the read clock (DQ/RWDS input DDIO), its phase
--                          swept at runtime by the core's calibration
--                          through hyperram_pll_reconfig.vhd
--   outclk2 (C2)  270 deg  the CK pin's DDIO ("the inverted 90 degree
--                          clock" the core expects) - a static, compile-time
--                          phase (it does apply: the IP sets C2's Counter
--                          Preset to 19, 7500 ps), never reconfigured
--   outclk3 (C3)  CPU_CLOCK_MHZ  niosv_zephyr_sys's clock (Nios V/g, its bus,
--                          the status PIOs) - build_all.sh's CPU_CLOCK_MHZ,
--                          default 120 MHz; the system is held in reset until
--                          the PLL locks
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
    generic (
        -- PR_DEMO=1 (build_all.sh): the reconfigurable LED blinker region
        -- (hw/pr/); without it the LEDs are held off
        g_pr_demo : boolean := false;
        -- the level that lights the RGB LED (not documented for the AXC3000)
        g_led_on  : std_logic := '1'
    );
    port (
        clk_clk       : in std_logic;  -- 25 MHz board oscillator, pin A7
        reset_reset_n : in std_logic;  -- board reset, active low, pin A12

        -- AXC3000 onboard HyperRAM (128 Mb/16 MB, x8) - see
        -- docs/hyperram_pinout.md for the pin table and its source.
        hr_clk      : out   std_logic;
        hr_csn      : out   std_logic;
        hr_resetn   : out   std_logic;
        hr_rwds     : inout std_logic;
        hr_dq       : inout std_logic_vector(7 downto 0);

        -- FTDI serial port (USB-Blaster UART channel B), 12 MBaud (the FTDI's
        -- maximum, tested: 1.2 MB/s full duplex without errors)
        uart_rxd    : in  std_logic;   -- AG23, board TX -> FPGA RX
        uart_txd    : out std_logic;   -- AG24, FPGA TX -> board RX

        -- RGB LED, blue and green (docs/mkr_pinout.md): the PR demo's
        led_b       : out std_logic;   -- AK20
        led_g       : out std_logic    -- AK21
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
            outclk_2            : out std_logic;
            outclk_3            : out std_logic
        );
    end component rpll0;

    signal rpll_rst     : std_logic;
    signal rpll_locked : std_logic;
    signal rpll_clk0, rpll_clk1, rpll_clk2 : std_logic;
    signal cpu_clk       : std_logic;    -- rpll0 outclk3, niosv_zephyr_sys's clock
    signal sys_reset_n   : std_logic;
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
    signal phase_done  : std_logic;    -- a read clock step written (hyperram_pll_reconfig)

    signal fpga_out : hyperram_ddr_fpga_out_record;
    signal fpga_in  : hyperram_ddr_fpga_in_record;

    -- niosv_zephyr_sys's HyperRAM window (AXI4-Lite, 100 MHz domain)
    signal hr_awaddr  : std_logic_vector(23 downto 0);
    signal hr_awvalid, hr_awready : std_logic;
    signal hr_wdata   : std_logic_vector(31 downto 0);
    signal hr_wstrb   : std_logic_vector(3 downto 0);
    signal hr_wvalid, hr_wready : std_logic;
    signal hr_bresp   : std_logic_vector(1 downto 0);
    signal hr_bvalid, hr_bready : std_logic;
    signal hr_araddr  : std_logic_vector(23 downto 0);
    signal hr_arvalid, hr_arready : std_logic;
    signal hr_rdata   : std_logic_vector(31 downto 0);
    signal hr_rresp   : std_logic_vector(1 downto 0);
    signal hr_rvalid, hr_rready : std_logic;

    -- hyperram_axi's native port
    signal arw_valid, arw_ready, arw_write : std_logic;
    signal arw_addr  : std_logic_vector(31 downto 0);
    signal arw_id    : std_logic_vector(7 downto 0);
    signal arw_len   : std_logic_vector(7 downto 0);
    signal arw_size  : std_logic_vector(2 downto 0);
    signal arw_burst : std_logic_vector(1 downto 0);
    signal w_valid, w_ready, w_last : std_logic;
    signal w_data    : std_logic_vector(63 downto 0);
    signal w_strb    : std_logic_vector(7 downto 0);
    signal b_valid, b_ready : std_logic;
    signal b_id      : std_logic_vector(7 downto 0);
    signal r_valid, r_ready, r_last : std_logic;
    signal r_data    : std_logic_vector(63 downto 0);
    signal r_id      : std_logic_vector(7 downto 0);
    signal r_resp    : std_logic_vector(1 downto 0);

    -- niosv_zephyr_sys's UART window (AXI4-Lite, cpu_clk domain)
    signal ua_awaddr, ua_araddr : std_logic_vector(7 downto 0);
    signal ua_awvalid, ua_awready, ua_wvalid, ua_wready : std_logic;
    signal ua_wdata, ua_rdata : std_logic_vector(31 downto 0);
    signal ua_wstrb : std_logic_vector(3 downto 0);
    signal ua_bresp, ua_rresp : std_logic_vector(1 downto 0);
    signal ua_bvalid, ua_bready, ua_arvalid, ua_arready, ua_rvalid, ua_rready : std_logic;
    signal uart_irq : std_logic;
    -- the UART's reset: sys_reset_n, synchronised to cpu_clk
    signal uart_reset_sync : std_logic_vector(1 downto 0) := "11";

    signal hr_status_bits  : std_logic_vector(31 downto 0);
    signal hr_debug_bits   : std_logic_vector(63 downto 0);
    signal hr_timeouts_cnt : unsigned(15 downto 0);

    -- plain double-flop synchronisers, clock_0 domain -> the Nios V domain
    -- (cpu_clk). Diagnostics only, polled by software - not claiming
    -- per-bit atomicity.
    signal status_sync_0, status_sync_1       : std_logic_vector(31 downto 0) := (others => '0');
    signal debug_lo_sync_0, debug_lo_sync_1   : std_logic_vector(31 downto 0) := (others => '0');
    signal debug_hi_sync_0, debug_hi_sync_1   : std_logic_vector(31 downto 0) := (others => '0');
    signal timeouts_sync_0, timeouts_sync_1   : std_logic_vector(31 downto 0) := (others => '0');

    -- partial reconfiguration demo: pio_pr_ctrl's bits (cpu clock) - 0 freeze
    -- the region's outputs, 1 hold the region in reset - into clk_clk's domain
    signal pr_ctrl           : std_logic_vector(1 downto 0);
    signal pr_ctrl_sync_0    : std_logic_vector(1 downto 0) := "00";
    signal pr_ctrl_sync_1    : std_logic_vector(1 downto 0) := "00";
    attribute altera_attribute : string;
    attribute altera_attribute of pr_ctrl_sync_0 : signal is "-name SYNCHRONIZER_IDENTIFICATION FORCED";
    signal region_led_b, region_led_g : std_logic;

begin

    rpll_rst       <= not reset_reset_n;
    sys_reset_n    <= reset_reset_n and rpll_locked;   -- cpu_clk runs only once locked
    hyperram_reset <= (rpll_locked /= '1');

    u_rpll : component rpll0
        port map (
            refclk              => clk_clk,
            rst                 => rpll_rst,
            locked              => rpll_locked,
            outclk_0            => rpll_clk0,
            outclk_1            => rpll_clk1,
            outclk_2            => rpll_clk2,
            outclk_3            => cpu_clk,

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
            dps_shift_enable => phase_shift.shift_enable,
            dps_done         => phase_done
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

    -- The read clock's phase is relative on this PLL (hyperram_pll_reconfig):
    -- the calibration walks it down one 52 ps step at a time through a whole
    -- 10 ns period (192 steps), tests every step, and uses the middle of the
    -- widest passing window; under 1 ns (19 steps) fails the calibration
    -- (status bit 1). Right after configuration the PLL acknowledges some
    -- steps before it makes them (seen on the board: a "window" of 177 steps,
    -- 1 in 4 cold boots reading garbage), so the step is found by a seek on
    -- what the reads show, then tested again; a failure restarts it all, up
    -- to 6 times.
    u_hyperram_axi : entity work.hyperram_axi
        generic map (
            g_phase_steps  => 192,
            g_min_window   => 19,
            g_cal_attempts => 6
        )
        port map (
            clock => rpll_clk0,
            reset => hyperram_reset,

            arw_valid => arw_valid,
            arw_ready => arw_ready,
            arw_addr  => arw_addr,
            arw_id    => arw_id,
            arw_len   => arw_len,
            arw_size  => arw_size,
            arw_burst => arw_burst,
            arw_write => arw_write,

            w_valid => w_valid,
            w_ready => w_ready,
            w_data  => w_data,
            w_strb  => w_strb,
            w_last  => w_last,

            b_valid => b_valid,
            b_ready => b_ready,
            b_id    => b_id,

            r_valid => r_valid,
            r_ready => r_ready,
            r_data  => r_data,
            r_id    => r_id,
            r_resp  => r_resp,
            r_last  => r_last,

            calibration_done   => open,
            calibration_passed => open,
            status             => hr_status_bits,
            read_timeouts      => hr_timeouts_cnt,
            debug              => hr_debug_bits,

            phase_shift        => phase_shift,
            phase_shift_output => 0,
            phase_shift_done   => phase_done,
            fpga_out           => fpga_out,
            fpga_in            => fpga_in
        );

    u_hr_bridge : entity work.hyperram_axi4lite_bridge
        port map (
            clock => rpll_clk0,
            reset => hyperram_reset,

            d_awaddr  => x"00" & hr_awaddr,
            d_awvalid => hr_awvalid,
            d_awready => hr_awready,
            d_wdata   => hr_wdata,
            d_wstrb   => hr_wstrb,
            d_wvalid  => hr_wvalid,
            d_wready  => hr_wready,
            d_bresp   => hr_bresp,
            d_bvalid  => hr_bvalid,
            d_bready  => hr_bready,
            d_araddr  => x"00" & hr_araddr,
            d_arvalid => hr_arvalid,
            d_arready => hr_arready,
            d_rdata   => hr_rdata,
            d_rresp   => hr_rresp,
            d_rvalid  => hr_rvalid,
            d_rready  => hr_rready,

            i_awaddr  => (others => '0'),
            i_awvalid => '0',
            i_awready => open,
            i_wdata   => (others => '0'),
            i_wstrb   => (others => '0'),
            i_wvalid  => '0',
            i_wready  => open,
            i_bresp   => open,
            i_bvalid  => open,
            i_bready  => '1',
            i_araddr  => (others => '0'),
            i_arvalid => '0',
            i_arready => open,
            i_rdata   => open,
            i_rresp   => open,
            i_rvalid  => open,
            i_rready  => '1',

            arw_valid => arw_valid,
            arw_ready => arw_ready,
            arw_addr  => arw_addr,
            arw_id    => arw_id,
            arw_len   => arw_len,
            arw_size  => arw_size,
            arw_burst => arw_burst,
            arw_write => arw_write,
            w_valid   => w_valid,
            w_ready   => w_ready,
            w_data    => w_data,
            w_strb    => w_strb,
            w_last    => w_last,
            b_valid   => b_valid,
            b_ready   => b_ready,
            b_id      => b_id,
            r_valid   => r_valid,
            r_ready   => r_ready,
            r_data    => r_data,
            r_id      => r_id,
            r_resp    => r_resp,
            r_last    => r_last
        );

    uart_reset : process(cpu_clk, sys_reset_n)
    begin
        if sys_reset_n = '0' then
            uart_reset_sync <= "11";
        elsif rising_edge(cpu_clk) then
            uart_reset_sync <= uart_reset_sync(0) & '0';
        end if;
    end process;

    u_uart : entity work.uart_axi4lite
        generic map (
            -- 16 KB each way: a whole SMP frame (16 KB) fits, so the receive
            -- interrupt need not keep up with 12 MBaud (1.2 MB/s) - from the
            -- HyperRAM it does not, and 2 KB overflowed (4.5 KB of a frame lost)
            g_fifo_depth_log2 => 14,
            g_bit_time        => 5333    -- reset value; the driver sets it from the clock
        )
        port map (
            clock => cpu_clk, reset => uart_reset_sync(1),
            awaddr => ua_awaddr, awvalid => ua_awvalid, awready => ua_awready,
            wdata => ua_wdata, wstrb => ua_wstrb, wvalid => ua_wvalid, wready => ua_wready,
            bresp => ua_bresp, bvalid => ua_bvalid, bready => ua_bready,
            araddr => ua_araddr, arvalid => ua_arvalid, arready => ua_arready,
            rdata => ua_rdata, rresp => ua_rresp, rvalid => ua_rvalid, rready => ua_rready,
            irq => uart_irq,
            uart_rxd => uart_rxd, uart_txd => uart_txd
        );

    sync : process(cpu_clk)
    begin
        if rising_edge(cpu_clk) then
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
            clk_in_clk       => cpu_clk,
            reset_in_reset_n => sys_reset_n,

            hr_clk_in_clk       => rpll_clk0,
            hr_reset_in_reset_n => rpll_locked,
            hr_axi_awaddr  => hr_awaddr,
            hr_axi_awprot  => open,
            hr_axi_awvalid => hr_awvalid,
            hr_axi_awready => hr_awready,
            hr_axi_wdata   => hr_wdata,
            hr_axi_wstrb   => hr_wstrb,
            hr_axi_wvalid  => hr_wvalid,
            hr_axi_wready  => hr_wready,
            hr_axi_bresp   => hr_bresp,
            hr_axi_bvalid  => hr_bvalid,
            hr_axi_bready  => hr_bready,
            hr_axi_araddr  => hr_araddr,
            hr_axi_arprot  => open,
            hr_axi_arvalid => hr_arvalid,
            hr_axi_arready => hr_arready,
            hr_axi_rdata   => hr_rdata,
            hr_axi_rresp   => hr_rresp,
            hr_axi_rvalid  => hr_rvalid,
            hr_axi_rready  => hr_rready,

            uart_axi_awaddr  => ua_awaddr,
            uart_axi_awprot  => open,
            uart_axi_awvalid => ua_awvalid,
            uart_axi_awready => ua_awready,
            uart_axi_wdata   => ua_wdata,
            uart_axi_wstrb   => ua_wstrb,
            uart_axi_wvalid  => ua_wvalid,
            uart_axi_wready  => ua_wready,
            uart_axi_bresp   => ua_bresp,
            uart_axi_bvalid  => ua_bvalid,
            uart_axi_bready  => ua_bready,
            uart_axi_araddr  => ua_araddr,
            uart_axi_arprot  => open,
            uart_axi_arvalid => ua_arvalid,
            uart_axi_arready => ua_arready,
            uart_axi_rdata   => ua_rdata,
            uart_axi_rresp   => ua_rresp,
            uart_axi_rvalid  => ua_rvalid,
            uart_axi_rready  => ua_rready,
            uart_irq_irq     => (0 => uart_irq),

            hr_status_export   => status_sync_1,
            hr_debug_lo_export => debug_lo_sync_1,
            hr_debug_hi_export => debug_hi_sync_1,
            hr_timeouts_export => timeouts_sync_1,

            pr_ctrl_export     => pr_ctrl
        );

    ----------------------------------------------------------------------
    -- Partial reconfiguration demo. The region (partition "blinker", a
    -- reserved core-only Logic Lock region - build_niosv_project.tcl) is one
    -- instance of entity blinker: persona "blue" in the base revision,
    -- "green" in impl_green (hw/pr/build_personas.sh). Its outputs go
    -- through the freeze here, in the static region: while software
    -- reconfigures it (pio_pr_ctrl: freeze + reset, PR, reset off, freeze
    -- off) the LEDs are held off and the region's registers in reset.
    process (clk_clk)
    begin
        if rising_edge(clk_clk) then
            pr_ctrl_sync_0 <= pr_ctrl;
            pr_ctrl_sync_1 <= pr_ctrl_sync_0;
        end if;
    end process;

    pr_demo : if g_pr_demo generate
        u_blinker : entity work.blinker
            port map (
                clk   => clk_clk,
                reset => pr_ctrl_sync_1(1),
                led_b => region_led_b,
                led_g => region_led_g
            );
    else generate
        region_led_b <= '0';
        region_led_g <= '0';
    end generate;

    led_b <= g_led_on when region_led_b = '1' and pr_ctrl_sync_1(0) = '0' else not g_led_on;
    led_g <= g_led_on when region_led_g = '1' and pr_ctrl_sync_1(0) = '0' else not g_led_on;

end architecture rtl;
