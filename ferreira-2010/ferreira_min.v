
`timescale 1ns/1ps

// ===================================================
// EXTRA-STAGE BLOCKING MIN
// N = physical routing lines (power of 2)
// ===================================================

module ferreira_min #(
    parameter integer N = 8,
    parameter integer L = $clog2(N),
    parameter integer STAGES = L + 2,
    parameter integer CFG_W = (N/2)*STAGES,
    parameter integer PIPE_MIDDLE = 0
)(
    input wire clk,
    input wire [N-1:0] data_in,
    input wire [CFG_W-1:0] cfg,
    output wire [N-1:0] data_out
);

    wire [N-1:0] level [0:STAGES];
    wire [N-1:0] switched [0:STAGES-1];

    assign level[0] = data_in;
    localparam integer CUT=STAGES/2;
    wire [N-1:0] middle_data;
    wire [CFG_W-1:0] middle_cfg;
    generate if(PIPE_MIDDLE) begin: MIDDLE_REGISTER
        reg [N-1:0] data_q;
        reg [CFG_W-1:0] cfg_q;
        always @(posedge clk) begin
            data_q<=level[CUT];
            cfg_q<=cfg;
        end
        assign middle_data=data_q;
        assign middle_cfg=cfg_q;
    end else begin: NO_MIDDLE_REGISTER
        assign middle_data=0;
        assign middle_cfg=0;
    end endgenerate

    genvar s, p, i;

    generate
        for (s = 0; s < STAGES; s = s + 1) begin: STAGE
            wire [N-1:0] stage_data=(PIPE_MIDDLE && s==CUT)?middle_data:level[s];

            // Each 2x2 switch supports:
            // 0 = straight
            // 1 = crossed

            for (p = 0; p < N/2; p = p + 1) begin: SWITCH

                wire sel;
                assign sel = (PIPE_MIDDLE && s>=CUT)?middle_cfg[s*(N/2)+p]:cfg[s*(N/2)+p];

                assign switched[s][2*p] =
                    sel ? stage_data[2*p+1]
                        : stage_data[2*p];

                assign switched[s][2*p+1] =
                    sel ? stage_data[2*p]
                        : stage_data[2*p+1];

            end

            // Perfect shuffle between stages.
            // Last stage goes directly to output.

            if (s < STAGES-1) begin: SHUFFLE

                for (i = 0; i < N; i = i + 1) begin: WIRE_MAP

                    localparam integer DEST =
                        ((2*i) % N) + (i / (N/2));

                    assign level[s+1][DEST] =
                        switched[s][i];

                end

            end
            else begin: FINAL

                assign level[s+1] = switched[s];

            end

        end
    endgenerate

    assign data_out = level[STAGES];

endmodule


// ===================================================
// BRAM CONFIGURATION MEMORY
// One memory address = one sub-step configuration
// ===================================================

module ferreira_cfg_bram #(
    parameter integer W = 20,
    parameter integer DEPTH = 512,
    parameter integer AW = $clog2(DEPTH)
)(
    input wire clk,

    input wire write_en,
    input wire [AW-1:0] write_addr,
    input wire [W-1:0] write_data,

    input wire [AW-1:0] read_addr,
    output reg [W-1:0] read_data
);

    (* ram_style = "block" *)
    reg [W-1:0] memory [0:DEPTH-1];

    always @(posedge clk) begin

        if (write_en)
            memory[write_addr] <= write_data;

        // Synchronous memory read
        read_data <= memory[read_addr];

    end

endmodule


// ===================================================
// MIN WITH RUNTIME CONFIGURATION MEMORY
// ===================================================

module ferreira_routed_min #(
    parameter integer N = 8,
    parameter integer L = $clog2(N),
    parameter integer STAGES = L+2,
    parameter integer CFG_W = (N/2)*STAGES,

    parameter integer DEPTH = 512,
    parameter integer AW = $clog2(DEPTH)
)(
    input wire clk,

    // Configuration loading
    input wire cfg_write_en,
    input wire [AW-1:0] cfg_write_addr,
    input wire [CFG_W-1:0] cfg_write_data,

    // Sub-step memory address
    input wire [AW-1:0] cfg_read_addr,

    // Physical routing lines
    input wire [N-1:0] data_in,
    output wire [N-1:0] data_out,

    // Debugging
    output wire [CFG_W-1:0] active_cfg
);

    ferreira_cfg_bram #(
        .W(CFG_W),
        .DEPTH(DEPTH)
    ) config_memory (
        .clk(clk),

        .write_en(cfg_write_en),
        .write_addr(cfg_write_addr),
        .write_data(cfg_write_data),

        .read_addr(cfg_read_addr),
        .read_data(active_cfg)
    );

    ferreira_min #(
        .N(N),
        .L(L),
        .STAGES(STAGES),
        .CFG_W(CFG_W)
    ) routing_network (
        .clk(clk),
        .data_in(data_in),
        .cfg(active_cfg),
        .data_out(data_out)
    );

endmodule
