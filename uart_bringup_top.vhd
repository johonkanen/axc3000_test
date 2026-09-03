------------------------------------------------------------------------
-- Minimal Agilex 3 UART bring-up build for the Arrow AXC3000 board.
--
-- Scope: the UART communication block (source/fpga_communication), a
-- 100 MHz IOPLL, one FP32 fused multiply-add DSP (the same
-- multiply_add(agilex) / native_fp32 module the ../quartus_pro build
-- uses), and 4 x 100 kHz PWM channels on the Arduino MKR header.
--
-- Board / pinout taken from the Arrow AXC3000 NIOSV_lab + docs/mkr_pinout.md:
--   clk_clk       PIN_A7    1.3-V LVCMOS   25 MHz oscillator
--   reset_reset_n PIN_A12   1.3-V LVCMOS   active low, weak pull-up
--   uart_rxd      PIN_AG23  3.3-V LVCMOS
--   uart_txd      PIN_AG24  3.3-V LVCMOS
--   mkr_d4        PIN_AF19  3.3-V LVCMOS   PWM0  (MKR J1-13)
--   mkr_d5        PIN_AG20  3.3-V LVCMOS   PWM1  (MKR J1-14)
--   mkr_d6        PIN_AK19  3.3-V LVCMOS   PWM2  (MKR J2-1)
--   mkr_d7        PIN_AJ19  3.3-V LVCMOS   PWM3  (MKR J2-2)
--
-- Clocking:  25 MHz clk_clk -> pll_100 IOPLL -> 100 MHz core_clock.
-- The UART and register logic run on core_clock:
--   g_clock_divider = 868  ->  100e6 / 868 = 115207 baud (~115200, 0.006% err)
--
-- Register map reachable over UART (32 bit data, 16 bit address):
--   addr 1 : constant id      0x0000ACDC   (read only)
--   addr 2 : git hash                       (read only)
--   addr 3 : loopback register              (read / write)
--   addr 4 : read strobe counter            (read only, increments on
--                                            every read of addr 4)
--   addr 50: FMA operand a (fp32 mult_a)    (read / write)
--   addr 51: FMA operand b (fp32 mult_b)    (read / write)
--   addr 52: FMA operand c (fp32 adder_a)   (read / write)
--   addr 53: FMA result  a*b + c  (fp32)    (read only)
--   addr 60: PWM0 duty (mkr_d4)             (read / write)
--   addr 61: PWM1 duty (mkr_d5)             (read / write)
--   addr 62: PWM2 duty (mkr_d6)             (read / write)
--   addr 63: PWM3 duty (mkr_d7)             (read / write)
-- FMA operands/result are raw IEEE-754 binary32 bit patterns.
-- PWM: 100 MHz core clock / 1000 = 100 kHz, CENTRE-aligned (triangle
-- carrier - all four pulses centred on the same instant).  Duty register
-- holds the number of core-clock cycles high per 1000-cycle period, i.e.
-- tenths of a percent (100 = 10.0%); centre alignment makes the effective
-- step 0.2%.  Resets to 100/200/300/400.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_bringup_top is
    generic (
        -- core clock (Hz) / baud rate.  100 MHz PLL / 115200 = 868.
        g_clock_divider : natural := 868
    );
    port (
        clk_clk        : in  std_logic   -- 25 MHz reference (PIN_A7)
        ;reset_reset_n : in  std_logic   -- active low (PIN_A12)
        ;uart_rxd      : in  std_logic   -- PIN_AG23
        ;uart_txd      : out std_logic   -- PIN_AG24
        ;mkr_d4        : out std_logic   -- PIN_AF19  PWM0
        ;mkr_d5        : out std_logic   -- PIN_AG20  PWM1
        ;mkr_d6        : out std_logic   -- PIN_AK19  PWM2
        ;mkr_d7        : out std_logic   -- PIN_AJ19  PWM3
    );
end entity uart_bringup_top;

