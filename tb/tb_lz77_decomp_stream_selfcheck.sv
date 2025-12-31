`timescale 1ns/1ps

module tb_lz77_decomp_stream_selfcheck;

  localparam int DIST_WIDTH        = 4;
  localparam int LEN_WIDTH         = 4;
  localparam int WINDOW_ADDR_WIDTH = 4;
  localparam int TOKEN_W           = DIST_WIDTH + LEN_WIDTH + 8;

  localparam int MAX_TOKENS = 1024;
  localparam int MAX_EXP    = 4096;

  logic clk, rst_n;

  logic [TOKEN_W-1:0] s_axis_tdata;
  logic               s_axis_tvalid;
  logic               s_axis_tready;
  logic               s_axis_tlast;

  logic [7:0]         m_axis_tdata;
  logic               m_axis_tvalid;
  logic               m_axis_tready;
  logic               m_axis_tlast;

  // DUT
  lz77_decomp_stream #(
    .DIST_WIDTH(DIST_WIDTH),
    .LEN_WIDTH(LEN_WIDTH),
    .WINDOW_ADDR_WIDTH(WINDOW_ADDR_WIDTH),
    .TOKEN_W(TOKEN_W)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),

    .s_axis_tdata (s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast (s_axis_tlast),

    .m_axis_tdata (m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast (m_axis_tlast)
  );

  // Clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Always ready (keep it minimal)
  assign m_axis_tready = 1'b1;

  // Vector memories
  logic [TOKEN_W-1:0] tokens   [0:MAX_TOKENS-1];
  logic [7:0]         expected [0:MAX_EXP-1];
  logic [31:0]        meta     [0:1]; // [0]=NUM_TOKENS, [1]=EXP_LEN

  int num_tokens;
  int exp_len;

  task automatic send_token_word(input logic [TOKEN_W-1:0] tdata, input logic last_token);
    begin
      s_axis_tdata  <= tdata;
      s_axis_tlast  <= last_token;
      s_axis_tvalid <= 1'b1;

      // Hold until handshake
      do @(posedge clk); while (!s_axis_tready);

      // Drop after handshake
      s_axis_tvalid <= 1'b0;
      s_axis_tlast  <= 1'b0;
      s_axis_tdata  <= '0;

      // bubble cycle for readability
      @(posedge clk);
    end
  endtask

  int out_idx;
  bit done_seen;

  // Self-checker (ONLY block that drives out_idx/done_seen)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_idx   <= 0;
      done_seen <= 0;
    end else begin
      if (m_axis_tvalid && m_axis_tready) begin
        if (out_idx >= exp_len) begin
          $fatal(1, "FAIL: Extra output byte %0d = 0x%02h", out_idx, m_axis_tdata);
        end

        if (m_axis_tdata !== expected[out_idx]) begin
          $fatal(1, "FAIL: Mismatch at %0d. Got 0x%02h exp 0x%02h",
                 out_idx, m_axis_tdata, expected[out_idx]);
        end

        // TLAST must only occur on final expected byte
        if (m_axis_tlast !== (out_idx == exp_len-1)) begin
          $fatal(1, "FAIL: TLAST wrong at out_idx=%0d got=%0b expected=%0b",
                 out_idx, m_axis_tlast, (out_idx == exp_len-1));
        end

        $display("%0t ns : OUT[%0d] = %c (0x%02h)%s",
                 $time, out_idx, m_axis_tdata, m_axis_tdata,
                 (m_axis_tlast ? " TLAST" : ""));

        if (out_idx == exp_len-1) done_seen <= 1;
        out_idx <= out_idx + 1;
      end
    end
  end

  initial begin
    // Init TB-driven signals ONLY (do NOT touch out_idx/done_seen here)
    rst_n         = 1'b0;
    s_axis_tdata  = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;

    // Load vectors (make sure these files exist)
    $readmemh("meta.mem",     meta);
    $readmemh("tokens.mem",   tokens);
    $readmemh("expected.mem", expected);

    num_tokens = meta[0];
    exp_len    = meta[1];

    if (num_tokens <= 0 || num_tokens > MAX_TOKENS) $fatal(1, "Bad num_tokens=%0d", num_tokens);
    if (exp_len    <= 0 || exp_len    > MAX_EXP)    $fatal(1, "Bad exp_len=%0d", exp_len);

    $display("Loaded vectors: num_tokens=%0d exp_len=%0d", num_tokens, exp_len);

    // Reset
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Drive tokens
    for (int i = 0; i < num_tokens; i++) begin
      send_token_word(tokens[i], (i == num_tokens-1));
    end

    // Wait for completion (timeout)
    repeat (5000) begin
      @(posedge clk);
      if (done_seen && out_idx == exp_len) begin
        $display("PASS: matched Python golden reference (bytes=%0d).", exp_len);
        $finish;
      end
    end

    $fatal(1, "FAIL: Timeout. out_idx=%0d exp_len=%0d done_seen=%0b", out_idx, exp_len, done_seen);
  end
endmodule
