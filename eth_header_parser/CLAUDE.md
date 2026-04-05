# CLAUDE.md — eth_header_parser

## Project Overview

Ultra-low-latency Ethernet header parser for 10GBASE-R. Parses 66-bit descrambled blocks at 312.5 MHz, extracts L2/L3/L4 header fields with **per-field valid signals** — downstream logic can act on MAC addresses in 1 clock (3.2 ns) without waiting for TCP/UDP ports.

**Target FPGA**: xcvu11p-flga2577-2-e (Xilinx UltraScale+)
**Clock**: 312.5 MHz (3.2 ns period)
**Origin**: Extracted from fibres_proj_v2 E-band backhaul analysis. Design patterns from `rsi.vhd` (barrel shift), `eth_txhold.vhd` (parallel VLAN decode), `eth_64b66b.vhd` (combinational output for minimum pipeline).

## Architecture

```
blk_d[65:0] + blk_v (312.5 MHz, descrambled 66-bit blocks)
       │
       ├──────────────────────────────────────────────┐
       ▼                                              ▼
┌──────────────────────────┐            ┌──────────────────────────┐
│ eth_hdr_realign          │            │ eth_fcs_bridge           │
│ aligned_d: COMBINATIONAL │            │ 66-bit → din/din_v       │
│ Latency: 0 extra clk     │            │ for CRC-32 checker       │
└──────────┬───────────────┘            └──────────┬───────────────┘
           │ aligned_d, aligned_v                  │ din[63:0], din_v[7:0]
           ├──────────────┐                        ▼
           ▼              ▼              ┌──────────────────────────┐
┌────────────────┐ ┌──────────────┐     │ eth_fcs (CRC-32)         │
│ eth_hdr_extract│ │ eth_l2_check │     │ Slice-by-8, 6-stage pipe │
│ Word counter   │ │ MAC filter + │     │ good_fcs / bad_fcs       │
│ Per-field valid│ │ frame length │     └──────────────────────────┘
└────────────────┘ └──────────────┘
```

## Latency (measured, all tests PASS)

| Field | SOF1 | SOF2/SOF3 | Time (SOF1) |
|-------|------|-----------|-------------|
| `mac_dst_v` | **1 clk** | 2 clk | **3.2 ns** |
| `mac_src_v` | 2 clk | 3 clk | 6.4 ns |
| `ethertype_v` | 2 clk | 3 clk | 6.4 ns |
| `ipv4_v` + `l4_ports_v` | 5 clk | 6 clk | 16.0 ns |

SOF2 and SOF3 add +1 clk because barrel shift requires 2 blocks to assemble the aligned word.

## SOF Types

| Type | Block Code | Alignment | Handling |
|------|-----------|-----------|----------|
| SOF1 | DDDDDDDS (0x78) | /S/ at lane 0 | Direct passthrough: `blk_d(65:2)` |
| SOF2 | DDDSZZZZ (0x33) | /S/ at lane 4 | Barrel shift: `current[33:2] & prev[65:34]` |
| SOF3 | DDDSDDDQ (0x66) | /S/ at lane 4 + /Q/ | Same barrel shift as SOF2, /Q/ ignored |

## Protocol Support

| Feature | Status |
|---------|--------|
| SOF1 / SOF2 / SOF3 | Supported |
| 0 / 1 / 2 VLAN tags (802.1Q, 802.1ad QinQ) | Supported |
| IPv4 (IHL=5, no options) | Supported |
| IPv6 (40-byte fixed header) | Supported (L4 ports +3 clk vs IPv4) |
| TCP / UDP port extraction | Supported |
| ARP and other non-IP | EtherType detected, no L3/L4 parsing |
| IPv4 options (IHL>5) | Not parsed, `ipv4_ihl` output for detection |
| FCS / CRC-32 | Not included (separate module responsibility) |

## Output Interface

Per-field valid signals — each `*_v` is a 1-clock pulse, data holds until next frame.

