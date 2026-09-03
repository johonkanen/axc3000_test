-- float_to_fixed_tb - the radix-10 float->fixed conversion used at
-- uart_bringup addr 56/57.  fixed = trunc(float * 2**10), so a float in
-- [0,1] maps to [0,1024].  Uses the hVHDL_floating_point non-generic
-- denormalizer_pkg (denormalizer_generic_pkg does not synthesise on
-- Quartus Pro - see the axc3000 README).
--
--   FP=../source/hVHDL_floating_point
--   nvc --std=2019 -a \
--     $FP/float_type_definitions/float_word_length_24_bit_pkg.vhd \
--     $FP/float_type_definitions/float_type_definitions_pkg.vhd \
--     $FP/float_arithmetic_operations/float_arithmetic_operations_pkg.vhd \
--     $FP/denormalizer/denormalizer_configuration/denormalizer_with_2_stage_pipe_pkg.vhd \
--     $FP/denormalizer/denormalizer_pkg.vhd \
--     sim/float_to_fixed_tb.vhd
--   nvc --std=2019 -e float_to_fixed_tb -r

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity float_to_fixed_tb is end entity;

architecture sim of float_to_fixed_tb is
    use work.float_type_definitions_pkg.all;
    use work.denormalizer_pkg.all;

    constant c_conv_radix : integer := 10;

    -- IEEE-754 binary32 slv -> float_record (24-bit mantissa word-length)
    function fp32_to_float_record (slv : std_logic_vector(31 downto 0)) return float_record is
        variable r  : float_record := zero;
        constant be : unsigned(7 downto 0) := unsigned(slv(30 downto 23));
        constant e  : integer := to_integer(be) - 126;
    begin
        if be /= 0 and e > -c_conv_radix then
            r.sign     := slv(31);
            r.exponent := to_signed(e, r.exponent'length);
            r.mantissa := resize(unsigned('1' & slv(22 downto 0)), r.mantissa'length);
        end if;
        return r;
    end function;

    signal clk    : std_logic := '0';
    signal denorm : denormalizer_record := init_denormalizer;
    signal req    : std_logic := '0';
    signal pat    : std_logic_vector(31 downto 0) := (others => '0');
    signal got    : integer := 0;
    signal gv     : std_logic := '0';

    type tvec is array (natural range <>) of std_logic_vector(31 downto 0);
    --                        1.0      0.5      0.25     0.75     0.1      -0.5     2.0      0.0      1/3      2**-10
    constant patterns : tvec := (x"3F800000", x"3F000000", x"3E800000", x"3F400000", x"3DCCCCCD",
                                 x"BF000000", x"40000000", x"00000000", x"3F333333", x"3A800000");
    constant expected : integer_vector := (1024, 512, 256, 768, 102, -512, 2048, 0, 716, 1);
begin
    clk <= not clk after 5 ns;

    drv : process (clk) is
    begin
        if rising_edge(clk) then
            create_denormalizer(denorm);
            gv <= '0';
            if req = '1' then
                convert_float_to_integer(denorm, fp32_to_float_record(pat), c_conv_radix);
            end if;
            if denormalizer_is_ready(denorm) then
                got <= get_integer(denorm);
                gv  <= '1';
            end if;
        end if;
    end process;

    stim : process is
    begin
        for i in patterns'range loop
            wait until rising_edge(clk); pat <= patterns(i); req <= '1';
            wait until rising_edge(clk); req <= '0';
            wait until gv = '1' for 200 ns;
            report "0x" & to_hstring(patterns(i)) & " -> " & integer'image(got)
                 & "  (expect " & integer'image(expected(i)) & ")";
            assert abs(got - expected(i)) <= 1 report "  MISMATCH" severity error;
        end loop;
        report "all ok";
        std.env.stop;
    end process;
end architecture;
