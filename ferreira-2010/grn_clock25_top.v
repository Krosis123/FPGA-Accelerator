`timescale 1ns/1ps

// Board clock wrapper only. The 64-slot datapath is unchanged from 8ab1481.
// 100 MHz * 8 / 32 = 25 MHz; MMCM VCO = 800 MHz.
// Vendor primitives are synthesized by Yosys. Behavioral integration tests
// drive grn_board_top directly at 25 MHz; they do not model analog MMCM lock.
`ifdef SYNTHESIZE
module grn_clock25_top(
    input wire CLK100MHZ, CPU_RESETN, BTNC,
    input wire [3:0] SW,
    input wire UART_TXD_IN,
    output wire UART_RXD_OUT,
    output wire [15:0] LED
);
    wire feedback_raw, feedback, clock_raw, clock25, locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(10.0),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(8.0),
        .CLKOUT0_DIVIDE_F(32.0), .STARTUP_WAIT("FALSE")
    ) clock_manager (
        .CLKIN1(CLK100MHZ), .CLKFBIN(feedback), .CLKFBOUT(feedback_raw),
        .CLKOUT0(clock_raw), .LOCKED(locked), .RST(1'b0), .PWRDWN(1'b0)
    );
    BUFG feedback_buffer(.I(feedback_raw), .O(feedback));
    BUFG accelerator_buffer(.I(clock_raw), .O(clock25));
    grn_board_top #(.CLOCK_HZ(25000000), .BAUD(115200)) runtime (
        .CLK100MHZ(clock25), .CPU_RESETN(CPU_RESETN && locked), .BTNC(BTNC),
        .SW(SW), .UART_TXD_IN(UART_TXD_IN), .UART_RXD_OUT(UART_RXD_OUT), .LED(LED)
    );
endmodule
`endif
