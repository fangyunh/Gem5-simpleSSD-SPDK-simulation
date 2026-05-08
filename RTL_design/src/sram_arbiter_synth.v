// sram_arbiter_synth.v — Synthesis version of sram_arbiter
// Uses sram_blackbox instead of register array.
// The arbiter logic is identical to sram_arbiter.v.

module sram_arbiter #(
    parameter NUM_REQUESTORS = 3,
    parameter SRAM_ADDR_WIDTH = 20,
    parameter DATA_WIDTH = 512,
    parameter SRAM_DEPTH = 1048576
) (
    input  wire clk,
    input  wire rst_n,

    input  wire                      req0_valid,
    input  wire                      req0_wr,
    input  wire [SRAM_ADDR_WIDTH-1:0] req0_addr,
    input  wire [DATA_WIDTH-1:0]     req0_wdata,
    output reg                       req0_grant,
    output wire [DATA_WIDTH-1:0]     req0_rdata,

    input  wire                      req1_valid,
    input  wire                      req1_wr,
    input  wire [SRAM_ADDR_WIDTH-1:0] req1_addr,
    input  wire [DATA_WIDTH-1:0]     req1_wdata,
    output reg                       req1_grant,
    output wire [DATA_WIDTH-1:0]     req1_rdata,

    input  wire                      req2_valid,
    input  wire                      req2_wr,
    input  wire [SRAM_ADDR_WIDTH-1:0] req2_addr,
    input  wire [DATA_WIDTH-1:0]     req2_wdata,
    output reg                       req2_grant,
    output wire [DATA_WIDTH-1:0]     req2_rdata
);

    // Round-robin priority
    reg [1:0] last_grant;

    // Internal signals
    reg                       sel_valid;
    reg                       sel_wr;
    reg [SRAM_ADDR_WIDTH-1:0] sel_addr;
    reg [DATA_WIDTH-1:0]      sel_wdata;
    reg [1:0]                 sel_id;

    // Read data from SRAM macro
    wire [DATA_WIDTH-1:0] sram_rdata;
    reg [DATA_WIDTH-1:0] rdata_reg;

    assign req0_rdata = rdata_reg;
    assign req1_rdata = rdata_reg;
    assign req2_rdata = rdata_reg;

    // Black-box SRAM macro (area modeled analytically)
    sram_macro #(
        .ADDR_WIDTH(SRAM_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(SRAM_DEPTH)
    ) u_sram (
        .clk(clk),
        .we(sel_valid & sel_wr),
        .addr(sel_addr),
        .wdata(sel_wdata),
        .rdata(sram_rdata)
    );

    // Arbitration: round-robin starting from (last_grant + 1)
    always @(*) begin
        sel_valid = 0;
        sel_wr    = 0;
        sel_addr  = 0;
        sel_wdata = 0;
        sel_id    = 0;
        req0_grant = 0;
        req1_grant = 0;
        req2_grant = 0;

        if (last_grant == 2'd0) begin
            if (req1_valid) begin
                sel_valid = 1; sel_id = 1; sel_wr = req1_wr;
                sel_addr = req1_addr; sel_wdata = req1_wdata; req1_grant = 1;
            end else if (req2_valid) begin
                sel_valid = 1; sel_id = 2; sel_wr = req2_wr;
                sel_addr = req2_addr; sel_wdata = req2_wdata; req2_grant = 1;
            end else if (req0_valid) begin
                sel_valid = 1; sel_id = 0; sel_wr = req0_wr;
                sel_addr = req0_addr; sel_wdata = req0_wdata; req0_grant = 1;
            end
        end else if (last_grant == 2'd1) begin
            if (req2_valid) begin
                sel_valid = 1; sel_id = 2; sel_wr = req2_wr;
                sel_addr = req2_addr; sel_wdata = req2_wdata; req2_grant = 1;
            end else if (req0_valid) begin
                sel_valid = 1; sel_id = 0; sel_wr = req0_wr;
                sel_addr = req0_addr; sel_wdata = req0_wdata; req0_grant = 1;
            end else if (req1_valid) begin
                sel_valid = 1; sel_id = 1; sel_wr = req1_wr;
                sel_addr = req1_addr; sel_wdata = req1_wdata; req1_grant = 1;
            end
        end else begin
            if (req0_valid) begin
                sel_valid = 1; sel_id = 0; sel_wr = req0_wr;
                sel_addr = req0_addr; sel_wdata = req0_wdata; req0_grant = 1;
            end else if (req1_valid) begin
                sel_valid = 1; sel_id = 1; sel_wr = req1_wr;
                sel_addr = req1_addr; sel_wdata = req1_wdata; req1_grant = 1;
            end else if (req2_valid) begin
                sel_valid = 1; sel_id = 2; sel_wr = req2_wr;
                sel_addr = req2_addr; sel_wdata = req2_wdata; req2_grant = 1;
            end
        end
    end

    // SRAM access on clock edge
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_grant <= 2'd2;
            rdata_reg  <= {DATA_WIDTH{1'b0}};
        end else if (sel_valid) begin
            last_grant <= sel_id;
            if (!sel_wr) begin
                rdata_reg <= sram_rdata;
            end
        end
    end

endmodule
