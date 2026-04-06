# eth_header_parser

Ultra-low-latency Ethernet header parser for 10GBASE-R. Parses 66-bit descrambled blocks at 312.5-500 MHz, extracts L2/L3/L4 header fields with **per-field valid signals** -- downstream logic can act on MAC addresses in 1 clock (3.2 ns @ 312.5 MHz) without waiting for TCP/UDP ports.

| Metric | Value |
|--------|-------|
| Target FPGA | xcvu11p-fsgd2104-2-e (UltraScale+) |
| Clock | 312.5 MHz (verified), 500 MHz (timing closed) |
| MAC address latency | **1 clock** (3.2 ns @ 312.5 MHz, 2.0 ns @ 500 MHz) |
| Full L4 ports latency | 5 clocks (IPv4), 8 clocks (IPv6) |
| Resources | 1,426 LUT / 1,569 FF / 0 BRAM / 0 DSP |
| WNS @ 500 MHz | +0.018 ns (all constraints met) |

---

## Architecture

```
blk_d[65:0] + blk_v (descrambled 66-bit blocks)
       |
       +-------------------------------+--------------------------+
       |                               |                          |
       v                               v                          v
+-----------------+          +------------------+        +------------------+
| eth_hdr_realign |          | eth_fcs_bridge   |        | eth_l2_check     |
| SOF detect +    |          | 66b -> din/din_v |        | MAC filter +     |
| barrel shift    |          | 128-deep FIFO    |        | frame length     |
| 4-state FSM     |          | 50% duty output  |        | runt/jumbo check |
+---------+-------+          +---------+--------+        +--------+---------+
          |                            |                          |
          | aligned_d[63:0]            | din[63:0]                | l2_good
          | aligned_v                  | din_v[7:0]               | l2_bad
          |                            | fcs_clk_en               | mac_match
          v                            v                          |
+-----------------+          +------------------+                 |
| eth_hdr_extract |          | eth_fcs          |                 |
| Word counter    |          | CRC-32 slice-by-8|                 |
| Per-field valid |          | 2-stage pipelined|                 |
| VLAN/IPv4/IPv6  |          | feedback loop    |                 |
+-----------------+          +------------------+                 |
   |                            |                                 |
   | mac_dst/src_v              | fcs_good                        |
   | ethertype_v                | fcs_bad                         |
   | ipv4_v / ipv6_v            |                                 |
   | l4_ports_v                 |                                 |
   v                            v                                 v
+--------------------------------------------------------------------------+
|                       eth_hdr_parser_top                                  |
|                     (top-level wrapper)                                   |
+--------------------------------------------------------------------------+
```

> See [`eth_header_parser/docs/architecture.drawio`](eth_header_parser/docs/architecture.drawio) for the system diagram, [`eth_hdr_realign.drawio`](eth_header_parser/docs/eth_hdr_realign.drawio) for the realign FSM + barrel shift, and [`eth_hdr_extract.drawio`](eth_header_parser/docs/eth_hdr_extract.drawio) for the per-word extraction pipeline.

### Data Flow

1. **Realign** (`eth_hdr_realign`): Detects SOF1/SOF2/SOF3 in 66-bit blocks. SOF1 (lane 0 start) passes through combinationally. SOF2/SOF3 (lane 4 start) uses a barrel shift to assemble an aligned 64-bit word from two consecutive blocks.

2. **Extract** (`eth_hdr_extract`): Walks the aligned stream with a word counter. Each word position maps to specific header fields. Per-field `*_v` pulses fire as soon as each field is fully assembled.

3. **FCS Check** (`eth_fcs_bridge` + `eth_fcs`): Parallel path that does not add latency to header extraction. The bridge converts 66-bit blocks to 8-byte words with valid masks. The CRC-32 engine uses the Kounavis & Berry slice-by-8 algorithm with 8 x 256-entry ROM lookup tables, pipelined for 500 MHz.

4. **L2 Check** (`eth_l2_check`): Parallel path validating destination MAC against station MAC (or broadcast) and frame length against 64B minimum / configurable maximum.

---

## Latency

All latencies measured from the clock edge where `sof_v` asserts.

