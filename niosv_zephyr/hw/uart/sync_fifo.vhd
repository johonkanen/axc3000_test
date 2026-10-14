-- sync_fifo - single-clock FIFO in block RAM.
--
-- A pop is a request: rdata holds the popped word the clock after pop. pop
-- and push are ignored when empty / full. count is the number of words in
-- it; a pushed word can be popped from the next clock on (count is updated
-- on the same edge that writes the RAM, so a pop never reads the address
-- being written).
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity sync_fifo is
    generic(
        g_width      : positive := 8;
        g_depth_log2 : positive := 11      -- 2**g_depth_log2 words
    );
    port(
        clock : in std_logic;
        reset : in std_logic;              -- empties it

        push  : in  std_logic;
        wdata : in  std_logic_vector(g_width - 1 downto 0);
        pop   : in  std_logic;
        rdata : out std_logic_vector(g_width - 1 downto 0);

        count : out unsigned(g_depth_log2 downto 0);
        empty : out std_logic;
        full  : out std_logic
    );
end entity sync_fifo;

architecture rtl of sync_fifo is

    constant depth : positive := 2**g_depth_log2;

    type ram_array is array (0 to depth - 1) of std_logic_vector(g_width - 1 downto 0);
    signal ram : ram_array;

    signal head, tail : unsigned(g_depth_log2 - 1 downto 0) := (others => '0');
    signal n          : unsigned(g_depth_log2 downto 0)     := (others => '0');

    signal do_push, do_pop : boolean;

begin

    do_push <= push = '1' and n /= depth;
    do_pop  <= pop = '1' and n /= 0;

    count <= n;
    empty <= '1' when n = 0 else '0';
    full  <= '1' when n = depth else '0';

    ram_port : process(clock)
    begin
        if rising_edge(clock) then
            if do_push then
                ram(to_integer(tail)) <= wdata;
            end if;
            rdata <= ram(to_integer(head));
        end if;
    end process;

    pointers : process(clock)
    begin
        if rising_edge(clock) then
            if do_push then
                tail <= tail + 1;
            end if;
            if do_pop then
                head <= head + 1;
            end if;
            if do_push and not do_pop then
                n <= n + 1;
            elsif do_pop and not do_push then
                n <= n - 1;
            end if;

            if reset = '1' then
                head <= (others => '0');
                tail <= (others => '0');
                n    <= (others => '0');
            end if;
        end if;
    end process;

end architecture rtl;
