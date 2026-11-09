// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_hnf -- CHI home node (HN-F) on the generated NoC: snoop filter, the
// point of coherence for the coherent memory, and the home of every request
// the RN-F ports (CHI) and the AMBA master NIs (RN-I) send to that memory.
// ----------------------------------------------------------------------------
//  * Snoop filter: inclusive and exact. Every RN-F cache is NL 64-byte lines,
//    direct-mapped (noc_chi_rnf), so the filter is a copy of their tags: per
//    RN-F and set, {valid, unique, tag}. An RN-F evicts (Evict /
//    WriteBackFull, waiting for Comp) before it fills a set again, so the
//    filter never has to back-invalidate.
//  * K transaction slots (HN_SLOTS), each running one transaction: snoops,
//    memory, response, then CompAck where the RN-F sends one. Requests are
//    taken in arrival order; the head waits while a slot holds a line of the
//    same filter set (the RN-I chunk's second line too), so a set -- and so
//    a line and its filter entries -- is never in two transactions and
//    requests to one set are served in order. K = 1 is the serial home.
//  * RN-F requests: ReadShared (UC if no other cache has the line, else SC;
//    an owner is snooped SnpShared and its dirty data is written back),
//    ReadUnique (others SnpUnique; dirty data passed on as UD_PD),
//    CleanUnique (others SnpUnique, Comp UC; Comp I if the requester lost
//    the line to an earlier snoop -- it then asks again with ReadUnique),
//    Evict, WriteBackFull (CompDBIDResp, CopyBackWrData; the data goes to
//    memory only if the requester still owns the line), and ReadNoSnp /
//    WriteNoSnpPtl (one beat of up to 4 bytes) for addresses outside the
//    coherent memory.
//  * RN-I chunks (OP_RD / OP_WR from noc_ni_mst, up to 32 bytes, at most two
//    lines): reads snoop the unique holder SnpCleanShared, writes snoop
//    every holder SnpUnique; dirty data is written back, then the chunk goes
//    to memory and its response back to the master NI.
//  * DMT (CHI_DMT): a ReadShared / ReadUnique line from memory is read with
//    the requester as the source and the CompData fields on the chunk; the
//    slave NI sends the data straight to the requester, which sends CompAck
//    here. DCT (CHI_DCT): with a unique owner, SnpSharedFwd / SnpUniqueFwd;
//    the owner sends the requester its CompData and this home SnpRespFwded
//    (SnpRespDataFwded with the dirty line, written back). If the owner has
//    already dropped the line it answers SnpResp I and the home reads memory.
//  * Several homes (NHN): each owns the lines hn_ep maps to it and keeps the
//    filter for those lines only; nothing is shared between homes.
//  * Memory: the slave NI of the line's channel (decode_tgt), 32-byte
//    chunks; a slot waits for every response before it moves on, so the
//    accesses of one line are ordered.
//  * Always ejects: the request queue holds QD entries (every chunk / request
//    the masters can have outstanding); responses are taken as they arrive.
//    `overflow` flags a sizing error. Responses find their slot by tag: the
//    home's memory chunks carry {slot, kind}, snoops carry the slot as TxnID
//    (SnpResp / SnpRespData echo it), DBIDResp gives the slot as DBID (write
//    data comes back with it), and CompAck matches the requester and its
//    TxnID (an RN-F has one request in flight).
//  * One packet out per cycle: the slots that want to send are served round
//    robin into a 4-entry output queue.
// ============================================================================
module noc_hnf
  import noc_cfg_pkg::*;
