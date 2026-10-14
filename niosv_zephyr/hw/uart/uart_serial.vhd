-- uart_tx / uart_rx - 8N1 serial with a fractional bit time.
--
-- bit_time is the length of one bit in 1/256 clocks (Q12.8): at 100 MHz,
-- 4.8 MBaud is 20.833 clocks = 5333/256. 'until_edge' holds the time to the
-- next bit edge (or sample point), in 1/256 clocks: one clock off every
-- clock, and when it is down to zero or below, the edge is now and bit_time
-- is added - the overshoot carries over, so every edge is within a clock of
-- the exact one and the average rate is exact. hVHDL_uart's integer
-- clocks-per-bit would make 4.8 MBaud at 100 MHz 0.8 % off.
--
-- The receiver samples each bit in its middle (from the start bit's falling
-- edge, through a two-flop synchroniser), checks the stop bit, and is back
-- to waiting for a start bit from the middle of the stop bit: a sender
-- slightly faster than the receiver does not lose characters in a
-- continuous stream. (Waiting out the whole stop bit, as hVHDL_uart's
-- receiver does, puts the next start edge before it is listening, and the
-- lag grows by the rate difference with every character.) After a framing
-- error (stop bit 0, also a break) it waits for the line to go high before
-- looking for a start bit again - the low stop bit is not a start bit.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_tx is
    port(
        clock    : in std_logic;
        reset    : in std_logic;
        bit_time : in unsigned(19 downto 0);   -- Q12.8 clocks, >= 2.0

        -- with start = '1', data is taken (take = '1', the same clock) when
        -- idle, or in the clock that ends the stop bit - back to back, no
        -- gap between characters
        start    : in  std_logic;
        data     : in  std_logic_vector(7 downto 0);
        take     : out std_logic;
        busy     : out std_logic;

        txd      : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is

    signal shifter   : std_logic_vector(9 downto 0) := (others => '1');  -- stop & data & start
    signal bits_left : natural range 0 to 10 := 0;
    signal until_edge : signed(21 downto 0) := (others => '0');
    signal next_edge  : signed(21 downto 0);
    signal taking     : boolean;

begin

    busy <= '1' when bits_left /= 0 else '0';

    next_edge <= until_edge - 256;
    taking    <= start = '1' and (bits_left = 0 or (bits_left = 1 and next_edge <= 0));
    take      <= '1' when taking else '0';
    txd  <= shifter(0);

    process(clock)
    begin
        if rising_edge(clock) then
            if taking then
                shifter   <= '1' & data & '0';
                bits_left <= 10;
                if bits_left = 0 then
                    until_edge <= signed(resize(bit_time, 22));
                else
                    -- straight after a stop bit: keep its overshoot
                    until_edge <= next_edge + signed(resize(bit_time, 22));
                end if;
            elsif bits_left = 0 then
                null;
            elsif next_edge <= 0 then
                -- this clock ends the bit
                shifter    <= '1' & shifter(9 downto 1);
                bits_left  <= bits_left - 1;
                until_edge <= next_edge + signed(resize(bit_time, 22));
            else
                until_edge <= next_edge;
            end if;

            if reset = '1' then
                shifter   <= (others => '1');
                bits_left <= 0;
            end if;
        end if;
    end process;

end architecture rtl;

------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_rx is
    port(
        clock    : in std_logic;
        reset    : in std_logic;
        bit_time : in unsigned(19 downto 0);   -- Q12.8 clocks, >= 4.0

        rxd      : in std_logic;               -- asynchronous

        -- one-clock pulses
        valid         : out std_logic;
        data          : out std_logic_vector(7 downto 0);
        framing_error : out std_logic;         -- stop bit was 0; the byte is dropped
        idle          : out std_logic          -- no character being received
    );
end entity uart_rx;

architecture rtl of uart_rx is

    signal sync      : std_logic_vector(1 downto 0) := (others => '1');
    signal receiving : boolean := false;
    signal wait_high : boolean := false;      -- after a framing error
    signal bit_index : natural range 0 to 9 := 0;      -- 0 start, 1..8 data, 9 stop
    signal until_sample : signed(21 downto 0) := (others => '0');
    signal shifter      : std_logic_vector(7 downto 0) := (others => '0');

    -- the start edge is seen 2.5 clocks late on average (the synchroniser,
    -- and the edge falling anywhere within a clock)
    constant detection_latency : natural := 2 * 256 + 128;

begin

    idle <= '0' when receiving else '1';

    process(clock)
        variable next_sample : signed(21 downto 0);
    begin
        if rising_edge(clock) then
            next_sample   := until_sample - 256;
            sync          <= sync(0) & rxd;
            valid         <= '0';
            framing_error <= '0';

            if wait_high then
                if sync(1) = '1' then
                    wait_high <= false;
                end if;
            elsif not receiving then
                if sync(1) = '0' then
                    -- start edge: the first sample is half a bit after it
                    receiving    <= true;
                    bit_index    <= 0;
                    until_sample <= signed(resize(bit_time / 2, 22)) - detection_latency;
                end if;
            else
                if next_sample > 0 then
                    until_sample <= next_sample;
                else
                    -- the middle of bit bit_index
                    until_sample <= next_sample + signed(resize(bit_time, 22));
                    case bit_index is
                        when 0 =>
                            if sync(1) = '1' then
                                receiving <= false;        -- a glitch, not a start bit
                            end if;
                            bit_index <= 1;
                        when 9 =>
                            receiving <= false;            -- listening again mid stop bit
                            if sync(1) = '1' then
                                valid <= '1';
                                data  <= shifter;
                            else
                                framing_error <= '1';
                                wait_high     <= true;
                            end if;
                        when others =>
                            shifter   <= sync(1) & shifter(7 downto 1);
                            bit_index <= bit_index + 1;
                    end case;
                end if;
            end if;

            if reset = '1' then
                receiving <= false;
                wait_high <= false;
            end if;
        end if;
    end process;

end architecture rtl;
