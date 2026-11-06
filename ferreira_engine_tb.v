
`timescale 1ns/1ps

module ferreira_engine_tb;

    localparam integer N = 4;
    localparam integer KMAX = 8;
    localparam integer CW = 9;

    // Clock
    reg clk = 0;
    always #5 clk = ~clk;

    // Control signals
    reg reset = 1;
    reg start = 0;
    reg [N-1:0] seed = 0;

    // Routing inputs
    reg [N*KMAX-1:0] routed_inputs;
    reg [N*KMAX-1:0] valid_mask;
    reg [N*KMAX-1:0] inhibitor_mask;

    // Engine outputs
    wire [N-1:0] route_state;
    wire [N-1:0] slow_state;
    wire [N-1:0] fast_state;

    wire [0:0] substep;
    wire step_valid;
    wire active_fast;
    wire update;
    wire phase2;
    wire done;
    wire [N:0] period;

    // All genes use activator/inhibitor logic.
    // Each gene has exactly one incoming edge.
    wire [N-1:0] rule = 0;
    wire [N*CW-1:0] degree = {N{9'd1}};

    // ==========================================
    // DUT: Ferreira engine
    // ==========================================

    ferreira_engine #(
        .N(N),
        .KMAX(KMAX),
        .SUBSTEPS(2),
        .CAP_LOG2(12'b011_010_001_000)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .seed(seed),

        .routed_inputs(routed_inputs),
        .valid_mask(valid_mask),
        .inhibitor_mask(inhibitor_mask),

        .rule(rule),
        .degree(degree),

        .route_state(route_state),
        .substep(substep),
        .step_valid(step_valid),
        .active_fast(active_fast),
        .update(update),
        .phase2(phase2),

        .slow_state(slow_state),
        .fast_state(fast_state),
        .done(done),
        .period(period)
    );

    // ==========================================
    // Temporary direct routing
    // ==========================================

    // Boolean network:
    //
    // gene0' = gene1
    // gene1' = gene0
    // gene2' = gene2
    // gene3' = gene3
    //
    // The first two genes form a 2-cycle
    // for seeds 0001 and 0010.
    //
    // We use the first sub-step for routing.
    // The second sub-step has no valid inputs.

    always @(*) begin

        routed_inputs = 0;
        valid_mask = 0;
        inhibitor_mask = 0;

        // Gene 0 receives gene 1
        routed_inputs[0] = route_state[1];

        // Gene 1 receives gene 0
        routed_inputs[8] = route_state[0];

        // Gene 2 receives itself
        routed_inputs[16] = route_state[2];

        // Gene 3 receives itself
        routed_inputs[24] = route_state[3];

        if (step_valid && substep == 0) begin
            valid_mask[0] = 1;
            valid_mask[8] = 1;
            valid_mask[16] = 1;
            valid_mask[24] = 1;
        end

    end

    // ==========================================
    // Check synchronous state updates
    // ==========================================

    reg [N-1:0] old_slow;
    reg [N-1:0] old_fast;

    always @(posedge clk) begin

        if (!reset && step_valid && !update) begin

            old_slow = slow_state;
            old_fast = fast_state;

            #1;

            if (slow_state !== old_slow ||
                fast_state !== old_fast) begin

                $fatal(1,
                    "ERROR: State changed before final substep");

            end
        end

    end

    // ==========================================
    // Reusable attractor test
    // ==========================================

    task run_case;

        input [N-1:0] initial_state;
        input [N:0] expected_period;

        begin

            // Reset engine
            @(negedge clk);
            reset = 1;
            start = 0;
            seed = initial_state;

            // Start computation
            @(negedge clk);
            reset = 0;
            start = 1;

            @(negedge clk);
            start = 0;

            // Wait for completion
            wait(done === 1'b1);
            #1;

            // Verify attractor period
            if (period !== expected_period) begin

                $fatal(1,
                    "Wrong period: seed=%b expected=%0d got=%0d",
                    initial_state,
                    expected_period,
                    period
                );

            end

            // Slow and fast states must agree
            if (slow_state !== fast_state) begin

                $fatal(1,
                    "Final slow and fast states differ");

            end

            // Verify Phase 2 was reached
            if (!phase2) begin

                $fatal(1,
                    "Controller did not enter Phase 2");

            end

            $display(
                "PASS: seed=%b period=%0d",
                initial_state,
                period
            );

        end

    endtask

    // ==========================================
    // Main test sequence
    // ==========================================

    initial begin

        // Test 1: Period-2 attractor
        //
        // 0001 -> 0010 -> 0001

        run_case(4'b0001, 5'd2);

        // Test 2: Fixed-point attractor
        //
        // 0011 -> 0011

        run_case(4'b0011, 5'd1);

        $display("--------------------------------");
        $display("ALL FERREIRA ENGINE TESTS PASSED");
        $display("--------------------------------");

        $finish;

    end

    // ==========================================
    // Timeout protection
    // ==========================================

    initial begin

        #50000;

        $fatal(1,
            "ERROR: Simulation timeout");

    end

endmodule
