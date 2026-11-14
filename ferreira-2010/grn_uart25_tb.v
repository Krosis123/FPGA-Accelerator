`timescale 1ns/1ps
// Real 25 MHz clock and external nominal 115200-baud 8N1 waveforms.
module grn_uart25_tb;
    reg clk=0; always #20 clk=~clk;
    reg reset=1, rx=1, send=0;
    reg [7:0] outgoing=0;
    wire [7:0] incoming;
    wire valid, tx, busy;
    integer value, bit_index, received_count=0;
    reg [7:0] expected, sampled;
    localparam real BIT_NS=1000000000.0/115200;
    ferreira_uart_rx #(.CLOCK_HZ(25000000),.BAUD(115200)) receiver(
        .clk(clk),.reset(reset),.uart_rx(rx),.data(incoming),.valid(valid));
    ferreira_uart_tx #(.CLOCK_HZ(25000000),.BAUD(115200)) transmitter(
        .clk(clk),.reset(reset),.send(send),.data(outgoing),.uart_tx(tx),.busy(busy));
    always @(posedge clk) if(valid) begin
        if(incoming !== expected) $fatal(1,"25 MHz RX mismatch");
        received_count=received_count+1;
    end
    initial begin
        repeat(5) @(negedge clk); reset=0;
        for(value=0;value<256;value=value+1) begin
            expected=value;
            rx=0; #(BIT_NS);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                rx=expected[bit_index]; #(BIT_NS);
            end
            rx=1; #(BIT_NS*2);
            @(negedge clk); outgoing=value; send=1;
            @(negedge clk); send=0;
            #(BIT_NS*1.5-20);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                sampled[bit_index]=tx; #(BIT_NS);
            end
            if(sampled !== expected || tx !== 1) $fatal(1,"25 MHz TX mismatch");
            wait(!busy);
        end
        if(received_count!=256) $fatal(1,"Missing RX bytes");
        $display("PASS: 25 MHz, nominal 115200 baud, all 256 RX/TX bytes");
        $finish;
    end
    initial begin #100000000; $fatal(1,"UART timeout"); end
endmodule
