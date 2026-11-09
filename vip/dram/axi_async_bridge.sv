// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axi_async_bridge: AXI4 clock-domain crossing (s_* on s_clk, m_* on m_clk)
// ----------------------------------------------------------------------------
// One gray-pointer asynchronous FIFO per channel (AW, W, AR towards the
// manager side, B and R back). Two-flop synchronizers; DEPTH a power of two.
// The ports carry what the SoC testbench's axi4_if uses (no QoS / user).
// ============================================================================
module axi_async_fifo #(
  parameter int W     = 8,
  parameter int DEPTH = 8
)(
  input  logic         w_clk,
  input  logic         w_rst_n,
  input  logic         w_valid,
  output logic         w_ready,
  input  logic [W-1:0] w_data,
  input  logic         r_clk,
  input  logic         r_rst_n,
  output logic         r_valid,
  input  logic         r_ready,
  output logic [W-1:0] r_data
);
  localparam int AB = $clog2(DEPTH);
  logic [W-1:0] mem [DEPTH];
  logic [AB:0]  wb, wg, rb, rg;                 // binary / gray pointers
  logic [AB:0]  wg_r1, wg_r2, rg_w1, rg_w2;     // synchronized gray
  function automatic logic [AB:0] b2g(input logic [AB:0] b);
    b2g = b ^ (b >> 1);
  endfunction

  assign w_ready = wg != {~rg_w2[AB:AB-1], rg_w2[AB-2:0]};
  assign r_valid = rg != wg_r2;
  assign r_data  = mem[rb[AB-1:0]];

  always_ff @(posedge w_clk or negedge w_rst_n) begin
    if (!w_rst_n) begin
      wb <= '0; wg <= '0; rg_w1 <= '0; rg_w2 <= '0;
    end else begin
      rg_w1 <= rg; rg_w2 <= rg_w1;
      if (w_valid && w_ready) begin
        mem[wb[AB-1:0]] <= w_data;
        wb <= wb + 1'b1;
        wg <= b2g(wb + 1'b1);
      end
    end
  end
  always_ff @(posedge r_clk or negedge r_rst_n) begin
    if (!r_rst_n) begin
      rb <= '0; rg <= '0; wg_r1 <= '0; wg_r2 <= '0;
    end else begin
      wg_r1 <= wg; wg_r2 <= wg_r1;
      if (r_valid && r_ready) begin
        rb <= rb + 1'b1;
        rg <= b2g(rb + 1'b1);
      end
    end
  end
endmodule

module axi_async_bridge #(
  parameter int IDW   = 8,
  parameter int DEPTH = 8
)(
  input  logic           s_clk,
  input  logic           s_rst_n,
  input  logic [IDW-1:0] s_awid,
  input  logic [31:0]    s_awaddr,
  input  logic [7:0]     s_awlen,
  input  logic [2:0]     s_awsize,
  input  logic [1:0]     s_awburst,
  input  logic           s_awvalid,
  output logic           s_awready,
  input  logic [31:0]    s_wdata,
  input  logic [3:0]     s_wstrb,
  input  logic           s_wlast,
  input  logic           s_wvalid,
  output logic           s_wready,
  output logic [IDW-1:0] s_bid,
  output logic [1:0]     s_bresp,
  output logic           s_bvalid,
  input  logic           s_bready,
  input  logic [IDW-1:0] s_arid,
  input  logic [31:0]    s_araddr,
  input  logic [7:0]     s_arlen,
  input  logic [2:0]     s_arsize,
  input  logic [1:0]     s_arburst,
  input  logic           s_arvalid,
  output logic           s_arready,
  output logic [IDW-1:0] s_rid,
  output logic [31:0]    s_rdata,
  output logic [1:0]     s_rresp,
  output logic           s_rlast,
  output logic           s_rvalid,
  input  logic           s_rready,
  input  logic           m_clk,
  input  logic           m_rst_n,
  output logic [IDW-1:0] m_awid,
  output logic [31:0]    m_awaddr,
  output logic [7:0]     m_awlen,
  output logic [2:0]     m_awsize,
  output logic [1:0]     m_awburst,
  output logic           m_awvalid,
  input  logic           m_awready,
  output logic [31:0]    m_wdata,
  output logic [3:0]     m_wstrb,
  output logic           m_wlast,
  output logic           m_wvalid,
  input  logic           m_wready,
  input  logic [IDW-1:0] m_bid,
  input  logic [1:0]     m_bresp,
  input  logic           m_bvalid,
  output logic           m_bready,
  output logic [IDW-1:0] m_arid,
  output logic [31:0]    m_araddr,
  output logic [7:0]     m_arlen,
  output logic [2:0]     m_arsize,
  output logic [1:0]     m_arburst,
  output logic           m_arvalid,
  input  logic           m_arready,
  input  logic [IDW-1:0] m_rid,
  input  logic [31:0]    m_rdata,
  input  logic [1:0]     m_rresp,
  input  logic           m_rlast,
  input  logic           m_rvalid,
  output logic           m_rready
);
  localparam int AW_W = IDW + 32 + 8 + 3 + 2;
  localparam int W_W  = 32 + 4 + 1;
  localparam int B_W  = IDW + 2;
  localparam int R_W  = IDW + 32 + 2 + 1;

  axi_async_fifo #(.W(AW_W), .DEPTH(DEPTH)) u_aw (
    .w_clk(s_clk), .w_rst_n(s_rst_n), .w_valid(s_awvalid), .w_ready(s_awready),
    .w_data({s_awid, s_awaddr, s_awlen, s_awsize, s_awburst}),
    .r_clk(m_clk), .r_rst_n(m_rst_n), .r_valid(m_awvalid), .r_ready(m_awready),
    .r_data({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst}));
  axi_async_fifo #(.W(W_W), .DEPTH(DEPTH)) u_w (
    .w_clk(s_clk), .w_rst_n(s_rst_n), .w_valid(s_wvalid), .w_ready(s_wready),
    .w_data({s_wdata, s_wstrb, s_wlast}),
    .r_clk(m_clk), .r_rst_n(m_rst_n), .r_valid(m_wvalid), .r_ready(m_wready),
    .r_data({m_wdata, m_wstrb, m_wlast}));
  axi_async_fifo #(.W(AW_W), .DEPTH(DEPTH)) u_ar (
    .w_clk(s_clk), .w_rst_n(s_rst_n), .w_valid(s_arvalid), .w_ready(s_arready),
    .w_data({s_arid, s_araddr, s_arlen, s_arsize, s_arburst}),
    .r_clk(m_clk), .r_rst_n(m_rst_n), .r_valid(m_arvalid), .r_ready(m_arready),
    .r_data({m_arid, m_araddr, m_arlen, m_arsize, m_arburst}));
  axi_async_fifo #(.W(B_W), .DEPTH(DEPTH)) u_b (
    .w_clk(m_clk), .w_rst_n(m_rst_n), .w_valid(m_bvalid), .w_ready(m_bready),
    .w_data({m_bid, m_bresp}),
    .r_clk(s_clk), .r_rst_n(s_rst_n), .r_valid(s_bvalid), .r_ready(s_bready),
    .r_data({s_bid, s_bresp}));
  axi_async_fifo #(.W(R_W), .DEPTH(DEPTH)) u_r (
    .w_clk(m_clk), .w_rst_n(m_rst_n), .w_valid(m_rvalid), .w_ready(m_rready),
    .w_data({m_rid, m_rdata, m_rresp, m_rlast}),
    .r_clk(s_clk), .r_rst_n(s_rst_n), .r_valid(s_rvalid), .r_ready(s_rready),
    .r_data({s_rid, s_rdata, s_rresp, s_rlast}));
endmodule
