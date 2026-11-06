`timescale 1ns/1ps

// Runtime graph transport for the 4-gene, 16-line, 80-bit configuration.
// Packet (all multibyte data little endian):
//   46 47 | version=01 | substeps (1..32) | rules (4 bits)
//   | degrees (5 bytes, packed 4x9 bits)
//   | substeps * (bank0:8 bytes + bank1:8 bytes)
//   | CRC16-CCITT (low byte, high byte)
// CRC covers version through last bank byte, initial CRC=0xffff.
// Version 02 inserts active-count and seed bytes after version, and autostarts.
// A CRC-framed FR result follows ACK; see PROTOCOL.md for the wire contract.
// ACK=06, NAK=15. A new frame is accepted only when allow_new=1.
// Engine MUST be held in reset while !graph_ready or graph_busy.
module ferreira_uart_loader #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200,
    parameter integer TIMEOUT_CYCLES = CLOCK_HZ/2,
    parameter integer TW = (TIMEOUT_CYCLES < 2) ? 1 : $clog2(TIMEOUT_CYCLES)
)(
    input wire clk,
    input wire reset,
    input wire uart_rx,
    output wire uart_tx,
    input wire allow_new,
    output reg run_request,
    output reg [3:0] run_seed,
    output reg [2:0] active_genes,
    input wire result_valid,
    input wire [4:0] result_period,
    input wire [3:0] result_state,
    input wire [63:0] result_cycles,
    output wire response_busy,

    output reg graph_ready,
    output reg graph_busy,
    output reg graph_error,
    output reg [3:0] graph_rule,
    output reg [35:0] graph_degree,
    output reg [4:0] graph_last_substep,

    output reg cfg_write_en,
    output reg [4:0] cfg_write_addr,
    output reg cfg_write_bank,
    output reg [63:0] cfg_write_data
);
    wire [7:0] rx_data;
    wire rx_valid;
    ferreira_uart_rx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) rx (
        .clk(clk), .reset(reset), .uart_rx(uart_rx),
        .data(rx_data), .valid(rx_valid)
    );

    reg tx_send;
    reg [7:0] tx_data;
    wire tx_busy;
    ferreira_uart_tx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) tx (
        .clk(clk), .reset(reset), .send(tx_send), .data(tx_data),
        .uart_tx(uart_tx), .busy(tx_busy)
    );

    function [15:0] crc_byte;
        input [15:0] prior;
        input [7:0] incoming;
        reg [15:0] c;
        integer k;
        begin
            c = prior ^ {incoming,8'b0};
            for (k=0; k<8; k=k+1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    localparam [3:0]
        WAIT_F=0, WAIT_G=1, VERSION=2, STEPS=3,
        RULES=4, DEGREES=5, WORDS=6,
        CRC_LO=7, CRC_HI=8, ACTIVE=9, SEED=10;

    reg [3:0] state;
    reg [15:0] crc;
    reg [7:0] crc_low;
    reg [7:0] pending_steps;
    reg [7:0] pending_rule;
    reg [39:0] pending_degrees;
    reg [2:0] degree_byte_index;
    reg [2:0] word_byte_index;
    reg [6:0] word_index;
    reg [63:0] word_shift;
    reg [TW-1:0] timeout_counter;
    reg run_mode;
    reg [7:0] pending_active, pending_seed;
    reg result_pending;
    reg [127:0] result_shift;
    reg [4:0] result_index;
    reg [15:0] result_crc;
    reg frame_invalid;
    reg [15:0] word_valid;
    reg [35:0] counted_degrees;
    wire [63:0] incoming_word = {rx_data, word_shift[63:8]};
    function [8:0] count_bits;
        input [15:0] value;
        integer i;
        begin
            count_bits = 0;
            for (i=0; i<16; i=i+1) count_bits = count_bits + value[i];
        end
    endfunction
    assign response_busy = result_pending || tx_busy || tx_send;

    always @(posedge clk) begin
        if (reset) begin
            state <= WAIT_F;
            run_request <= 0;
            run_seed <= 0;
            active_genes <= 4;
            pending_active <= 4;
            pending_seed <= 0;
            run_mode <= 0;
            frame_invalid <= 0;
            word_valid <= 0;
            counted_degrees <= 0;
            result_pending <= 0;
            result_shift <= 0;
            result_index <= 0;
            result_crc <= 16'hffff;
            crc <= 16'hffff;
            crc_low <= 0;
            pending_steps <= 0;
            pending_rule <= 0;
            pending_degrees <= 0;
            degree_byte_index <= 0;
            word_byte_index <= 0;
            word_index <= 0;
            word_shift <= 0;
            timeout_counter <= 0;
            graph_ready <= 0;
            graph_busy <= 0;
            graph_error <= 0;
            graph_rule <= 0;
            graph_degree <= 0;
            graph_last_substep <= 0;
            cfg_write_en <= 0;
            cfg_write_addr <= 0;
            cfg_write_bank <= 0;
            cfg_write_data <= 0;
            tx_send <= 0;

            tx_data <= 8'h00;
        end else begin
            cfg_write_en <= 0;
            tx_send <= 0;
            run_request <= 0;
            // One result buffered while the upload ACK finishes transmission.
            if (result_valid) begin
                result_pending <= 1;
                result_index <= 0;
                result_crc <= 16'hffff;
                result_shift <= {16'd0, result_cycles, 4'd0, result_state,
                                 3'd0, result_period, 5'd0, active_genes,
                                 8'h02, 8'h52, 8'h46};
            end
            if (result_pending && !tx_busy && !tx_send) begin
                tx_send <= 1;
                tx_data <= result_index == 14 ? result_crc[7:0] :
                           result_index == 15 ? result_crc[15:8] : result_shift[7:0];
                if (result_index >= 2 && result_index < 14)
                    result_crc <= crc_byte(result_crc, result_shift[7:0]);
                result_shift <= result_shift >> 8;
                result_index <= result_index + 1'b1;
                if (result_index == 15) result_pending <= 0;
            end

            if (rx_valid)
                timeout_counter <= 0;
            else if (graph_busy)
                timeout_counter <= timeout_counter + 1'b1;

            // Abort a truncated or stalled upload (~500 ms).
            if (graph_busy && timeout_counter == TIMEOUT_CYCLES-1) begin
                graph_busy <= 0;
                graph_ready <= 0;
                graph_error <= 1;
                state <= WAIT_F;
                tx_send <= 1;
                tx_data <= 8'h15;
                timeout_counter <= 0;
            end else if (rx_valid) begin
                case (state)
                    WAIT_F: begin
                        if (allow_new && !response_busy && rx_data == 8'h46)
                            state <= WAIT_G;
                    end
                    WAIT_G: begin
                        if (rx_data == 8'h47 && allow_new) begin
                            state <= VERSION;
                            graph_ready <= 0;
                            graph_busy <= 1;
                            graph_error <= 0;
                            crc <= 16'hffff;
                            frame_invalid <= 0;
                            counted_degrees <= 0;
                            pending_degrees <= 0;
                            word_index <= 0;
                            word_byte_index <= 0;
                            degree_byte_index <= 0;
                        end else if (rx_data != 8'h46)
                            state <= WAIT_F;
                    end
                    VERSION: begin
                        crc <= crc_byte(crc, rx_data);
                        if (rx_data == 8'h01 || rx_data == 8'h02) begin
                            run_mode <= rx_data == 8'h02;
                            pending_active <= 4;
                            pending_seed <= 0;
                            state <= rx_data == 8'h02 ? ACTIVE : STEPS;
                        end else begin
                            state <= WAIT_F;
                            graph_busy <= 0;
                            graph_error <= 1;
                            tx_send <= 1;
                            tx_data <= 8'h15;
                        end
                    end
                    ACTIVE: begin
                        pending_active <= rx_data;
                        crc <= crc_byte(crc, rx_data);
                        state <= SEED;
                    end
                    SEED: begin
                        pending_seed <= rx_data;
                        crc <= crc_byte(crc, rx_data);
                            state <= STEPS;
                    end
                    STEPS: begin
                        crc <= crc_byte(crc, rx_data);
                        if (rx_data >= 1 && rx_data <= 32) begin
                            pending_steps <= rx_data;
                            state <= RULES;
                        end else begin
                            state <= WAIT_F;
                            graph_busy <= 0;
                            graph_error <= 1;
                            tx_send <= 1;
                            tx_data <= 8'h15;
                        end
                    end
                    RULES: begin
                        crc <= crc_byte(crc, rx_data);
                        pending_rule <= rx_data;
                        degree_byte_index <= 0;
                        pending_degrees <= 0;
                        state <= DEGREES;
                    end
                    DEGREES: begin
                        crc <= crc_byte(crc, rx_data);
                        pending_degrees <= {rx_data, pending_degrees[39:8]};
                        if (degree_byte_index == 4) begin
                            state <= WORDS;
                            word_index <= 0;
                            word_byte_index <= 0;
                            word_shift <= 0;
                        end else
                            degree_byte_index <= degree_byte_index + 1'b1;
                    end
                    WORDS: begin
                        crc <= crc_byte(crc, rx_data);
                        word_shift <= {rx_data, word_shift[63:8]};
                        if (word_byte_index == 7) begin
                            if (!word_index[0]) begin
                                word_valid <= incoming_word[63:48];
                                counted_degrees[8:0] <= counted_degrees[8:0] + count_bits(incoming_word[63:48] & 16'h0001);
                                counted_degrees[17:9] <= counted_degrees[17:9] + count_bits(incoming_word[63:48] & 16'h0006);
                                counted_degrees[26:18] <= counted_degrees[26:18] + count_bits(incoming_word[63:48] & 16'h0078);
                                counted_degrees[35:27] <= counted_degrees[35:27] + count_bits(incoming_word[63:48] & 16'h7f80);
                                if (incoming_word[63] ||
                                    (run_mode && ((incoming_word[63:48] >>
                                      ((1 << pending_active)-1)) != 0)))
                                    frame_invalid <= 1;
                            end else if (incoming_word[63:16] != 0 ||
                                         (incoming_word[15:0] & ~word_valid) != 0)
                                frame_invalid <= 1;
                            cfg_write_en <= 1;
                            cfg_write_data <= {rx_data,word_shift[63:8]};
                            cfg_write_addr <= word_index[5:1];
                            cfg_write_bank <= word_index[0];
                            word_byte_index <= 0;
                            word_shift <= 0;
                            if ((word_index + 7'd1) ==
                                ({1'b0,pending_steps} << 1))
                                state <= CRC_LO;
                            word_index <= word_index + 1'b1;
                        end else
                            word_byte_index <= word_byte_index + 1'b1;
                    end
                    CRC_LO: begin
                        crc_low <= rx_data;
                        state <= CRC_HI;
                    end
                    CRC_HI: begin
                        state <= WAIT_F;
                        graph_busy <= 0;
                        // Reject unsupported high bits of rule and degree.
                        if (!frame_invalid && counted_degrees == pending_degrees[35:0] &&
                            crc_low == crc[7:0] && rx_data == crc[15:8] &&
                            pending_rule[7:4] == 0 &&
                            pending_degrees[39:36] == 0 &&
                            pending_degrees[8:0] <= 256 &&
                            pending_degrees[17:9] <= 256 &&
                            pending_degrees[26:18] <= 256 &&
                            pending_degrees[35:27] <= 256 &&
                            pending_active >= 1 && pending_active <= 4 &&
                            (pending_seed >> pending_active) == 0 &&
                            (!run_mode || ((pending_rule >> pending_active) == 0 &&
                             (pending_degrees >> (9*pending_active)) == 0))) begin
                            graph_rule <= pending_rule[3:0];
                            graph_degree <= pending_degrees[35:0];
                            graph_last_substep <= pending_steps - 1'b1;
                            graph_ready <= 1;
                            run_seed <= pending_seed[3:0];
                            active_genes <= pending_active[2:0];
                            run_request <= run_mode;
                            graph_error <= 0;
                            tx_send <= 1;
                            tx_data <= 8'h06;
                        end else begin
                            graph_ready <= 0;
                            graph_error <= 1;
                            tx_send <= 1;
                            tx_data <= 8'h15;
                        end
                    end
                    default: state <= WAIT_F;
                endcase
            end
        end
    end
endmodule
