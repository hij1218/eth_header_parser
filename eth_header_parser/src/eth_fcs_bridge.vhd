------------------------------------------------------------------------
--  Entity:  eth_fcs_bridge
--  Description:
--    Converts 66-bit descrambled blocks to the din[63:0]/din_v[7:0]
--    interface expected by eth_fcs.vhd (slice-by-8 CRC module).
--    Strips preamble/SFD, passes frame data bytes with correct valid
--    masks, and handles SOF1/SOF2/SOF3 alignment.
--
--    This module sits in a parallel path alongside eth_hdr_realign.
--    It does NOT affect header parsing latency.
--
--    500 MHz rate limiting:
--      fcs_clk_en is emitted at max 50% duty (1 pulse per 2 clocks).
--      A 16-deep skid FIFO buffers input bursts from a 100%-duty source
--      (testbench) so the downstream eth_fcs can pipeline its CRC
--      feedback loop. In real 10GBASE-R deployment blk_v averages ~31%
--      duty, so the FIFO sees minimal occupancy.
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.eth_hdr_parser_pkg.all;

entity eth_fcs_bridge is
port (
    clk     : in  std_logic;
    rst     : in  std_logic;
    -- Input: descrambled 66-bit blocks
    blk_d   : in  std_logic_vector(65 downto 0);
    blk_v   : in  std_logic;
    -- Output: din/din_v for eth_fcs (max 50% duty)
    fcs_din   : out std_logic_vector(63 downto 0);
    fcs_din_v : out std_logic_vector(7 downto 0);
    fcs_clk_en: out std_logic
);
end eth_fcs_bridge;

architecture rtl of eth_fcs_bridge is

    type state_t is (IDLE_S, SOF1_PRE_S, SOF2_PRE1_S, SOF2_PRE2_S, DATA_S);
    signal state : state_t := IDLE_S;

    signal is_ctrl     : std_logic;
    signal block_type  : std_logic_vector(7 downto 0);
    signal dec_data    : std_logic_vector(63 downto 0);

    -- Internal state-machine output (pre-FIFO)
    signal int_din   : std_logic_vector(63 downto 0) := (others => '0');
    signal int_din_v : std_logic_vector(7 downto 0)  := (others => '0');
    signal int_push  : std_logic := '0';

    -- Drain counter: keeps pushing idles for N cycles after the frame
    -- ends so eth_fcs can shift its 6-stage pipe and complete EOF
    -- processing. Idle blocks outside this window are suppressed to
    -- avoid overflowing the output FIFO (10GBASE-R source is 31% duty
    -- in deployment, but simulation/testbench may push every cycle).
    signal drain_cnt : unsigned(3 downto 0) := (others => '0');

    -- 128-deep skid FIFO: stores {din[63:0], din_v[7:0]} = 72 bits.
    -- At 50% output duty, input bursts longer than 128 blocks overflow;
    -- a standard 1500-byte Ethernet frame is ~188 blocks, so max frame
    -- bursts from an aggressive simulator source may not fit. In real
    -- 10GBASE-R deployment blk_v averages 31% (< 50% output rate), so
    -- the FIFO empties between successive 10G blocks and stays at <=1.
    constant FIFO_AW : integer := 7;  -- 128 entries
    type fifo_mem_t is array(0 to 2**FIFO_AW - 1) of std_logic_vector(71 downto 0);
    signal fifo_mem : fifo_mem_t := (others => (others => '0'));
    signal wr_ptr   : unsigned(FIFO_AW-1 downto 0) := (others => '0');
    signal rd_ptr   : unsigned(FIFO_AW-1 downto 0) := (others => '0');
    signal count    : unsigned(FIFO_AW   downto 0) := (others => '0');

    -- 50% duty toggle: emit only on emit_phase='1'
    signal emit_phase : std_logic := '1';

