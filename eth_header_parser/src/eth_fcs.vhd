-------------------------------------------------------------------------------
--  Entity:  eth_fcs
--  Description:
--  This module generates an Ethernet CRC32 from packet payload. The module
--  can either compare the generated CRC32 with the packet's own FCS
--  to check packet data integrity, or it can overwrite the packet's FCS
--  field with the CRC32 that it has generated.
--  We use the slice by 8 algorithm described in the paper by M.Kounavis
--  & F.Berry, "Novel Table Lookup-Based Algorithms for High-Performance
--  CRC Generation", IEEE Trans on Computers v.57, no.11, November 2008
--  Back-to-back packets are supported but there must be at least 5 idle
--  octets between packets
------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.eth_fcs_roms_pkg.ALL;
use work.eth_hdr_parser_pkg.ALL;

entity eth_fcs is
port (
   -- Clock and synchronous reset
   clk      : in std_logic;
   clk_en   : in std_logic;
   rst      : in std_logic;
   -- Packet data in. The first octet of a packet can either
   -- be in the b<7:0> or the b<39:31> position. The 4 last
   -- octets in the packet are used as the FCS field.
   din      : in std_logic_vector(63 downto 0);
   din_v    : in std_logic_vector(7 downto 0);
   -- Packet data out. Only useful when set_fcs = '1'
   dout     : out std_logic_vector(63 downto 0);
   dout_v   : out std_logic_vector(7 downto 0);
   -- If set_fcs is '1' then the packet's FCS field will
   -- be overwritten by the generated CRC32.
   set_fcs  : in std_logic;
   -- Outputs from comparison of packet FCS field with
   -- generated CRC64.
   good_fcs : out std_logic;
   bad_fcs  : out std_logic );
end eth_fcs;

