// tb_gate_stim.v — Gate-level activity stimulus for VCD-driven power analysis.
// Drives the post-synth netlist with a synthetic but representative workload:
//   - 4 queues seeing mailbox writes (Mode-B compact-SQE submissions)
//   - Doorbell toggles
//   - CQE completions arriving
//   - Stat counter reads
// VCD covers ~10 µs of simulated time at 1 GHz, which OpenSTA can ingest
// for activity-aware report_power.
//
// Note: This TB drives PRIMARY INPUTS only. Internal nets get activity by
// propagation in the netlist sim. The SRAM is a black-box (sram_macro) —
// its outputs are driven by the synth-version sram_arbiter logic, but
// since sram_macro has no body in the flattened netlist, the rdata path
// will stay at X. That's fine for *control logic* power; SRAM power is
// modeled analytically.

`timescale 1ps / 1ps

module tb_gate_stim;
    // Clock at 1 GHz = 1000 ps period
    reg clk = 0;
    always #500 clk = ~clk;

    reg rst_n = 0;
    reg mmio_rd_valid = 0;
    reg [15:0] mmio_rd_addr = 0;
    wire [63:0] mmio_rd_data;
    wire mmio_rd_ready;
    reg mmio_wr_valid = 0;
    reg [15:0] mmio_wr_addr = 0;
    reg [63:0] mmio_wr_data = 0;
    reg cqe_valid = 0;
    reg [127:0] cqe_data = 0;
    reg [5:0] cqe_qid = 0;
    wire sq_ready;
    wire [5:0] sq_qid;
    wire dev_db_valid;
    wire [5:0] dev_db_qid;
    wire [15:0] dev_db_tail;
    wire dev_db_is_sq;
    wire dma_wr_req;
    wire [63:0] dma_wr_addr;
    wire [127:0] dma_wr_data;
    reg [3:0] stat_rd_addr = 0;
    wire [63:0] stat_rd_data;

    io_uncore_top dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_rd_valid(mmio_rd_valid), .mmio_rd_addr(mmio_rd_addr),
        .mmio_rd_data(mmio_rd_data), .mmio_rd_ready(mmio_rd_ready),
        .mmio_wr_valid(mmio_wr_valid), .mmio_wr_addr(mmio_wr_addr),
        .mmio_wr_data(mmio_wr_data),
        .cqe_valid(cqe_valid), .cqe_data(cqe_data), .cqe_qid(cqe_qid),
        .sq_ready(sq_ready), .sq_qid(sq_qid),
        .dev_db_valid(dev_db_valid), .dev_db_qid(dev_db_qid),
        .dev_db_tail(dev_db_tail), .dev_db_is_sq(dev_db_is_sq),
        .dma_wr_req(dma_wr_req), .dma_wr_addr(dma_wr_addr),
        .dma_wr_data(dma_wr_data),
        .stat_rd_addr(stat_rd_addr), .stat_rd_data(stat_rd_data)
    );

    // Synthetic stim: cycle through a few representative actions per queue
    integer i, q, lba;

    initial begin
        $dumpfile("tb_gate_stim.vcd");
        $dumpvars(0, tb_gate_stim);

        // Reset for 50 cycles
        rst_n = 0;
        #50000;
        rst_n = 1;
        #5000;

        // Issue 200 mailbox writes across 4 queues, doorbell each
        lba = 0;
        for (i = 0; i < 200; i = i + 1) begin
            q = i & 3;
            // mailbox bytes 0-7 (opcode + flags + nsid + lba_lo)
            @(posedge clk);
            mmio_wr_valid = 1;
            mmio_wr_addr  = 16'h3000 + (q[1:0] * 32);
            mmio_wr_data  = {32'd0, 16'h0001, 8'h00, 8'h02};
            @(posedge clk);
            mmio_wr_addr  = 16'h3008 + (q[1:0] * 32);
            mmio_wr_data  = {16'd0, q[1:0], 14'd0, lba[31:0]};
            @(posedge clk);
            mmio_wr_valid = 0;

            // Ring SQ doorbell
            @(posedge clk);
            mmio_wr_valid = 1;
            mmio_wr_addr  = 16'h1000 + (q[1:0] * 8);
            mmio_wr_data  = {48'd0, i[15:0] + 16'd1};
            @(posedge clk);
            mmio_wr_valid = 0;

            // Inject a CQE every ~3 iters
            if ((i & 3) == 2) begin
                @(posedge clk);
                cqe_valid = 1;
                cqe_qid   = q[1:0];
                cqe_data  = {64'h0, 32'h0, i[15:0], 16'h0001};
                @(posedge clk);
                cqe_valid = 0;
            end

            // Stat-counter read every ~8 iters
            if ((i & 7) == 0) begin
                @(posedge clk);
                mmio_rd_valid = 1;
                mmio_rd_addr  = 16'h2000;
                @(posedge clk);
                mmio_rd_valid = 0;
                stat_rd_addr  = i[3:0];
            end

            lba = lba + 8;
        end

        // Idle for ~2 µs so background timers/coalescers fire
        #2000000;

        $finish;
    end

    // Safety timeout: 20 µs
    initial begin
        #20000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