| Field | SOF1 | SOF2 / SOF3 | Time @ 312.5 MHz | Time @ 500 MHz |
|-------|------|-------------|------------------|----------------|
| `sof_v` | 0 | 0 | 0 ns | 0 ns |
| `mac_dst_v` | **1 clk** | 2 clk | **3.2 ns** | **2.0 ns** |
| `mac_src_v` | 2 clk | 3 clk | 6.4 ns | 4.0 ns |
| `ethertype_v` (no VLAN) | 2 clk | 3 clk | 6.4 ns | 4.0 ns |
| `ethertype_v` (1 VLAN) | 3 clk | 4 clk | 9.6 ns | 6.0 ns |
| `ethertype_v` (2 VLAN QinQ) | 4 clk | 5 clk | 12.8 ns | 8.0 ns |
| `ipv4_v` + `l4_ports_v` | 5 clk | 6 clk | 16.0 ns | 10.0 ns |
| `ipv6_v` + `l4_ports_v` | 8 clk | 9 clk | 25.6 ns | 16.0 ns |
| `eof_v` | N+1 | N+2 | frame dependent | frame dependent |

SOF2/SOF3 add +1 clock because the barrel shift requires 2 blocks to assemble the first aligned word.

---

## SOF Types

10GBASE-R defines three start-of-frame block encodings:

| Type | Block Code | Bits [9:2] | Alignment | Handling |
|------|-----------|------------|-----------|----------|
| SOF1 | `DDDDDDDS` | `0x78` | `/S/` at lane 0 | Direct: `blk_d[65:2]` |
| SOF2 | `DDDSZZZZ` | `0x33` | `/S/` at lane 4 | Barrel shift: `curr[33:2] & prev[65:34]` |
| SOF3 | `DDDSDDDQ` | `0x66` | `/S/` at lane 4 | Same barrel shift as SOF2 |

---

## Protocol Support

| Feature | Status | Notes |
|---------|--------|-------|
| SOF1 / SOF2 / SOF3 | Supported | All three 10GBASE-R start-of-frame types |
| 0 / 1 / 2 VLAN tags | Supported | 802.1Q (`0x8100`) and 802.1ad QinQ (`0x88A8`) |
| IPv4 (IHL=5) | Supported | Standard 20-byte header, no options |
| IPv6 (40-byte fixed) | Supported | L4 ports at +3 clk vs IPv4 |
| TCP port extraction | Supported | `is_tcp` flag + `l4_src_port` / `l4_dst_port` |
| UDP port extraction | Supported | `is_udp` flag + `l4_src_port` / `l4_dst_port` |
| ARP / other non-IP | Detected | EtherType output, no L3/L4 parsing |
| IPv4 options (IHL>5) | Detected | `ipv4_ihl` output for downstream handling |
| FCS CRC-32 | Supported | Parallel path, no impact on parse latency |
| MAC address filtering | Supported | Station MAC + broadcast accept |
| Frame length check | Supported | Runt (<64B) / jumbo (>max) detection |

---

## Output Interface

Per-field valid signals -- each `*_v` is a 1-clock pulse, data holds until next frame. All multi-byte fields are in **network byte order** (big-endian, matching Wireshark).

```vhdl
-- Generics
G_STATION_MAC    : std_logic_vector(47 downto 0) := x"AABBCCDDEEFF"
G_MAX_FRAME_SIZE : integer := 1518

-- Input: descrambled 66-bit blocks
clk, rst  : in  std_logic
blk_d     : in  std_logic_vector(65 downto 0)
blk_v     : in  std_logic

-- SOF (T+0)
sof_v     : out std_logic
sof_type  : out std_logic_vector(1 downto 0)   -- "01"=SOF1, "10"=SOF2, "11"=SOF3
frame_v   : out std_logic                       -- high during active frame

-- L2 MAC (SOF1: T+1)
mac_dst_v : out std_logic
mac_dst   : out std_logic_vector(47 downto 0)
mac_src_v : out std_logic
mac_src   : out std_logic_vector(47 downto 0)

-- L2 EtherType + VLAN (SOF1: T+2)
ethertype_v : out std_logic
ethertype   : out std_logic_vector(15 downto 0)
vlan_count  : out std_logic_vector(1 downto 0)  -- 0, 1, or 2 tags
vlan1_tci   : out std_logic_vector(15 downto 0)
vlan2_tci   : out std_logic_vector(15 downto 0)

-- L3 IPv4 (SOF1: T+5)
ipv4_v      : out std_logic
is_ipv4     : out std_logic
ipv4_ihl    : out std_logic_vector(3 downto 0)
ipv4_dscp   : out std_logic_vector(5 downto 0)
ipv4_totlen : out std_logic_vector(15 downto 0)
ipv4_proto  : out std_logic_vector(7 downto 0)
ipv4_src    : out std_logic_vector(31 downto 0)
ipv4_dst    : out std_logic_vector(31 downto 0)

-- L3 IPv6 (SOF1: T+8)
ipv6_v    : out std_logic
is_ipv6   : out std_logic
ipv6_nhdr : out std_logic_vector(7 downto 0)
ipv6_plen : out std_logic_vector(15 downto 0)
ipv6_src  : out std_logic_vector(127 downto 0)
ipv6_dst  : out std_logic_vector(127 downto 0)

-- L4 TCP/UDP (SOF1: T+5 IPv4, T+8 IPv6)
l4_ports_v  : out std_logic
is_tcp      : out std_logic
is_udp      : out std_logic
l4_src_port : out std_logic_vector(15 downto 0)
l4_dst_port : out std_logic_vector(15 downto 0)

-- L2 check (at EOF)
l2_good    : out std_logic
l2_bad     : out std_logic
mac_match  : out std_logic
mac_bcast  : out std_logic
frame_len  : out std_logic_vector(15 downto 0)
frame_runt : out std_logic
frame_jumbo: out std_logic

-- FCS CRC-32 (parallel path)
fcs_good : out std_logic
fcs_bad  : out std_logic

-- Status
eof_v       : out std_logic
parse_error : out std_logic
```

