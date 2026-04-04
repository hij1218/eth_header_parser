------------------------------------------------------------------------
--  Entity:  eth_hdr_parser_top
--  Description:
--    Top-level wrapper for the low-latency Ethernet header parser.
--    Connects eth_hdr_realign, eth_hdr_extract, eth_l2_check, and
--    eth_fcs_check (bridge + CRC-32).
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.eth_hdr_parser_pkg.all;

entity eth_hdr_parser_top is
generic (
    G_STATION_MAC    : std_logic_vector(47 downto 0) := x"AABBCCDDEEFF";
    G_MAX_FRAME_SIZE : integer := 1518
);
port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    -- Input: descrambled 66-bit blocks
    blk_d       : in  std_logic_vector(65 downto 0);
    blk_v       : in  std_logic;
    -- SOF detection
    sof_v       : out std_logic;
    sof_type    : out std_logic_vector(1 downto 0);
    frame_v     : out std_logic;
    -- Layer 2 -- MAC
    mac_dst_v   : out std_logic;
    mac_dst     : out std_logic_vector(47 downto 0);
    mac_src_v   : out std_logic;
    mac_src     : out std_logic_vector(47 downto 0);
    -- Layer 2 -- EtherType & VLAN
    ethertype_v : out std_logic;
    ethertype   : out std_logic_vector(15 downto 0);
    vlan_count  : out std_logic_vector(1 downto 0);
    vlan1_tci   : out std_logic_vector(15 downto 0);
    vlan2_tci   : out std_logic_vector(15 downto 0);
    -- Layer 3 -- IPv4
    ipv4_v      : out std_logic;
    is_ipv4     : out std_logic;
    ipv4_ihl    : out std_logic_vector(3 downto 0);
    ipv4_dscp   : out std_logic_vector(5 downto 0);
    ipv4_totlen : out std_logic_vector(15 downto 0);
    ipv4_proto  : out std_logic_vector(7 downto 0);
    ipv4_src    : out std_logic_vector(31 downto 0);
    ipv4_dst    : out std_logic_vector(31 downto 0);
    -- Layer 3 -- IPv6
    ipv6_v      : out std_logic;
    is_ipv6     : out std_logic;
    ipv6_nhdr   : out std_logic_vector(7 downto 0);
    ipv6_plen   : out std_logic_vector(15 downto 0);
    ipv6_src    : out std_logic_vector(127 downto 0);
    ipv6_dst    : out std_logic_vector(127 downto 0);
    -- Layer 4
    l4_ports_v  : out std_logic;
    is_tcp      : out std_logic;
    is_udp      : out std_logic;
    l4_src_port : out std_logic_vector(15 downto 0);
    l4_dst_port : out std_logic_vector(15 downto 0);
    -- Status
    eof_v       : out std_logic;
    parse_error : out std_logic;
    -- L2 check
    l2_good     : out std_logic;
    l2_bad      : out std_logic;
    mac_match   : out std_logic;
    mac_bcast   : out std_logic;
    frame_len   : out std_logic_vector(15 downto 0);
    frame_runt  : out std_logic;
    frame_jumbo : out std_logic;
    -- FCS check
    fcs_good    : out std_logic;
    fcs_bad     : out std_logic
);
end eth_hdr_parser_top;

architecture rtl of eth_hdr_parser_top is

    signal aligned_d    : std_logic_vector(63 downto 0);
    signal aligned_v    : std_logic;
    signal sof_pulse_i  : std_logic;
    signal eof_pulse_i  : std_logic;
    signal sof_type_i   : std_logic_vector(1 downto 0);
    signal frame_act_i  : std_logic;

    signal mac_dst_v_i  : std_logic;
    signal mac_dst_i    : std_logic_vector(47 downto 0);

    -- FCS bridge -> FCS module
    signal fcs_din      : std_logic_vector(63 downto 0);
    signal fcs_din_v    : std_logic_vector(7 downto 0);
    signal fcs_clk_en   : std_logic;

begin

    ----------------------------------------------------------------
    -- Realign: SOF detection + barrel shift
    ----------------------------------------------------------------
    realign_inst : entity work.eth_hdr_realign
    port map (
        clk          => clk,
        rst          => rst,
        blk_d        => blk_d,
        blk_v        => blk_v,
        aligned_d    => aligned_d,
        aligned_v    => aligned_v,
        sof_pulse    => sof_pulse_i,
        sof_type     => sof_type_i,
        eof_pulse    => eof_pulse_i,
        frame_active => frame_act_i
    );

    ----------------------------------------------------------------
    -- Extract: header field parsing
    ----------------------------------------------------------------
    extract_inst : entity work.eth_hdr_extract
    port map (
        clk         => clk,
        rst         => rst,
        aligned_d   => aligned_d,
        aligned_v   => aligned_v,
        sof_pulse   => sof_pulse_i,
        eof_pulse   => eof_pulse_i,
        mac_dst_v   => mac_dst_v_i,
        mac_dst     => mac_dst_i,
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
        parse_error => parse_error
    );

    mac_dst_v <= mac_dst_v_i;
    mac_dst   <= mac_dst_i;

    ----------------------------------------------------------------
    -- L2 check: MAC filtering + frame length
    ----------------------------------------------------------------
    l2_check_inst : entity work.eth_l2_check
    generic map (
        G_STATION_MAC    => G_STATION_MAC,
        G_MAX_FRAME_SIZE => G_MAX_FRAME_SIZE
    )
    port map (
        clk       => clk,
        rst       => rst,
        aligned_v => aligned_v,
        sof_pulse => sof_pulse_i,
        eof_pulse => eof_pulse_i,
        sof_type  => sof_type_i,
        blk_d     => blk_d,
        mac_dst   => mac_dst_i,
        mac_dst_v => mac_dst_v_i,
        l2_good   => l2_good,
        l2_bad    => l2_bad,
        mac_match => mac_match,
        mac_bcast => mac_bcast,
        frame_len => frame_len,
        frame_runt => frame_runt,
        frame_jumbo => frame_jumbo
    );

    ----------------------------------------------------------------
    -- FCS bridge: 66-bit blocks -> din/din_v for CRC module
    ----------------------------------------------------------------
    fcs_bridge_inst : entity work.eth_fcs_bridge
    port map (
        clk        => clk,
        rst        => rst,
        blk_d      => blk_d,
        blk_v      => blk_v,
        fcs_din    => fcs_din,
        fcs_din_v  => fcs_din_v,
        fcs_clk_en => fcs_clk_en
    );

    ----------------------------------------------------------------
    -- FCS: CRC-32 slice-by-8 checker
    ----------------------------------------------------------------
    fcs_inst : entity work.eth_fcs
    port map (
        clk      => clk,
        rst      => rst,
        clk_en   => fcs_clk_en,
        din      => fcs_din,
        din_v    => fcs_din_v,
        dout     => open,
        dout_v   => open,
        set_fcs  => '0',
        good_fcs => fcs_good,
        bad_fcs  => fcs_bad
    );

    sof_v    <= sof_pulse_i;
    sof_type <= sof_type_i;
    frame_v  <= frame_act_i;
    eof_v    <= eof_pulse_i;

end rtl;
