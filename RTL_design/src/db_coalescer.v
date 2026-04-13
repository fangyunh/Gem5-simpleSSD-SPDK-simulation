// db_coalescer.v — Doorbell aggregation FSM
// Batches per-I/O doorbell writes into coalesced device notifications.
// Two triggers: count threshold (COALESCE_COUNT) or timeout (TIMEOUT_CYCLES).
// No SRAM access — all state in flip-flops.

module db_coalescer #(
    parameter NUM_QUEUES     = 16,
    parameter COALESCE_COUNT = 4,
    parameter TIMEOUT_CYCLES = 100
) (
    input  wire clk,
    input  wire rst_n,

    // From MMIO decoder
    input  wire                         db_wr_valid,
    input  wire [$clog2(NUM_QUEUES)-1:0] db_wr_qid,
    input  wire [15:0]                  db_wr_tail,
    input  wire                         db_wr_is_sq,

    // To NVMe device
    output reg                          dev_db_valid,
    output reg  [$clog2(NUM_QUEUES)-1:0] dev_db_qid,
    output reg  [15:0]                  dev_db_tail,
    output reg                          dev_db_is_sq,

    // Stats
    output wire stat_db_received,
    output wire stat_db_coalesced
);

    localparam QW = $clog2(NUM_QUEUES);
    localparam CW = $clog2(COALESCE_COUNT + 1);
    localparam TW = $clog2(TIMEOUT_CYCLES + 1);

    // Per-queue state arrays
    reg [15:0] latest_tail [0:NUM_QUEUES-1];
    reg        latest_is_sq [0:NUM_QUEUES-1];
    reg [CW-1:0] db_count  [0:NUM_QUEUES-1];
    reg [TW-1:0] timer     [0:NUM_QUEUES-1];
    reg          timer_active [0:NUM_QUEUES-1];

    // FSM states
    localparam S_IDLE       = 2'd0;
    localparam S_ACCUMULATE = 2'd1;
    localparam S_EVAL       = 2'd2;
    localparam S_SEND       = 2'd3;

    reg [1:0] state;
    reg [QW-1:0] cur_qid;

    // Stat pulses
    assign stat_db_received  = (state == S_ACCUMULATE);
    assign stat_db_coalesced = (state == S_SEND);

    integer i;

    // Timer tick: decrement all active timers every cycle
    // (done outside FSM for parallel operation)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                timer[i] <= 0;
                timer_active[i] <= 0;
            end
        end else begin
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                if (state == S_SEND && cur_qid == i[QW-1:0]) begin
                    // Reset on send
                    timer[i] <= 0;
                    timer_active[i] <= 0;
                end else if (state == S_ACCUMULATE && cur_qid == i[QW-1:0]) begin
                    // Start or refresh timer on accumulate
                    timer[i] <= TIMEOUT_CYCLES[TW-1:0];
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
            state <= S_IDLE;
            cur_qid <= 0;
            dev_db_valid <= 0;
            dev_db_qid   <= 0;
            dev_db_tail  <= 0;
            dev_db_is_sq <= 0;
            for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                latest_tail[i] <= 0;
                latest_is_sq[i] <= 0;
                db_count[i] <= 0;
            end
        end else begin
            dev_db_valid <= 0; // default: no output

            case (state)
                S_IDLE: begin
                    if (db_wr_valid) begin
                        cur_qid <= db_wr_qid;
                        latest_tail[db_wr_qid] <= db_wr_tail;
                        latest_is_sq[db_wr_qid] <= db_wr_is_sq;
                        db_count[db_wr_qid] <= db_count[db_wr_qid] + 1'b1;
                        state <= S_EVAL; // skip ACCUMULATE since we update inline
                    end else begin
                        // Check for timer expiry on any queue
                        for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                            if (timer_active[i] && timer[i] == 0 && db_count[i] > 0) begin
                                cur_qid <= i[QW-1:0];
                                state <= S_SEND;
                            end
                        end
                    end
                end

                S_EVAL: begin
                    if (db_count[cur_qid] >= COALESCE_COUNT[CW-1:0]) begin
                        state <= S_SEND;
                    end else if (timer_active[cur_qid] && timer[cur_qid] == 0) begin
                        state <= S_SEND;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                S_SEND: begin
                    dev_db_valid <= 1;
                    dev_db_qid   <= cur_qid;
                    dev_db_tail  <= latest_tail[cur_qid];
                    dev_db_is_sq <= latest_is_sq[cur_qid];
                    db_count[cur_qid] <= 0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
