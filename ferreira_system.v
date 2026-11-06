
`timescale 1ns/1ps

// ================================================
// 64-BIT BANKED CONFIGURATION MEMORY
// ================================================

module ferreira_config_memory #(
    parameter integer W = 128,
    parameter integer DEPTH = 32,
    parameter integer AW = $clog2(DEPTH),
    parameter integer BANKS = (W+63)/64,
    parameter integer BW =
        (BANKS < 2) ? 1 : $clog2(BANKS)
)(
    input wire clk,

    input wire write_en,
    input wire [AW-1:0] write_addr,
    input wire [BW-1:0] write_bank,
    input wire [63:0] write_data,

    input wire [AW-1:0] read_addr,
    output wire [W-1:0] read_word
);

    wire [BANKS*64-1:0] bank_outputs;

    genvar b;

    generate
        for (b = 0; b < BANKS; b = b+1) begin: BANK

            (* ram_style = "block" *)
            reg [63:0] memory [0:DEPTH-1];

            reg [63:0] read_reg;

            always @(posedge clk) begin

                if (write_en && write_bank == b)
                    memory[write_addr] <= write_data;

                read_reg <= memory[read_addr];

            end

            assign bank_outputs[b*64 +: 64] =
                read_reg;

        end
    endgenerate

    assign read_word = bank_outputs[W-1:0];

endmodule


// ================================================
// INTEGRATED FERREIRA ACCELERATOR
// ================================================

module ferreira_system #(
    parameter integer N = 4,
    parameter integer KMAX = 8,

    // Must be a power of two
    parameter integer ROUTE_N = 16,

    parameter integer SUBSTEPS = 2,
    parameter integer RUNTIME_CONFIG = 0,
    parameter integer PIPE_ROUTING = 0,
    parameter integer DEPTH = 32,
    parameter integer MAX_DEGREE = 256,

    parameter integer CW = $clog2(MAX_DEGREE+1),
    parameter integer AW = $clog2(DEPTH),

    parameter integer L = $clog2(ROUTE_N),
    parameter integer STAGES = L+2,

    parameter integer SWITCH_W =
        (ROUTE_N/2)*STAGES,

    // Switch bits + destination valid masks
    // + inhibitor masks
    parameter integer MEM_W =
        SWITCH_W + 2*ROUTE_N,

    parameter integer BANKS = (MEM_W+63)/64,

    parameter integer BW =
        (BANKS < 2) ? 1 : $clog2(BANKS),

    parameter integer SW =
        (SUBSTEPS < 2) ? 1 :
        $clog2(SUBSTEPS),

    parameter [3*N-1:0] CAP_LOG2 =
        12'b011_010_001_000
)(
    input wire clk,
    input wire reset,
    input wire start,

    input wire [N-1:0] seed,
    input wire [SW-1:0] last_substep_index,

    // Load one 64-bit memory bank at a time
    input wire cfg_write_en,
    input wire [AW-1:0] cfg_write_addr,
    input wire [BW-1:0] cfg_write_bank,
    input wire [63:0] cfg_write_data,

    // Gene update rules
    input wire [N-1:0] rule,
    input wire [N*CW-1:0] degree,

    output wire done,
    output wire [N:0] period,

    output wire [N-1:0] slow_state,
    output wire [N-1:0] fast_state,

    output wire [SW-1:0] substep,
    output wire phase2
);

    // ----------------------------------------
    // Compute packed PE slot offsets
    // ----------------------------------------

    function integer slot_base;
        input integer gene;
        integer i;

        begin
            slot_base = 0;

            for (i = 0; i < gene; i = i+1)
                slot_base = slot_base +
                    (1 << CAP_LOG2[3*i +: 3]);
        end
    endfunction

    localparam integer USED_LINES = slot_base(N);

    // ----------------------------------------
    // Routing and controller signals
    // ----------------------------------------

    wire [N-1:0] route_state;

    wire step_valid;
    wire active_fast;
    wire update;

    wire [ROUTE_N-1:0] min_input;
    wire [ROUTE_N-1:0] min_output;

    wire [N*KMAX-1:0] routed_inputs;
    wire [N*KMAX-1:0] valid_mask;
    wire [N*KMAX-1:0] inhibitor_mask;

    wire [SWITCH_W-1:0] switch_config;
    wire [ROUTE_N-1:0] valid_config;
    wire [ROUTE_N-1:0] inhibit_config;
    wire [ROUTE_N-1:0] valid_config_raw, inhibit_config_raw;

    // ----------------------------------------
    // Configuration memory
    // ----------------------------------------

    wire [MEM_W-1:0] memory_word;
    wire [AW-1:0] memory_read_addr;

    // One-cycle lookahead for synchronous BRAM.
    //
    // During sub-step s, fetch s+1.
    // At the final sub-step, fetch 0 for
    // the next complete network update.

    assign memory_read_addr =
        (step_valid && !update) ?
            (substep + 1'b1) :
            {AW{1'b0}};

    ferreira_config_memory #(
        .W(MEM_W),
        .DEPTH(DEPTH)
    ) cfg_memory (
        .clk(clk),

        .write_en(cfg_write_en),
        .write_addr(cfg_write_addr),
        .write_bank(cfg_write_bank),
        .write_data(cfg_write_data),

        .read_addr(memory_read_addr),
        .read_word(memory_word)
    );

    assign switch_config =
        memory_word[0 +: SWITCH_W];

    assign valid_config_raw =
        memory_word[SWITCH_W +: ROUTE_N];

    assign inhibit_config_raw =
        memory_word[SWITCH_W+ROUTE_N +: ROUTE_N];
    generate if(PIPE_ROUTING==2) begin: MASK_PIPELINE
        reg [ROUTE_N-1:0] valid_q, inhibit_q;
        always @(posedge clk) begin valid_q<=valid_config_raw; inhibit_q<=inhibit_config_raw; end
        assign valid_config=valid_q;
        assign inhibit_config=inhibit_q;
    end else begin: DIRECT_MASKS
        assign valid_config=valid_config_raw;
        assign inhibit_config=inhibit_config_raw;
    end endgenerate

    // ----------------------------------------
    // Pack source state copies onto MIN lines
    // and unpack routed lines into PEs.
    //
    // This uses fixed source replication.
    // The mapping must be validated against
    // the original paper's physical layout.
    // ----------------------------------------

    genvar g, j, p;

    generate

        for (g = 0; g < N; g = g+1) begin: GENE_MAP

            localparam integer K =
                1 << CAP_LOG2[3*g +: 3];

            localparam integer BASE = slot_base(g);

            for (j = 0; j < K; j = j+1) begin: SLOT

                // Copies of source gene output
                assign min_input[BASE+j] =
                    route_state[g];

                // MIN output into corresponding PE
                assign routed_inputs[g*KMAX+j] =
                    min_output[BASE+j];

                assign valid_mask[g*KMAX+j] =
                    valid_config[BASE+j];

                assign inhibitor_mask[g*KMAX+j] =
                    inhibit_config[BASE+j];

            end

            // Tie off unused padded PE lanes
            for (j = K; j < KMAX; j = j+1) begin: PAD

                assign routed_inputs[g*KMAX+j] = 0;
                assign valid_mask[g*KMAX+j] = 0;
                assign inhibitor_mask[g*KMAX+j] = 0;

            end

        end

        // Unused MIN input lines
        for (p = USED_LINES; p < ROUTE_N; p = p+1)
            assign min_input[p] = 1'b0;

    endgenerate

    // ----------------------------------------
    // Extra-stage multistage network
    // ----------------------------------------

    ferreira_min #(
        .N(ROUTE_N), .PIPE_MIDDLE(PIPE_ROUTING==2)
    ) min_network (
        .clk(clk),
        .data_in(min_input),
        .cfg(switch_config),
        .data_out(min_output)
    );

    // ----------------------------------------
    // Heterogeneous PEs and global controller
    // ----------------------------------------

    ferreira_engine #(
        .N(N),
        .KMAX(KMAX),
        .SUBSTEPS(SUBSTEPS),
        .RUNTIME_CONFIG(RUNTIME_CONFIG),
        .PIPE_ROUTING(PIPE_ROUTING),
        .MAX_DEGREE(MAX_DEGREE),
        .CAP_LOG2(CAP_LOG2)
    ) engine (
        .clk(clk),
        .reset(reset),
        .start(start),
        .seed(seed),
        .last_substep_index(last_substep_index),

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

endmodule
