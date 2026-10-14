-- hyperram_pins - the AXC3000 HyperRAM pins, their registers in the I/O
-- cells through the GPIO IP (ip/hr_gpio/), between hyperram_core's half-
-- rate (hi/lo) fpga_out/fpga_in records and the single-ended pins.
--
-- An earlier version inferred the DDR registers by hand (rising/falling-edge
-- flops, muxed by the clock level). Quartus never packed those into the I/O
-- cells: the fit report showed Input/Output/Output Enable Register = "no" on
-- every hr_* pin, with the clock driving a fabric mux. The GPIO IP's DDIO is
-- the I/O cell's own.
--
-- Clock domains, matching hVHDL_memory_library's hyperram_pkg.vhd:
--   clock_0  (0 deg)   hyperram_core's clock; DQ/RWDS output DDIO and output
--                      enables; CS#/RESET# (fabric registers - see below)
--   clock_ck (270 deg) the CK pin's output DDIO ("the inverted 90 degree
--                      clock")
--   clock_rd           DQ/RWDS input DDIO - the read clock, its phase swept
--                      at runtime by hyperram_core's calibration
--
-- Input capture is two stages: the DDIO input registers on clock_rd, then a
-- re-register on clock_0 a cycle later - both clocks are one frequency at a
-- known phase, a plain synchronous transfer.
--
-- GPIO IP DDIO half order (checked by simulating the generated IP): the
-- LOWER half of din is driven while the clock is high (the first half of
-- the cycle) - so *_hi goes in the lower half; on input the lower half of
-- dout is the value captured at the rising edge.
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

    -- bits 7:0 DQ, bit 8 RWDS; DDIO data: bits 8:0 the first half, 17:9 the second
    component hr_dq_io is
        port (
            ck_in  : in    std_logic;
            ck_out : in    std_logic;
            dout   : out   std_logic_vector(17 downto 0);
            din    : in    std_logic_vector(17 downto 0);
            oe     : in    std_logic_vector(8 downto 0);
            pad_io : inout std_logic_vector(8 downto 0)
        );
    end component hr_dq_io;

    component hr_ck_io is
        port (
            ck      : in  std_logic;
            din     : in  std_logic_vector(1 downto 0);
            pad_out : out std_logic_vector(0 downto 0)
        );
    end component hr_ck_io;


    signal dq_din   : std_logic_vector(17 downto 0);
    signal dq_dout  : std_logic_vector(17 downto 0);
    signal dq_oe    : std_logic_vector(8 downto 0);
    signal ck_out   : std_logic_vector(0 downto 0);
    signal cs_n_r, reset_n_r : std_logic := '1';

begin

    dq_din <= fpga_out.rwds_lo & fpga_out.dq_lo & fpga_out.rwds_hi & fpga_out.dq_hi;
    dq_oe  <= fpga_out.rwds_oe & (7 downto 0 => fpga_out.dq_oe);

    u_dq : component hr_dq_io
        port map (
            ck_in  => clock_rd,
            ck_out => clock_0,
            dout   => dq_dout,
            din    => dq_din,
            oe     => dq_oe,
            pad_io(7 downto 0) => hr_dq,
            pad_io(8)          => hr_rwds
        );

    u_ck : component hr_ck_io
        port map (
            ck      => clock_ck,
            din     => fpga_out.ck_lo & fpga_out.ck_hi,
            pad_out => ck_out
        );
    hr_clk <= ck_out(0);

    -- CS#/RESET#: fabric registers on clock_0, not I/O-cell ones - they share
    -- an I/O lane with CK, whose DDIO is on clock_ck, and one lane's output
    -- registers take only one clock
    ctl_out : process(clock_0)
    begin
        if rising_edge(clock_0) then
            cs_n_r    <= fpga_out.cs_n;
            reset_n_r <= fpga_out.reset_n;
        end if;
    end process;
    hr_csn    <= cs_n_r;
    hr_resetn <= reset_n_r;

    -- re-register into hyperram_core's own (clock_0) domain, one cycle later
    cross_to_clock_0 : process(clock_0)
    begin
        if rising_edge(clock_0) then
            fpga_in.dq_hi   <= dq_dout(7 downto 0);
            fpga_in.rwds_hi <= dq_dout(8);
            fpga_in.dq_lo   <= dq_dout(16 downto 9);
            fpga_in.rwds_lo <= dq_dout(17);
        end if;
    end process;

end architecture rtl;
