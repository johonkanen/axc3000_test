-- ------------------------------------------------------------------------
-- niosv_zephyr_top - board-level wrapper around the Platform Designer
-- system (niosv_zephyr_sys.qsys: Nios V/g + 256 KB on-chip RAM + JTAG UART).
-- Phase 1 bring-up: proves the system compiles/fits. No PLL yet - the
-- Nios V/g core runs directly off the board's 25 MHz oscillator.
-- ------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

-- Platform Designer registers its generated system under a library named
-- after the system ("niosv_zephyr_sys"), not "work" - a plain
-- `entity work.niosv_zephyr_sys` instantiation fails to resolve
-- ("design library altera_work does not contain primary unit ...").
library niosv_zephyr_sys;

entity niosv_zephyr_top is
    port (
        clk_clk       : in std_logic;  -- 25 MHz board oscillator, pin A7
        reset_reset_n : in std_logic   -- board reset, active low, pin A12
    );
end entity niosv_zephyr_top;

architecture rtl of niosv_zephyr_top is
begin

    u_sys : entity niosv_zephyr_sys.niosv_zephyr_sys
        port map (
            clk_in_clk       => clk_clk,
            reset_in_reset_n => reset_reset_n
        );

end architecture rtl;
