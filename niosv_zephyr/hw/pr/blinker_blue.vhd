-- The PR demo's reconfigurable region, persona "blue" (the base revision's):
-- the RGB LED's blue blinks, about 0.75 Hz on the 25 MHz board clock; green
-- off. Every persona has this entity's ports (the region's boundary, see
-- niosv_zephyr_top.vhd); led_* = '1' is on - the static side applies the
-- board's polarity. No initial values in a PR region: the registers start
-- from reset (held by the static side while the region is reconfigured).
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity blinker is
    port (
        clk   : in  std_logic;
        reset : in  std_logic;      -- synchronous, active high
        led_b : out std_logic;
        led_g : out std_logic
    );
end entity blinker;

architecture rtl of blinker is
    signal count : unsigned(24 downto 0);
begin
    process (clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                count <= (others => '0');
            else
                count <= count + 1;
            end if;
        end if;
    end process;

    led_b <= count(24);
    led_g <= '0';
end architecture rtl;
