-- uart_axi4lite - an 8N1 UART with RX/TX FIFOs behind an AXI4-Lite slave,
-- for the Nios V/g to talk to the board's FTDI UART (AG23/AG24) at up to
-- 4.8 MBaud. One clock: the bus clock is the UART's clock.
--
-- Registers (32 bit, byte offsets):
--   0x00 DATA        W: bits 7:0 into the TX FIFO (dropped when it is full)
--                    R: the oldest received byte, popped: bits 7:0, bit 8 = 1
--                       when the RX FIFO was empty (bits 7:0 then 0)
--   0x04 STATUS      R: 15:0 bytes in the RX FIFO, 31:16 free places in the TX FIFO
--   0x08 BIT_TIME    RW: 19:0 one bit in 1/256 clocks (Q12.8), e.g. 100 MHz,
--                       4.8 MBaud: 5333; at least 4.0 (1024)
--   0x0C IRQ_ENABLE  RW: bit 0 RX (level or timeout), bit 1 TX
--   0x10 IRQ_LEVELS  RW: 15:0 RX level - the RX interrupt when at least this
--                       many bytes are waiting; 31:16 TX level - the TX
--                       interrupt when at least this many places are free
--   0x14 IRQ_STATUS  R: bit 0 RX level reached, bit 1 RX timeout (bytes waiting
--                       and nothing received for 4 characters), bit 2 TX level
--                       reached - whether enabled or not; bit 3 TX done (all
--                       sent: FIFO empty, the last stop bit over) - status only
--   0x18 ERRORS      R: 15:0 bytes lost to a full RX FIFO, 31:16 framing errors
--                       (both saturate); W: clears both
--
-- irq = the enabled conditions of IRQ_STATUS, a level.
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_axi4lite is
    generic(
        g_fifo_depth_log2 : positive := 11;                   -- 2 KB each way
        g_bit_time        : natural  := 5333                  -- reset BIT_TIME
    );
    port(
        clock : in std_logic;
        reset : in std_logic;

        -- AXI4-Lite slave (address bits 4:2 decoded)
        awaddr  : in  std_logic_vector(7 downto 0);
        awvalid : in  std_logic;
        awready : out std_logic;
        wdata   : in  std_logic_vector(31 downto 0);
        wstrb   : in  std_logic_vector(3 downto 0);
        wvalid  : in  std_logic;
        wready  : out std_logic;
        bresp   : out std_logic_vector(1 downto 0);
        bvalid  : out std_logic;
        bready  : in  std_logic;
        araddr  : in  std_logic_vector(7 downto 0);
        arvalid : in  std_logic;
        arready : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        rresp   : out std_logic_vector(1 downto 0);
        rvalid  : out std_logic;
        rready  : in  std_logic;

        irq : out std_logic;

        uart_rxd : in  std_logic;
        uart_txd : out std_logic
    );
end entity uart_axi4lite;

