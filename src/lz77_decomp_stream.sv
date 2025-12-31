`timescale 1ns/1ps

module lz77_decomp_stream #(
    parameter int DIST_WIDTH        = 4,
    parameter int LEN_WIDTH         = 4,
    parameter int WINDOW_ADDR_WIDTH = 4,
    parameter int TOKEN_W           = DIST_WIDTH + LEN_WIDTH + 8
)(
    input  logic                clk,
    input  logic                rst_n,

    // AXI-Stream input: token stream (TDATA packs {dist,len,lit})
    input  logic [TOKEN_W-1:0]   s_axis_tdata,
    input  logic                s_axis_tvalid,
    output logic                s_axis_tready,
    input  logic                s_axis_tlast,

    // AXI-Stream output: byte stream
    output logic [7:0]          m_axis_tdata,
    output logic                m_axis_tvalid,
    input  logic                m_axis_tready,
    output logic                m_axis_tlast
);

    // ----------------------------
    // Unpack token: LSB = literal
    // TDATA = {dist, len, lit}
    // ----------------------------
    logic [DIST_WIDTH-1:0] tok_dist;
    logic [LEN_WIDTH-1:0]  tok_len;
    logic [7:0]            tok_lit;

    always_comb begin
        tok_lit  = s_axis_tdata[7:0];
        tok_len  = s_axis_tdata[8 +: LEN_WIDTH];
        tok_dist = s_axis_tdata[8 + LEN_WIDTH +: DIST_WIDTH];
    end

    // ----------------------------
    // Core connections
    // ----------------------------
    logic core_in_ready;
    logic core_in_valid;

    logic core_out_valid;
    logic [7:0] core_out_byte;

    // ----------------------------
    // FIFO (depth = 2^LEN_WIDTH bytes)
    // ----------------------------
    localparam int FIFO_DEPTH = (1 << LEN_WIDTH);
    localparam int PTR_W      = LEN_WIDTH; // because FIFO_DEPTH is power-of-2

    logic [7:0] fifo_data [0:FIFO_DEPTH-1];
    logic       fifo_last [0:FIFO_DEPTH-1];

    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [PTR_W:0]   count;

    logic fifo_full, fifo_empty;
    assign fifo_full  = (count == FIFO_DEPTH);
    assign fifo_empty = (count == 0);

    // Make outputs clean (no X) when empty
    assign m_axis_tvalid = !fifo_empty;
    assign m_axis_tdata  = fifo_empty ? 8'h00 : fifo_data[rd_ptr];
    assign m_axis_tlast  = fifo_empty ? 1'b0  : fifo_last[rd_ptr];

    logic pop;
    assign pop = m_axis_tvalid && m_axis_tready;

    // ----------------------------
    // Token sizing + acceptance (no overflow)
    // Token outputs: (len==0)?1:(len+1) bytes
    // ----------------------------
    logic [LEN_WIDTH:0] token_bytes;     // up to 2^LEN_WIDTH
    int unsigned        fifo_free_i;
    int unsigned        token_bytes_i;
    logic               can_accept;

    always_comb begin
        fifo_free_i = FIFO_DEPTH - count;

        // Guard against X when s_axis_tvalid=0
        if (!s_axis_tvalid) begin
            token_bytes_i = 1;
        end else begin
            token_bytes_i = (tok_len == '0) ? 1 : (int'(tok_len) + 1);
        end

        can_accept = (fifo_free_i >= token_bytes_i);
    end

    assign s_axis_tready = core_in_ready && can_accept;

    // Handshake event for input token
    logic token_fire;
    assign token_fire   = s_axis_tvalid && s_axis_tready;

    // Core sees a 1-cycle valid pulse when token transfers
    assign core_in_valid = token_fire;

    lz77_decomp_core #(
        .DIST_WIDTH(DIST_WIDTH),
        .LEN_WIDTH(LEN_WIDTH),
        .WINDOW_ADDR_WIDTH(WINDOW_ADDR_WIDTH)
    ) u_core (
        .clk        (clk),
        .rst_n       (rst_n),

        .in_valid    (core_in_valid),
        .in_ready    (core_in_ready),
        .in_distance (tok_dist),
        .in_length   (tok_len),
        .in_literal  (tok_lit),

        .out_valid   (core_out_valid),
        .out_byte    (core_out_byte)
    );

    // ----------------------------
    // TLAST tracking:
    // s_axis_tlast marks last TOKEN.
    // We need TLAST on last OUTPUT BYTE of that token.
    // ----------------------------
    logic                cur_token_last;
    logic [LEN_WIDTH:0]  rem_bytes;  // bytes remaining to be produced for current token

    // Compute token_bytes (packed width) for loading rem_bytes
    always_comb begin
        if (!s_axis_tvalid) begin
            token_bytes = 1;
        end else begin
            token_bytes = (tok_len == '0) ? {{LEN_WIDTH{1'b0}},1'b1}
                                          : ({{1'b0}, tok_len} + 1);
        end
    end

    // FIFO push: allow push if not full OR if popping same cycle (freeing slot)
    logic push;
    assign push = core_out_valid && (!fifo_full || pop);

    // FIFO write last-flag when we are writing the final byte of a LAST token
    logic push_last;
    assign push_last = cur_token_last && (rem_bytes == 1);

    // ----------------------------
    // Sequential state updates
    // ----------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr         <= '0;
            rd_ptr         <= '0;
            count          <= '0;
            cur_token_last <= 1'b0;
            rem_bytes      <= '0;
        end else begin
            // Latch token_last and expected byte count at token acceptance
            if (token_fire) begin
                cur_token_last <= s_axis_tlast;
                rem_bytes      <= token_bytes;
            end

            // push/pop cases
            unique case ({push, pop})
                2'b10: begin // push only
                    fifo_data[wr_ptr] <= core_out_byte;
                    fifo_last[wr_ptr] <= push_last;
                    wr_ptr            <= wr_ptr + 1'b1;
                    count             <= count + 1'b1;
                    if (rem_bytes != 0) rem_bytes <= rem_bytes - 1'b1;
                end
                2'b01: begin // pop only
                    rd_ptr <= rd_ptr + 1'b1;
                    count  <= count - 1'b1;
                end
                2'b11: begin // push and pop
                    fifo_data[wr_ptr] <= core_out_byte;
                    fifo_last[wr_ptr] <= push_last;
                    wr_ptr            <= wr_ptr + 1'b1;
                    rd_ptr            <= rd_ptr + 1'b1;
                    // count unchanged
                    if (rem_bytes != 0) rem_bytes <= rem_bytes - 1'b1;
                end
                default: ; // no-op
            endcase
        end
    end
endmodule
