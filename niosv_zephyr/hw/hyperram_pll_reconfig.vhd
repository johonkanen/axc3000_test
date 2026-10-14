-- hyperram_pll_reconfig - drives a dynamically-reconfigurable altera_iopll
-- (gui_en_iossm_reconf=true)'s calibration bus, bridged by emif_cal
-- (ip/emif_cal/emif_cal.qsys, an emif_io96b_cal instance) to a plain
-- AXI4-Lite slave, to set two output counters' phase shift. This is the
-- only way to get a non-zero PLL output phase on this Quartus/Agilex 3
-- combination: the compile-time gui_phase_shift_deg<N> parameter accepts
-- a value but never actually applies it (confirmed by inspecting
-- qsys-generate's own real output, not guessed - see
-- niosv_zephyr/README.md).
--
-- HSIO path (Sec. 6.1 "Implementing HSIO I/O PLL Reconfiguration using
-- EMIF Calibration IP"), not HVIO (Sec. 6.2's core_avl_* mailbox, which
-- an earlier version of this file drove): this part's package (M16A) has
-- zero HVIO banks at all, confirmed from Intel's own pin-information
-- table for A3CY100B - see niosv_zephyr_top.vhd's header for the full
-- diagnostic trail. gui_en_iossm_reconf is the matching PLL-side
-- parameter, found via the Agilex 3 evaluation kit's own working LPDDR4
-- EMIF example (which calibrates its PLL through the same
-- emif_io96b_cal component).
--
-- Register map (Intel/Altera Clocking and PLL User Guide, Agilex 3 FPGAs
-- and SoCs, doc 847921, 2026.01.26, Sec. 6.3 "Address Bus and Data Bus
-- Settings", Table 21 - same map for HSIO as HVIO, only the bridge
-- differs):
--   address 0x10, data[0]=1       - enable registers for read-modify-write
--   address (0x5C + 4*N)          - counter N's 32-bit register: data[7:0]
--                                   high_count, data[30:23] low_count,
--                                   data[31] odd division enable, data[8]
--                                   bypass enable, data[18:11] "Counter
--                                   Preset" (coarse phase-shift step count,
--                                   default 1 = no shift), data[21:19]
--                                   "Phase Mux Preset" (fine phase shift,
--                                   0-7, each 1/8 VCO period per step).
--                                   Read-modify-write to touch only the
--                                   phase field - Counter Preset is left
--                                   untouched at whatever qsys-generate
--                                   already programmed into it (1, no
--                                   coarse shift).
-- s0_axi4lite_awaddr/araddr[26:0] encoding (Sec. 6.1.6): [7:0] = the
-- register address above, [20:13] = "I/O PLL Base Address" (0 - the only
-- PLL on this calibration bus, NUM_CALBUS_PLLS=1), [23:21] = fixed
-- 3'b101. Confirmed by simulation, not guessed: a Questa testbench drove
-- this exact encoding against the real generated emif_io96b_cal +
-- altera_iopll pair and got a byte-exact read-modify-write round trip on
-- the C0 register (baseline read decoded to all documented defaults;
-- after forcing the phase field and writing back, the readback showed
-- the new phase value with every other field unchanged).
--
-- This is a plain, standard single-beat AXI4-Lite master - no
-- preamble/idle-cycle dance like the HVIO mailbox protocol needed.
--
-- No PLL reset/recalibrate step: Sec. 6.1's intro text says recalibration
-- is only required after a reconfiguration that changes the output
-- frequency, explicitly NOT for "clock gating or dynamic phase shift
-- reconfiguration"; and Sec. 3.3 says resetting the PLL would UNDO any
-- dynamic phase shift already applied (restoring the C counters' original
-- programmed phase) - i.e. for this phase-only use case, issuing a
-- post-reconfiguration PLL reset would be actively wrong, not just
-- unnecessary.
--
-- Two targets, both infrequent/one-shot, not performance-critical:
--   counter 0 (outclk0, the CK pin's own clock) - set once to a fixed
--   phase shortly after reset.
--   counter 1 (outclk1, the HyperRAM read-capture clock) - rewritten
--   whenever hyperram_axi's calibration logic requests a new phase (its
--   phase_shift record - see hyperram_pkg.vhd). shift_select's one-hot
--   target decoding is skipped: there is only one dynamically-swept
--   output in this design, so any shift_enable pulse means "apply shift
--   to counter 1".
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity hyperram_pll_reconfig is
    generic(
        g_ck_fixed_phase : natural range 0 to 7 := 6   -- 270 deg = 6 * 45 deg
    );
    port(
        clock : in std_logic;
        reset : in std_logic;

        axil_awaddr  : out std_logic_vector(26 downto 0);
        axil_awvalid : out std_logic;
        axil_awready : in  std_logic;
        axil_araddr  : out std_logic_vector(26 downto 0);
        axil_arvalid : out std_logic;
        axil_arready : in  std_logic;
        axil_wdata   : out std_logic_vector(31 downto 0);
        axil_wvalid  : out std_logic;
        axil_wready  : in  std_logic;
        axil_rdata   : in  std_logic_vector(31 downto 0);
        axil_rvalid  : in  std_logic;
        axil_rready  : out std_logic;
        axil_bvalid  : in  std_logic;
        axil_bready  : out std_logic;

        dps_shift        : in std_logic_vector(2 downto 0);
        dps_shift_enable : in std_logic
    );
end entity hyperram_pll_reconfig;

