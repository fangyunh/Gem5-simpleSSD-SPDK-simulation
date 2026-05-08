// stat_counters.v — Telemetry accumulation for IO-Uncore
// 10 x 64-bit saturating counters, pulse-increment interface, address-read export.

module stat_counters #(
    parameter NUM_COUNTERS = 10
) (
    input  wire clk,
    input  wire rst_n,

    // Pulse inputs (active-high, one per counter)
    input  wire [NUM_COUNTERS-1:0] stat_inc,

    // Read interface
    input  wire [3:0]  stat_rd_addr,  // counter index (0..NUM_COUNTERS-1)
    output wire [63:0] stat_rd_data,  // counter value

    // Bulk reset (clear all counters)
    input  wire stat_reset
);

    reg [63:0] counters [0:NUM_COUNTERS-1];

    // Read: combinational mux
    assign stat_rd_data = (stat_rd_addr < NUM_COUNTERS) ?
                          counters[stat_rd_addr] : 64'd0;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_COUNTERS; gi = gi + 1) begin : gen_counters
            always @(posedge clk) begin
                if (!rst_n || stat_reset)
                    counters[gi] <= 64'd0;
                else if (stat_inc[gi] && counters[gi] != {64{1'b1}})
                    counters[gi] <= counters[gi] + 64'd1;
            end
        end
    endgenerate

endmodule
