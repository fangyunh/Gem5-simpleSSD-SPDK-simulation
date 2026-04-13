// mmio_decoder.v — BAR0 address decode and transaction routing
// Routes MMIO reads/writes to the correct engine based on address offset:
//   0x0000-0x0FFF: Standard NVMe registers (passed through)
//   0x1000-0x1FFF: Doorbells (routed to db_coalescer)
//   0x2000-0x200F: Uncore status/cap/credits (handled locally)
//   0x2100+:       Mailbox region (routed to sq_engine)

module mmio_decoder #(
    parameter NUM_QUEUES = 16,
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 64
) (
    input  wire clk,
    input  wire rst_n,

    // Host MMIO interface
    input  wire                   mmio_rd_valid,
    input  wire [ADDR_WIDTH-1:0]  mmio_rd_addr,
    output reg  [63:0]            mmio_rd_data,
    output reg                    mmio_rd_ready,

    input  wire                   mmio_wr_valid,
    input  wire [ADDR_WIDTH-1:0]  mmio_wr_addr,
    input  wire [63:0]            mmio_wr_data,

    // To SQ Engine (mailbox writes)
    output wire                   sq_mmio_wr_valid,
    output wire [15:0]            sq_mmio_wr_addr,
    output wire [63:0]            sq_mmio_wr_data,

    // To DB Coalescer (doorbell writes)
    output reg                    db_wr_valid,
    output reg  [$clog2(NUM_QUEUES)-1:0] db_wr_qid,
    output reg  [15:0]            db_wr_tail,
    output reg                    db_wr_is_sq,

    // From Credit Manager (for status register read)
    input  wire [31:0]            credit_count,
    // From CQ Engine (for status register read)
    input  wire [31:0]            hint_ready,

    // Stats (hint register reads)
    output wire                   stat_hint_read_total,
    output wire                   stat_hint_read_empty
);

    // Address ranges
    localparam DOORBELL_BASE = 16'h1000;
    localparam DOORBELL_END  = 16'h2000;
    localparam UNCORE_STATUS = 16'h2000;
    localparam UNCORE_CAP    = 16'h2008;
    localparam UNCORE_CRED   = 16'h2010;
    localparam MAILBOX_BASE  = 16'h2100;

    // Mailbox region: pass through to SQ Engine
    assign sq_mmio_wr_valid = mmio_wr_valid && (mmio_wr_addr >= MAILBOX_BASE);
    assign sq_mmio_wr_addr  = mmio_wr_addr;
    assign sq_mmio_wr_data  = mmio_wr_data;

    // Stat tracking
    wire is_status_read = mmio_rd_valid && (mmio_rd_addr == UNCORE_STATUS);
    assign stat_hint_read_total = is_status_read;
    assign stat_hint_read_empty = is_status_read && (hint_ready == 0);

    // Doorbell decode
    always @(*) begin
        db_wr_valid = 0;
        db_wr_qid   = 0;
        db_wr_tail   = 0;
        db_wr_is_sq  = 0;

        if (mmio_wr_valid && mmio_wr_addr >= DOORBELL_BASE && mmio_wr_addr < DOORBELL_END) begin
            db_wr_valid = 1;
            // Doorbell address: 0x1000 + (qid * 2 + is_cq) * 4
            // Simplified: extract qid and type from offset
            db_wr_qid  = (mmio_wr_addr - DOORBELL_BASE) >> 3;
            db_wr_is_sq = ~mmio_wr_addr[2]; // even offset = SQ, odd = CQ
            db_wr_tail  = mmio_wr_data[15:0];
        end
    end

    // Read handling
    always @(*) begin
        mmio_rd_data  = 64'd0;
        mmio_rd_ready = 0;

        if (mmio_rd_valid) begin
            mmio_rd_ready = 1;
            case (mmio_rd_addr)
                UNCORE_STATUS: mmio_rd_data = {hint_ready, credit_count};
                UNCORE_CAP:    mmio_rd_data = {32'd0, 32'd2}; // Mode B = 2
                UNCORE_CRED:   mmio_rd_data = {32'd0, credit_count};
                default:       mmio_rd_data = 64'd0;
            endcase
        end
    end

endmodule
