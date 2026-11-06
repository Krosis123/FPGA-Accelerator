`timescale 1ns/1ps

// Runtime configurable 4-gene prototype. The hardware capacity/PE layout
// remains fixed; graph routing, edge types, gene rules, degrees and active
// substep count are loaded over USB-UART without a new FPGA bitstream.
module ferreira_board_top #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200,
    parameter integer DEBOUNCE_CYCLES = 100000
)(
    input wire CLK100MHZ,
    input wire CPU_RESETN,
    input wire BTNC,
    input wire [3:0] SW,
    input wire UART_TXD_IN,
    output wire UART_RXD_OUT,
    output wire [15:0] LED
);
    // FPGA configuration initializes this counter. Hold every controller in
    // reset briefly after programming, even if CPU_RESETN never goes low.
    reg [3:0] power_on_count = 0;
    wire power_on_reset = !(&power_on_count);
    always @(posedge CLK100MHZ) begin
        if (power_on_reset) power_on_count <= power_on_count + 1'b1;
    end

    // Assert the button reset asynchronously; release it on clock edges.
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b11;
    always @(posedge CLK100MHZ or negedge CPU_RESETN) begin
        if (!CPU_RESETN) reset_sync <= 2'b11;
        else reset_sync <= {reset_sync[0], 1'b0};
    end
    wire sys_reset = power_on_reset || reset_sync[1];

    // Runtime graph configuration (same fixed capacities as before).
    wire graph_ready, graph_busy, graph_error;
    wire [3:0] graph_rule;
    wire [35:0] graph_degree;
    wire [4:0] graph_last_substep;
    wire cfg_write_en;
    wire [4:0] cfg_write_addr;
    wire cfg_write_bank;
    wire [63:0] cfg_write_data;
    wire run_request, response_busy;
    wire [3:0] run_seed;
    wire [2:0] active_genes;
    reg remote_run;
    reg [63:0] execution_cycles;
    wire core_done;
    wire [4:0] core_period;
    wire [3:0] slow_state, fast_state;

    // Button synchronization + debounce.
    localparam integer DBW = (DEBOUNCE_CYCLES < 2) ? 1 :
        $clog2(DEBOUNCE_CYCLES);
    reg [1:0] btn_sync;
    reg btn_stable, btn_previous;
    reg [DBW-1:0] db_count;
    always @(posedge CLK100MHZ) begin
        if (sys_reset) begin
            btn_sync <= 0;
            btn_stable <= 0;
            btn_previous <= 0;
            db_count <= 0;
        end else begin
            btn_sync <= {btn_sync[0],BTNC};
            btn_previous <= btn_stable;
            if (btn_sync[1] == btn_stable)
                db_count <= 0;
            else if (db_count == DEBOUNCE_CYCLES-1) begin
                btn_stable <= btn_sync[1];
                db_count <= 0;
            end else db_count <= db_count+1'b1;
        end
    end
    wire button_pressed = btn_stable && !btn_previous;

    localparam [2:0] WAIT=0, ARM=1, START=2, RUN=3, SHOW=4;
    reg [2:0] controller_state;
    reg [3:0] selected_seed;
    reg [4:0] result_period;

    // Reject frame starts during an attractor computation.
    wire allow_new = controller_state == WAIT ||
                     controller_state == SHOW;
    ferreira_uart_loader #(
        .CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)
    ) loader (
        .clk(CLK100MHZ), .reset(sys_reset),
        .uart_rx(UART_TXD_IN), .uart_tx(UART_RXD_OUT),
        .allow_new(allow_new && !run_request),
        .run_request(run_request), .run_seed(run_seed),
        .active_genes(active_genes), .response_busy(response_busy),
        .result_valid(remote_run && controller_state == RUN && core_done),
        .result_period(core_period), .result_state(slow_state),
        .result_cycles(execution_cycles),
        .graph_ready(graph_ready),
        .graph_busy(graph_busy),
        .graph_error(graph_error),
        .graph_rule(graph_rule),
        .graph_degree(graph_degree),
        .graph_last_substep(graph_last_substep),
        .cfg_write_en(cfg_write_en),
        .cfg_write_addr(cfg_write_addr),
        .cfg_write_bank(cfg_write_bank),
        .cfg_write_data(cfg_write_data)
    );

    wire core_reset = sys_reset || !graph_ready || graph_busy ||
        controller_state == WAIT || controller_state == ARM;
    wire core_start = (controller_state == START);
    wire [4:0] core_substep;
    wire core_phase2;

    ferreira_system #(
        .N(4), .KMAX(8), .ROUTE_N(16),
        .SUBSTEPS(32), .RUNTIME_CONFIG(1),
        .PIPE_ROUTING(1),
        .DEPTH(32), .MAX_DEGREE(256),
        .CAP_LOG2(12'h688)
    ) accelerator (
        .clk(CLK100MHZ),
        .reset(core_reset),
        .start(core_start),
        .seed(selected_seed),
        .last_substep_index(graph_last_substep),
        .cfg_write_en(cfg_write_en),
        .cfg_write_addr(cfg_write_addr),
        .cfg_write_bank(cfg_write_bank),
        .cfg_write_data(cfg_write_data),
        .rule(graph_rule),
        .degree(graph_degree),
        .done(core_done),
        .period(core_period),
        .slow_state(slow_state),
        .fast_state(fast_state),
        .substep(core_substep),
        .phase2(core_phase2)
    );

    always @(posedge CLK100MHZ) begin
        if (sys_reset) begin
            controller_state <= WAIT;
            selected_seed <= 0;
            result_period <= 0;
            remote_run <= 0;
            execution_cycles <= 0;
        end else if (!graph_ready || graph_busy) begin
            controller_state <= WAIT;
            result_period <= 0;
        end else begin
            // Count rising edges after the start edge through done assertion.
            if (controller_state == START) execution_cycles <= 0;
            else if (controller_state == RUN && !core_done)
                execution_cycles <= execution_cycles + 1'b1;
            case (controller_state)
                WAIT: if (run_request || (button_pressed && !response_busy)) begin
                    selected_seed <= run_request ? run_seed : SW;
                    remote_run <= run_request;
                    result_period <= 0;
                    controller_state <= ARM;
                end
                ARM: controller_state <= START;
                START: controller_state <= RUN;
                RUN: if (core_done) begin
                    result_period <= core_period;
                    controller_state <= SHOW;
                end
                SHOW: if (run_request || (button_pressed && !response_busy)) begin
                    selected_seed <= run_request ? run_seed : SW;
                    remote_run <= run_request;
                    result_period <= 0;
                    controller_state <= ARM;
                end
                default: controller_state <= WAIT;
            endcase
        end
    end

    assign LED[4:0] = result_period;
    assign LED[5] = (controller_state == SHOW);
    assign LED[6] = (controller_state == RUN);
    assign LED[7] = graph_ready && (controller_state == WAIT);
    assign LED[11:8] = selected_seed;
    assign LED[12] = core_phase2 && (controller_state == RUN);
    assign LED[13] = core_substep[0] && (controller_state == RUN);
    assign LED[14] = graph_error;
    assign LED[15] = graph_ready;
endmodule
