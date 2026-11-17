// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_ni_mst -- master-side network interface: AXI4 slave port -> NoC
// ----------------------------------------------------------------------------
//  * DW = 32: any AXI4 burst (FIXED / INCR / WRAP, narrow, unaligned, strobes).
//    DW = 64: full-width (AxSIZE = 3) INCR bursts, the form the c1p decoder's
//    AXI master issues; each 64-bit beat travels as two 32-bit words.
//  * Each burst is cut into chunks of up to 8 contiguous 32-bit words (a WRAP
//    burst splits at its wrap point); one chunk = one request flit.
//  * Up to MAXB bursts per direction accepted, up to MAXO chunks per direction
//    in flight. A read chunk is only issued when its response slot is free, so
//    responses are always accepted (ej_ready = 1).
//  * Responses are returned in issue order (stricter than AXI needs: no read
//    interleaving, no reordering across IDs), so any AXI master is happy.
//  * Address decode misses never enter the NoC: DECERR is answered locally.
// ============================================================================
module tv8k_ni_mst
  import tv8k_noc_pkg::*;
#(
  parameter int SELF = 0,                 // endpoint id
  parameter int DW   = 32,                // 32 or 64
  parameter int IDW  = 4,
  parameter int MAXB = 4,                 // bursts per direction
  parameter int MAXO = 8                  // chunks in flight per direction
)(
  input  logic             clk,
  input  logic             rst_n,
  // ---------------- AXI4 slave port (from the master IP / VIP) ----------------
  input  logic [IDW-1:0]   s_awid,
  input  logic [31:0]      s_awaddr,
  input  logic [7:0]       s_awlen,
  input  logic [2:0]       s_awsize,
  input  logic [1:0]       s_awburst,
  input  logic [2:0]       s_awprot,
  input  logic             s_awvalid,
  output logic             s_awready,
  input  logic [DW-1:0]    s_wdata,
  input  logic [DW/8-1:0]  s_wstrb,
  input  logic             s_wlast,
  input  logic             s_wvalid,
  output logic             s_wready,
  output logic [IDW-1:0]   s_bid,
  output logic [1:0]       s_bresp,
  output logic             s_bvalid,
  input  logic             s_bready,
  input  logic [IDW-1:0]   s_arid,
  input  logic [31:0]      s_araddr,
  input  logic [7:0]       s_arlen,
  input  logic [2:0]       s_arsize,
  input  logic [1:0]       s_arburst,
  input  logic [2:0]       s_arprot,
  input  logic             s_arvalid,
  output logic             s_arready,
  output logic [IDW-1:0]   s_rid,
  output logic [DW-1:0]    s_rdata,
  output logic [1:0]       s_rresp,
  output logic             s_rlast,
  output logic             s_rvalid,
  input  logic             s_rready,
  // ---------------- NoC (node mux) ----------------
  output tv8k_flit_t       inj_flit,
  output logic             inj_valid,
  input  logic             inj_ready,
  input  tv8k_flit_t       ej_flit,
  input  logic             ej_valid,
  output logic             ej_ready
);
  localparam int R  = DW / 32;            // words per beat
  localparam int BW = $clog2(MAXB);
  localparam int OW = $clog2(MAXO);
  localparam logic [1:0] DECERR = 2'b11;

  typedef struct packed {
    logic [IDW-1:0] id;
    logic [31:0]    addr;
    logic [7:0]     len;
    logic [2:0]     size;
    logic [1:0]     burst;
    logic [2:0]     prot;
  } burst_t;

  // AXI4 A3.4.1 beat address
  function automatic logic [31:0] beat_addr(burst_t b, int unsigned i);
    logic [31:0] nb, aligned, wsize, wbase;
    nb = 32'd1 << b.size;
    aligned = b.addr & ~(nb - 1);
    case (b.burst)
      2'b00: return b.addr;
      2'b10: begin
        wsize = nb * (32'(b.len) + 1);
        wbase = b.addr & ~(wsize - 1);
        return wbase + ((aligned - wbase + i * nb) & (wsize - 1));
      end
      default: return (i == 0) ? b.addr : aligned + i * nb;
    endcase
  endfunction

  // beats in the chunk that starts at beat i (1..8/R)
  function automatic int unsigned chunk_beats(burst_t b, int unsigned i);
    int unsigned n = 1;
    logic [31:0] nb = 32'd1 << b.size;
    for (int unsigned k = 1; k < CW / R; k++) begin
      if (i + k > int'(b.len)) break;
      if (b.burst != 2'b00 &&
          beat_addr(b, i + k) != (beat_addr(b, i + k - 1) & ~(nb - 1)) + nb) break;
      n++;
    end
    return n;
  endfunction

  logic inj_pref_rd, inj_sel_rd;
  pkt_t ej_pkt;
  assign ej_pkt   = pkt_of(ej_flit);
  assign ej_ready = 1'b1;                 // every response has a reserved slot

  // ===========================================================================
  // read side
  // ===========================================================================
  burst_t           rb   [MAXB];
  logic [BW:0]      rb_cnt;
  logic [BW-1:0]    rb_wp, rb_rp;
  logic [7:0]       rb_i;                 // next beat of the head burst to issue

  typedef struct packed {
    logic [IDW-1:0]       id;
    logic [2:0]           nm1;            // words - 1
    logic                 last;           // last chunk of its burst
    logic                 filled;
    logic [CW-1:0][1:0]   rresp;
    logic [CW-1:0][31:0]  data;
  } rslot_t;
  rslot_t           rs   [MAXO];
  logic [OW:0]      rs_cnt;
  logic [OW-1:0]    rs_wp, rs_rp;
  logic [2:0]       rs_k;                 // word index of the next R beat in the head slot

  pkt_t  rq_pkt;  logic rq_v;             // read request waiting for injection

  assign s_arready = (rb_cnt != (BW+1)'(MAXB));

  // chunk at the head of the read queue
  burst_t      rh;
  int unsigned rh_n;
  logic        rh_last;
  logic [EPB-1:0] rh_dst;
  logic        rd_issue;
  always_comb begin
    rh      = rb[rb_rp];
    rh_n    = chunk_beats(rh, rb_i);
    rh_last = (int'(rb_i) + rh_n - 1 == int'(rh.len));
    rh_dst  = decode(beat_addr(rh, rb_i));
    rd_issue = (rb_cnt != 0) && (rs_cnt != (OW+1)'(MAXO)) && !rq_v;
  end

  // R channel from the head slot
  rslot_t rhs;
  assign rhs      = rs[rs_rp];
  assign s_rvalid = (rs_cnt != 0) && rhs.filled;
  assign s_rid    = rhs.id;
  always_comb begin
    s_rdata = '0;
    s_rresp = rhs.rresp[rs_k];
    for (int w = 0; w < R; w++) begin
      s_rdata[32*w +: 32] = rhs.data[rs_k + 3'(w)];
      if (rhs.rresp[rs_k + 3'(w)] > s_rresp) s_rresp = rhs.rresp[rs_k + 3'(w)];
    end
  end
  wire r_slot_end = (int'(rs_k) + R - 1 >= int'(rhs.nm1));
  assign s_rlast  = rhs.last && r_slot_end;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rb_cnt <= '0; rb_wp <= '0; rb_rp <= '0; rb_i <= '0;
      rs_cnt <= '0; rs_wp <= '0; rs_rp <= '0; rs_k <= '0;
      rq_v <= 1'b0; rq_pkt <= '0;
      for (int s = 0; s < MAXO; s++) rs[s] <= '0;
    end else begin
      automatic logic push_b = s_arvalid && s_arready;
      automatic logic pop_b  = 1'b0;
      automatic logic push_s = 1'b0;
      automatic logic pop_s  = 1'b0;
      if (push_b) begin
        rb[rb_wp] <= '{id: s_arid, addr: s_araddr, len: s_arlen, size: s_arsize,
                       burst: s_arburst, prot: s_arprot};
        rb_wp <= (int'(rb_wp) == MAXB - 1) ? '0 : rb_wp + 1'b1;
      end
      // issue one chunk
      if (rd_issue) begin
        automatic rslot_t ns = '0;
        ns.id   = rh.id;
        ns.nm1  = 3'(rh_n * R - 1);
        ns.last = rh_last;
        if (rh_dst == EP_NONE) begin
          ns.filled = 1'b1;
          for (int w = 0; w < CW; w++) ns.rresp[w] = DECERR;
        end else begin
          automatic pkt_t p = '0;
          p.op     = OP_RD;
          p.dst_ep = rh_dst;
          p.src_ep = EPB'(SELF);
          p.tag    = TAGW'(rs_wp);
          p.addr   = beat_addr(rh, rb_i);
          p.nm1    = 3'(rh_n * R - 1);
          p.size   = (R == 2) ? 3'd2 : rh.size;
          p.fixed  = (rh.burst == 2'b00);
          p.prot   = rh.prot;
          rq_pkt <= p;
          rq_v   <= 1'b1;
        end
        rs[rs_wp] <= ns;
        rs_wp <= (int'(rs_wp) == MAXO - 1) ? '0 : rs_wp + 1'b1;
        push_s = 1'b1;
        if (rh_last) begin
          rb_i  <= '0;
          rb_rp <= (int'(rb_rp) == MAXB - 1) ? '0 : rb_rp + 1'b1;
          pop_b = 1'b1;
        end else
          rb_i <= rb_i + 8'(rh_n);
      end
      if (rq_v && inj_valid && inj_ready && inj_sel_rd) rq_v <= 1'b0;
      // read data back from the NoC
      if (ej_valid && ej_pkt.op == OP_RDATA) begin
        automatic logic [OW-1:0] t = OW'(ej_pkt.tag);
        rs[t].filled <= 1'b1;
        rs[t].data   <= ej_pkt.data;
        rs[t].rresp  <= ej_pkt.rresp;
      end
      // R beats
      if (s_rvalid && s_rready) begin
        if (r_slot_end) begin
          rs_k <= '0;
          rs[rs_rp].filled <= 1'b0;
          rs_rp <= (int'(rs_rp) == MAXO - 1) ? '0 : rs_rp + 1'b1;
          pop_s = 1'b1;
        end else
          rs_k <= rs_k + 3'(R);
      end
      rb_cnt <= rb_cnt + (BW+1)'(push_b) - (BW+1)'(pop_b);
      rs_cnt <= rs_cnt + (OW+1)'(push_s) - (OW+1)'(pop_s);
    end
  end

  // ===========================================================================
  // write side
  // ===========================================================================
  typedef struct packed {
    burst_t      b;
    logic [7:0]  nchunk;      // chunks issued so far
    logic [7:0]  nrsp;        // chunk responses received
    logic        issued;      // all chunks issued
    logic [1:0]  worst;
  } wburst_t;
  wburst_t          wb  [MAXB];
  logic [BW:0]      wb_cnt;
  logic [BW-1:0]    wb_wp, wb_ip, wb_rp;  // AW in / chunk build / B out
  logic [BW:0]      wb_pend;              // bursts accepted, not fully issued
  logic [7:0]       wb_i;                 // next beat of the burst being built
  logic [2:0]       wc_n;                 // beats collected in the current chunk
  logic [OW:0]      w_infl;               // write chunks in flight
  logic [CW-1:0][31:0] wc_data;
  logic [CW-1:0][3:0]  wc_strb;
  pkt_t  wq_pkt;  logic wq_v;             // write chunk waiting for injection

  assign s_awready = (wb_cnt != (BW+1)'(MAXB));

  burst_t      wh;
  int unsigned wh_n;                      // beats in the chunk being built
  logic        wh_lastc;                  // that chunk is the last of its burst
  logic [EPB-1:0] wh_dst;
  logic [31:0] wh_a0;
  always_comb begin
    wh       = wb[wb_ip].b;
    wh_a0    = beat_addr(wh, int'(wb_i) - int'(wc_n));
    wh_n     = chunk_beats(wh, int'(wb_i) - int'(wc_n));
    wh_lastc = (int'(wb_i) - int'(wc_n) + wh_n - 1 == int'(wh.len));
    wh_dst   = decode(wh_a0);
  end
  // a W beat is taken while a burst is being built, the chunk has room and a
  // slot will be free for it
  assign s_wready = (wb_pend != 0) && !wq_v && (w_infl != (OW+1)'(MAXO));
  wire   w_take   = s_wvalid && s_wready;
  wire   w_cdone  = w_take && (int'(wc_n) + 1 == int'(wh_n));

  // B from the head burst
  wburst_t whb;
  assign whb      = wb[wb_rp];
  assign s_bvalid = (wb_cnt != 0) && whb.issued && (whb.nrsp == whb.nchunk);
  assign s_bid    = whb.b.id;
  assign s_bresp  = whb.worst;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_cnt <= '0; wb_wp <= '0; wb_ip <= '0; wb_rp <= '0; wb_pend <= '0;
      wb_i <= '0; wc_n <= '0; w_infl <= '0; wq_v <= 1'b0; wq_pkt <= '0;
      wc_data <= '0; wc_strb <= '0;
      for (int s = 0; s < MAXB; s++) wb[s] <= '0;
    end else begin
      automatic logic push_b = s_awvalid && s_awready;
      automatic logic pop_b  = s_bvalid && s_bready;
      automatic logic done_b = 1'b0;
      automatic logic inj_w  = 1'b0;
      automatic logic rsp_w  = ej_valid && ej_pkt.op == OP_WRSP;
      if (push_b) begin
        wb[wb_wp] <= '{b: '{id: s_awid, addr: s_awaddr, len: s_awlen, size: s_awsize,
                            burst: s_awburst, prot: s_awprot},
                       nchunk: 8'd0, nrsp: 8'd0, issued: 1'b0, worst: 2'b00};
        wb_wp <= (int'(wb_wp) == MAXB - 1) ? '0 : wb_wp + 1'b1;
      end
      if (w_take) begin
        for (int w = 0; w < R; w++) begin
          wc_data[int'(wc_n) * R + w] <= s_wdata[32*w +: 32];
          wc_strb[int'(wc_n) * R + w] <= s_wstrb[4*w +: 4];
        end
        wb_i <= wb_i + 8'd1;
        if (w_cdone) begin
          automatic logic [CW-1:0][31:0] d = wc_data;
          automatic logic [CW-1:0][3:0]  s = wc_strb;
          for (int w = 0; w < R; w++) begin
            d[int'(wc_n) * R + w] = s_wdata[32*w +: 32];
            s[int'(wc_n) * R + w] = s_wstrb[4*w +: 4];
          end
          wc_n <= '0;
          if (wh_dst == EP_NONE) begin
            // DECERR locally: the chunk counts as issued and answered
            wb[wb_ip].nrsp  <= wb[wb_ip].nrsp + 8'd1 + 8'(rsp_w && OW'(ej_pkt.tag) == OW'(wb_ip));
            wb[wb_ip].worst <= DECERR;
          end else begin
            automatic pkt_t p = '0;
            p.op     = OP_WR;
            p.dst_ep = wh_dst;
            p.src_ep = EPB'(SELF);
            p.tag    = TAGW'(wb_ip);
            p.addr   = wh_a0;
            p.nm1    = 3'(wh_n * R - 1);
            p.size   = (R == 2) ? 3'd2 : wh.size;
            p.fixed  = (wh.burst == 2'b00);
            p.prot   = wh.prot;
            p.data   = d;
            p.strb   = s;
            wq_pkt <= p;
            wq_v   <= 1'b1;
            inj_w = 1'b1;
          end
          wb[wb_ip].nchunk <= wb[wb_ip].nchunk + 8'd1;
          if (wh_lastc) begin
            wb[wb_ip].issued <= 1'b1;
            wb_ip <= (int'(wb_ip) == MAXB - 1) ? '0 : wb_ip + 1'b1;
            wb_i  <= '0;
            done_b = 1'b1;
          end
        end else
          wc_n <= wc_n + 3'd1;
      end
      // response for a write chunk (unless merged into the DECERR update above)
      if (rsp_w && !(w_take && w_cdone && wh_dst == EP_NONE && OW'(ej_pkt.tag) == OW'(wb_ip))) begin
        automatic logic [BW-1:0] t = BW'(ej_pkt.tag);
        wb[t].nrsp <= wb[t].nrsp + 8'd1;
        if (ej_pkt.resp > wb[t].worst) wb[t].worst <= ej_pkt.resp;
      end
      if (wq_v && inj_valid && inj_ready && !inj_sel_rd) wq_v <= 1'b0;
      if (pop_b) wb_rp <= (int'(wb_rp) == MAXB - 1) ? '0 : wb_rp + 1'b1;
      wb_cnt  <= wb_cnt  + (BW+1)'(push_b) - (BW+1)'(pop_b);
      wb_pend <= wb_pend + (BW+1)'(push_b) - (BW+1)'(done_b);
      w_infl  <= w_infl + (OW+1)'(inj_w) - (OW+1)'(rsp_w);
    end
  end

  // ===========================================================================
  // injection: alternate between the read request and the write chunk
  // ===========================================================================
  assign inj_sel_rd = rq_v && (inj_pref_rd || !wq_v);
  assign inj_valid  = rq_v || wq_v;
  assign inj_flit   = mk_flit(inj_sel_rd ? rq_pkt : wq_pkt, SELF, VC_REQ);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) inj_pref_rd <= 1'b1;
    else if (inj_valid && inj_ready) inj_pref_rd <= !inj_sel_rd;

  // DW = 64 supports full-width INCR bursts only
  // synopsys translate_off
  always @(posedge clk)
    if (R == 2 && rst_n && ((s_awvalid && (s_awsize != 3'd3 || s_awburst != 2'b01)) ||
                            (s_arvalid && (s_arsize != 3'd3 || s_arburst != 2'b01))))
      $error("tv8k_ni_mst[%0d]: 64-bit port needs AxSIZE=3 INCR bursts", SELF);
  // synopsys translate_on
endmodule
