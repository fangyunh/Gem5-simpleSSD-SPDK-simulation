// tb_sram_arbiter.v — Self-checking testbench for sram_arbiter
// Timing convention: present inputs at negedge, check combinatorial grants at
// negedge+1, commit on posedge.  rdata is sampled one cycle after the read grant.
`timescale 1ns / 1ps

module tb_sram_arbiter;

    parameter SRAM_ADDR_WIDTH = 8;
    parameter DATA_WIDTH = 128;
    parameter SRAM_DEPTH = 256;

    reg  clk, rst_n;
    reg  req0_valid, req0_wr;
    reg  [SRAM_ADDR_WIDTH-1:0] req0_addr;
    reg  [DATA_WIDTH-1:0] req0_wdata;
    wire req0_grant;
    wire [DATA_WIDTH-1:0] req0_rdata;

    reg  req1_valid, req1_wr;
    reg  [SRAM_ADDR_WIDTH-1:0] req1_addr;
    reg  [DATA_WIDTH-1:0] req1_wdata;
    wire req1_grant;
    wire [DATA_WIDTH-1:0] req1_rdata;

    reg  req2_valid, req2_wr;
    reg  [SRAM_ADDR_WIDTH-1:0] req2_addr;
    reg  [DATA_WIDTH-1:0] req2_wdata;
    wire req2_grant;
    wire [DATA_WIDTH-1:0] req2_rdata;

    integer errors = 0;

    sram_arbiter #(
        .NUM_REQUESTORS(3), .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH), .SRAM_DEPTH(SRAM_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req0_valid(req0_valid), .req0_wr(req0_wr), .req0_addr(req0_addr),
        .req0_wdata(req0_wdata), .req0_grant(req0_grant), .req0_rdata(req0_rdata),
        .req1_valid(req1_valid), .req1_wr(req1_wr), .req1_addr(req1_addr),
        .req1_wdata(req1_wdata), .req1_grant(req1_grant), .req1_rdata(req1_rdata),
        .req2_valid(req2_valid), .req2_wr(req2_wr), .req2_addr(req2_addr),
        .req2_wdata(req2_wdata), .req2_grant(req2_grant), .req2_rdata(req2_rdata)
    );

    // 10 ns period (negedge at 5 ns = mid-cycle)
    always #5 clk = ~clk;

    task reset_inputs;
        begin
            req0_valid = 0; req0_wr = 0; req0_addr = 0; req0_wdata = 0;
            req1_valid = 0; req1_wr = 0; req1_addr = 0; req1_wdata = 0;
            req2_valid = 0; req2_wr = 0; req2_addr = 0; req2_wdata = 0;
        end
    endtask

    // Helper: wait for next negedge, apply inputs, check grants,
    //         then posedge commits to SRAM.
    // Grants are combinatorial outputs valid while inputs are asserted.
    // We check at negedge+1ns (inputs stable, combinatorial settled).

    initial begin
        $dumpfile("tb_sram_arbiter.vcd");
        $dumpvars(0, tb_sram_arbiter);

        clk = 0; rst_n = 0; reset_inputs;
        // Hold reset for 2 posedges
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk); // settle

        // ----------------------------------------------------------------
        // T1: Single requestor write — present at negedge, check grant,
        //     posedge commits write.
        // ----------------------------------------------------------------
        $display("--- T1: Single requestor write + read ---");
        @(negedge clk);
        req0_valid = 1; req0_wr = 1; req0_addr = 8'd10; req0_wdata = 128'hDEADBEEF;
        #1; // combinatorial settle
        if (!req0_grant) begin
            $display("FAIL T1: write grant not asserted (got g0=%b)", req0_grant);
            errors = errors + 1;
        end else $display("PASS T1: write granted");
        @(posedge clk); // commit write to SRAM
        reset_inputs;

        // Read back: present read at negedge, commit at posedge,
        // rdata is registered and available one cycle later.
        @(negedge clk);
        req0_valid = 1; req0_wr = 0; req0_addr = 8'd10;
        #1;
        if (!req0_grant) begin
            $display("FAIL T1: read grant not asserted"); errors = errors + 1;
        end
        @(posedge clk); // commit read — rdata latches at this edge
        reset_inputs;
        @(posedge clk); // rdata now stable in rdata_reg
        #1;
        if (req0_rdata !== 128'hDEADBEEF) begin
            $display("FAIL T1: readback=%h (exp DEADBEEF)", req0_rdata);
            errors = errors + 1;
        end else $display("PASS T1: readback correct");

        // ----------------------------------------------------------------
        // T2: Contention — req0 and req1 both valid.
        //     After T1 last_grant=0, so RR order: 1 -> 2 -> 0.
        //     req1 should win first; req0 wins next cycle.
        // ----------------------------------------------------------------
        $display("--- T2: Contention round-robin ---");
        @(negedge clk);
        req0_valid = 1; req0_wr = 1; req0_addr = 8'd20; req0_wdata = 128'hAAAA;
        req1_valid = 1; req1_wr = 1; req1_addr = 8'd30; req1_wdata = 128'hBBBB;
        #1;
        if (!req1_grant || req0_grant) begin
            $display("FAIL T2: req1 should win first (g0=%b g1=%b)", req0_grant, req1_grant);
            errors = errors + 1;
        end else $display("PASS T2: req1 granted first");
        @(posedge clk); // commit req1 write
        // req0 still pending; req1 de-asserted next cycle
        req1_valid = 0;
        #1;
        if (!req0_grant) begin
            $display("FAIL T2: req0 should get second grant (g0=%b)", req0_grant);
            errors = errors + 1;
        end else $display("PASS T2: req0 granted second");
        @(posedge clk); // commit req0 write
        reset_inputs;
        @(posedge clk);

        // ----------------------------------------------------------------
        // T3: Three-way contention — after T2 last_grant=0, order: 1->2->0.
        // ----------------------------------------------------------------
        $display("--- T3: Three-way contention ---");
        @(negedge clk);
        req0_valid = 1; req0_wr = 1; req0_addr = 8'd40; req0_wdata = 128'h1111;
        req1_valid = 1; req1_wr = 1; req1_addr = 8'd50; req1_wdata = 128'h2222;
        req2_valid = 1; req2_wr = 1; req2_addr = 8'd60; req2_wdata = 128'h3333;
        #1;
        if (!req1_grant || req0_grant || req2_grant) begin
            $display("FAIL T3a: req1 expected first (g0=%b g1=%b g2=%b)",
                     req0_grant, req1_grant, req2_grant);
            errors = errors + 1;
        end else $display("PASS T3a: req1 first");
        @(posedge clk);
        req1_valid = 0;
        #1;
        if (!req2_grant || req0_grant) begin
            $display("FAIL T3b: req2 expected second (g0=%b g2=%b)", req0_grant, req2_grant);
            errors = errors + 1;
        end else $display("PASS T3b: req2 second");
        @(posedge clk);
        req2_valid = 0;
        #1;
        if (!req0_grant) begin
            $display("FAIL T3c: req0 expected third (g0=%b)", req0_grant);
            errors = errors + 1;
        end else $display("PASS T3c: req0 third");
        @(posedge clk);
        reset_inputs;
        @(posedge clk);

        // ----------------------------------------------------------------
        // Summary
        // ----------------------------------------------------------------
        $display("---");
        if (errors == 0)
            $display("sram_arbiter: ALL TESTS PASSED");
        else
            $display("sram_arbiter: %0d ERRORS", errors);
        $finish;
    end

endmodule
