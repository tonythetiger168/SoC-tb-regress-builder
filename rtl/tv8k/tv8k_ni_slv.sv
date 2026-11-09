// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_ni_slv -- slave-side network interface: NoC -> AXI4 master port (32-bit)
// ----------------------------------------------------------------------------
//  * Request flits land in a read queue and a write queue of QD entries each.
//    QD must cover every chunk all masters can have in flight to this slave
//    (masters x MAXO): the queues then never fill, the NI always ejects, and
//    request / response traffic cannot deadlock in the shared router FIFOs.
//  * Each chunk becomes one AXI burst (ID 0, up to 8 beats). Up to OUTS reads
//    and OUTS writes are outstanding at the slave; the slave must answer in
//    order (one ID), as every AXI slave does for a single ID.
//  * Read data / write responses go back as one flit per chunk to the
//    requesting master NI, which always accepts them.
// ============================================================================
module tv8k_ni_slv
  import tv8k_noc_pkg::*;
#(
  parameter int SELF = NM,
  parameter int QD   = 64,
  parameter int OUTS = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // ---------------- AXI4 master port (to the slave) ----------------
  output logic [3:0]  m_awid,
  output logic [31:0] m_awaddr,
  output logic [7:0]  m_awlen,
  output logic [2:0]  m_awsize,
  output logic [1:0]  m_awburst,
  output logic [2:0]  m_awprot,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wlast,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,
  output logic [3:0]  m_arid,
  output logic [31:0] m_araddr,
  output logic [7:0]  m_arlen,
  output logic [2:0]  m_arsize,
  output logic [1:0]  m_arburst,
  output logic [2:0]  m_arprot,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rlast,
  input  logic        m_rvalid,
  output logic        m_rready,
  // ---------------- NoC (node mux) ----------------
  output tv8k_flit_t  inj_flit,
  output logic        inj_valid,
  input  logic        inj_ready,
  input  tv8k_flit_t  ej_flit,
  input  logic        ej_valid,
  output logic        ej_ready
);
  localparam int QB = $clog2(QD);
  localparam int PB = $clog2(OUTS);

  typedef struct packed {
    logic [EPB-1:0]  src;
    logic [TAGW-1:0] tag;
    logic [2:0]      nm1;
  } pend_t;

  pkt_t ej_pkt;
  assign ej_pkt = pkt_of(ej_flit);

  // ---------------- request queues ----------------
  pkt_t        rq [QD];
  pkt_t        wq [QD];
  logic [QB:0] rq_cnt, wq_cnt;
  logic [QB-1:0] rq_wp, rq_rp, wq_wp, wq_rp;
  assign ej_ready = (rq_cnt != (QB+1)'(QD)) && (wq_cnt != (QB+1)'(QD));
  wire   ej_rd = ej_valid && ej_ready && ej_pkt.op == OP_RD;
  wire   ej_wr = ej_valid && ej_ready && ej_pkt.op == OP_WR;

  // ---------------- read: AR issue, R collect ----------------
  pend_t       rp [OUTS];
  logic [PB:0] rp_cnt;
  logic [PB-1:0] rp_wp, rp_rp;
  pkt_t        rh;
  assign rh        = rq[rq_rp];
  assign m_arid    = 4'd0;
  assign m_araddr  = rh.addr;
  assign m_arlen   = 8'(rh.nm1);
  assign m_arsize  = rh.size;
  assign m_arburst = rh.fixed ? 2'b00 : 2'b01;
  assign m_arprot  = rh.prot;
  assign m_arvalid = (rq_cnt != 0) && (rp_cnt != (PB+1)'(OUTS));
  wire   ar_hs     = m_arvalid && m_arready;

  logic [CW-1:0][31:0] r_data;
  logic [CW-1:0][1:0]  r_resp;
  logic [2:0]          r_k;
  pkt_t rr_pkt; logic rr_v;               // read data flit waiting for injection
  assign m_rready = !rr_v && (rp_cnt != 0);
  wire   r_hs     = m_rvalid && m_rready;
  wire   r_end    = r_hs && (r_k == rp[rp_rp].nm1);

  // ---------------- write: AW + W issue, B collect ----------------
  pend_t       wp [OUTS];
  logic [PB:0] wp_cnt;
  logic [PB-1:0] wp_wp, wp_rp;
  pkt_t        wh;
  logic        aw_done;
  logic [2:0]  w_k;
  assign wh        = wq[wq_rp];
  assign m_awid    = 4'd0;
  assign m_awaddr  = wh.addr;
  assign m_awlen   = 8'(wh.nm1);
  assign m_awsize  = wh.size;
  assign m_awburst = wh.fixed ? 2'b00 : 2'b01;
  assign m_awprot  = wh.prot;
  assign m_awvalid = (wq_cnt != 0) && !aw_done && (wp_cnt != (PB+1)'(OUTS));
  assign m_wvalid  = (wq_cnt != 0) && aw_done;
  assign m_wdata   = wh.data[w_k];
  assign m_wstrb   = wh.strb[w_k];
  assign m_wlast   = (w_k == wh.nm1);
  wire   aw_hs     = m_awvalid && m_awready;
  wire   w_hs      = m_wvalid && m_wready;
  wire   w_end     = w_hs && m_wlast;
  pkt_t wr_pkt; logic wr_v;               // write response flit waiting for injection
  assign m_bready = !wr_v && (wp_cnt != 0);
  wire   b_hs     = m_bvalid && m_bready;

  // ---------------- injection ----------------
  logic pref_rd, sel_rd;
  assign sel_rd    = rr_v && (pref_rd || !wr_v);
  assign inj_valid = rr_v || wr_v;
  assign inj_flit  = mk_flit(sel_rd ? rr_pkt : wr_pkt, SELF, VC_RSP);
  wire   inj_hs    = inj_valid && inj_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rq_cnt <= '0; rq_wp <= '0; rq_rp <= '0; wq_cnt <= '0; wq_wp <= '0; wq_rp <= '0;
      rp_cnt <= '0; rp_wp <= '0; rp_rp <= '0; wp_cnt <= '0; wp_wp <= '0; wp_rp <= '0;
      r_k <= '0; r_data <= '0; r_resp <= '0; rr_v <= 1'b0; rr_pkt <= '0;
      aw_done <= 1'b0; w_k <= '0; wr_v <= 1'b0; wr_pkt <= '0; pref_rd <= 1'b1;
    end else begin
      // queues
      if (ej_rd) begin rq[rq_wp] <= ej_pkt; rq_wp <= (int'(rq_wp) == QD - 1) ? '0 : rq_wp + 1'b1; end
      if (ej_wr) begin wq[wq_wp] <= ej_pkt; wq_wp <= (int'(wq_wp) == QD - 1) ? '0 : wq_wp + 1'b1; end
      if (ar_hs) begin
        rq_rp <= (int'(rq_rp) == QD - 1) ? '0 : rq_rp + 1'b1;
        rp[rp_wp] <= '{src: rh.src_ep, tag: rh.tag, nm1: rh.nm1};
        rp_wp <= (int'(rp_wp) == OUTS - 1) ? '0 : rp_wp + 1'b1;
      end
      rq_cnt <= rq_cnt + (QB+1)'(ej_rd) - (QB+1)'(ar_hs);
      // read data
      if (r_hs) begin
        r_data[r_k] <= m_rdata;
        r_resp[r_k] <= m_rresp;
        if (r_end) begin
          automatic pkt_t p = '0;
          automatic logic [CW-1:0][31:0] d = r_data;
          automatic logic [CW-1:0][1:0]  s = r_resp;
          d[r_k] = m_rdata;
          s[r_k] = m_rresp;
          p.op = OP_RDATA; p.dst_ep = rp[rp_rp].src; p.src_ep = EPB'(SELF);
          p.tag = rp[rp_rp].tag; p.nm1 = rp[rp_rp].nm1; p.data = d; p.rresp = s;
          rr_pkt <= p;
          rr_v   <= 1'b1;
          r_k    <= '0;
          rp_rp  <= (int'(rp_rp) == OUTS - 1) ? '0 : rp_rp + 1'b1;
        end else
          r_k <= r_k + 3'd1;
      end
      rp_cnt <= rp_cnt + (PB+1)'(ar_hs) - (PB+1)'(r_end);
      // writes
      if (aw_hs) begin
        aw_done <= 1'b1;
        wp[wp_wp] <= '{src: wh.src_ep, tag: wh.tag, nm1: wh.nm1};
        wp_wp <= (int'(wp_wp) == OUTS - 1) ? '0 : wp_wp + 1'b1;
      end
      if (w_hs) w_k <= w_end ? '0 : w_k + 3'd1;
      if (w_end) begin
        aw_done <= 1'b0;
        wq_rp <= (int'(wq_rp) == QD - 1) ? '0 : wq_rp + 1'b1;
      end
      wq_cnt <= wq_cnt + (QB+1)'(ej_wr) - (QB+1)'(w_end);
      if (b_hs) begin
        automatic pkt_t p = '0;
        p.op = OP_WRSP; p.dst_ep = wp[wp_rp].src; p.src_ep = EPB'(SELF);
        p.tag = wp[wp_rp].tag; p.resp = m_bresp;
        wr_pkt <= p;
        wr_v   <= 1'b1;
        wp_rp  <= (int'(wp_rp) == OUTS - 1) ? '0 : wp_rp + 1'b1;
      end
      wp_cnt <= wp_cnt + (PB+1)'(aw_hs) - (PB+1)'(b_hs);
      // injection
      if (inj_hs) begin
        if (sel_rd) rr_v <= 1'b0; else wr_v <= 1'b0;
        pref_rd <= !sel_rd;
      end
    end
  end
endmodule
