
`timescale 1ns/1ps

module ferreira_system_tb;

    localparam integer DEPTH = 32;
    localparam integer BANKS = 2;
    localparam integer AW = $clog2(DEPTH);
    localparam integer BW = $clog2(BANKS);

    reg clk = 0;
    always #5 clk = ~clk;

    reg reset = 1;
    reg start = 0;
    reg [3:0] seed = 0;

    reg cfg_write_en = 0;
    reg [AW-1:0] cfg_write_addr = 0;
    reg [BW-1:0] cfg_write_bank = 0;
    reg [63:0] cfg_write_data = 0;

    wire done;
    wire [4:0] period;
    wire [3:0] slow_state;
    wire [3:0] fast_state;
    wire substep;
    wire phase2;

    reg [63:0] config_words [0:DEPTH*BANKS-1];

    ferreira_system #(
        .N(4),
        .KMAX(8),
        .ROUTE_N(16),
        .SUBSTEPS(2),
        .PIPE_ROUTING(1),
        .DEPTH(DEPTH),
        .MAX_DEGREE(256),
        .CAP_LOG2(12'h688)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .seed(seed),

        .cfg_write_en(cfg_write_en),
        .cfg_write_addr(cfg_write_addr),
        .cfg_write_bank(cfg_write_bank),
        .cfg_write_data(cfg_write_data),

        .rule(4'h0),
        .degree(36'h8040201),

        .done(done),
        .period(period),

        .slow_state(slow_state),
        .fast_state(fast_state),
        .substep(substep),
        .phase2(phase2)
    );

    task run_seed;
        input [3:0] state;
        integer cycles;
        integer expected_period;

        begin
            @(negedge clk);
            reset = 1;
            start = 0;
            seed = state;

            repeat (3) @(negedge clk);

            reset = 0;
            start = 1;

            @(negedge clk);
            start = 0;

            cycles = 0;

            while (done !== 1'b1 && cycles < 500) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            if (done !== 1'b1)
                $fatal(1,
                    "TIMEOUT seed=%b slow=%b fast=%b",
                    state, slow_state, fast_state);

            expected_period =
                (state[0] ^ state[1]) ? 2 : 1;

            if (period !== expected_period)
                $fatal(1,
                    "WRONG PERIOD seed=%b got=%0d expected=%0d",
                    state, period, expected_period);

            $display(
                "PASS seed=%b period=%0d cycles=%0d",
                state, period, cycles
            );
        end
    endtask

    integer addr, bank, s;

    initial begin

        $readmemh("ferreira_config.mem", config_words);

        // Load configuration through actual RAM write ports
        for (addr = 0; addr < DEPTH; addr = addr + 1) begin
            for (bank = 0; bank < BANKS; bank = bank + 1) begin

                @(negedge clk);

                cfg_write_en = 1;
                cfg_write_addr = addr;
                cfg_write_bank = bank;
                cfg_write_data =
                    config_words[addr*BANKS + bank];

            end
        end

        @(negedge clk);
        cfg_write_en = 0;

        repeat (3) @(negedge clk);

        // Exhaustively test all 16 initial states
        for (s = 0; s < 16; s = s + 1)
            run_seed(s[3:0]);

        $display(
            "PASS: all 16 seeds, integrated system"
        );

        $finish;
    end

endmodule
