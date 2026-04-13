// credit_manager.v — Global credit pool with backpressure
// Up/down saturating counter. Decrement on SQ submit, increment on CQ complete.
// Simultaneous inc+dec cancels out. Stall signal when credits=0.

module credit_manager #(
    parameter CREDITS_MAX = 64
) (
    input  wire clk,
    input  wire rst_n,

    // From SQ Engine
    input  wire credit_dec,
    // From CQ Engine
    input  wire credit_inc,

    // To SQ Engine
    output wire credit_avail,
    // To MMIO decoder (UNCORE_STATUS[31:0])
    output wire [31:0] credit_count,
    // To stat counters
    output wire stat_credit_stall
);

    // Width sufficient to hold CREDITS_MAX
    localparam CW = $clog2(CREDITS_MAX + 1);

    reg [CW-1:0] credits;

    // Credit available when count > 0
    assign credit_avail = (credits != 0);

    // Export as 32-bit for status register
    assign credit_count = {{(32-CW){1'b0}}, credits};

    // Stall: dec requested but credits already 0
    assign stat_credit_stall = credit_dec & ~credit_avail;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            credits <= CREDITS_MAX[CW-1:0];
        end else begin
            case ({credit_inc, credit_dec})
                2'b10: begin // increment only
                    if (credits < CREDITS_MAX[CW-1:0])
                        credits <= credits + 1'b1;
                end
                2'b01: begin // decrement only
                    if (credits > 0)
                        credits <= credits - 1'b1;
                end
                2'b11: begin // simultaneous — no change
                    credits <= credits;
                end
                default: begin
                    credits <= credits;
                end
            endcase
        end
    end

endmodule
