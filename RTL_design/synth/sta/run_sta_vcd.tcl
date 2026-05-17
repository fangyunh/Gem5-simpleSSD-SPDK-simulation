# run_sta_vcd.tcl — Activity-aware power using VCD from gate-level sim.
# Usage: NQ=16 QD=64 VCD=/tmp/tb_gate_stim.vcd sta -no_init -no_splash -exit synth/sta/run_sta_vcd.tcl

if {[info exists ::env(NQ)]} { set NQ $::env(NQ) } else { set NQ 16 }
if {[info exists ::env(QD)]} { set QD $::env(QD) } else { set QD 64 }
if {[info exists ::env(VCD)]} { set VCDFILE $::env(VCD) } else { set VCDFILE "/tmp/tb_gate_stim.vcd" }
set TAG "${NQ}_${QD}"

read_liberty lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib
read_liberty lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib
read_liberty lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
read_liberty synth/sta/sram_macro_stub.lib
read_verilog netlists/io_uncore_${TAG}.v
link_design io_uncore_top
read_sdc synth/sta/constraints.sdc

# Read VCD activity. Scope = the DUT inside the testbench.
read_vcd -scope tb_gate_stim/dut $VCDFILE

report_power -digits 4 > reports/sta_${TAG}_power_vcd.rpt
puts "===== Power-VCD complete: NQ=$NQ QD=$QD ====="
puts "Report: reports/sta_${TAG}_power_vcd.rpt"
