
`timescale 1ns/1ps

// ==================================================
// HETEROGENEOUS PROCESSING ELEMENT ARRAY
// ==================================================

module ferreira_bank #(
    parameter integer N = 4,
    parameter integer KMAX = 8,
    parameter integer MAX_DEGREE = 256,
    parameter integer CW = $clog2(MAX_DEGREE+1),

    // Three bits per gene encode log2(PE capacity).
    // Default: gene 0=1, gene 1=2,
    //          gene 2=4, gene 3=8.
    parameter [3*N-1:0] CAP_LOG2 =
        12'b011_010_001_000
)(
    input wire clk,
    input wire reset,
    input wire load_seed,

    input wire [N-1:0] seed,

    input wire step_valid,
    input wire first_substep,
    input wire last_substep,

    input wire [N*KMAX-1:0] routed_inputs,
    input wire [N*KMAX-1:0] valid_mask,
    input wire [N*KMAX-1:0] inhibitor_mask,

    input wire [N-1:0] rule,
    input wire [N*CW-1:0] degree,

    output wire [N-1:0] state
);

    genvar g;

    generate
        for (g = 0; g < N; g = g + 1) begin: GENES

            localparam integer K =
                1 << CAP_LOG2[3*g +: 3];

            ferreira_pe #(
                .K(K),
                .MAX_DEGREE(MAX_DEGREE)
            ) pe (
                .clk(clk),
                .reset(reset),

                .load_seed(load_seed),
                .seed(seed[g]),

                .step_valid(step_valid),
                .first_substep(first_substep),
                .last_substep(last_substep),

                .inputs(routed_inputs[g*KMAX +: K]),
                .valid_mask(valid_mask[g*KMAX +: K]),
                .inhibitor_mask(
                    inhibitor_mask[g*KMAX +: K]
                ),

                .rule(rule[g]),
                .degree(degree[g*CW +: CW]),

                .state(state[g])
            );

        end
    endgenerate

endmodule


// ==================================================
// GLOBAL TWO-PHASE ATTRACTOR CONTROLLER
// ==================================================

module ferreira_engine #(
    parameter integer N = 4,
    parameter integer KMAX = 8,
    parameter integer SUBSTEPS = 2,
    parameter integer RUNTIME_CONFIG = 0,
    // Register routed data before the PE's counting logic.
    // Each routing substep takes two clocks when enabled.
    parameter integer PIPE_ROUTING = 0,
    parameter integer MAX_DEGREE = 256,

    parameter integer CW = $clog2(MAX_DEGREE+1),
    parameter integer SW =
        (SUBSTEPS < 2) ? 1 : $clog2(SUBSTEPS),

    parameter [3*N-1:0] CAP_LOG2 =
        12'b011_010_001_000
)(
    input wire clk,
    input wire reset,
    input wire start,

    input wire [N-1:0] seed,
    // Used only when RUNTIME_CONFIG=1; otherwise the original
    // SUBSTEPS parameter is retained for existing testbenches.
    input wire [SW-1:0] last_substep_index,

    // Inputs supplied by the routing network.
    input wire [N*KMAX-1:0] routed_inputs,
    input wire [N*KMAX-1:0] valid_mask,
    input wire [N*KMAX-1:0] inhibitor_mask,

    input wire [N-1:0] rule,
    input wire [N*CW-1:0] degree,

    // Routing interface
    output wire [N-1:0] route_state,
    output reg [SW-1:0] substep,
    output wire step_valid,
    output wire active_fast,
    output wire update,

    // Global simulation phase
    output reg phase2,

    // Attractor outputs
    output wire [N-1:0] slow_state,
    output wire [N-1:0] fast_state,
    output reg done,
    output reg [N:0] period
);

    localparam [2:0]
        IDLE          = 3'd0,
        SLOW_SEARCH   = 3'd1,
        FAST_FIRST    = 3'd2,
        FAST_SECOND   = 3'd3,
        CHECK_SEARCH  = 3'd4,
        SLOW_COUNT    = 3'd5,
        CHECK_PERIOD  = 3'd6,
        FINISHED      = 3'd7;

    reg [2:0] stage;

    wire load_seed;
    wire first_substep;
    wire last_substep;

    wire slow_enable;
    wire fast_enable;

    assign load_seed = (stage == IDLE) && start;

    assign slow_enable =
        (stage == SLOW_SEARCH) ||
        (stage == SLOW_COUNT);

    assign fast_enable =
        (stage == FAST_FIRST) ||
        (stage == FAST_SECOND);

    assign active_fast = fast_enable;

    // No extra cycle when PIPE_ROUTING=0 (legacy test compatibility).
    // In pipelined mode: capture routed inputs in cycle A, commit the
    // corresponding PE update in cycle B. The stage/substep only advance
    // on cycle B, and configuration BRAM prefetch is aligned to that edge.
    // Mode 2 adds a MIN middle register: wait, capture, commit. Modes 0/1
    // retain their original latency and legacy interface behavior.
    localparam integer RPW=(PIPE_ROUTING==2)?2:1;
    localparam integer COMMIT_PHASE=(PIPE_ROUTING==2)?2:1;
    localparam integer CAPTURE_PHASE=(PIPE_ROUTING==2)?1:0;
    reg [RPW-1:0] route_execute;
    reg [N*KMAX-1:0] routed_inputs_q;
    reg [N*KMAX-1:0] valid_mask_q;
    reg [N*KMAX-1:0] inhibitor_mask_q;
    wire in_update_stage = slow_enable || fast_enable;
    wire commit_substep = (!PIPE_ROUTING) || (route_execute==COMMIT_PHASE);

    always @(posedge clk) begin
        if (reset) begin
            route_execute <= 1'b0;
            routed_inputs_q <= 0;
            valid_mask_q <= 0;
            inhibitor_mask_q <= 0;
        end else if (PIPE_ROUTING) begin
            if (in_update_stage) begin
                if (route_execute==CAPTURE_PHASE) begin
                    routed_inputs_q <= routed_inputs;
                    valid_mask_q <= valid_mask;
                    inhibitor_mask_q <= inhibitor_mask;
                end
                route_execute <= commit_substep ? 0 : route_execute+1'b1;
            end else begin
                route_execute <= 1'b0;
            end
        end else begin
            route_execute <= 1'b0;
        end
    end

    wire [N*KMAX-1:0] pe_inputs =
        PIPE_ROUTING ? routed_inputs_q : routed_inputs;
    wire [N*KMAX-1:0] pe_valid_mask =
        PIPE_ROUTING ? valid_mask_q : valid_mask;
    wire [N*KMAX-1:0] pe_inhibitor_mask =
        PIPE_ROUTING ? inhibitor_mask_q : inhibitor_mask;

    // Exposed signal is the actual PE commit edge, used for BRAM prefetch.
    assign step_valid = in_update_stage && commit_substep;

    assign first_substep = (substep == 0);

    assign last_substep =
        (substep == (RUNTIME_CONFIG ?
                     last_substep_index : SUBSTEPS-1));

    // Global update occurs on the last sub-step.
    assign update = step_valid && last_substep;

    // Select the current simulation's source states.
    assign route_state =
        active_fast ? fast_state : slow_state;

    // ----------------------------------------------
    // Slow simulation: S
    // ----------------------------------------------

    ferreira_bank #(
        .N(N),
        .KMAX(KMAX),
        .MAX_DEGREE(MAX_DEGREE),
        .CAP_LOG2(CAP_LOG2)
    ) slow_bank (
        .clk(clk),
        .reset(reset),
        .load_seed(load_seed),
        .seed(seed),

        .step_valid(slow_enable && commit_substep),
        .first_substep(first_substep),
        .last_substep(last_substep),

        .routed_inputs(pe_inputs),
        .valid_mask(pe_valid_mask),
        .inhibitor_mask(pe_inhibitor_mask),

        .rule(rule),
        .degree(degree),

        .state(slow_state)
    );

    // ----------------------------------------------
    // Double-speed simulation: S2x
    // ----------------------------------------------

    ferreira_bank #(
        .N(N),
        .KMAX(KMAX),
        .MAX_DEGREE(MAX_DEGREE),
        .CAP_LOG2(CAP_LOG2)
    ) fast_bank (
        .clk(clk),
        .reset(reset),
        .load_seed(load_seed),
        .seed(seed),

        .step_valid(fast_enable && commit_substep),
        .first_substep(first_substep),
        .last_substep(last_substep),

        .routed_inputs(pe_inputs),
        .valid_mask(pe_valid_mask),
        .inhibitor_mask(pe_inhibitor_mask),

        .rule(rule),
        .degree(degree),

        .state(fast_state)
    );

    // ----------------------------------------------
    // Global controller
    // ----------------------------------------------

    always @(posedge clk) begin

        if (reset) begin
            stage   <= IDLE;
            substep <= 0;
            phase2  <= 0;
            period  <= 0;
            done    <= 0;
        end

        else begin

            case (stage)

                IDLE: begin
                    done <= 0;

                    if (start) begin
                        substep <= 0;
                        phase2 <= 0;
                        period <= 0;
                        stage <= SLOW_SEARCH;
                    end
                end

                // Phase 1: one S update
                SLOW_SEARCH: begin
                    if (commit_substep) begin
                        if (last_substep) begin
                            substep <= 0;
                            stage <= FAST_FIRST;
                        end else
                            substep <= substep + 1'b1;
                    end
                end

                // Phase 1: first S2x update
                FAST_FIRST: begin
                    if (commit_substep) begin
                        if (last_substep) begin
                            substep <= 0;
                            stage <= FAST_SECOND;
                        end else
                            substep <= substep + 1'b1;
                    end
                end

                // Phase 1: second S2x update
                FAST_SECOND: begin
                    if (commit_substep) begin
                        if (last_substep) begin
                            substep <= 0;
                            stage <= CHECK_SEARCH;
                        end else
                            substep <= substep + 1'b1;
                    end
                end

                CHECK_SEARCH: begin
                    if (slow_state == fast_state) begin
                        phase2 <= 1;
                        period <= 0;
                        stage <= SLOW_COUNT;
                    end
                    else
                        stage <= SLOW_SEARCH;
                end

                // Phase 2: advance only S
                SLOW_COUNT: begin
                    if (commit_substep) begin
                        if (last_substep) begin
                            substep <= 0;
                            stage <= CHECK_PERIOD;
                        end else
                            substep <= substep + 1'b1;
                    end
                end

                CHECK_PERIOD: begin
                    period <= period + 1'b1;

                    if (slow_state == fast_state) begin
                        done <= 1;
                        stage <= FINISHED;
                    end
                    else
                        stage <= SLOW_COUNT;
                end

                FINISHED: begin
                    done <= 1;
                end

                default: stage <= IDLE;

            endcase
        end
    end

endmodule
