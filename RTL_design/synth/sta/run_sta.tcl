# run_sta.tcl — OpenSTA timing + power analysis for IO-Uncore
# Usage: NQ=16 QD=64 sta -no_init -no_splash -exit synth/sta/run_sta.tcl
# Reports go to reports/sta_<NQ>_<QD>_*.rpt

if {[info exists ::env(NQ)]} { set NQ $::env(NQ) } else { set NQ 16 }
if {[info exists ::env(QD)]} { set QD $::env(QD) } else { set QD 64 }
if {[info exists ::env(CLK_PERIOD_PS)]} {
    set ::env(CLK_PERIOD_OVERRIDE) $::env(CLK_PERIOD_PS)
}
set TAG "${NQ}_${QD}"

puts "===== OpenSTA: IO-Uncore NQ=$NQ QD=$QD ====="

# ASAP7 standard-cell + SRAM stub libraries
read_liberty lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib
read_liberty lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib
read_liberty lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
read_liberty synth/sta/sram_macro_stub.lib

# Mapped netlist (gate-level)
read_verilog netlists/io_uncore_${TAG}.v
link_design io_uncore_top

# Constraints
read_sdc synth/sta/constraints.sdc

# Timing reports
report_checks -path_delay max -fields {slew cap nets} -digits 3                \
              -group_count 1 -endpoint_count 1                                  \
              > reports/sta_${TAG}_timing_max.rpt
report_checks -path_delay min -fields {slew cap nets} -digits 3                \
              -group_count 1 -endpoint_count 1                                  \
              > reports/sta_${TAG}_timing_min.rpt
report_check_types -max_slew -max_capacitance -violators -digits 3              \
              > reports/sta_${TAG}_violators.rpt
report_wns                                                                       \
              > reports/sta_${TAG}_wns.rpt
report_tns                                                                       \
              > reports/sta_${TAG}_tns.rpt

# Power: with no activity file, OpenSTA uses default activity 0.10
# This gives leakage exactly + a coarse dynamic estimate
report_power -digits 4 > reports/sta_${TAG}_power.rpt

# Cell-instance count (sanity vs Yosys stat)
set num_inst [llength [get_cells *]]
puts "InstanceCount: $num_inst"

puts "===== STA complete: NQ=$NQ QD=$QD ====="
puts "Reports: reports/sta_${TAG}_*.rpt"
