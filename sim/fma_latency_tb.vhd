-- ---------------------------------------------------------------------
-- fma_latency_tb - measures the pipeline latency of multiply_add(agilex)
-- with the behavioural sim_native_fp32.vhd model, using the same probe
-- FSM that uart_bringup_top.vhd runs on the real IP (UART addr 54/55).
--
--   nvc --std=2008 -a \
--     ../source/hVHDL_floating_point/vhdl2008/float_typedefs_generic_pkg.vhd \
--     ../source/hVHDL_floating_point/vhdl2008/multiply_add_entity.vhd \
--     ../source/hVHDL_floating_point/vhdl2008/altera/sim_native_fp32.vhd \
--     ../source/hVHDL_floating_point/vhdl2008/altera/multiply_add_arch_agilex.vhd \
--     fma_latency_tb.vhd
--   nvc --std=2008 -e fma_latency_tb -r
--
-- Result 2026-09-03:
--   sim_native_fp32.vhd model -> 3 core-clock edges
--   real native_fp32 IP (hw)  -> 3 core-clock edges
-- They match: native_fp32.ip enables the mult/adder input registers,
-- adder_input, and the output register (adder_input_clken = 0).  Before
-- adder_input was enabled the hardware measured 2.
-- ---------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity fma_latency_tb is
end entity;

architecture sim of fma_latency_tb is

    use work.multiply_add_pkg.all;

    constant ref     : mpya_subtype_record := create_mpya_typeref;
    signal   mpya_in : ref.mpya_in'subtype  := ref.mpya_in;
    signal   mpya_out: ref.mpya_out'subtype := ref.mpya_out;

    signal clock : std_logic := '0';

    constant c_fma_a0 : std_logic_vector(31 downto 0) := x"3F800000"; -- 1.0
    constant c_fma_a1 : std_logic_vector(31 downto 0) := x"41000000"; -- 8.0
    constant c_fma_b  : std_logic_vector(31 downto 0) := x"41000000"; -- 8.0
    constant c_fma_c  : std_logic_vector(31 downto 0) := x"00000000"; -- 0.0
    constant c_fma_r1 : std_logic_vector(31 downto 0) := x"42800000"; -- 64.0

    type probe_state_t is (P_IDLE, P_SETTLE, P_MEASURE, P_DONE);
    signal probe_state   : probe_state_t := P_IDLE;
    signal probe_active  : std_logic := '0';
    signal probe_a       : std_logic_vector(31 downto 0) := c_fma_a0;
    signal probe_wait    : natural range 0 to 63 := 0;
    signal probe_count   : natural range 0 to 63 := 0;
    signal probe_latency : std_logic_vector(31 downto 0) := (others => '0');
    signal probe_trig    : std_logic := '0';
    signal probe_seen    : std_logic := '0';
    signal fp_zero       : std_logic_vector(31 downto 0) := (others => '0');

begin

    clock <= not clock after 5 ns;   -- 100 MHz

    -- identical operand mux + probe FSM to uart_bringup_top.vhd
    mpya_in.mpy_a        <= probe_a  when probe_active = '1' else fp_zero;
    mpya_in.mpy_b        <= c_fma_b  when probe_active = '1' else fp_zero;
    mpya_in.add_a        <= c_fma_c  when probe_active = '1' else fp_zero;
    mpya_in.is_requested <= '1';

    dut : entity work.multiply_add(agilex)
        port map (clock => clock, mpya_in => mpya_in, mpya_out => mpya_out);

    fma_latency_probe : process (clock) is
    begin
        if rising_edge(clock) then
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
                when P_SETTLE =>
                    if probe_wait = 0 then
                        probe_a     <= c_fma_a1;
                        probe_count <= 0;
                        probe_state <= P_MEASURE;
                    else
                        probe_wait <= probe_wait - 1;
                    end if;
                when P_MEASURE =>
                    if get_mpya_result(mpya_out) = c_fma_r1 then
                        probe_latency <= std_logic_vector(to_unsigned(probe_count, 32));
                        probe_state   <= P_DONE;
                    elsif probe_count = 63 then
                        probe_latency <= x"FFFFFFFF";
                        probe_state   <= P_DONE;
                    else
                        probe_count <= probe_count + 1;
                    end if;
                when P_DONE =>
                    probe_active <= '0';
                    probe_state  <= P_IDLE;
            end case;
        end if;
    end process;

    stim : process is
    begin
        wait for 100 ns;
        probe_trig <= '1';
        wait until probe_state = P_DONE;
        wait until rising_edge(clock);
        report "sim_native_fp32 model: measured FMA latency = "
             & integer'image(to_integer(unsigned(probe_latency))) & " core-clock edges"
             severity note;
        std.env.stop;
    end process;

end architecture;
