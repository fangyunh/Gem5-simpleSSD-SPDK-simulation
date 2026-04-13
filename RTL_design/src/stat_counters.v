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

    integer i;

    // Read: combinational mux
    assign stat_rd_data = (stat_rd_addr < NUM_COUNTERS) ?
                          counters[stat_rd_addr] : 64'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || stat_reset) begin
            for (i = 0; i < NUM_COUNTERS; i = i + 1)
                counters[i] <= 64'd0;
        end else begin
            for (i = 0; i < NUM_COUNTERS; i = i + 1) begin
                if (stat_inc[i] && counters[i] != {64{1'b1}})
                    counters[i] <= counters[i] + 64'd1;
            end
        end
    end

endmodule
