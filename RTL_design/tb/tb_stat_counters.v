// tb_stat_counters.v — Self-checking testbench for stat_counters
`timescale 1ns / 1ps

module tb_stat_counters;

    parameter NUM_COUNTERS = 10;

    reg  clk, rst_n;
    reg  [NUM_COUNTERS-1:0] stat_inc;
    reg  [3:0]  stat_rd_addr;
    wire [63:0] stat_rd_data;
    reg  stat_reset;

    integer errors = 0;

    stat_counters #(.NUM_COUNTERS(NUM_COUNTERS)) dut (
        .clk(clk), .rst_n(rst_n),
        .stat_inc(stat_inc),
        .stat_rd_addr(stat_rd_addr),
        .stat_rd_data(stat_rd_data),
        .stat_reset(stat_reset)
    );

    always #0.5 clk = ~clk;

    task check_counter(input [3:0] idx, input [63:0] expected, input [127:0] msg);
        begin
            stat_rd_addr = idx;
            #0.1;
            if (stat_rd_data !== expected) begin
                $display("FAIL %0s: counter[%0d]=%0d (exp %0d)", msg, idx, stat_rd_data, expected);
                errors = errors + 1;
            end else begin
                $display("PASS %0s", msg);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_stat_counters.vcd");
        $dumpvars(0, tb_stat_counters);

        clk = 0; rst_n = 0; stat_inc = 0; stat_rd_addr = 0; stat_reset = 0;
        #2; rst_n = 1; #1;

        // T1: All counters zero after reset
        check_counter(0, 0, "reset counter 0");
        check_counter(9, 0, "reset counter 9");

        // T2: Increment counter 0 three times
        stat_inc = 10'b0000000001;
        @(posedge clk); @(posedge clk); @(posedge clk); #0.1;
        stat_inc = 0; @(posedge clk); #0.1;
        check_counter(0, 3, "counter 0 incremented 3x");
        check_counter(1, 0, "counter 1 still zero");

        // T3: Increment multiple counters simultaneously
        stat_inc = 10'b0000001010; // counters 1 and 3
        @(posedge clk); @(posedge clk); #0.1;
        stat_inc = 0; @(posedge clk); #0.1;
        check_counter(1, 2, "counter 1 incremented 2x");
        check_counter(3, 2, "counter 3 incremented 2x");
        check_counter(0, 3, "counter 0 unchanged");

        // T4: Bulk reset
        stat_reset = 1; @(posedge clk); #0.1;
        stat_reset = 0; @(posedge clk); #0.1;
        check_counter(0, 0, "counter 0 after reset");
        check_counter(1, 0, "counter 1 after reset");
        check_counter(3, 0, "counter 3 after reset");

        // T5: Out-of-range read returns 0
        check_counter(4'd15, 0, "out-of-range returns 0");

        // Summary
        $display("---");
        if (errors == 0)
            $display("stat_counters: ALL TESTS PASSED");
        else
            $display("stat_counters: %0d ERRORS", errors);
        $finish;
    end

endmodule