```
-- SOF (T+0)
sof_v, sof_type[1:0], frame_v

-- L2 MAC (SOF1: T+1)
mac_dst_v, mac_dst[47:0]
mac_src_v, mac_src[47:0]

-- L2 EtherType + VLAN (SOF1: T+2)
ethertype_v, ethertype[15:0], vlan_count[1:0], vlan1_tci[15:0], vlan2_tci[15:0]

-- L3 IPv4 (SOF1: T+5)
ipv4_v, is_ipv4, ipv4_ihl[3:0], ipv4_dscp[5:0], ipv4_totlen[15:0]
ipv4_proto[7:0], ipv4_src[31:0], ipv4_dst[31:0]

-- L3 IPv6
ipv6_v, is_ipv6, ipv6_nhdr[7:0], ipv6_plen[15:0], ipv6_src[127:0], ipv6_dst[127:0]

-- L4 TCP/UDP (SOF1: T+5)
l4_ports_v, is_tcp, is_udp, l4_src_port[15:0], l4_dst_port[15:0]

-- Status
eof_v, parse_error
```

All multi-byte fields output in **network byte order** (big-endian), matching Wireshark.

## File Structure

```
eth_header_parser/
  src/
    eth_hdr_parser_pkg.vhd      -- Constants (block types, sync codes, EtherTypes), helpers
    eth_hdr_realign.vhd          -- SOF detection + barrel shift (4-state FSM)
    eth_hdr_extract.vhd          -- Header extraction (word counter + per-field valid)
    eth_hdr_parser_top.vhd       -- Top-level wrapper
  testbench/
    eth_hdr_parser_tb.vhd        -- 6 test cases with latency measurement
  Makefile                       -- Vivado XSIM: make simulate / make synth
  run.tcl                        -- XSIM run script
  CLAUDE.md                      -- This file
```

## Build Commands

```bash
make simulate    # Compile + elaborate + run (Vivado XSIM)
make clean       # Remove build artifacts
make synth       # Vivado synthesis for timing check (optional)
```

## Test Cases

| # | Test | SOF | Verified Fields |
|---|------|-----|----------------|
| 1 | IPv4/TCP min frame | SOF1 | All fields + latency=1/2/2/5/5 clk |
| 2 | IPv4/TCP min frame | SOF2 | Barrel shift + latency=2/3/3/6/6 clk |
| 3 | IPv4/TCP min frame | SOF3 | SOF3 = SOF2 alignment |
| 4 | IPv4/UDP | SOF1 | UDP proto=0x11, sport=5000, dport=53 |
| 9 | ARP broadcast | SOF1 | DMAC=FF:FF:FF:FF:FF:FF, etype=0x0806, no IPv4/L4 |
| 10 | Back-to-back frames | SOF1×2 | Frame transition, different SMAC on 2nd frame |

## Key Design Decisions

1. **Combinational aligned output** — `aligned_d`/`aligned_v` are NOT registered in realign module. Following `eth_64b66b.vhd` pattern: input → combinational → downstream register. Saves 1 clk. Combinational path is pure bit selection (wire), no timing risk at 312.5 MHz.

2. **Per-field valid signals** — No single `parsed_v` for all fields. Each group (`mac_dst_v`, `ethertype_v`, `ipv4_v`, `l4_ports_v`) fires independently as soon as data is available. Critical for low-latency systems where downstream can start MAC lookup at T+1 without waiting for L4 parsing at T+5.

3. **Direct 66-bit block parsing** — No XGMII conversion (saves 1 clk vs `eth_64b66b` decoder path). Byte extraction directly from block payload bits.

4. **Parallel VLAN decode** — VLAN detection at EtherType position, branches for 0/1/2 tags processed in the same word counter without extra pipeline stages.

## Byte Order in 66-bit Blocks

Within a DATA block's 64-bit payload `[65:2]`:
- `bits[9:2]` = byte 0 = first byte on wire (e.g., DMAC[0])
- `bits[65:58]` = byte 7 = 8th byte on wire

In `make_data(b7, b6, b5, b4, b3, b2, b1, b0)`:
- b0 → bits[9:2] (first on wire)
- b7 → bits[65:58] (last on wire)

Multi-byte field extraction uses `ntohs()` / `extract16()` / `extract32()` to swap to network byte order.

## Design Origin

