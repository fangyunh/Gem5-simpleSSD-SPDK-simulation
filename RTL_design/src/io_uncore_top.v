// io_uncore_top.v — Top-level IO-Uncore wrapper
// Instantiates: mmio_decoder, sq_engine, cq_engine, db_coalescer,
//               sram_arbiter, credit_manager, stat_counters

module io_uncore_top #(
    parameter NUM_QUEUES     = 16,
    parameter QUEUE_DEPTH    = 64,
    parameter CREDITS_MAX    = 64,
    parameter BATCH_N        = 8,
    parameter BATCH_T        = 1000,
    parameter COALESCE_B     = 4,
    parameter COALESCE_T     = 100,
    parameter SRAM_ADDR_WIDTH = 20,
    parameter SRAM_DEPTH     = 1048576,
    parameter DATA_WIDTH     = 128
) (
    input  wire clk,
    input  wire rst_n,

    // Host MMIO read interface
    input  wire        mmio_rd_valid,
    input  wire [15:0] mmio_rd_addr,
    output wire [63:0] mmio_rd_data,
    output wire        mmio_rd_ready,

    // Host MMIO write interface
    input  wire        mmio_wr_valid,
    input  wire [15:0] mmio_wr_addr,
    input  wire [63:0] mmio_wr_data,

    // CQE input from NVMe backend
    input  wire                          cqe_valid,
    input  wire [DATA_WIDTH-1:0]         cqe_data,
    input  wire [$clog2(NUM_QUEUES)-1:0] cqe_qid,

    // Backend notification (SQE ready)
    output wire                          sq_ready,
    output wire [$clog2(NUM_QUEUES)-1:0] sq_qid,

    // Coalesced doorbell output to device
    output wire                          dev_db_valid,
    output wire [$clog2(NUM_QUEUES)-1:0] dev_db_qid,
    output wire [15:0]                   dev_db_tail,
    output wire                          dev_db_is_sq,

    // DMA write to host (from CQ flush)
    output wire                          dma_wr_req,
    output wire [63:0]                   dma_wr_addr,
    output wire [DATA_WIDTH-1:0]         dma_wr_data,

    // Stat read interface
    input  wire [3:0]  stat_rd_addr,
    output wire [63:0] stat_rd_data
);

    // Internal wires: MMIO decoder -> engines
    wire        sq_mmio_wr_valid;
    wire [15:0] sq_mmio_wr_addr;
    wire [63:0] sq_mmio_wr_data;

    wire        db_wr_valid_i;
    wire [$clog2(NUM_QUEUES)-1:0] db_wr_qid_i;
    wire [15:0] db_wr_tail_i;
    wire        db_wr_is_sq_i;

    // Credit manager wires
    wire credit_avail, credit_dec, credit_inc;
    wire [31:0] credit_count;
    wire stat_credit_stall;

    // CQ engine -> hint
    wire [31:0] hint_ready;

    // SRAM arbiter wires
    wire sq_sram_req, sq_sram_wr;
    wire [SRAM_ADDR_WIDTH-1:0] sq_sram_addr;
    wire [DATA_WIDTH-1:0] sq_sram_wdata;
    wire sq_sram_grant;

    wire cq_sram_req, cq_sram_wr;
    wire [SRAM_ADDR_WIDTH-1:0] cq_sram_addr;
    wire [DATA_WIDTH-1:0] cq_sram_wdata;
    wire [DATA_WIDTH-1:0] cq_sram_rdata;
    wire cq_sram_grant;

    // Stat pulse wires
    wire stat_mailbox_sub, stat_prp_simple, stat_prp_list;
    wire stat_cqe_enqueued, stat_batch_flush;
    wire stat_db_received, stat_db_coalesced;
    wire stat_hint_read_total, stat_hint_read_empty;

    // 10 stat pulses packed into bus
    wire [9:0] stat_inc_bus;
    assign stat_inc_bus = {
        stat_db_coalesced,     // [9]
        stat_db_received,      // [8]
        stat_batch_flush,      // [7]
        stat_cqe_enqueued,     // [6]
        stat_hint_read_empty,  // [5]
        stat_hint_read_total,  // [4]
        stat_credit_stall,     // [3]
        stat_prp_list,         // [2]
        stat_prp_simple,       // [1]
        stat_mailbox_sub       // [0]
    };

    // ---- MMIO Decoder ----
    mmio_decoder #(
        .NUM_QUEUES(NUM_QUEUES)
    ) u_mmio_decoder (
        .clk(clk), .rst_n(rst_n),
        .mmio_rd_valid(mmio_rd_valid), .mmio_rd_addr(mmio_rd_addr),
        .mmio_rd_data(mmio_rd_data), .mmio_rd_ready(mmio_rd_ready),
        .mmio_wr_valid(mmio_wr_valid), .mmio_wr_addr(mmio_wr_addr),
        .mmio_wr_data(mmio_wr_data),
        .sq_mmio_wr_valid(sq_mmio_wr_valid),
        .sq_mmio_wr_addr(sq_mmio_wr_addr),
        .sq_mmio_wr_data(sq_mmio_wr_data),
        .db_wr_valid(db_wr_valid_i), .db_wr_qid(db_wr_qid_i),
        .db_wr_tail(db_wr_tail_i), .db_wr_is_sq(db_wr_is_sq_i),
        .credit_count(credit_count), .hint_ready(hint_ready),
        .stat_hint_read_total(stat_hint_read_total),
        .stat_hint_read_empty(stat_hint_read_empty)
    );

    // ---- SQ Engine ----
    sq_engine #(
        .NUM_QUEUES(NUM_QUEUES), .QUEUE_DEPTH(QUEUE_DEPTH),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .MAX_TRANSFER(131072)
    ) u_sq_engine (
        .clk(clk), .rst_n(rst_n),
        .mmio_wr_valid(sq_mmio_wr_valid),
        .mmio_wr_addr(sq_mmio_wr_addr),
        .mmio_wr_data(sq_mmio_wr_data),
        .sram_req(sq_sram_req), .sram_wr(sq_sram_wr),
        .sram_addr(sq_sram_addr), .sram_wdata(sq_sram_wdata),
        .sram_grant(sq_sram_grant),
        .credit_avail(credit_avail), .credit_dec(credit_dec),
        .sq_ready(sq_ready), .sq_qid(sq_qid),
        .stat_mailbox_sub(stat_mailbox_sub),
        .stat_prp_simple(stat_prp_simple),
        .stat_prp_list(stat_prp_list)
    );

    // ---- CQ Engine ----
    cq_engine #(
        .NUM_QUEUES(NUM_QUEUES), .QUEUE_DEPTH(QUEUE_DEPTH),
        .BATCH_N(BATCH_N), .BATCH_T(BATCH_T),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
    ) u_cq_engine (
        .clk(clk), .rst_n(rst_n),
        .cqe_valid(cqe_valid), .cqe_data(cqe_data), .cqe_qid(cqe_qid),
        .sram_req(cq_sram_req), .sram_wr(cq_sram_wr),
        .sram_addr(cq_sram_addr), .sram_wdata(cq_sram_wdata),
        .sram_rdata(cq_sram_rdata), .sram_grant(cq_sram_grant),
        .credit_inc(credit_inc), .hint_ready(hint_ready),
        .dma_wr_req(dma_wr_req), .dma_wr_addr(dma_wr_addr),
        .dma_wr_data(dma_wr_data),
        .stat_cqe_enqueued(stat_cqe_enqueued),
        .stat_batch_flush(stat_batch_flush)
    );

    // ---- Doorbell Coalescer ----
    db_coalescer #(
        .NUM_QUEUES(NUM_QUEUES),
        .COALESCE_COUNT(COALESCE_B),
        .TIMEOUT_CYCLES(COALESCE_T)
    ) u_db_coalescer (
        .clk(clk), .rst_n(rst_n),
        .db_wr_valid(db_wr_valid_i), .db_wr_qid(db_wr_qid_i),
        .db_wr_tail(db_wr_tail_i), .db_wr_is_sq(db_wr_is_sq_i),
        .dev_db_valid(dev_db_valid), .dev_db_qid(dev_db_qid),
        .dev_db_tail(dev_db_tail), .dev_db_is_sq(dev_db_is_sq),
        .stat_db_received(stat_db_received),
        .stat_db_coalesced(stat_db_coalesced)
    );

    // ---- SRAM Arbiter ----
    // DB Coalescer doesn't use SRAM, tie off req2
    sram_arbiter #(
        .NUM_REQUESTORS(3),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SRAM_DEPTH(SRAM_DEPTH)
    ) u_sram_arbiter (
        .clk(clk), .rst_n(rst_n),
        .req0_valid(sq_sram_req), .req0_wr(sq_sram_wr),
        .req0_addr(sq_sram_addr), .req0_wdata(sq_sram_wdata),
        .req0_grant(sq_sram_grant), .req0_rdata(),
        .req1_valid(cq_sram_req), .req1_wr(cq_sram_wr),
        .req1_addr(cq_sram_addr), .req1_wdata(cq_sram_wdata),
        .req1_grant(cq_sram_grant), .req1_rdata(cq_sram_rdata),
        .req2_valid(1'b0), .req2_wr(1'b0),
        .req2_addr({SRAM_ADDR_WIDTH{1'b0}}), .req2_wdata({DATA_WIDTH{1'b0}}),
        .req2_grant(), .req2_rdata()
    );

    // ---- Credit Manager ----
    credit_manager #(
        .CREDITS_MAX(CREDITS_MAX)
    ) u_credit_manager (
        .clk(clk), .rst_n(rst_n),
        .credit_dec(credit_dec), .credit_inc(credit_inc),
        .credit_avail(credit_avail), .credit_count(credit_count),
        .stat_credit_stall(stat_credit_stall)
    );

    // ---- Stat Counters ----
    stat_counters #(
        .NUM_COUNTERS(10)
    ) u_stat_counters (
        .clk(clk), .rst_n(rst_n),
        .stat_inc(stat_inc_bus),
        .stat_rd_addr(stat_rd_addr),
        .stat_rd_data(stat_rd_data),
        .stat_reset(1'b0)
    );

endmodule
