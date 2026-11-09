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
//  * One transaction at a time, in arrival order: snoops, memory, response,
//    then CompAck where the RN-F sends one. A line is never in two
//    transactions, so there are no hazards to track.
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
//    chunks; the home waits for every response before it moves on, so its
//    accesses are ordered.
//  * Always ejects: the request queue holds QD entries (every chunk / request
//    the masters can have outstanding); responses are taken as they arrive.
//    `overflow` flags a sizing error. Responses are matched by source, not
//    by txnid (one transaction at a time).
// ============================================================================
module noc_hnf
  import noc_cfg_pkg::*;
#(
  parameter int SELF = NM + NS,
  parameter int QD   = 64,
  parameter int NL   = CHI_LINES
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
  localparam int RB = (NRN > 1) ? $clog2(NRN) : 1;

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
  pkt_t        push_p;
  wire         can_push = (oq_cnt < 3'(OQ));

  assign inj_valid = (oq_cnt != 0);
  assign inj_flit  = mk_flit(oq[oq_rp], SELF,
                             (oq[oq_rp].op == OP_RD || oq[oq_rp].op == OP_WR || oq[oq_rp].op == OP_CSNP) ? VC_REQ : VC_RSP);
  assign ej_ready  = 1'b1;

  pkt_t ej;
  assign ej = pkt_of(ej_flit);
  wire ej_req = ej_valid && (ej.op == OP_RD || ej.op == OP_WR || ej.op == OP_CREQ);

  // ---------------- transaction ----------------
  typedef enum logic [3:0] {
    H_IDLE, H_SETUP, H_SNP, H_SNPW, H_POST, H_NEXT, H_WB, H_MRD, H_MEMW, H_FWD,
    H_REPLY, H_ACK, H_DBID, H_WDATA, H_DMT, H_GRANT
  } hst_e;
  hst_e st, after_wb;                     // after_wb: state after H_MEMW

  pkt_t          cur;
  int            rqr;                     // requesting RN-F (-1: RN-I chunk)
  logic          ni_chunk;                // RN-I chunk
  logic [25:0]   ln [2];
  logic          nl2, li;                 // two lines; line in progress
  logic [NRN-1:0] snp_todo, snp_pend;
  logic [4:0]    snp_op;
  logic [1:0]    snp_half [NRN];
  logic [255:0]  lbuf [2];                // line data (snoop, memory or write data)
  logic          dirty;                   // lbuf holds dirty data passed to the home
  logic [2:0]    wd_resp;                 // CopyBackWrData / NonCopyBackWrData Resp
  logic [31:0]   wd_be;
  logic [1:0]    wd_n;                    // write-data flits received
  logic [2:0]    mem_pend;                // own memory chunks outstanding
  logic [1:0]    mem_sent;
  pkt_t          fwd_rsp;                 // response to a forwarded chunk / NoSnp access
  logic          ack_got;
  logic [1:0]    rep_n;                   // reply flits sent
  logic          lost;                    // CleanUnique: requester no longer holds the line
  logic          nderr;                   // NoSnp: no slave at the address
  logic          fwded;                   // DCT: the owner sent the requester its CompData

  wire [5:0] opc = cur.copc;
  wire is_rs  = !ni_chunk && opc == REQ_READSHARED;
  wire is_ru  = !ni_chunk && opc == REQ_READUNIQUE;
  wire is_cu  = !ni_chunk && opc == REQ_CLEANUNIQUE;
  wire is_ev  = !ni_chunk && opc == REQ_EVICT;
  wire is_wb  = !ni_chunk && opc == REQ_WRITEBACKFULL;
  wire is_rns = !ni_chunk && opc == REQ_READNOSNP;
  wire is_wns = !ni_chunk && opc == REQ_WRITENOSNPPTL;

  wire [25:0]    L  = ln[li];
  wire [IB-1:0]  LS = set_of(L);
  wire [TW-1:0]  LT = tag_of(L);

  // does RN-F r hold line L (per the filter)?
  function automatic logic holds(int r, logic [25:0] l);
    return sf_v[r][set_of(l)] && sf_t[r][set_of(l)] == tag_of(l);
  endfunction

  // ReadShared / ReadUnique: the requester's state (ReadShared: SC if another
  // cache keeps the line after the snoops, else UC)
  logic [2:0] gr_cresp;
  always_comb begin
    gr_cresp = is_ru ? (dirty ? RESP_UD_PD : RESP_UC) : RESP_UC;
    if (is_rs)
      for (int r = 0; r < NRN; r++)
        if (r != rqr && holds(r, L)) gr_cresp = RESP_SC;
  end

  // the packet sent in the current state (combinational), see H_* below
  pkt_t np;
  always_comb begin
    np = '0;
    np.src_ep = EPB'(SELF);
    np.tag    = cur.tag;
    unique case (st)
      H_SNP: begin
        for (int r = NRN - 1; r >= 0; r--)
          if (snp_todo[r]) np.dst_ep = EPB'(RN_EP[r]);
        np.op   = OP_CSNP;
        np.copc = {1'b0, snp_op};
        np.addr = {L, 6'd0};
        np.fwd  = cur.src_ep;               // DCT: FwdNID, FwdTxnID
        np.dbid = cur.tag;
      end
      H_WB, H_MRD: begin                    // a 32-byte half of line L
        np.op     = (st == H_WB) ? OP_WR : OP_RD;
        np.dst_ep = decode_tgt({L, 6'd0});
        np.tag    = TAGW'(mem_sent[0]);
        np.addr   = {L, mem_sent[0], 5'd0};
        np.nm1    = 3'd7;
        np.size   = 3'd2;
        np.strb   = '1;
        np.data   = lbuf[mem_sent[0]];
      end
      H_DMT: begin                          // DMT: memory sends the requester its CompData
        np.op     = OP_RD;
        np.dst_ep = decode_tgt({L, 6'd0});
        np.src_ep = cur.src_ep;
        np.addr   = {L, mem_sent[0], 5'd0};
        np.nm1    = 3'd7;
        np.size   = 3'd2;
        np.copc   = {2'b0, DAT_COMPDATA};
        np.cresp  = gr_cresp;
        np.dataid = {mem_sent[0], 1'b0};
        np.hnid   = EPB'(SELF);
      end
      H_FWD: begin
        if (ni_chunk) np = cur;             // the chunk as the master NI sent it
        else begin                          // NoSnp: one beat
          np.op   = is_rns ? OP_RD : OP_WR;
          np.addr = cur.addr;
          np.size = cur.size;
          np.data[0] = lbuf[cur.addr[5]][32*cur.addr[4:2] +: 32];
          np.strb[0] = wd_be[4*cur.addr[4:2] +: 4];
        end
        np.dst_ep = decode_tgt(cur.addr);
        np.src_ep = EPB'(SELF);
        np.tag    = TAGW'(2);
      end
      H_DBID: begin
        np.op = OP_CRSP; np.dst_ep = cur.src_ep;
        np.copc = {2'b0, is_wb ? RSP_COMPDBIDRESP : RSP_DBIDRESP};
        np.dbid = cur.tag;
      end
      H_REPLY: begin
        np.dst_ep = cur.src_ep;
        if (ni_chunk) begin                 // back to the master NI
          np.op    = fwd_rsp.op;
          np.resp  = fwd_rsp.resp;
          np.rresp = fwd_rsp.rresp;
          np.data  = fwd_rsp.data;
        end else if (is_rs || is_ru) begin
          np.op     = OP_CDAT;
          np.copc   = {2'b0, DAT_COMPDATA};
          np.dataid = {rep_n[0], 1'b0};
          np.data   = lbuf[rep_n[0]];
          np.cresp  = gr_cresp;
          np.hnid   = EPB'(SELF);
        end else if (is_rns) begin
          np.op     = OP_CDAT;
          np.copc   = {2'b0, DAT_COMPDATA};
          np.dataid = {cur.addr[5], 1'b0};
          np.cresp  = RESP_UC;
          np.hnid   = EPB'(SELF);
          np.resp   = nderr ? RESPERR_NDERR : fwd_rsp.rresp[0] == 2'b11 ? RESPERR_NDERR :
                      fwd_rsp.rresp[0] == 2'b10 ? RESPERR_DERR : RESPERR_OK;
          if (!nderr) np.data[cur.addr[4:2]] = fwd_rsp.data[0];
        end else begin                      // Comp: CleanUnique, Evict, WriteNoSnpPtl
          np.op    = OP_CRSP;
          np.copc  = {2'b0, RSP_COMP};
          np.cresp = (is_cu && !lost) ? RESP_UC : RESP_I;
          if (is_wns)
            np.resp = nderr ? RESPERR_NDERR : fwd_rsp.resp == 2'b11 ? RESPERR_NDERR :
                      fwd_rsp.resp == 2'b10 ? RESPERR_DERR : RESPERR_OK;
        end
      end
      default: ;
    endcase
  end

  wire [1:0] n_reply = (!ni_chunk && (is_rs || is_ru)) ? 2'd2 : 2'd1;

  wire mem_dec = ej_valid && (ej.op == OP_RDATA || ej.op == OP_WRSP);
  wire mem_inc = push && (st == H_WB || st == H_MRD || st == H_FWD);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < NRN; r++)
        for (int i = 0; i < NL; i++) begin sf_v[r][i] <= 1'b0; sf_u[r][i] <= 1'b0; sf_t[r][i] <= '0; end
      rq_cnt <= '0; rq_wp <= '0; rq_rp <= '0;
      oq_cnt <= '0; oq_wp <= '0; oq_rp <= '0;
      overflow <= 1'b0;
      st <= H_IDLE; after_wb <= H_IDLE;
      cur <= '0; rqr <= -1; ni_chunk <= 1'b0; ln[0] <= '0; ln[1] <= '0; nl2 <= 1'b0; li <= 1'b0;
      snp_todo <= '0; snp_pend <= '0; snp_op <= '0;
      for (int r = 0; r < NRN; r++) snp_half[r] <= '0;
      lbuf[0] <= '0; lbuf[1] <= '0; dirty <= 1'b0;
      wd_resp <= '0; wd_be <= '0; wd_n <= '0;
      mem_pend <= '0; mem_sent <= '0; fwd_rsp <= '0; ack_got <= 1'b0; rep_n <= '0;
      lost <= 1'b0; nderr <= 1'b0; fwded <= 1'b0;
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
          OP_RDATA, OP_WRSP: begin           // memory / forwarded access
            if (ej.tag == TAGW'(2)) fwd_rsp <= ej;
            else if (ej.op == OP_RDATA) lbuf[ej.tag[0]] <= ej.data;
          end
          OP_CRSP: begin
            if (ej.copc[3:0] == RSP_COMPACK) ack_got <= 1'b1;
            else if ((ej.copc[3:0] == RSP_SNPRESP || ej.copc[3:0] == RSP_SNPRESPFWDED) && r >= 0) begin
              if (ej.copc[3:0] == RSP_SNPRESPFWDED) fwded <= 1'b1;
              if (holds(r, L)) begin
                sf_v[r][LS] <= (ej.cresp[1:0] != 2'd0);
                sf_u[r][LS] <= (ej.cresp[1:0] == 2'd2);
              end
              snp_pend[r] <= 1'b0;
            end
          end
          OP_CDAT: begin
            lbuf[ej.dataid[1]] <= ej.data;
            if ((ej.copc[3:0] == DAT_SNPRESPDATA || ej.copc[3:0] == DAT_SNPRESPDATAFWDED) && r >= 0) begin
              if (ej.copc[3:0] == DAT_SNPRESPDATAFWDED) fwded <= 1'b1;
              if (ej.cresp[2]) dirty <= 1'b1;
              snp_half[r] <= snp_half[r] + 2'd1;
              if (snp_half[r] == 2'd1) begin
                if (holds(r, L)) begin
                  sf_v[r][LS] <= (ej.cresp[1:0] != 2'd0);
                  sf_u[r][LS] <= (ej.cresp[1:0] == 2'd2);
                end
                snp_pend[r] <= 1'b0;
              end
            end else begin                  // CopyBackWrData / NonCopyBackWrData
              wd_resp <= ej.cresp;
              wd_be   <= ej.strb;
              wd_n    <= wd_n + 2'd1;
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
      end
      oq_cnt <= oq_cnt + 3'(push) - 3'(inj_valid && inj_ready);

      // ---------------- transaction ----------------
      unique case (st)
        H_IDLE: if (rq_cnt != 0) begin
          automatic pkt_t q = rq[rq_rp];
          automatic logic [31:0] last = q.fixed ? q.addr : q.addr + (32'(q.nm1) << q.size);
          rq_rp <= (int'(rq_rp) == QD - 1) ? '0 : rq_rp + 1'b1;
          cur <= q;
          ni_chunk <= (q.op != OP_CREQ);
          rqr <= rn_of(int'(q.src_ep));
          ln[0] <= q.addr[31:6];
          ln[1] <= last[31:6];
          nl2 <= (q.op != OP_CREQ) && (last[31:6] != q.addr[31:6]);
          li <= 1'b0;
          dirty <= 1'b0; ack_got <= 1'b0; rep_n <= '0; wd_n <= '0; mem_sent <= '0;
          lost <= 1'b0; fwded <= 1'b0;
          nderr <= (q.op == OP_CREQ) && decode_tgt(q.addr) == EP_NONE;
          st <= H_SETUP;
        end

        H_SETUP: begin                      // snoops for line ln[li]
          automatic logic [NRN-1:0] msk = '0;
          automatic logic [4:0] so = SNP_UNIQUE;
          for (int r = 0; r < NRN; r++) begin
            if (!holds(r, L) || r == rqr) continue;
            if (ni_chunk) begin
              if (cur.op == OP_RD) begin so = SNP_CLEANSHARED; msk[r] = sf_u[r][LS]; end
              else msk[r] = 1'b1;
            end else if (is_rs) begin so = SNP_SHARED; msk[r] = sf_u[r][LS]; end
            else if (is_ru) msk[r] = 1'b1;
            else if (is_cu) msk[r] = holds(rqr, L);
          end
          // DCT: ReadShared / ReadUnique with a unique owner: it forwards the line
          if (CHI_DCT && (is_rs || is_ru))
            for (int r = 0; r < NRN; r++)
              if (r != rqr && holds(r, L) && sf_u[r][LS]) begin
                so = is_rs ? SNP_SHAREDFWD : SNP_UNIQUEFWD;
                msk = '0;
                msk[r] = 1'b1;
              end
          if (is_cu && !holds(rqr, L)) lost <= 1'b1;
          snp_op <= so;
          snp_todo <= msk;
          snp_pend <= msk;
          for (int r = 0; r < NRN; r++) snp_half[r] <= '0;
          if (is_wb || is_wns) st <= H_DBID;
          else if (is_rns) st <= nderr ? H_REPLY : H_FWD;
          else if (is_ev) begin
            if (holds(rqr, L)) sf_v[rqr][LS] <= 1'b0;
            st <= H_REPLY;
          end else st <= (msk != 0) ? H_SNP : H_POST;
        end

        H_SNP: if (can_push) begin
          automatic logic [NRN-1:0] t = snp_todo;
          for (int r = 0; r < NRN; r++) if (t[r]) begin t[r] = 1'b0; break; end
          snp_todo <= t;
          if (t == 0) st <= H_SNPW;
        end

        H_SNPW: if (snp_pend == 0) st <= H_POST;

        H_POST: begin                       // snoops done for line ln[li]
          if (ni_chunk) begin
            automatic hst_e nx = (nl2 && !li) ? H_NEXT : H_FWD;
            if (dirty) begin after_wb <= nx; st <= H_WB; end
            else st <= nx;
          end else if (fwded) begin         // DCT: the owner sent the CompData
            after_wb <= H_GRANT;
            st <= dirty ? H_WB : H_GRANT;   // SnpSharedFwd of a dirty line: to memory
          end else if (is_rs) begin
            after_wb <= H_REPLY;
            st <= dirty ? H_WB : CHI_DMT ? H_DMT : H_MRD;   // dirty: to memory, and the data from lbuf
          end else if (is_ru) begin
            after_wb <= H_REPLY;
            st <= dirty ? H_REPLY : CHI_DMT ? H_DMT : H_MRD; // dirty: passed on as UD_PD
          end else st <= H_REPLY;           // CleanUnique
        end

        H_NEXT: begin                       // RN-I chunk: its second line
          dirty <= 1'b0;
          li <= 1'b1;
          st <= H_SETUP;
        end

        H_WB, H_MRD: if (can_push) begin    // two halves of line L
          mem_sent <= mem_sent + 2'd1;
          if (mem_sent == 2'd1) st <= H_MEMW;
        end

        H_DMT: if (can_push) begin          // two halves, then the requester's CompAck
          mem_sent <= mem_sent + 2'd1;
          if (mem_sent == 2'd1) begin
            mem_sent <= '0;
            st <= H_GRANT;
          end
        end

        H_GRANT: begin                      // the requester's line in the filter
          if (!(is_cu && lost)) begin
            sf_v[rqr][LS] <= 1'b1;
            sf_t[rqr][LS] <= LT;
            sf_u[rqr][LS] <= is_ru || is_cu || gr_cresp == RESP_UC;
          end
          st <= H_ACK;
        end

        H_MEMW: if (mem_pend == 0) begin
          mem_sent <= '0;
          st <= after_wb;
        end

        H_FWD: if (can_push) begin
          after_wb <= H_REPLY;
          st <= H_MEMW;
        end

        H_DBID: if (can_push) st <= H_WDATA;

        H_WDATA: if (wd_n == (is_wb ? 2'd2 : 2'd1)) begin
          if (is_wb) begin
            if (holds(rqr, L)) sf_v[rqr][LS] <= 1'b0;
            if (holds(rqr, L) && sf_u[rqr][LS] && wd_resp == RESP_UD_PD) begin
              after_wb <= H_IDLE;
              st <= H_WB;
            end else st <= H_IDLE;
          end else st <= nderr ? H_REPLY : H_FWD;
        end

        H_REPLY: if (can_push) begin
          rep_n <= rep_n + 2'd1;
          if (rep_n + 2'd1 == n_reply) begin
            st <= (!ni_chunk && (is_rs || is_ru || is_cu)) ? H_GRANT : H_IDLE;
          end
        end

        H_ACK: if (ack_got) st <= H_IDLE;

        default: st <= H_IDLE;
      endcase

      rq_cnt   <= rq_cnt + (QB+1)'(ej_req) - (QB+1)'(st == H_IDLE && rq_cnt != 0);
      mem_pend <= mem_pend + 3'(mem_inc) - 3'(mem_dec);
    end
  end

  always_comb
    push = can_push && (st == H_SNP || st == H_WB || st == H_MRD || st == H_FWD ||
                        st == H_DBID || st == H_REPLY || st == H_DMT);

  // synopsys translate_off
  always @(posedge clk)
    if (rst_n && overflow) $error("noc_hnf: request queue overflow (QD %0d too small)", QD);

  // activity counts, printed at the end: HNF <name> txn=.. rni=.. snp=.. dct=.. dmt=.. wb=..
  int unsigned n_txn, n_rni, n_snp, n_dct, n_dmt, n_wb;
  always @(posedge clk) if (rst_n) begin
    if (st == H_IDLE && rq_cnt != 0) begin
      n_txn++;
      if (rq[rq_rp].op != OP_CREQ) n_rni++;
    end
    if (push && st == H_SNP) begin
      n_snp++;
      if (snp_op == SNP_SHAREDFWD || snp_op == SNP_UNIQUEFWD) n_dct++;
    end
    if (push && st == H_DMT) n_dmt++;
    if (push && st == H_WB) n_wb++;
  end
  final $display("HNF %s txn=%0d rni=%0d snp=%0d dct=%0d dmt=%0d wb=%0d", ep_name(SELF),
                 n_txn, n_rni, n_snp, n_dct, n_dmt / 2, n_wb / 2);
  // synopsys translate_on
endmodule
