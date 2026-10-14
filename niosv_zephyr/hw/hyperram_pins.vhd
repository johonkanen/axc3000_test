-- hyperram_pins - DDIO wrapper between hyperram_axi's half-rate (hi/lo)
-- fpga_out/fpga_in records and the real single-ended AXC3000 HyperRAM
-- pins. Plain inferred DDR registers (two opposite-edge flip-flops + a
-- clock-level mux), not a vendor DDIO primitive - the "rising_edge/
-- falling_edge pair, muxed by the clock level" shape is the standard
-- template Quartus's fitter packs into the IOE's dedicated DDIO hardware,
-- and it sidesteps needing any particular megafunction (relevant after
-- hitting a real bug in altera_iopll's dynamic-phase-shift ports on this
-- Quartus/device combination - see niosv_zephyr/README.md).
--
-- Clock domains, matching hVHDL_memory_library's hyperram_pkg.vhd header:
--   clock_0  (0deg)   - hyperram_axi's own clock; also cs_n/reset_n (SDR)
--                       and dq_*/rwds_* OUTPUT DDIO (DDR).
--   clock_ck (270deg) - CK pin's own DDIO ("the inverted 90 degree clock").
--   clock_rd           - read-capture clock for the INPUT DDIO registers.
--                       Fixed phase, not dynamically calibrated (no known-
--                       working dynamic phase shift on this device/
--                       toolchain yet) - a first guess, expect to sweep
--                       it empirically against real hardware.
--
-- Input capture is two stages: DDIO registers clocked by clock_rd, then a
-- single re-register clocked by clock_0 one cycle later to cross into
-- hyperram_axi's own domain - both clocks are the same frequency at a
-- fixed, known phase relationship, so this is a plain synchronous
-- crossing, not an async FIFO/handshake.
library ieee;
    use ieee.std_logic_1164.all;

    use work.hyperram_pkg.all;

entity hyperram_pins is
    port(
        clock_0  : in std_logic;
        clock_ck : in std_logic;
        clock_rd : in std_logic;

        fpga_out : in  hyperram_ddr_fpga_out_record;
        fpga_in  : out hyperram_ddr_fpga_in_record;

        hr_clk    : out   std_logic;
        hr_csn    : out   std_logic;
        hr_resetn : out   std_logic;
        hr_rwds   : inout std_logic;
        hr_dq     : inout std_logic_vector(7 downto 0)
    );
end entity hyperram_pins;

architecture rtl of hyperram_pins is

    signal ck_hi_r, ck_lo_r : std_logic := '0';

    signal cs_n_r, reset_n_r : std_logic := '1';
    signal dq_oe_r, rwds_oe_r : std_logic := '0';
    signal dq_hi_r, dq_lo_r : std_logic_vector(7 downto 0) := (others => '0');
    signal rwds_hi_r, rwds_lo_r : std_logic := '0';
    signal dq_out, rwds_out : std_logic_vector(7 downto 0);
    signal rwds_out_bit : std_logic;

    signal dq_capture_hi, dq_capture_lo : std_logic_vector(7 downto 0) := (others => '0');
    signal rwds_capture_hi, rwds_capture_lo : std_logic := '0';

begin

    -- CK pin DDIO (its own 270deg clock domain)
    ck_out : process(clock_ck)
    begin
        if rising_edge(clock_ck) then
            ck_hi_r <= fpga_out.ck_hi;
        elsif falling_edge(clock_ck) then
            ck_lo_r <= fpga_out.ck_lo;
        end if;
    end process;
    hr_clk <= ck_hi_r when clock_ck = '1' else ck_lo_r;

    -- cs_n/reset_n: single-rate, clock_0 domain
    sdr_out : process(clock_0)
    begin
        if rising_edge(clock_0) then
            cs_n_r    <= fpga_out.cs_n;
            reset_n_r <= fpga_out.reset_n;
            dq_oe_r   <= fpga_out.dq_oe;
            rwds_oe_r <= fpga_out.rwds_oe;
        end if;
    end process;
    hr_csn    <= cs_n_r;
    hr_resetn <= reset_n_r;

    -- dq/rwds OUTPUT DDIO, clock_0 domain
    ddr_out : process(clock_0)
    begin
        if rising_edge(clock_0) then
            dq_hi_r   <= fpga_out.dq_hi;
            rwds_hi_r <= fpga_out.rwds_hi;
        elsif falling_edge(clock_0) then
            dq_lo_r   <= fpga_out.dq_lo;
            rwds_lo_r <= fpga_out.rwds_lo;
        end if;
    end process;
    dq_out       <= dq_hi_r   when clock_0 = '1' else dq_lo_r;
    rwds_out_bit <= rwds_hi_r when clock_0 = '1' else rwds_lo_r;

    hr_dq   <= dq_out when dq_oe_r = '1' else (others => 'Z');
    hr_rwds <= rwds_out_bit when rwds_oe_r = '1' else 'Z';

    -- dq/rwds INPUT DDIO, clock_rd domain (stage 1)
    ddr_in : process(clock_rd)
    begin
        if rising_edge(clock_rd) then
            dq_capture_hi   <= hr_dq;
            rwds_capture_hi <= hr_rwds;
        elsif falling_edge(clock_rd) then
            dq_capture_lo   <= hr_dq;
            rwds_capture_lo <= hr_rwds;
        end if;
    end process;

    -- re-register into hyperram_axi's own (clock_0) domain, one cycle later (stage 2)
    cross_to_clock_0 : process(clock_0)
    begin
        if rising_edge(clock_0) then
            fpga_in.dq_hi   <= dq_capture_hi;
            fpga_in.dq_lo   <= dq_capture_lo;
            fpga_in.rwds_hi <= rwds_capture_hi;
            fpga_in.rwds_lo <= rwds_capture_lo;
        end if;
    end process;

end architecture rtl;
