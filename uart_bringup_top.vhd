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
--   addr 54: measured FMA pipeline latency  (read only, core-clock edges)
--   addr 55: write -> run the latency probe  (write only)
--   addr 56: float->fixed input (fp32)      (read / write)
--   addr 57: fixed-point result             (read only, signed integer)
--   addr 58: float->fixed radix             (read / write, default 10)
--   addr 60: PWM0 duty (mkr_d4), 0..1024     (read only, cycles high / period)
--   addr 61: PWM1 duty (mkr_d5), 0..1024     (read only)
--   addr 62: PWM2 duty (mkr_d6), 0..1024     (read only)
--   addr 63: PWM3 duty (mkr_d7), 0..1024     (read only)
--   addr 64: PWM0 duty as a float [0,1] (fp32) (read / write)
--   addr 65: PWM1 duty as a float [0,1] (fp32) (read / write)
--   addr 66: PWM2 duty as a float [0,1] (fp32) (read / write)
--   addr 67: PWM3 duty as a float [0,1] (fp32) (read / write)
-- FMA operands/result and addr 56 are raw IEEE-754 binary32 bit patterns.
-- Float->fixed (addr 56/57/58): the float_to_fixed entity (abstract
-- interface, multiply_add style; hfloat ref + pipeline depth are
-- generics, radix travels in the request record from addr 58).
-- fixed = trunc(float * 2**radix); at radix 10, [0,1] -> [0, 1024].
-- PWM: 100 MHz core clock / 1024 = 97.66 kHz, CENTRE-aligned (triangle
-- carrier - all four pulses centred on the same instant).  Write a float
-- in [0,1] to addr 64..67; float_to_fixed converts it at radix 10 to a
-- 0..1024 duty count (period = 1024), so the fp32 value is the duty ratio
-- you see on a scope.  Addr 60..63 read that integer back.
-- Resets to 0.1/0.2/0.3/0.4 (~10/20/30/40 %).
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
    use work.float_typedefs_generic_pkg.all;
    use work.float_to_fixed_pkg.all;

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

    -- FMA latency probe: on a write to addr 55 it drives (1.0, 8.0, 0.0)
    -- -> result 8.0, then steps mult_a to 8.0 and counts core_clock
    -- edges until the result reads 64.0.  Result at addr 54.  Reads 3 -
    -- input regs + adder_input + output reg - matching the behavioural
    -- model source/hVHDL_floating_point/.../sim_native_fp32.vhd.
    constant c_fma_a0  : std_logic_vector(31 downto 0) := x"3F800000";  -- 1.0
    constant c_fma_a1  : std_logic_vector(31 downto 0) := x"41000000";  -- 8.0
    constant c_fma_b   : std_logic_vector(31 downto 0) := x"41000000";  -- 8.0
    constant c_fma_c   : std_logic_vector(31 downto 0) := x"00000000";  -- 0.0
    constant c_fma_r0  : std_logic_vector(31 downto 0) := x"41000000";  -- 1.0*8 + 0 =  8.0
    constant c_fma_r1  : std_logic_vector(31 downto 0) := x"42800000";  -- 8.0*8 + 0 = 64.0

    type probe_state_t is (P_IDLE, P_SETTLE, P_MEASURE, P_DONE);
    signal probe_state   : probe_state_t := P_IDLE;
    signal probe_active  : std_logic := '0';
    signal probe_a       : std_logic_vector(31 downto 0) := c_fma_a0;
    signal probe_wait    : natural range 0 to 63 := 0;
    signal probe_count   : natural range 0 to 63 := 0;
    signal probe_latency : std_logic_vector(31 downto 0) := (others => '0');
    signal probe_trig    : std_logic := '0';   -- toggles on write to 55 (test_registers)
    signal probe_seen    : std_logic := '0';   -- follows probe_trig (probe fsm)

    -- float -> fixed-point: the float_to_fixed entity (abstract interface,
    -- multiply_add style).  floatref defaults to hfloat32; radix travels in
    -- the input record, so the one instance converts at any radix.
    constant c_conv_stages : natural := 2;
    constant c_conv_radix   : natural := 10;    -- reset value of the radix register

    constant f2f_ref : float_to_fixed_typeref := create_float_to_fixed_typeref(hfloat32);
    signal   f2f_in  : f2f_ref.f2f_in'subtype  := f2f_ref.f2f_in;
    signal   f2f_out : f2f_ref.f2f_out'subtype := f2f_ref.f2f_out;

    signal fp_conv_in     : std_logic_vector(31 downto 0) := (others => '0');  -- addr 56, fp32
    signal conv_radix     : std_logic_vector(31 downto 0)                      -- addr 58
                          := std_logic_vector(to_unsigned(c_conv_radix, 32));
    signal fixed_conv_out : std_logic_vector(31 downto 0) := (others => '0');  -- addr 57, signed

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

    -- 4 x centre-aligned PWM on mkr_d4..d7.  Period is 1024 core-clock
    -- cycles (2**c_pwm_radix) so a float [0,1] converted at radix
    -- c_pwm_radix maps straight to the duty count with no scaling
    -- multiply: 100 MHz / 1024 = 97.66 kHz.
    constant c_pwm_radix  : natural := 10;
    constant c_pwm_period : natural := 2 ** c_pwm_radix;   -- 1024
    constant c_pwm_half   : natural := c_pwm_period / 2;

    type slv32_array is array (natural range <>) of std_logic_vector(31 downto 0);
    function init_duty return slv32_array is
        variable v : slv32_array(0 to 3);
    begin
        for i in 0 to 3 loop
            v(i) := std_logic_vector(to_unsigned((i + 1) * c_pwm_period / 10, 32));  -- ~10/20/30/40 %
        end loop;
        return v;
    end function;

    -- fp32 patterns for 0.1 / 0.2 / 0.3 / 0.4 (the reset duty ratios)
    function init_pwm_float return slv32_array is
        constant v : slv32_array(0 to 3) :=
            (x"3DCCCCCD", x"3E4CCCCD", x"3E99999A", x"3ECCCCCD");
    begin
        return v;
    end function;

    -- clamp the radix-c_pwm_radix fixed-point value to a 0..c_pwm_period duty
    function clamp_duty (f : signed) return natural is
        variable v : integer := to_integer(f);
    begin
        if v < 0 then
            v := 0;
        elsif v > c_pwm_period then
            v := c_pwm_period;
        end if;
        return v;
    end function;

    signal pwm_float : slv32_array(0 to 3) := init_pwm_float;   -- addr 64..67, fp32
    signal pwm_duty  : slv32_array(0 to 3) := init_duty;        -- addr 60..63, 0..1024

    -- one float_to_fixed converter per PWM channel
    type f2f_in_array  is array (natural range <>) of f2f_ref.f2f_in'subtype;
    type f2f_out_array is array (natural range <>) of f2f_ref.f2f_out'subtype;
    signal pwm_f2f_in  : f2f_in_array (0 to 3) := (others => f2f_ref.f2f_in);
    signal pwm_f2f_out : f2f_out_array(0 to 3) := (others => f2f_ref.f2f_out);

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
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 54, probe_latency);
            if write_is_requested_to_address(bus_from_communications, 55) then
                probe_trig <= not probe_trig;
            end if;

            -- float -> fixed: write the fp32 to addr 56, the radix to addr 58,
            -- read the signed result at addr 57
            connect_data_to_address(bus_from_communications, bus_from_top, 56, fp_conv_in);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 57, fixed_conv_out);
            connect_data_to_address(bus_from_communications, bus_from_top, 58, conv_radix);

            -- PWM: read the integer duty (0..1000) at 60..63, write the
            -- duty ratio as a float [0,1] at 64..67
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 60, pwm_duty(0));
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 61, pwm_duty(1));
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 62, pwm_duty(2));
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 63, pwm_duty(3));
            connect_data_to_address(bus_from_communications, bus_from_top, 64, pwm_float(0));
            connect_data_to_address(bus_from_communications, bus_from_top, 65, pwm_float(1));
            connect_data_to_address(bus_from_communications, bus_from_top, 66, pwm_float(2));
            connect_data_to_address(bus_from_communications, bus_from_top, 67, pwm_float(3));

            bus_to_communications <= bus_from_top;

            if system_reset = '1' then
                loopback_register     <= (others => '0');
                read_counter          <= (others => '0');
                fp_a                  <= (others => '0');
                fp_b                  <= (others => '0');
                fp_c                  <= (others => '0');
                fp_conv_in            <= (others => '0');
                conv_radix            <= std_logic_vector(to_unsigned(c_conv_radix, 32));
                pwm_float             <= init_pwm_float;
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
    -- Operands come from the a/b/c registers, except while the latency
    -- probe has taken over (probe_active).
    fma_in.mpy_a        <= probe_a  when probe_active = '1' else fp_a;
    fma_in.mpy_b        <= c_fma_b  when probe_active = '1' else fp_b;
    fma_in.add_a        <= c_fma_c  when probe_active = '1' else fp_c;
    fma_in.is_requested <= '1';

    u_fma : entity work.multiply_add(agilex)
    port map (
        clock     => core_clock
        ,mpya_in  => fma_in
        ,mpya_out => fma_out
    );

