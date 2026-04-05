------------------------------------------------------------------------
--  Entity:  eth_hdr_extract
--  Description:
--    Header field extraction FSM. Receives aligned 64-bit words from
--    eth_hdr_realign (word 0 = DMAC[0:5]+SMAC[0:1], word 1 = SMAC+EtherType, etc.)
--    Outputs per-field valid signals for minimum latency.
--    Supports 0/1/2 VLAN tags, IPv4, IPv6, TCP/UDP port extraction.
--
--    Byte order within 64-bit word (from wire):
--      word[7:0]   = first byte on wire (e.g., DMAC[0])
--      word[63:56] = 8th byte on wire (e.g., SMAC[1])
--    Output fields are in network byte order (big-endian).
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.eth_hdr_parser_pkg.all;

entity eth_hdr_extract is
port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- From realign
    aligned_d     : in  std_logic_vector(63 downto 0);
    aligned_v     : in  std_logic;
    sof_pulse     : in  std_logic;
    eof_pulse     : in  std_logic;
    -- Layer 2 — MAC
    mac_dst_v     : out std_logic;
    mac_dst       : out std_logic_vector(47 downto 0);
    mac_src_v     : out std_logic;
    mac_src       : out std_logic_vector(47 downto 0);
    -- Layer 2 — EtherType & VLAN
    ethertype_v   : out std_logic;
    ethertype     : out std_logic_vector(15 downto 0);
    vlan_count    : out std_logic_vector(1 downto 0);
    vlan1_tci     : out std_logic_vector(15 downto 0);
    vlan2_tci     : out std_logic_vector(15 downto 0);
    -- Layer 3 — IPv4
    ipv4_v        : out std_logic;
    is_ipv4       : out std_logic;
    ipv4_ihl      : out std_logic_vector(3 downto 0);
    ipv4_dscp     : out std_logic_vector(5 downto 0);
    ipv4_totlen   : out std_logic_vector(15 downto 0);
    ipv4_proto    : out std_logic_vector(7 downto 0);
    ipv4_src      : out std_logic_vector(31 downto 0);
    ipv4_dst      : out std_logic_vector(31 downto 0);
    -- Layer 3 — IPv6
    ipv6_v        : out std_logic;
    is_ipv6       : out std_logic;
    ipv6_nhdr     : out std_logic_vector(7 downto 0);
    ipv6_plen     : out std_logic_vector(15 downto 0);
    ipv6_src      : out std_logic_vector(127 downto 0);
    ipv6_dst      : out std_logic_vector(127 downto 0);
    -- Layer 4
    l4_ports_v    : out std_logic;
    is_tcp        : out std_logic;
    is_udp        : out std_logic;
    l4_src_port   : out std_logic_vector(15 downto 0);
    l4_dst_port   : out std_logic_vector(15 downto 0);
    -- Status
    parse_error   : out std_logic
);
end eth_hdr_extract;

