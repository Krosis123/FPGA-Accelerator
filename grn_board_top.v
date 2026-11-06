`timescale 1ns/1ps

// Fixed physical capacity, runtime graph and active count. No network constants.
module grn_board_top #(
    parameter integer N=64, KMAX=2, ROUTE_N=1<<$clog2(2*N), DEPTH=32,
    parameter integer CLOCK_HZ=100000000, BAUD=115200, PIPE_ROUTING=1,
    parameter [3*N-1:0] CAP_LOG2={N{3'd1}},
    parameter integer MAX_DEGREE=256, CW=$clog2(MAX_DEGREE+1), AW=$clog2(DEPTH),
    parameter integer BANKS=(((ROUTE_N/2)*($clog2(ROUTE_N)+2)+2*ROUTE_N)+63)/64,
    parameter integer BW=(BANKS<2)?1:$clog2(BANKS)
)(
    input wire CLK100MHZ, CPU_RESETN, BTNC,
    input wire [3:0] SW,
    input wire UART_TXD_IN,
    output wire UART_RXD_OUT,
    output wire [15:0] LED
);
    reg [3:0] power_on_count=0;
    always @(posedge CLK100MHZ) if(!(&power_on_count)) power_on_count<=power_on_count+1'b1;
    (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync=2'b11;
    always @(posedge CLK100MHZ or negedge CPU_RESETN)
        if(!CPU_RESETN) reset_sync<=2'b11;
        else reset_sync<={reset_sync[0],1'b0};
    // Registered reset distribution prevents startup-counter decode from
    // feeding every datapath/loader register through control logic in one cycle.
    reg global_reset=1, loader_reset=1, controller_reset=1;
    always @(posedge CLK100MHZ) begin
        global_reset<=!(&power_on_count)||reset_sync[1];
        loader_reset<=global_reset;
        controller_reset<=loader_reset;
    end
    wire ready, busy, error, run_request, response_busy;
    wire [N-1:0] seed, rule, slow_state;
    wire [N*CW-1:0] degree;
    wire [15:0] active;
    wire [AW-1:0] last_step, address;
    wire [BW-1:0] bank;
    wire [63:0] data;
    wire write_en, done;
    wire [N:0] period;
    reg [63:0] cycles;
    localparam WAIT=0, ARM=1, START=2, RUN=3, SHOW=4;
    reg [2:0] stage;
    reg core_reset=1, core_start=0;
    always @(posedge CLK100MHZ) begin
        core_reset<=controller_reset||!ready||busy||stage==WAIT||stage==ARM;
        core_start<=!controller_reset && stage==START;
    end
    grn_uart_runtime #(.N(N),.KMAX(KMAX),.ROUTE_N(ROUTE_N),.DEPTH(DEPTH),
        .MAX_DEGREE(MAX_DEGREE),.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.CAP_LOG2(CAP_LOG2),.PIPE_ROUTING(PIPE_ROUTING)) loader(
        .clk(CLK100MHZ),.reset(loader_reset),.uart_rx(UART_TXD_IN),.uart_tx(UART_RXD_OUT),
        .allow_new((stage==WAIT||stage==SHOW)&&!run_request),.response_busy(response_busy),
        .graph_ready(ready),.graph_busy(busy),.graph_error(error),.run_request(run_request),
        .run_seed(seed),.graph_rule(rule),.graph_degree(degree),.active_genes(active),
        .graph_last_substep(last_step),.cfg_write_en(write_en),.cfg_write_addr(address),
        .cfg_write_bank(bank),.cfg_write_data(data),
        .result_valid(stage==RUN&&done),.result_period(period),.result_state(slow_state),.result_cycles(cycles));
    ferreira_system #(.N(N),.KMAX(KMAX),.ROUTE_N(ROUTE_N),.DEPTH(DEPTH),
        .MAX_DEGREE(MAX_DEGREE),.SUBSTEPS(DEPTH),.RUNTIME_CONFIG(1),.PIPE_ROUTING(PIPE_ROUTING),.CAP_LOG2(CAP_LOG2)) accelerator(
        .clk(CLK100MHZ),.reset(core_reset),.start(core_start),.seed(seed),
        .last_substep_index(last_step),.cfg_write_en(write_en),.cfg_write_addr(address),
        .cfg_write_bank(bank),.cfg_write_data(data),.rule(rule),.degree(degree),
        .done(done),.period(period),.slow_state(slow_state),.fast_state(),.substep(),.phase2());
    always @(posedge CLK100MHZ) begin
        if(controller_reset) begin stage<=WAIT; cycles<=0; end
        else if(!ready||busy) stage<=WAIT;
        else begin
          if(core_start) cycles<=0;
          else if(stage==RUN&&!done) cycles<=cycles+1'b1;
          case(stage)
            WAIT,SHOW: if(run_request) stage<=ARM;
            ARM: stage<=START;
            START: stage<=RUN;
            RUN: if(done) stage<=SHOW;
            default: stage<=WAIT;
          endcase
        end
    end
    wire [4:0] led_period=period;
    assign LED={ready,error,response_busy,busy,active[3:0],
                1'b0,(stage==RUN),(stage==SHOW),led_period};
endmodule
