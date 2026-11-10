// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_ni_chi -- RN-F network interface: a CHI port (noc_cfg_pkg chi_*_t
// channels) <-> NoC packets to and from the homes and other RN-Fs
// ----------------------------------------------------------------------------
//  * TX: the RN-F's REQ, RSP and DAT channels (valid / ready) become one
//    packet each (OP_CREQ / OP_CRSP / OP_CDAT). A request goes to the home of
//    its address (hn_ep); a response or data flit to its TgtID (a home, or
//    the requester of a forwarded snoop, DCT). DAT goes first, then RSP, then
//    REQ, so snoop responses and write data are never held behind a new
//    request.
//  * RX: RSP, DAT and SNP packets are handed over the cycle they arrive, and
//    so is read data a slave NI sends here for a home (DMT: OP_RDATA carrying
//    the home's CompData fields). The RN-F always accepts (room for every
//    response to its own requests and one snoop per home
//    transaction slot), so the NI always
//    ejects.
// ============================================================================
module noc_ni_chi
  import noc_cfg_pkg::*;
#(
  parameter int SELF = 0
)(
  input  logic       clk,
  input  logic       rst_n,
  // ---------------- CHI port (from / to the RN-F) ----------------
  input  logic       txreq_valid,
  output logic       txreq_ready,
  input  chi_req_t   txreq_flit,
  input  logic       txrsp_valid,
  output logic       txrsp_ready,
  input  chi_rsp_t   txrsp_flit,
  input  logic       txdat_valid,
  output logic       txdat_ready,
  input  chi_dat_t   txdat_flit,
  output logic       rxrsp_valid,
  output chi_rsp_t   rxrsp_flit,
  output logic       rxdat_valid,
  output chi_dat_t   rxdat_flit,
  output logic       rxsnp_valid,
  output chi_snp_t   rxsnp_flit,
  // ---------------- NoC ----------------
  output noc_flit_t  inj_flit,
  output logic       inj_valid,
  input  logic       inj_ready,
  input  noc_flit_t  ej_flit,
  input  logic       ej_valid,
  output logic       ej_ready
);
  pkt_t tp, ep;

  always_comb begin
    tp = '0;
    tp.src_ep = EPB'(SELF);
    if (txdat_valid) begin
      tp.op     = OP_CDAT;
      tp.dst_ep = txdat_flit.nid;
      tp.hnid   = txdat_flit.homenid;
      tp.tag    = txdat_flit.txnid;
      tp.copc   = {2'b0, txdat_flit.opcode};
      tp.cresp  = txdat_flit.resp;
      tp.resp   = txdat_flit.resperr;
      tp.dataid = txdat_flit.dataid;
      tp.strb   = txdat_flit.be;
      tp.data   = txdat_flit.data;
    end else if (txrsp_valid) begin
      tp.op     = OP_CRSP;
      tp.dst_ep = txrsp_flit.nid;
      tp.tag    = txrsp_flit.txnid;
      tp.copc   = {2'b0, txrsp_flit.opcode};
      tp.cresp  = txrsp_flit.resp;
      tp.resp   = txrsp_flit.resperr;
      tp.dbid   = txrsp_flit.dbid;
    end else begin
      tp.op     = OP_CREQ;
      tp.dst_ep = hn_ep(txreq_flit.addr);
      tp.tag    = txreq_flit.txnid;
      tp.copc   = txreq_flit.opcode;
      tp.addr   = txreq_flit.addr;
      tp.size   = txreq_flit.size;
      tp.nm1    = txreq_flit.nm1;
    end
  end

  assign inj_valid   = txdat_valid || txrsp_valid || txreq_valid;
  assign inj_flit    = mk_flit(tp, SELF, (tp.op == OP_CREQ) ? VC_REQ : VC_RSP);
  assign txdat_ready = inj_ready;
  assign txrsp_ready = inj_ready && !txdat_valid;
  assign txreq_ready = inj_ready && !txdat_valid && !txrsp_valid;

  assign ej_ready = 1'b1;
  assign ep = pkt_of(ej_flit);
  wire dmt = ep.op == OP_RDATA;            // memory data for a home's CompData
  assign rxrsp_valid = ej_valid && ep.op == OP_CRSP;
  assign rxdat_valid = ej_valid && (ep.op == OP_CDAT || dmt);
  assign rxsnp_valid = ej_valid && ep.op == OP_CSNP;
  assign rxrsp_flit  = '{nid: ep.src_ep, txnid: ep.tag, opcode: ep.copc[3:0], resp: ep.cresp,
                         resperr: ep.resp, dbid: ep.dbid};
  assign rxdat_flit  = '{nid: ep.src_ep, homenid: ep.hnid, txnid: ep.tag, opcode: ep.copc[3:0],
                         resp: ep.cresp, resperr: dmt ? ep.rresp[0] : ep.resp,
                         dataid: ep.dataid, be: dmt ? '1 : ep.strb, data: ep.data};
  assign rxsnp_flit  = '{nid: ep.src_ep, txnid: ep.tag, opcode: ep.copc[4:0], addr: ep.addr,
                         fwdnid: ep.fwd, fwdtxnid: ep.dbid};

  // synopsys translate_off
  always @(posedge clk)
    if (rst_n && ej_valid && ep.op inside {OP_RD, OP_WR, OP_WRSP, OP_CREQ})
      $error("noc_ni_chi[%0d]: unexpected packet op %0d", SELF, ep.op);
  // synopsys translate_on
endmodule