architecture rtl of eth_hdr_extract is

    -- Word counter from start of frame
    signal word_cnt : unsigned(4 downto 0) := (others => '0');

    -- Saved partial fields across words
    signal smac_lo       : std_logic_vector(15 downto 0);  -- SMAC[0:1] from word 0
    signal ipv4_dst_hi   : std_logic_vector(15 downto 0);  -- DstIP[0:1] from word 3
    signal ipv6_src_b01  : std_logic_vector(15 downto 0);  -- IPv6 SrcAddr[0:1] from word 2
    signal ipv6_src_mid  : std_logic_vector(63 downto 0);  -- IPv6 SrcAddr[2:9] from word 3
    signal ipv6_src_tail : std_logic_vector(47 downto 0);  -- IPv6 SrcAddr[10:15] from word 4
    signal ipv6_dst_b01  : std_logic_vector(15 downto 0);  -- IPv6 DstAddr[0:1] from word 4
    signal ipv6_dst_mid  : std_logic_vector(63 downto 0);  -- IPv6 DstAddr[2:9] from word 5
    signal ipv6_l4_sport : std_logic_vector(15 downto 0);  -- IPv6 L4 SrcPort from word 6
    signal l3_proto_reg  : std_logic_vector(7 downto 0);   -- protocol/next-header

    -- EtherType tracking for VLAN decode
    signal raw_etype    : std_logic_vector(15 downto 0);  -- First EtherType seen
    signal vlan_state   : unsigned(1 downto 0);           -- 0=no vlan, 1=1 tag, 2=2 tags
    signal is_ip4_reg   : std_logic;
    signal is_ip6_reg   : std_logic;

    -- IPv4 payload word offset (shifts by VLAN tags)
    -- word_cnt value when IPv4/IPv6 header byte 0 starts
    -- No VLAN:  IPv4[0:1] at word 1 [55:48]&[63:56], IPv4[2:9] at word 2
    -- 1 VLAN:   IPv4[0:1] shift +4 bytes = word 2 [23:16]&[31:24] partial, rest at word 2&3
    -- 2 VLAN:   IPv4[0:1] shift +8 bytes = word 2 [55:48]&[63:56], same as no-VLAN but +1 word
    -- We use combinational decode per word, similar to eth_txhold cdl1/2/3 pattern

    -- Helper: extract 16-bit field in network byte order from word at given byte offset
    -- byte_offset 0 means word[7:0]&word[15:8], etc.
    function extract16(w : std_logic_vector(63 downto 0); byte_off : integer) return std_logic_vector is
        variable lo : integer;
    begin
        lo := byte_off * 8;
        return w(lo+7 downto lo) & w(lo+15 downto lo+8);
    end function;

    -- Helper: extract 32-bit field in network byte order
    function extract32(w : std_logic_vector(63 downto 0); byte_off : integer) return std_logic_vector is
        variable lo : integer;
    begin
        lo := byte_off * 8;
        return w(lo+7 downto lo) & w(lo+15 downto lo+8) & w(lo+23 downto lo+16) & w(lo+31 downto lo+24);
    end function;

