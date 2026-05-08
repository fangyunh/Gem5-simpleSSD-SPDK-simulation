# Synthesis using Synopsys Design Compiler
The Synopsys Design Compiler is invoked by entering 
design_vision in the terminal. At
the beginning of a new project, one must expose the cell libraries that are to be used
for synthesis and compilation. An initial setup script should take care of the
essentials, and should be placed in the directory from where you invoke
design_vision . The setup script should be names 
.synosys_dc.setup .
A sample setup script is given below:

<code>
#Define the target logic library, symbol library, and link libraries

set_app_var target_library lsi_10k.db

set_app_var symbol_library lsi_10k.sdb

set_app_var synthetic_library dw_foundation.sldb 

set_app_var link_library "* $target_library $synthetic_library"

set_app_var search_path [concat $search_path ./src]

set_app_var designer "Your name"

#Define aliases

alias h history

alias rc "report_constraint -all_violators"

</code>

This script sets up 
lsi_10k library as a source for cells and technology specific
constraints. In actual synthesis, I have used 
FreePDK-45 , which is a free, 45 nm
library available all over the internet. I'll attach the PDK below, but you don't have
to use that specific PDK just yet.
## Steps for Design Compilation
I have been using the following steps to compile my FIR implementations:
1. Setup cell library (as stated above).
2. Analyze the verilog module to be synthesized. Use 
File -> Analyze . It turns
out that the design compiler supports a very strict subset of verilog. One may
have to re-tailor the code at some spots to make it pass with a design
compiler.
3. Elaborate the top module. Use 
File -> Elaborate .
4. Specify timing and load capacitance constraints. I have batched my
specifications in a 
tcl script given below:

<code>
link

uniquify 

#specify clk 

create_clock clk -period 42 -waveform {0 20}

set_clock_latency 0.3 clk 

set_input_delay 2.0 -clock clk [all_inputs] 

set_output_delay 1.65 -clock clk [all_outputs] 

#specify clk_serial 

create_clock clk_serial -period 14 -waveform {0 7} 

set_clock_latency 0.3 clk_serial 

set_input_delay 2.0 -clock clk_serial [all_inputs] 

set_output_delay 1.65 -clock clk_serial [all_outputs] 

#specify loads 

set_load 0.1 [all_outputs] 

set_max_fanout 1 [all_inputs] 

set_fanout_load 8 [all_outputs] 

report_port

</code>

5. Check Design. Use 
Design -> Check Design .
6. Compile Design. USe 
Design -> Compile Design .
## Steps for Report Generation
From here on, one can generate timing, area and power reports. The steps to do that
are as follows:
1. Use 
Timing -> Report Timing Path to generate timing reports. The crucial
metric here is the slack. Defined in units of nano-seconds, it is the spare
time budget of the critical path for a specified clock period. For example,
let's assume a specified clock period of 100 ns, and a critical path of 98 ns.
Here, the slack will be calculated as: 
specified clock period - critical path
propagation delay = +2 ns . This means that we can still decrease the clock
period by 2 ns, and the design will keep working. On the other hand, a negative
slack means that the timing constraints have failed. As an example, a slack of-2 ns means that we have to slow the clock down by 2ns to meet timing
requirements.
2. Use 
Design -> Report Area to generate an area report. Area is reported in
terms of cells used.
3. Use 
Design -> Report Power to generate power estimation reports.