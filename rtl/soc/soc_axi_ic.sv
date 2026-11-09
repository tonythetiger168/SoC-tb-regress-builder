// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_axi_ic -- 2-master x 3-slave AXI4 interconnect (32-bit data/address)
// ----------------------------------------------------------------------------
//  * Read and write paths are independent. Each path serves one burst at a
//    time (single outstanding transaction per direction across the fabric),
//    picked round-robin between the two masters.
//  * Address decode (see rtl/soc/soc_pkg.sv):
//      S0 SRAM   0x0000_0000 - 0x0000_FFFF
//      S1 APB    0x1000_0000 - 0x1000_FFFF (AXI-to-APB bridge)
//      S2 DDR    0x8000_0000 - 0x8FFF_FFFF (external AXI master port)
//      anything else goes to the internal default slave: DECERR
//  * Slave-side ID = {master index, master ID} (MIDW+1 bits). The SRAM slave
//    (open-ip AXI4_top) only accepts ID 0, so S0 gets ID 0 and the original
//    ID is restored on the way back (legal: one burst in flight per path).
//  * Addresses pass through unchanged; slaves decode the low bits they need.
// ============================================================================
module soc_axi_ic
  import soc_pkg::*;
#(
  parameter int MIDW = 4,              // master ID width
  parameter int SIDW = MIDW + 1        // slave ID width
)(
  input  logic             clk,
  input  logic             rst_n,
  // ---------------- master ports (arrays index the master) ----------------
  input  logic [MIDW-1:0]  m_awid    [2],
  input  logic [31:0]      m_awaddr  [2],
  input  logic [7:0]       m_awlen   [2],
  input  logic [2:0]       m_awsize  [2],
  input  logic [1:0]       m_awburst [2],
  input  logic [2:0]       m_awprot  [2],
  input  logic             m_awvalid [2],
  output logic             m_awready [2],
  input  logic [31:0]      m_wdata   [2],
  input  logic [3:0]       m_wstrb   [2],
  input  logic             m_wlast   [2],
  input  logic             m_wvalid  [2],
  output logic             m_wready  [2],
  output logic [MIDW-1:0]  m_bid     [2],
  output logic [1:0]       m_bresp   [2],
  output logic             m_bvalid  [2],
  input  logic             m_bready  [2],
  input  logic [MIDW-1:0]  m_arid    [2],
  input  logic [31:0]      m_araddr  [2],
  input  logic [7:0]       m_arlen   [2],
  input  logic [2:0]       m_arsize  [2],
  input  logic [1:0]       m_arburst [2],
  input  logic [2:0]       m_arprot  [2],
  input  logic             m_arvalid [2],
  output logic             m_arready [2],
  output logic [MIDW-1:0]  m_rid     [2],
  output logic [31:0]      m_rdata   [2],
  output logic [1:0]       m_rresp   [2],
  output logic             m_rlast   [2],
  output logic             m_rvalid  [2],
  input  logic             m_rready  [2],
  // ---------------- slave ports (arrays index the slave) ------------------
  output logic [SIDW-1:0]  s_awid    [3],
  output logic [31:0]      s_awaddr  [3],
  output logic [7:0]       s_awlen   [3],
  output logic [2:0]       s_awsize  [3],
  output logic [1:0]       s_awburst [3],
  output logic [2:0]       s_awprot  [3],
  output logic             s_awvalid [3],
  input  logic             s_awready [3],
  output logic [31:0]      s_wdata   [3],
  output logic [3:0]       s_wstrb   [3],
  output logic             s_wlast   [3],
  output logic             s_wvalid  [3],
  input  logic             s_wready  [3],
  input  logic [1:0]       s_bresp   [3],
  input  logic             s_bvalid  [3],
  output logic             s_bready  [3],
  output logic [SIDW-1:0]  s_arid    [3],
  output logic [31:0]      s_araddr  [3],
  output logic [7:0]       s_arlen   [3],
  output logic [2:0]       s_arsize  [3],
  output logic [1:0]       s_arburst [3],
  output logic [2:0]       s_arprot  [3],
  output logic             s_arvalid [3],
  input  logic             s_arready [3],
  input  logic [31:0]      s_rdata   [3],
  input  logic [1:0]       s_rresp   [3],
  input  logic             s_rlast   [3],
  input  logic             s_rvalid  [3],
  output logic             s_rready  [3]
);

  localparam int DEF = 3;   // index of the internal default (DECERR) slave

  // ==========================================================================
  // write path
  // ==========================================================================
  typedef enum logic [1:0] {W_IDLE, W_ADDR, W_DATA, W_RESP} wst_t;
  wst_t           wst;
  logic           w_m;          // granted master
  logic [1:0]     w_s;          // selected slave (3 = default slave)
  logic [MIDW-1:0] w_id;
  logic           w_rr;         // round-robin pointer: master preferred next

  // grant: preferred master if requesting, else the other one
  logic           w_req_any, w_pick;
  logic           aw_ready_sel, w_ready_sel, b_valid_sel;
  logic [1:0]     b_resp_sel;
  assign w_req_any = m_awvalid[0] | m_awvalid[1];
  assign w_pick    = m_awvalid[w_rr] ? w_rr : ~w_rr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst  <= W_IDLE;
      w_m  <= 1'b0;
      w_s  <= 2'd0;
      w_id <= '0;
      w_rr <= 1'b0;
    end else begin
      case (wst)
        W_IDLE: if (w_req_any) begin
          w_m  <= w_pick;
          w_s  <= soc_decode(m_awaddr[w_pick]);
          w_id <= m_awid[w_pick];
          w_rr <= ~w_pick;
          wst  <= W_ADDR;
        end
        W_ADDR: if (m_awvalid[w_m] && aw_ready_sel) wst <= W_DATA;
        W_DATA: if (m_wvalid[w_m] && w_ready_sel && m_wlast[w_m]) wst <= W_RESP;
        W_RESP: if (b_valid_sel && m_bready[w_m]) wst <= W_IDLE;
        default: wst <= W_IDLE;
      endcase
    end
  end

  // default slave write side: accept AW/W immediately, answer DECERR
  always_comb begin
    aw_ready_sel = (w_s == DEF) ? 1'b1 : s_awready[w_s];
    w_ready_sel  = (w_s == DEF) ? 1'b1 : s_wready[w_s];
    b_valid_sel  = (w_s == DEF) ? 1'b1 : s_bvalid[w_s];
    b_resp_sel   = (w_s == DEF) ? RESP_DECERR : s_bresp[w_s];
  end

  always_comb begin
    for (int m = 0; m < 2; m++) begin
      m_awready[m] = (wst == W_ADDR) && (w_m == m) && aw_ready_sel;
      m_wready[m]  = (wst == W_DATA) && (w_m == m) && w_ready_sel;
      m_bvalid[m]  = (wst == W_RESP) && (w_m == m) && b_valid_sel;
      m_bresp[m]   = b_resp_sel;
      m_bid[m]     = w_id;
    end
    for (int s = 0; s < 3; s++) begin
      s_awid[s]    = (s == S_SRAM) ? '0 : {w_m, w_id};
      s_awaddr[s]  = m_awaddr[w_m];
      s_awlen[s]   = m_awlen[w_m];
      s_awsize[s]  = m_awsize[w_m];
      s_awburst[s] = m_awburst[w_m];
      s_awprot[s]  = m_awprot[w_m];
      s_awvalid[s] = (wst == W_ADDR) && (w_s == s) && m_awvalid[w_m];
      s_wdata[s]   = m_wdata[w_m];
      s_wstrb[s]   = m_wstrb[w_m];
      s_wlast[s]   = m_wlast[w_m];
      s_wvalid[s]  = (wst == W_DATA) && (w_s == s) && m_wvalid[w_m];
      s_bready[s]  = (wst == W_RESP) && (w_s == s) && m_bready[w_m];
    end
  end

  // ==========================================================================
  // read path
  // ==========================================================================
  typedef enum logic [1:0] {R_IDLE, R_ADDR, R_DATA} rst_t;
  rst_t           rst;
  logic           r_m;
  logic [1:0]     r_s;
  logic [MIDW-1:0] r_id;
  logic [7:0]     r_len, r_beat;   // default slave beat counter
  logic           r_rr;

  logic           r_req_any, r_pick;
  assign r_req_any = m_arvalid[0] | m_arvalid[1];
  assign r_pick    = m_arvalid[r_rr] ? r_rr : ~r_rr;

  logic ar_ready_sel, r_valid_sel, r_last_sel;
  logic [1:0]  r_resp_sel;
  logic [31:0] r_data_sel;
  always_comb begin
    ar_ready_sel = (r_s == DEF) ? 1'b1 : s_arready[r_s];
    r_valid_sel  = (r_s == DEF) ? 1'b1 : s_rvalid[r_s];
    r_last_sel   = (r_s == DEF) ? (r_beat == r_len) : s_rlast[r_s];
    r_resp_sel   = (r_s == DEF) ? RESP_DECERR : s_rresp[r_s];
    r_data_sel   = (r_s == DEF) ? 32'h0 : s_rdata[r_s];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst    <= R_IDLE;
      r_m    <= 1'b0;
      r_s    <= 2'd0;
      r_id   <= '0;
      r_len  <= 8'd0;
      r_beat <= 8'd0;
      r_rr   <= 1'b0;
    end else begin
      case (rst)
        R_IDLE: if (r_req_any) begin
          r_m    <= r_pick;
          r_s    <= soc_decode(m_araddr[r_pick]);
          r_id   <= m_arid[r_pick];
          r_len  <= m_arlen[r_pick];
          r_beat <= 8'd0;
          r_rr   <= ~r_pick;
          rst    <= R_ADDR;
        end
        R_ADDR: if (m_arvalid[r_m] && ar_ready_sel) rst <= R_DATA;
        R_DATA: if (r_valid_sel && m_rready[r_m]) begin
          r_beat <= r_beat + 8'd1;
          if (r_last_sel) rst <= R_IDLE;
        end
        default: rst <= R_IDLE;
      endcase
    end
  end

  always_comb begin
    for (int m = 0; m < 2; m++) begin
      m_arready[m] = (rst == R_ADDR) && (r_m == m) && ar_ready_sel;
      m_rvalid[m]  = (rst == R_DATA) && (r_m == m) && r_valid_sel;
      m_rdata[m]   = r_data_sel;
      m_rresp[m]   = r_resp_sel;
      m_rlast[m]   = r_last_sel;
      m_rid[m]     = r_id;
    end
    for (int s = 0; s < 3; s++) begin
      s_arid[s]    = (s == S_SRAM) ? '0 : {r_m, r_id};
      s_araddr[s]  = m_araddr[r_m];
      s_arlen[s]   = m_arlen[r_m];
      s_arsize[s]  = m_arsize[r_m];
      s_arburst[s] = m_arburst[r_m];
      s_arprot[s]  = m_arprot[r_m];
      s_arvalid[s] = (rst == R_ADDR) && (r_s == s) && m_arvalid[r_m];
      s_rready[s]  = (rst == R_DATA) && (r_s == s) && m_rready[r_m];
    end
  end

endmodule
