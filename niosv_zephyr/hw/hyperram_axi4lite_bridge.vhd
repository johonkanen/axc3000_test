-- hyperram_axi4lite_bridge - arbitrates Nios V/g's two AXI4-Lite masters
-- (instruction_manager, data_manager - single 32-bit beat, no id/len/size/
-- burst/last: confirmed from the generated niosv_zephyr_sys.vhd, not
-- assumed) onto source/hVHDL_memory_library's hyperram_axi, whose native
-- port is AXI3-shaped (one shared read/write address channel, 64-bit
-- beats, id-tagged). No protocol-mismatch adapter chain is needed - the
-- hyperram_axi port already differs from AXI4-Lite in exactly two ways,
-- both handled here:
--
--   1. two masters, one address channel: fixed-priority arbiter
--      (data writes > data reads > instruction writes > instruction
--      reads - instruction fetches should mostly hit the i-cache once
--      enabled, so data traffic gets priority). Writes are serialised
--      through the bridge (arw_ready for an AW is gated on the previous
--      write's W phase having been sent) because hyperram_axi's write
--      buffer expects W beats in the same order its command queue was
--      given them; reads need no such gating - the core returns them in
--      request order and this bridge's 2-bit id field (bit 0 = owner)
--      only needs to steer each response to the right master, which it
--      can do for any number of reads in flight within the core's own
--      queue depth.
--   2. 32-bit beats vs the core's 64-bit ones: the byte address's bit 2
--      selects which half of a 64-bit beat a 32-bit AXI4-Lite transfer
--      lands in; the unused half is write-strobed off and, for reads,
--      discarded by picking the right half of r_data. Latched per owner
--      (d_read_bit2/i_read_bit2) since each master is assumed to have at
--      most one outstanding transaction per direction at a time - true
--      for Nios V/g's non-pipelined AXI4-Lite masters, not asserted here
--      in hardware.
--
-- Untested on real HyperRAM/hardware yet - see sim/hyperram_axi4lite_bridge_tb.vhd
-- for what is verified (the arbitration/width-adaptation logic above, against
-- a simple behavioural mock of the native port, not the real hyperram_axi -
-- that part is already validated by the submodule's own testbench).
library ieee;
    use ieee.std_logic_1164.all;

entity hyperram_axi4lite_bridge is
    port(
        clock : in std_logic;
        reset : in boolean;

        -- data_manager (AXI4-Lite)
        d_awaddr  : in  std_logic_vector(31 downto 0);
        d_awvalid : in  std_logic;
        d_awready : out std_logic;
        d_wdata   : in  std_logic_vector(31 downto 0);
        d_wstrb   : in  std_logic_vector(3 downto 0);
        d_wvalid  : in  std_logic;
        d_wready  : out std_logic;
        d_bresp   : out std_logic_vector(1 downto 0);
        d_bvalid  : out std_logic;
        d_bready  : in  std_logic;
        d_araddr  : in  std_logic_vector(31 downto 0);
        d_arvalid : in  std_logic;
        d_arready : out std_logic;
        d_rdata   : out std_logic_vector(31 downto 0);
        d_rresp   : out std_logic_vector(1 downto 0);
        d_rvalid  : out std_logic;
        d_rready  : in  std_logic;

        -- instruction_manager (AXI4-Lite)
        i_awaddr  : in  std_logic_vector(31 downto 0);
        i_awvalid : in  std_logic;
        i_awready : out std_logic;
        i_wdata   : in  std_logic_vector(31 downto 0);
        i_wstrb   : in  std_logic_vector(3 downto 0);
        i_wvalid  : in  std_logic;
        i_wready  : out std_logic;
        i_bresp   : out std_logic_vector(1 downto 0);
        i_bvalid  : out std_logic;
        i_bready  : in  std_logic;
        i_araddr  : in  std_logic_vector(31 downto 0);
        i_arvalid : in  std_logic;
        i_arready : out std_logic;
        i_rdata   : out std_logic_vector(31 downto 0);
        i_rresp   : out std_logic_vector(1 downto 0);
        i_rvalid  : out std_logic;
        i_rready  : in  std_logic;

        -- hyperram_axi's native port, unchanged field for field
        arw_valid : out std_logic;
        arw_ready : in  std_logic;
        arw_addr  : out std_logic_vector(31 downto 0);
        arw_id    : out std_logic_vector(7 downto 0);
        arw_len   : out std_logic_vector(7 downto 0);
        arw_size  : out std_logic_vector(2 downto 0);
        arw_burst : out std_logic_vector(1 downto 0);
        arw_write : out std_logic;

        w_valid : out std_logic;
        w_ready : in  std_logic;
        w_data  : out std_logic_vector(63 downto 0);
        w_strb  : out std_logic_vector(7 downto 0);
        w_last  : out std_logic;

        b_valid : in  std_logic;
        b_ready : out std_logic;
        b_id    : in  std_logic_vector(7 downto 0);

        r_valid : in  std_logic;
        r_ready : out std_logic;
        r_data  : in  std_logic_vector(63 downto 0);
        r_id    : in  std_logic_vector(7 downto 0);
        r_resp  : in  std_logic_vector(1 downto 0);
        r_last  : in  std_logic
    );
end entity hyperram_axi4lite_bridge;

architecture rtl of hyperram_axi4lite_bridge is

    -- owner tag: '0' = data_manager, '1' = instruction_manager
    -- (two separate declarations - `constant a, b : std_logic := '0'` would
    -- give both the SAME value, not what's wanted here)
    constant data_owner  : std_logic := '0';
    constant instr_owner : std_logic := '1';

    signal w_pending   : std_logic := '0';   -- an accepted write's W phase not sent yet
    signal write_owner : std_logic := '0';
    signal write_bit2  : std_logic := '0';
    signal d_read_bit2, i_read_bit2 : std_logic := '0';

    -- this cycle's arbitration result (combinational)
    signal req_d_aw, req_d_ar, req_i_aw, req_i_ar : std_logic;
    signal sel_owner, sel_is_write : std_logic;

    signal cur_wdata : std_logic_vector(31 downto 0);
    signal cur_wstrb : std_logic_vector(3 downto 0);

begin

    -- writes wait for the previous one's data phase; reads are free - see
    -- the file header for why
    req_d_aw <= d_awvalid and not w_pending;
    req_i_aw <= i_awvalid and not w_pending;
    req_d_ar <= d_arvalid;
    req_i_ar <= i_arvalid;

    arw_valid <= req_d_aw or req_d_ar or req_i_aw or req_i_ar;
    arw_id    <= "0000000" & sel_owner;
    arw_len   <= x"00";          -- always 1 beat
    arw_size  <= "011";          -- always 8 bytes (the core's only legal value)
    arw_burst <= "01";           -- INCR (required field, moot at len=1)

    -- fixed priority: data write > data read > instruction write > instruction read
    arbitrate : process(req_d_aw, req_d_ar, req_i_aw, req_i_ar,
                         d_awaddr, d_araddr, i_awaddr, i_araddr, arw_ready)
    begin
        d_awready <= '0'; d_arready <= '0'; i_awready <= '0'; i_arready <= '0';
        arw_addr  <= (others => '0');
        arw_write <= '0';
        sel_owner <= data_owner;
        sel_is_write <= '0';

        if req_d_aw = '1' then
            arw_addr <= d_awaddr; arw_write <= '1'; sel_owner <= data_owner; sel_is_write <= '1';
            d_awready <= arw_ready;
        elsif req_d_ar = '1' then
            arw_addr <= d_araddr; arw_write <= '0'; sel_owner <= data_owner; sel_is_write <= '0';
            d_arready <= arw_ready;
        elsif req_i_aw = '1' then
            arw_addr <= i_awaddr; arw_write <= '1'; sel_owner <= instr_owner; sel_is_write <= '1';
            i_awready <= arw_ready;
        elsif req_i_ar = '1' then
            arw_addr <= i_araddr; arw_write <= '0'; sel_owner <= instr_owner; sel_is_write <= '0';
            i_arready <= arw_ready;
        end if;
    end process;

    latch_grant : process(clock)
    begin
        if rising_edge(clock) then
            if arw_valid = '1' and arw_ready = '1' then
                if sel_is_write = '1' then
                    w_pending   <= '1';
                    write_owner <= sel_owner;
                    write_bit2  <= arw_addr(2);
                elsif sel_owner = data_owner then
                    d_read_bit2 <= arw_addr(2);
                else
                    i_read_bit2 <= arw_addr(2);
                end if;
            end if;
            if w_valid = '1' and w_ready = '1' then
                w_pending <= '0';
            end if;
            if reset then
                w_pending <= '0';
            end if;
        end if;
    end process;

    -- W phase: forward whichever master owns the pending write, placed into
    -- the half of the 64-bit beat its address selected
    cur_wdata <= d_wdata when write_owner = data_owner else i_wdata;
    cur_wstrb <= d_wstrb when write_owner = data_owner else i_wstrb;

    w_valid <= '0' when w_pending = '0' else
               d_wvalid when write_owner = data_owner else i_wvalid;
    d_wready <= w_ready when (w_pending = '1' and write_owner = data_owner)   else '0';
    i_wready <= w_ready when (w_pending = '1' and write_owner = instr_owner) else '0';
    w_last   <= '1';

    w_data <= x"00000000" & cur_wdata when write_bit2 = '0' else cur_wdata & x"00000000";
    w_strb <= ("0000" & cur_wstrb) when write_bit2 = '0' else (cur_wstrb & "0000");

    -- B channel: routed by arw_id's owner bit
    d_bvalid <= b_valid when b_id(0) = data_owner   else '0';
    i_bvalid <= b_valid when b_id(0) = instr_owner else '0';
    b_ready  <= d_bready when b_id(0) = data_owner else i_bready;
    d_bresp  <= "00";    -- always OKAY - hyperram_axi never reports otherwise
    i_bresp  <= "00";

    -- R channel: routed by r_id's owner bit, half selected by that owner's latched bit2
    d_rvalid <= r_valid when r_id(0) = data_owner   else '0';
    i_rvalid <= r_valid when r_id(0) = instr_owner else '0';
    r_ready  <= d_rready when r_id(0) = data_owner else i_rready;
    d_rresp  <= r_resp;
    i_rresp  <= r_resp;
    d_rdata  <= r_data(63 downto 32) when d_read_bit2 = '1' else r_data(31 downto 0);
    i_rdata  <= r_data(63 downto 32) when i_read_bit2 = '1' else r_data(31 downto 0);

end architecture rtl;