------------------------------------------------------------------------
    -- FMA hardware-latency probe.  Measures core_clock edges from a step
    -- on mult_a to the new value appearing at the result, and parks it in
    -- probe_latency (addr 54).  Reads 3, matching the sim model in
    -- source/hVHDL_floating_point/.../sim_native_fp32.vhd.
    fma_latency_probe : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            case probe_state is
                when P_IDLE =>
                    probe_active <= '0';
                    if probe_trig /= probe_seen then
                        probe_seen   <= probe_trig;
                        probe_a      <= c_fma_a0;
                        probe_active <= '1';
                        probe_wait   <= 63;
                        probe_state  <= P_SETTLE;
                    end if;

                when P_SETTLE =>                    -- let the result reach c_fma_r0
                    if probe_wait = 0 then
                        probe_a     <= c_fma_a1;    -- the step
                        probe_count <= 0;
                        probe_state <= P_MEASURE;
                    else
                        probe_wait <= probe_wait - 1;
                    end if;

                when P_MEASURE =>
                    if get_mpya_result(fma_out) = c_fma_r1 then
                        probe_latency <= std_logic_vector(to_unsigned(probe_count, 32));
                        probe_state   <= P_DONE;
                    elsif probe_count = 63 then
                        probe_latency <= x"FFFFFFFF";   -- did not settle
                        probe_state   <= P_DONE;
                    else
                        probe_count <= probe_count + 1;
                    end if;

                when P_DONE =>
                    probe_active <= '0';
                    probe_state  <= P_IDLE;
            end case;

            if system_reset = '1' then
                probe_state  <= P_IDLE;
                probe_active <= '0';
                probe_seen   <= probe_trig;
            end if;
        end if;
    end process fma_latency_probe;

