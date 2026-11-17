// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_axi2axil -- AXI4 subordinate port to an AXI4-Lite manager port
// ----------------------------------------------------------------------------
// For register blocks behind a slave NI (e.g. the c1p decoder's 64 KB AXI4-Lite
// register port at S_VDECR). Register accesses are single 32-bit beats; a
// longer burst is split into one AXI4-Lite access per beat (INCR, addresses
// step by 4), the responses merged (worst BRESP) and the R beats passed
// through with RLAST on the last one. One access in flight per direction.
// ============================================================================
module tv8k_axi2axil #(
  parameter int AW = 16                      // AXI4-Lite address width
)(
  input  logic          clk,
  input  logic          rst_n,
  // AXI4 subordinate (from the slave NI)
  input  logic [3:0]    s_awid,
  input  logic [31:0]   s_awaddr,
  input  logic [7:0]    s_awlen,
  input  logic          s_awvalid,
  output logic          s_awready,
  input  logic [31:0]   s_wdata,
  input  logic [3:0]    s_wstrb,
  input  logic          s_wlast,
  input  logic          s_wvalid,
  output logic          s_wready,
  output logic [3:0]    s_bid,
  output logic [1:0]    s_bresp,
  output logic          s_bvalid,
  input  logic          s_bready,
  input  logic [3:0]    s_arid,
  input  logic [31:0]   s_araddr,
  input  logic [7:0]    s_arlen,
  input  logic          s_arvalid,
  output logic          s_arready,
  output logic [3:0]    s_rid,
  output logic [31:0]   s_rdata,
  output logic [1:0]    s_rresp,
  output logic          s_rlast,
  output logic          s_rvalid,
  input  logic          s_rready,
  // AXI4-Lite manager (to the register block)
  output logic          m_awvalid,
  input  logic          m_awready,
  output logic [AW-1:0] m_awaddr,
  output logic          m_wvalid,
  input  logic          m_wready,
  output logic [31:0]   m_wdata,
  output logic [3:0]    m_wstrb,
  input  logic          m_bvalid,
  output logic          m_bready,
  input  logic [1:0]    m_bresp,
  output logic          m_arvalid,
  input  logic          m_arready,
  output logic [AW-1:0] m_araddr,
  input  logic          m_rvalid,
  output logic          m_rready,
  input  logic [31:0]   m_rdata,
  input  logic [1:0]    m_rresp
);
  function automatic logic [1:0] worst(logic [1:0] a, logic [1:0] b);
    return (a > b) ? a : b;
  endfunction

  // ---------------- write ----------------
  typedef enum logic [2:0] {W_IDLE, W_DATA, W_LITE, W_BWAIT, W_RESP} wst_t;
  wst_t        ws;
  logic [31:0] w_addr;
  logic [7:0]  w_left;
  logic [3:0]  w_id;
  logic [1:0]  w_resp;
  logic        aw_sent, w_sent;
  logic [31:0] w_d;
  logic [3:0]  w_s;

  assign s_awready = (ws == W_IDLE);
  assign s_wready  = (ws == W_DATA);
  assign m_awvalid = (ws == W_LITE) && !aw_sent;
  assign m_awaddr  = AW'(w_addr);
  assign m_wvalid  = (ws == W_LITE) && !w_sent;
  assign m_wdata   = w_d;
  assign m_wstrb   = w_s;
  assign m_bready  = (ws == W_BWAIT);
  assign s_bvalid  = (ws == W_RESP);
  assign s_bid     = w_id;
  assign s_bresp   = w_resp;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ws <= W_IDLE; w_addr <= '0; w_left <= '0; w_id <= '0; w_resp <= '0;
      aw_sent <= 1'b0; w_sent <= 1'b0; w_d <= '0; w_s <= '0;
    end else case (ws)
      W_IDLE: if (s_awvalid) begin
        w_addr <= s_awaddr; w_left <= s_awlen; w_id <= s_awid; w_resp <= 2'b00; ws <= W_DATA;
      end
      W_DATA: if (s_wvalid) begin
        w_d <= s_wdata; w_s <= s_wstrb; aw_sent <= 1'b0; w_sent <= 1'b0; ws <= W_LITE;
      end
      W_LITE: begin
        if (m_awvalid && m_awready) aw_sent <= 1'b1;
        if (m_wvalid && m_wready) w_sent <= 1'b1;
        if ((aw_sent || m_awready) && (w_sent || m_wready)) ws <= W_BWAIT;
      end
      W_BWAIT: if (m_bvalid) begin
        w_resp <= worst(w_resp, m_bresp);
        if (w_left == 0) ws <= W_RESP;
        else begin w_left <= w_left - 8'd1; w_addr <= w_addr + 32'd4; ws <= W_DATA; end
      end
      W_RESP: if (s_bready) ws <= W_IDLE;
      default: ws <= W_IDLE;
    endcase

  // ---------------- read ----------------
  typedef enum logic [1:0] {R_IDLE, R_ADDR, R_DATA, R_BEAT} rst_t;
  rst_t        rs;
  logic [31:0] r_addr;
  logic [7:0]  r_left;
  logic [3:0]  r_id;
  logic [31:0] r_d;
  logic [1:0]  r_r;

  assign s_arready = (rs == R_IDLE);
  assign m_arvalid = (rs == R_ADDR);
  assign m_araddr  = AW'(r_addr);
  assign m_rready  = (rs == R_DATA);
  assign s_rvalid  = (rs == R_BEAT);
  assign s_rid     = r_id;
  assign s_rdata   = r_d;
  assign s_rresp   = r_r;
  assign s_rlast   = (r_left == 0);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rs <= R_IDLE; r_addr <= '0; r_left <= '0; r_id <= '0; r_d <= '0; r_r <= '0;
    end else case (rs)
      R_IDLE: if (s_arvalid) begin r_addr <= s_araddr; r_left <= s_arlen; r_id <= s_arid; rs <= R_ADDR; end
      R_ADDR: if (m_arready) rs <= R_DATA;
      R_DATA: if (m_rvalid) begin r_d <= m_rdata; r_r <= m_rresp; rs <= R_BEAT; end
      R_BEAT: if (s_rready) begin
        if (r_left == 0) rs <= R_IDLE;
        else begin r_left <= r_left - 8'd1; r_addr <= r_addr + 32'd4; rs <= R_ADDR; end
      end
      default: rs <= R_IDLE;
    endcase
endmodule
