// sram_blackbox.v — Black-box SRAM macro for synthesis
// Area is computed analytically by scripts/sram_area_model.py.
// This module is not synthesized — it appears as a black box in the netlist.

(* blackbox *)
module sram_macro #(
    parameter ADDR_WIDTH = 20,
    parameter DATA_WIDTH = 512,
    parameter DEPTH      = 1048576
) (
    input  wire                    clk,
    input  wire                    we,
    input  wire [ADDR_WIDTH-1:0]   addr,
    input  wire [DATA_WIDTH-1:0]   wdata,
    output reg  [DATA_WIDTH-1:0]   rdata
);
    // Black box — no implementation for synthesis.
    // Simulation model uses register array (see sram_arbiter.v).
endmodule