begin

    main_p : process(clk)
        variable etype_at_w1 : std_logic_vector(15 downto 0);
        variable etype_at_w2 : std_logic_vector(15 downto 0);
        variable etype_at_w3 : std_logic_vector(15 downto 0);
        variable word_idx    : integer range 0 to 31;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                word_cnt    <= (others => '0');
                mac_dst_v   <= '0';
                mac_src_v   <= '0';
                ethertype_v <= '0';
                ipv4_v      <= '0';
                ipv6_v      <= '0';
                l4_ports_v  <= '0';
                parse_error <= '0';
                is_ipv4     <= '0';
                is_ipv6     <= '0';
                is_tcp      <= '0';
                is_udp      <= '0';
                vlan_state  <= "00";
                is_ip4_reg  <= '0';
                is_ip6_reg  <= '0';
            else
                -- Clear per-cycle pulses
                mac_dst_v   <= '0';
                mac_src_v   <= '0';
                ethertype_v <= '0';
                ipv4_v      <= '0';
                ipv6_v      <= '0';
                l4_ports_v  <= '0';
                parse_error <= '0';

                if sof_pulse = '1' then
                    -- Reset state for new frame.
                    -- For SOF1, aligned_v may be active in this SAME clock
                    -- (combinational output from realign). Use word_idx = 0 below.
                    vlan_state <= "00";
                    is_ip4_reg <= '0';
                    is_ip6_reg <= '0';
                    is_ipv4    <= '0';
                    is_ipv6    <= '0';
                    is_tcp     <= '0';
                    is_udp     <= '0';
                    if aligned_v = '1' then
                        word_cnt <= to_unsigned(1, word_cnt'length);  -- Reset + count word 0
                    else
                        word_cnt <= (others => '0');  -- SOF2/3: aligned_v comes later
                    end if;
                elsif aligned_v = '1' then
                    word_cnt <= word_cnt + 1;
                end if;

                -- Determine word index: if sof_pulse concurrent with aligned_v,
                -- word_cnt is stale → force word_idx = 0
                if sof_pulse = '1' then
                    word_idx := 0;
                else
                    word_idx := to_integer(word_cnt);
                end if;

                if aligned_v = '1' then

                    case word_idx is

                    --------------------------------------------------------
                    -- WORD 0: DMAC[0:5] + SMAC[0:1]
                    --------------------------------------------------------
                    when 0 =>
                        -- DMAC: bytes 0-5 = word[47:0], network byte order
                        mac_dst   <= aligned_d(7 downto 0) & aligned_d(15 downto 8)
                                   & aligned_d(23 downto 16) & aligned_d(31 downto 24)
                                   & aligned_d(39 downto 32) & aligned_d(47 downto 40);
                        mac_dst_v <= '1';
                        -- Save SMAC[0:1] for next word
                        smac_lo   <= aligned_d(55 downto 48) & aligned_d(63 downto 56);

                    --------------------------------------------------------
                    -- WORD 1: SMAC[2:5] + EtherType/TPID + 2 payload bytes
                    --------------------------------------------------------
                    when 1 =>
                        -- SMAC: bytes 0-3 from this word + saved bytes from word 0
                        mac_src   <= smac_lo
                                   & aligned_d(7 downto 0) & aligned_d(15 downto 8)
                                   & aligned_d(23 downto 16) & aligned_d(31 downto 24);
                        mac_src_v <= '1';

                        -- EtherType at bytes 4-5 of this word
                        etype_at_w1 := extract16(aligned_d, 4);
                        raw_etype   <= etype_at_w1;

                        if etype_at_w1 = ETYPE_VLAN or etype_at_w1 = ETYPE_QINQ then
                            -- VLAN tag: TCI at bytes 6-7, real EtherType in next word
                            vlan1_tci  <= extract16(aligned_d, 6);
                            vlan_state <= "01";
                        else
                            -- No VLAN: this IS the real EtherType
                            ethertype   <= etype_at_w1;
                            ethertype_v <= '1';
                            vlan_count  <= "00";
                            vlan_state  <= "00";

                            -- Start L3 decode: first 2 bytes of L3 header at bytes 6-7
                            if etype_at_w1 = ETYPE_IPV4 then
                                is_ip4_reg <= '1';
                                is_ipv4    <= '1';
                                -- IPv4[0]: Version(4b)+IHL(4b) at byte 6
                                ipv4_ihl  <= aligned_d(51 downto 48);  -- low nibble of byte 6
                                ipv4_dscp <= aligned_d(55 downto 50);  -- high 6 bits of byte 7...
                                -- Actually: byte6 = word[55:48], byte7 = word[63:56]
                                -- IPv4 byte 0 = Version(hi nibble) + IHL(lo nibble)
                                -- ipv4_ihl = byte6[3:0] = word[51:48]
                                -- IPv4 byte 1 = DSCP(6 bits) + ECN(2 bits)
                                -- ipv4_dscp = byte7[7:2] = word[63:58]
                                ipv4_dscp <= aligned_d(63 downto 58);
                            elsif etype_at_w1 = ETYPE_IPV6 then
                                is_ip6_reg <= '1';
                                is_ipv6    <= '1';
                            end if;
                        end if;

                    --------------------------------------------------------
                    -- WORD 2: depends on VLAN state
                    --------------------------------------------------------
                    when 2 =>
                        if vlan_state = "01" then
                            -- Had 1 VLAN tag. Bytes 0-1 = inner EtherType or 2nd VLAN TPID
                            etype_at_w2 := extract16(aligned_d, 0);
                            if etype_at_w2 = ETYPE_VLAN then
                                -- Double VLAN (QinQ): bytes 0-1 = 2nd TPID, bytes 2-3 = 2nd TCI
                                vlan2_tci  <= extract16(aligned_d, 2);
                                vlan_state <= "10";
                            else
                                -- Single VLAN done: bytes 0-1 = real EtherType
                                ethertype   <= etype_at_w2;
                                ethertype_v <= '1';
                                vlan_count  <= "01";
                                if etype_at_w2 = ETYPE_IPV4 then
                                    is_ip4_reg  <= '1';
                                    is_ipv4     <= '1';
                                    ipv4_ihl    <= aligned_d(19 downto 16);
                                    ipv4_dscp   <= aligned_d(31 downto 26);
                                    ipv4_totlen <= extract16(aligned_d, 4);  -- bytes 4-5 = IPv4[2:3]
                                elsif etype_at_w2 = ETYPE_IPV6 then
                                    is_ip6_reg <= '1';
                                    is_ipv6    <= '1';
                                end if;
                            end if;
                        elsif vlan_state = "00" then
                            -- No VLAN: this word has L3 header continuation
                            if is_ip4_reg = '1' then
                                -- IPv4[2:9]: TotalLen/ID/Flags/TTL/Protocol
                                ipv4_totlen <= extract16(aligned_d, 0);
                                ipv4_proto  <= aligned_d(63 downto 56);  -- byte 7 = Protocol
                                l3_proto_reg <= aligned_d(63 downto 56);
                            elsif is_ip6_reg = '1' then
                                -- IPv6[2:9] in this word:
                                -- byte0-1=TC/FlowLabel, byte2-3=PayloadLen,
                                -- byte4=NextHeader, byte5=HopLimit,
                                -- byte6-7=SrcAddr[0:1]
                                ipv6_plen    <= extract16(aligned_d, 2);  -- bytes 2-3
                                ipv6_nhdr    <= aligned_d(39 downto 32);  -- byte 4
                                l3_proto_reg <= aligned_d(39 downto 32);
                                ipv6_src_b01 <= extract16(aligned_d, 6);  -- bytes 6-7 = SrcAddr[0:1]
                            end if;
                        end if;

                    --------------------------------------------------------
                    -- WORD 3
                    --------------------------------------------------------
                    when 3 =>
                        if vlan_state = "10" then
                            -- 2 VLAN tags: bytes 0-1 = real EtherType
                            etype_at_w3 := extract16(aligned_d, 0);
                            ethertype   <= etype_at_w3;
                            ethertype_v <= '1';
                            vlan_count  <= "10";
                            if etype_at_w3 = ETYPE_IPV4 then
                                is_ip4_reg  <= '1';
                                is_ipv4     <= '1';
                                ipv4_ihl    <= aligned_d(19 downto 16);
                                ipv4_dscp   <= aligned_d(31 downto 26);
                                ipv4_totlen <= extract16(aligned_d, 4);  -- bytes 4-5 = IPv4[2:3]
                            elsif etype_at_w3 = ETYPE_IPV6 then
                                is_ip6_reg <= '1';
                                is_ipv6    <= '1';
                            end if;
                        elsif vlan_state = "01" then
                            -- 1 VLAN: IPv4[6:13] or IPv6 continuation
                            if is_ip4_reg = '1' then
                                -- byte 3 = IPv4[9] = Protocol
                                ipv4_proto   <= aligned_d(31 downto 24);
                                l3_proto_reg <= aligned_d(31 downto 24);
                            elsif is_ip6_reg = '1' then
                                ipv6_plen    <= extract16(aligned_d, 2);
                                ipv6_nhdr    <= aligned_d(39 downto 32);
                                l3_proto_reg <= aligned_d(39 downto 32);
                            end if;
                        elsif vlan_state = "00" then
                            -- No VLAN: IPv4 word 3 or IPv6 word 3
                            if is_ip4_reg = '1' then
                                -- IPv4[10:17]: Checksum + SrcIP + DstIP[0:1]
                                ipv4_src    <= extract32(aligned_d, 2);  -- bytes 2-5
                                ipv4_dst_hi <= extract16(aligned_d, 6);  -- bytes 6-7 = DstIP[0:1]
                            elsif is_ip6_reg = '1' then
                                -- IPv6[10:17]: SrcAddr[2:9] (8 bytes, full word)
                                ipv6_src_mid <= aligned_d(7 downto 0) & aligned_d(15 downto 8)
                                              & aligned_d(23 downto 16) & aligned_d(31 downto 24)
                                              & aligned_d(39 downto 32) & aligned_d(47 downto 40)
                                              & aligned_d(55 downto 48) & aligned_d(63 downto 56);
                            end if;
                        end if;

                    --------------------------------------------------------
                    -- WORD 4
                    --------------------------------------------------------
                    when 4 =>
                        if vlan_state = "00" and is_ip4_reg = '1' then
                            -- IPv4[18:25]: DstIP[2:3] + L4 SrcPort + DstPort + 2 bytes
                            ipv4_dst <= ipv4_dst_hi & extract16(aligned_d, 0);
                            ipv4_v   <= '1';
                            -- L4 ports at bytes 2-5
                            l4_src_port <= extract16(aligned_d, 2);
                            l4_dst_port <= extract16(aligned_d, 4);
                            l4_ports_v  <= '1';
                            if l3_proto_reg = IP_PROTO_TCP then
                                is_tcp <= '1';
                            elsif l3_proto_reg = IP_PROTO_UDP then
                                is_udp <= '1';
                            end if;

                        elsif vlan_state = "00" and is_ip6_reg = '1' then
                            -- IPv6[18:25]: SrcAddr[10:15](bytes 0-5) + DstAddr[0:1](bytes 6-7)
                            ipv6_src_tail <= aligned_d(7 downto 0) & aligned_d(15 downto 8)
                                           & aligned_d(23 downto 16) & aligned_d(31 downto 24)
                                           & aligned_d(39 downto 32) & aligned_d(47 downto 40);
                            ipv6_dst_b01  <= extract16(aligned_d, 6);

                        elsif vlan_state = "01" and is_ip4_reg = '1' then
                            -- 1 VLAN + IPv4: same as no-VLAN word 3
                            ipv4_src    <= extract32(aligned_d, 2);
                            ipv4_dst_hi <= extract16(aligned_d, 6);

                        elsif vlan_state = "10" then
                            -- 2 VLAN: IPv4[6:13] or IPv6 continuation
                            if is_ip4_reg = '1' then
                                -- byte 3 = IPv4[9] = Protocol
                                ipv4_proto   <= aligned_d(31 downto 24);
                                l3_proto_reg <= aligned_d(31 downto 24);
                            elsif is_ip6_reg = '1' then
                                ipv6_plen    <= extract16(aligned_d, 2);
                                ipv6_nhdr    <= aligned_d(39 downto 32);
                                l3_proto_reg <= aligned_d(39 downto 32);
                            end if;
                        end if;

                    --------------------------------------------------------
                    -- WORD 5
                    --------------------------------------------------------
                    when 5 =>
                        if vlan_state = "01" and is_ip4_reg = '1' then
                            -- 1 VLAN + IPv4: same as no-VLAN word 4
                            ipv4_dst <= ipv4_dst_hi & extract16(aligned_d, 0);
                            ipv4_v   <= '1';
                            l4_src_port <= extract16(aligned_d, 2);
                            l4_dst_port <= extract16(aligned_d, 4);
                            l4_ports_v  <= '1';
                            if l3_proto_reg = IP_PROTO_TCP then
                                is_tcp <= '1';
                            elsif l3_proto_reg = IP_PROTO_UDP then
                                is_udp <= '1';
                            end if;

                        elsif vlan_state = "10" and is_ip4_reg = '1' then
                            -- 2 VLAN + IPv4: SrcIP + DstIP partial
                            ipv4_src    <= extract32(aligned_d, 2);
                            ipv4_dst_hi <= extract16(aligned_d, 6);

                        elsif vlan_state = "00" and is_ip6_reg = '1' then
                            -- No VLAN + IPv6: DstAddr[2:9] (8 bytes, full word)
                            ipv6_dst_mid <= aligned_d(7 downto 0) & aligned_d(15 downto 8)
                                          & aligned_d(23 downto 16) & aligned_d(31 downto 24)
                                          & aligned_d(39 downto 32) & aligned_d(47 downto 40)
                                          & aligned_d(55 downto 48) & aligned_d(63 downto 56);
                        end if;

                    --------------------------------------------------------
                    -- WORD 6
                    --------------------------------------------------------
                    when 6 =>
                        if vlan_state = "10" and is_ip4_reg = '1' then
                            -- 2 VLAN + IPv4: DstIP + L4 ports
                            ipv4_dst <= ipv4_dst_hi & extract16(aligned_d, 0);
                            ipv4_v   <= '1';
                            l4_src_port <= extract16(aligned_d, 2);
                            l4_dst_port <= extract16(aligned_d, 4);
                            l4_ports_v  <= '1';
                            if l3_proto_reg = IP_PROTO_TCP then
                                is_tcp <= '1';
                            elsif l3_proto_reg = IP_PROTO_UDP then
                                is_udp <= '1';
                            end if;

                        elsif vlan_state = "00" and is_ip6_reg = '1' then
                            -- No VLAN + IPv6 word 6:
                            -- bytes 0-5 = DstAddr[10:15], bytes 6-7 = L4 SrcPort
                            -- Assemble full ipv6_src: b01(16) + mid(64) + tail(48) = 128
                            ipv6_src <= ipv6_src_b01 & ipv6_src_mid & ipv6_src_tail;
                            -- Assemble full ipv6_dst: b01(16) + mid(64) + word6[0:5](48) = 128
                            ipv6_dst <= ipv6_dst_b01 & ipv6_dst_mid
                                      & aligned_d(7 downto 0) & aligned_d(15 downto 8)
                                      & aligned_d(23 downto 16) & aligned_d(31 downto 24)
                                      & aligned_d(39 downto 32) & aligned_d(47 downto 40);
                            ipv6_v <= '1';
                            -- Save L4 SrcPort at bytes 6-7 for next word
                            ipv6_l4_sport <= extract16(aligned_d, 6);

                        end if;

                    --------------------------------------------------------
                    -- WORD 7: IPv6 L4 ports (no VLAN)
                    --------------------------------------------------------
                    when 7 =>
                        if vlan_state = "00" and is_ip6_reg = '1' then
                            -- L4 SrcPort was at word 6 bytes 6-7 (saved in ipv6_l4_sport)
                            -- L4 DstPort at word 7 bytes 0-1
                            l4_src_port <= ipv6_l4_sport;
                            l4_dst_port <= extract16(aligned_d, 0);
                            l4_ports_v  <= '1';
                            if l3_proto_reg = IP_PROTO_TCP then
                                is_tcp <= '1';
                            elsif l3_proto_reg = IP_PROTO_UDP then
                                is_udp <= '1';
                            end if;
                        end if;

                    when others =>
                        null;  -- Frame payload, no more header parsing

                    end case;
                end if;

                -- EOF: check for runt frames
                if eof_pulse = '1' then
                    if word_cnt < 4 and is_ip4_reg = '1' then
                        parse_error <= '1';  -- Runt: EOF before IPv4 header complete
                    elsif word_cnt < 7 and is_ip6_reg = '1' then
                        parse_error <= '1';  -- Runt: EOF before IPv6 header complete
                    elsif word_cnt < 1 then
                        parse_error <= '1';  -- Runt: EOF before MAC addresses
                    end if;
                end if;
            end if;
        end if;
    end process main_p;

end rtl;
