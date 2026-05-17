# run_sta_fmax.tcl — Find achievable Fmax for a given NQ/QD config.
# Reads the same libs/netlist as run_sta.tcl, then sweeps clock period
# from coarse (5000 ps) downward until WNS goes negative.

if {[info exists ::env(NQ)]} { set NQ $::env(NQ) } else { set NQ 16 }
if {[info exists ::env(QD)]} { set QD $::env(QD) } else { set QD 64 }
set TAG "${NQ}_${QD}"

read_liberty lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib
read_liberty lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib
read_liberty lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
read_liberty synth/sta/sram_macro_stub.lib
read_verilog netlists/io_uncore_${TAG}.v
link_design io_uncore_top

set CLK_UNCERT 50.0
set CLK_TRAN   20.0

proc test_period {period clk_uncert clk_tran} {
    create_clock -name clk -period $period [get_ports clk]
    set_clock_uncertainty $clk_uncert [get_clocks clk]
    set_clock_transition  $clk_tran  [get_clocks clk]
    set_false_path -from [get_ports rst_n]
    set io_dly [expr $period * 0.20]
    foreach p [get_ports *] {
      set pname [get_property $p name]
      if {$pname eq "clk"} { continue }
      if {[get_property $p direction] eq "input"} {
        set_input_delay $io_dly -clock clk $p
      } else {
        set_output_delay $io_dly -clock clk $p
      }
    }
    set_driving_cell -lib_cell INVx1_ASAP7_75t_R -pin Y [all_inputs]
    set_load 0.010 [all_outputs]
    set wns [sta::worst_slack -max]
    remove_clock [get_clocks clk]
    return $wns
}

# Bisection search: lo = period that meets (initial guess: 20000 ps), hi = period that violates
# Step 1: find a period that meets
set period 10000.0
set wns [test_period $period $CLK_UNCERT $CLK_TRAN]
puts "period=$period ps  wns=$wns"
while {$wns < 0 && $period < 50000.0} {
    set period [expr $period * 1.5]
    set wns [test_period $period $CLK_UNCERT $CLK_TRAN]
    puts "period=$period ps  wns=$wns"
}
if {$wns < 0} {
    puts "FMAX_FAIL: cannot meet timing even at 50 ns period; netlist needs buffering."
    exit 1
}
set lo $period       ;# meets
set hi [expr $period / 1.5]   ;# may violate (last failure)
if {$hi < 100} { set hi 100.0 }

# Bisection
for {set i 0} {$i < 20 && [expr $lo - $hi] > 25.0} {incr i} {
    set mid [expr ($lo + $hi) / 2.0]
    set wns [test_period $mid $CLK_UNCERT $CLK_TRAN]
    puts "period=$mid ps  wns=$wns"
    if {$wns < 0} { set hi $mid } else { set lo $mid }
}
set fmax_mhz [expr 1000000.0 / $lo]
puts "FMAX_RESULT: NQ=$NQ QD=$QD period=$lo ps  fmax=$fmax_mhz MHz"
