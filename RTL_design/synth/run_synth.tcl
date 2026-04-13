# run_synth.tcl — Automated synthesis for one configuration
# Usage: dc_shell -f synth/run_synth.tcl -x "set NQ 16; set QD 64"
# Must be run from RTL_design/ directory

if {![info exists NQ]} { set NQ 16 }
if {![info exists QD]} { set QD 64 }

set TAG "${NQ}_${QD}"

puts "===== Synthesizing IO-Uncore: NQ=$NQ QD=$QD ====="

# Analyze all sources
analyze -format verilog {
    src/credit_manager.v
    src/stat_counters.v
    src/sram_arbiter.v
    src/db_coalescer.v
    src/cq_engine.v
    src/sq_engine.v
    src/mmio_decoder.v
    src/io_uncore_top.v
}

# Elaborate with parameter overrides
elaborate io_uncore_top -parameters "NUM_QUEUES=$NQ, QUEUE_DEPTH=$QD, CREDITS_MAX=$QD, BATCH_N=8, BATCH_T=1000, COALESCE_B=4, COALESCE_T=100, SRAM_ADDR_WIDTH=20, SRAM_DEPTH=1048576"

# Apply constraints
source synth/constraints.tcl

# Check design
check_design

# Compile with clock gating
compile_ultra -gate_clock
compile_ultra -incremental

# Reports
file mkdir reports
report_timing -max_paths 10 > reports/timing_${TAG}.rpt
report_area -hierarchy       > reports/area_${TAG}.rpt
report_power -analysis_effort high > reports/power_${TAG}.rpt
report_qor                   > reports/qor_${TAG}.rpt

# Export netlist
file mkdir netlists
write -format verilog -hierarchy -output netlists/io_uncore_${TAG}.v
write_sdc netlists/io_uncore_${TAG}.sdc

puts "===== Synthesis complete: NQ=$NQ QD=$QD ====="
puts "Reports in: reports/*_${TAG}.rpt"

exit
