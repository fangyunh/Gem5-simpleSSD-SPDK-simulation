// sq_engine.v — Mailbox ingestion FSM with SQE decode and PRP expansion
// Receives compact 24B SQE via 3 x 8B MMIO writes, expands to full 64B SQE,
// generates PRP entries, writes to SRAM SQ buffer.

module sq_engine #(
    parameter NUM_QUEUES      = 16,
    parameter QUEUE_DEPTH     = 64,
    parameter SRAM_ADDR_WIDTH = 20,
    parameter DATA_WIDTH      = 128,
    parameter LBA_SIZE        = 4096,
    parameter MAX_TRANSFER    = 131072, // 128KB
    parameter MAILBOX_BASE    = 16'h2100,
    parameter MAILBOX_STRIDE  = 32
) (
    input  wire clk,
    input  wire rst_n,

    // MMIO write from decoder
    input  wire        mmio_wr_valid,
    input  wire [15:0] mmio_wr_addr,
    input  wire [63:0] mmio_wr_data,

    // SRAM interface (to arbiter)
    output reg                           sram_req,
    output reg                           sram_wr,
    output reg  [SRAM_ADDR_WIDTH-1:0]    sram_addr,
    output reg  [DATA_WIDTH-1:0]         sram_wdata,
    input  wire                          sram_grant,

    // Credit interface (from credit_manager)
    input  wire credit_avail,
    output reg  credit_dec,

    // Backend notification
    output reg                           sq_ready,
    output reg  [$clog2(NUM_QUEUES)-1:0] sq_qid,

    // Stats
    output wire stat_mailbox_sub,
    output wire stat_prp_simple,
    output wire stat_prp_list
);

    localparam QW = $clog2(NUM_QUEUES);
    localparam DW = $clog2(QUEUE_DEPTH);
    localparam PAGE_SIZE = 4096;
    localparam MAX_PRP = (MAX_TRANSFER / PAGE_SIZE) - 1; // 31 for 128KB
    localparam PW = $clog2(MAX_PRP + 1);

    // FSM states
    localparam S_IDLE       = 4'd0;
    localparam S_LATCH_0    = 4'd1;
    localparam S_LATCH_1    = 4'd2;
    localparam S_DECODE     = 4'd3;
    localparam S_PRP_CALC   = 4'd4;
    localparam S_PRP_SIMPLE = 4'd5;
    localparam S_PRP_DUAL   = 4'd6;
    localparam S_PRP_LIST   = 4'd7;
    localparam S_INJECT     = 4'd8;

    reg [3:0] state;

    // Per-queue mailbox latch (24B = 3 x 8B)
    reg [63:0] latch_w0 [0:NUM_QUEUES-1]; // bytes [0:7]
    reg [63:0] latch_w1 [0:NUM_QUEUES-1]; // bytes [8:15]
    reg [63:0] latch_w2 [0:NUM_QUEUES-1]; // bytes [16:23]
    reg [1:0]  write_count [0:NUM_QUEUES-1];

    // Per-queue CID counter
    reg [DW-1:0] cid_counter [0:NUM_QUEUES-1];

    // Current command being processed
    reg [QW-1:0] cur_qid;
    reg [7:0]    cur_opcode;
    reg [7:0]    cur_flags;
    reg [15:0]   cur_nsid;
    reg [63:0]   cur_lba;
    reg [15:0]   cur_nlb;
    reg [15:0]   cur_qpair_id;
    reg [63:0]   cur_buf_addr;
    reg [DW-1:0] cur_cid;

    // PRP state
    reg [31:0] cur_transfer_size;
    reg [63:0] cur_prp1;
    reg [63:0] cur_prp2;
    reg [PW-1:0] prp_idx;
    reg [PW-1:0] prp_count;

    // SQ SRAM base = 0 (SQ buffers start at address 0)
    // Each SQE = 64B = 4 x 128b words. But we write in a simplified way.
    // For the SRAM model, each SQE occupies 4 consecutive 128b addresses.
    // SQE addr = (qid * QUEUE_DEPTH + cid) * 4

    // PRP SRAM base = after SQ + CQ regions
    localparam PRP_SRAM_BASE = NUM_QUEUES * QUEUE_DEPTH * 4  // SQ region
                              + NUM_QUEUES * QUEUE_DEPTH;     // CQ region

    // Stat flags
    reg inject_done;
    reg prp_was_simple;
    reg prp_was_list;
    assign stat_mailbox_sub = inject_done;
    assign stat_prp_simple  = inject_done & prp_was_simple;
    assign stat_prp_list    = inject_done & prp_was_list;

    // Address decode: is this a mailbox write?
    wire mailbox_hit = mmio_wr_valid &&
                       (mmio_wr_addr >= MAILBOX_BASE) &&
                       (mmio_wr_addr < MAILBOX_BASE + NUM_QUEUES * MAILBOX_STRIDE);
    wire [QW-1:0] mailbox_qid = (mmio_wr_addr - MAILBOX_BASE) / MAILBOX_STRIDE;
    wire [4:0] mailbox_offset = (mmio_wr_addr - MAILBOX_BASE) % MAILBOX_STRIDE;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cur_qid <= 0;
            sram_req <= 0; sram_wr <= 0; sram_addr <= 0; sram_wdata <= 0;
            credit_dec <= 0;
            sq_ready <= 0; sq_qid <= 0;
            inject_done <= 0;
            prp_was_simple <= 0;
            prp_was_list <= 0;
            prp_idx <= 0; prp_count <= 0;
            cur_opcode <= 0; cur_flags <= 0; cur_nsid <= 0;
            cur_lba <= 0; cur_nlb <= 0; cur_qpair_id <= 0;
            cur_buf_addr <= 0; cur_cid <= 0;
            cur_transfer_size <= 0; cur_prp1 <= 0; cur_prp2 <= 0;
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                latch_w0[i] <= 0; latch_w1[i] <= 0; latch_w2[i] <= 0;
                write_count[i] <= 0;
                cid_counter[i] <= 0;
            end
        end else begin
            // Defaults
            credit_dec  <= 0;
            sq_ready    <= 0;
            inject_done <= 0;
            sram_req    <= 0;

            case (state)
                S_IDLE: begin
                    if (mailbox_hit) begin
                        cur_qid <= mailbox_qid;
                        if (mailbox_offset == 5'd0) begin
                            // First 8B write
                            latch_w0[mailbox_qid] <= mmio_wr_data;
                            write_count[mailbox_qid] <= 2'd1;
                            state <= S_LATCH_0;
                        end
                    end
                end

                S_LATCH_0: begin
                    // Wait for second write
                    if (mailbox_hit && mailbox_qid == cur_qid && mailbox_offset == 5'd8) begin
                        latch_w1[cur_qid] <= mmio_wr_data;
                        write_count[cur_qid] <= 2'd2;
                        state <= S_LATCH_1;
                    end
                end

                S_LATCH_1: begin
                    // Wait for third write
                    if (mailbox_hit && mailbox_qid == cur_qid && mailbox_offset == 5'd16) begin
                        latch_w2[cur_qid] <= mmio_wr_data;
                        write_count[cur_qid] <= 2'd0;
                        state <= S_DECODE;
                    end
                end

                S_DECODE: begin
                    // Parse compact SQE fields from latched 24B
                    cur_opcode   <= latch_w0[cur_qid][7:0];
                    cur_flags    <= latch_w0[cur_qid][15:8];
                    cur_nsid     <= latch_w0[cur_qid][31:16];
                    cur_lba      <= {latch_w1[cur_qid][31:0], latch_w0[cur_qid][63:32]};
                    cur_nlb      <= latch_w1[cur_qid][47:32];
                    cur_qpair_id <= latch_w1[cur_qid][63:48];
                    cur_buf_addr <= latch_w2[cur_qid];

                    // Assign CID
                    cur_cid <= cid_counter[cur_qid];
                    cid_counter[cur_qid] <= (cid_counter[cur_qid] == QUEUE_DEPTH[DW-1:0] - 1) ?
                                            {DW{1'b0}} : cid_counter[cur_qid] + 1'b1;

                    // Check credit availability (stall if none)
                    if (credit_avail) begin
                        state <= S_PRP_CALC;
                    end
                    // else: stay in S_DECODE until credit available
                end

                S_PRP_CALC: begin
                    // transfer_size = (nlb + 1) * LBA_SIZE
                    cur_transfer_size <= ({16'd0, cur_nlb} + 32'd1) * LBA_SIZE;
                    cur_prp1 <= cur_buf_addr;
                    state <= S_PRP_SIMPLE; // default, overridden below
                    prp_was_simple <= 1;
                    prp_was_list <= 0;

                    if (({16'd0, cur_nlb} + 32'd1) * LBA_SIZE <= PAGE_SIZE) begin
                        state <= S_PRP_SIMPLE;
                        prp_was_simple <= 1;
                    end else if (({16'd0, cur_nlb} + 32'd1) * LBA_SIZE <= 2 * PAGE_SIZE) begin
                        state <= S_PRP_DUAL;
                        prp_was_simple <= 1; // dual counts as simple
                    end else begin
                        state <= S_PRP_LIST;
                        prp_count <= (({16'd0, cur_nlb} + 32'd1) * LBA_SIZE - PAGE_SIZE)
                                     / PAGE_SIZE;
                        prp_idx <= 0;
                        prp_was_simple <= 0;
                        prp_was_list <= 1;
                    end
                end

                S_PRP_SIMPLE: begin
                    cur_prp2 <= 64'd0;
                    state <= S_INJECT;
                end

                S_PRP_DUAL: begin
                    cur_prp2 <= cur_buf_addr + PAGE_SIZE;
                    state <= S_INJECT;
                end

                S_PRP_LIST: begin
                    // Write PRP entries to SRAM one per cycle
                    sram_req <= 1;
                    sram_wr  <= 1;
                    sram_addr <= PRP_SRAM_BASE[SRAM_ADDR_WIDTH-1:0]
                                 + {{(SRAM_ADDR_WIDTH-QW-DW-PW){1'b0}}, cur_qid, cur_cid, prp_idx};
                    sram_wdata <= {{(DATA_WIDTH-64){1'b0}},
                                   cur_buf_addr + ({32'd0, prp_idx} + 64'd1) * PAGE_SIZE};

                    if (sram_grant) begin
                        if (prp_idx == prp_count - 1) begin
                            cur_prp2 <= PRP_SRAM_BASE[SRAM_ADDR_WIDTH-1:0]
                                        + {{(SRAM_ADDR_WIDTH-QW-DW-PW){1'b0}}, cur_qid, cur_cid, {PW{1'b0}}};
                            state <= S_INJECT;
                        end else begin
                            prp_idx <= prp_idx + 1'b1;
                        end
                    end
                end

                S_INJECT: begin
                    // Write SQE to SRAM
                    sram_req <= 1;
                    sram_wr  <= 1;
                    // SQE base address: (qid * QD + cid) * 4 (4 words per SQE)
                    sram_addr <= {{(SRAM_ADDR_WIDTH-QW-DW-2){1'b0}}, cur_qid, cur_cid, 2'b00};
                    // Pack key fields into first 128b word
                    sram_wdata <= {cur_prp2, cur_prp1}; // PRP1 + PRP2

                    if (sram_grant) begin
                        credit_dec  <= 1;
                        sq_ready    <= 1;
                        sq_qid      <= cur_qid;
                        inject_done <= 1;
                        state       <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
