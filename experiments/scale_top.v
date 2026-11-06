// Capacity experiment only. Serial register access keeps runtime configuration
// observable and avoids a graph-specific constant-propagation benchmark.
// Uses the unchanged Ferreira backend; this is not the production UART top.
module scale_top #(
    parameter integer N = 100,
    parameter integer ROUTE_N = 1 << $clog2(2*N),
    parameter integer BANKS = (((ROUTE_N/2)*($clog2(ROUTE_N)+2)+2*ROUTE_N)+63)/64,
    parameter integer BW = (BANKS < 2) ? 1 : $clog2(BANKS),
    parameter integer INPUT_W = N + N + 9*N + 5 + 64 + 5 + BW
)(
    input wire clk, reset, start, shift_en, shift_bit, write_en, read_en,
    output wire result_bit, done
);
    reg [INPUT_W-1:0] configuration;
    wire [N-1:0] seed = configuration[0 +: N];
    wire [N-1:0] rule = configuration[N +: N];
    wire [9*N-1:0] degree = configuration[2*N +: 9*N];
    wire [4:0] last_step = configuration[11*N +: 5];
    wire [63:0] data = configuration[11*N+5 +: 64];
    wire [4:0] address = configuration[11*N+69 +: 5];
    wire [BW-1:0] bank = configuration[11*N+74 +: BW];
    wire [N:0] period;
    wire [N-1:0] state;
    reg [2*N:0] result;
    reg prior_done;
    always @(posedge clk) begin
        if (reset) begin configuration <= 0; result <= 0; prior_done <= 0; end
        else begin
            prior_done <= done;
            if (shift_en) configuration <= {configuration[INPUT_W-2:0],shift_bit};
            if (done && !prior_done) result <= {period,state};
            else if (read_en) result <= {result[2*N-1:0],1'b0};
        end
    end
    assign result_bit = result[2*N];
    ferreira_system #(
        .N(N), .KMAX(2), .ROUTE_N(ROUTE_N), .SUBSTEPS(32),
        .RUNTIME_CONFIG(1), .PIPE_ROUTING(1), .DEPTH(32),
        .MAX_DEGREE(256), .CAP_LOG2({N{3'd1}})
    ) core (
        .clk(clk), .reset(reset), .start(start), .seed(seed),
        .last_substep_index(last_step), .cfg_write_en(write_en),
        .cfg_write_addr(address), .cfg_write_bank(bank), .cfg_write_data(data),
        .rule(rule), .degree(degree), .done(done), .period(period),
        .slow_state(state), .fast_state(), .substep(), .phase2()
    );
endmodule
