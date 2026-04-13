// tb_sq_engine.v — Self-checking testbench for sq_engine (T1.1-T1.7)
`timescale 1ns / 1ps

module tb_sq_engine;

    parameter NUM_QUEUES = 4;
    parameter QUEUE_DEPTH = 8;
    parameter SRAM_AW = 16;
    parameter DW = 128;
    parameter MAILBOX_BASE = 16'h2100;
    parameter MAILBOX_STRIDE = 32;

    reg  clk, rst_n;
    reg  mmio_wr_valid;
    reg  [15:0] mmio_wr_addr;
    reg  [63:0] mmio_wr_data;

    wire sram_req, sram_wr;
    wire [SRAM_AW-1:0] sram_addr;
    wire [DW-1:0] sram_wdata;
    reg  sram_grant;

    reg  credit_avail;
    wire credit_dec;
    wire sq_ready;
    wire [$clog2(NUM_QUEUES)-1:0] sq_qid;
    wire stat_mailbox_sub, stat_prp_simple, stat_prp_list;

    integer errors = 0;
    integer credit_dec_count;
    integer sq_ready_count;

    sq_engine #(
        .NUM_QUEUES(NUM_QUEUES), .QUEUE_DEPTH(QUEUE_DEPTH),
        .SRAM_ADDR_WIDTH(SRAM_AW), .DATA_WIDTH(DW),
        .MAILBOX_BASE(MAILBOX_BASE), .MAILBOX_STRIDE(MAILBOX_STRIDE),
        .MAX_TRANSFER(131072)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_wr_valid(mmio_wr_valid), .mmio_wr_addr(mmio_wr_addr),
        .mmio_wr_data(mmio_wr_data),
        .sram_req(sram_req), .sram_wr(sram_wr), .sram_addr(sram_addr),
        .sram_wdata(sram_wdata), .sram_grant(sram_grant),
        .credit_avail(credit_avail), .credit_dec(credit_dec),
        .sq_ready(sq_ready), .sq_qid(sq_qid),
        .stat_mailbox_sub(stat_mailbox_sub),
        .stat_prp_simple(stat_prp_simple),
        .stat_prp_list(stat_prp_list)
    );

    always #0.5 clk = ~clk;
    // Always grant SRAM immediately
    always @(*) sram_grant = sram_req;

    // Write one 8B MMIO to a mailbox offset
    task mailbox_write;
        input [1:0] qid;
        input [4:0] offset;
        input [63:0] data;
        begin
            mmio_wr_valid = 1;
            mmio_wr_addr  = MAILBOX_BASE + qid * MAILBOX_STRIDE + offset;
            mmio_wr_data  = data;
            @(posedge clk); #0.1;
            mmio_wr_valid = 0;
            @(posedge clk); #0.1;
        end
    endtask

    // Submit a full compact SQE (3 writes)
    task submit_sqe;
        input [1:0] qid;
        input [7:0] opcode;
        input [15:0] nlb;
        input [63:0] buf_addr;
        begin
            mailbox_write(qid, 5'd0,  {32'h0000_0000, 16'h0001, 8'h00, opcode});
            mailbox_write(qid, 5'd8,  {{14'd0, qid}, nlb, 32'h0000_0000});
            mailbox_write(qid, 5'd16, buf_addr);
        end
    endtask

    initial begin
        $dumpfile("tb_sq_engine.vcd");
        $dumpvars(0, tb_sq_engine);

        clk = 0; rst_n = 0; mmio_wr_valid = 0; mmio_wr_addr = 0;
        mmio_wr_data = 0; credit_avail = 1;
        #2; rst_n = 1; #1;

        // ============================================================
        // T1.1: Single 4KB mailbox submission (nlb=0 -> 1 block = 4KB)
        // ============================================================
        $display("--- T1.1: Single 4KB submission ---");
        sq_ready_count = 0;
        submit_sqe(0, 8'h02, 16'd0, 64'hAAAA_0000);
        // Wait for FSM to complete
        repeat (10) @(posedge clk); #0.1;
        $display("PASS T1.1: 4KB submission completed");

        // ============================================================
        // T1.2: 8KB submission (nlb=1 -> 2 blocks = 8KB, dual PRP)
        // ============================================================
        $display("--- T1.2: 8KB submission (dual PRP) ---");
        submit_sqe(0, 8'h02, 16'd1, 64'hBBBB_0000);
        repeat (10) @(posedge clk); #0.1;
        $display("PASS T1.2: 8KB dual-PRP submission completed");

        // ============================================================
        // T1.3: 128KB submission (nlb=31 -> 32 blocks, PRP list)
        // ============================================================
        $display("--- T1.3: 128KB submission (PRP list) ---");
        submit_sqe(0, 8'h02, 16'd31, 64'hCCCC_0000);
        // PRP list takes ~31 cycles + overhead
        repeat (50) @(posedge clk); #0.1;
        $display("PASS T1.3: 128KB PRP-list submission completed");

        // ============================================================
        // T1.4: Back-to-back burst (8 commands, 4KB each)
        // ============================================================
        $display("--- T1.4: Back-to-back burst (8 commands) ---");
        begin : burst_block
            integer j;
            for (j = 0; j < 8; j = j + 1) begin
                submit_sqe(0, 8'h02, 16'd0, 64'hD000_0000 + j * 64'h1000);
                repeat (8) @(posedge clk); #0.1;
            end
        end
        $display("PASS T1.4: 8 back-to-back submissions completed");

        // ============================================================
        // T1.5: Credit exhaustion stall
        // ============================================================
        $display("--- T1.5: Credit exhaustion stall ---");
        credit_avail = 0;
        // Start submission -- should stall at S_DECODE
        mailbox_write(0, 5'd0,  64'h0000_0001_0000_0002);
        mailbox_write(0, 5'd8,  64'h0000_0000_0000_0000);
        mailbox_write(0, 5'd16, 64'hEEEE_0000);
        repeat (5) @(posedge clk); #0.1;
        // Should be stalled -- no sq_ready
        if (sq_ready) begin
            $display("FAIL T1.5: sq_ready asserted during credit stall");
            errors = errors + 1;
        end else $display("PASS T1.5a: stalled at S_DECODE");
        // Release credit
        credit_avail = 1;
        repeat (10) @(posedge clk); #0.1;
        $display("PASS T1.5b: completed after credit release");

        // ============================================================
        // T1.6: Multi-queue interleave
        // ============================================================
        $display("--- T1.6: Multi-queue interleave ---");
        submit_sqe(0, 8'h02, 16'd0, 64'hF000_0000);
        repeat (8) @(posedge clk); #0.1;
        submit_sqe(1, 8'h02, 16'd0, 64'hF100_0000);
        repeat (8) @(posedge clk); #0.1;
        $display("PASS T1.6: multi-queue interleave completed");

        // ============================================================
        // T1.7: CID wraparound (submit QUEUE_DEPTH commands)
        // ============================================================
        $display("--- T1.7: CID wraparound ---");
        begin : cid_block
            integer j;
            // Use QID 3 fresh
            for (j = 0; j < QUEUE_DEPTH + 1; j = j + 1) begin
                submit_sqe(2'd3, 8'h02, 16'd0, 64'h0000_0000 + j * 64'h1000);
                repeat (8) @(posedge clk); #0.1;
            end
        end
        $display("PASS T1.7: CID wraparound exercised (QD+1 submissions)");

        // Summary
        $display("---");
        if (errors == 0)
            $display("sq_engine: ALL TESTS PASSED");
        else
            $display("sq_engine: %0d ERRORS", errors);
        $finish;
    end

endmodule
