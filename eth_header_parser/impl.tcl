# impl.tcl — Non-project mode: synth + impl for timing/resource check
# Usage: vivado -mode batch -source impl.tcl

set design_name    eth_hdr_parser
set fpga_part      xcvu11p-flga2577-2-e
set top_module     eth_hdr_parser_top
set rpt_dir        impl_out

file mkdir $rpt_dir

# ----------------------------------------------------------------
# Read sources
# ----------------------------------------------------------------
read_vhdl -vhdl2008 {
    src/eth_hdr_parser_pkg.vhd
    src/eth_fcs_roms_pkg.vhd
    src/eth_hdr_realign.vhd
    src/eth_hdr_extract.vhd
    src/eth_fcs.vhd
    src/eth_fcs_bridge.vhd
    src/eth_l2_check.vhd
    src/eth_hdr_parser_top.vhd
}
read_xdc constraints.xdc

# ----------------------------------------------------------------
# Synthesis (out-of-context: no I/O buffers)
# ----------------------------------------------------------------
synth_design -top $top_module -part $fpga_part -mode out_of_context \
    -directive AreaOptimized_high

report_utilization -file ${rpt_dir}/synth_utilization.rpt
report_timing_summary -file ${rpt_dir}/synth_timing.rpt
write_checkpoint -force ${rpt_dir}/post_synth.dcp

# ----------------------------------------------------------------
# Implementation
# ----------------------------------------------------------------
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

# ----------------------------------------------------------------
# Reports
# ----------------------------------------------------------------
report_utilization -hierarchical -file ${rpt_dir}/impl_utilization_hier.rpt
report_timing_summary -max_paths 20 -file ${rpt_dir}/impl_timing.rpt
report_timing -max_paths 10 -sort_by group -file ${rpt_dir}/impl_critical_paths.rpt
report_control_sets -verbose -file ${rpt_dir}/impl_control_sets.rpt
write_checkpoint -force ${rpt_dir}/post_impl.dcp

puts "========================================"
puts "Implementation complete!"
puts "Reports in: ${rpt_dir}/"
puts "========================================"

# ----------------------------------------------------------------
# Create project for GUI browsing (import checkpoint)
# ----------------------------------------------------------------
set proj_dir proj_${design_name}
if {[file exists $proj_dir]} {
    file delete -force $proj_dir
}
create_project $design_name $proj_dir -part $fpga_part -force

# Add sources + testbench + constraints
add_files -norecurse {
    src/eth_hdr_parser_pkg.vhd
    src/eth_fcs_roms_pkg.vhd
    src/eth_hdr_realign.vhd
    src/eth_hdr_extract.vhd
    src/eth_fcs.vhd
    src/eth_fcs_bridge.vhd
    src/eth_l2_check.vhd
    src/eth_hdr_parser_top.vhd
}
set_property file_type {VHDL 2008} [get_files *.vhd]
add_files -fileset sim_1 -norecurse testbench/eth_hdr_parser_tb.vhd
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1] *.vhd]
set_property top eth_hdr_parser_tb [get_filesets sim_1]
add_files -fileset constrs_1 -norecurse constraints.xdc
set_property top $top_module [current_fileset]

# Import implemented checkpoint so GUI can browse it
add_files ${rpt_dir}/post_impl.dcp

close_project
