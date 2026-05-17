# constraints.sdc — IO-Uncore timing constraints @ 1 GHz
# Used by run_sta.tcl with OpenSTA.
# ASAP7 Liberty time_unit is 1 ps, so all values below are in picoseconds.

if {[info exists ::env(CLK_PERIOD_OVERRIDE)]} {
    set CLK_PERIOD [expr {double($::env(CLK_PERIOD_OVERRIDE))}]
} else {
    set CLK_PERIOD 1000.0         ;# 1 ns = 1 GHz target
}
set IO_DLY     [expr $CLK_PERIOD * 0.20]
set CLK_UNCERT 50.0
set CLK_TRAN   20.0

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty $CLK_UNCERT [get_clocks clk]
set_clock_transition  $CLK_TRAN  [get_clocks clk]

# Reset is asynchronous; do not constrain
set_false_path -from [get_ports rst_n]

# I/O delays: 20% of clock period
# OpenSTA forbids set_input_delay on the port that hosts the clock; iterate per-port.
foreach p [get_ports *] {
  set pname [get_property $p name]
  if {$pname eq "clk"} { continue }
  if {[get_property $p direction] eq "input"} {
    set_input_delay $IO_DLY -clock clk $p
  } else {
    set_output_delay $IO_DLY -clock clk $p
  }
}

# Drive / load assumptions for boundary cells
set_driving_cell -lib_cell INVx1_ASAP7_75t_R -pin Y [all_inputs]
set_load 0.010 [all_outputs]
