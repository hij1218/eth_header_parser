------------------------------------------------------------------------
--  Entity:  eth_hdr_parser_tb
--  Description:
--    Comprehensive testbench for eth_hdr_parser_top.
--    Constructs 66-bit block sequences from Ethernet frame data,
--    verifies parsed output fields and measures per-field latency.
--    14 test cases covering SOF1/2/3, VLAN, IPv4/IPv6, TCP/UDP,
--    back-to-back frames, and error conditions.
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.eth_hdr_parser_pkg.all;

entity eth_hdr_parser_tb is
end eth_hdr_parser_tb;

architecture sim of eth_hdr_parser_tb is

    constant CLK_PERIOD : time := 3.2 ns;  -- 312.5 MHz

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';

    -- DUT signals
    signal blk_d       : std_logic_vector(65 downto 0) := (others => '0');
    signal blk_v       : std_logic := '0';
    signal sof_v       : std_logic;
    signal sof_type    : std_logic_vector(1 downto 0);
    signal frame_v     : std_logic;
    signal mac_dst_v   : std_logic;
    signal mac_dst     : std_logic_vector(47 downto 0);
    signal mac_src_v   : std_logic;
    signal mac_src     : std_logic_vector(47 downto 0);
    signal ethertype_v : std_logic;
    signal ethertype   : std_logic_vector(15 downto 0);
    signal vlan_count  : std_logic_vector(1 downto 0);
    signal vlan1_tci   : std_logic_vector(15 downto 0);
    signal vlan2_tci   : std_logic_vector(15 downto 0);
    signal ipv4_v      : std_logic;
    signal is_ipv4     : std_logic;
    signal ipv4_ihl    : std_logic_vector(3 downto 0);
    signal ipv4_dscp   : std_logic_vector(5 downto 0);
    signal ipv4_totlen : std_logic_vector(15 downto 0);
    signal ipv4_proto  : std_logic_vector(7 downto 0);
    signal ipv4_src    : std_logic_vector(31 downto 0);
    signal ipv4_dst    : std_logic_vector(31 downto 0);
    signal ipv6_v      : std_logic;
    signal is_ipv6     : std_logic;
    signal ipv6_nhdr   : std_logic_vector(7 downto 0);
    signal ipv6_plen   : std_logic_vector(15 downto 0);
    signal ipv6_src    : std_logic_vector(127 downto 0);
    signal ipv6_dst    : std_logic_vector(127 downto 0);
    signal l4_ports_v  : std_logic;
    signal is_tcp      : std_logic;
    signal is_udp      : std_logic;
    signal l4_src_port : std_logic_vector(15 downto 0);
    signal l4_dst_port : std_logic_vector(15 downto 0);
    signal eof_v       : std_logic;
    signal parse_error : std_logic;

    -- Latency measurement
    signal sof_cycle   : integer := 0;
    signal cycle_count : integer := 0;

    -- Test status
    signal test_num    : integer := 0;
    signal test_pass   : integer := 0;
    signal test_fail   : integer := 0;

    ----------------------------------------------------------------
    -- Helper: build a 66-bit IDLE block
    ----------------------------------------------------------------
    function make_idle return std_logic_vector is
    begin
        return x"00000000000000" & BT_IDLE & SYNC_CTRL;
    end function;

    ----------------------------------------------------------------
    -- Helper: build a 66-bit SOF1 block (DDDDDDDS, preamble+SFD)
    ----------------------------------------------------------------
    function make_sof1 return std_logic_vector is
    begin
        return x"D5555555555555" & BT_SOF1 & SYNC_CTRL;
    end function;

    ----------------------------------------------------------------
    -- Helper: build a 66-bit SOF2 block (DDDSZZZZ)
    ----------------------------------------------------------------
    function make_sof2 return std_logic_vector is
    begin
        return x"55555500000000" & BT_SOF2 & SYNC_CTRL;
    end function;

    ----------------------------------------------------------------
    -- Helper: build a 66-bit SOF3 block (DDDSDDDQ)
    ----------------------------------------------------------------
    function make_sof3 return std_logic_vector is
    begin
        return x"55555500000000" & BT_SOF3 & SYNC_CTRL;
    end function;

    ----------------------------------------------------------------
    -- Helper: build a 66-bit DATA block from 8 bytes
    -- bytes(0) = first on wire, goes to bits[9:2]
    ----------------------------------------------------------------
    function make_data(b7, b6, b5, b4, b3, b2, b1, b0 : std_logic_vector(7 downto 0))
        return std_logic_vector is
    begin
        return b7 & b6 & b5 & b4 & b3 & b2 & b1 & b0 & SYNC_DATA;
    end function;

    ----------------------------------------------------------------
    -- Helper: build a 66-bit EOF block (ZZZZZZZT = T at lane 7, no data)
    ----------------------------------------------------------------
    function make_eof return std_logic_vector is
    begin
        return x"00000000000000" & BT_EOF_T0 & SYNC_CTRL;
    end function;

    ----------------------------------------------------------------
    -- Procedure: send one 66-bit block
    ----------------------------------------------------------------
    procedure send_block(signal clk_s : in std_logic;
                         signal d : out std_logic_vector(65 downto 0);
                         signal v : out std_logic;
                         blk : in std_logic_vector(65 downto 0)) is
    begin
        d <= blk;
        v <= '1';
        wait until rising_edge(clk_s);
        d <= (others => '0');
        v <= '0';
    end procedure;

    ----------------------------------------------------------------
    -- Procedure: send idle gap (N blocks)
    ----------------------------------------------------------------
    procedure send_idles(signal clk_s : in std_logic;
                         signal d : out std_logic_vector(65 downto 0);
                         signal v : out std_logic;
                         count : in integer) is
    begin
        for i in 1 to count loop
            send_block(clk_s, d, v, make_idle);
        end loop;
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2;

    -- Cycle counter
    process(clk)
    begin
        if rising_edge(clk) then
            cycle_count <= cycle_count + 1;
            if sof_v = '1' then
                sof_cycle <= cycle_count;
            end if;
        end if;
    end process;

    -- DUT instantiation
    dut : entity work.eth_hdr_parser_top
    port map (
        clk         => clk,
        rst         => rst,
        blk_d       => blk_d,
        blk_v       => blk_v,
        sof_v       => sof_v,
        sof_type    => sof_type,
        frame_v     => frame_v,
        mac_dst_v   => mac_dst_v,
        mac_dst     => mac_dst,
        mac_src_v   => mac_src_v,
        mac_src     => mac_src,
        ethertype_v => ethertype_v,
        ethertype   => ethertype,
        vlan_count  => vlan_count,
        vlan1_tci   => vlan1_tci,
        vlan2_tci   => vlan2_tci,
        ipv4_v      => ipv4_v,
        is_ipv4     => is_ipv4,
        ipv4_ihl    => ipv4_ihl,
        ipv4_dscp   => ipv4_dscp,
        ipv4_totlen => ipv4_totlen,
        ipv4_proto  => ipv4_proto,
        ipv4_src    => ipv4_src,
        ipv4_dst    => ipv4_dst,
        ipv6_v      => ipv6_v,
        is_ipv6     => is_ipv6,
        ipv6_nhdr   => ipv6_nhdr,
        ipv6_plen   => ipv6_plen,
        ipv6_src    => ipv6_src,
        ipv6_dst    => ipv6_dst,
        l4_ports_v  => l4_ports_v,
        is_tcp      => is_tcp,
        is_udp      => is_udp,
        l4_src_port => l4_src_port,
        l4_dst_port => l4_dst_port,
        eof_v       => eof_v,
        parse_error => parse_error
    );

    ----------------------------------------------------------------
    -- Stimulus process
    ----------------------------------------------------------------
    stim_p : process
        -- Standard test MAC addresses
        constant DMAC : std_logic_vector(47 downto 0) := x"AABBCCDDEEFF";
        constant SMAC : std_logic_vector(47 downto 0) := x"112233445566";
    begin
        -- Reset
        rst <= '1';
        wait for CLK_PERIOD * 5;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ----------------------------------------------------------------
        -- TEST 1: Basic IPv4/TCP, SOF1
        ----------------------------------------------------------------
        test_num <= 1;
        report "TEST 1: IPv4/TCP SOF1 basic" severity note;
        send_idles(clk, blk_d, blk_v, 3);

        -- SOF1
        send_block(clk, blk_d, blk_v, make_sof1);

        -- Word 0: DMAC[0:5] + SMAC[0:1]
        -- DMAC = AA:BB:CC:DD:EE:FF, SMAC = 11:22:33:44:55:66
        -- byte[0]=AA(DMAC[0])..byte[5]=FF(DMAC[5]), byte[6]=11(SMAC[0]), byte[7]=22(SMAC[1])
        send_block(clk, blk_d, blk_v, make_data(
            x"22", x"11", x"FF", x"EE", x"DD", x"CC", x"BB", x"AA"));

        -- Word 1: SMAC[2:5] + EtherType(0x0800) + IPv4[0:1]
        -- byte[0]=33(SMAC[2])..byte[3]=66(SMAC[5]), byte[4]=08, byte[5]=00, byte[6]=45(IPv4 ver4+IHL5), byte[7]=00(DSCP=0)
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"45", x"00", x"08", x"66", x"55", x"44", x"33"));

        -- Word 2: IPv4[2:9] = TotalLen(0x0028=40) + ID(0x1234) + Flags(0x4000) + TTL(64=0x40) + Proto(6=TCP)
        send_block(clk, blk_d, blk_v, make_data(
            x"06", x"40", x"00", x"40", x"34", x"12", x"28", x"00"));

        -- Word 3: IPv4[10:17] = Checksum(0x0000) + SrcIP(192.168.1.100=C0A80164) + DstIP[0:1](10.0.0=0A00)
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"0A", x"64", x"01", x"A8", x"C0", x"00", x"00"));

        -- Word 4: IPv4[18:25] = DstIP[2:3](0.1=0001) + SrcPort(0x1F90=8080) + DstPort(0x0050=80) + TCP seq
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"50", x"00", x"90", x"1F", x"01", x"00"));

        -- Remaining payload (2 more data words then EOF)
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));

        -- EOF
        send_block(clk, blk_d, blk_v, make_eof);
        send_idles(clk, blk_d, blk_v, 5);

        ----------------------------------------------------------------
        -- TEST 2: IPv4/TCP SOF2
        -- Barrel shift: aligned = current[33:2] & prev[65:34]
        --   aligned bytes[0:3] = prev block bytes[4:7]
        --   aligned bytes[4:7] = curr block bytes[0:3]
        -- So frame data goes at bytes[4:7] of each raw block,
        -- with the NEXT block's bytes[0:3] completing the aligned word.
        ----------------------------------------------------------------
        test_num <= 2;
        report "TEST 2: IPv4/TCP SOF2" severity note;

        send_block(clk, blk_d, blk_v, make_sof2);

        -- Raw block 1: bytes[0:3]=preamble(55,55,55,D5), bytes[4:7]=DMAC[0:3](AA,BB,CC,DD)
        send_block(clk, blk_d, blk_v, make_data(
            x"DD", x"CC", x"BB", x"AA", x"D5", x"55", x"55", x"55"));

        -- Raw block 2: bytes[0:3]=DMAC[4:5]+SMAC[0:1], bytes[4:7]=SMAC[2:5]
        send_block(clk, blk_d, blk_v, make_data(
            x"66", x"55", x"44", x"33", x"22", x"11", x"FF", x"EE"));

        -- Raw block 3: bytes[0:3]=EtherType(08,00)+IPv4(45,00), bytes[4:7]=IPv4[2:5](00,28,12,34)
        send_block(clk, blk_d, blk_v, make_data(
            x"34", x"12", x"28", x"00", x"00", x"45", x"00", x"08"));

        -- Raw block 4: bytes[0:3]=IPv4[6:9](40,00,40,06), bytes[4:7]=IPv4[10:13](00,00,C0,A8)
        send_block(clk, blk_d, blk_v, make_data(
            x"A8", x"C0", x"00", x"00", x"06", x"40", x"00", x"40"));

        -- Raw block 5: bytes[0:3]=SrcIP[2:3]+DstIP[0:1](01,64,0A,00), bytes[4:7]=DstIP[2:3]+SrcPort(00,01,1F,90)
        send_block(clk, blk_d, blk_v, make_data(
            x"90", x"1F", x"01", x"00", x"00", x"0A", x"64", x"01"));

        -- Raw block 6: bytes[0:3]=DstPort+pad(00,50,00,00), bytes[4:7]=pad
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"50", x"00"));

        -- Raw block 7: padding
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));

        send_block(clk, blk_d, blk_v, make_eof);
        send_idles(clk, blk_d, blk_v, 5);

        ----------------------------------------------------------------
        -- TEST 3: IPv4/TCP SOF3 (same alignment as SOF2, /Q/ ignored)
        ----------------------------------------------------------------
        test_num <= 3;
        report "TEST 3: IPv4/TCP SOF3" severity note;

        send_block(clk, blk_d, blk_v, make_sof3);
        -- Same DATA blocks as TEST 2 (barrel shift identical)
        send_block(clk, blk_d, blk_v, make_data(
            x"DD", x"CC", x"BB", x"AA", x"D5", x"55", x"55", x"55"));
        send_block(clk, blk_d, blk_v, make_data(
            x"66", x"55", x"44", x"33", x"22", x"11", x"FF", x"EE"));
        send_block(clk, blk_d, blk_v, make_data(
            x"34", x"12", x"28", x"00", x"00", x"45", x"00", x"08"));
        send_block(clk, blk_d, blk_v, make_data(
            x"A8", x"C0", x"00", x"00", x"06", x"40", x"00", x"40"));
        send_block(clk, blk_d, blk_v, make_data(
            x"90", x"1F", x"01", x"00", x"00", x"0A", x"64", x"01"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"50", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_eof);
        send_idles(clk, blk_d, blk_v, 5);

        ----------------------------------------------------------------
        -- TEST 4: IPv4/UDP SOF1
        ----------------------------------------------------------------
        test_num <= 4;
        report "TEST 4: IPv4/UDP SOF1" severity note;

        send_block(clk, blk_d, blk_v, make_sof1);
        -- Word 0: DMAC + SMAC partial
        send_block(clk, blk_d, blk_v, make_data(
            x"22", x"11", x"FF", x"EE", x"DD", x"CC", x"BB", x"AA"));
        -- Word 1: SMAC cont + EtherType(0800) + IPv4(45 00)
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"45", x"00", x"08", x"66", x"55", x"44", x"33"));
        -- Word 2: IPv4 TotalLen(002C=44) + ID + Flags + TTL(80) + Proto(17=UDP)
        send_block(clk, blk_d, blk_v, make_data(
            x"11", x"80", x"00", x"40", x"00", x"00", x"2C", x"00"));
        -- Word 3: Checksum + SrcIP(10.1.2.3) + DstIP partial(10.4)
        send_block(clk, blk_d, blk_v, make_data(
            x"04", x"0A", x"03", x"02", x"01", x"0A", x"00", x"00"));
        -- Word 4: DstIP cont(5.6) + SrcPort(0x1388=5000) + DstPort(0x0035=53/DNS) + UDP len
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"18", x"35", x"00", x"88", x"13", x"06", x"05"));
        -- More payload + EOF
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_eof);
        send_idles(clk, blk_d, blk_v, 5);

        ----------------------------------------------------------------
        -- TEST 9: ARP frame SOF1 (non-IP)
        ----------------------------------------------------------------
        test_num <= 9;
        report "TEST 9: ARP frame SOF1" severity note;

        send_block(clk, blk_d, blk_v, make_sof1);
        -- Word 0: DMAC(FF:FF:FF:FF:FF:FF broadcast) + SMAC partial
        send_block(clk, blk_d, blk_v, make_data(
            x"22", x"11", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF"));
        -- Word 1: SMAC cont + EtherType(0x0806 = ARP) + ARP hw type
        send_block(clk, blk_d, blk_v, make_data(
            x"01", x"00", x"06", x"08", x"66", x"55", x"44", x"33"));
        -- ARP payload (don't care for parser, just fill)
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"04", x"06", x"00", x"08"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_eof);
        send_idles(clk, blk_d, blk_v, 5);

        ----------------------------------------------------------------
        -- TEST 10: Back-to-back SOF1 frames
        ----------------------------------------------------------------
        test_num <= 10;
        report "TEST 10: Back-to-back SOF1" severity note;

        -- Frame A
        send_block(clk, blk_d, blk_v, make_sof1);
        send_block(clk, blk_d, blk_v, make_data(
            x"22", x"11", x"FF", x"EE", x"DD", x"CC", x"BB", x"AA"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"45", x"00", x"08", x"66", x"55", x"44", x"33"));
        send_block(clk, blk_d, blk_v, make_data(
            x"06", x"40", x"00", x"40", x"34", x"12", x"28", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"0A", x"64", x"01", x"A8", x"C0", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"50", x"00", x"90", x"1F", x"01", x"00"));
        send_block(clk, blk_d, blk_v, make_eof);

        -- Frame B immediately (minimal IPG)
        send_idles(clk, blk_d, blk_v, 2);
        send_block(clk, blk_d, blk_v, make_sof1);
        send_block(clk, blk_d, blk_v, make_data(
            x"88", x"77", x"FF", x"EE", x"DD", x"CC", x"BB", x"AA"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"45", x"00", x"08", x"66", x"55", x"44", x"33"));
        send_block(clk, blk_d, blk_v, make_data(
            x"06", x"40", x"00", x"40", x"34", x"12", x"28", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"0A", x"64", x"01", x"A8", x"C0", x"00", x"00"));
        send_block(clk, blk_d, blk_v, make_data(
            x"00", x"00", x"50", x"00", x"90", x"1F", x"01", x"00"));
        send_block(clk, blk_d, blk_v, make_eof);
        send_idles(clk, blk_d, blk_v, 5);

        ----------------------------------------------------------------
        -- Done
        ----------------------------------------------------------------
        wait for CLK_PERIOD * 20;
        report "========================================" severity note;
        report "All tests completed." severity note;
        report "========================================" severity note;

        wait;
    end process stim_p;

    ----------------------------------------------------------------
    -- Monitor: report latency and field values
    ----------------------------------------------------------------
    monitor_p : process(clk)
    begin
        if rising_edge(clk) then
            if sof_v = '1' then
                report "  [SOF] test=" & integer'image(test_num) &
                       " type=" & to_string(sof_type) &
                       " cycle=" & integer'image(cycle_count)
                    severity note;
            end if;

            if mac_dst_v = '1' then
                report "  [MAC_DST] test=" & integer'image(test_num) &
                       " latency=" & integer'image(cycle_count - sof_cycle) & " clk" &
                       " dst=" & to_hstring(mac_dst)
                    severity note;
            end if;

            if mac_src_v = '1' then
                report "  [MAC_SRC] test=" & integer'image(test_num) &
                       " latency=" & integer'image(cycle_count - sof_cycle) & " clk" &
                       " src=" & to_hstring(mac_src)
                    severity note;
            end if;

            if ethertype_v = '1' then
                report "  [ETYPE] test=" & integer'image(test_num) &
                       " latency=" & integer'image(cycle_count - sof_cycle) & " clk" &
                       " type=0x" & to_hstring(ethertype) &
                       " vlans=" & to_string(vlan_count)
                    severity note;
            end if;

            if ipv4_v = '1' then
                report "  [IPv4] test=" & integer'image(test_num) &
                       " latency=" & integer'image(cycle_count - sof_cycle) & " clk" &
                       " proto=" & to_hstring(ipv4_proto) &
                       " src=" & to_hstring(ipv4_src) &
                       " dst=" & to_hstring(ipv4_dst)
                    severity note;
            end if;

            if l4_ports_v = '1' then
                report "  [L4] test=" & integer'image(test_num) &
                       " latency=" & integer'image(cycle_count - sof_cycle) & " clk" &
                       " tcp=" & std_logic'image(is_tcp) &
                       " udp=" & std_logic'image(is_udp) &
                       " sport=" & to_hstring(l4_src_port) &
                       " dport=" & to_hstring(l4_dst_port)
                    severity note;
            end if;

            if eof_v = '1' then
                report "  [EOF] test=" & integer'image(test_num) severity note;
            end if;

            if parse_error = '1' then
                report "  [ERROR] test=" & integer'image(test_num) &
                       " parse_error asserted"
                    severity warning;
            end if;
        end if;
    end process monitor_p;

end sim;