begin

    is_ctrl    <= '1' when blk_d(1 downto 0) = SYNC_CTRL else '0';
    block_type <= blk_d(9 downto 2);
    dec_data   <= blk_d(65 downto 2);

    main_p : process(clk)
        variable eof_bytes : integer range 0 to 7;
        variable is_sof    : std_logic;
        variable push_ok   : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= IDLE_S;
                int_din   <= (others => '0');
                int_din_v <= (others => '0');
                int_push  <= '0';
                drain_cnt <= (others => '0');
            else
                int_din   <= (others => '0');
                int_din_v <= (others => '0');

                -- Drain-cycle tracker: reload while processing a frame,
                -- count down once we return to IDLE_S.
                if state /= IDLE_S then
                    drain_cnt <= to_unsigned(8, drain_cnt'length);
                elsif drain_cnt /= 0 then
                    drain_cnt <= drain_cnt - 1;
                end if;

                -- Suppress idle pushes when the bridge has nothing useful
                -- to hand to eth_fcs (state=IDLE, no drain pending, and
                -- this block is not a fresh SOF control block).
                is_sof := '0';
                if is_ctrl = '1' and
                   (block_type = BT_SOF1 or block_type = BT_SOF2 or block_type = BT_SOF3) then
                    is_sof := '1';
                end if;
                if state /= IDLE_S or drain_cnt /= 0 or is_sof = '1' then
                    push_ok := '1';
                else
                    push_ok := '0';
                end if;
                int_push <= blk_v and push_ok;

                if blk_v = '1' then
                    case state is

                    when IDLE_S =>
                        if is_ctrl = '1' and block_type = BT_SOF1 then
                            state <= SOF1_PRE_S;
                        elsif is_ctrl = '1' and (block_type = BT_SOF2 or block_type = BT_SOF3) then
                            state <= SOF2_PRE1_S;
                        end if;

                    when SOF1_PRE_S =>
                        -- First DATA block after SOF1 = first frame data (8 bytes)
                        if is_ctrl = '0' then
                            int_din   <= dec_data;
                            int_din_v <= "11111111";
                            state     <= DATA_S;
                        else
                            state <= IDLE_S;  -- unexpected ctrl
                        end if;

                    when SOF2_PRE1_S =>
                        -- First DATA block after SOF2/3: lower 4 = preamble, upper 4 = frame data
                        if is_ctrl = '0' then
                            int_din   <= dec_data;
                            int_din_v <= "11110000";  -- upper 4 bytes valid
                            state     <= SOF2_PRE2_S;
                        else
                            state <= IDLE_S;
                        end if;

                    when SOF2_PRE2_S =>
                        -- Second DATA block after SOF2/3: full 8 bytes
                        if is_ctrl = '0' then
                            int_din   <= dec_data;
                            int_din_v <= "11111111";
                            state     <= DATA_S;
                        elsif is_ctrl = '1' and is_eof_type(block_type) then
                            -- Very short frame: EOF right after first data word
                            eof_bytes := eof_data_bytes(block_type);
                            int_din <= dec_data;
                            case eof_bytes is
                                when 0 => int_din_v <= "00000000";
                                when 1 => int_din(7 downto 0) <= dec_data(63 downto 56);
                                          int_din_v <= "00000001";
                                when 2 => int_din(15 downto 0) <= dec_data(63 downto 48);
                                          int_din_v <= "00000011";
                                when 3 => int_din(23 downto 0) <= dec_data(63 downto 40);
                                          int_din_v <= "00000111";
                                when 4 => int_din(31 downto 0) <= dec_data(63 downto 32);
                                          int_din_v <= "00001111";
                                when 5 => int_din(39 downto 0) <= dec_data(63 downto 24);
                                          int_din_v <= "00011111";
                                when 6 => int_din(47 downto 0) <= dec_data(63 downto 16);
                                          int_din_v <= "00111111";
                                when 7 => int_din(55 downto 0) <= dec_data(63 downto 8);
                                          int_din_v <= "01111111";
                            end case;
                            state <= IDLE_S;
                        else
                            state <= IDLE_S;
                        end if;

                    when DATA_S =>
                        if is_ctrl = '0' then
                            -- Full data word
                            int_din   <= dec_data;
                            int_din_v <= "11111111";
                        elsif is_ctrl = '1' and is_eof_type(block_type) then
                            -- EOF: extract trailing data bytes
                            -- In EOF blocks, data bytes are at high end of dec_data
                            -- and map to low byte positions (matching XGMII/64b66b decoder)
                            eof_bytes := eof_data_bytes(block_type);
                            int_din <= dec_data;
                            case eof_bytes is
                                when 0 => int_din_v <= "00000000";
                                when 1 => int_din(7 downto 0) <= dec_data(63 downto 56);
                                          int_din_v <= "00000001";
                                when 2 => int_din(15 downto 0) <= dec_data(63 downto 48);
                                          int_din_v <= "00000011";
                                when 3 => int_din(23 downto 0) <= dec_data(63 downto 40);
                                          int_din_v <= "00000111";
                                when 4 => int_din(31 downto 0) <= dec_data(63 downto 32);
                                          int_din_v <= "00001111";
                                when 5 => int_din(39 downto 0) <= dec_data(63 downto 24);
                                          int_din_v <= "00011111";
                                when 6 => int_din(47 downto 0) <= dec_data(63 downto 16);
                                          int_din_v <= "00111111";
                                when 7 => int_din(55 downto 0) <= dec_data(63 downto 8);
                                          int_din_v <= "01111111";
                            end case;
                            state <= IDLE_S;
                        elsif is_ctrl = '1' then
                            -- New SOF within frame (back-to-back without EOF)
                            if block_type = BT_SOF1 then
                                state <= SOF1_PRE_S;
                            elsif block_type = BT_SOF2 or block_type = BT_SOF3 then
                                state <= SOF2_PRE1_S;
                            else
                                state <= IDLE_S;
                            end if;
                        end if;

                    end case;
                end if;
            end if;
        end if;
    end process main_p;

    -------------------------------------------------------------------
    -- Skid FIFO: stores (int_din, int_din_v) pushed every blk_v cycle;
    -- pops once every 2 clocks into the registered output.
    -- Result: fcs_clk_en is at most 50% duty, giving eth_fcs a 2-clock
    -- budget for its combinational CRC feedback loop.
    -------------------------------------------------------------------
    fifo_p : process(clk)
        variable do_read : std_logic;
        variable nxt_cnt : unsigned(FIFO_AW downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_ptr     <= (others => '0');
                rd_ptr     <= (others => '0');
                count      <= (others => '0');
                emit_phase <= '1';
                fcs_din    <= (others => '0');
                fcs_din_v  <= (others => '0');
                fcs_clk_en <= '0';
            else
                -- Toggle emit phase every clock
                emit_phase <= not emit_phase;

                -- Default outputs
                fcs_clk_en <= '0';
                fcs_din    <= (others => '0');
                fcs_din_v  <= (others => '0');

                do_read := '0';

                -- Read: every other cycle if FIFO non-empty
                if emit_phase = '1' and count /= 0 then
                    fcs_din    <= fifo_mem(to_integer(rd_ptr))(71 downto 8);
                    fcs_din_v  <= fifo_mem(to_integer(rd_ptr))(7 downto 0);
                    fcs_clk_en <= '1';
                    rd_ptr     <= rd_ptr + 1;
                    do_read    := '1';
                end if;

                -- Write: on int_push
                if int_push = '1' then
                    fifo_mem(to_integer(wr_ptr)) <= int_din & int_din_v;
                    wr_ptr <= wr_ptr + 1;
                end if;

                -- Count update
                nxt_cnt := count;
                if int_push = '1' and do_read = '0' then
                    nxt_cnt := count + 1;
                elsif int_push = '0' and do_read = '1' then
                    nxt_cnt := count - 1;
                end if;
                count <= nxt_cnt;

                -- Simulation-only overflow check
                -- pragma translate_off
                assert not (int_push = '1' and count = 2**FIFO_AW)
                    report "eth_fcs_bridge: FIFO overflow"
                    severity failure;
                -- pragma translate_on
            end if;
        end if;
    end process fifo_p;

end rtl;
