# run_synth_yosys.tcl — Yosys synthesis for IO-Uncore with ASAP7
# Usage: yosys -c synth/run_synth_yosys.tcl
# Set NQ/QD via environment: NQ=16 QD=64 yosys -c synth/run_synth_yosys.tcl
# Must be run from RTL_design/ directory
#
# SRAM uses a black-box macro (area modeled analytically by sram_area_model.py).
# Only the control logic is synthesized against ASAP7 standard cells.

# Read NQ/QD from environment variables, default to 16/64
if {[info exists ::env(NQ)]} { set NQ $::env(NQ) } else { set NQ 16 }
if {[info exists ::env(QD)]} { set QD $::env(QD) } else { set QD 64 }

set TAG "${NQ}_${QD}"

yosys log "===== Synthesizing IO-Uncore: NQ=$NQ QD=$QD ====="

# Read sources — use sram_arbiter_synth.v (black-box SRAM) instead of sram_arbiter.v
yosys read_verilog src/sram_blackbox.v
yosys read_verilog src/credit_manager.v
yosys read_verilog src/stat_counters.v
yosys read_verilog src/sram_arbiter_synth.v
yosys read_verilog src/db_coalescer.v
yosys read_verilog src/cq_engine.v
yosys read_verilog src/sq_engine.v
yosys read_verilog src/mmio_decoder.v
yosys read_verilog src/io_uncore_top.v

# Override parameters on top module (before hierarchy elaboration)
yosys chparam -set NUM_QUEUES $NQ io_uncore_top
yosys chparam -set QUEUE_DEPTH $QD io_uncore_top
yosys chparam -set CREDITS_MAX $QD io_uncore_top
yosys chparam -set BATCH_N 8 io_uncore_top
yosys chparam -set BATCH_T 1000 io_uncore_top
yosys chparam -set COALESCE_B 4 io_uncore_top
yosys chparam -set COALESCE_T 100 io_uncore_top
yosys chparam -set SRAM_ADDR_WIDTH 20 io_uncore_top
yosys chparam -set SRAM_DEPTH 1048576 io_uncore_top

# Read trimmed Liberty files (area + function only, no timing tables)
yosys read_liberty -lib lib/asap7sc7p5t_SIMPLE_RVT_TT_trimmed.lib
yosys read_liberty -lib lib/asap7sc7p5t_INVBUF_RVT_TT_trimmed.lib
yosys read_liberty -lib lib/asap7sc7p5t_SEQ_RVT_TT_trimmed.lib

# Synthesize (synth runs hierarchy internally; -noabc to handle DFF/abc manually)
yosys synth -top io_uncore_top -flatten -noabc

# Legalize DFFs: decompose SDFF/DFFE into plain DFF + combinational logic
# ASAP7 SEQ lib only has plain DFF and async-reset DFF
yosys "script synth/dfflegalize.ys"

# Map DFF cells to ASAP7 sequential library cells
yosys dfflibmap -liberty lib/asap7sc7p5t_SEQ_RVT_TT_trimmed.lib

# Map combinational logic to ASAP7 standard cells.
# Use inline ABC script with classic mapper + buffer/sizing passes so the
# resulting netlist is closer to timing-closed (fanout-aware).
# -D 1000 = 1000 ps clock target.
yosys "abc -D 1000 -liberty lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib -script +strash;dc2;map,-B,0.9"
yosys {opt -fast}
yosys clean -purge

# Output
file mkdir reports
file mkdir netlists
yosys tee -o reports/stat_${TAG}.rpt stat
yosys write_verilog -noattr netlists/io_uncore_${TAG}.v

yosys log "===== Synthesis complete: NQ=$NQ QD=$QD ====="
