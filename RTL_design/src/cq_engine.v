// cq_engine.v — CQE batching FSM with N/T flush and hint register
// Accumulates CQEs in SRAM, flushes to host DRAM in batches.
// Maintains hint_ready counter for poll-lite completion path.

module cq_engine #(
    parameter NUM_QUEUES  = 16,
    parameter QUEUE_DEPTH = 64,
    parameter BATCH_N     = 8,
    parameter BATCH_T     = 1000,  // timeout in cycles
    parameter SRAM_ADDR_WIDTH = 20,
    parameter DATA_WIDTH  = 128
) (
    input  wire clk,
    input  wire rst_n,

    // CQE input from NVMe backend
    input  wire                          cqe_valid,
    input  wire [DATA_WIDTH-1:0]         cqe_data,   // 16B CQE (128 bits)
    input  wire [$clog2(NUM_QUEUES)-1:0] cqe_qid,

    // SRAM interface (to arbiter)
    output reg                           sram_req,
    output reg                           sram_wr,
    output reg  [SRAM_ADDR_WIDTH-1:0]    sram_addr,
    output reg  [DATA_WIDTH-1:0]         sram_wdata,
    input  wire [DATA_WIDTH-1:0]         sram_rdata,
    input  wire                          sram_grant,

    // Credit replenishment (to credit_manager)
    output reg                           credit_inc,

    // Hint register (to mmio_decoder for UNCORE_STATUS[63:32])
    output wire [31:0]                   hint_ready,

    // DMA write interface (to host DRAM)
    output reg                           dma_wr_req,
    output reg  [63:0]                   dma_wr_addr,
    output reg  [DATA_WIDTH-1:0]         dma_wr_data,

    // Stats
    output wire                          stat_cqe_enqueued,
    output wire                          stat_batch_flush
);

    localparam QW = $clog2(NUM_QUEUES);
    localparam DW = $clog2(QUEUE_DEPTH);
    localparam BW = $clog2(BATCH_N + 1);
    localparam TW = $clog2(BATCH_T + 1);

    // CQ SRAM base address (after SQ region: NQ * QD * 4 words of 128b each)
    // For simplicity, CQ base = NUM_QUEUES * QUEUE_DEPTH (each SQE = 4 x 128b words)
    localparam CQ_SRAM_BASE = NUM_QUEUES * QUEUE_DEPTH * 4;

    // Per-queue state
    reg [DW-1:0]  cq_tail     [0:NUM_QUEUES-1];
    reg [BW-1:0]  batch_count [0:NUM_QUEUES-1];
    reg [TW-1:0]  timer       [0:NUM_QUEUES-1];
    reg           timer_active[0:NUM_QUEUES-1];

    // FSM states
    localparam C_IDLE      = 3'd0;
    localparam C_ENQUEUE   = 3'd1;
    localparam C_CHECK     = 3'd2;
    localparam C_FLUSH     = 3'd3;
    localparam C_WRITEBACK = 3'd4;

    reg [2:0] state;
    reg [QW-1:0] cur_qid;
    reg [DATA_WIDTH-1:0] cur_cqe;
    reg [BW-1:0] flush_count;
    reg [DW-1:0] flush_idx;

    // hint_ready = sum of all batch_counts
    reg [31:0] hint_sum;
    integer hi;
    always @(*) begin
        hint_sum = 0;
        for (hi = 0; hi < NUM_QUEUES; hi = hi + 1)
            hint_sum = hint_sum + {{(32-BW){1'b0}}, batch_count[hi]};
    end
    assign hint_ready = hint_sum;

    // Stat pulses
    assign stat_cqe_enqueued = (state == C_ENQUEUE && sram_grant);
    assign stat_batch_flush  = (state == C_WRITEBACK);

    integer i;

    // Timer tick (parallel, outside FSM)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                timer[i] <= 0;
                timer_active[i] <= 0;
            end
        end else begin
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                if (state == C_WRITEBACK && cur_qid == i[QW-1:0]) begin
                    timer[i] <= 0;
                    timer_active[i] <= 0;
                end else if (state == C_ENQUEUE && sram_grant && cur_qid == i[QW-1:0]
                             && batch_count[i] == 0) begin
                    timer[i] <= BATCH_T[TW-1:0];
                    timer_active[i] <= 1;
                end else if (timer_active[i] && timer[i] > 0) begin
                    timer[i] <= timer[i] - 1'b1;
                end
            end
        end
    end

    // Main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= C_IDLE;
            cur_qid <= 0;
            cur_cqe <= 0;
            flush_count <= 0;
            flush_idx <= 0;
            sram_req <= 0;
            sram_wr <= 0;
            sram_addr <= 0;
            sram_wdata <= 0;
            credit_inc <= 0;
            dma_wr_req <= 0;
            dma_wr_addr <= 0;
            dma_wr_data <= 0;
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                cq_tail[i] <= 0;
                batch_count[i] <= 0;
            end
        end else begin
            credit_inc <= 0; // default
            dma_wr_req <= 0;
            sram_req   <= 0;

            case (state)
                C_IDLE: begin
                    if (cqe_valid) begin
                        cur_qid <= cqe_qid;
                        cur_cqe <= cqe_data;
                        // Request SRAM write
                        sram_req <= 1;
                        sram_wr  <= 1;
                        sram_addr <= CQ_SRAM_BASE[SRAM_ADDR_WIDTH-1:0]
                                     + {{(SRAM_ADDR_WIDTH-QW-DW){1'b0}}, cqe_qid, cq_tail[cqe_qid]};
                        sram_wdata <= cqe_data;
                        state <= C_ENQUEUE;
                    end else begin
                        // Check for timer expiry
                        for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                            if (timer_active[i] && timer[i] == 0 && batch_count[i] > 0) begin
                                cur_qid <= i[QW-1:0];
                                flush_count <= batch_count[i];
                                flush_idx <= 0;
                                state <= C_FLUSH;
                            end
                        end
                    end
                end

                C_ENQUEUE: begin
                    if (sram_grant) begin
                        // CQE written to SRAM
                        cq_tail[cur_qid] <= (cq_tail[cur_qid] == QUEUE_DEPTH[DW-1:0] - 1) ?
                                            {DW{1'b0}} : cq_tail[cur_qid] + 1'b1;
                        batch_count[cur_qid] <= batch_count[cur_qid] + 1'b1;
                        credit_inc <= 1;
                        state <= C_CHECK;
                    end else begin
                        // Keep requesting
                        sram_req <= 1;
                    end
                end

                C_CHECK: begin
                    if (batch_count[cur_qid] >= BATCH_N[BW-1:0]) begin
                        flush_count <= batch_count[cur_qid];
                        flush_idx <= 0;
                        state <= C_FLUSH;
                    end else begin
                        state <= C_IDLE;
                    end
                end

                C_FLUSH: begin
                    // Read CQEs from SRAM and issue DMA writes
                    if (flush_idx < flush_count) begin
                        sram_req <= 1;
                        sram_wr  <= 0;
                        sram_addr <= CQ_SRAM_BASE[SRAM_ADDR_WIDTH-1:0]
                                     + {{(SRAM_ADDR_WIDTH-QW-DW){1'b0}}, cur_qid, flush_idx};
                        if (sram_grant) begin
                            dma_wr_req  <= 1;
                            dma_wr_data <= sram_rdata;
                            dma_wr_addr <= {48'd0, cur_qid, flush_idx, 4'b0000}; // simplified addr
                            flush_idx <= flush_idx + 1'b1;
                        end
                    end else begin
                        state <= C_WRITEBACK;
                    end
                end

                C_WRITEBACK: begin
                    batch_count[cur_qid] <= 0;
                    state <= C_IDLE;
                end

                default: state <= C_IDLE;
            endcase
        end
    end

endmodule
