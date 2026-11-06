
`timescale 1ns/1ps

module ferreira_pe #(
    parameter integer K = 4,
    parameter integer MAX_DEGREE = 256,
    parameter integer CW = $clog2(MAX_DEGREE + 1)
)(
    input wire clk,
    input wire reset,

    // Initial gene state
    input wire load_seed,
    input wire seed,

    // Global sub-step control
    input wire step_valid,
    input wire first_substep,
    input wire last_substep,

    // Routed input signals
    input wire [K-1:0] inputs,
    input wire [K-1:0] valid_mask,
    input wire [K-1:0] inhibitor_mask,

    // Boolean update rule
    // 0 = activator/inhibitor
    // 1 = strict majority
    input wire rule,
    input wire [CW-1:0] degree,

    output reg state
);

    // Partial results across sub-steps
    reg activator_acc;
    reg inhibitor_acc;
    reg [CW-1:0] count_acc;

    // Current sub-step results
    reg chunk_activator;
    reg chunk_inhibitor;
    reg [CW-1:0] chunk_count;

    integer i;

    always @(*) begin
        chunk_activator = 1'b0;
        chunk_inhibitor = 1'b0;
        chunk_count = 0;

        for (i = 0; i < K; i = i + 1) begin
            if (valid_mask[i]) begin

                if (inputs[i]) begin
                    chunk_count = chunk_count + 1'b1;

                    if (inhibitor_mask[i])
                        chunk_inhibitor = 1'b1;
                    else
                        chunk_activator = 1'b1;
                end

            end
        end
    end

    // Include earlier sub-steps unless this is
    // the first sub-step of a new gene update.
    wire total_activator =
        (first_substep ? 1'b0 : activator_acc)
        | chunk_activator;

    wire total_inhibitor =
        (first_substep ? 1'b0 : inhibitor_acc)
        | chunk_inhibitor;

    wire [CW-1:0] total_count =
        (first_substep ? {CW{1'b0}} : count_acc)
        + chunk_count;

    wire next_gene_state =
        rule ?
            (total_count > (degree >> 1)) :
            (total_activator & ~total_inhibitor);

    always @(posedge clk) begin

        if (reset) begin
            state <= 0;
            activator_acc <= 0;
            inhibitor_acc <= 0;
            count_acc <= 0;
        end

        else if (load_seed) begin
            state <= seed;
            activator_acc <= 0;
            inhibitor_acc <= 0;
            count_acc <= 0;
        end

        else if (step_valid) begin

            activator_acc <= total_activator;
            inhibitor_acc <= total_inhibitor;
            count_acc <= total_count;

            // Visible state changes only after
            // the final sub-step.
            if (last_substep)
                state <= next_gene_state;

        end

    end

endmodule
