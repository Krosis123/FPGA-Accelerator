`timescale 1ns/1ps

// End-to-end test, exercising USB-UART loader, configuration BRAM,
// runtime substep count and repeated graph swaps without resynthesis.
module ferreira_runtime_tb;
    reg CLK100MHZ=0;
    always #5 CLK100MHZ = ~CLK100MHZ;

    reg CPU_RESETN=0;
    reg BTNC=0;
    reg [3:0] SW=0;
    reg UART_TXD_IN=1;
    wire UART_RXD_OUT;
    wire [15:0] LED;

    // Fast simulation UART: 100 clocks/bit, same RTL as 115200 baud.
    ferreira_board_top #(
        .BAUD(1000000), .DEBOUNCE_CYCLES(3)
    ) dut (
        .CLK100MHZ(CLK100MHZ), .CPU_RESETN(CPU_RESETN),
        .BTNC(BTNC), .SW(SW),
        .UART_TXD_IN(UART_TXD_IN), .UART_RXD_OUT(UART_RXD_OUT),
        .LED(LED)
    );

    reg [7:0] swap_packet [0:43];
    reg [7:0] identity_packet [0:43];
    reg [7:0] multistep_packet [0:75];
    reg [7:0] corrupted_packet [0:43];
    reg [7:0] majority_packet [0:43];
    reg [7:0] responses [0:7];
    reg [7:0] sampled_response;
    integer response_count = 0;
    integer rx_bit;
    initial forever begin
        @(negedge UART_RXD_OUT);
        repeat(150) @(posedge CLK100MHZ);
        for (rx_bit=0; rx_bit<8; rx_bit=rx_bit+1) begin
            sampled_response[rx_bit] = UART_RXD_OUT;
            repeat(100) @(posedge CLK100MHZ);
        end
        if (UART_RXD_OUT !== 1'b1)
            $fatal(1,"UART TX stop bit invalid");
        responses[response_count] = sampled_response;
        response_count = response_count + 1;
    end

    task uart_bit;
        input bit_value;
        integer t;
        begin
            @(negedge CLK100MHZ);
            UART_TXD_IN = bit_value;
            for (t=0; t<100; t=t+1)
                @(negedge CLK100MHZ);
        end
    endtask

    task uart_byte;
        input [7:0] value;
        integer j;
        begin
            uart_bit(0); // start
            for (j=0; j<8; j=j+1)
                uart_bit(value[j]);
            uart_bit(1); // stop
        end
    endtask

    task send_swap;
        integer i;
        begin
            for (i=0;i<44;i=i+1) uart_byte(swap_packet[i]);
            repeat(1200) @(negedge CLK100MHZ);
            if (LED[15] !== 1 || LED[14] !== 0)
                $fatal(1,"Swap configuration not accepted, LEDs=%h",LED);
            if (dut.graph_last_substep !== 5'd1)
                $fatal(1,"Expected 2 substeps");
        end
    endtask

    task send_identity;
        integer i;
        begin
            for (i=0;i<44;i=i+1) uart_byte(identity_packet[i]);
            repeat(1200) @(negedge CLK100MHZ);
            if (LED[15] !== 1 || LED[14] !== 0)
                $fatal(1,"Identity configuration not accepted, LEDs=%h",LED);
            if (dut.graph_last_substep !== 5'd1)
                $fatal(1,"Expected 2 substeps");
        end
    endtask

    task send_multistep;
        integer i;
        begin
            for (i=0;i<76;i=i+1) uart_byte(multistep_packet[i]);
            repeat(1200) @(negedge CLK100MHZ);
            if (LED[15] !== 1 || LED[14] !== 0)
                $fatal(1,"4-substep configuration not accepted, LEDs=%h",LED);
            if (dut.graph_last_substep !== 5'd3)
                $fatal(1,"Expected 4 substeps, got %0d",
                       dut.graph_last_substep);
        end
    endtask

    task run_seed;
        input [3:0] seed;
        input [4:0] expected_period;
        integer t;
        begin
            SW = seed;
            repeat(4) @(negedge CLK100MHZ);
            BTNC = 1;
            repeat(10) @(negedge CLK100MHZ);
            BTNC = 0;
            t = 0;
            while (!LED[5] && t < 2000) begin
                @(negedge CLK100MHZ);
                t = t + 1;
            end
            if (LED[5] !== 1)
                $fatal(1,"Attractor engine timeout, seed=%b",seed);
            if (LED[4:0] !== expected_period)
                $fatal(1,"seed=%b got period %0d expected %0d",
                       seed,LED[4:0],expected_period);
            if (LED[11:8] !== seed)
                $fatal(1,"Wrong displayed seed");
            $display("PASS seed=%b period=%0d",seed,expected_period);
            repeat(12) @(negedge CLK100MHZ);
        end
    endtask

    integer i;
    initial begin
        $readmemh("swap_packet.hex",swap_packet);
        $readmemh("identity_packet.hex",identity_packet);
        $readmemh("multistep_packet.hex",multistep_packet);
        $readmemh("corrupted_packet.hex",corrupted_packet);
        $readmemh("majority_packet.hex",majority_packet);

        repeat(10) @(negedge CLK100MHZ);
        CPU_RESETN = 1;
        repeat(30) @(negedge CLK100MHZ);

        send_swap();
        run_seed(4'b0001,5'd2); // A and B swap => cycle length 2
        run_seed(4'b0011,5'd1); // both equal => fixed point

        send_identity();
        run_seed(4'b0001,5'd1); // same seed, new graph => fixed point

        send_multistep();
        run_seed(4'b0010,5'd1); // A' = A|B|C|D; others hold
        if (dut.graph_degree[8:0] !== 9'd4)
            $fatal(1,"Runtime degree metadata not installed");

        // Runtime rules + degrees: gene A uses strict majority of B,C.
        for (i=0;i<44;i=i+1) uart_byte(majority_packet[i]);
        repeat(1200) @(negedge CLK100MHZ);
        if (LED[15] !== 1 || LED[14] !== 0 ||
            dut.graph_rule !== 4'b0001 ||
            dut.graph_degree[8:0] !== 9'd2)
            $fatal(1,"Runtime majority metadata not accepted");
        run_seed(4'b0010,5'd1);
        if (dut.slow_state !== 4'b0010)
            $fatal(1,"Majority-rule state incorrect");

        // Deliberately corrupt CRC: loader must reject configuration.
        for (i=0;i<44;i=i+1) uart_byte(corrupted_packet[i]);
        repeat(1200) @(negedge CLK100MHZ);
        if (LED[15] !== 0 || LED[14] !== 1)
            $fatal(1,"Bad CRC was not rejected, LEDs=%h",LED);
        $display("PASS: bad CRC rejected");
        if (response_count !== 5 ||
            responses[0] !== 8'h06 ||
            responses[1] !== 8'h06 ||
            responses[2] !== 8'h06 ||
            responses[3] !== 8'h06 ||
            responses[4] !== 8'h15)
            $fatal(1,"Unexpected UART ACK/NAK sequence; got %0d",
                   response_count);
        $display("PASS: runtime graph reconfiguration, no bitstream change");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1,"Global UART test timeout");
    end
endmodule
