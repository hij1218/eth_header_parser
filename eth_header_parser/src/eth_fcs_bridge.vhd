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
--    Latency: 1 clock (registered outputs).
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.eth_hdr_parser_pkg.all;

entity eth_fcs_bridge is
port (
    clk     : in  std_logic;
    rst     : in  std_logic;
    -- Input: descrambled 66-bit blocks
    blk_d   : in  std_logic_vector(65 downto 0);
    blk_v   : in  std_logic;
    -- Output: din/din_v for eth_fcs
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

begin

    is_ctrl    <= '1' when blk_d(1 downto 0) = SYNC_CTRL else '0';
    block_type <= blk_d(9 downto 2);
    dec_data   <= blk_d(65 downto 2);

    main_p : process(clk)
        variable eof_bytes : integer range 0 to 7;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= IDLE_S;
                fcs_din   <= (others => '0');
                fcs_din_v <= (others => '0');
                fcs_clk_en <= '0';
            else
                fcs_din   <= (others => '0');
                fcs_din_v <= (others => '0');
                fcs_clk_en <= blk_v;

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
                            fcs_din   <= dec_data;
                            fcs_din_v <= "11111111";
                            state     <= DATA_S;
                        else
                            state <= IDLE_S;  -- unexpected ctrl
                        end if;

                    when SOF2_PRE1_S =>
                        -- First DATA block after SOF2/3: lower 4 = preamble, upper 4 = frame data
                        if is_ctrl = '0' then
                            fcs_din   <= dec_data;
                            fcs_din_v <= "11110000";  -- upper 4 bytes valid
                            state     <= SOF2_PRE2_S;
                        else
                            state <= IDLE_S;
                        end if;

                    when SOF2_PRE2_S =>
                        -- Second DATA block after SOF2/3: full 8 bytes
                        if is_ctrl = '0' then
                            fcs_din   <= dec_data;
                            fcs_din_v <= "11111111";
                            state     <= DATA_S;
                        elsif is_ctrl = '1' and is_eof_type(block_type) then
                            -- Very short frame: EOF right after first data word
                            eof_bytes := eof_data_bytes(block_type);
                            fcs_din <= dec_data;
                            case eof_bytes is
                                when 0 => fcs_din_v <= "00000000";
                                when 1 => fcs_din(7 downto 0) <= dec_data(63 downto 56);
                                          fcs_din_v <= "00000001";
                                when 2 => fcs_din(15 downto 0) <= dec_data(63 downto 48);
                                          fcs_din_v <= "00000011";
                                when 3 => fcs_din(23 downto 0) <= dec_data(63 downto 40);
                                          fcs_din_v <= "00000111";
                                when 4 => fcs_din(31 downto 0) <= dec_data(63 downto 32);
                                          fcs_din_v <= "00001111";
                                when 5 => fcs_din(39 downto 0) <= dec_data(63 downto 24);
                                          fcs_din_v <= "00011111";
                                when 6 => fcs_din(47 downto 0) <= dec_data(63 downto 16);
                                          fcs_din_v <= "00111111";
                                when 7 => fcs_din(55 downto 0) <= dec_data(63 downto 8);
                                          fcs_din_v <= "01111111";
                            end case;
                            state <= IDLE_S;
                        else
                            state <= IDLE_S;
                        end if;

                    when DATA_S =>
                        if is_ctrl = '0' then
                            -- Full data word
                            fcs_din   <= dec_data;
                            fcs_din_v <= "11111111";
                        elsif is_ctrl = '1' and is_eof_type(block_type) then
                            -- EOF: extract trailing data bytes
                            -- In EOF blocks, data bytes are at high end of dec_data
                            -- and map to low byte positions (matching XGMII/64b66b decoder)
                            eof_bytes := eof_data_bytes(block_type);
                            fcs_din <= dec_data;
                            case eof_bytes is
                                when 0 => fcs_din_v <= "00000000";
                                when 1 => fcs_din(7 downto 0) <= dec_data(63 downto 56);
                                          fcs_din_v <= "00000001";
                                when 2 => fcs_din(15 downto 0) <= dec_data(63 downto 48);
                                          fcs_din_v <= "00000011";
                                when 3 => fcs_din(23 downto 0) <= dec_data(63 downto 40);
                                          fcs_din_v <= "00000111";
                                when 4 => fcs_din(31 downto 0) <= dec_data(63 downto 32);
                                          fcs_din_v <= "00001111";
                                when 5 => fcs_din(39 downto 0) <= dec_data(63 downto 24);
                                          fcs_din_v <= "00011111";
                                when 6 => fcs_din(47 downto 0) <= dec_data(63 downto 16);
                                          fcs_din_v <= "00111111";
                                when 7 => fcs_din(55 downto 0) <= dec_data(63 downto 8);
                                          fcs_din_v <= "01111111";
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

end rtl;
