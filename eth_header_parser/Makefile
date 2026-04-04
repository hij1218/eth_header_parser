# Makefile for eth_header_parser — Vivado XSIM simulation
DESIGN_NAME = eth_hdr_parser
FPGA_PART = xcvu11p-flga2577-2-e

SRC_FILES = \
    src/eth_hdr_parser_pkg.vhd \
    src/eth_hdr_realign.vhd \
    src/eth_hdr_extract.vhd \
    src/eth_hdr_parser_top.vhd

TB_FILE = testbench/eth_hdr_parser_tb.vhd

WORK_DIR = xsim_work
SIM_TIME = 5us

.PHONY: simulate compile elaborate run clean synth

simulate: compile elaborate run

compile:
	@mkdir -p $(WORK_DIR)
	cd $(WORK_DIR) && xvhdl --2008 $(addprefix ../,$(SRC_FILES)) ../$(TB_FILE)

elaborate:
	cd $(WORK_DIR) && xelab -debug typical eth_hdr_parser_tb -s $(DESIGN_NAME)_sim

run:
	cd $(WORK_DIR) && xsim $(DESIGN_NAME)_sim -runall -t ../run.tcl 2>&1 | tee sim.log
	@echo "=== Simulation complete. Check $(WORK_DIR)/sim.log ==="

clean:
	rm -rf $(WORK_DIR) *.jou *.log .Xil

synth:
	@echo "Running synthesis for timing check..."
	vivado -mode batch -source synth.tcl -tclargs $(FPGA_PART)
