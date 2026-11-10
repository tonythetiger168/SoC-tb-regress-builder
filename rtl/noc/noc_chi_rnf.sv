// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_chi_rnf -- CHI RN-F with a small cache: AXI4 slave port (32-bit, from a
// CPU model or the bench's AXI4 VIP) -> write-back cache -> CHI port
// (noc_cfg_pkg chi_*_t channels, to noc_ni_chi)
// ----------------------------------------------------------------------------
//  * Cache: NL 64-byte lines, direct-mapped, MESI as CHI states I / SC / UC /
//    UD. Addresses in coherent memory (noc_cfg_pkg::cacheable) are cached;
//    everything else goes as ReadNoSnp / WriteNoSnpPtl: an INCR burst of
//    32-bit beats as one request per 32-byte half line it touches (nm1 + 1
//    words: only the beats asked for, so no peripheral register is read or
//    written that the burst does not address), any other burst one per beat.
//  * One AXI burst at a time (reads and writes alternate), beat by beat:
//      read hit            data from the line
//      write hit, UC / UD  bytes written, line UD
//      write hit, SC       CleanUnique; Comp UC -> UC, Comp I (the line was
//                          lost to a snoop first) -> miss
//      miss                victim out first (UD: WriteBackFull + two
//                          CopyBackWrData; SC / UC: Evict), then ReadShared
//                          (read) or ReadUnique (write), two CompData, CompAck
//    so at most one request is outstanding.
//  * DCT: SnpSharedFwd / SnpUniqueFwd on a line it holds: CompData straight
//    to the requester (FwdNID / FwdTxnID, HomeNID = the home), SnpRespFwded
//    to the home (SnpRespDataFwded with the dirty line on SnpSharedFwd).
//  * CompAck goes to the HomeNID of the CompData (DMT: the slave sends it on
//    the home's behalf; DCT: the owner) or to the source of the Comp.
//  * Snoops (SnpShared, SnpCleanShared, SnpUnique) are answered between beats
//    and while a request is outstanding: SnpResp with the new state, or
//    SnpRespData (_PD) with the line when it is dirty.
//  * RespErr maps to RRESP / BRESP: OK -> OKAY, DERR -> SLVERR, NDERR -> DECERR.
// ============================================================================
module noc_chi_rnf
  import noc_cfg_pkg::*;
