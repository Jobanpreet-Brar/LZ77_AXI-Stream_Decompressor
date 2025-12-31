`timescale 1ns/1ps

module tb_lz77_decomp_core;

  localparam int DIST_WIDTH        = 4;
  localparam int LEN_WIDTH         = 4;
  localparam int WINDOW_ADDR_WIDTH = 4;

  logic clk, rst_n;

  logic                   in_valid;
  wire                    in_ready;
  logic [DIST_WIDTH-1:0]  in_distance;
  logic [LEN_WIDTH-1:0]   in_length;
  logic [7:0]             in_literal;

  wire                    out_valid;
  wire [7:0]              out_byte;

  // DUT
  lz77_decomp_core #(
    .DIST_WIDTH(DIST_WIDTH),
    .LEN_WIDTH(LEN_WIDTH),
    .WINDOW_ADDR_WIDTH(WINDOW_ADDR_WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in_valid),
    .in_ready(in_ready),
    .in_distance(in_distance),
    .in_length(in_length),
    .in_literal(in_literal),
    .out_valid(out_valid),
    .out_byte(out_byte)
  );

  // Clock 100 MHz
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Simple monitor
  always @(posedge clk) begin
    if (out_valid) begin
      $display("%0t ns : out_byte = %c (0x%02h)", $time, out_byte, out_byte);
    end
  end

  // Drive one token for one cycle (inline, no task)
  // We wait until in_ready=1, then assert in_valid for exactly 1 cycle.
  initial begin
    // init
    rst_n       = 1'b0;
    in_valid    = 1'b0;
    in_distance = '0;
    in_length   = '0;
    in_literal  = 8'h00;

    // reset
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Token 1: (0,0,'1')
    while (!in_ready) @(posedge clk);
    in_distance <= 4'd0; in_length <= 4'd0; in_literal <= "1"; in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;

    // Token 2: (0,0,'0')
    while (!in_ready) @(posedge clk);
    in_distance <= 4'd0; in_length <= 4'd0; in_literal <= "0"; in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;

    // Token 3: (2,2,'A')
    while (!in_ready) @(posedge clk);
    in_distance <= 4'd2; in_length <= 4'd2; in_literal <= "A"; in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;

    // Token 4: (0,0,'B')
    while (!in_ready) @(posedge clk);
    in_distance <= 4'd0; in_length <= 4'd0; in_literal <= "B"; in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;

    // Token 5: (2,2,'X')
    while (!in_ready) @(posedge clk);
    in_distance <= 4'd2; in_length <= 4'd2; in_literal <= "X"; in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;

    // let it run
    repeat (60) @(posedge clk);
    $finish;
  end
endmodule
