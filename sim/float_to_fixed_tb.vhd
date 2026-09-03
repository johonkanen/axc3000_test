-- float_to_fixed_tb - the float->fixed conversion used at uart_bringup
-- addr 56/57/58.  fixed = trunc(float * 2**radix); the radix is carried
-- in the input record, so one instance converts at any radix.
--
-- float_to_fixed.vhd is an abstract interface in the multiply_add style:
-- input / output records, create_float_to_fixed_typeref, a
-- request_float_to_fixed procedure, get_fixed_result / *_is_ready, and a
-- separate fp32_to_hfloat glue function.  The hfloat reference type and
-- the pipeline depth are entity generics (floatref defaults to hfloat32).
--
--   FP=../source/hVHDL_floating_point
--   nvc --std=2019 -a $FP/vhdl2008/float_typedefs_generic_pkg.vhd \
--                     ../float_to_fixed.vhd sim/float_to_fixed_tb.vhd
--   nvc --std=2019 -e float_to_fixed_tb -r

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.float_to_fixed_pkg.all;

entity float_to_fixed_tb is end entity;

architecture sim of float_to_fixed_tb is
    constant f2f_ref : float_to_fixed_typeref := create_float_to_fixed_typeref(hfloat32);
    signal   f2f_in  : f2f_ref.f2f_in'subtype  := f2f_ref.f2f_in;
    signal   f2f_out : f2f_ref.f2f_out'subtype := f2f_ref.f2f_out;

    signal clock : std_logic := '0';
    signal pat   : std_logic_vector(31 downto 0) := (others => '0');
    signal rdx   : natural := 10;

    type tcase is record
        p : std_logic_vector(31 downto 0);
        r : natural;
        e : integer;
    end record;
    type tcase_arr is array (natural range <>) of tcase;
    constant cases : tcase_arr := (
        (x"3F800000", 10,  1024),  (x"3F800000",  8,   256),
        (x"3F800000", 12,  4096),  (x"3F800000",  0,     1),
        (x"3F000000", 10,   512),  (x"3F000000",  9,   256),
        (x"3E800000", 10,   256),  (x"3F400000", 10,   768),
        (x"3DCCCCCD", 10,   102),  (x"3DCCCCCD", 14,  1638),
        (x"BF000000", 10,  -512),  (x"BF000000", 11, -1024),
        (x"40000000", 10,  2048),  (x"40400000", 10,  3072),
        (x"00000000", 10,     0),  (x"3A800000", 10,     1));
begin
    clock <= not clock after 5 ns;

    u_f2f : entity work.float_to_fixed
        port map (clock => clock, float_to_fixed_in => f2f_in, float_to_fixed_out => f2f_out);

    driver : process (clock) is
    begin
        if rising_edge(clock) then
            request_float_to_fixed(f2f_in, fp32_to_hfloat(pat), rdx);
        end if;
    end process;

    stim : process is
    begin
        for i in cases'range loop
            pat <= cases(i).p;
            rdx <= cases(i).r;
            for k in 0 to 6 loop wait until rising_edge(clock); end loop;
            report "0x" & to_hstring(cases(i).p) & " radix " & integer'image(cases(i).r)
                 & " -> " & integer'image(to_integer(get_fixed_result(f2f_out)))
                 & "  (expect " & integer'image(cases(i).e) & ")";
            assert abs(to_integer(get_fixed_result(f2f_out)) - cases(i).e) <= 1
                report "  MISMATCH" severity error;
        end loop;
        assert float_to_fixed_is_ready(f2f_out) report "not ready" severity error;
        report "all ok";
        std.env.stop;
    end process;
end architecture;
