`timescale 1ns/1ps

module ferreira_routed_min_tb;

localparam N = 8;
    localparam L = $clog2(N);
    localparam STAGES = L + 2;
    localparam CFG_W = (N/2)*STAGES;

reg clk = 0;
    always #5 clk = ~clk;

    reg [N-1:0] data_in = 0;

reg cfg_write_en = 0;
    reg [2:0] cfg_write_addr = 0;
    reg [CFG_W-1:0] cfg_write_data = 0;

    reg [2:0] cfg_read_addr = 0;

wire [N-1:0] data_out;
    wire [CFG_W-1:0] active_cfg;

ferreira_routed_min #(
        .N(N),
        .DEPTH(8)
    ) dut (
        .clk(clk),

.cfg_write_en(cfg_write_en),
        .cfg_write_addr(cfg_write_addr),
        .cfg_write_data(cfg_write_data),

        .cfg_read_addr(cfg_read_addr),

.data_in(data_in),
        .data_out(data_out),
        .active_cfg(active_cfg)
    );

    initial begin

// ===================================
        // Write configuration 0
        // ===================================

        @(negedge clk);

cfg_write_en = 1;
        cfg_write_addr = 0;
        cfg_write_data = 0;

// ===================================
        // Write configuration 1
        // ===================================

        @(negedge clk);

cfg_write_addr = 1;
        cfg_write_data = 20'b1;

        @(negedge clk);

cfg_write_en = 0;
        data_in = 8'b00000010;
        cfg_read_addr = 0;

// ===================================
        // TEST 1: Read configuration 0
        // ===================================

@(posedge clk);
        #1;

if (active_cfg !== 0)
            $fatal(1, "Configuration 0 read failed");

if (data_out !== 8'b00000100)
            $fatal(1,
                "Routing cfg0 failed output=%b", data_out);

        $display("PASS: Configuration 0");

// ===================================
        // TEST 2: Synchronous BRAM read
        // ===================================

@(negedge clk);
        cfg_read_addr = 1;

        #1;

// Output must still hold previous config
        // until the next rising clock edge.

if (active_cfg !== 0)
            $fatal(1, "BRAM read changed too early");

@(posedge clk);
        #1;

if (active_cfg !== 20'b1)
            $fatal(1, "Configuration 1 read failed");

if (data_out !== 8'b00000001)
            $fatal(1,
                "Routing cfg1 failed output=%b", data_out);

$display("PASS: Synchronous BRAM read");
        $display("PASS: Configuration 1");

// ===================================
        // TEST 3: Runtime reconfiguration
        // ===================================

@(negedge clk);
        cfg_read_addr = 0;

@(posedge clk);
        #1;

if (data_out !== 8'b00000100)
            $fatal(1, "Runtime reconfiguration failed");

        $display("PASS: Runtime reconfiguration");

// ===================================
        // TEST 4: Overwrite configuration
        // ===================================

        @(negedge clk);

cfg_write_en = 1;
        cfg_write_addr = 1;
        cfg_write_data = 0;

        @(negedge clk);

cfg_write_en = 0;
        cfg_read_addr = 1;

@(posedge clk);
        #1;

if (active_cfg !== 0)
            $fatal(1, "Configuration overwrite failed");

if (data_out !== 8'b00000100)
            $fatal(1, "Overwritten routing failed");

        $display("PASS: Configuration overwrite");

$display("--------------------------------");
        $display("ALL ROUTED MIN TESTS PASSED");
        $display("--------------------------------");

        $finish;

    end

initial begin
        #10000;
        $fatal(1, "Simulation timeout");
    end

endmodule