------------------------------------------------------------------------
    -- float -> fixed-point conversion (float_to_fixed entity).  Every
    -- core-clock edge the fp32 at addr 56 is decoded to an hfloat (glue
    -- call fp32_to_hfloat) and requested at the current radix (addr 58);
    -- the signed result trunc(float * 2**radix) lands in fixed_conv_out /
    -- addr 57 c_conv_stages edges later.  Same instance, any radix.
    u_float_to_fixed : entity work.float_to_fixed
        generic map (g_stages => c_conv_stages)     -- floatref defaults to hfloat32
        port map (
            clock              => core_clock,
            float_to_fixed_in  => f2f_in,
            float_to_fixed_out => f2f_out
        );

    float_to_fixed : process (core_clock) is
    begin
        if rising_edge(core_clock) then
            request_float_to_fixed(f2f_in,
                fp32_to_hfloat(fp_conv_in),
                to_integer(unsigned(conv_radix(5 downto 0))));

            fixed_conv_out <= std_logic_vector(get_fixed_result(f2f_out));

            if system_reset = '1' then
                fixed_conv_out <= (others => '0');
            end if;
        end if;
    end process float_to_fixed;

------------------------------------------------------------------------
    -- PWM duty from a float: one float_to_fixed converter per channel.
    -- The fp32 at addr 64+i is converted at radix c_pwm_radix and scaled
    -- to 0..c_pwm_period, so writing 0.25 gives a 25 % duty cycle.
    gen_pwm_convert : for i in 0 to 3 generate
        u_pwm_f2f : entity work.float_to_fixed
            generic map (g_stages => c_conv_stages)
            port map (
                clock              => core_clock,
                float_to_fixed_in  => pwm_f2f_in(i),
                float_to_fixed_out => pwm_f2f_out(i)
            );

        pwm_conv : process (core_clock) is
        begin
            if rising_edge(core_clock) then
                request_float_to_fixed(pwm_f2f_in(i),
                    fp32_to_hfloat(pwm_float(i)), c_pwm_radix);
                pwm_duty(i) <= std_logic_vector(
                    to_unsigned(clamp_duty(get_fixed_result(pwm_f2f_out(i))), 32));

                if system_reset = '1' then
                    pwm_duty(i) <= init_duty(i);
                end if;
            end if;
        end process pwm_conv;
    end generate gen_pwm_convert;

------------------------------------------------------------------------
    -- 4 x 97.66 kHz centre-aligned PWM.  A triangle carrier ramps
    -- 0 -> c_pwm_half -> 0 over one period; each output is high while the
    -- carrier is below (pwm_duty / 2), so the pulse is centred on the
    -- carrier minimum and all four channels are aligned there.  pwm_duty is
    -- "high cycles per 1024-cycle period" (0..1024); centre alignment
    -- costs one bit of resolution.
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
