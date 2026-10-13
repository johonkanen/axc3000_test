-- hyperram_axi4lite_bridge_tb - exercises the bridge's own new logic
-- (arbitration between the two masters, 32<->64 bit placement, write
-- serialisation, id-based response routing) against a simple behavioural
-- mock of hyperram_axi's native port, not the real core - that part is
-- already covered by hVHDL_memory_library's own testbench. The mock
-- accepts one command at a time (legal: hyperram_axi may accept up to 4
-- queued, it isn't required to), applying writes/returning reads from an
-- 8-word memory indexed by addr(5 downto 3).
--
--   nvc --std=2019 -a ../hyperram_axi4lite_bridge.vhd hyperram_axi4lite_bridge_tb.vhd
--   nvc --std=2019 -e hyperram_axi4lite_bridge_tb -r
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity hyperram_axi4lite_bridge_tb is end entity;

architecture sim of hyperram_axi4lite_bridge_tb is

    signal clock : std_logic := '0';
    signal reset : boolean := true;
    signal done  : boolean := false;

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

    -- the mock: single command in flight at a time
    type mock_state_t is (idle, writing, reading);
    signal mock_state : mock_state_t := idle;
    signal mock_id     : std_logic_vector(7 downto 0) := (others => '0');
    signal mock_beat   : unsigned(2 downto 0) := (others => '0');
    type mem_array is array (0 to 7) of std_logic_vector(63 downto 0);
    signal mem : mem_array := (others => (others => '0'));

    signal errors : natural := 0;

    procedure check(cond : boolean; msg : string; signal errors : inout natural) is
    begin
        if not cond then
            report "FAIL: " & msg severity error;
            errors <= errors + 1;
        end if;
    end procedure;

begin

    clock <= not clock after 5 ns when not done;
    reset <= true, false after 23 ns;

    watchdog : process
    begin
        wait for 10 us;
        if not done then
            report "TIMEOUT: simulation did not finish in time" severity failure;
        end if;
        wait;
    end process;

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
    arw_ready <= '1' when mock_state = idle else '0';
    w_ready   <= '1' when mock_state = writing else '0';

    mock : process(clock)
    begin
        if rising_edge(clock) then
            b_valid <= '0';
            r_valid <= '0';

            case mock_state is
                when idle =>
                    if arw_valid = '1' and arw_ready = '1' then
                        mock_id   <= arw_id;
                        mock_beat <= unsigned(arw_addr(5 downto 3));
                        if arw_write = '1' then
                            mock_state <= writing;
                        else
                            mock_state <= reading;
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

                when reading =>
                    r_id    <= mock_id;
                    r_data  <= mem(to_integer(mock_beat));
                    r_last  <= '1';
                    r_resp  <= "00";
                    r_valid <= '1';
                    mock_state <= idle;
            end case;

            if reset then
                mock_state <= idle;
                mem <= (others => (others => '0'));
            end if;
        end if;
    end process;

    -- fixed handshake on the master side: always ready for B/R
    d_bready <= '1'; i_bready <= '1';
    d_rready <= '1'; i_rready <= '1';

    stimulus : process
        procedure cycle is begin wait until rising_edge(clock); end procedure;

        -- Clears `valid` once `ready` is seen high at a clock edge. Robust even
        -- when `ready` is already high the instant this is called - unlike
        -- `while ready /= '1' loop cycle; end loop;`, which then exits with
        -- ZERO cycles consumed, so an immediately-following same-delta `valid`
        -- pulse never reaches a clock edge for the other side to sample (this
        -- is exactly what hung test 6 originally: d_wready was already '1'
        -- when checked, so d_wvalid's pulse was set and cleared in the same
        -- delta cycle, never actually seen by the mock).
        procedure handshake(signal valid : out std_logic; signal ready : in std_logic) is
        begin
            wait until rising_edge(clock) and ready = '1';
            valid <= '0';
        end procedure;
    begin
        wait until not reset;
        cycle;

        ------------------------------------------------------------
        -- 1. data_manager write to addr 0x10 (bit2=0, low half), 0xDEADBEEF
        d_awaddr <= x"00000010"; d_awvalid <= '1';
        d_wdata  <= x"DEADBEEF"; d_wstrb <= "1111"; d_wvalid <= '1';
        handshake(d_awvalid, d_awready);
        handshake(d_wvalid, d_wready);
        wait until d_bvalid = '1';
        cycle;

        -- check the unused (high) half of the beat stayed zero
        report "progress: test1 write done";
        check(mem(2)(31 downto 0) = x"DEADBEEF", "low-half write landed at the right bytes", errors);
        check(mem(2)(63 downto 32) = x"00000000", "high half of a low-half write stays untouched", errors);

        ------------------------------------------------------------
        -- 2. data_manager read it back
        d_araddr <= x"00000010"; d_arvalid <= '1';
        handshake(d_arvalid, d_arready);
        wait until d_rvalid = '1';
        report "progress: test2 read done";
        check(d_rdata = x"DEADBEEF", "data_manager read back what it wrote (low half)", errors);
        cycle;

        ------------------------------------------------------------
        -- 3. instruction_manager write to addr 0x14 (bit2=1, high half), 0xCAFEF00D
        i_awaddr <= x"00000014"; i_awvalid <= '1';
        i_wdata  <= x"CAFEF00D"; i_wstrb <= "1111"; i_wvalid <= '1';
        handshake(i_awvalid, i_awready);
        handshake(i_wvalid, i_wready);
        wait until i_bvalid = '1';
        cycle;

        report "progress: test3 write done";
        check(mem(2)(63 downto 32) = x"CAFEF00D", "high-half write landed at the right bytes", errors);
        check(mem(2)(31 downto 0) = x"DEADBEEF", "low half untouched by a high-half write", errors);

        ------------------------------------------------------------
        -- 4. instruction_manager reads it back
        i_araddr <= x"00000014"; i_arvalid <= '1';
        handshake(i_arvalid, i_arready);
        wait until i_rvalid = '1';
        report "progress: test4 read done";
        check(i_rdata = x"CAFEF00D", "instruction_manager read back what it wrote (high half)", errors);
        cycle;

        ------------------------------------------------------------
        -- 5. priority: both masters present an AR in the same cycle - data_manager
        --    must win first (fixed priority), instruction_manager must still be
        --    served right after, each getting its OWN data back correctly
        d_araddr <= x"00000010"; d_arvalid <= '1';
        i_araddr <= x"00000014"; i_arvalid <= '1';
        cycle;
        check(d_arready = '1' and i_arready = '0', "data_manager AR wins priority over instruction_manager", errors);
        handshake(d_arvalid, d_arready);
        wait until d_rvalid = '1';
        report "progress: test5a data read resolved";
        check(d_rdata = x"DEADBEEF", "data_manager's read resolved correctly under contention", errors);
        cycle;
        handshake(i_arvalid, i_arready);
        wait until i_rvalid = '1';
        report "progress: test5b instr read resolved";
        check(i_rdata = x"CAFEF00D", "instruction_manager's read resolved correctly after data_manager", errors);
        cycle;

        ------------------------------------------------------------
        -- 6. write serialisation: instruction_manager must not be granted an AW
        --    while data_manager's write is still waiting to send its W beat.
        --    i_awvalid is withdrawn right after the check (rather than left
        --    asserted across the unrelated wait below) because the bridge
        --    grants it the instant w_pending clears, independent of when this
        --    process gets back around to watching for it via handshake() -
        --    leaving it up risks the grant landing "in the background" a
        --    cycle or two before this process is looking, which then hangs
        --    waiting for a second grant that never comes.
        d_awaddr <= x"00000018"; d_awvalid <= '1';   -- AW accepted, W held back
        handshake(d_awvalid, d_awready);

        i_awaddr <= x"00000018"; i_awvalid <= '1';
        cycle;
        check(i_awready = '0', "instruction_manager's AW is held off while a write's W phase is pending", errors);
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
        report "progress: test6 serialisation done";
        check(mem(3)(31 downto 0) = x"33334444", "instruction_manager's write went through after data_manager's finished", errors);

        ------------------------------------------------------------
        if errors = 0 then
            report "PASS: hyperram_axi4lite_bridge_tb";
        else
            report "FAIL: " & integer'image(errors) & " check(s) failed" severity failure;
        end if;
        done <= true;
        wait;
    end process;

end architecture sim;