---

## File Structure

```
README.md                                  -- This file (repo root)
eth_header_parser/
  src/
    eth_hdr_parser_pkg.vhd                 -- Constants, types, helper functions
    eth_fcs_roms_pkg.vhd                   -- 8 x 256-entry CRC-32 lookup tables
    eth_hdr_realign.vhd                    -- SOF detection + barrel shift (4-state FSM)
    eth_hdr_extract.vhd                    -- Header extraction (word counter + per-field valid)
    eth_l2_check.vhd                       -- MAC filtering + frame length validation
    eth_fcs_bridge.vhd                     -- 66-bit -> din/din_v converter + 128-deep FIFO
    eth_fcs.vhd                            -- CRC-32 slice-by-8 checker (pipelined)
    eth_hdr_parser_top.vhd                 -- Top-level wrapper
  testbench/
    eth_hdr_parser_tb.vhd                  -- 11 test cases with latency measurement
  docs/
    architecture.drawio                    -- System architecture (Draw.io)
    eth_hdr_realign.drawio                 -- Realign FSM + barrel shift (Draw.io)
    eth_hdr_extract.drawio                 -- Per-word extraction pipeline (Draw.io)
  constraints.xdc                          -- Timing constraints (500 MHz)
  Makefile                                 -- Vivado XSIM: make simulate / make synth
  run.tcl                                  -- XSIM waveform dump script
  CLAUDE.md                                -- Design decisions and progress log
```

---

## Build

Requires Vivado 2022.2+ (XSIM for simulation, Vivado for synthesis/implementation).

```bash
make simulate    # Compile + elaborate + run all tests (XSIM, ~5 us)
make wave        # Open waveform viewer (XSIM GUI)
make synth       # Vivado OOC synthesis
make impl        # Vivado OOC implementation
make clean       # Remove build artifacts
```

---

## Implementation Results

### Timing (500 MHz, OOC on xcvu11p-fsgd2104-2-e)

| Metric | Value |
|--------|-------|
| Clock period | 2.000 ns (500 MHz) |
| WNS | **+0.018 ns** (all constraints met) |
| TNS | 0.000 ns |
| Failing endpoints | **0** / 4,322 |
| Synthesis strategy | `Flow_PerfOptimized_high` |
| Implementation strategy | `Performance_ExplorePostRoutePhysOpt` |

Critical path: `fcs_inst/crc_reg_reg[15]` -> `fcs_inst/bad_fcs_reg` (FCS comparison), 6 logic levels, 1.772 ns.

### Resource Utilization

| Module | LUT | FF | Notes |
|--------|----:|---:|-------|
| `realign_inst` | 138 | 41 | SOF detect + barrel shift |
| `extract_inst` | 55 | 550 | Header field registers |
| `l2_check_inst` | 26 | 38 | MAC filter + frame length |
| `fcs_bridge_inst` | 169 | 76 | 128-deep skid FIFO |
| `fcs_inst` | 725 | 247 | CRC-32 (8 distributed ROM tables) |
| **Total** | **1,426** | **1,569** | **0 BRAM, 0 DSP** |