Patterns extracted from fibres_proj_v2 (E-band 10G backhaul):
- `rsi.vhd` L330: `rxrsi_din <= descrambled_d(33:2) & descrambled_d_1(65:34)` — barrel shift for unaligned SOF
- `eth_txhold.vhd` L181-254: parallel decode pipelines (cdl1/2/3) for VLAN/IPv4/IPv6 EtherType detection
- `eth_64b66b.vhd` L90-93: combinational output pattern — `xgmii_rxd <= dec_data` with 1-clk registered output, no intermediate pipeline
- `eth_rxfifo.vhd` L206-209: SOF1/SOF2/SOF3 detection from sync code + block type

## Current Progress (2026-04-04)

### Completed This Session

1. **SOF2/SOF3 distinct test vectors** — Tests 2 and 3 now use unique MAC/IP/port data (DEADBEEF0001 for SOF2, 001122334455 for SOF3) for clear waveform identification. All SOF types verified correct with expected latency.

2. **L2 check module** (`eth_l2_check.vhd`) — MAC address filtering (station MAC + broadcast accept), frame length validation (runt <64B, jumbo >max), per-frame `l2_good`/`l2_bad` verdicts.

3. **FCS CRC-32 check** (`eth_fcs_bridge.vhd` + `eth_fcs.vhd`) — Adapted slice-by-8 CRC-32 from fibres_proj_v2. Bridge converts 66-bit blocks to din/din_v for CRC module. Runs on parallel path (no impact on parsing latency). Verified: test 11 good FCS → `fcs_good=1`, test 12 corrupted FCS → `fcs_bad=1`.

4. **Vivado implementation** — 1110 LUT, 952 FF, 0 BRAM, 0 DSP. Timing MET: WNS +0.229 ns @ 312.5 MHz (OOC mode, xcvu11p). Reports in `impl_out/`.

5. **UVM testbench** (16 files in `uvm_test/`) — Full UVM environment with constrained-random stimulus, self-checking scoreboard, functional coverage. Compile+elaborate 0 errors.

### UVM Test Results

| Test | Result | Scoreboard |
|------|--------|------------|
| `eth_basic_ipv4_tcp_test` | PASS | 1 match, 0 mismatch |
| `eth_basic_ipv4_udp_test` | PASS | 1 match, 0 mismatch |
| `eth_good_fcs_test` | PASS | 1 match, 0 mismatch |
| `eth_back_to_back_test` | PASS | 5 matches, 0 mismatches |
| `eth_bad_fcs_test` | BLOCKED | XSIM 2022.2 randomize hang on constraint override |
| `eth_mac_mismatch_test` | BLOCKED | Same XSIM randomize issue |

### Known Issues

- **XSIM constrained randomization** — XSIM 2022.2 hangs when inline `randomize() with {}` overrides soft constraints in certain patterns (inject_fcs_error, non-default MAC). Fix: set fields procedurally after randomize, or use Questa/VCS.
- **SOF2/SOF3 UVM driver** — Barrel-shift encoding implemented but not yet validated in UVM (works in VHDL testbench).
- **ARP/non-IP UVM test** — Hangs on XSIM randomize with `is_ipv4==0` constraint override.

### Implementation Resources

| Module | LUT | FF | Notes |
|--------|-----|-----|-------|
| realign_inst | 138 | 41 | SOF detect + barrel shift |
| extract_inst | 55 | 550 | Header field extraction |
| l2_check_inst | 26 | 38 | MAC filter + frame length |
| fcs_bridge_inst | 169 | 76 | Block → din/din_v |
| fcs_inst | 725 | 247 | CRC-32 (8 ROM tables as SRLs) |
| **Total** | **1110** | **952** | WNS +0.229 ns @ 312.5 MHz |

### Git

Pushed to https://github.com/hij1218/eth_header_parser (private).

## Next Steps

- [ ] Fix UVM XSIM randomize hangs (procedural field setting instead of constraint override)
- [ ] Validate SOF2/SOF3 barrel-shift encoding in UVM driver
- [ ] Add VLAN-tagged test vectors (UVM sequences exist, need constraint debug)
- [ ] Add IPv6 test vectors
- [ ] Add runt frame / jumbo frame / parse_error tests
- [ ] Run UVM random stress test (50+ frames)
- [ ] Integration with order book / matching engine downstream
