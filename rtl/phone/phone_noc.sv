// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_noc -- NM x NS AXI4 NoC (behavioural 4x4 mesh timing model)
// ----------------------------------------------------------------------------
//  * Every slave port has its own write path and read path, so different
//    masters reach different slaves in parallel. A port serves one burst per
//    direction at a time; masters that want the same port are picked
//    round-robin, so they really contend for a channel.
//  * A master keeps at most one burst per direction in flight (it is locked
//    to the port that granted it until the response completes).
//  * Mesh timing: the request (AW / AR) is held for noc_lat(m, s) cycles
//    before it reaches the slave, and the response (B / first R beat) is
//    held for noc_lat(m, s) cycles before it reaches the master. noc_lat is
//    the XY-route latency between the two mesh nodes (phone_soc_pkg).
//    This models hop latency and port contention; it is not a flit-level
//    router (no buffers, virtual channels or link contention).
//  * Slave-side ID = {master index, master ID}. The SRAM slave (open-ip
//    AXI4_top) only accepts ID 0, so its port gets ID 0 and the ID is
//    restored on the way back (legal: one burst in flight per direction).
//  * Addresses outside the map go to an internal default slave: DECERR.
// ============================================================================
module phone_noc
  import phone_soc_pkg::*;
#(
  parameter int MIDW = 4,
  parameter int SIDW = MIDW + 4
)(
  input  logic             clk,
  input  logic             rst_n,
  // ---------------- master ports ----------------
  input  logic [MIDW-1:0]  m_awid    [NM],
  input  logic [31:0]      m_awaddr  [NM],
  input  logic [7:0]       m_awlen   [NM],
  input  logic [2:0]       m_awsize  [NM],
  input  logic [1:0]       m_awburst [NM],
  input  logic [2:0]       m_awprot  [NM],
  input  logic             m_awvalid [NM],
  output logic             m_awready [NM],
  input  logic [31:0]      m_wdata   [NM],
  input  logic [3:0]       m_wstrb   [NM],
  input  logic             m_wlast   [NM],
  input  logic             m_wvalid  [NM],
  output logic             m_wready  [NM],
  output logic [MIDW-1:0]  m_bid     [NM],
  output logic [1:0]       m_bresp   [NM],
  output logic             m_bvalid  [NM],
  input  logic             m_bready  [NM],
  input  logic [MIDW-1:0]  m_arid    [NM],
  input  logic [31:0]      m_araddr  [NM],
  input  logic [7:0]       m_arlen   [NM],
  input  logic [2:0]       m_arsize  [NM],
  input  logic [1:0]       m_arburst [NM],
  input  logic [2:0]       m_arprot  [NM],
  input  logic             m_arvalid [NM],
  output logic             m_arready [NM],
  output logic [MIDW-1:0]  m_rid     [NM],
  output logic [31:0]      m_rdata   [NM],
  output logic [1:0]       m_rresp   [NM],
  output logic             m_rlast   [NM],
  output logic             m_rvalid  [NM],
  input  logic             m_rready  [NM],
  // ---------------- slave ports ----------------
  output logic [SIDW-1:0]  s_awid    [NS],
  output logic [31:0]      s_awaddr  [NS],
  output logic [7:0]       s_awlen   [NS],
  output logic [2:0]       s_awsize  [NS],
  output logic [1:0]       s_awburst [NS],
  output logic [2:0]       s_awprot  [NS],
  output logic             s_awvalid [NS],
  input  logic             s_awready [NS],
  output logic [31:0]      s_wdata   [NS],
  output logic [3:0]       s_wstrb   [NS],
  output logic             s_wlast   [NS],
  output logic             s_wvalid  [NS],
  input  logic             s_wready  [NS],
  input  logic [1:0]       s_bresp   [NS],
  input  logic             s_bvalid  [NS],
  output logic             s_bready  [NS],
  output logic [SIDW-1:0]  s_arid    [NS],
  output logic [31:0]      s_araddr  [NS],
  output logic [7:0]       s_arlen   [NS],
  output logic [2:0]       s_arsize  [NS],
  output logic [1:0]       s_arburst [NS],
  output logic [2:0]       s_arprot  [NS],
  output logic             s_arvalid [NS],
  input  logic             s_arready [NS],
  input  logic [31:0]      s_rdata   [NS],
  input  logic [1:0]       s_rresp   [NS],
  input  logic             s_rlast   [NS],
  input  logic             s_rvalid  [NS],
  output logic             s_rready  [NS]
);
  localparam int NP  = NS + 1;               // + default slave
  localparam int MW  = $clog2(NM);

  // route latency table, computed once
  logic [7:0] lat [NM][NP];
  always_comb
    for (int m = 0; m < NM; m++)
      for (int p = 0; p < NP; p++) lat[m][p] = 8'(noc_lat(m, p));

  // target port of every master's pending request
  int unsigned aw_tgt [NM], ar_tgt [NM];
  always_comb
    for (int m = 0; m < NM; m++) begin
      aw_tgt[m] = phone_decode(m_awaddr[m]);
      ar_tgt[m] = phone_decode(m_araddr[m]);
    end

  // ==========================================================================
  // write path, one FSM per port
  // ==========================================================================
  typedef enum logic [2:0] {W_IDLE, W_REQ, W_ADDR, W_DATA, W_BWAIT, W_BDLY, W_RESP} wst_t;
  wst_t            wst  [NP];
  logic [MW-1:0]   wown [NP];
  logic [MIDW-1:0] wid  [NP];
  logic [MW-1:0]   wrr  [NP];
  logic [7:0]      wcnt [NP];
  logic            w_busy [NM];
  logic            wg_v [NP];
  logic [MW-1:0]   wg   [NP];
  // per-port view of the slave (the default slave answers internally)
  logic            p_awready [NP], p_wready [NP], p_bvalid [NP];
  logic [1:0]      p_bresp [NP];

  always_comb begin
    for (int m = 0; m < NM; m++) w_busy[m] = 1'b0;
    for (int p = 0; p < NP; p++)
      if (wst[p] != W_IDLE) w_busy[wown[p]] = 1'b1;
    for (int p = 0; p < NP; p++) begin
      wg_v[p] = 1'b0;
      wg[p]   = '0;
      for (int k = 0; k < NM; k++) begin
        int m;
        m = (int'(wrr[p]) + k) % NM;
        if (!wg_v[p] && m_awvalid[m] && aw_tgt[m] == p && !w_busy[m]) begin
          wg_v[p] = 1'b1;
          wg[p]   = MW'(m);
        end
      end
      if (p < NS) begin
        p_awready[p] = s_awready[p];
        p_wready[p]  = s_wready[p];
        p_bvalid[p]  = s_bvalid[p];
        p_bresp[p]   = s_bresp[p];
      end else begin
        p_awready[p] = 1'b1;
        p_wready[p]  = 1'b1;
        p_bvalid[p]  = 1'b1;
        p_bresp[p]   = RESP_DECERR;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int p = 0; p < NP; p++) begin
        wst[p] <= W_IDLE; wown[p] <= '0; wid[p] <= '0; wrr[p] <= '0; wcnt[p] <= '0;
      end
    end else begin
      for (int p = 0; p < NP; p++) begin
        case (wst[p])
          W_IDLE: if (wg_v[p]) begin
            wown[p] <= wg[p];
            wid[p]  <= m_awid[wg[p]];
            wrr[p]  <= MW'((int'(wg[p]) + 1) % NM);
            wcnt[p] <= lat[wg[p]][p];
            wst[p]  <= W_REQ;
          end
          W_REQ:   if (wcnt[p] <= 8'd1) wst[p] <= W_ADDR; else wcnt[p] <= wcnt[p] - 8'd1;
          W_ADDR:  if (p_awready[p]) wst[p] <= W_DATA;
          W_DATA:  if (m_wvalid[wown[p]] && p_wready[p] && m_wlast[wown[p]]) wst[p] <= W_BWAIT;
          W_BWAIT: if (p_bvalid[p]) begin
            wcnt[p] <= lat[wown[p]][p];
            wst[p]  <= W_BDLY;
          end
          W_BDLY:  if (wcnt[p] <= 8'd1) wst[p] <= W_RESP; else wcnt[p] <= wcnt[p] - 8'd1;
          W_RESP:  if (m_bready[wown[p]]) wst[p] <= W_IDLE;
          default: wst[p] <= W_IDLE;
        endcase
      end
    end
  end

  always_comb begin
    for (int m = 0; m < NM; m++) begin
      m_awready[m] = 1'b0; m_wready[m] = 1'b0; m_bvalid[m] = 1'b0;
      m_bresp[m] = '0; m_bid[m] = '0;
    end
    for (int p = 0; p < NP; p++) begin
      if (wst[p] == W_ADDR) m_awready[wown[p]] = p_awready[p];
      if (wst[p] == W_DATA) m_wready[wown[p]]  = p_wready[p];
      if (wst[p] == W_RESP) begin
        m_bvalid[wown[p]] = p_bvalid[p];
        m_bresp[wown[p]]  = p_bresp[p];
        m_bid[wown[p]]    = wid[p];
      end
    end
    for (int s = 0; s < NS; s++) begin
      s_awid[s]    = (s == S_SRAM) ? '0 : {4'(wown[s]), wid[s]};
      s_awaddr[s]  = m_awaddr[wown[s]];
      s_awlen[s]   = m_awlen[wown[s]];
      s_awsize[s]  = m_awsize[wown[s]];
      s_awburst[s] = m_awburst[wown[s]];
      s_awprot[s]  = m_awprot[wown[s]];
      s_awvalid[s] = (wst[s] == W_ADDR);
      s_wdata[s]   = m_wdata[wown[s]];
      s_wstrb[s]   = m_wstrb[wown[s]];
      s_wlast[s]   = m_wlast[wown[s]];
      s_wvalid[s]  = (wst[s] == W_DATA) && m_wvalid[wown[s]];
      s_bready[s]  = (wst[s] == W_RESP) && m_bready[wown[s]];
    end
  end

  // ==========================================================================
  // read path, one FSM per port
  // ==========================================================================
  typedef enum logic [2:0] {R_IDLE, R_REQ, R_ADDR, R_RWAIT, R_RDLY, R_DATA} rst_t;
  rst_t            rst  [NP];
  logic [MW-1:0]   rown [NP];
  logic [MIDW-1:0] rid  [NP];
  logic [MW-1:0]   rrr  [NP];
  logic [7:0]      rcnt [NP];
  logic [7:0]      rlen [NP], rbeat [NP];
  logic            r_busy [NM];
  logic            rg_v [NP];
  logic [MW-1:0]   rg   [NP];
  logic            p_arready [NP], p_rvalid [NP], p_rlast [NP];
  logic [1:0]      p_rresp [NP];
  logic [31:0]     p_rdata [NP];

  always_comb begin
    for (int m = 0; m < NM; m++) r_busy[m] = 1'b0;
    for (int p = 0; p < NP; p++)
      if (rst[p] != R_IDLE) r_busy[rown[p]] = 1'b1;
    for (int p = 0; p < NP; p++) begin
      rg_v[p] = 1'b0;
      rg[p]   = '0;
      for (int k = 0; k < NM; k++) begin
        int m;
        m = (int'(rrr[p]) + k) % NM;
        if (!rg_v[p] && m_arvalid[m] && ar_tgt[m] == p && !r_busy[m]) begin
          rg_v[p] = 1'b1;
          rg[p]   = MW'(m);
        end
      end
      if (p < NS) begin
        p_arready[p] = s_arready[p];
        p_rvalid[p]  = s_rvalid[p];
        p_rlast[p]   = s_rlast[p];
        p_rresp[p]   = s_rresp[p];
        p_rdata[p]   = s_rdata[p];
      end else begin
        p_arready[p] = 1'b1;
        p_rvalid[p]  = 1'b1;
        p_rlast[p]   = (rbeat[p] == rlen[p]);
        p_rresp[p]   = RESP_DECERR;
        p_rdata[p]   = 32'h0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int p = 0; p < NP; p++) begin
        rst[p] <= R_IDLE; rown[p] <= '0; rid[p] <= '0; rrr[p] <= '0; rcnt[p] <= '0;
        rlen[p] <= '0; rbeat[p] <= '0;
      end
    end else begin
      for (int p = 0; p < NP; p++) begin
        case (rst[p])
          R_IDLE: if (rg_v[p]) begin
            rown[p]  <= rg[p];
            rid[p]   <= m_arid[rg[p]];
            rlen[p]  <= m_arlen[rg[p]];
            rbeat[p] <= '0;
            rrr[p]   <= MW'((int'(rg[p]) + 1) % NM);
            rcnt[p]  <= lat[rg[p]][p];
            rst[p]   <= R_REQ;
          end
          R_REQ:   if (rcnt[p] <= 8'd1) rst[p] <= R_ADDR; else rcnt[p] <= rcnt[p] - 8'd1;
          R_ADDR:  if (p_arready[p]) rst[p] <= R_RWAIT;
          R_RWAIT: if (p_rvalid[p]) begin
            rcnt[p] <= lat[rown[p]][p];
            rst[p]  <= R_RDLY;
          end
          R_RDLY:  if (rcnt[p] <= 8'd1) rst[p] <= R_DATA; else rcnt[p] <= rcnt[p] - 8'd1;
          R_DATA:  if (p_rvalid[p] && m_rready[rown[p]]) begin
            rbeat[p] <= rbeat[p] + 8'd1;
            if (p_rlast[p]) rst[p] <= R_IDLE;
          end
          default: rst[p] <= R_IDLE;
        endcase
      end
    end
  end

  always_comb begin
    for (int m = 0; m < NM; m++) begin
      m_arready[m] = 1'b0; m_rvalid[m] = 1'b0; m_rdata[m] = '0; m_rresp[m] = '0;
      m_rlast[m] = 1'b0; m_rid[m] = '0;
    end
    for (int p = 0; p < NP; p++) begin
      if (rst[p] == R_ADDR) m_arready[rown[p]] = p_arready[p];
      if (rst[p] == R_DATA) begin
        m_rvalid[rown[p]] = p_rvalid[p];
        m_rdata[rown[p]]  = p_rdata[p];
        m_rresp[rown[p]]  = p_rresp[p];
        m_rlast[rown[p]]  = p_rlast[p];
        m_rid[rown[p]]    = rid[p];
      end
    end
    for (int s = 0; s < NS; s++) begin
      s_arid[s]    = (s == S_SRAM) ? '0 : {4'(rown[s]), rid[s]};
      s_araddr[s]  = m_araddr[rown[s]];
      s_arlen[s]   = m_arlen[rown[s]];
      s_arsize[s]  = m_arsize[rown[s]];
      s_arburst[s] = m_arburst[rown[s]];
      s_arprot[s]  = m_arprot[rown[s]];
      s_arvalid[s] = (rst[s] == R_ADDR);
      s_rready[s]  = (rst[s] == R_DATA) && m_rready[rown[s]];
    end
  end

  // ---------------- statistics (read by the testbench) ----------------
  // cycles a master waited at a port held by another master
  int unsigned n_contended_w [NM], n_contended_r [NM];
  always_ff @(posedge clk)
    if (rst_n)
      for (int m = 0; m < NM; m++) begin
        if (m_awvalid[m] && !w_busy[m] && wst[aw_tgt[m]] != W_IDLE) n_contended_w[m] <= n_contended_w[m] + 1;
        if (m_arvalid[m] && !r_busy[m] && rst[ar_tgt[m]] != R_IDLE) n_contended_r[m] <= n_contended_r[m] + 1;
      end
endmodule