#(
  parameter int IDW = 4,
  parameter int NL  = CHI_LINES
)(
  input  logic           clk,
  input  logic           rst_n,
  // ---------------- AXI4 slave port ----------------
  input  logic [IDW-1:0] s_awid,
  input  logic [31:0]    s_awaddr,
  input  logic [7:0]     s_awlen,
  input  logic [2:0]     s_awsize,
  input  logic [1:0]     s_awburst,
  input  logic [2:0]     s_awprot,
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
  input  logic [2:0]     s_arprot,
  input  logic           s_arvalid,
  output logic           s_arready,
  output logic [IDW-1:0] s_rid,
  output logic [31:0]    s_rdata,
  output logic [1:0]     s_rresp,
  output logic           s_rlast,
  output logic           s_rvalid,
  input  logic           s_rready,
  // ---------------- CHI port ----------------
  output logic           txreq_valid,
  input  logic           txreq_ready,
  output chi_req_t       txreq_flit,
  output logic           txrsp_valid,
  input  logic           txrsp_ready,
  output chi_rsp_t       txrsp_flit,
  output logic           txdat_valid,
  input  logic           txdat_ready,
  output chi_dat_t       txdat_flit,
  input  logic           rxrsp_valid,
  input  chi_rsp_t       rxrsp_flit,
  input  logic           rxdat_valid,
  input  chi_dat_t       rxdat_flit,
  input  logic           rxsnp_valid,
  input  chi_snp_t       rxsnp_flit
);
  localparam int IB = $clog2(NL);
  localparam int TW = 26 - IB;
  typedef enum logic [1:0] { CS_I = 2'd0, CS_SC = 2'd1, CS_UC = 2'd2, CS_UD = 2'd3 } cst_e;

  // ---------------- cache ----------------
  cst_e          cs   [NL];
  logic [TW-1:0] ctag [NL];
  logic [511:0]  cdat [NL];

  // ---------------- TX queues (one writer per cycle: snoop or main) ----------------
  chi_req_t qreq [2];  logic [1:0] nreq; logic wreq, rreq;
  chi_rsp_t qrsp [4];  logic [2:0] nrsp; logic [1:0] wrsp, rrsp;
  chi_dat_t qdat [4];  logic [2:0] ndat; logic [1:0] wdat, rdat;
  logic     push_req, push_rsp, push_dat;
  chi_req_t p_req;
  chi_rsp_t p_rsp;
  chi_dat_t p_dat;

  assign txreq_valid = nreq != 0;  assign txreq_flit = qreq[rreq];
  assign txrsp_valid = nrsp != 0;  assign txrsp_flit = qrsp[rrsp];
  assign txdat_valid = ndat != 0;  assign txdat_flit = qdat[rdat];
  wire room_req = nreq < 2'd2, room_rsp = nrsp < 3'd4, room_dat2 = ndat < 3'd3, room_dat1 = ndat < 3'd4;

  // ---------------- responses to our request (latched) ----------------
  logic         rsp_got;
  chi_rsp_t     rsp_q;
  logic [1:0]   dat_n;
  logic [255:0] dat_q [2];
  logic [2:0]   dat_resp;
  logic [1:0]   dat_err;

  // ---------------- snoops ----------------
  // a home sends at most one snoop per transaction slot: room for all of them
  localparam int SQB = $clog2(NHN * HN_SLOTS) > 0 ? $clog2(NHN * HN_SLOTS) : 1;
  chi_snp_t   snq [2 ** SQB];
  logic [SQB:0]   nsnq;
  logic [SQB-1:0] wsnq, rsnq;
  // after the pop: CompData to the requester (DCT, F0 / F1), then data to the home (H0 / H1)
  typedef enum logic [2:0] { S_IDLE, S_F0, S_F1, S_H0, S_H1 } sst_e;
  sst_e       sst;
  logic [IB-1:0]   s_idx;
  logic [EPB-1:0]  s_home, s_fwdnid;
  logic [TAGW-1:0] s_txn, s_fwdtxn;
  logic [2:0]      s_hresp, s_fresp;
  logic [3:0]      s_hopc;
  logic            s_hdat;
  logic [EPB-1:0]  ack_nid;                 // where CompAck goes (HomeNID / the Comp's source)
  wire  snp_busy = (nsnq != 0) || (sst != S_IDLE);

  // ---------------- AXI burst ----------------
  typedef enum logic [3:0] { M_IDLE, M_BEAT, M_WAIT, M_ACK, M_WBD0, M_WBD1, M_ROUT, M_B, M_NSR } mst_e;
  typedef enum logic [3:0] { W_FILL, W_CU, W_EV, W_WB, W_NSRD, W_NSDBID, W_NSGATH, W_NSDATA, W_NSCOMP } wk_e;
  mst_e st;
  wk_e  wk;
  logic           b_wr, last_rd;
  logic [IDW-1:0] b_id;
  logic [31:0]    b_addr;
  logic [7:0]     b_len, b_i;
  logic [2:0]     b_size;
  logic [1:0]     b_burst;
  logic [1:0]     b_worst;
  logic [31:0]    r_data;
  logic [1:0]     r_resp;
  logic [TAGW-1:0] txn;
  logic [IB-1:0]  wb_idx;
  // NoSnp of several words: words in the request, words gathered / served,
  // its half line, the write data, and whether it ends the burst
  logic [3:0]     ns_n, ns_k;
  logic           ns_half, ns_rd, ns_last;
  logic [255:0]   ns_wd;
  logic [31:0]    ns_be;
  logic [2:0]     wb_resp;
  logic [25:0]    wb_line;

  function automatic logic [31:0] beat_addr(int unsigned i);
    logic [31:0] nb = 32'd1 << b_size;
    logic [31:0] tot = nb * (32'(b_len) + 1);
    case (b_burst)
      2'b00: return b_addr;
      2'b10: return (b_addr & ~(tot - 1)) | ((b_addr + i * nb) & (tot - 1));
      default: return (i == 0) ? b_addr : (b_addr & ~(nb - 1)) + i * nb;
    endcase
  endfunction

  wire [31:0]   a    = beat_addr(b_i);
  wire [IB-1:0] idx  = a[6 +: IB];
  wire [TW-1:0] tg   = a[31:6+IB];
  wire          hit  = cs[idx] != CS_I && ctag[idx] == tg;
  wire          cach = cacheable(a);
  wire          lastb = (b_i == b_len);
  // NoSnp: words this request carries (the rest of an INCR 32-bit burst in
  // this half line; one for any other burst)
  wire [8:0]    b_rem  = {1'b0, b_len} - {1'b0, b_i} + 9'd1;
  wire [3:0]    w_room = 4'd8 - {1'b0, a[4:2]};
  wire [3:0]    ns_nc  = (b_burst != 2'b01 || b_size != 3'd2) ? 4'd1 :
                         (b_rem < 9'(w_room)) ? 4'(b_rem) : w_room;

  // main FSM may act this cycle (no snoop in progress)
  wire go = !snp_busy;

  // ---------------- AXI handshakes ----------------
  wire pick_rd = s_arvalid && (!s_awvalid || !last_rd);
  assign s_arready = (st == M_IDLE) && pick_rd;
  assign s_awready = (st == M_IDLE) && !pick_rd && s_awvalid;
  logic w_take;
  assign s_wready = w_take;
  assign s_rvalid = (st == M_ROUT);
  assign s_rid    = b_id;
  assign s_rdata  = r_data;
  assign s_rresp  = r_resp;
  assign s_rlast  = lastb;
  assign s_bvalid = (st == M_B);
  assign s_bid    = b_id;
  assign s_bresp  = b_worst;

  // ---------------- main FSM: what it pushes / takes this cycle ----------------
  always_comb begin
    push_req = 1'b0; p_req = '0;
    w_take = 1'b0;
    p_req.txnid = txn;
    if (go) unique case (st)
      M_BEAT: if (!b_wr || s_wvalid) begin
        if (!cach) begin
          push_req     = room_req;
          p_req.opcode = b_wr ? REQ_WRITENOSNPPTL : REQ_READNOSNP;
          p_req.addr   = a;
          p_req.size   = b_size;
          p_req.nm1    = 3'(ns_nc - 4'd1);
        end else if (hit && b_wr && (cs[idx] == CS_UC || cs[idx] == CS_UD)) w_take = 1'b1;
        else if (hit && b_wr) begin
          push_req     = room_req;
          p_req.opcode = REQ_CLEANUNIQUE;
          p_req.addr   = {a[31:6], 6'd0};
        end else if (!hit) begin
          push_req     = room_req;
          p_req.size   = 3'd6;
          if (cs[idx] != CS_I) begin       // victim out first
            p_req.opcode = (cs[idx] == CS_UD) ? REQ_WRITEBACKFULL : REQ_EVICT;
            p_req.addr   = {ctag[idx], idx, 6'd0};
          end else begin
            p_req.opcode = b_wr ? REQ_READUNIQUE : REQ_READSHARED;
            p_req.addr   = {a[31:6], 6'd0};
          end
        end
      end
      M_WAIT: if (wk == W_NSGATH && s_wvalid) w_take = 1'b1;
      default: ;
    endcase
  end

  // the snoop at the head of the queue
  chi_snp_t      sn;
  logic [IB-1:0] si;
  logic          sh, sud, sfwd, snp_pop;
  logic          p_hdat, p_fdat, p_rsp1;    // its plan: data to the home, CompData forwarded, a RSP
  assign sn   = snq[rsnq];
  assign si   = sn.addr[6 +: IB];
  assign sh   = cs[si] != CS_I && ctag[si] == sn.addr[31:6+IB];
  assign sud  = sh && cs[si] == CS_UD;
  assign sfwd = sn.opcode == SNP_SHAREDFWD || sn.opcode == SNP_UNIQUEFWD;
  // forwarded snoop on a line we hold: CompData to the requester; the home
  // gets the dirty data only on SnpSharedFwd (the requester gets it clean, SC)
  assign p_fdat = sfwd && sh;
  assign p_hdat = sfwd ? (sud && sn.opcode == SNP_SHAREDFWD) : sud;
  assign p_rsp1 = !p_hdat;
  // taken this cycle: its RSP (if any) is pushed and the data sequence starts
  assign snp_pop = sst == S_IDLE && nsnq != 0 && room_rsp;

  // snoop FSM / main FSM pushes on RSP and DAT (never both in one cycle)
  always_comb begin
    push_rsp = 1'b0; p_rsp = '0;
    push_dat = 1'b0; p_dat = '0;
    if (sst == S_IDLE && nsnq != 0) begin
      if (snp_pop && p_rsp1) begin
        push_rsp = 1'b1;
        p_rsp.nid    = sn.nid;
        p_rsp.txnid  = sn.txnid;
        p_rsp.opcode = p_fdat ? RSP_SNPRESPFWDED : RSP_SNPRESP;
        p_rsp.resp   = !sh ? RESP_I :
                       (sn.opcode == SNP_UNIQUE || sn.opcode == SNP_UNIQUEFWD) ? RESP_I :
                       (sn.opcode == SNP_SHARED || sn.opcode == SNP_SHAREDFWD) ? RESP_SC :
                       (cs[si] == CS_UC) ? RESP_UC : RESP_SC;
      end
    end else if (sst != S_IDLE) begin
      automatic logic f = (sst == S_F0 || sst == S_F1);
      automatic logic h1 = (sst == S_F1 || sst == S_H1);
      push_dat = room_dat1;
      p_dat.nid     = f ? s_fwdnid : s_home;
      p_dat.homenid = s_home;
      p_dat.txnid   = f ? s_fwdtxn : s_txn;
      p_dat.opcode  = f ? DAT_COMPDATA : s_hopc;
      p_dat.resp    = f ? s_fresp : s_hresp;
      p_dat.dataid  = {h1, 1'b0};
      p_dat.be      = '1;
      p_dat.data    = cdat[s_idx][256*h1 +: 256];
    end else if (go) begin
      if (st == M_ACK && room_rsp) begin
        push_rsp = 1'b1;
        p_rsp.nid    = ack_nid;
        p_rsp.txnid  = txn - 1'b1;          // the request's TxnID (txn moved on at its push)
        p_rsp.opcode = RSP_COMPACK;
      end
      if (st == M_WAIT && wk == W_NSDATA && room_dat2) begin
        push_dat = 1'b1;
        p_dat.nid    = rsp_q.nid;
        p_dat.txnid  = rsp_q.dbid;
        p_dat.opcode = DAT_NONCOPYBACKWRDATA;
        p_dat.dataid = {ns_half, 1'b0};
        p_dat.be     = ns_be;
        p_dat.data   = ns_wd;
      end
      if ((st == M_WBD0 || st == M_WBD1) && room_dat2) begin
        push_dat = 1'b1;
        p_dat.nid    = rsp_q.nid;
        p_dat.txnid  = rsp_q.dbid;
        p_dat.opcode = DAT_COPYBACKWRDATA;
        p_dat.resp   = wb_resp;
        p_dat.dataid = {st == M_WBD1, 1'b0};
        p_dat.be     = '1;
        p_dat.data   = cdat[wb_idx][256*(st == M_WBD1) +: 256];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NL; i++) begin cs[i] <= CS_I; ctag[i] <= '0; cdat[i] <= '0; end
      nreq <= '0; wreq <= '0; rreq <= '0;
      nrsp <= '0; wrsp <= '0; rrsp <= '0;
      ndat <= '0; wdat <= '0; rdat <= '0;
      rsp_got <= 1'b0; rsp_q <= '0; dat_n <= '0; dat_q[0] <= '0; dat_q[1] <= '0;
      dat_resp <= '0; dat_err <= '0;
      nsnq <= '0; wsnq <= '0; rsnq <= '0; sst <= S_IDLE; s_idx <= '0; s_txn <= '0; s_fwdtxn <= '0;
      s_home <= '0; s_fwdnid <= '0; s_hresp <= '0; s_fresp <= '0; s_hopc <= '0; s_hdat <= 1'b0;
      ack_nid <= '0;
      st <= M_IDLE; wk <= W_FILL; b_wr <= 1'b0; last_rd <= 1'b0; b_id <= '0; b_addr <= '0;
      b_len <= '0; b_i <= '0; b_size <= '0; b_burst <= '0; b_worst <= '0;
      r_data <= '0; r_resp <= '0; txn <= '0; wb_idx <= '0; wb_resp <= '0; wb_line <= '0;
      ns_n <= '0; ns_k <= '0; ns_half <= 1'b0; ns_rd <= 1'b0; ns_last <= 1'b0; ns_wd <= '0; ns_be <= '0;
    end else begin
      // ---------------- TX queues ----------------
      if (push_req) begin qreq[wreq] <= p_req; wreq <= ~wreq; end
      if (txreq_valid && txreq_ready) rreq <= ~rreq;
      nreq <= nreq + 2'(push_req) - 2'(txreq_valid && txreq_ready);
      if (push_rsp) begin qrsp[wrsp] <= p_rsp; wrsp <= wrsp + 2'd1; end
      if (txrsp_valid && txrsp_ready) rrsp <= rrsp + 2'd1;
      nrsp <= nrsp + 3'(push_rsp) - 3'(txrsp_valid && txrsp_ready);
      if (push_dat) begin qdat[wdat] <= p_dat; wdat <= wdat + 2'd1; end
      if (txdat_valid && txdat_ready) rdat <= rdat + 2'd1;
      ndat <= ndat + 3'(push_dat) - 3'(txdat_valid && txdat_ready);

      // ---------------- RX ----------------
      if (rxrsp_valid) begin rsp_got <= 1'b1; rsp_q <= rxrsp_flit; ack_nid <= rxrsp_flit.nid; end
      if (rxdat_valid) begin
        ack_nid  <= rxdat_flit.homenid;
        dat_q[rxdat_flit.dataid[1]] <= rxdat_flit.data;
        dat_resp <= rxdat_flit.resp;
        dat_err  <= rxdat_flit.resperr;
        dat_n    <= dat_n + 2'd1;
      end
      if (rxsnp_valid) begin snq[wsnq] <= rxsnp_flit; wsnq <= wsnq + 1'b1; end

      // ---------------- snoop FSM ----------------
      unique case (sst)
        S_IDLE: if (snp_pop) begin
          rsnq <= rsnq + 1'b1;
          s_idx <= si; s_home <= sn.nid; s_txn <= sn.txnid;
          s_fwdnid <= sn.fwdnid; s_fwdtxn <= sn.fwdtxnid;
          s_hdat <= p_hdat;
          s_hopc <= sfwd ? DAT_SNPRESPDATAFWDED : DAT_SNPRESPDATA;
          if (sh) unique case (sn.opcode)
            SNP_SHARED: begin
              cs[si] <= CS_SC; s_hresp <= RESP_SC_PD;
            end
            SNP_CLEANSHARED: begin
              if (sud) cs[si] <= CS_UC;
              s_hresp <= RESP_UC_PD;
            end
            SNP_SHAREDFWD: begin            // requester SC; dirty data to the home
              cs[si] <= CS_SC; s_fresp <= RESP_SC; s_hresp <= RESP_SC_PD;
            end
            SNP_UNIQUEFWD: begin            // requester takes the line, dirty or not
              cs[si] <= CS_I; s_fresp <= sud ? RESP_UD_PD : RESP_UC;
            end
            default: begin                  // SnpUnique
              cs[si] <= CS_I; s_hresp <= RESP_I_PD;
            end
          endcase
          sst <= p_fdat ? S_F0 : p_hdat ? S_H0 : S_IDLE;
        end
        S_F0: if (push_dat) sst <= S_F1;
        S_F1: if (push_dat) sst <= s_hdat ? S_H0 : S_IDLE;
        S_H0: if (push_dat) sst <= S_H1;
        S_H1: if (push_dat) sst <= S_IDLE;
        default: sst <= S_IDLE;
      endcase
      nsnq <= nsnq + (SQB+1)'(rxsnp_valid) - (SQB+1)'(snp_pop);

      // ---------------- main FSM ----------------
      unique case (st)
        M_IDLE: begin
          if (s_arvalid && s_arready) begin
            b_wr <= 1'b0; b_id <= s_arid; b_addr <= s_araddr; b_len <= s_arlen;
            b_size <= s_arsize; b_burst <= s_arburst; last_rd <= 1'b1;
          end else if (s_awvalid && s_awready) begin
            b_wr <= 1'b1; b_id <= s_awid; b_addr <= s_awaddr; b_len <= s_awlen;
            b_size <= s_awsize; b_burst <= s_awburst; last_rd <= 1'b0;
          end
          if ((s_arvalid && s_arready) || (s_awvalid && s_awready)) begin
            b_i <= '0; b_worst <= 2'b00;
            st <= M_BEAT;
          end
        end

        M_BEAT: if (go && (!b_wr || s_wvalid)) begin
          if (push_req) begin
            txn <= txn + 1'b1;
            rsp_got <= 1'b0; dat_n <= '0;
            if (!cach) begin
              wk <= b_wr ? W_NSDBID : W_NSRD;
              ns_n <= ns_nc; ns_k <= '0; ns_half <= a[5]; ns_be <= '0; ns_last <= 1'b0;
            end
            else if (hit) wk <= W_CU;
            else if (cs[idx] != CS_I) begin
              wk <= (cs[idx] == CS_UD) ? W_WB : W_EV;
              wb_idx <= idx;
            end else wk <= W_FILL;
            st <= M_WAIT;
          end else if (w_take) begin        // write hit, unique
            for (int l = 0; l < 4; l++)
              if (s_wstrb[l]) cdat[idx][32*a[5:2] + 8*l +: 8] <= s_wdata[8*l +: 8];
            cs[idx] <= CS_UD;
            b_i <= b_i + 8'd1;
            st <= lastb ? M_B : M_BEAT;
          end else if (cach && hit && !b_wr) begin  // read hit
            r_data <= cdat[idx][32*a[5:2] +: 32];
            r_resp <= 2'b00;
            st <= M_ROUT;
          end
        end

        M_WAIT: if (go) unique case (wk)
          W_FILL: if (dat_n == 2'd2) begin
            cdat[idx] <= {dat_q[1], dat_q[0]};
            ctag[idx] <= tg;
            cs[idx]   <= (dat_resp == RESP_SC) ? CS_SC : (dat_resp == RESP_UD_PD) ? CS_UD : CS_UC;
            st <= M_ACK;
          end
          W_CU: if (rsp_got) begin
            // Comp UC: the line is ours; Comp I: a snoop took it first, miss
            if (hit) cs[idx] <= (rsp_q.resp == RESP_UC) ? CS_UC : CS_I;
            st <= M_ACK;
          end
          W_EV: if (rsp_got) begin
            cs[wb_idx] <= CS_I;
            st <= M_BEAT;
          end
          W_WB: if (rsp_got) begin          // CompDBIDResp: send the line (or I if snooped away)
            wb_resp <= (cs[wb_idx] == CS_UD) ? RESP_UD_PD : (cs[wb_idx] == CS_SC) ? RESP_SC :
                       (cs[wb_idx] == CS_UC) ? RESP_UC : RESP_I;
            cs[wb_idx] <= CS_I;
            st <= M_WBD0;
          end
          W_NSRD: if (dat_n != 0) begin     // the first word; M_NSR serves the rest
            r_data <= dat_q[a[5]][32*a[4:2] +: 32];
            r_resp <= dat_err;
            ns_k <= 4'd1; ns_rd <= 1'b1;
            st <= M_ROUT;
          end
          W_NSDBID: if (rsp_got) begin      // DBIDResp: gather the words
            rsp_got <= 1'b0;
            wk <= W_NSGATH;
          end
          W_NSGATH: if (s_wvalid) begin     // w_take is on
            for (int l = 0; l < 4; l++) begin
              ns_wd[32*a[4:2] + 8*l +: 8] <= s_wdata[8*l +: 8];
              ns_be[4*a[4:2] + l]         <= s_wstrb[l];
            end
            ns_k <= ns_k + 4'd1;
            if (lastb) ns_last <= 1'b1;
            else b_i <= b_i + 8'd1;
            if (ns_k + 4'd1 == ns_n) wk <= W_NSDATA;
          end
          W_NSDATA: if (push_dat) wk <= W_NSCOMP;
          W_NSCOMP: if (rsp_got) begin
            if (rsp_q.resperr > b_worst) b_worst <= rsp_q.resperr;
            st <= ns_last ? M_B : M_BEAT;
          end
          default: ;
        endcase

        M_ACK: if (go && push_rsp) st <= M_BEAT;

        M_WBD0: if (go && push_dat) st <= M_WBD1;
        M_WBD1: if (go && push_dat) st <= M_BEAT;

        M_ROUT: if (s_rready) begin
          b_i <= b_i + 8'd1;
          if (!lastb && ns_rd && ns_k != ns_n) st <= M_NSR;
          else begin
            ns_rd <= 1'b0;
            st <= lastb ? M_IDLE : M_BEAT;
          end
        end

        M_NSR: begin                        // the next word of a NoSnp read
          r_data <= dat_q[a[5]][32*a[4:2] +: 32];
          r_resp <= dat_err;
          ns_k <= ns_k + 4'd1;
          st <= M_ROUT;
        end

        M_B: if (s_bready) st <= M_IDLE;

        default: st <= M_IDLE;
      endcase
    end
  end
endmodule