architecture rtl of uart_bringup_top is

    component pll_100 is
        port (
            rst       : in  std_logic := 'X'
            ;refclk   : in  std_logic := 'X'
            ;locked   : out std_logic
            ;outclk_0 : out std_logic
        );
    end component pll_100;

    use work.fpga_interconnect_pkg.all;
    use work.multiply_add_pkg.all;

    signal core_clock : std_logic;
    signal pll_locked : std_logic;
    signal pll_rst    : std_logic;

    -- FP32 fused multiply-add: result = a*b + c
    constant mpya_ref : mpya_subtype_record := create_mpya_typeref;   -- 8 exp / 23 mant -> 32 bit
    signal fma_in  : mpya_ref.mpya_in'subtype  := mpya_ref.mpya_in;
    signal fma_out : mpya_ref.mpya_out'subtype := mpya_ref.mpya_out;

    signal fp_a : std_logic_vector(31 downto 0) := (others => '0');
    signal fp_b : std_logic_vector(31 downto 0) := (others => '0');
    signal fp_c : std_logic_vector(31 downto 0) := (others => '0');

    -- synchronous, active-high reset: PLL not locked / power-on / button
    signal por_counter  : natural range 0 to 1_048_575 := 1_048_575;
    signal reset_meta   : std_logic := '1';
    signal reset_sync   : std_logic := '1';
    signal system_reset : std_logic := '1';

    signal bus_to_communications   : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_communications : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_top            : fpga_interconnect_record := init_fpga_interconnect;

    signal loopback_register : std_logic_vector(31 downto 0) := (others => '0');
    signal read_counter      : std_logic_vector(31 downto 0) := (others => '0');

    -- 4 x 100 kHz centre-aligned PWM on mkr_d4..d7
    constant c_pwm_period : natural := 1000;   -- 100 MHz / 1000 = 100 kHz
    constant c_pwm_half   : natural := c_pwm_period / 2;

    type slv32_array is array (natural range <>) of std_logic_vector(31 downto 0);
    function init_duty return slv32_array is
        variable v : slv32_array(0 to 3);
    begin
        for i in 0 to 3 loop
            v(i) := std_logic_vector(to_unsigned((i + 1) * c_pwm_period / 10, 32));  -- 10/20/30/40 %
        end loop;
        return v;
    end function;

    signal pwm_duty : slv32_array(0 to 3) := init_duty;
    -- triangle (up/down) carrier: 0 -> c_pwm_half -> 0 = one 100 kHz period
    signal pwm_tri  : natural range 0 to c_pwm_half := 0;
    signal pwm_up   : std_logic := '1';
    signal pwm_out  : std_logic_vector(3 downto 0) := (others => '0');

begin

------------------------------------------------------------------------
    pll_rst <= not reset_reset_n;

    u_pll : component pll_100
    port map (
        rst      => pll_rst
        ,refclk   => clk_clk
        ,locked   => pll_locked
        ,outclk_0 => core_clock
    );

------------------------------------------------------------------------
    -- hold reset until the PLL is locked, then ~10 ms more, plus the button
    reset_synchroniser : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            reset_meta <= (not reset_reset_n) or (not pll_locked);
            reset_sync <= reset_meta;

            if por_counter /= 0 then
                por_counter  <= por_counter - 1;
                system_reset <= '1';
            else
                system_reset <= reset_sync;
            end if;
        end if;
    end process reset_synchroniser;

