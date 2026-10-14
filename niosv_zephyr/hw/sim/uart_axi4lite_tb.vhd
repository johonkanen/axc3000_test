-- uart_axi4lite_tb - the UART peripheral at 4.8 MBaud on a 100 MHz clock
-- (BIT_TIME 5333/256 = 20.83 clocks), against serial models with exact
-- timing: TX bytes and their bit timing, RX streams sent back to back at
-- -2 %, 0 and +2 % of the rate, loopback, the FIFO overflow and framing
-- error counters, and the three interrupt conditions. FIFOs of 512 here.
--
--   python3 run.py "*uart_axi4lite*"          (from the repo root)
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

entity uart_axi4lite_tb is
    generic (runner_cfg : string);
end entity;

architecture vunit_simulation of uart_axi4lite_tb is

    constant clock_period : time := 10 ns;                -- 100 MHz
    constant bit_period   : time := 1 sec / 4_800_000;     -- 208.333 ns
    constant depth        : natural := 512;

    signal clock : std_logic := '0';
    signal reset : std_logic := '1';

    signal awaddr, araddr : std_logic_vector(7 downto 0) := (others => '0');
    signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
    signal arvalid, arready, rvalid, rready : std_logic := '0';
    signal wdata, rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb : std_logic_vector(3 downto 0) := "1111";
    signal bresp, rresp : std_logic_vector(1 downto 0);
    signal irq : std_logic;

    signal txd, rxd   : std_logic;
    signal sender_rxd : std_logic := '1';
    signal loopback   : boolean := false;

    -- bytes captured from txd
    type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
    signal captured       : byte_array(0 to 1023);
    signal captured_count : natural := 0;
    signal capture_errors : natural := 0;
    signal first_start, last_stop : time := 0 ns;

    constant DATA_REG       : std_logic_vector(7 downto 0) := x"00";
    constant STATUS_REG     : std_logic_vector(7 downto 0) := x"04";
    constant BIT_TIME_REG   : std_logic_vector(7 downto 0) := x"08";
    constant IRQ_ENABLE_REG : std_logic_vector(7 downto 0) := x"0C";
    constant IRQ_LEVELS_REG : std_logic_vector(7 downto 0) := x"10";
    constant IRQ_STATUS_REG : std_logic_vector(7 downto 0) := x"14";
    constant ERRORS_REG     : std_logic_vector(7 downto 0) := x"18";

    function test_byte(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i * 37 + 11) mod 256, 8));
    end function;

