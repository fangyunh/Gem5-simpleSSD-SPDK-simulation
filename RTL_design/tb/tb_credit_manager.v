// tb_credit_manager.v — Self-checking testbench for credit_manager
`timescale 1ns / 1ps

module tb_credit_manager;

    parameter CREDITS_MAX = 4; // Small for fast testing

    reg  clk, rst_n;
    reg  credit_dec, credit_inc;
    wire credit_avail;
    wire [31:0] credit_count;
    wire stat_credit_stall;

    integer errors = 0;
    integer test_num = 0;

    credit_manager #(.CREDITS_MAX(CREDITS_MAX)) dut (
        .clk(clk), .rst_n(rst_n),
        .credit_dec(credit_dec), .credit_inc(credit_inc),
        .credit_avail(credit_avail),
        .credit_count(credit_count),
        .stat_credit_stall(stat_credit_stall)
    );

    // Clock: 1 GHz = 1 ns period
    always #0.5 clk = ~clk;

    task check(input [31:0] exp_count, input exp_avail, input [127:0] msg);
        begin
            if (credit_count !== exp_count || credit_avail !== exp_avail) begin
                $display("FAIL [T%0d] %0s: count=%0d (exp %0d) avail=%0b (exp %0b)",
                         test_num, msg, credit_count, exp_count, credit_avail, exp_avail);
                errors = errors + 1;
            end else begin
                $display("PASS [T%0d] %0s", test_num, msg);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_credit_manager.vcd");
        $dumpvars(0, tb_credit_manager);

        clk = 0; rst_n = 0; credit_dec = 0; credit_inc = 0;
        #2; rst_n = 1; #1;

        // T1: After reset, credits = CREDITS_MAX
        test_num = 1;
        check(CREDITS_MAX, 1, "reset value");

        // T2: Decrement to 0
        test_num = 2;
        repeat (CREDITS_MAX) begin
            credit_dec = 1; @(posedge clk); #0.1;
        end
        credit_dec = 0; @(posedge clk); #0.1;
        check(0, 0, "decremented to zero");

        // T3: Stall on further decrement
        test_num = 3;
        credit_dec = 1; @(posedge clk); #0.1;
        if (stat_credit_stall !== 1) begin
            $display("FAIL [T3] stall not asserted at zero");
            errors = errors + 1;
        end else begin
            $display("PASS [T3] stall asserted at zero");
        end
        credit_dec = 0;
        check(0, 0, "no underflow");

        // T4: Increment back to max
        test_num = 4;
        repeat (CREDITS_MAX) begin
            credit_inc = 1; @(posedge clk); #0.1;
        end
        credit_inc = 0; @(posedge clk); #0.1;
        check(CREDITS_MAX, 1, "incremented to max");

        // T5: No overflow past max
        test_num = 5;
        credit_inc = 1; @(posedge clk); #0.1;
        credit_inc = 0; @(posedge clk); #0.1;
        check(CREDITS_MAX, 1, "no overflow past max");

        // T6: Simultaneous inc + dec = no change
        test_num = 6;
        credit_dec = 1; @(posedge clk); #0.1; // dec to MAX-1
        credit_dec = 0; @(posedge clk); #0.1;
        check(CREDITS_MAX - 1, 1, "dec to MAX-1");
        credit_inc = 1; credit_dec = 1;
        @(posedge clk); #0.1;
        credit_inc = 0; credit_dec = 0;
        @(posedge clk); #0.1;
        check(CREDITS_MAX - 1, 1, "simultaneous inc+dec no change");

        // Summary
        $display("---");
        if (errors == 0)
            $display("credit_manager: ALL TESTS PASSED");
        else
            $display("credit_manager: %0d ERRORS", errors);
        $finish;
    end

endmodule
