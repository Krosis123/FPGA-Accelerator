`timescale 1ns/1ps

// Standard 8N1 UART receiver. Input has two FFs of synchronization.
module ferreira_uart_rx #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200,
    parameter integer DIVIDER = (CLOCK_HZ + BAUD/2) / BAUD,
    parameter integer CW = (DIVIDER < 2) ? 1 : $clog2(DIVIDER+1)
)(
    input wire clk,
    input wire reset,
    input wire uart_rx,
    output reg [7:0] data,
    output reg valid
);
    localparam [1:0] IDLE=0, START=1, DATA=2, STOP=3;
    reg [1:0] state;
    reg [1:0] sync;
    reg [CW-1:0] timer;
    reg [2:0] bit_index;
    reg [7:0] shift;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            sync <= 2'b11;
            timer <= 0;
            bit_index <= 0;
            shift <= 0;
            data <= 0;
            valid <= 0;
        end else begin
            sync <= {sync[0], uart_rx};
            valid <= 0;
            case (state)
                IDLE: if (!sync[1]) begin
                    timer <= (DIVIDER/2)-1;
                    state <= START;
                end
                START: if (timer == 0) begin
                    if (!sync[1]) begin
                        timer <= DIVIDER-1;
                        bit_index <= 0;
                        state <= DATA;
                    end else state <= IDLE;
                end else timer <= timer - 1'b1;
                DATA: if (timer == 0) begin
                    shift[bit_index] <= sync[1];
                    timer <= DIVIDER-1;
                    if (bit_index == 7)
                        state <= STOP;
                    else
                        bit_index <= bit_index + 1'b1;
                end else timer <= timer - 1'b1;
                STOP: if (timer == 0) begin
                    if (sync[1]) begin
                        data <= shift;
                        valid <= 1;
                    end
                    state <= IDLE;
                end else timer <= timer - 1'b1;
                default: state <= IDLE;
            endcase
        end
    end
endmodule

module ferreira_uart_tx #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200,
    parameter integer DIVIDER = (CLOCK_HZ + BAUD/2) / BAUD,
    parameter integer CW = (DIVIDER < 2) ? 1 : $clog2(DIVIDER+1)
)(
    input wire clk,
    input wire reset,
    input wire send,
    input wire [7:0] data,
    output reg uart_tx,
    output reg busy
);
    reg [CW-1:0] timer;
    reg [3:0] bit_index;
    reg [9:0] bits;
    always @(posedge clk) begin
        if (reset) begin
            timer <= 0;
            bit_index <= 0;
            bits <= 10'h3ff;
            uart_tx <= 1;
            busy <= 0;
        end else if (!busy) begin
            if (send) begin
                bits <= {1'b1, data, 1'b0};
                uart_tx <= 0;
                busy <= 1;
                bit_index <= 0;
                timer <= DIVIDER-1;
            end
        end else if (timer == 0) begin
            if (bit_index == 9) begin
                busy <= 0;
                uart_tx <= 1;
            end else begin
                bit_index <= bit_index+1'b1;
                uart_tx <= bits[bit_index+1'b1];
                timer <= DIVIDER-1;
            end
        end else timer <= timer-1'b1;
    end
endmodule
