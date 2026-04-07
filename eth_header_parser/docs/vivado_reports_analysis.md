# Vivado 综合与实现报告深度分析

> **项目**: eth_header_parser (10GBASE-R 超低延迟以太网头解析器)
> **器件**: xcvu11p-fsgd2104-2-e (Virtex UltraScale+)
> **时钟**: 500 MHz (2.0 ns)
> **工具**: Vivado 2024.2
> **综合策略**: Flow_PerfOptimized_high (OOC)
> **实现策略**: Performance_ExplorePostRoutePhysOpt
> **分析日期**: 2026-04-07

---

## 目录

1. [报告总览与分类](#1-报告总览与分类)
2. [综合阶段报告详解](#2-综合阶段报告详解)
3. [实现阶段报告详解](#3-实现阶段报告详解)
4. [优化价值矩阵](#4-优化价值矩阵)
5. [关键优化建议](#5-关键优化建议)
6. [报告阅读优先级指南](#6-报告阅读优先级指南)

---

## 1. 报告总览与分类

### 1.1 综合阶段报告 (synth_3/)

| 报告文件 | 大小 | 内容概述 | 优化价值 |
|----------|------|----------|----------|
| `runme.log` | 37 KB | 综合过程日志：FSM编码、RAM/ROM/SRL映射、警告信息、单元统计 | ★★★★★ |
| `*_utilization_synth.rpt` | 11 KB | 综合后资源利用率：LUT/FF/BRAM/DSP/CARRY8 | ★★★★☆ |
| `synth_timing.rpt` (impl_out/) | 19 KB | 综合后时序估算：WNS/WHS/关键路径（布局前） | ★★★☆☆ |
| `synth_utilization.rpt` (impl_out/) | 11 KB | 综合后优化资源统计（与 synth.rpt 对比看优化效果） | ★★★☆☆ |

### 1.2 实现阶段报告 (impl_3/)

| 报告文件 | 大小 | 内容概述 | 优化价值 |
|----------|------|----------|----------|
| `*_timing_summary_postroute_physopted.rpt` | 186 KB | **最终时序结果**：WNS/TNS/WHS/THS + 详细路径 | ★★★★★ |
| `*_timing_summary_routed.rpt` | 187 KB | 布线后时序（post-route physopt 前） | ★★★★☆ |
| `*_utilization_placed.rpt` | 17 KB | **最终资源利用率**：分层级 LUT/FF/BRAM/DSP | ★★★★★ |
| `*_methodology_drc_routed.rpt` | 124 KB | 方法学检查：时序约束完整性、设计规则违规 | ★★★★☆ |
| `*_control_sets_placed.rpt` | 11 KB | 控制集分析：CE/RST 信号分组、FF 打包效率 | ★★★☆☆ |
| `*_power_routed.rpt` | 9 KB | 功耗分析：动态/静态功耗、模块级功耗分布 | ★★★☆☆ |
| `*_clock_utilization_routed.rpt` | 48 KB | 时钟资源：BUFG/PLL/MMCM 使用、时钟域 | ★★☆☆☆ |
| `*_drc_routed.rpt` | 2 KB | 设计规则检查：布线后 DRC 违规 | ★★☆☆☆ |
| `*_drc_opted.rpt` | 1.4 KB | 优化后 DRC 检查 | ★☆☆☆☆ |
| `*_bus_skew_*.rpt` | 1.3 KB | 总线偏斜分析（需手动定义总线约束） | ★☆☆☆☆ |
| `*_route_status.rpt` | 0.7 KB | 布线状态：全部网络是否完成布线 | ★★☆☆☆ |
| `*_io_placed.rpt` | 741 KB | I/O 引脚分配（OOC 模式下不适用） | ★☆☆☆☆ |
| `runme.log` | 92 KB | 实现过程日志：各阶段耗时、优化迭代 | ★★★☆☆ |

### 1.3 手动导出报告 (impl_out/)

| 报告文件 | 大小 | 内容概述 | 优化价值 |
|----------|------|----------|----------|
| `impl_timing.rpt` | 209 KB | 完整时序报告（含所有路径组详情） | ★★★★★ |
| `impl_critical_paths.rpt` | 63 KB | **前 N 条关键路径**：逻辑级数、延迟分解 | ★★★★★ |
| `impl_utilization_hier.rpt` | 2.5 KB | **分模块资源**：每个子模块 LUT/FF/SRL 统计 | ★★★★★ |
| `impl_control_sets.rpt` | 9 KB | 控制集详细列表（含扇出统计） | ★★★☆☆ |

---

## 2. 综合阶段报告详解

### 2.1 runme.log — 综合日志 ★★★★★

**这是综合阶段最有价值的报告**，包含 Vivado 综合引擎的所有决策和诊断信息。

#### 2.1.1 FSM 编码报告

```
FSM 编码决策：
- eth_hdr_realign / state : one-hot 编码
- eth_fcs / state : one-hot 编码
```

**作用**: 显示 Vivado 为每个状态机选择的编码方式。UltraScale+ 上 one-hot 编码通常最优（LUT6 架构天然适合 one-hot 解码）。若状态数 > 16，可能需要考虑 gray 或 binary 编码以节省 FF。

**优化方向**: 如果 FSM 状态数少（<5），检查是否 one-hot 反而浪费 FF；可通过 `(* fsm_encoding = "sequential" *)` 属性覆盖。

#### 2.1.2 RAM/ROM/SRL 映射报告

```
已映射资源：
- fcs_bridge_inst/fifo_mem_reg : 128 x 72-bit → RAM64M8 x 22 (分布式 RAM)
- CRC ROM 表 : 未映射为 BRAM（rom_style="distributed" 属性生效）
- SRL16E : 64 个移位寄存器单元
```

**作用**: 显示 Vivado 将 RTL 中的数组/常量映射为何种硬件原语。这是**资源优化最关键的检查点**。

**优化方向**:
| 映射结果 | 是否正确 | 优化建议 |
|----------|---------|----------|
| 128x72 → 分布式 RAM | ✓ 正确 | 深度 >64 通常用 BRAM，但此处宽度/深度比适合分布式 |
| CRC ROM → 分布式 LUT | ✓ 正确 | 避免 BRAM 的 1.1ns clock-to-out 延迟 |
| 移位寄存器 → SRL16E | ✓ 正确 | 比 FF 链节省面积 |
| 数组 >64 深在分布式 RAM | ⚠ 注意 | VP-MEM2 规则：>64 深应检查是否应为 BRAM |

#### 2.1.3 综合警告（Synth 8-xxxx）

| 消息代码 | 含义 | 本项目情况 | 优化建议 |
|----------|------|------------|----------|
| Synth 8-7079 | 多线程综合启动 | 7 进程 | 正常 |
| Synth 8-7080 | 不满足并行综合条件 | — | 模块太小，无影响 |
| Synth 8-3332 | 顺序元件被移除 | raw_etype_reg, frame_len_i_reg | 死代码，可清理 RTL |
| Synth 8-3331 | 端口无负载 | blk_d 在 l2_check 中 66+ 警告 | 接口设计可优化 |
| **Synth 8-7052** | **BRAM 缺少输出寄存器** | 本项目无 | 若出现，需加 BRAM 输出寄存器 |
| **Synth 8-4767** | **RAM 推断信息** | 128x72 分布式 RAM | 确认映射正确 |

#### 2.1.4 关键提取命令

```bash
# 快速提取综合日志关键信息
grep -A30 "DSP Final Report" runme.log | head -40
grep -B1 -A3 "Implemented As" runme.log | head -30
grep "Synth 8-7052\|Synth 8-4767\|Synth 8-113\|Synth 8-3332" runme.log
grep -E "CARRY8|DSP48|SRL16|SRLC32" runme.log | grep "^|" | tail -10
```

---

### 2.2 utilization_synth.rpt — 综合后资源 ★★★★☆

**本项目综合后资源统计**:

| 资源类型 | 使用量 | 可用量 | 利用率 |
|----------|--------|--------|--------|
| CLB LUT (总计) | 1,610 | 1,296,000 | 0.12% |
| - LUT 逻辑 | 1,442 | — | — |
| - LUT 分布式 RAM | 168 | 593,280 | 0.03% |
| CLB 寄存器 | 1,569 | 2,592,000 | 0.06% |
| CARRY8 | 15 | 162,000 | <0.01% |
| Block RAM | 0 | 2,016 | 0.00% |
| DSP | 0 | 9,216 | 0.00% |

**作用**: 提供综合后的资源估算。**注意**：此数值高于最终实现值，因为布局优化会合并 LUT、移除冗余逻辑。

**关键观察**:
- RAMD64E x 168 → FIFO 的 128x72 分布式 RAM（22 个 RAM64M8 单元）
- FDRE x 1,532 / FDSE x 37 → 寄存器分布合理
- 无 DSP/BRAM 使用 → 纯 LUT/FF 设计

**⚠ 综合资源 vs 实现资源差异**:

| 指标 | 综合后 | 实现后 | 变化 |
|------|--------|--------|------|
| LUT | 1,610 | 1,426 | -11.4% (优化合并) |
| FF | 1,569 | 1,569 | 0% (无变化) |
| CARRY8 | 15 | 15 | 0% |

**结论**: 综合资源高估约 10-15%，以实现后数据为准。

---

### 2.3 synth_timing.rpt — 综合后时序估算 ★★★☆☆

**作用**: 提供布局前的时序估算。**布线延迟为估算值**，不如实现后精确，但可早期发现严重时序问题。

**本项目综合后时序** (312.5 MHz 约束下):

| 指标 | 值 | 状态 |
|------|-----|------|
| WNS (建立时间) | -0.055 ns | ⚠ 违规 |
| TNS | -0.166 ns | 6 个失败端点 |
| WHS (保持时间) | -0.135 ns | ⚠ 违规 |
| THS | -76.887 ns | 854 个失败端点 |

**重要说明**: 综合后时序违规是**正常的**，特别是保持时间违规。布局布线后，Vivado 会通过插入缓冲器和优化布局来修复保持时间。**只有建立时间违规需要关注**，且需看实现后最终结果。

**关键路径分析**:
```
最差建立路径: fcs_inst/slice_reg[0] → crc_reg_reg[24]
  数据延迟: 3.045 ns (逻辑 0.796 ns + 布线估算 2.249 ns)
  逻辑级数: 12 级 LUT
  裕量: -0.055 ns
```

**优化方向**: 12 级 LUT 是 CRC 反馈环路的组合逻辑深度。在我们的 500 MHz 实现中，已通过流水线寄存器将其拆分为两级。

---

## 3. 实现阶段报告详解

### 3.1 timing_summary_postroute_physopted.rpt — 最终时序 ★★★★★

**这是整个设计流程中最重要的报告**。所有优化决策的最终验证都依赖此报告。

**本项目最终时序** (500 MHz):

| 指标 | 值 | 状态 |
|------|-----|------|
| WNS (建立时间) | **+0.018 ns** | ✅ 满足 |
| TNS | 0.000 ns | ✅ 无违规 |
| WHS (保持时间) | +0.023 ns | ✅ 满足 |
| THS | 0.000 ns | ✅ 无违规 |
| WPWS (脉冲宽度) | +0.468 ns | ✅ 满足 |
| 失败端点 | **0** / 4,322 | ✅ 全部通过 |

#### 报告结构详解

**第一部分：设计时序总结 (Design Timing Summary)**
```
WNS(ns)  TNS(ns)  TNS Failing  WHS(ns)  THS(ns)  THS Failing  WPWS(ns)
0.018    0.000    0            0.023    0.000    0            0.468
```
- **WNS** (Worst Negative Slack): 最差建立时间裕量。正值=满足，负值=违规
- **TNS** (Total Negative Slack): 所有违规路径的裕量总和
- **WHS** (Worst Hold Slack): 最差保持时间裕量
- **WPWS** (Worst Pulse Width Slack): 最差脉冲宽度裕量

**第二部分：各时钟域时序**
```
Clock  WNS    TNS    Failing  WHS    THS    Failing
clk    0.018  0.000  0        0.023  0.000  0
```

**第三部分：路径详情 (Max Delay Paths)**

每条路径包含：
```
Slack:          0.018 ns (满足)
Source:         fcs_inst/crc_reg_reg[15]/C    (源寄存器)
Destination:    fcs_inst/bad_fcs_reg/D         (目标寄存器)
Path Group:     clk                            (时钟域)
Requirement:    2.000 ns                       (时钟周期)
Data Path Delay: 1.772 ns                     (数据路径延迟)
  Logic:        0.573 ns (32.3%)               (逻辑延迟)
  Route:        1.199 ns (67.7%)               (布线延迟)
Logic Levels:   6 (CARRY8=2, LUT5=1, LUT6=3) (逻辑级数)
Clock Skew:     -0.008 ns                     (时钟偏斜)
Clock Uncertainty: 0.227 ns                   (时钟不确定性)
```

**优化方向**:
| 指标 | 诊断 | 优化方法 |
|------|------|----------|
| Logic > 50% | 逻辑过深 | 加流水线寄存器、拆分组合逻辑 |
| Route > 70% | 布线拥塞 | 改善布局约束、添加 Pblock |
| Logic Levels > 8 | 组合深度过大 | 重新划分模块、插入寄存器 |
| Clock Uncertainty > 0.3 ns | 时钟质量差 | 检查 PLL/MMCM 配置 |

---

### 3.2 utilization_placed.rpt — 最终资源利用率 ★★★★★

**作用**: 实现后的精确资源统计，是**资源优化的权威数据源**。

**本项目资源统计**:

| 资源 | 使用量 | 可用量 | 利用率 |
|------|--------|--------|--------|
| CLB LUT | 1,426 | 1,296,000 | 0.11% |
| - LUT 逻辑 | 1,258 | — | — |
| - LUT 分布式 RAM | 168 | — | — |
| CLB 寄存器 | 1,569 | 2,592,000 | 0.06% |
| CARRY8 | 15 | 162,000 | <0.01% |
| Block RAM | 0 | 2,016 | 0.00% |
| DSP | 0 | 9,216 | 0.00% |

#### 报告关键章节

1. **CLB Logic** — LUT 和 FF 的详细分类（逻辑/RAM/移位寄存器/MUX）
2. **BLOCKRAM** — BRAM18/BRAM36/URAM 使用情况
3. **ARITHMETIC** — DSP48E2 使用情况
4. **I/O** — IOB 使用（OOC 模式下为 0）
5. **CLOCK** — 时钟缓冲器使用
6. **ADVANCED** — PCIE/GT/SYSCLK 等高级原语
7. **CONFIGURATION** — 配置逻辑
8. **Primitives** — 原语级统计

#### 原语分布 (本项目)

| 原语 | 数量 | 用途 |
|------|------|------|
| FDRE | 1,532 | 同步复位触发器（主力） |
| LUT6 | 697 | 6 输入查找表 |
| LUT5 | 279 | 5 输入查找表 |
| LUT3 | 232 | 3 输入查找表 |
| RAMD64E | 168 | 分布式 RAM (FIFO) |
| LUT4 | 130 | 4 输入查找表 |
| LUT2 | 100 | 2 输入查找表 |
| FDSE | 37 | 同步置位触发器 |
| CARRY8 | 15 | 进位链（比较器/加法器） |

---

### 3.3 impl_utilization_hier.rpt — 分模块资源 ★★★★★

**作用**: **优化的首要参考**。显示每个子模块的资源消耗，直接定位优化热点。

**本项目分模块统计**:

| 模块 | LUT | LUT逻辑 | LUTRAM | SRL | FF | 占比 |
|------|-----|---------|--------|-----|-----|------|
| **fcs_inst** | **725** | 693 | 0 | 32 | 247 | **65% LUT** |
| fcs_bridge_inst | 169 | 169 | 0 | 0 | 76 | 15% |
| realign_inst | 138 | 138 | 0 | 0 | 41 | 12% |
| extract_inst | 55 | 55 | 0 | 0 | 550 | 5% LUT, **58% FF** |
| l2_check_inst | 26 | 26 | 0 | 0 | 38 | 2% |

**关键发现**:
- `fcs_inst` 消耗 65% 的 LUT → CRC-32 计算是资源热点
- `extract_inst` 仅 55 LUT 但 550 FF → 大量头部字段寄存器（正常）
- `l2_check_inst` 极小（26 LUT） → MAC 过滤非常轻量

**优化优先级**: fcs_inst > fcs_bridge_inst > realign_inst

---

### 3.4 impl_critical_paths.rpt — 关键路径详情 ★★★★★

**作用**: 列出前 N 条最差路径的完整延迟分解，是**时序优化的核心依据**。

**本项目前 3 条关键路径** (312.5 MHz 约束下):

| 排名 | 裕量 | 源 → 目标 | 数据延迟 | 逻辑/布线比 | 逻辑级数 |
|------|------|-----------|----------|------------|----------|
| 1 | +0.229 ns | fcs/crc_reg[26] → crc_reg[15] | 2.761 ns | 44% / 56% | 11 级 |
| 2 | +0.260 ns | fcs/pipe_reg[2][21] → crc_reg[25] | 2.728 ns | 37% / 63% | 混合 |
| 3 | +0.275 ns | fcs/slice_reg[0] → crc_reg[19] | 2.715 ns | 39% / 61% | 混合 |

**分析**: 所有关键路径都在 `fcs_inst`（CRC-32 反馈环路）。布线延迟占 56-63%，说明逻辑已经优化到位，瓶颈在互连布线。

---

### 3.5 methodology_drc_routed.rpt — 方法学检查 ★★★★☆

**作用**: 检查设计约束的完整性和最佳实践遵循情况。

**本项目违规统计**:

| 违规类型 | 代码 | 数量 | 严重程度 | 含义 |
|----------|------|------|----------|------|
| 无输入延迟约束 | TIMING-18 | 68 | Warning | 输入端口未定义时序 |
| 无输出延迟约束 | TIMING-18 | 596 | Warning | 输出端口未定义时序 |
| **总计** | — | **664** | Warning | — |

**说明**: OOC（Out-of-Context）模式下，I/O 延迟约束通常不添加，因为顶层集成时会统一约束。这些警告在 OOC 模式下是**预期行为**，不影响内部时序分析的正确性。

**⚠ 需要关注的检查项** (本项目未出现，但应知道):
| 检查 | 含义 | 严重程度 |
|------|------|----------|
| TIMING-6 | 无时钟约束的端点 | 严重 |
| TIMING-7 | 未约束的跨时钟域路径 | 严重 |
| TIMING-16 | 大建立时间违规 | 严重 |
| TIMING-17 | 大保持时间违规 | 中等 |
| TIMING-56 | 大脉冲宽度违规 | 中等 |

---

### 3.6 control_sets_placed.rpt — 控制集分析 ★★★☆☆

**作用**: 分析时钟使能 (CE) 和复位 (RST) 信号的分组，影响 FF 打包效率。

**本项目**: 45 个控制集

**什么是控制集**? 每个 Slice 中的 FF 必须共享相同的 CLK + CE + RST 组合。控制集过多会导致 Slice 利用率低下（FF 空位）。

**优化阈值**:
| 控制集数量 | 评估 |
|------------|------|
| < 50 | 良好 |
| 50-100 | 可接受 |
| 100-500 | 需关注 |
| > 500 | 需优化（合并 CE/RST） |

**本项目 45 个控制集** → **良好**，无需优化。

**如果需要优化**:
- 合并相似的 CE 信号
- 使用 `(* DONT_TOUCH = "yes" *)` 防止 CE 信号被优化掉
- 减少异步复位的使用

---

### 3.7 power_routed.rpt — 功耗分析 ★★★☆☆

**作用**: 估算芯片功耗，用于散热设计和电源规划。

**本项目功耗**:

| 类别 | 功耗 | 占比 |
|------|------|------|
| 动态功耗 | 0.137 W | 6% |
| 静态功耗 | 2.201 W | 94% |
| **总计** | **2.338 W** | 100% |

**模块级动态功耗**:
| 模块 | 功耗 | 占动态总功耗 |
|------|------|-------------|
| fcs_inst | 70 mW | 51% |
| fcs_bridge_inst | 42 mW | 31% |
| extract_inst | 17 mW | 12% |
| realign_inst | 7 mW | 5% |

**说明**: 设计利用率极低（<0.2%），静态功耗占绝对主导。动态功耗 137 mW 在 500 MHz 下非常低。

**置信度**: Medium（缺少完整的翻转率仿真数据）。精确功耗需要通过 SAIF 文件提供信号翻转率。

---

### 3.8 clock_utilization_routed.rpt — 时钟资源 ★★☆☆☆

**作用**: 显示时钟缓冲器、PLL、MMCM 等时钟资源的使用情况。

**本项目**: 单时钟域，无全局时钟原语使用（OOC 模式下由上层分配）。

**多时钟设计需关注**:
- BUFGCE/BUFGCTRL 数量（全局时钟缓冲器有限）
- PLL/MMCM 使用（每个时钟区域有限）
- 跨时钟域路径

---

### 3.9 route_status.rpt — 布线状态 ★★☆☆☆

**作用**: 确认所有网络是否完成布线。

**本项目**:
```
总逻辑网络: 3,286
  已布线:     2,170
  内部布线:   482 (不需要物理布线)
  无负载:     24
  布线错误:   0
```

**关键检查**: `布线错误 = 0` → ✅ 设计完全布线成功

**⚠ DRC 警告** (RTSTAT-10): 541 个网络无可布线负载 → OOC 模式下输出端口未连接到 IOB，预期行为。

---

### 3.10 drc_routed.rpt — 设计规则检查 ★★☆☆☆

**作用**: 检查物理设计规则违规。

**本项目**: 仅 OOC 相关 DRC → 无实质问题。

**严重 DRC 类型** (本项目未出现):
| DRC 代码 | 含义 | 影响 |
|----------|------|------|
| HDOOC-3 | OOC 模块不允许生成比特流 | 预期（OOC 模式） |
| NSTD-1 | 非标准时钟树 | 可能影响时序 |
| UCIO-1 | 未约束的 I/O | 影响信号完整性 |
| DPOP-1 | DSP 级联断开 | 影响性能 |

---

### 3.11 bus_skew_*.rpt — 总线偏斜 ★☆☆☆☆

**作用**: 分析总线信号之间的时序偏斜。需要手动定义 `set_bus_skew` 约束才有意义。

**本项目**: 无总线偏斜约束 → 报告为空。

---

## 4. 优化价值矩阵

| 优化目标 | 主要报告 | 辅助报告 | 查看内容 |
|----------|---------|---------|----------|
| **时序收敛** | timing_summary_postroute_physopted | critical_paths, synth_timing | WNS, 逻辑级数, 延迟分解 |
| **资源缩减** | utilization_hier | utilization_placed, synth utilization | 模块级 LUT/FF, 原语分布 |
| **RAM/ROM 优化** | runme.log (综合) | utilization_placed | "Implemented As" 映射, BRAM vs 分布式 |
| **功耗优化** | power_routed | utilization_hier | 模块级功耗, 翻转率 |
| **时钟优化** | clock_utilization | methodology_drc | 时钟缓冲器, 跨域路径 |
| **FF 打包效率** | control_sets_placed | utilization_placed | CE/RST 分组, Slice 利用率 |
| **约束完整性** | methodology_drc | timing_summary | TIMING-18 缺失约束 |
| **设计规则** | drc_routed | route_status | 物理违规, 布线完成度 |

---

## 5. 关键优化建议

### 5.1 从报告中提取优化信号

| 报告中的发现 | 严重程度 | 修复方法 |
|-------------|---------|---------|
| DSP 数量 < 预期 | 高 | 添加 `attribute use_dsp : signal is "yes"` |
| DSP 缺少 AREG/MREG | 高 | 移除外部 FF，使用 DSP 内部寄存器 (VP-DSP9) |
| CARRY8 数量高 | 高 | 将加减法移入 DSP PCOUT→PCIN 级联 |
| 数组 >64 在分布式 RAM | 中 | 添加 `attribute ram_style : signal is "block"` |
| 数组 ≤64 在 BRAM | 中 | 添加 `attribute ram_style : signal is "distributed"` |
| 宽浅 RAM 在 BRAM (width/depth>20) | 高 | 强制分布式（VP-MEM3 拥塞规则） |
| Synth 8-7052 缺少输出寄存器 | 中 | 在 BRAM 读后添加寄存器级 |
| WNS 为负 | 高 | 参考 TIMING-16 路径 → 添加流水线寄存器 |
| TIMING-16 建立违规 | 高 | 在源→目标之间插入寄存器 |
| 控制集 > 100 | 低 | 合并 CE/RST 信号 |
| SRL 被复位阻止 | 中 | 移除移位寄存器的同步复位 |

### 5.2 本项目具体优化空间

1. **WNS 裕量极小 (+0.018 ns)** → 如需更高频率，CRC 比较路径（6 级 CARRY8+LUT）需进一步流水线化
2. **缺失 I/O 约束 (664 个)** → 集成到顶层时需添加 `set_input_delay` / `set_output_delay`
3. **fcs_inst 占 65% LUT** → 如需缩减面积，可考虑共享 CRC ROM 表或使用 BRAM（牺牲时序）
4. **死代码 (raw_etype_reg)** → 可清理 RTL 中未使用的信号

---

## 6. 报告阅读优先级指南

### 6.1 日常开发（每次综合/实现后必看）

```
1. timing_summary_postroute_physopted.rpt  →  WNS/TNS 是否满足？
2. utilization_placed.rpt                   →  资源是否在预算内？
3. runme.log (综合)                         →  RAM/ROM/SRL 映射正确？
```

### 6.2 时序不满足时

```
1. timing_summary → 确认 WNS 差距大小
2. critical_paths → 定位具体路径和模块
3. methodology_drc → 检查是否有缺失约束
4. runme.log → 检查 LUT 级数、ROM 映射
```

### 6.3 资源超预算时

```
1. utilization_hier → 定位消耗最多的模块
2. runme.log → 检查 RAM/ROM 映射是否正确
3. control_sets → 检查 FF 打包效率
4. utilization_placed → 检查原语分布
```

### 6.4 快速检查命令（适用于任何 Vivado 项目）

```bash
# 综合日志关键提取 (~140 行)
grep -A30 "DSP Final Report" runme.log | head -40
grep -B1 -A3 "Implemented As" runme.log | head -30
grep "Synth 8-7052\|Synth 8-4767\|Synth 8-113" runme.log

# 实现报告关键提取
grep -E "CLB LUT|CLB Reg|DSP48|Block RAM" *_utilization_placed.rpt | head -6
grep -A2 "WNS.*TNS" *_timing_summary_*.rpt | head -3
grep -A3 "TIMING-16" *_methodology_drc_routed.rpt | head -15
grep "Total control sets" *_control_sets_placed.rpt
```

---

> **总结**: Vivado 综合和实现共生成约 20 份报告。其中**最核心的 5 份**是：
> 1. `runme.log` (综合) — RAM/ROM/SRL 映射 + 警告
> 2. `timing_summary_postroute_physopted.rpt` — 最终时序
> 3. `utilization_placed.rpt` — 最终资源
> 4. `impl_utilization_hier.rpt` — 分模块资源热点
> 5. `impl_critical_paths.rpt` — 关键路径分解
>
> 掌握这 5 份报告的阅读方法，即可完成 90% 的优化工作。
