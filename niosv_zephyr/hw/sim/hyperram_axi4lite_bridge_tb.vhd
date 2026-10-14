-- hyperram_axi4lite_bridge_tb - exercises the bridge's own new logic
-- (arbitration between the two masters, 32<->64 bit placement, write
-- serialisation, id-based response routing) against a simple behavioural
-- mock of hyperram_axi's native port, not the real core - that part is
-- already covered by hVHDL_memory_library's own testbench. The mock keeps
-- up to 4 reads queued and returns them in order, a few cycles later (as
-- hyperram_axi does), and takes one write at a time; data comes from an
-- 8-word memory indexed by addr(5 downto 3).
--
-- Each `run(...)` test gets its own fresh simulation (VUnit's default), so
-- every test writes whatever it needs to read back itself - none of them
-- depend on another's leftover memory state.
--
--   python3 run.py -v "*hyperram*"          (from the repo root)
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

entity hyperram_axi4lite_bridge_tb is
    generic (runner_cfg : string);
end entity;

architecture vunit_simulation of hyperram_axi4lite_bridge_tb is

    signal clock : std_logic := '0';
    signal reset : boolean := true;

    -- data_manager
    signal d_awaddr, d_araddr, d_wdata, d_rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal d_wstrb : std_logic_vector(3 downto 0) := (others => '0');
    signal d_rresp, d_bresp : std_logic_vector(1 downto 0);
    signal d_awvalid, d_awready, d_wvalid, d_wready, d_bvalid, d_bready : std_logic := '0';
    signal d_arvalid, d_arready, d_rvalid, d_rready : std_logic := '0';

    -- instruction_manager
    signal i_awaddr, i_araddr, i_wdata, i_rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal i_wstrb : std_logic_vector(3 downto 0) := (others => '0');
    signal i_rresp, i_bresp : std_logic_vector(1 downto 0);
    signal i_awvalid, i_awready, i_wvalid, i_wready, i_bvalid, i_bready : std_logic := '0';
    signal i_arvalid, i_arready, i_rvalid, i_rready : std_logic := '0';

    -- native port to the mock
    signal arw_valid, arw_ready, arw_write : std_logic := '0';
    signal arw_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal arw_id, arw_len : std_logic_vector(7 downto 0);
    signal arw_size  : std_logic_vector(2 downto 0);
    signal arw_burst : std_logic_vector(1 downto 0);
    signal w_valid, w_ready, w_last : std_logic := '0';
    signal w_data : std_logic_vector(63 downto 0);
    signal w_strb : std_logic_vector(7 downto 0);
    signal b_valid, b_ready : std_logic := '0';
    signal b_id : std_logic_vector(7 downto 0) := (others => '0');
    signal r_valid, r_ready : std_logic := '0';
    signal r_data : std_logic_vector(63 downto 0) := (others => '0');
    signal r_id : std_logic_vector(7 downto 0) := (others => '0');
    signal r_resp : std_logic_vector(1 downto 0) := "00";
    signal r_last : std_logic := '0';

    -- the mock: a queue of up to 4 reads, one write at a time
    type mock_state_t is (idle, writing);
    signal mock_state : mock_state_t := idle;
    signal mock_id     : std_logic_vector(7 downto 0) := (others => '0');
    signal mock_beat   : unsigned(2 downto 0) := (others => '0');
    type read_entry is record
        id   : std_logic_vector(7 downto 0);
        beat : unsigned(2 downto 0);
    end record;
    type read_queue_t is array (0 to 3) of read_entry;
    signal read_queue : read_queue_t;
    signal rq_count   : natural range 0 to 4 := 0;
    signal rq_delay   : natural range 0 to 3 := 0;
    type mem_array is array (0 to 7) of std_logic_vector(63 downto 0);
    signal mem : mem_array := (others => (others => '0'));

begin

    clock <= not clock after 5 ns;
    reset <= true, false after 23 ns;

    u_bridge : entity work.hyperram_axi4lite_bridge
    port map(
        clock => clock, reset => reset,
        d_awaddr => d_awaddr, d_awvalid => d_awvalid, d_awready => d_awready,
        d_wdata => d_wdata, d_wstrb => d_wstrb, d_wvalid => d_wvalid, d_wready => d_wready,
        d_bresp => d_bresp, d_bvalid => d_bvalid, d_bready => d_bready,
        d_araddr => d_araddr, d_arvalid => d_arvalid, d_arready => d_arready,
        d_rdata => d_rdata, d_rresp => d_rresp, d_rvalid => d_rvalid, d_rready => d_rready,
        i_awaddr => i_awaddr, i_awvalid => i_awvalid, i_awready => i_awready,
        i_wdata => i_wdata, i_wstrb => i_wstrb, i_wvalid => i_wvalid, i_wready => i_wready,
        i_bresp => i_bresp, i_bvalid => i_bvalid, i_bready => i_bready,
        i_araddr => i_araddr, i_arvalid => i_arvalid, i_arready => i_arready,
        i_rdata => i_rdata, i_rresp => i_rresp, i_rvalid => i_rvalid, i_rready => i_rready,
        arw_valid => arw_valid, arw_ready => arw_ready, arw_addr => arw_addr,
        arw_id => arw_id, arw_len => arw_len, arw_size => arw_size, arw_burst => arw_burst,
        arw_write => arw_write,
        w_valid => w_valid, w_ready => w_ready, w_data => w_data, w_strb => w_strb, w_last => w_last,
        b_valid => b_valid, b_ready => b_ready, b_id => b_id,
        r_valid => r_valid, r_ready => r_ready, r_data => r_data, r_id => r_id,
        r_resp => r_resp, r_last => r_last
    );

    -- the mock core
    arw_ready <= '1' when mock_state = idle and rq_count < 4 else '0';
    w_ready   <= '1' when mock_state = writing else '0';

    mock : process(clock)
        variable q : read_queue_t;
        variable n : natural range 0 to 4;
    begin
        if rising_edge(clock) then
            b_valid <= '0';
            r_valid <= '0';
            q := read_queue;
            n := rq_count;

            -- the oldest read comes back once its delay is over (r_ready is
            -- always '1' in this testbench)
            if n > 0 then
                if rq_delay = 3 then
                    r_id    <= q(0).id;
                    r_data  <= mem(to_integer(q(0).beat));
                    r_last  <= '1';
                    r_resp  <= "00";
                    r_valid <= '1';
                    q(0 to 2) := q(1 to 3);
                    n := n - 1;
                    rq_delay <= 0;
                else
                    rq_delay <= rq_delay + 1;
                end if;
            end if;

            case mock_state is
                when idle =>
                    if arw_valid = '1' and arw_ready = '1' then
                        if arw_write = '1' then
                            mock_id    <= arw_id;
                            mock_beat  <= unsigned(arw_addr(5 downto 3));
                            mock_state <= writing;
                        else
                            q(n) := (arw_id, unsigned(arw_addr(5 downto 3)));
                            n := n + 1;
                        end if;
                    end if;

                when writing =>
                    if w_valid = '1' and w_ready = '1' then
                        for byte in 0 to 7 loop
                            if w_strb(byte) = '1' then
                                mem(to_integer(mock_beat))(8*byte+7 downto 8*byte)
                                    <= w_data(8*byte+7 downto 8*byte);
                            end if;
                        end loop;
                        b_id    <= mock_id;
                        b_valid <= '1';
                        mock_state <= idle;
                    end if;
            end case;

            read_queue <= q;
            rq_count   <= n;

            if reset then
                mock_state <= idle;
                rq_count   <= 0;
                rq_delay   <= 0;
                mem <= (others => (others => '0'));
            end if;
        end if;
    end process;

    -- fixed handshake on the master side: always ready for B/R
    d_bready <= '1'; i_bready <= '1';
    d_rready <= '1'; i_rready <= '1';

    test_runner : process
        procedure cycle is begin wait until rising_edge(clock); end procedure;

        -- Clears `valid` once `ready` is seen high at a clock edge. Robust
        -- even when `ready` is already high the instant this is called -
        -- unlike `while ready /= '1' loop cycle; end loop;`, which then
        -- exits with ZERO cycles consumed, so an immediately-following
        -- same-delta `valid` pulse never reaches a clock edge for the other
        -- side to sample.
        procedure handshake(signal valid : out std_logic; signal ready : in std_logic) is
        begin
            wait until rising_edge(clock) and ready = '1';
            valid <= '0';
        end procedure;

        -- a full AXI4-Lite write, for whichever master's signals are passed in
        procedure axi_write(signal awaddr  : out std_logic_vector(31 downto 0);
                             signal awvalid : out std_logic; signal awready : in std_logic;
                             signal wdata   : out std_logic_vector(31 downto 0);
                             signal wstrb   : out std_logic_vector(3 downto 0);
                             signal wvalid  : out std_logic; signal wready : in std_logic;
                             signal bvalid  : in std_logic;
                             addr, data : std_logic_vector(31 downto 0)) is
        begin
            awaddr <= addr; awvalid <= '1';
            wdata  <= data; wstrb  <= "1111"; wvalid <= '1';
            handshake(awvalid, awready);
            handshake(wvalid, wready);
            wait until bvalid = '1';
            cycle;
        end procedure;

        -- a full AXI4-Lite read, returning the data
        procedure axi_read(signal araddr  : out std_logic_vector(31 downto 0);
                            signal arvalid : out std_logic; signal arready : in std_logic;
                            signal rdata   : in std_logic_vector(31 downto 0);
                            signal rvalid  : in std_logic;
                            addr : std_logic_vector(31 downto 0);
                            variable result : out std_logic_vector(31 downto 0)) is
        begin
            araddr <= addr; arvalid <= '1';
            handshake(arvalid, arready);
            wait until rvalid = '1';
            result := rdata;
            cycle;
        end procedure;

        variable got : std_logic_vector(31 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);
        wait until not reset;
        cycle;

        while test_suite loop

            if run("data_manager_write_then_read_back_low_half") then
                -- addr 0x10, bit2=0 -> low half of the 64-bit beat
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000010", x"DEADBEEF");
                check_equal(mem(2)(31 downto 0), std_logic_vector'(x"DEADBEEF"),
                            "low-half write landed at the right bytes");
                check_equal(mem(2)(63 downto 32), std_logic_vector'(x"00000000"),
                            "high half of a low-half write stays untouched");

                axi_read(d_araddr, d_arvalid, d_arready, d_rdata, d_rvalid, x"00000010", got);
                check_equal(got, std_logic_vector'(x"DEADBEEF"),
                            "data_manager read back what it wrote (low half)");

            elsif run("instruction_manager_write_then_read_back_high_half") then
                -- addr 0x14, bit2=1 -> high half of the 64-bit beat
                axi_write(i_awaddr, i_awvalid, i_awready, i_wdata, i_wstrb, i_wvalid, i_wready,
                          i_bvalid, x"00000014", x"CAFEF00D");
                check_equal(mem(2)(63 downto 32), std_logic_vector'(x"CAFEF00D"),
                            "high-half write landed at the right bytes");
                check_equal(mem(2)(31 downto 0), std_logic_vector'(x"00000000"),
                            "low half of a high-half write stays untouched");

                axi_read(i_araddr, i_arvalid, i_arready, i_rdata, i_rvalid, x"00000014", got);
                check_equal(got, std_logic_vector'(x"CAFEF00D"),
                            "instruction_manager read back what it wrote (high half)");

            elsif run("data_manager_wins_priority_under_contention") then
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000010", x"DEADBEEF");
                axi_write(i_awaddr, i_awvalid, i_awready, i_wdata, i_wstrb, i_wvalid, i_wready,
                          i_bvalid, x"00000014", x"CAFEF00D");

                -- both masters present an AR in the same cycle - data_manager must
                -- win first (fixed priority), instruction_manager right after
                d_araddr <= x"00000010"; d_arvalid <= '1';
                i_araddr <= x"00000014"; i_arvalid <= '1';
                cycle;
                check_equal(d_arready, '1', "data_manager AR wins priority over instruction_manager");
                check_equal(i_arready, '0', "instruction_manager's AR waits while data_manager's is granted");
                handshake(d_arvalid, d_arready);
                wait until d_rvalid = '1';
                check_equal(d_rdata, std_logic_vector'(x"DEADBEEF"),
                            "data_manager's read resolved correctly under contention");
                cycle;
                handshake(i_arvalid, i_arready);
                wait until i_rvalid = '1';
                check_equal(i_rdata, std_logic_vector'(x"CAFEF00D"),
                            "instruction_manager's read resolved correctly after data_manager");
                cycle;

            elsif run("write_serialisation_blocks_the_other_master") then
                -- data_manager's write holds the bridge's one write slot until its
                -- W phase is sent; instruction_manager's AW must wait for it.
                --
                -- i_awvalid is withdrawn right after the check (rather than left
                -- asserted across the unrelated wait below) because the bridge
                -- grants it the instant w_pending clears, independent of when
                -- this process gets back around to watching for it via
                -- handshake() - leaving it up risks the grant landing "in the
                -- background" a cycle or two before this process is looking,
                -- which then hangs waiting for a second grant that never comes.
                d_awaddr <= x"00000018"; d_awvalid <= '1';   -- AW accepted, W held back
                handshake(d_awvalid, d_awready);

                i_awaddr <= x"00000018"; i_awvalid <= '1';
                cycle;
                check_equal(i_awready, '0',
                            "instruction_manager's AW is held off while a write's W phase is pending");
                i_awvalid <= '0';   -- withdraw - not accepted yet (i_awready was '0'), nothing lost
                cycle;

                d_wdata <= x"11112222"; d_wstrb <= "1111"; d_wvalid <= '1';
                handshake(d_wvalid, d_wready);
                wait until d_bvalid = '1';
                cycle;

                i_awaddr <= x"00000018"; i_awvalid <= '1';   -- re-assert now that the coast is clear
                handshake(i_awvalid, i_awready);
                i_wdata <= x"33334444"; i_wstrb <= "1111"; i_wvalid <= '1';
                handshake(i_wvalid, i_wready);
                wait until i_bvalid = '1';
                cycle;
                check_equal(mem(3)(31 downto 0), std_logic_vector'(x"33334444"),
                            "instruction_manager's write went through after data_manager's finished");

            elsif run("reads_in_flight_from_one_master_get_their_own_halves") then
                -- a cache line fill: back-to-back reads of both halves of two
                -- beats, all accepted before the first comes back
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000010", x"00000010");
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000014", x"00000014");
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000018", x"00000018");
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"0000001C", x"0000001C");

                i_arvalid <= '0';
                d_arvalid <= '1';
                d_araddr  <= x"00000014";
                wait until rising_edge(clock) and d_arready = '1';
                d_araddr  <= x"00000010";
                wait until rising_edge(clock) and d_arready = '1';
                d_araddr  <= x"0000001C";
                wait until rising_edge(clock) and d_arready = '1';
                d_araddr  <= x"00000018";
                wait until rising_edge(clock) and d_arready = '1';
                d_arvalid <= '0';
                check_equal(d_rvalid, '0', "all four accepted before the first came back");

                for expected in 0 to 3 loop
                    wait until rising_edge(clock) and d_rvalid = '1';
                    case expected is
                        when 0 => check_equal(d_rdata, std_logic_vector'(x"00000014"), "1st read");
                        when 1 => check_equal(d_rdata, std_logic_vector'(x"00000010"), "2nd read");
                        when 2 => check_equal(d_rdata, std_logic_vector'(x"0000001C"), "3rd read");
                        when others => check_equal(d_rdata, std_logic_vector'(x"00000018"), "4th read");
                    end case;
                end loop;

            elsif run("reads_in_flight_from_both_masters_get_their_own_halves") then
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000010", x"D0D0D0D0");
                axi_write(d_awaddr, d_awvalid, d_awready, d_wdata, d_wstrb, d_wvalid, d_wready,
                          d_bvalid, x"00000014", x"1D1D1D1D");

                -- both present a read at once: data's (low half) is granted
                -- first, instruction's (high half) next cycle, both in flight
                d_araddr <= x"00000010"; d_arvalid <= '1';
                i_araddr <= x"00000014"; i_arvalid <= '1';
                wait until rising_edge(clock) and d_arready = '1';
                d_arvalid <= '0';
                wait until rising_edge(clock) and i_arready = '1';
                i_arvalid <= '0';

                wait until rising_edge(clock) and (d_rvalid = '1' or i_rvalid = '1');
                check_equal(d_rvalid, '1', "data_manager's read comes back first");
                check_equal(d_rdata, std_logic_vector'(x"D0D0D0D0"), "data_manager got the low half");
                wait until rising_edge(clock) and i_rvalid = '1';
                check_equal(i_rdata, std_logic_vector'(x"1D1D1D1D"), "instruction_manager got the high half");
            end if;
        end loop;

        test_runner_cleanup(runner);
        wait;
    end process;

    test_runner_watchdog(runner, 10 us);

end architecture vunit_simulation;