Device utilization: < 0.2% of xcvu11p.

---

## Test Cases

| # | Test | SOF | Protocol | Verified |
|---|------|-----|----------|----------|
| 1 | IPv4/TCP basic | SOF1 | TCP | MAC, IP, ports, latency 1/2/2/5/5 clk |
| 2 | IPv4/UDP SOF2 | SOF2 | UDP | Barrel shift, latency 2/3/3/6/6 clk |
| 3 | IPv4/TCP SOF3 | SOF3 | TCP | SOF3 alignment |
| 4 | IPv4/UDP | SOF1 | UDP | Proto=0x11, sport=5000, dport=53 |
| 5 | 1 VLAN + IPv4/TCP | SOF1 | TCP | 802.1Q tag, ethertype latency +1 clk |
| 6 | 2 VLAN QinQ + IPv4/TCP | SOF1 | TCP | 802.1ad + 802.1Q, ethertype latency +2 clk |
| 7 | IPv6/TCP | SOF1 | TCP | 128-bit src/dst, L4 at T+8 clk |
| 9 | ARP broadcast | SOF1 | ARP | DMAC=FF:FF:FF:FF:FF:FF, etype=0x0806 |
| 10 | Back-to-back | SOF1x2 | TCP | Frame transition, different SMAC |
| 11 | Correct FCS | SOF1 | TCP | 64-byte frame, `fcs_good=1` |
| 12 | Corrupted FCS | SOF1 | TCP | Bit-flipped FCS, `fcs_bad=1` |

---

## Byte Ordering

Within a 66-bit DATA block's 64-bit payload `[65:2]`:

```
bits[9:2]   = byte 0 = first byte on wire (e.g., DMAC[0])
bits[17:10] = byte 1
  ...
bits[65:58] = byte 7 = 8th byte on wire
```

The testbench helper `make_data(b7, b6, b5, b4, b3, b2, b1, b0)` maps:
- `b0` -> bits[9:2] (first on wire)
- `b7` -> bits[65:58] (last on wire)

All multi-byte output fields use **network byte order** (big-endian), matching Wireshark captures.

---

## 500 MHz CRC Pipeline Design

The original CRC-32 slice-by-8 engine had a combinational feedback loop of 6-7 LUT levels:

```
crc_reg -> XOR(pipe[3]) -> sliced -> ROM lookup -> 8-way XOR -> crcgen -> crc_reg
```

This loop closed at 312.5 MHz (WNS +0.229 ns) but violated timing at 500 MHz (WNS -0.156 ns).

**Solution**: split the loop at `sliced` with a pipeline register (`sliced_q`, `slice_q`). The upstream bridge (`eth_fcs_bridge`) emits data at max 50% duty via a 128-deep skid FIFO with phase-toggled output, guaranteeing the CRC engine always has one idle cycle between updates for the registered path to settle. This matches real 10GBASE-R data rate (blocks arrive at 156.25 MHz, which is 31% duty at 500 MHz).

```
Stage 1 (clk_en=1):  crc_reg + pipe[3] + slice  -->  sliced_q (register)
                                                      slice_q  (register)
                                                      crc_wr_req = 1

Stage 2 (clk_en=0):  ROM(sliced_q) --> spo32..spo88 --> crcgen_new --> crc_reg
                                                                       crc_wr_req = 0
```

The 8 CRC ROM tables (256 x 32-bit each) are forced to distributed RAM via `attribute rom_style of spo* : signal is "distributed"` to avoid BRAM inference (~1.1 ns clock-to-out would violate timing).

---

## Design Origin

Patterns extracted from the fibres_proj_v2 E-band 10G backhaul system:

| Pattern | Source | Usage |
|---------|--------|-------|
| Barrel shift | `rsi.vhd` L330 | SOF2/SOF3 alignment |
| Parallel VLAN decode | `eth_txhold.vhd` L181-254 | Multi-pipeline EtherType detection |
| Combinational output | `eth_64b66b.vhd` L90-93 | Zero-latency aligned data |
| SOF detection | `eth_rxfifo.vhd` L206-209 | Block type classification |
| CRC-32 slice-by-8 | `eth_fcs.vhd` | Adapted from fibres_proj_v2 |

---

## License

Private repository. Contact repository owner for licensing.