#(
  parameter int SELF = NM + NS,
  parameter int QD   = 64,
  parameter int NL   = CHI_LINES,
  parameter int K    = HN_SLOTS
)(
  input  logic       clk,
  input  logic       rst_n,
  output noc_flit_t  inj_flit,
  output logic       inj_valid,
  input  logic       inj_ready,
  input  noc_flit_t  ej_flit,
  input  logic       ej_valid,
  output logic       ej_ready,
  output logic       overflow
);
  localparam int IB = $clog2(NL);
  localparam int TW = 26 - IB;            // tag bits of a line address [31:6]
  localparam int QB = $clog2(QD);
  localparam int KB = (K > 1) ? $clog2(K) : 1;

  // synopsys translate_off
  initial if (K < 1 || K > 2 ** (TAGW - 2)) $fatal(1, "noc_hnf: K=%0d slots (1..%0d)", K, 2 ** (TAGW - 2));
  // synopsys translate_on

  // ---------------- snoop filter ----------------
  logic          sf_v [NRN][NL];
  logic          sf_u [NRN][NL];
  logic [TW-1:0] sf_t [NRN][NL];

  function automatic logic [IB-1:0] set_of(logic [25:0] l); return l[IB-1:0]; endfunction
  function automatic logic [TW-1:0] tag_of(logic [25:0] l); return l[25:IB]; endfunction

  function automatic int rn_of(int ep);
    for (int r = 0; r < NRN; r++) if (RN_EP[r] == ep) return r;
    return -1;
  endfunction

  // does RN-F r hold line l (per the filter)?
  function automatic logic holds(int r, logic [25:0] l);
    return sf_v[r][set_of(l)] && sf_t[r][set_of(l)] == tag_of(l);
  endfunction

  // ---------------- request queue ----------------
  pkt_t        rq [QD];
  logic [QB:0] rq_cnt;
  logic [QB-1:0] rq_wp, rq_rp;

  // ---------------- output queue ----------------
  localparam int OQ = 4;
  pkt_t        oq [OQ];
  logic [2:0]  oq_cnt;
  logic [1:0]  oq_wp, oq_rp;
  logic        push;
  pkt_t        np;
  wire         can_push = (oq_cnt < 3'(OQ));

  assign inj_valid = (oq_cnt != 0);
  assign inj_flit  = mk_flit(oq[oq_rp], SELF,
                             (oq[oq_rp].op == OP_RD || oq[oq_rp].op == OP_WR || oq[oq_rp].op == OP_CSNP) ? VC_REQ : VC_RSP);
  assign ej_ready  = 1'b1;

  pkt_t ej;
  assign ej = pkt_of(ej_flit);
  wire ej_req = ej_valid && (ej.op == OP_RD || ej.op == OP_WR || ej.op == OP_CREQ);

  // ---------------- transaction slots ----------------
  typedef enum logic [3:0] {
    H_IDLE, H_SETUP, H_SNP, H_SNPW, H_POST, H_NEXT, H_WB, H_MRD, H_MEMW, H_FWD,
    H_REPLY, H_ACK, H_DBID, H_WDATA, H_DMT, H_GRANT
  } hst_e;
  hst_e          st [K], after_wb [K];    // after_wb: state after H_MEMW

  pkt_t          cur [K];
  int            rqr [K];                 // requesting RN-F (-1: RN-I chunk)
  logic          ni_chunk [K];            // RN-I chunk
  logic [25:0]   ln [K][2];
  logic          nl2 [K], li [K];         // two lines; line in progress
  logic [NRN-1:0] snp_todo [K], snp_pend [K];
  logic [4:0]    snp_op [K];
  logic [1:0]    snp_half [K][NRN];
  logic [255:0]  lbuf [K][2];             // line data (snoop, memory or write data)
  logic          dirty [K];               // lbuf holds dirty data passed to the home
  logic [2:0]    wd_resp [K];             // CopyBackWrData / NonCopyBackWrData Resp
  logic [31:0]   wd_be [K];
  logic [1:0]    wd_n [K];                // write-data flits received
  logic [2:0]    mem_pend [K];            // own memory chunks outstanding
  logic [1:0]    mem_sent [K];
  pkt_t          fwd_rsp [K];             // response to a forwarded chunk / NoSnp access
  logic          ack_got [K];
  logic [1:0]    rep_n [K];               // reply flits sent
  logic          lost [K];                // CleanUnique: requester no longer holds the line
  logic          nderr [K];               // NoSnp: no slave at the address
  logic          fwded [K];               // DCT: the owner sent the requester its CompData

  // per-slot decode
  logic          is_rs [K], is_ru [K], is_cu [K], is_ev [K], is_wb [K], is_rns [K], is_wns [K];
  logic [25:0]   L  [K];
  logic [IB-1:0] LS [K];
  logic [TW-1:0] LT [K];
  logic [2:0]    gr_cresp [K];            // ReadShared / ReadUnique: the requester's state
  logic [K-1:0]  wantp;                   // slot wants to send a packet this cycle
  always_comb
    for (int k = 0; k < K; k++) begin
      automatic logic [5:0] opc = cur[k].copc;
      is_rs[k]  = !ni_chunk[k] && opc == REQ_READSHARED;
      is_ru[k]  = !ni_chunk[k] && opc == REQ_READUNIQUE;
      is_cu[k]  = !ni_chunk[k] && opc == REQ_CLEANUNIQUE;
      is_ev[k]  = !ni_chunk[k] && opc == REQ_EVICT;
      is_wb[k]  = !ni_chunk[k] && opc == REQ_WRITEBACKFULL;
      is_rns[k] = !ni_chunk[k] && opc == REQ_READNOSNP;
      is_wns[k] = !ni_chunk[k] && opc == REQ_WRITENOSNPPTL;
      L[k]  = ln[k][li[k]];
      LS[k] = set_of(L[k]);
      LT[k] = tag_of(L[k]);
      // ReadShared: SC if another cache keeps the line after the snoops, else UC
      gr_cresp[k] = is_ru[k] ? (dirty[k] ? RESP_UD_PD : RESP_UC) : RESP_UC;
      if (is_rs[k])
        for (int r = 0; r < NRN; r++)
          if (r != rqr[k] && holds(r, L[k])) gr_cresp[k] = RESP_SC;
      wantp[k] = st[k] inside {H_SNP, H_WB, H_MRD, H_FWD, H_DBID, H_REPLY, H_DMT};
    end

  // ---------------- output arbitration: round robin over the slots ----------------
  logic [KB-1:0] rr, ps;                  // next priority; granted slot
  logic          pany;
  always_comb begin
    ps = rr; pany = 1'b0;
    for (int i = K - 1; i >= 0; i--) begin
      automatic int k = (int'(rr) + i) % K;
      if (wantp[k]) begin ps = KB'(k); pany = 1'b1; end
    end
  end
  assign push = can_push && pany;
  wire [K-1:0] gnt = push ? (K'(1) << ps) : '0;

  // the packet the granted slot sends (combinational), see H_* below
  always_comb begin
    automatic int k = int'(ps);
    np = '0;
    np.src_ep = EPB'(SELF);
    np.tag    = cur[k].tag;
    unique case (st[k])
      H_SNP: begin
        for (int r = NRN - 1; r >= 0; r--)
          if (snp_todo[k][r]) np.dst_ep = EPB'(RN_EP[r]);
        np.op   = OP_CSNP;
        np.tag  = TAGW'(k);                 // TxnID: the slot (SnpResp echoes it)
        np.copc = {1'b0, snp_op[k]};
        np.addr = {L[k], 6'd0};
        np.fwd  = cur[k].src_ep;            // DCT: FwdNID, FwdTxnID
        np.dbid = cur[k].tag;
      end
      H_WB, H_MRD: begin                    // a 32-byte half of line L
        np.op     = (st[k] == H_WB) ? OP_WR : OP_RD;
        np.dst_ep = decode_tgt({L[k], 6'd0});
        np.tag    = TAGW'({k, 1'b0, mem_sent[k][0]});
        np.addr   = {L[k], mem_sent[k][0], 5'd0};
        np.nm1    = 3'd7;
        np.size   = 3'd2;
        np.strb   = '1;
        np.data   = lbuf[k][mem_sent[k][0]];
      end
      H_DMT: begin                          // DMT: memory sends the requester its CompData
        np.op     = OP_RD;
        np.dst_ep = decode_tgt({L[k], 6'd0});
        np.src_ep = cur[k].src_ep;
        np.addr   = {L[k], mem_sent[k][0], 5'd0};
        np.nm1    = 3'd7;
        np.size   = 3'd2;
        np.copc   = {2'b0, DAT_COMPDATA};
        np.cresp  = gr_cresp[k];
        np.dataid = {mem_sent[k][0], 1'b0};
        np.hnid   = EPB'(SELF);
      end
      H_FWD: begin
        if (ni_chunk[k]) np = cur[k];       // the chunk as the master NI sent it
        else begin                          // NoSnp: one beat
          np.op   = is_rns[k] ? OP_RD : OP_WR;
          np.addr = cur[k].addr;
          np.size = cur[k].size;
          np.data[0] = lbuf[k][cur[k].addr[5]][32*cur[k].addr[4:2] +: 32];
          np.strb[0] = wd_be[k][4*cur[k].addr[4:2] +: 4];
        end
        np.dst_ep = decode_tgt(cur[k].addr);
        np.src_ep = EPB'(SELF);
        np.tag    = TAGW'({k, 2'd2});
      end
      H_DBID: begin
        np.op = OP_CRSP; np.dst_ep = cur[k].src_ep;
        np.copc = {2'b0, is_wb[k] ? RSP_COMPDBIDRESP : RSP_DBIDRESP};
        np.dbid = TAGW'(k);                 // DBID: the slot (write data comes back with it)
      end
      H_REPLY: begin
        np.dst_ep = cur[k].src_ep;
        if (ni_chunk[k]) begin              // back to the master NI
          np.op    = fwd_rsp[k].op;
          np.resp  = fwd_rsp[k].resp;
          np.rresp = fwd_rsp[k].rresp;
          np.data  = fwd_rsp[k].data;
        end else if (is_rs[k] || is_ru[k]) begin
          np.op     = OP_CDAT;
          np.copc   = {2'b0, DAT_COMPDATA};
          np.dataid = {rep_n[k][0], 1'b0};
          np.data   = lbuf[k][rep_n[k][0]];
          np.cresp  = gr_cresp[k];
          np.hnid   = EPB'(SELF);
        end else if (is_rns[k]) begin
          np.op     = OP_CDAT;
          np.copc   = {2'b0, DAT_COMPDATA};
          np.dataid = {cur[k].addr[5], 1'b0};
          np.cresp  = RESP_UC;
          np.hnid   = EPB'(SELF);
          np.resp   = nderr[k] ? RESPERR_NDERR : fwd_rsp[k].rresp[0] == 2'b11 ? RESPERR_NDERR :
                      fwd_rsp[k].rresp[0] == 2'b10 ? RESPERR_DERR : RESPERR_OK;
          if (!nderr[k]) np.data[cur[k].addr[4:2]] = fwd_rsp[k].data[0];
        end else begin                      // Comp: CleanUnique, Evict, WriteNoSnpPtl
          np.op    = OP_CRSP;
          np.copc  = {2'b0, RSP_COMP};
          np.cresp = (is_cu[k] && !lost[k]) ? RESP_UC : RESP_I;
          if (is_wns[k])
            np.resp = nderr[k] ? RESPERR_NDERR : fwd_rsp[k].resp == 2'b11 ? RESPERR_NDERR :
                      fwd_rsp[k].resp == 2'b10 ? RESPERR_DERR : RESPERR_OK;
        end
      end
      default: ;
    endcase
  end

  // ---------------- dispatch: the queue head to a free slot ----------------
  pkt_t          hq;
  logic [31:0]   hq_last;
  logic          hq_nl2, d_ok;
  logic [KB-1:0] d_k;
  always_comb begin
    automatic logic free = 1'b0, hz = 1'b0;
    hq      = rq[rq_rp];
    hq_last = hq.fixed ? hq.addr : hq.addr + (32'(hq.nm1) << hq.size);
    hq_nl2  = (hq.op != OP_CREQ) && (hq_last[31:6] != hq.addr[31:6]);
    d_k = '0;
    for (int k = K - 1; k >= 0; k--) if (st[k] == H_IDLE) begin free = 1'b1; d_k = KB'(k); end
    for (int k = 0; k < K; k++)
      if (st[k] != H_IDLE)
        for (int j = 0; j < 2; j++)
          if (j == 0 || nl2[k]) begin
            if (set_of(ln[k][j]) == set_of(hq.addr[31:6])) hz = 1'b1;
            if (hq_nl2 && set_of(ln[k][j]) == set_of(hq_last[31:6])) hz = 1'b1;
          end
    d_ok = (rq_cnt != 0) && free && !hz;
  end

  wire [K-1:0] mem_inc;
  for (genvar k = 0; k < K; k++) begin : g_mi
    assign mem_inc[k] = gnt[k] && (st[k] == H_WB || st[k] == H_MRD || st[k] == H_FWD);
  end
  wire        mem_dec = ej_valid && (ej.op == OP_RDATA || ej.op == OP_WRSP);
  wire [KB-1:0] ej_ks = KB'(ej.tag >> 2); // slot of a memory response to the home
  wire [KB-1:0] ej_kt = KB'(ej.tag);      // slot of a snoop response / write data

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < NRN; r++)
        for (int i = 0; i < NL; i++) begin sf_v[r][i] <= 1'b0; sf_u[r][i] <= 1'b0; sf_t[r][i] <= '0; end
      rq_cnt <= '0; rq_wp <= '0; rq_rp <= '0;
      oq_cnt <= '0; oq_wp <= '0; oq_rp <= '0;
      overflow <= 1'b0; rr <= '0;
      for (int k = 0; k < K; k++) begin
        st[k] <= H_IDLE; after_wb[k] <= H_IDLE;
        cur[k] <= '0; rqr[k] <= -1; ni_chunk[k] <= 1'b0; ln[k][0] <= '0; ln[k][1] <= '0;
        nl2[k] <= 1'b0; li[k] <= 1'b0;
        snp_todo[k] <= '0; snp_pend[k] <= '0; snp_op[k] <= '0;
        for (int r = 0; r < NRN; r++) snp_half[k][r] <= '0;
        lbuf[k][0] <= '0; lbuf[k][1] <= '0; dirty[k] <= 1'b0;
        wd_resp[k] <= '0; wd_be[k] <= '0; wd_n[k] <= '0;
        mem_pend[k] <= '0; mem_sent[k] <= '0; fwd_rsp[k] <= '0; ack_got[k] <= 1'b0; rep_n[k] <= '0;
        lost[k] <= 1'b0; nderr[k] <= 1'b0; fwded[k] <= 1'b0;
      end
    end else begin
      // ---------------- eject ----------------
      if (ej_req) begin
        if (rq_cnt == (QB+1)'(QD)) overflow <= 1'b1;
        rq[rq_wp] <= ej;
        rq_wp <= (int'(rq_wp) == QD - 1) ? '0 : rq_wp + 1'b1;
      end
      if (ej_valid && !ej_req) begin
        automatic int r = rn_of(int'(ej.src_ep));
        unique case (ej.op)
          OP_RDATA, OP_WRSP: begin           // memory / forwarded access: tag {slot, kind}
            if (ej.tag[1:0] == 2'd2) fwd_rsp[ej_ks] <= ej;
            else if (ej.op == OP_RDATA) lbuf[ej_ks][ej.tag[0]] <= ej.data;
          end
          OP_CRSP: begin
            if (ej.copc[3:0] == RSP_COMPACK) begin
              for (int k = 0; k < K; k++)
                if (st[k] != H_IDLE && !ni_chunk[k] && rqr[k] == r && cur[k].tag == ej.tag)
                  ack_got[k] <= 1'b1;
            end else if ((ej.copc[3:0] == RSP_SNPRESP || ej.copc[3:0] == RSP_SNPRESPFWDED) && r >= 0) begin
              if (ej.copc[3:0] == RSP_SNPRESPFWDED) fwded[ej_kt] <= 1'b1;
              if (holds(r, L[ej_kt])) begin
                sf_v[r][LS[ej_kt]] <= (ej.cresp[1:0] != 2'd0);
                sf_u[r][LS[ej_kt]] <= (ej.cresp[1:0] == 2'd2);
              end
              snp_pend[ej_kt][r] <= 1'b0;
            end
          end
          OP_CDAT: begin                     // TxnID: the slot (snoop TxnID or DBID)
            lbuf[ej_kt][ej.dataid[1]] <= ej.data;
            if ((ej.copc[3:0] == DAT_SNPRESPDATA || ej.copc[3:0] == DAT_SNPRESPDATAFWDED) && r >= 0) begin
              if (ej.copc[3:0] == DAT_SNPRESPDATAFWDED) fwded[ej_kt] <= 1'b1;
              if (ej.cresp[2]) dirty[ej_kt] <= 1'b1;
              snp_half[ej_kt][r] <= snp_half[ej_kt][r] + 2'd1;
              if (snp_half[ej_kt][r] == 2'd1) begin
                if (holds(r, L[ej_kt])) begin
                  sf_v[r][LS[ej_kt]] <= (ej.cresp[1:0] != 2'd0);
                  sf_u[r][LS[ej_kt]] <= (ej.cresp[1:0] == 2'd2);
                end
                snp_pend[ej_kt][r] <= 1'b0;
              end
            end else begin                  // CopyBackWrData / NonCopyBackWrData
              wd_resp[ej_kt] <= ej.cresp;
              wd_be[ej_kt]   <= ej.strb;
              wd_n[ej_kt]    <= wd_n[ej_kt] + 2'd1;
            end
          end
          default: ;
        endcase
      end

      // ---------------- output queue ----------------
      if (inj_valid && inj_ready) oq_rp <= oq_rp + 2'd1;
      if (push) begin
        oq[oq_wp] <= np;
        oq_wp <= oq_wp + 2'd1;
        rr <= (int'(ps) == K - 1) ? '0 : ps + 1'b1;
      end
      oq_cnt <= oq_cnt + 3'(push) - 3'(inj_valid && inj_ready);

      // ---------------- dispatch ----------------
      if (d_ok) begin
        automatic int k = int'(d_k);
        rq_rp <= (int'(rq_rp) == QD - 1) ? '0 : rq_rp + 1'b1;
        cur[k] <= hq;
        ni_chunk[k] <= (hq.op != OP_CREQ);
        rqr[k] <= rn_of(int'(hq.src_ep));
        ln[k][0] <= hq.addr[31:6];
        ln[k][1] <= hq_last[31:6];
        nl2[k] <= hq_nl2;
        li[k] <= 1'b0;
        dirty[k] <= 1'b0; ack_got[k] <= 1'b0; rep_n[k] <= '0; wd_n[k] <= '0; mem_sent[k] <= '0;
        lost[k] <= 1'b0; fwded[k] <= 1'b0;
        nderr[k] <= (hq.op == OP_CREQ) && decode_tgt(hq.addr) == EP_NONE;
        st[k] <= H_SETUP;
      end

      // ---------------- transactions ----------------
      for (int k = 0; k < K; k++) begin
        unique case (st[k])
          H_IDLE: ;

          H_SETUP: begin                    // snoops for line ln[li]
            automatic logic [NRN-1:0] msk = '0;
            automatic logic [4:0] so = SNP_UNIQUE;
            for (int r = 0; r < NRN; r++) begin
              if (!holds(r, L[k]) || r == rqr[k]) continue;
              if (ni_chunk[k]) begin
                if (cur[k].op == OP_RD) begin so = SNP_CLEANSHARED; msk[r] = sf_u[r][LS[k]]; end
                else msk[r] = 1'b1;
              end else if (is_rs[k]) begin so = SNP_SHARED; msk[r] = sf_u[r][LS[k]]; end
              else if (is_ru[k]) msk[r] = 1'b1;
              else if (is_cu[k]) msk[r] = holds(rqr[k], L[k]);
            end
            // DCT: ReadShared / ReadUnique with a unique owner: it forwards the line
            if (CHI_DCT && (is_rs[k] || is_ru[k]))
              for (int r = 0; r < NRN; r++)
                if (r != rqr[k] && holds(r, L[k]) && sf_u[r][LS[k]]) begin
                  so = is_rs[k] ? SNP_SHAREDFWD : SNP_UNIQUEFWD;
                  msk = '0;
                  msk[r] = 1'b1;
                end
            if (is_cu[k] && !holds(rqr[k], L[k])) lost[k] <= 1'b1;
            snp_op[k] <= so;
            snp_todo[k] <= msk;
            snp_pend[k] <= msk;
            for (int r = 0; r < NRN; r++) snp_half[k][r] <= '0;
            if (is_wb[k] || is_wns[k]) st[k] <= H_DBID;
            else if (is_rns[k]) st[k] <= nderr[k] ? H_REPLY : H_FWD;
            else if (is_ev[k]) begin
              if (holds(rqr[k], L[k])) sf_v[rqr[k]][LS[k]] <= 1'b0;
              st[k] <= H_REPLY;
            end else st[k] <= (msk != 0) ? H_SNP : H_POST;
          end

          H_SNP: if (gnt[k]) begin
            automatic logic [NRN-1:0] t = snp_todo[k];
            for (int r = 0; r < NRN; r++) if (t[r]) begin t[r] = 1'b0; break; end
            snp_todo[k] <= t;
            if (t == 0) st[k] <= H_SNPW;
          end

          H_SNPW: if (snp_pend[k] == 0) st[k] <= H_POST;

          H_POST: begin                     // snoops done for line ln[li]
            if (ni_chunk[k]) begin
              automatic hst_e nx = (nl2[k] && !li[k]) ? H_NEXT : H_FWD;
              if (dirty[k]) begin after_wb[k] <= nx; st[k] <= H_WB; end
              else st[k] <= nx;
            end else if (fwded[k]) begin    // DCT: the owner sent the CompData
              after_wb[k] <= H_GRANT;
              st[k] <= dirty[k] ? H_WB : H_GRANT;   // SnpSharedFwd of a dirty line: to memory
            end else if (is_rs[k]) begin
              after_wb[k] <= H_REPLY;
              st[k] <= dirty[k] ? H_WB : CHI_DMT ? H_DMT : H_MRD;   // dirty: to memory, and the data from lbuf
            end else if (is_ru[k]) begin
              after_wb[k] <= H_REPLY;
              st[k] <= dirty[k] ? H_REPLY : CHI_DMT ? H_DMT : H_MRD; // dirty: passed on as UD_PD
            end else st[k] <= H_REPLY;      // CleanUnique
          end

          H_NEXT: begin                     // RN-I chunk: its second line
            dirty[k] <= 1'b0;
            li[k] <= 1'b1;
            st[k] <= H_SETUP;
          end

          H_WB, H_MRD: if (gnt[k]) begin    // two halves of line L
            mem_sent[k] <= mem_sent[k] + 2'd1;
            if (mem_sent[k] == 2'd1) st[k] <= H_MEMW;
          end

          H_DMT: if (gnt[k]) begin          // two halves, then the requester's CompAck
            mem_sent[k] <= mem_sent[k] + 2'd1;
            if (mem_sent[k] == 2'd1) begin
              mem_sent[k] <= '0;
              st[k] <= H_GRANT;
            end
          end

          H_GRANT: begin                    // the requester's line in the filter
            if (!(is_cu[k] && lost[k])) begin
              sf_v[rqr[k]][LS[k]] <= 1'b1;
              sf_t[rqr[k]][LS[k]] <= LT[k];
              sf_u[rqr[k]][LS[k]] <= is_ru[k] || is_cu[k] || gr_cresp[k] == RESP_UC;
            end
            st[k] <= H_ACK;
          end

          H_MEMW: if (mem_pend[k] == 0) begin
            mem_sent[k] <= '0;
            st[k] <= after_wb[k];
          end

          H_FWD: if (gnt[k]) begin
            after_wb[k] <= H_REPLY;
            st[k] <= H_MEMW;
          end

          H_DBID: if (gnt[k]) st[k] <= H_WDATA;

          H_WDATA: if (wd_n[k] == (is_wb[k] ? 2'd2 : 2'd1)) begin
            if (is_wb[k]) begin
              if (holds(rqr[k], L[k])) sf_v[rqr[k]][LS[k]] <= 1'b0;
              if (holds(rqr[k], L[k]) && sf_u[rqr[k]][LS[k]] && wd_resp[k] == RESP_UD_PD) begin
                after_wb[k] <= H_IDLE;
                st[k] <= H_WB;
              end else st[k] <= H_IDLE;
            end else st[k] <= nderr[k] ? H_REPLY : H_FWD;
          end

          H_REPLY: if (gnt[k]) begin
            rep_n[k] <= rep_n[k] + 2'd1;
            if (rep_n[k] + 2'd1 == ((!ni_chunk[k] && (is_rs[k] || is_ru[k])) ? 2'd2 : 2'd1))
              st[k] <= (!ni_chunk[k] && (is_rs[k] || is_ru[k] || is_cu[k])) ? H_GRANT : H_IDLE;
          end

          H_ACK: if (ack_got[k]) st[k] <= H_IDLE;

          default: st[k] <= H_IDLE;
        endcase
        mem_pend[k] <= mem_pend[k] + 3'(mem_inc[k]) - 3'(mem_dec && int'(ej_ks) == k);
      end

      rq_cnt <= rq_cnt + (QB+1)'(ej_req) - (QB+1)'(d_ok);
    end
  end

  // synopsys translate_off
  always @(posedge clk)
    if (rst_n && overflow) $error("noc_hnf: request queue overflow (QD %0d too small)", QD);

  // activity counts, printed at the end:
  //   HNF <name> slots=K txn= rni= snp= dct= dmt= wb= busy=% occ= svc= qwait=
  // busy: share of cycles with a transaction in a slot; occ: average slots in
  // use; svc: average cycles a transaction holds its slot; qwait: average
  // cycles a request waits in the queue (Little's law)
  int unsigned n_txn, n_rni, n_snp, n_dct, n_dmt, n_wb;
  longint unsigned n_cyc, n_busy, n_occ, n_qsum;
  always @(posedge clk) if (rst_n) begin
    automatic int a = 0;
    for (int k = 0; k < K; k++) if (st[k] != H_IDLE) a++;
    n_cyc++; n_qsum += rq_cnt; n_occ += a;
    if (a != 0) n_busy++;
    if (d_ok) begin
      n_txn++;
      if (hq.op != OP_CREQ) n_rni++;
    end
    if (push && st[ps] == H_SNP) begin
      n_snp++;
      if (snp_op[ps] == SNP_SHAREDFWD || snp_op[ps] == SNP_UNIQUEFWD) n_dct++;
    end
    if (push && st[ps] == H_DMT) n_dmt++;
    if (push && st[ps] == H_WB) n_wb++;
  end
  final $display("HNF %s slots=%0d txn=%0d rni=%0d snp=%0d dct=%0d dmt=%0d wb=%0d busy=%0d%% occ=%0d.%02d svc=%0d qwait=%0d",
                 ep_name(SELF), K, n_txn, n_rni, n_snp, n_dct, n_dmt / 2, n_wb / 2,
                 n_cyc ? 100 * n_busy / n_cyc : 0, n_cyc ? n_occ / n_cyc : 0,
                 n_cyc ? (100 * n_occ / n_cyc) % 100 : 0,
                 n_txn ? n_occ / n_txn : 0, n_txn ? n_qsum / n_txn : 0);
  // synopsys translate_on
endmodule