architecture Behavioral of eth_fcs is

   type state_t is (idle_s, sof1_s, sof2_s, frame_s, eof1_s, eof2_s, eof3_s, eof4_s );
   type slice_t is (sof1, sof2, eof1, eof2, eof3, eof4, eof5, eof6, eof7, full8 );

   signal pipe       : word64_array_t(0 to 5) := (others=>(others=>'0'));
   signal pipe_valid : word8_array_t(pipe'range) := (others=>(others=>'0'));
   signal state      : state_t := idle_s;
   signal nxt_state  : state_t;
   signal pipe_eof   : std_logic;
   signal crc_reg    : std_logic_vector(31 downto 0) := (others=>'1');
   signal crc_reg_n  : std_logic_vector(31 downto 0);
   signal sliced     : std_logic_vector(63 downto 0);
   signal spo32      : std_logic_vector(31 downto 0);
   signal spo40      : std_logic_vector(31 downto 0);
   signal spo48      : std_logic_vector(31 downto 0);
   signal spo56      : std_logic_vector(31 downto 0);
   signal spo64      : std_logic_vector(31 downto 0);
   signal spo72      : std_logic_vector(31 downto 0);
   signal spo80      : std_logic_vector(31 downto 0);
   signal spo88      : std_logic_vector(31 downto 0);
   signal slice      : slice_t;
   signal set_fcs_reg : std_logic := '0';

   -- 500 MHz pipeline break:
   --   sliced/slice are registered (sliced_q/slice_q) before ROM lookup,
   --   splitting the combinational CRC feedback loop into 2 clock stages.
   --   Upstream (eth_fcs_bridge) guarantees clk_en is max 50% duty, so
   --   crc_reg updates 1 cycle after sliced_q was registered, before the
   --   next clk_en tick uses crc_reg to compute the next sliced.
   signal sliced_q   : std_logic_vector(63 downto 0) := (others=>'0');
   signal slice_q    : slice_t := full8;
   signal crc_wr_req : std_logic := '0';
   signal crcgen_new : std_logic_vector(31 downto 0);

   -- Keep the 256x32 CRC ROM lookups in LUT-based distributed memory.
   -- With the registered address (sliced_q), Vivado would otherwise
   -- infer BRAM whose ~1.1 ns clock-to-out kills the 500 MHz budget.
   attribute rom_style : string;
   attribute rom_style of spo32 : signal is "distributed";
   attribute rom_style of spo40 : signal is "distributed";
   attribute rom_style of spo48 : signal is "distributed";
   attribute rom_style of spo56 : signal is "distributed";
   attribute rom_style of spo64 : signal is "distributed";
   attribute rom_style of spo72 : signal is "distributed";
   attribute rom_style of spo80 : signal is "distributed";
   attribute rom_style of spo88 : signal is "distributed";

begin

   pipe_p : process(clk)
   begin
      if rising_edge(clk) then
         if rst = '1' then
            state <= idle_s;
            pipe_valid <= (others=>(others=>'0'));
            good_fcs <= '0';
            bad_fcs <= '0';
            sliced_q <= (others=>'0');
            slice_q  <= full8;
            crc_wr_req <= '0';
            crc_reg  <= (others=>'1');
         else
            -- Pipelined CRC update: fires 1 cycle after sliced_q/slice_q
            -- were registered. clk_en is max 50% duty from bridge, so
            -- crc_reg always settles before the next clk_en tick.
            if crc_wr_req = '1' then
               crc_reg    <= crcgen_new;
               crc_wr_req <= '0';
            end if;

            if clk_en = '1' then
               state <= nxt_state;
               pipe(0) <= din;
               pipe_valid(0) <= din_v;
               for i in 1 to pipe'high loop
                  pipe(i) <= pipe(i-1);
                  pipe_valid(i) <= pipe_valid(i-1);
               end loop;
               good_fcs <= '0';
               bad_fcs <= '0';
               -- Register sliced/slice for pipelined CRC feedback loop
               sliced_q <= sliced;
               slice_q  <= slice;
            case state is
            when sof1_s =>
               -- SOF1 is at pipe(2)
               slice <= sof1;
            when sof2_s =>
               -- SOF2 is at pipe(2)
               slice <= sof2;
            when frame_s =>
               crc_wr_req <= '1';
               slice <= full8;
            when eof1_s =>
               -- EOF is at pipe(1)
               case pipe_valid(1) is
               when "00000001" => slice <= eof5;
               when "00000011" => slice <= eof6;
               when "00000111" => slice <= eof7;
               when others => slice <= full8;
               end case;
               crc_wr_req <= '1';
               set_fcs_reg <= set_fcs;
            when eof2_s =>
               -- EOF is at pipe(2)
               case pipe_valid(2) is
               when "00011111" => slice <= eof1;
               when "00111111" => slice <= eof2;
               when "01111111" => slice <= eof3;
               when "11111111" => slice <= eof4;
               when others => null;
               end case;
               crc_wr_req <= '1';
            when eof3_s =>
               -- EOF is at pipe(3)
               case pipe_valid(3) is
               when "00000001" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= crc_reg_n(23 downto 0) & pipe(4)(39 downto 0);
                     pipe(4) <= x"00000000000000" & crc_reg_n(31 downto 24);
                  end if;
                  if pipe(4)(63 downto 40) = crc_reg_n(23 downto 0)
                        and pipe(3)(7 downto 0) = crc_reg_n(31 downto 24) then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "00000011" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= crc_reg_n(15 downto 0) & pipe(4)(47 downto 0);
                     pipe(4) <= x"000000000000" & crc_reg_n(31 downto 16);
                  end if;
                  if pipe(4)(63 downto 48) = crc_reg_n(15 downto 0)
                        and pipe(3)(15 downto 0) = crc_reg_n(31 downto 16) then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "00000111" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= crc_reg_n(7 downto 0) & pipe(4)(55 downto 0);
                     pipe(4) <= x"0000000000" & crc_reg_n(31 downto 8);
                  end if;
                  if pipe(4)(63 downto 56) = crc_reg_n(7 downto 0)
                        and pipe(3)(23 downto 0) = crc_reg_n(31 downto 8) then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "00001111" =>
                  if set_fcs_reg = '1' then
                     pipe(4) <= x"00000000" & crc_reg_n;
                  end if;
                  if pipe(3)(31 downto 0) = crc_reg_n then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "00011111" => crc_wr_req <= '1'; -- 8 bit
               when "00111111" => crc_wr_req <= '1'; -- 16 bit
               when "01111111" => crc_wr_req <= '1'; -- 24 bit
               when "11111111" => crc_wr_req <= '1'; -- 32 bit
               when others => null;
               end case;
               -- Process possible SOF at pipe(2)
               if pipe_valid(2) = "11111111" then
                  slice <= sof1;
               elsif pipe_valid(2) = "11110000" then
                  slice <= sof2;
               end if;
            when eof4_s =>
               -- EOF is at pipe(4)
               case pipe_valid(4) is
               when "00011111" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= x"000000" & crc_reg_n & pipe(4)(7 downto 0);
                  end if;
                  if pipe(4)(39 downto 8) = crc_reg_n then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "00111111" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= x"0000" & crc_reg_n & pipe(4)(15 downto 0);
                  end if;
                  if pipe(4)(47 downto 16) = crc_reg_n then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "01111111" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= x"00" & crc_reg_n & pipe(4)(23 downto 0);
                  end if;
                  if pipe(4)(55 downto 24) = crc_reg_n then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when "11111111" =>
                  if set_fcs_reg = '1' then
                     pipe(5) <= crc_reg_n & pipe(4)(31 downto 0);
                  end if;
                  if pipe(4)(63 downto 32) = crc_reg_n then
                     good_fcs <= '1';
                  else
                     bad_fcs <= '1';
                  end if;
               when others => null;
               end case;
               -- Process possible back-to-back SOFs at pipe(3) or pipe(2)
               if pipe_valid(3) = "11110000" then
                  crc_wr_req <= '1';
                  slice <= full8;
               elsif pipe_valid(2) = "11111111" then
                  slice <= sof1;
               elsif pipe_valid(2) = "11110000" then
                  slice <= sof2;
               end if;
            when others => null;
            end case;
            end if;  -- clk_en
         end if;  -- rst
      end if;
   end process pipe_p;

   nxt_state_p : process(state,pipe_eof,pipe_valid(1),pipe_valid(2),pipe_valid(3))
   begin
      nxt_state <= state;
      case state is
      when idle_s =>
         if pipe_valid(1) = "11111111" then
            nxt_state <= sof1_s;
         elsif pipe_valid(1) = "11110000" then
            nxt_state <= sof2_s;
         end if;
      when sof1_s | sof2_s =>
         nxt_state <= frame_s;
      when frame_s =>
         if pipe_eof = '1' then
            nxt_state <= eof1_s;
         end if;
      when eof1_s =>
         nxt_state <= eof2_s;
      when eof2_s =>
         nxt_state <= eof3_s;
      when eof3_s =>
         if pipe_valid(3)(4) = '1' then
            nxt_state <= eof4_s;
         elsif pipe_valid(2) = "11111111" or pipe_valid(2) = "11110000" then
            nxt_state <= frame_s;
         elsif pipe_valid(1) = "11111111" then
            nxt_state <= sof1_s;
         elsif pipe_valid(1) = "11110000" then
            nxt_state <= sof2_s;
         else
            nxt_state <= idle_s;
         end if;
      when eof4_s =>
         if pipe_valid(3) = "11110000" or pipe_valid(2) = "11111111" or pipe_valid(2) = "11110000" then
            nxt_state <= frame_s;
         elsif pipe_valid(1) = "11111111" then
            nxt_state <= sof1_s;
         elsif pipe_valid(1) = "11110000" then
            nxt_state <= sof2_s;
         else
            nxt_state <= idle_s;
         end if;
      end case;
   end process nxt_state_p;

   pipe_eof <= '1' when pipe_valid(0) /= "11111111" or ( pipe_valid(0)(7) = '1' and din_v(0) = '0' ) else '0';

   -- Stage 1: compute sliced combinationally from crc_reg, pipe(3), slice.
   -- Registered into sliced_q at end of each clk_en='1' cycle by pipe_p.
   sliced_p : process(slice,pipe(3),crc_reg)
   begin
      case slice is
      when sof1 =>
         -- Special case of slice by 8 for SOF1 which uses an initial value of xFFFFFFFF
         sliced(31 downto 0) <= not pipe(3)(31 downto 0);
         sliced(63 downto 32) <= pipe(3)(63 downto 32);
      when sof2 =>
         -- Special case of slice by 4 for SOF2 which uses an initial value of xFFFFFFFF
         sliced(31 downto 0) <= x"00000000";
         sliced(63 downto 32) <= not pipe(3)(63 downto 32);
      when eof1 =>
         -- Sarwate
         sliced(55 downto 0) <= x"00000000000000";
         sliced(63 downto 56) <= pipe(3)(7 downto 0) xor crc_reg(7 downto 0);
      when eof2 =>
         -- Slice by 2
         sliced(47 downto 0) <= x"000000000000";
         sliced(63 downto 48) <= pipe(3)(15 downto 0) xor crc_reg(15 downto 0);
      when eof3 =>
         -- Slice by 3
         sliced(39 downto 0) <= x"0000000000";
         sliced(63 downto 40) <= pipe(3)(23 downto 0) xor crc_reg(23 downto 0);
      when eof4 =>
         -- Slice by 4
         sliced(31 downto 0) <= x"00000000";
         sliced(63 downto 32) <= pipe(3)(31 downto 0) xor crc_reg;
      when eof5 =>
         -- Slice by 5
         sliced(31 downto 0) <= ( pipe(3)(7 downto 0) xor crc_reg(7 downto 0) ) & x"000000";
         sliced(63 downto 32) <= pipe(3)(39 downto 32) & ( pipe(3)(31 downto 8) xor crc_reg(31 downto 8) );
      when eof6 =>
         -- Slice by 6
         sliced(31 downto 0) <= ( pipe(3)(15 downto 0) xor crc_reg(15 downto 0) ) & x"0000";
         sliced(63 downto 32) <= pipe(3)(47 downto 32) & ( pipe(3)(31 downto 16) xor crc_reg(31 downto 16) ) ;
      when eof7 =>
         -- Slice by 7
         sliced(31 downto 0) <= ( pipe(3)(23 downto 0) xor crc_reg(23 downto 0) ) & x"00";
         sliced(63 downto 32) <= pipe(3)(55 downto 32) & ( pipe(3)(31 downto 24) xor crc_reg(31 downto 24));
      when full8 =>
         -- Slice by 8
         sliced(31 downto 0) <= pipe(3)(31 downto 0) xor crc_reg;
         sliced(63 downto 32) <= pipe(3)(63 downto 32);
      end case;
   end process sliced_p;

   -- Stage 2: combine ROM outputs (from registered sliced_q) with
   -- current crc_reg (for eof1..eof3) to produce crcgen_new. Case-muxed
   -- on slice_q which was captured alongside sliced_q.
   crcgen_new_p : process(slice_q,crc_reg,spo32,spo40,spo48,spo56,spo64,spo72,spo80,spo88)
   begin
      case slice_q is
      when sof1 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56 xor spo64 xor spo72
                           xor spo80 xor spo88;
      when sof2 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56;
      when eof1 =>
         crcgen_new <= spo32 xor ( x"00" & crc_reg(31 downto 8) );
      when eof2 =>
         crcgen_new <= spo32 xor spo40 xor ( x"0000" & crc_reg(31 downto 16) );
      when eof3 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor ( x"000000" & crc_reg(31 downto 24) );
      when eof4 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56;
      when eof5 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56 xor spo64;
      when eof6 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56 xor spo64 xor spo72;
      when eof7 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56 xor spo64 xor spo72
                           xor spo80;
      when full8 =>
         crcgen_new <= spo32 xor spo40 xor spo48 xor spo56 xor spo64 xor spo72
                           xor spo80 xor spo88;
      end case;
   end process crcgen_new_p;

   crc_reg_n <= not crc_reg;
   dout <= pipe(pipe'high);
   dout_v <= pipe_valid(pipe'high);

   -- ROMs index the registered sliced_q (stage-2 lookups)
   spo32 <= crc64_o32(to_integer(unsigned(sliced_q(63 downto 56))));
   spo40 <= crc64_o40(to_integer(unsigned(sliced_q(55 downto 48))));
   spo48 <= crc64_o48(to_integer(unsigned(sliced_q(47 downto 40))));
   spo56 <= crc64_o56(to_integer(unsigned(sliced_q(39 downto 32))));
   spo64 <= crc64_o64(to_integer(unsigned(sliced_q(31 downto 24))));
   spo72 <= crc64_o72(to_integer(unsigned(sliced_q(23 downto 16))));
   spo80 <= crc64_o80(to_integer(unsigned(sliced_q(15 downto 8))));
   spo88 <= crc64_o88(to_integer(unsigned(sliced_q(7 downto 0))));

end Behavioral;

