# constraints.tcl — Timing constraints for IO-Uncore @ 1 GHz
# Sourced by run_synth.tcl after elaborate

link
uniquify

# Clock: 1 GHz = 1 ns period
create_clock clk -period 1.0 -waveform {0 0.5}
set_clock_latency 0.05 clk
set_clock_uncertainty 0.05 clk

# I/O delays
set_input_delay 0.2 -clock clk [remove_from_collection [all_inputs] {clk}]
set_output_delay 0.2 -clock clk [all_outputs]

# Loads
set_load 0.01 [all_outputs]
set_max_fanout 16 [all_inputs]
set_driving_cell -lib_cell INVx1_ASAP7_75t_R -pin Y [remove_from_collection [all_inputs] {clk}]

report_port