------------------------------------------------------------------------
    test_registers : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            init_bus(bus_from_top);

            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 1, x"0000ACDC");
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 2, work.git_hash_pkg.git_hash);
            connect_data_to_address(bus_from_communications, bus_from_top, 3, loopback_register);

            if data_is_requested_from_address(bus_from_communications, 4) then
                read_counter <= std_logic_vector(unsigned(read_counter) + 1);
                write_data_to_address(bus_from_top, 0, read_counter);
            end if;

            -- FP32 fused multiply-add operands / result
            connect_data_to_address(bus_from_communications, bus_from_top, 50, fp_a);
            connect_data_to_address(bus_from_communications, bus_from_top, 51, fp_b);
            connect_data_to_address(bus_from_communications, bus_from_top, 52, fp_c);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 53, get_mpya_result(fma_out));

            -- PWM duty registers (mkr_d4..d7)
            connect_data_to_address(bus_from_communications, bus_from_top, 60, pwm_duty(0));
            connect_data_to_address(bus_from_communications, bus_from_top, 61, pwm_duty(1));
            connect_data_to_address(bus_from_communications, bus_from_top, 62, pwm_duty(2));
            connect_data_to_address(bus_from_communications, bus_from_top, 63, pwm_duty(3));

            bus_to_communications <= bus_from_top;

            if system_reset = '1' then
                loopback_register     <= (others => '0');
                read_counter          <= (others => '0');
                fp_a                  <= (others => '0');
                fp_b                  <= (others => '0');
                fp_c                  <= (others => '0');
                pwm_duty              <= init_duty;
                bus_to_communications <= init_fpga_interconnect;
            end if;
        end if;
    end process test_registers;

------------------------------------------------------------------------
    u_fpga_communications : entity work.fpga_communications
    generic map (
        fpga_interconnect_pkg => work.fpga_interconnect_pkg
        ,g_clock_divider      => g_clock_divider
    )
    port map (
        clock                    => core_clock
        ,uart_rx                 => uart_rxd
        ,uart_tx                 => uart_txd
        ,bus_to_communications   => bus_to_communications
        ,bus_from_communications => bus_from_communications
    );

------------------------------------------------------------------------
    -- FP32 fused multiply-add DSP (native_fp32 hard-float IP).
    -- Operands are driven continuously from the registers; result
    -- settles a few core_clock cycles after any operand write, long
    -- before software reads it back over UART.
    fma_in.mpy_a        <= fp_a;
    fma_in.mpy_b        <= fp_b;
    fma_in.add_a        <= fp_c;
    fma_in.is_requested <= '1';

    u_fma : entity work.multiply_add(agilex)
    port map (
        clock     => core_clock
        ,mpya_in  => fma_in
        ,mpya_out => fma_out
    );

------------------------------------------------------------------------
    -- 4 x 100 kHz centre-aligned PWM.  A triangle carrier ramps
    -- 0 -> c_pwm_half -> 0 over one period; each output is high while the
    -- carrier is below (duty / 2), so the pulse is centred on the carrier
    -- minimum and all four channels are aligned there.  Duty register is
    -- still "high cycles per 1000-cycle period" (LSB = 0.1 %); centre
    -- alignment costs one bit of resolution (effective step 0.2 %).
    pwm_gen : process (core_clock) is
        variable du  : unsigned(31 downto 0);
        variable cmp : natural range 0 to c_pwm_half;
    begin
        if rising_edge(core_clock) then
            if pwm_up = '1' then
                if pwm_tri = c_pwm_half - 1 then
                    pwm_tri <= c_pwm_half;
                    pwm_up  <= '0';
                else
                    pwm_tri <= pwm_tri + 1;
                end if;
            else
                if pwm_tri = 1 then
                    pwm_tri <= 0;
                    pwm_up  <= '1';
                else
                    pwm_tri <= pwm_tri - 1;
                end if;
            end if;

            for i in 0 to 3 loop
                du := unsigned(pwm_duty(i));
                if du >= to_unsigned(c_pwm_period, 32) then
                    cmp := c_pwm_half;
                else
                    cmp := to_integer(du) / 2;
                end if;

                if pwm_tri < cmp then
                    pwm_out(i) <= '1';
                else
                    pwm_out(i) <= '0';
                end if;
            end loop;

            if system_reset = '1' then
                pwm_tri <= 0;
                pwm_up  <= '1';
                pwm_out <= (others => '0');
            end if;
        end if;
    end process pwm_gen;

    mkr_d4 <= pwm_out(0);
    mkr_d5 <= pwm_out(1);
    mkr_d6 <= pwm_out(2);
    mkr_d7 <= pwm_out(3);

end rtl;
