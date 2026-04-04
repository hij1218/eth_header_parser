------------------------------------------------------------------------
--  Entity:  eth_hdr_realign
--  Description:
--    SOF1/SOF2/SOF3 detection from 66-bit descrambled blocks.
--    Strips preamble/SFD and outputs aligned 64-bit frame data words.
--
--    Key design: aligned_d/aligned_v are COMBINATIONAL outputs (not
--    registered), following the eth_64b66b.vhd pattern of minimal
--    pipeline stages. The downstream extract module registers the
--    fields directly, eliminating one pipeline stage.
--
--    Latency from SOF to first aligned_v:
--      SOF1: 1 clk (DATA block arrives next clock, combinational output)
--      SOF2/SOF3: 2 clk (barrel shift needs 2 blocks to assemble)
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.eth_hdr_parser_pkg.all;

entity eth_hdr_realign is
port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    -- Input: descrambled 66-bit blocks
    blk_d       : in  std_logic_vector(65 downto 0);
    blk_v       : in  std_logic;
    -- Output: aligned 64-bit frame data (COMBINATIONAL, not registered)
    aligned_d   : out std_logic_vector(63 downto 0);
    aligned_v   : out std_logic;
    -- SOF/EOF (registered, active 1 clk after SOF/EOF block)
    sof_pulse   : out std_logic;
    sof_type    : out std_logic_vector(1 downto 0);
    eof_pulse   : out std_logic;
    frame_active: out std_logic
);
end eth_hdr_realign;

architecture rtl of eth_hdr_realign is

    type state_t is (IDLE_S, SOF1_DATA_S, SOF2_PRE_S, SOF2_DATA_S);
    signal state : state_t := IDLE_S;

    signal blk_d_prev_upper : std_logic_vector(31 downto 0) := (others => '0');
    signal is_ctrl          : std_logic;
    signal block_type       : std_logic_vector(7 downto 0);
    signal detect_sof1      : std_logic;
    signal detect_sof2      : std_logic;
    signal detect_sof3      : std_logic;
    signal detect_eof       : std_logic;

begin

    -- Combinational SOF/EOF detection
    is_ctrl    <= '1' when blk_d(1 downto 0) = SYNC_CTRL else '0';
    block_type <= blk_d(9 downto 2);

    detect_sof1 <= '1' when blk_v = '1' and is_ctrl = '1' and block_type = BT_SOF1 else '0';
    detect_sof2 <= '1' when blk_v = '1' and is_ctrl = '1' and block_type = BT_SOF2 else '0';
    detect_sof3 <= '1' when blk_v = '1' and is_ctrl = '1' and block_type = BT_SOF3 else '0';
    detect_eof  <= '1' when blk_v = '1' and is_ctrl = '1' and is_eof_type(block_type) else '0';

    --------------------------------------------------------------------------
    -- COMBINATIONAL aligned output (no register — like eth_64b66b pattern)
    -- SOF1 path: blk_d(65:2) direct passthrough (just bit selection = wire)
    -- SOF2/3 path: barrel shift = concatenation (also just wire)
    --------------------------------------------------------------------------
    aligned_d <= blk_d(65 downto 2) when (state = SOF1_DATA_S)
                 else blk_d(33 downto 2) & blk_d_prev_upper;

    aligned_v <= blk_v and not is_ctrl
                 when (state = SOF1_DATA_S or state = SOF2_DATA_S)
                 else '0';

    --------------------------------------------------------------------------
    -- Registered: state machine, prev_upper capture, sof/eof pulses
    --------------------------------------------------------------------------
    main_p : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state        <= IDLE_S;
                sof_pulse    <= '0';
                eof_pulse    <= '0';
                frame_active <= '0';
                sof_type     <= "00";
                blk_d_prev_upper <= (others => '0');
            else
                sof_pulse <= '0';
                eof_pulse <= '0';

                -- Always capture upper 32 bits for barrel shift
                if blk_v = '1' then
                    blk_d_prev_upper <= blk_d(65 downto 34);
                end if;

                case state is

                when IDLE_S =>
                    frame_active <= '0';
                    if detect_sof1 = '1' then
                        state        <= SOF1_DATA_S;
                        sof_pulse    <= '1';
                        sof_type     <= SOF_TYPE_1;
                        frame_active <= '1';
                    elsif detect_sof2 = '1' or detect_sof3 = '1' then
                        state        <= SOF2_PRE_S;
                        sof_pulse    <= '1';
                        sof_type     <= SOF_TYPE_2 when detect_sof2 = '1' else SOF_TYPE_3;
                        frame_active <= '1';
                    end if;

                when SOF1_DATA_S =>
                    if blk_v = '1' then
                        if detect_eof = '1' then
                            eof_pulse <= '1';
                            state <= IDLE_S;
                        elsif detect_sof1 = '1' then
                            -- Back-to-back: new SOF1 replaces current frame
                            sof_pulse <= '1';
                            sof_type  <= SOF_TYPE_1;
                            eof_pulse <= '1';
                        elsif detect_sof2 = '1' or detect_sof3 = '1' then
                            state     <= SOF2_PRE_S;
                            sof_pulse <= '1';
                            sof_type  <= SOF_TYPE_2 when detect_sof2 = '1' else SOF_TYPE_3;
                            eof_pulse <= '1';
                        end if;
                    end if;

                when SOF2_PRE_S =>
                    -- Preamble continuation block. prev_upper captures DMAC[0:3].
                    -- Wait one more block for barrel shift.
                    if blk_v = '1' then
                        state <= SOF2_DATA_S;
                    end if;

                when SOF2_DATA_S =>
                    if blk_v = '1' then
                        if detect_eof = '1' then
                            eof_pulse <= '1';
                            state <= IDLE_S;
                        elsif detect_sof1 = '1' then
                            state     <= SOF1_DATA_S;
                            sof_pulse <= '1';
                            sof_type  <= SOF_TYPE_1;
                            eof_pulse <= '1';
                        elsif detect_sof2 = '1' or detect_sof3 = '1' then
                            state     <= SOF2_PRE_S;
                            sof_pulse <= '1';
                            sof_type  <= SOF_TYPE_2 when detect_sof2 = '1' else SOF_TYPE_3;
                            eof_pulse <= '1';
                        end if;
                    end if;

                end case;
            end if;
        end if;
    end process main_p;

end rtl;
