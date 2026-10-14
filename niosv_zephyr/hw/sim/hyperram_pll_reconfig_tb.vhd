-- hyperram_pll_reconfig_tb - the reconfiguration state machine against a
-- behavioural mock of emif_cal's AXI4-Lite slave, modelled on the real
-- bridge (altera_emif_cal_gearbox.sv): one transaction at a time, awready/
-- wready/arready only while idle, BVALID a single-clock pulse (lost if
-- BREADY is low), RVALID held until RREADY, each after a configurable delay.
-- Phase requests come from a 100 MHz process shaped like hyperram_core's
-- (shift set four cycles before shift_enable, which is high for ten).
--
--   python3 run.py -v "*pll_reconfig*"          (from the repo root)
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

entity hyperram_pll_reconfig_tb is
    generic (runner_cfg : string);
end entity;

architecture vunit_simulation of hyperram_pll_reconfig_tb is

    constant c_enable_addr : unsigned(26 downto 0) := to_unsigned(16#A00010#, 27);
    constant c_c1_addr     : unsigned(26 downto 0) := to_unsigned(16#A00060#, 27);
    constant c_c1_initial  : std_logic_vector(31 downto 0) := x"0600080C";
    constant c_phase_mask  : std_logic_vector(31 downto 0) := x"00380000";

    signal clk25  : std_logic := '0';
    signal clk100 : std_logic := '0';
    signal reset  : std_logic := '1';
    signal locked : std_logic := '0';

    signal awaddr, araddr : std_logic_vector(26 downto 0);
    signal wdata, rdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal awvalid, awready, arvalid, arready, wvalid, wready : std_logic := '0';
    signal rvalid, rready, bvalid, bready : std_logic := '0';

    signal dps_shift        : std_logic_vector(2 downto 0) := (others => '0');
    signal dps_shift_enable : std_logic := '0';

    -- the mock slave
    signal slave_delay   : natural := 20;
    signal reg_c1        : std_logic_vector(31 downto 0) := c_c1_initial;
    signal enable_writes : natural := 0;
    signal c1_writes     : natural := 0;
    signal other_writes  : natural := 0;
    signal bus_seen      : boolean := false;     -- any AWVALID/ARVALID

    function phase_of(r : std_logic_vector) return natural is
    begin
        return to_integer(unsigned(r(21 downto 19)));
    end function;

begin

    clk25  <= not clk25  after 20 ns;
    clk100 <= not clk100 after 5 ns;

    dut : entity work.hyperram_pll_reconfig
        port map(
            clock => clk25, reset => reset, pll_locked => locked,
            axil_awaddr => awaddr, axil_awvalid => awvalid, axil_awready => awready,
            axil_araddr => araddr, axil_arvalid => arvalid, axil_arready => arready,
            axil_wdata => wdata, axil_wvalid => wvalid, axil_wready => wready,
            axil_rdata => rdata, axil_rvalid => rvalid, axil_rready => rready,
            axil_bvalid => bvalid, axil_bready => bready,
            dps_shift => dps_shift, dps_shift_enable => dps_shift_enable);

------------------------------------------------------------------------
    slave : process(clk25)
        type state_t is (idle, w_delay, r_delay, r_resp);
        variable state  : state_t := idle;
        variable aw_got, w_got : boolean := false;
        variable a_addr : unsigned(26 downto 0);
        variable a_data : std_logic_vector(31 downto 0);
        variable cnt    : natural := 0;
    begin
        if rising_edge(clk25) then
            bvalid <= '0';
            if awvalid = '1' or arvalid = '1' then
                bus_seen <= true;
            end if;

            case state is
                when idle =>
                    if awvalid = '1' and awready = '1' then
                        aw_got := true;
                        a_addr := unsigned(awaddr);
                    end if;
                    if wvalid = '1' and wready = '1' then
                        w_got  := true;
                        a_data := wdata;
                    end if;
                    if aw_got and w_got then
                        cnt   := 0;
                        state := w_delay;
                    elsif arvalid = '1' and arready = '1' then
                        a_addr := unsigned(araddr);
                        cnt    := 0;
                        state  := r_delay;
                    end if;

                when w_delay =>
                    cnt := cnt + 1;
                    if cnt >= slave_delay then
                        if a_addr = c_c1_addr then
                            reg_c1    <= a_data;
                            c1_writes <= c1_writes + 1;
                        elsif a_addr = c_enable_addr then
                            enable_writes <= enable_writes + 1;
                        else
                            other_writes <= other_writes + 1;
                        end if;
                        bvalid <= '1';          -- a single-clock pulse, as the real bridge
                        aw_got := false;
                        w_got  := false;
                        state  := idle;
                    end if;

                when r_delay =>
                    cnt := cnt + 1;
                    if cnt >= slave_delay then
                        if a_addr = c_c1_addr then
                            rdata <= reg_c1;
                        else
                            rdata <= (others => '0');
                        end if;
                        rvalid <= '1';
                        state  := r_resp;
                    end if;

                when r_resp =>
                    if rready = '1' then
                        rvalid <= '0';
                        state  := idle;
                    end if;
            end case;

            if state = idle and not aw_got then awready <= '1'; else awready <= '0'; end if;
            if state = idle and not w_got  then wready  <= '1'; else wready  <= '0'; end if;
            if state = idle and not aw_got and not w_got then arready <= '1'; else arready <= '0'; end if;
        end if;
    end process;

------------------------------------------------------------------------
    main : process
        -- hyperram_core's shape: shift first, enable four cycles later, held ten
        procedure request(phase : natural) is
        begin
            wait until rising_edge(clk100);
            dps_shift <= std_logic_vector(to_unsigned(phase, 3));
            for i in 1 to 4 loop wait until rising_edge(clk100); end loop;
            dps_shift_enable <= '1';
            for i in 1 to 10 loop wait until rising_edge(clk100); end loop;
            dps_shift_enable <= '0';
        end procedure;

        procedure lock_and_enable is
        begin
            reset <= '0';
            wait for 200 ns;
            locked <= '1';
            wait until enable_writes = 1 for 100 us;
            check_equal(enable_writes, 1, "enable-registers write after lock");
        end procedure;

        procedure wait_for_phase(phase : natural; timeout : time) is
        begin
            if phase_of(reg_c1) /= phase then
                wait until phase_of(reg_c1) = phase for timeout;
            end if;
            check_equal(phase_of(reg_c1), phase, "C1 phase field");
            check_equal(reg_c1 and not c_phase_mask, c_c1_initial and not c_phase_mask,
                        "C1's other fields unchanged");
        end procedure;
    begin
        test_runner_setup(runner, runner_cfg);
        while test_suite loop

            if run("nothing_on_the_bus_before_lock") then
                reset <= '0';
                wait for 5 us;
                check(not bus_seen, "no AXI request before the PLL locks");
                locked <= '1';
                wait until enable_writes = 1 for 100 us;
                check_equal(enable_writes, 1);

            elsif run("phase_request_applied_to_c1_only") then
                lock_and_enable;
                request(5);
                wait_for_phase(5, 100 us);
                wait for 10 us;
                check_equal(c1_writes, 1);
                check_equal(other_writes, 0, "no other counter (C0/C2) written");
                check_equal(enable_writes, 1);

            elsif run("every_phase_in_turn") then
                lock_and_enable;
                for p in 1 to 7 loop
                    request(p);
                    wait_for_phase(p, 100 us);
                end loop;
                request(0);
                wait_for_phase(0, 100 us);
                check_equal(other_writes, 0);

            elsif run("request_during_write_is_not_dropped") then
                slave_delay <= 400;             -- 16 us per transaction
                lock_and_enable;
                request(3);
                wait for 5 us;                  -- the read of C1 still in flight
                request(6);
                wait_for_phase(6, 200 us);      -- the newest request wins
                check_equal(other_writes, 0);

            elsif run("lock_loss_stops_and_restarts_cleanly") then
                lock_and_enable;
                request(2);
                wait_for_phase(2, 100 us);
                locked <= '0';
                wait for 5 us;
                locked <= '1';
                wait until enable_writes = 2 for 100 us;
                check_equal(enable_writes, 2, "enable rewritten after relock");
                request(4);
                wait_for_phase(4, 100 us);
            end if;

        end loop;
        test_runner_cleanup(runner);
    end process;

    test_runner_watchdog(runner, 20 ms);

end architecture;
