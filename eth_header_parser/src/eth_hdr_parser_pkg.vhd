------------------------------------------------------------------------
--  Package: eth_hdr_parser_pkg
--  Description:
--    Constants and types for the low-latency Ethernet header parser.
--    Covers 10GBASE-R 64b/66b block types, sync codes, and protocol IDs.
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package eth_hdr_parser_pkg is

    -- 2-bit sync codes (bits [1:0] of 66-bit block)
    constant SYNC_DATA : std_logic_vector(1 downto 0) := "10";
    constant SYNC_CTRL : std_logic_vector(1 downto 0) := "01";

    -- 8-bit block type field (bits [9:2] of control blocks)
    constant BT_IDLE     : std_logic_vector(7 downto 0) := x"1e";  -- ZZZZZZZZ
    constant BT_SOF1     : std_logic_vector(7 downto 0) := x"78";  -- DDDDDDDS
    constant BT_SOF2     : std_logic_vector(7 downto 0) := x"33";  -- DDDSZZZZ
    constant BT_SOF3     : std_logic_vector(7 downto 0) := x"66";  -- DDDSDDDQ
    constant BT_EOF_T0   : std_logic_vector(7 downto 0) := x"87";  -- ZZZZZZZT
    constant BT_EOF_T1   : std_logic_vector(7 downto 0) := x"99";  -- ZZZZZZTD
    constant BT_EOF_T2   : std_logic_vector(7 downto 0) := x"aa";  -- ZZZZZTDD
    constant BT_EOF_T3   : std_logic_vector(7 downto 0) := x"b4";  -- ZZZZTDDD
    constant BT_EOF_T4   : std_logic_vector(7 downto 0) := x"cc";  -- ZZZTDDDD
    constant BT_EOF_T5   : std_logic_vector(7 downto 0) := x"d2";  -- ZZTDDDDD
    constant BT_EOF_T6   : std_logic_vector(7 downto 0) := x"e1";  -- ZTDDDDDD
    constant BT_EOF_T7   : std_logic_vector(7 downto 0) := x"ff";  -- TDDDDDDD

    -- SOF type encoding (output)
    constant SOF_TYPE_1  : std_logic_vector(1 downto 0) := "01";
    constant SOF_TYPE_2  : std_logic_vector(1 downto 0) := "10";
    constant SOF_TYPE_3  : std_logic_vector(1 downto 0) := "11";

    -- EtherType values (network byte order, big-endian)
    constant ETYPE_IPV4  : std_logic_vector(15 downto 0) := x"0800";
    constant ETYPE_IPV6  : std_logic_vector(15 downto 0) := x"86DD";
    constant ETYPE_ARP   : std_logic_vector(15 downto 0) := x"0806";
    constant ETYPE_VLAN  : std_logic_vector(15 downto 0) := x"8100";  -- 802.1Q
    constant ETYPE_QINQ  : std_logic_vector(15 downto 0) := x"88A8";  -- 802.1ad

    -- IP protocol numbers
    constant IP_PROTO_TCP : std_logic_vector(7 downto 0) := x"06";
    constant IP_PROTO_UDP : std_logic_vector(7 downto 0) := x"11";

    -- Helper function: check if block type is an EOF variant
    function is_eof_type(bt : std_logic_vector(7 downto 0)) return boolean;

    -- Helper function: swap 2 bytes (network to host order within a 66-bit block)
    -- In 66-bit blocks, byte[0] is at bits[9:2], byte[1] at bits[17:10], etc.
    -- The first transmitted byte (MSB of a 16-bit field) is at the LOWER bit position.
    -- This function swaps to produce big-endian (network byte order) output.
    function ntohs(word : std_logic_vector(15 downto 0)) return std_logic_vector;

end package eth_hdr_parser_pkg;

package body eth_hdr_parser_pkg is

    function is_eof_type(bt : std_logic_vector(7 downto 0)) return boolean is
    begin
        case bt is
            when x"87" | x"99" | x"aa" | x"b4" |
                 x"cc" | x"d2" | x"e1" | x"ff" =>
                return true;
            when others =>
                return false;
        end case;
    end function;

    function ntohs(word : std_logic_vector(15 downto 0)) return std_logic_vector is
    begin
        -- In 66-bit block payload, byte[0] (first on wire, MSB) is at [7:0],
        -- byte[1] (second on wire, LSB) is at [15:8].
        -- Swap to produce standard big-endian: MSB at [15:8], LSB at [7:0].
        return word(7 downto 0) & word(15 downto 8);
    end function;

end package body eth_hdr_parser_pkg;
