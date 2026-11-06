`timescale 1ns/1ps

// Generic v3 transport. Configuration writes are gated from execution until
// frame CRC, lengths, profile, degrees and masks have all been validated.
// Protocol: FG, version=3, opcode, request_id:u16, length:u32, payload, CRC16.
module grn_uart_runtime #(
    parameter integer N=64, KMAX=2, ROUTE_N=128, DEPTH=32,
    parameter integer MAX_DEGREE=256, CW=$clog2(MAX_DEGREE+1),
    parameter integer CLOCK_HZ=100000000, BAUD=115200, PIPE_ROUTING=1,
    parameter [3*N-1:0] CAP_LOG2={N{3'd1}},
    parameter integer AW=$clog2(DEPTH),
    parameter integer SWITCH_W=(ROUTE_N/2)*($clog2(ROUTE_N)+2),
    parameter integer MEM_W=SWITCH_W+2*ROUTE_N,
    parameter integer BANKS=(MEM_W+63)/64,
    parameter integer BW=(BANKS<2)?1:$clog2(BANKS),
    parameter integer TIMEOUT_CYCLES=CLOCK_HZ/2,
    parameter integer TW=$clog2(TIMEOUT_CYCLES+1)
)(
    input wire clk, reset, uart_rx, allow_new,
    output wire uart_tx, response_busy,
    output reg graph_ready, graph_busy, graph_error, run_request,
    output reg [N-1:0] run_seed, graph_rule,
    output reg [N*CW-1:0] graph_degree,
    output reg [15:0] active_genes,
    output reg [AW-1:0] graph_last_substep,
    output reg cfg_write_en,
    output reg [AW-1:0] cfg_write_addr,
    output reg [BW-1:0] cfg_write_bank,
    output reg [63:0] cfg_write_data,
    input wire result_valid,
    input wire [N:0] result_period,
    input wire [N-1:0] result_state,
    input wire [63:0] result_cycles
);
    localparam integer STATE_BYTES=(N+7)/8, DEG_BYTES=(N*CW+7)/8;
    localparam integer PERIOD_BYTES=(N+8)/8;
    localparam integer META_BYTES=6+2*STATE_BYTES+DEG_BYTES;
    localparam integer CAP_BYTES=16+N;
    localparam integer RESULT_BYTES=4+PERIOD_BYTES+STATE_BYTES+8;
    localparam integer MAX_PAYLOAD=META_BYTES+DEPTH*BANKS*8;
    localparam integer PIW=$clog2(MAX_PAYLOAD+1);
    localparam integer TXW=$clog2(CAP_BYTES+RESULT_BYTES+13);
    localparam integer NCW=$clog2(N+1);

    function integer slot_base;
        input integer gene;
        integer i;
        begin
            slot_base=0;
            for(i=0;i<gene;i=i+1) slot_base=slot_base+(1<<CAP_LOG2[3*i+:3]);
        end
    endfunction
    localparam integer USED_LINES=slot_base(N);

    function [15:0] crc_byte;
        input [15:0] prior;
        input [7:0] incoming;
        reg [15:0] c;
        integer k;
        begin
            c=prior^{incoming,8'd0};
            for(k=0;k<8;k=k+1) c=c[15]?((c<<1)^16'h1021):(c<<1);
            crc_byte=c;
        end
    endfunction
    function [7:0] capability_byte;
        input integer index;
        integer gene;
        begin
            case(index)
                0,1,2,3: capability_byte=CLOCK_HZ>>(8*index);
                4,5: capability_byte=N>>(8*(index-4));
                6,7: capability_byte=DEPTH>>(8*(index-6));
                8,9: capability_byte=MAX_DEGREE>>(8*(index-8));
                10,11: capability_byte=ROUTE_N>>(8*(index-10));
                12: capability_byte=KMAX;
                13: capability_byte=CW;
                14: capability_byte=3; // AI and unsigned strict majority
                15: capability_byte=PIPE_ROUTING;
                default: begin
                    capability_byte=0;
                    // Static ROM entries avoid a variable multiply-by-three
                    // and wide barrel shifter in the capability read path.
                    for(gene=0;gene<N;gene=gene+1)
                        if(index==16+gene) capability_byte={5'd0,CAP_LOG2[3*gene+:3]};
                end
            endcase
        end
    endfunction
    function [15:0] capability_crc;
        input unused;
        integer i;
        reg [15:0] c;
        begin
            c=16'hffff;
            for(i=0;i<CAP_BYTES;i=i+1) c=crc_byte(c,capability_byte(i));
            capability_crc=c;
        end
    endfunction
    localparam [15:0] CAP_CRC=capability_crc(1'b0);

    wire [7:0] rx_data;
    wire rx_valid, tx_busy;
    reg tx_send;
    reg [7:0] tx_data;
    ferreira_uart_rx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) receiver(
        .clk(clk),.reset(reset),.uart_rx(uart_rx),.data(rx_data),.valid(rx_valid));
    ferreira_uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) transmitter(
        .clk(clk),.reset(reset),.send(tx_send),.data(tx_data),.uart_tx(uart_tx),.busy(tx_busy));

    localparam WAIT_F=0, WAIT_G=1, HEADER=2, PAYLOAD=3, CRC_LO=4, CRC_HI=5;
    reg [2:0] state;
    reg [2:0] header_index, word_byte;
    reg [63:0] header_bytes, word_shift;
    reg [15:0] request_id, pending_signature, pending_active, pending_steps;
    reg [7:0] command, crc_low, frame_error;
    reg [31:0] payload_length;
    reg [PIW-1:0] payload_index;
    reg [AW:0] route_address;
    reg [BW-1:0] route_bank;
    reg [15:0] rx_crc;
    reg [TW-1:0] timeout_counter;
    reg [8*STATE_BYTES-1:0] pending_seed, pending_rule;
    reg [8*DEG_BYTES-1:0] pending_degree;
    reg [BANKS*64-1:0] row_buffer;
    reg validate_row;
    reg [N*CW-1:0] counted_degree;
    reg accept_new_q, frame_start;
    wire [63:0] incoming_header={rx_data,header_bytes[63:8]};
    wire [63:0] incoming_word={rx_data,word_shift[63:8]};
    wire [ROUTE_N-1:0] row_valid=row_buffer[SWITCH_W+:ROUTE_N];
    wire [ROUTE_N-1:0] row_inhib=row_buffer[SWITCH_W+ROUTE_N+:ROUTE_N];

    // A response request is a one-clock event; one execution result may wait
    // behind its ACK. New frames are blocked until the response is complete.
    reg reply_request;
    reg [7:0] reply_kind, reply_error;
    reg [15:0] reply_id, run_id;
    reg sending, result_pending;
    reg byte_ready;
    reg [7:0] prepared_byte;
    reg [7:0] response_kind, response_error;
    reg [15:0] response_id, response_crc;
    reg [TXW-1:0] response_length;
    reg [TXW:0] tx_index;
    reg [8*PERIOD_BYTES-1:0] saved_period;
    reg [8*STATE_BYTES-1:0] saved_state;
    reg [15:0] saved_active;
    reg [63:0] saved_cycles;
    assign response_busy=sending||result_pending||tx_busy||tx_send||reply_request;
    always @(posedge clk) begin
        if(reset) accept_new_q<=0;
        else accept_new_q<=allow_new && !response_busy && !run_request;
    end

    function [7:0] response_byte;
        input [TXW:0] index;
        reg [TXW:0] p;
        begin
            p=index-10;
            case(index)
                0: response_byte=8'h46;
                1: response_byte=8'h52;
                2: response_byte=3;
                3: response_byte=response_kind;
                4,5: response_byte=response_id>>(8*(index-4));
                6,7,8,9: response_byte=response_length>>(8*(index-6));
                default: begin
                    if(response_kind==8'h81) response_byte=capability_byte(p);
                    else if(response_kind==8'hff) response_byte=response_error;
                    else if(p<2) response_byte=CAP_CRC>>(8*p);
                    else if(p<4) response_byte=saved_active>>(8*(p-2));
                    else if(p<4+PERIOD_BYTES) response_byte=saved_period>>(8*(p-4));
                    else if(p<4+PERIOD_BYTES+STATE_BYTES)
                        response_byte=saved_state>>(8*(p-4-PERIOD_BYTES));
                    else response_byte=saved_cycles>>(8*(p-4-PERIOD_BYTES-STATE_BYTES));
                end
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if(reset) begin
            tx_send<=0; tx_data<=0; sending<=0; result_pending<=0;
            byte_ready<=0; prepared_byte<=0;
            response_kind<=0; response_error<=0; response_id<=0;
            response_length<=0; response_crc<=16'hffff; tx_index<=0;
            saved_period<=0; saved_state<=0; saved_active<=0; saved_cycles<=0;
        end else begin
            tx_send<=0;
            if(result_valid) begin
                result_pending<=1;
                saved_period<=result_period;
                saved_state<=result_state;
                saved_active<=active_genes;
                saved_cycles<=result_cycles;
            end
            if(reply_request) begin
                sending<=1; tx_index<=0; response_crc<=16'hffff; byte_ready<=0;
                response_kind<=reply_kind; response_id<=reply_id; response_error<=reply_error;
                response_length<=reply_kind==8'h81 ? CAP_BYTES : reply_kind==8'hff ? 1 : 0;
            end else if(!sending && result_pending && !tx_busy && !tx_send) begin
                sending<=1; tx_index<=0; response_crc<=16'hffff; byte_ready<=0;
                response_kind<=8'h82; response_id<=run_id;
                response_length<=RESULT_BYTES; result_pending<=0;
            end else if(sending && !tx_busy && !tx_send) begin
                // Register byte selection separately from CRC feedback. This
                // adds one clock per serial byte, not per Boolean transition.
                if(!byte_ready) begin
                    byte_ready<=1;
                    if(tx_index==10+response_length) prepared_byte<=response_crc[7:0];
                    else if(tx_index==11+response_length) prepared_byte<=response_crc[15:8];
                    else prepared_byte<=response_byte(tx_index);
                end else begin
                    byte_ready<=0; tx_send<=1; tx_data<=prepared_byte;
                    if(tx_index==11+response_length) sending<=0;
                    if(tx_index>=2 && tx_index<10+response_length)
                        response_crc<=crc_byte(response_crc,prepared_byte);
                    tx_index<=tx_index+1'b1;
                end
            end
        end
    end

    reg metadata_bad;
    reg metadata_bad_q;
    reg [N-1:0] metadata_gene_bad_q, row_gene_bad_q;
    reg row_check_q, row_global_bad_q;
    reg [PIW-1:0] expected_payload_length, length_acc, length_term;
    reg [AW:0] length_steps_q, length_steps_shift;
    reg payload_length_bad_q;
    // Metadata and lane counts settle long before CRC bytes arrive. Register
    // the reduction so accepting a frame does not span all per-gene comparators.
    always @(posedge clk) begin
        if(reset) begin
            metadata_bad_q<=0; expected_payload_length<=0; payload_length_bad_q<=0;
            length_steps_q<=0; length_steps_shift<=0; length_acc<=0; length_term<=BANKS*8;
        end else begin
            metadata_bad_q<=metadata_bad || (|metadata_gene_bad_q);
            // A few shift/add clocks during metadata reception replace a
            // combinational DSP multiply. Full-width bounds are checked below.
            if(length_steps_q!=pending_steps[AW:0]) begin
                length_steps_q<=pending_steps[AW:0]; length_steps_shift<=pending_steps[AW:0];
                length_acc<=0; length_term<=BANKS*8;
            end else if(length_steps_shift!=0) begin
                if(length_steps_shift[0]) length_acc<=length_acc+length_term;
                length_steps_shift<=length_steps_shift>>1; length_term<=length_term<<1;
            end
            expected_payload_length<=META_BYTES+length_acc;
            payload_length_bad_q<=payload_length!=expected_payload_length;
        end
    end
    always @* begin
        metadata_bad=(pending_seed>>N)!=0 || (pending_rule>>N)!=0 ||
                     (pending_degree>>(N*CW))!=0;
    end

    // Per-gene masks are constant at synthesis; no graph-dependent RTL.
    genvar g;
    wire [N*CW-1:0] chunk_degree;
    wire [N-1:0] inactive_mask_bad, signed_majority_bad;
    generate for(g=0;g<N;g=g+1) begin: CHECK_GENE
        localparam integer K=1<<CAP_LOG2[3*g+:3];
        localparam integer BASE=slot_base(g);
        integer k;
        reg [CW-1:0] count;
        always @* begin
            count=0;
            for(k=0;k<K;k=k+1) count=count+row_valid[BASE+k];
        end
        assign chunk_degree[g*CW+:CW]=count;
        assign inactive_mask_bad[g]=(g>=pending_active[NCW-1:0])&&(|row_valid[BASE+:K]);
        assign signed_majority_bad[g]=pending_rule[g]&&(|row_inhib[BASE+:K]);
        always @(posedge clk) begin
            if(reset) begin metadata_gene_bad_q[g]<=0; row_gene_bad_q[g]<=0; end
            else begin
                metadata_gene_bad_q[g]<=pending_degree[g*CW+:CW]>MAX_DEGREE ||
                    pending_degree[g*CW+:CW]!=counted_degree[g*CW+:CW] ||
                    ((g>=pending_active[NCW-1:0]) &&
                     (pending_seed[g] || pending_rule[g] || pending_degree[g*CW+:CW]!=0));
                if(validate_row) row_gene_bad_q[g]<=inactive_mask_bad[g]||signed_majority_bad[g];
            end
        end
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin row_check_q<=0; row_global_bad_q<=0; end
        else begin
            row_check_q<=validate_row;
            if(validate_row) row_global_bad_q<=(row_buffer>>MEM_W)!=0 ||
                (row_valid>>USED_LINES)!=0 || (row_inhib&~row_valid)!=0;
        end
    end

    task fail_frame;
        input [7:0] code;
        begin
            state<=WAIT_F; graph_busy<=0; graph_ready<=0; graph_error<=1;
            reply_request<=1; reply_kind<=8'hff; reply_error<=code; reply_id<=request_id;
        end
    endtask

    integer d;
    always @(posedge clk) begin
        if(reset) begin
            state<=WAIT_F; header_index<=0; header_bytes<=0;
            word_byte<=0; word_shift<=0; route_bank<=0; route_address<=0;
            request_id<=0; run_id<=0; command<=0; pending_signature<=0;
            pending_active<=0; pending_steps<=0; pending_seed<=0; pending_rule<=0;
            pending_degree<=0; counted_degree<=0; row_buffer<=0; validate_row<=0;
            frame_error<=0; payload_length<=0; payload_index<=0;
            frame_start<=0;
            rx_crc<=16'hffff; crc_low<=0; timeout_counter<=0;
            graph_ready<=0; graph_busy<=0; graph_error<=0; run_request<=0;
            run_seed<=0; graph_rule<=0; graph_degree<=0; active_genes<=0;
            graph_last_substep<=0; cfg_write_en<=0; cfg_write_addr<=0;
            cfg_write_bank<=0; cfg_write_data<=0;
            reply_request<=0; reply_kind<=0; reply_error<=0; reply_id<=0;
        end else begin
            cfg_write_en<=0; run_request<=0; reply_request<=0; validate_row<=0; frame_start<=0;
            if(validate_row) begin
                for(d=0;d<N;d=d+1)
                    counted_degree[d*CW+:CW]<=counted_degree[d*CW+:CW]+chunk_degree[d*CW+:CW];
            end
            if(row_check_q && (row_global_bad_q || (|row_gene_bad_q))) frame_error<=7;
            // Decouple serial/response admission logic from the wide metadata
            // clear. The next header byte cannot arrive within this one clock.
            if(frame_start) begin
                counted_degree<=0; pending_seed<=0; pending_rule<=0; pending_degree<=0;
                pending_signature<=0; pending_active<=0; pending_steps<=0;
            end
            if(rx_valid) timeout_counter<=0;
            else if(graph_busy) timeout_counter<=timeout_counter+1'b1;
            if(graph_busy && timeout_counter==TIMEOUT_CYCLES-1) begin
                timeout_counter<=0; fail_frame(8);
            end else if(rx_valid) begin
                case(state)
                    WAIT_F: if(accept_new_q && rx_data==8'h46) state<=WAIT_G;
                    WAIT_G: if(rx_data==8'h47) begin
                        state<=HEADER; graph_busy<=1; graph_error<=0;
                        header_index<=0; header_bytes<=0; rx_crc<=16'hffff;
                        request_id<=0; frame_error<=0; frame_start<=1;
                        route_address<=0; route_bank<=0; word_byte<=0; word_shift<=0;
                    end else if(rx_data!=8'h46) state<=WAIT_F;
                    HEADER: begin
                        rx_crc<=crc_byte(rx_crc,rx_data);
                        header_bytes<={rx_data,header_bytes[63:8]};
                        if(header_index==7) begin
                            request_id<=incoming_header[31:16]; command<=incoming_header[15:8];
                            payload_length<=incoming_header[63:32]; payload_index<=0;
                            if(incoming_header[7:0]!=3) begin
                                fail_frame(2); reply_id<=incoming_header[31:16];
                            end else if(!((incoming_header[15:8]==1 && incoming_header[63:32]==0) ||
                                        (incoming_header[15:8]==2 && incoming_header[63:32]>=META_BYTES+8*BANKS &&
                                         incoming_header[63:32]<=MAX_PAYLOAD))) begin
                                fail_frame(3); reply_id<=incoming_header[31:16];
                            end else begin
                                if(incoming_header[15:8]==2) graph_ready<=0;
                                state<=incoming_header[63:32]==0?CRC_LO:PAYLOAD;
                            end
                        end else header_index<=header_index+1'b1;
                    end
                    PAYLOAD: begin
                        rx_crc<=crc_byte(rx_crc,rx_data);
                        if(payload_index<2) pending_signature[payload_index*8+:8]<=rx_data;
                        else if(payload_index<4) pending_active[(payload_index-2)*8+:8]<=rx_data;
                        else if(payload_index<6) pending_steps[(payload_index-4)*8+:8]<=rx_data;
                        else if(payload_index<6+STATE_BYTES) pending_seed<={rx_data,pending_seed}>>8;
                        else if(payload_index<6+2*STATE_BYTES) pending_rule<={rx_data,pending_rule}>>8;
                        else if(payload_index<META_BYTES) pending_degree<={rx_data,pending_degree}>>8;
                        else begin
                            word_shift<={rx_data,word_shift[63:8]};
                            if(word_byte==7) begin
                                if(route_address<DEPTH) begin
                                    cfg_write_en<=1; cfg_write_addr<=route_address;
                                    cfg_write_bank<=route_bank; cfg_write_data<=incoming_word;
                                end else frame_error<=3;
                                row_buffer[route_bank*64+:64]<=incoming_word;
                                word_byte<=0; word_shift<=0;
                                if(route_bank==BANKS-1) begin
                                    route_bank<=0; route_address<=route_address+1;
                                    validate_row<=1;
                                end else route_bank<=route_bank+1'b1;
                            end else word_byte<=word_byte+1'b1;
                        end
                        payload_index<=payload_index+1;
                        if(payload_index+1==payload_length) state<=CRC_LO;
                    end
                    CRC_LO: begin crc_low<=rx_data; state<=CRC_HI; end
                    CRC_HI: begin
                        if({rx_data,crc_low}!=rx_crc) fail_frame(1);
                        else if(command==1) begin
                            graph_busy<=0; state<=WAIT_F; reply_request<=1;
                            reply_kind<=8'h81; reply_id<=request_id;
                        end else if(pending_signature!=CAP_CRC) fail_frame(4);
                        else if(pending_active<1 || pending_active>N || pending_steps<1 || pending_steps>DEPTH)
                            fail_frame(5);
                        else if(payload_length_bad_q || route_bank!=0 || word_byte!=0)
                            fail_frame(3);
                        else if(frame_error!=0) fail_frame(frame_error);
                        else if(metadata_bad_q) fail_frame(6);
                        else begin
                            state<=WAIT_F; graph_busy<=0; graph_ready<=1; graph_error<=0;
                            run_seed<=pending_seed[N-1:0]; graph_rule<=pending_rule[N-1:0];
                            graph_degree<=pending_degree[N*CW-1:0]; active_genes<=pending_active;
                            graph_last_substep<=pending_steps-1'b1; run_request<=1; run_id<=request_id;
                            reply_request<=1; reply_kind<=8'h80; reply_id<=request_id;
                        end
                    end
                    default: state<=WAIT_F;
                endcase
            end
        end
    end
endmodule
