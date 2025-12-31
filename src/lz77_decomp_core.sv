`timescale 1ns / 1ps

module lz77_decomp_core #(
    // Parameter types: "int" is clearer in SV than plain "parameter"
    parameter int DIST_WIDTH        = 4,  // bits for distance
    parameter int LEN_WIDTH         = 4,  // bits for length
    parameter int WINDOW_ADDR_WIDTH = 4   // log2(size of history buffer)
) (
    input  logic                     clk,
    input  logic                     rst_n,        // active-low synchronous reset

    // Token input interface
    input  logic                     in_valid,
    output logic                     in_ready,
    input  logic [DIST_WIDTH-1:0]    in_distance,
    input  logic [LEN_WIDTH-1:0]     in_length,
    input  logic [7:0]               in_literal,

    // Decompressed byte output interface
    output logic                     out_valid,
    output logic [7:0]               out_byte
);

    //Using enum is more readable and safer than raw bits)
    typedef enum logic [1:0]{
        S_IDLE = 2'b00,
        S_COPY = 2'b01,
        S_OUT_LIT = 2'b10
    } state_t;

    localparam int WINDOW_SIZE = (1 << WINDOW_ADDR_WIDTH);
    
    state_t state;
    
    // Circular buffer pointer: points to "next write" position
    logic [WINDOW_ADDR_WIDTH-1:0] write_ptr;
    logic [WINDOW_ADDR_WIDTH-1:0] copy_ptr;

    // History buffer: sliding window of previously output bytes
    logic [7:0] history [0:WINDOW_SIZE-1];

    // Latched token fields
    logic [DIST_WIDTH-1:0]      distance_r;
    logic [LEN_WIDTH-1:0]       length_r;
    logic [7:0]                 literal_r;

    // Remaining bytes to copy in current match
    logic [LEN_WIDTH-1:0]       remaining_len;
    
    // Ready for a new token only in IDLE
    assign in_ready = (state == S_IDLE);
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Reset: clear state and registers

            state        <= S_IDLE;
            out_valid    <= 1'b0;
            out_byte     <= 8'd0;

            distance_r   <= '0;
            length_r     <= '0;
            literal_r    <= 8'd0;
            copy_ptr     <= '0;
            write_ptr    <= '0;
            remaining_len<= '0;

            // Optional: clear history buffer
            for (int i = 0; i < WINDOW_SIZE; i++) begin
                history[i] <= 8'd0;
            end

        end else begin
            // Default: no output unless a state explicitly sets it
            out_valid <= 1'b0;

            unique case (state)
               // ------------------------------------------------
                // S_IDLE: wait for a new token, then decide:
                //   - length == 0  -> literal-only
                //   - length > 0   -> copy+literal
                // ------------------------------------------------
                S_IDLE: begin
                    if (in_ready && in_valid) begin
                        // Latch token fields for later use
                        distance_r <= in_distance;
                        length_r   <= in_length;
                        literal_r  <= in_literal;

                        if (in_length == '0) begin
                            // Case 1: length = 0 -> literal only
                            out_byte  <= in_literal;
                            out_valid <= 1'b1;

                            // Store literal into history at current write_ptr
                            history[write_ptr] <= in_literal;
                            write_ptr          <= write_ptr + 1'b1;

                            // Remain in S_IDLE, ready for next token
                        end else begin
                            // Case 2: length > 0 (copy + literal)
                            remaining_len <= in_length;
                            // Start copying from "distance" bytes behind the end
                            copy_ptr      <= write_ptr - in_distance;
                            state         <= S_COPY;
                        end
                    end
                end

                // ------------------------------------------------
                // S_COPY: each cycle:
                //   - output one byte from history[copy_ptr]
                //   - write same byte at history[write_ptr]
                //   - advance both pointers (circular)
                //   - decrement remaining_len
                // when remaining_len hits 1 (old value), go to S_OUT_LIT
                // ------------------------------------------------
                S_COPY: begin
                    // 1) Output one copied byte
                    out_byte  <= history[copy_ptr];
                    out_valid <= 1'b1;

                    // 2) Write that byte into history at the current end
                    history[write_ptr] <= history[copy_ptr];

                    // 3) Advance both pointers (wraps automatically via width)
                    write_ptr <= write_ptr + 1'b1;
                    copy_ptr  <= copy_ptr  + 1'b1;

                    // 4) Decrease remaining length
                    remaining_len <= remaining_len - 1'b1;

                    // 5) If that was the last byte to copy, move to literal output
                    if (remaining_len == {{(LEN_WIDTH-1){1'b0}}, 1'b1}) begin
                        // remaining_len == 1 (old value) -> this cycle is last copy
                        state <= S_OUT_LIT;
                    end
                    // else: stay in S_COPY
                end

                // ------------------------------------------------
                // S_OUT_LIT: output the saved literal, store it in
                // history, then go back to IDLE for next token
                // ------------------------------------------------
                S_OUT_LIT: begin
                    // Output the saved literal from this token
                    out_byte  <= literal_r;
                    out_valid <= 1'b1;

                    // Store literal into history window
                    history[write_ptr] <= literal_r;
                    write_ptr          <= write_ptr + 1'b1;

                    // Done with this token, go back to idle
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