architecture rtl of hyperram_pll_reconfig is

    -- awaddr[23:21] = 3'b101, awaddr[20:13] = I/O PLL base address (0,
    -- our only PLL), awaddr[7:0] = register offset below.
    constant c_axil_fixed_bits : unsigned(26 downto 0) := to_unsigned(16#A00000#, 27);
    constant c_reg_enable_addr : unsigned(26 downto 0) := c_axil_fixed_bits + 16#10#;
    constant c_counter0_addr   : unsigned(26 downto 0) := c_axil_fixed_bits + 16#5C#;
    constant c_counter1_addr   : unsigned(26 downto 0) := c_axil_fixed_bits + 16#5C# + 4;

    -- bits [21:19] of the counter's 32-bit word ("Phase Mux Preset")
    constant c_phase_mask : unsigned(31 downto 0) := to_unsigned(16#00380000#, 32);

    type step_t is (
        s_enable_reconfig,
        s_read_c0, s_write_c0,
        s_wait_dps,
        s_read_c1, s_write_c1
    );
    signal step : step_t := s_enable_reconfig;

    type axil_phase_t is (axil_req, axil_resp);
    signal axil_phase    : axil_phase_t := axil_req;
    signal bus_is_write  : boolean := true;

    signal aw_v, w_v, ar_v, b_r, r_r : std_logic := '0';

    signal bus_addr      : unsigned(26 downto 0) := c_reg_enable_addr;
    signal bus_wdata      : unsigned(31 downto 0) := to_unsigned(1, 32);
    signal bus_rdata      : unsigned(31 downto 0) := (others => '0');
    signal pending_phase : unsigned(2 downto 0) := (others => '0');

    signal dps_shift_enable_prev : std_logic := '0';

begin

    axil_awaddr <= std_logic_vector(bus_addr);
    axil_araddr <= std_logic_vector(bus_addr);
    axil_wdata  <= std_logic_vector(bus_wdata);
    axil_awvalid <= aw_v;
    axil_wvalid  <= w_v;
    axil_arvalid <= ar_v;
    axil_bready  <= b_r;
    axil_rready  <= r_r;

    process(clock)
    begin
        if rising_edge(clock) then

            dps_shift_enable_prev <= dps_shift_enable;

            if step = s_wait_dps then

                if dps_shift_enable = '1' and dps_shift_enable_prev = '0' then
                    pending_phase <= unsigned(dps_shift);
                    bus_addr      <= c_counter1_addr;
                    bus_is_write  <= false;
                    axil_phase    <= axil_req;
                    ar_v          <= '1';
                    r_r           <= '1';
                    step          <= s_read_c1;
                end if;

            else

                case axil_phase is

                    -- request phase: hold AWVALID+WVALID (write) or
                    -- ARVALID (read) until each is individually
                    -- acknowledged - a plain, standard single-beat
                    -- AXI4-Lite handshake.
                    when axil_req =>
                        if bus_is_write then
                            if (aw_v = '0' or axil_awready = '1') and
                               (w_v  = '0' or axil_wready  = '1') then
                                aw_v       <= '0';
                                w_v        <= '0';
                                b_r        <= '1';
                                axil_phase <= axil_resp;
                            else
                                if aw_v = '1' and axil_awready = '1' then aw_v <= '0'; end if;
                                if w_v  = '1' and axil_wready  = '1' then w_v  <= '0'; end if;
                            end if;
                        else
                            if ar_v = '0' or axil_arready = '1' then
                                ar_v       <= '0';
                                r_r        <= '1';
                                axil_phase <= axil_resp;
                            end if;
                        end if;

                    -- response phase: wait for BVALID (write) or RVALID
                    -- (read), then dispatch the next step.
                    when axil_resp =>
                        if bus_is_write then
                            if axil_bvalid = '1' then
                                b_r <= '0';

                                case step is
                                    when s_write_c0 =>
                                        step <= s_wait_dps; -- no bus op in this state - see above

                                    when s_write_c1 =>
                                        step <= s_wait_dps;

                                    when s_enable_reconfig =>
                                        bus_addr     <= c_counter0_addr;
                                        bus_is_write <= false;
                                        ar_v         <= '1';
                                        r_r          <= '1';
                                        axil_phase   <= axil_req;
                                        step         <= s_read_c0;

                                    when others =>
                                        null; -- unreachable: s_read_c0/s_read_c1/s_wait_dps never do a write

                                end case;
                            end if;
                        else
                            if axil_rvalid = '1' then
                                r_r       <= '0';
                                bus_rdata <= unsigned(axil_rdata);

                                case step is
                                    when s_read_c0 =>
                                        bus_wdata <= (unsigned(axil_rdata) and not c_phase_mask) or
                                                     (shift_left(resize(to_unsigned(g_ck_fixed_phase, 3), 32), 19) and c_phase_mask);
                                        bus_is_write <= true;
                                        aw_v         <= '1';
                                        w_v          <= '1';
                                        axil_phase   <= axil_req;
                                        step         <= s_write_c0;

                                    when s_read_c1 =>
                                        bus_wdata <= (unsigned(axil_rdata) and not c_phase_mask) or
                                                     (shift_left(resize(pending_phase, 32), 19) and c_phase_mask);
                                        bus_is_write <= true;
                                        aw_v         <= '1';
                                        w_v          <= '1';
                                        axil_phase   <= axil_req;
                                        step         <= s_write_c1;

                                    when others =>
                                        null; -- unreachable: s_enable_reconfig/s_write_c0/s_write_c1/s_wait_dps never do a read

                                end case;
                            end if;
                        end if;

                end case;

            end if;

            if reset = '1' then
                step         <= s_enable_reconfig;
                axil_phase   <= axil_req;
                bus_is_write <= true;
                bus_addr     <= c_reg_enable_addr;
                bus_wdata    <= to_unsigned(1, 32);
                aw_v         <= '1';
                w_v          <= '1';
                ar_v         <= '0';
                b_r          <= '0';
                r_r          <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
