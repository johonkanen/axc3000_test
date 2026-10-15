-- The PR demo's persona "green" (impl_green revision, hw/pr/build_personas.sh):
-- the RGB LED's green blinks at twice the blue persona's rate; blue off.
-- Ports as blinker_blue.vhd's entity blinker (the region's boundary).
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity blinker_green is
    port (
        clk   : in  std_logic;
        reset : in  std_logic;
        led_b : out std_logic;
        led_g : out std_logic
    );
end entity blinker_green;

architecture rtl of blinker_green is
    signal count : unsigned(23 downto 0);
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

    led_g <= count(23);
    led_b <= '0';
end architecture rtl;