begin

    clock <= not clock after clock_period / 2;
    rxd   <= txd when loopback else sender_rxd;

    dut : entity work.uart_axi4lite
        generic map(g_fifo_depth_log2 => 9, g_bit_time => 5333)
        port map(
            clock => clock, reset => reset,
            awaddr => awaddr, awvalid => awvalid, awready => awready,
            wdata => wdata, wstrb => wstrb, wvalid => wvalid, wready => wready,
            bresp => bresp, bvalid => bvalid, bready => bready,
            araddr => araddr, arvalid => arvalid, arready => arready,
            rdata => rdata, rresp => rresp, rvalid => rvalid, rready => rready,
            irq => irq, uart_rxd => rxd, uart_txd => txd);

    -- txd decoded with the exact 4.8 MBaud timing, sampled mid-bit
    capture : process
        variable byte : std_logic_vector(7 downto 0);
    begin
        wait until txd = '0';
        if captured_count = 0 then
            first_start <= now;
        end if;
        wait for bit_period / 2;
        if txd /= '0' then
            capture_errors <= capture_errors + 1;
        end if;
        for k in 0 to 7 loop
            wait for bit_period;
            byte(k) := txd;
        end loop;
        wait for bit_period;
        if txd /= '1' then
            capture_errors <= capture_errors + 1;
        end if;
        captured(captured_count) <= byte;
        captured_count <= captured_count + 1;
        last_stop <= now + bit_period / 2;    -- the end of the stop bit
        if txd /= '1' then                    -- (it is, mid stop bit, unless broken)
            wait until txd = '1';
        end if;
    end process;

    test_runner : process

        procedure write_reg(addr : std_logic_vector(7 downto 0); data : std_logic_vector(31 downto 0)) is
        begin
            awaddr <= addr; awvalid <= '1';
            wdata  <= data; wvalid  <= '1';
            wait until rising_edge(clock) and awready = '1';
            awvalid <= '0'; wvalid <= '0';
            bready <= '1';
            wait until rising_edge(clock) and bvalid = '1';
            bready <= '0';
        end procedure;

        procedure read_reg(addr : std_logic_vector(7 downto 0); variable data : out std_logic_vector(31 downto 0)) is
        begin
            araddr <= addr; arvalid <= '1';
            wait until rising_edge(clock) and arready = '1';
            arvalid <= '0';
            rready <= '1';
            wait until rising_edge(clock) and rvalid = '1';
            data := rdata;
            rready <= '0';
        end procedure;

        impure function to_u(v : std_logic_vector) return natural is
        begin
            return to_integer(unsigned(v));
        end function;

        -- one 8N1 character on sender_rxd, every bit lasting 'period'
        procedure send(byte : std_logic_vector(7 downto 0); period : time; stop : std_logic := '1') is
        begin
            sender_rxd <= '0';
            wait for period;
            for k in 0 to 7 loop
                sender_rxd <= byte(k);
                wait for period;
            end loop;
            sender_rxd <= stop;
            wait for period;
            sender_rxd <= '1';
        end procedure;

        -- n bytes back to back at bit period 'period', then read them all
        -- through DATA and compare
        procedure stream_check(n : natural; period : time) is
            variable r : std_logic_vector(31 downto 0);
        begin
            for i in 0 to n - 1 loop
                send(test_byte(i), period);
            end loop;
            wait for 4 * bit_period;
            read_reg(STATUS_REG, r);
            check_equal(to_u(r(15 downto 0)), n, "all bytes in the RX FIFO");
            for i in 0 to n - 1 loop
                read_reg(DATA_REG, r);
                check_equal(r(8), '0', "a byte was there");
                check_equal(r(7 downto 0), test_byte(i), "byte " & integer'image(i));
            end loop;
            read_reg(DATA_REG, r);
            check_equal(r(8), '1', "the RX FIFO is empty after reading them all");
            read_reg(ERRORS_REG, r);
            check_equal(to_u(r), 0, "no overflow or framing errors");
        end procedure;

        variable r : std_logic_vector(31 downto 0);
        variable rate : real;

    begin
        test_runner_setup(runner, runner_cfg);
        wait for 5 * clock_period;
        wait until rising_edge(clock);
        reset <= '0';
        wait until rising_edge(clock);

        while test_suite loop

            if run("registers_after_reset") then
                read_reg(BIT_TIME_REG, r);
                check_equal(to_u(r), 5333, "BIT_TIME");
                read_reg(STATUS_REG, r);
                check_equal(to_u(r(15 downto 0)), 0, "RX FIFO empty");
                check_equal(to_u(r(31 downto 16)), depth, "TX FIFO all free");
                read_reg(DATA_REG, r);
                check_equal(r(8), '1', "DATA reads as empty");
                read_reg(IRQ_ENABLE_REG, r);
                check_equal(to_u(r), 0, "interrupts off");
                check_equal(irq, '0', "no interrupt");

            elsif run("tx_bytes_at_exact_rate") then
                for i in 0 to 199 loop
                    write_reg(DATA_REG, x"000000" & test_byte(i));
                end loop;
                read_reg(IRQ_STATUS_REG, r);
                check_equal(r(3), '0', "TX not done while sending");
                wait until captured_count = 200 for 200 * 11 * bit_period;
                check_equal(captured_count, 200, "all bytes sent");
                wait for bit_period;
                read_reg(IRQ_STATUS_REG, r);
                check_equal(r(3), '1', "TX done after the last stop bit");
                check_equal(capture_errors, 0, "start and stop bits where expected");
                for i in 0 to 199 loop
                    check_equal(captured(i), test_byte(i), "byte " & integer'image(i));
                end loop;
                -- 200 characters back to back: 2000 bits, from the first start
                -- edge to the end of the last stop bit
                rate := real(2000) / real((last_stop - first_start) / 1 ps) * 1.0e12;
                info("TX rate " & real'image(rate) & " baud");
                check(abs(rate - 4.8e6) < 4.8e6 * 0.001, "within 0.1 % of 4.8 MBaud");

            elsif run("tx_status_counts_free_places") then
                for i in 0 to 9 loop
                    write_reg(DATA_REG, x"000000" & test_byte(i));
                end loop;
                read_reg(STATUS_REG, r);
                -- one byte already moved into the transmitter
                check(to_u(r(31 downto 16)) >= depth - 10 and to_u(r(31 downto 16)) <= depth - 8,
                      "free places " & integer'image(to_u(r(31 downto 16))));

            elsif run("rx_stream_at_exact_rate") then
                stream_check(400, bit_period);

            elsif run("rx_stream_from_a_2_percent_faster_sender") then
                stream_check(400, bit_period * 0.98);

            elsif run("rx_stream_from_a_2_percent_slower_sender") then
                stream_check(400, bit_period * 1.02);

            elsif run("loopback") then
                loopback <= true;
                for i in 0 to 99 loop
                    write_reg(DATA_REG, x"000000" & test_byte(i));
                end loop;
                wait for 100 * 10 * bit_period + 20 * bit_period;
                read_reg(STATUS_REG, r);
                check_equal(to_u(r(15 downto 0)), 100, "all looped back");
                for i in 0 to 99 loop
                    read_reg(DATA_REG, r);
                    check_equal(r(7 downto 0), test_byte(i), "byte " & integer'image(i));
                end loop;

            elsif run("rx_overflow_counted_first_bytes_kept") then
                for i in 0 to depth + 9 loop
                    send(test_byte(i), bit_period);
                end loop;
                wait for 4 * bit_period;
                read_reg(ERRORS_REG, r);
                check_equal(to_u(r(15 downto 0)), 10, "10 bytes lost");
                read_reg(STATUS_REG, r);
                check_equal(to_u(r(15 downto 0)), depth, "RX FIFO full");
                for i in 0 to depth - 1 loop
                    read_reg(DATA_REG, r);
                    check_equal(r(7 downto 0), test_byte(i), "byte " & integer'image(i));
                end loop;
                write_reg(ERRORS_REG, x"00000000");
                read_reg(ERRORS_REG, r);
                check_equal(to_u(r), 0, "ERRORS cleared");

            elsif run("framing_error_counted_byte_dropped") then
                send(x"55", bit_period, stop => '0');
                wait for bit_period;               -- idle high: a start edge again
                send(x"AA", bit_period);
                wait for 4 * bit_period;
                read_reg(ERRORS_REG, r);
                check_equal(to_u(r(31 downto 16)), 1, "one framing error");
                read_reg(STATUS_REG, r);
                check_equal(to_u(r(15 downto 0)), 1, "only the good byte kept");
                read_reg(DATA_REG, r);
                check_equal(r(7 downto 0), std_logic_vector'(x"AA"), "the good byte");

            elsif run("rx_level_interrupt") then
                write_reg(IRQ_LEVELS_REG, x"0000" & x"0004");     -- RX level 4
                write_reg(IRQ_ENABLE_REG, x"00000001");
                for i in 0 to 2 loop
                    send(test_byte(i), bit_period);
                end loop;
                wait for bit_period;
                check_equal(irq, '0', "3 bytes: below the level (and no timeout yet)");
                send(test_byte(3), bit_period);
                wait for bit_period;
                check_equal(irq, '1', "4 bytes: interrupt");
                read_reg(IRQ_STATUS_REG, r);
                check_equal(r(0), '1', "RX level in IRQ_STATUS");
                for i in 0 to 3 loop
                    read_reg(DATA_REG, r);
                end loop;
                wait until rising_edge(clock);
                check_equal(irq, '0', "emptied: no interrupt");

            elsif run("rx_timeout_interrupt") then
                write_reg(IRQ_LEVELS_REG, x"0000" & x"0010");     -- RX level 16
                write_reg(IRQ_ENABLE_REG, x"00000001");
                send(test_byte(0), bit_period);
                wait for 30 * bit_period;
                check_equal(irq, '0', "3 characters quiet: not yet");
                wait for 15 * bit_period;
                check_equal(irq, '1', "4+ characters quiet: timeout");
                read_reg(IRQ_STATUS_REG, r);
                check_equal(r(1 downto 0), std_logic_vector'("10"), "RX timeout, not level");
                read_reg(DATA_REG, r);
                wait until rising_edge(clock);
                check_equal(irq, '0', "read: no interrupt");

            elsif run("tx_interrupt") then
                write_reg(IRQ_LEVELS_REG, std_logic_vector(to_unsigned(depth - 4, 16)) & x"0000");
                for i in 0 to 19 loop
                    write_reg(DATA_REG, x"000000" & test_byte(i));
                end loop;
                write_reg(IRQ_ENABLE_REG, x"00000002");
                wait until rising_edge(clock);
                check_equal(irq, '0', "TX FIFO too full for the level");
                wait until irq = '1' for 30 * 10 * bit_period;
                check_equal(irq, '1', "drained down to the level: interrupt");
                read_reg(STATUS_REG, r);
                check(to_u(r(31 downto 16)) >= depth - 4, "free places at the level");
            end if;

        end loop;

        test_runner_cleanup(runner);
        wait;
    end process;

    test_runner_watchdog(runner, 10 ms);

end architecture vunit_simulation;