architecture rtl of uart_axi4lite is

    constant depth : natural := 2**g_fifo_depth_log2;

    -- registers
    signal bit_time    : unsigned(19 downto 0) := to_unsigned(g_bit_time, 20);
    signal irq_enable  : std_logic_vector(1 downto 0) := "00";
    signal rx_level    : unsigned(15 downto 0) := to_unsigned(1, 16);
    signal tx_level    : unsigned(15 downto 0) := to_unsigned(1, 16);
    signal rx_overflow : unsigned(15 downto 0) := (others => '0');
    signal rx_framing  : unsigned(15 downto 0) := (others => '0');

    -- FIFOs
    signal tx_push, tx_pop, tx_empty, tx_full : std_logic;
    signal tx_wdata, tx_rdata : std_logic_vector(7 downto 0);
    signal tx_count : unsigned(g_fifo_depth_log2 downto 0);
    signal rx_push, rx_pop, rx_empty, rx_full : std_logic;
    signal rx_wdata, rx_rdata : std_logic_vector(7 downto 0);
    signal rx_count : unsigned(g_fifo_depth_log2 downto 0);

    -- serial side
    signal tx_start, tx_take, tx_busy, tx_popped : std_logic := '0';
    signal tx_hold      : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_hold_full : std_logic := '0';
    signal rx_valid, rx_framing_error, rx_idle : std_logic;
    signal rx_data : std_logic_vector(7 downto 0);

    -- RX timeout: clocks since the last received byte, against 4 characters
    signal quiet_clocks  : unsigned(23 downto 0) := (others => '0');
    signal timeout_limit : unsigned(23 downto 0);

    signal tx_free : unsigned(15 downto 0);
    signal irq_status : std_logic_vector(3 downto 0);

    -- bus
    signal b_pending  : std_logic := '0';
    signal r_pending  : std_logic := '0';
    signal r_wait     : std_logic := '0';     -- the read is a clock old: rx_rdata is valid
    signal r_addr     : unsigned(2 downto 0) := (others => '0');
    signal r_was_empty : std_logic := '0';
    signal rdata_r    : std_logic_vector(31 downto 0) := (others => '0');

    signal write_now : boolean;
    signal read_now  : boolean;

    function saturating_increment(x : unsigned) return unsigned is
    begin
        if x = (x'range => '1') then
            return x;
        end if;
        return x + 1;
    end function;

begin

------------------------------------------------------------------------
    u_tx_fifo : entity work.sync_fifo
        generic map(g_width => 8, g_depth_log2 => g_fifo_depth_log2)
        port map(clock => clock, reset => reset,
                 push => tx_push, wdata => tx_wdata, pop => tx_pop, rdata => tx_rdata,
                 count => tx_count, empty => tx_empty, full => tx_full);

    u_rx_fifo : entity work.sync_fifo
        generic map(g_width => 8, g_depth_log2 => g_fifo_depth_log2)
        port map(clock => clock, reset => reset,
                 push => rx_push, wdata => rx_wdata, pop => rx_pop, rdata => rx_rdata,
                 count => rx_count, empty => rx_empty, full => rx_full);

    u_tx : entity work.uart_tx
        port map(clock => clock, reset => reset, bit_time => bit_time,
                 start => tx_start, data => tx_hold, take => tx_take, busy => tx_busy,
                 txd => uart_txd);

    u_rx : entity work.uart_rx
        port map(clock => clock, reset => reset, bit_time => bit_time, rxd => uart_rxd,
                 valid => rx_valid, data => rx_data, framing_error => rx_framing_error,
                 idle => rx_idle);

------------------------------------------------------------------------
    -- TX: the next byte waits in tx_hold, so the transmitter can take it the
    -- clock its stop bit ends. Pop when tx_hold is free (or being taken); the
    -- popped byte is in tx_rdata the clock after.
    tx_pop   <= '1' when tx_empty = '0' and tx_popped = '0'
                         and (tx_hold_full = '0' or tx_take = '1') else '0';
    tx_start <= tx_hold_full;

    tx_engine : process(clock)
    begin
        if rising_edge(clock) then
            tx_popped <= tx_pop;
            if tx_take = '1' then
                tx_hold_full <= '0';
            end if;
            if tx_popped = '1' then
                tx_hold      <= tx_rdata;
                tx_hold_full <= '1';
            end if;
            if reset = '1' then
                tx_popped    <= '0';
                tx_hold_full <= '0';
            end if;
        end if;
    end process;

    -- RX: received bytes into the FIFO; a full FIFO drops them (counted)
    rx_push  <= rx_valid;
    rx_wdata <= rx_data;

------------------------------------------------------------------------
    tx_free <= resize(to_unsigned(depth, tx_count'length + 1) - tx_count, 16);

    -- 4 characters of 10 bits: 40 * bit_time / 256 clocks
    timeout_limit <= resize(shift_right(resize(bit_time, 32) * 40, 8), 24);

    irq_status(0) <= '1' when rx_count >= rx_level and rx_level /= 0 else '0';
    irq_status(1) <= '1' when rx_empty = '0' and quiet_clocks >= timeout_limit else '0';
    irq_status(2) <= '1' when tx_free >= tx_level else '0';
    irq_status(3) <= tx_empty and not tx_popped and not tx_hold_full and not tx_busy;

    irq <= (irq_enable(0) and (irq_status(0) or irq_status(1)))
           or (irq_enable(1) and irq_status(2));

------------------------------------------------------------------------
    -- AXI4-Lite: one write and one read at a time; a write needs AW and W
    -- together
    write_now <= awvalid = '1' and wvalid = '1' and b_pending = '0';
    read_now  <= arvalid = '1' and r_pending = '0';

    awready <= '1' when write_now else '0';
    wready  <= '1' when write_now else '0';
    bvalid  <= b_pending;
    bresp   <= "00";

    arready <= '1' when read_now else '0';
    rvalid  <= r_pending and not r_wait;
    rresp   <= "00";
    rdata   <= rdata_r;

    -- a DATA read pops the RX FIFO; its byte is in rx_rdata a clock later
    rx_pop <= '1' when read_now and unsigned(araddr(4 downto 2)) = 0 else '0';

    tx_push  <= '1' when write_now and unsigned(awaddr(4 downto 2)) = 0 and wstrb(0) = '1' else '0';
    tx_wdata <= wdata(7 downto 0);

    bus_side : process(clock)
    begin
        if rising_edge(clock) then
            -- writes
            if b_pending = '1' and bready = '1' then
                b_pending <= '0';
            end if;
            if write_now then
                b_pending <= '1';
                case to_integer(unsigned(awaddr(4 downto 2))) is
                    when 2 => bit_time   <= unsigned(wdata(19 downto 0));
                    when 3 => irq_enable <= wdata(1 downto 0);
                    when 4 => rx_level   <= unsigned(wdata(15 downto 0));
                              tx_level   <= unsigned(wdata(31 downto 16));
                    when others => null;
                end case;
            end if;

            -- reads: accepted, then a clock for the FIFO, then R
            if r_pending = '1' and r_wait = '0' and rready = '1' then
                r_pending <= '0';
            end if;
            if read_now then
                r_pending   <= '1';
                r_wait      <= '1';
                r_addr      <= unsigned(araddr(4 downto 2));
                r_was_empty <= rx_empty;
            end if;
            if r_wait = '1' then
                r_wait <= '0';
                case to_integer(r_addr) is
                    when 0 =>
                        if r_was_empty = '1' then
                            rdata_r <= (8 => '1', others => '0');
                        else
                            rdata_r <= x"000000" & rx_rdata;
                        end if;
                    when 1 => rdata_r <= std_logic_vector(tx_free) & std_logic_vector(resize(rx_count, 16));
                    when 2 => rdata_r <= x"000" & std_logic_vector(bit_time);
                    when 3 => rdata_r <= (31 downto 2 => '0') & irq_enable;
                    when 4 => rdata_r <= std_logic_vector(tx_level) & std_logic_vector(rx_level);
                    when 5 => rdata_r <= (31 downto 4 => '0') & irq_status;
                    when 6 => rdata_r <= std_logic_vector(rx_framing) & std_logic_vector(rx_overflow);
                    when others => rdata_r <= (others => '0');
                end case;
            end if;

            -- error counters, cleared by any ERRORS write
            if rx_valid = '1' and rx_full = '1' then
                rx_overflow <= saturating_increment(rx_overflow);
            end if;
            if rx_framing_error = '1' then
                rx_framing <= saturating_increment(rx_framing);
            end if;
            if write_now and unsigned(awaddr(4 downto 2)) = 6 then
                rx_overflow <= (others => '0');
                rx_framing  <= (others => '0');
            end if;

            -- RX timeout timer
            if rx_valid = '1' or rx_idle = '0' then
                quiet_clocks <= (others => '0');
            elsif quiet_clocks /= (quiet_clocks'range => '1') then
                quiet_clocks <= quiet_clocks + 1;
            end if;

            if reset = '1' then
                b_pending   <= '0';
                r_pending   <= '0';
                r_wait      <= '0';
                bit_time    <= to_unsigned(g_bit_time, 20);
                irq_enable  <= "00";
                rx_level    <= to_unsigned(1, 16);
                tx_level    <= to_unsigned(1, 16);
                rx_overflow <= (others => '0');
                rx_framing  <= (others => '0');
                quiet_clocks <= (others => '0');
            end if;
        end if;
    end process;

end architecture rtl;
