# Makefile for eth_header_parser — Vivado XSIM simulation
DESIGN_NAME = eth_hdr_parser
FPGA_PART = xcvu11p-flga2577-2-e



# Hardware configuration
CLOCK_FREQ = 312.5MHz

CLOCK_UNCERTAINTY = 6%

# Resource targets (from successful implementation)


# Vivado Strategy Configuration
# Synthesis: AreaOptimized_high — ternary adders, BRAM shift regs, aggressive area reduction
# See: .claude/docs/vivado/vivado-synth/SKILL.md for all options
SYNTH_STRATEGY = AreaOptimized_high

# Implementation: Performance_Explore — deep exploration across all stages
# See: .claude/docs/vivado/vivado-impl/SKILL.md for all options
OPT_DIRECTIVE = Explore
PLACE_DIRECTIVE = Explore
PHYS_OPT_DIRECTIVE = Explore
ROUTE_DIRECTIVE = Explore

# Timing constraint options (set to 'yes' to enable detailed I/O timing)
ENABLE_IO_TIMING = no
ENABLE_MULTICYCLE = no
ENABLE_PLACEMENT_CONSTRAINTS = no

# Vivado installation path - modify this to match your installation
VIVADO_PATH ?= /opt/Xilinx/Vivado/2024.2
VIVADO = $(VIVADO_PATH)/bin/vivado

# Project configuration
VIVADO_PROJECT = proj_$(DESIGN_NAME)
DEVICE = $(FPGA_PART)
MATLAB_PATH = /usr/local/MATLAB/R2025a

SRC_FILES = \
    src/eth_hdr_parser_pkg.vhd \
    src/eth_fcs_roms_pkg.vhd \
    src/eth_hdr_realign.vhd \
    src/eth_hdr_extract.vhd \
    src/eth_fcs.vhd \
    src/eth_fcs_bridge.vhd \
    src/eth_l2_check.vhd \
    src/eth_hdr_parser_top.vhd

TB_FILE = testbench/eth_hdr_parser_tb.vhd

WORK_DIR = xsim_work
SIM_TIME = 5us

.PHONY: simulate compile elaborate run clean synth impl open wave

simulate: compile elaborate run

compile:
	@mkdir -p $(WORK_DIR)
	cd $(WORK_DIR) && xvhdl --2008 $(addprefix ../,$(SRC_FILES)) ../$(TB_FILE)

elaborate:
	cd $(WORK_DIR) && xelab -debug typical eth_hdr_parser_tb -s $(DESIGN_NAME)_sim

run:
	cd $(WORK_DIR) && xsim $(DESIGN_NAME)_sim -runall -t ../run.tcl 2>&1 | tee sim.log
	@echo "=== Simulation complete. Check $(WORK_DIR)/sim.log ==="

wave:
	cd $(WORK_DIR) && xsim --gui $(DESIGN_NAME)_sim.wdb &

impl:
	$(VIVADO) -mode batch -source impl.tcl -journal impl.jou -log impl.log 2>&1 | tee impl_console.log

open:
	$(VIVADO) $(VIVADO_PROJECT)/$(DESIGN_NAME).xpr &

clean:
	rm -rf $(WORK_DIR) *.jou *.log .Xil $(VIVADO_PROJECT)
