------------------------------------------------------------------------
--  Entity:  eth_l2_check
--  Description:
--    Layer 2 validation: MAC address filtering and frame length check.
--    - Compares parsed DMAC against station MAC + broadcast accept
--    - Counts frame bytes from SOF to EOF
--    - Flags runt (<64) and jumbo (>max) frames
--    Outputs l2_good/l2_bad 1-clock pulses at end of frame.
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.eth_hdr_parser_pkg.all;

entity eth_l2_check is
generic (
    G_STATION_MAC    : std_logic_vector(47 downto 0) := x"000000000000";
    G_MAX_FRAME_SIZE : integer := 1518
);
port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- From realign
    aligned_v     : in  std_logic;
    sof_pulse     : in  std_logic;
    eof_pulse     : in  std_logic;
    sof_type      : in  std_logic_vector(1 downto 0);
    -- Raw block for EOF byte count decode
    blk_d         : in  std_logic_vector(65 downto 0);
    -- From extract
    mac_dst       : in  std_logic_vector(47 downto 0);
    mac_dst_v     : in  std_logic;
    -- Outputs
    l2_good       : out std_logic;
    l2_bad        : out std_logic;
    mac_match     : out std_logic;
    mac_bcast     : out std_logic;
    frame_len     : out std_logic_vector(15 downto 0);
    frame_runt    : out std_logic;
    frame_jumbo   : out std_logic
);
end eth_l2_check;

architecture rtl of eth_l2_check is

    signal word_cnt     : unsigned(13 downto 0) := (others => '0');
    signal sof_type_reg : std_logic_vector(1 downto 0) := "00";
    signal mac_match_i  : std_logic := '0';
    signal mac_bcast_i  : std_logic := '0';
    signal frame_len_i  : unsigned(15 downto 0);

begin

    main_p : process(clk)
        variable eof_bytes  : integer range 0 to 7;
        variable shift_adj  : integer range 0 to 4;
        variable flen       : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                word_cnt     <= (others => '0');
                sof_type_reg <= "00";
                mac_match_i  <= '0';
                mac_bcast_i  <= '0';
                l2_good      <= '0';
                l2_bad       <= '0';
                mac_match    <= '0';
                mac_bcast    <= '0';
                frame_len    <= (others => '0');
                frame_runt   <= '0';
                frame_jumbo  <= '0';
            else
                l2_good     <= '0';
                l2_bad      <= '0';
                frame_runt  <= '0';
                frame_jumbo <= '0';

                -- SOF: reset counters
                if sof_pulse = '1' then
                    sof_type_reg <= sof_type;
                    mac_match_i  <= '0';
                    mac_bcast_i  <= '0';
                    if aligned_v = '1' then
                        word_cnt <= to_unsigned(1, word_cnt'length);
                    else
                        word_cnt <= (others => '0');
                    end if;
                elsif aligned_v = '1' then
                    word_cnt <= word_cnt + 1;
                end if;

                -- MAC address check (fires when extract provides mac_dst)
                if mac_dst_v = '1' then
                    if mac_dst = G_STATION_MAC or mac_dst = MAC_BROADCAST then
                        mac_match_i <= '1';
                    end if;
                    if mac_dst = MAC_BROADCAST then
                        mac_bcast_i <= '1';
                    end if;
                end if;

                -- EOF: compute frame length and check
                if eof_pulse = '1' then
                    eof_bytes := eof_data_bytes(blk_d(9 downto 2));

                    -- SOF2/SOF3 barrel shift adds 4 trailing bytes not emitted on aligned_d
                    if sof_type_reg = SOF_TYPE_2 or sof_type_reg = SOF_TYPE_3 then
                        shift_adj := 4;
                    else
                        shift_adj := 0;
                    end if;

                    flen := resize(word_cnt * 8, 16) + to_unsigned(eof_bytes + shift_adj, 16);
                    frame_len_i <= flen;
                    frame_len   <= std_logic_vector(flen);

                    mac_match <= mac_match_i;
                    mac_bcast <= mac_bcast_i;

                    -- L2 verdict
                    if flen < MIN_FRAME_SIZE then
                        frame_runt <= '1';
                    end if;
                    if flen > G_MAX_FRAME_SIZE then
                        frame_jumbo <= '1';
                    end if;

                    if mac_match_i = '1'
                       and flen >= MIN_FRAME_SIZE
                       and flen <= G_MAX_FRAME_SIZE then
                        l2_good <= '1';
                    else
                        l2_bad <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process main_p;

end rtl;
