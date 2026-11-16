// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_d2d_gw -- die-to-die gateway: one die's mesh <-> a UCIe D2D adapter
// ----------------------------------------------------------------------------
//  * Sits on its die's mesh as endpoint SELF (NM + NS + die). The mesh
//    ejects here every flit whose destination endpoint is on another die
//    (noc_cfg_pkg::local_ep); the gateway sends its packet (pkt_t, which
//    fits the 64-byte UCIe payload) over the link. Packets that arrive from
//    the link are injected into this die's mesh toward their endpoint.
//  * Never back-pressures the mesh and needs no link credits: both queues
//    hold QD packets, and every packet in the system belongs to one chunk
//    a master NI has in flight (at most NM x MAXO reads + NM x MAXO writes),
//    so with QD >= 2 x NM x MAXO they cannot fill. `overflow` reports a
//    violation (a sizing error), it is not a flow-control signal.
//  * The UCIe adapter's tx_ready (link up, replay buffer room) holds the
//    transmit queue; the receive side has no ready, as in UCIe_top.
// ============================================================================
module noc_d2d_gw
  import noc_cfg_pkg::*;
#(
  parameter int SELF = NM + NS,
  parameter int QD   = 64
)(
  input  logic         clk,
  input  logic         rst_n,
  // ---------------- this die's mesh ----------------
  output noc_flit_t    inj_flit,
  output logic         inj_valid,
  input  logic         inj_ready,
  input  noc_flit_t    ej_flit,
  input  logic         ej_valid,
  output logic         ej_ready,
  // ---------------- UCIe adapter, protocol side ----------------
  output logic         tx_valid,
  output logic [511:0] tx_data,
  input  logic         tx_ready,
  input  logic         rx_valid,
  input  logic [511:0] rx_data,
  // ---------------- status ----------------
  output logic         overflow,
  output logic [$clog2(QD):0] tx_level,
  output logic [$clog2(QD):0] rx_level
);
  localparam int QB = $clog2(QD);

  pkt_t        txq [QD];
  pkt_t        rxq [QD];
  logic [QB:0] tx_cnt, rx_cnt;
  logic [QB-1:0] tx_wp, tx_rp, rx_wp, rx_rp;

  assign ej_ready  = 1'b1;
  assign tx_valid  = (tx_cnt != 0);
  assign tx_data   = 512'(txq[tx_rp]);
  assign inj_valid = (rx_cnt != 0);
  assign inj_flit  = mk_flit(rxq[rx_rp], SELF,
                             (rxq[rx_rp].op == OP_RD || rxq[rx_rp].op == OP_WR) ? VC_REQ : VC_RSP);
  assign tx_level  = tx_cnt;
  assign rx_level  = rx_cnt;

  wire tx_push = ej_valid;
  wire tx_pop  = tx_valid && tx_ready;
  wire rx_push = rx_valid;
  wire rx_pop  = inj_valid && inj_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_cnt <= '0; tx_wp <= '0; tx_rp <= '0;
      rx_cnt <= '0; rx_wp <= '0; rx_rp <= '0;
      overflow <= 1'b0;
    end else begin
      if (tx_push) begin
        if (tx_cnt == (QB+1)'(QD) && !tx_pop) overflow <= 1'b1;
        txq[tx_wp] <= pkt_of(ej_flit);
        tx_wp <= (int'(tx_wp) == QD - 1) ? '0 : tx_wp + 1'b1;
      end
      if (tx_pop) tx_rp <= (int'(tx_rp) == QD - 1) ? '0 : tx_rp + 1'b1;
      tx_cnt <= tx_cnt + (QB+1)'(tx_push) - (QB+1)'(tx_pop);
      if (rx_push) begin
        if (rx_cnt == (QB+1)'(QD) && !rx_pop) overflow <= 1'b1;
        rxq[rx_wp] <= pkt_t'(rx_data[PKT_W-1:0]);
        rx_wp <= (int'(rx_wp) == QD - 1) ? '0 : rx_wp + 1'b1;
      end
      if (rx_pop) rx_rp <= (int'(rx_rp) == QD - 1) ? '0 : rx_rp + 1'b1;
      rx_cnt <= rx_cnt + (QB+1)'(rx_push) - (QB+1)'(rx_pop);
    end
  end

  // synopsys translate_off
  always @(posedge clk)
    if (rst_n && overflow) $error("noc_d2d_gw[%0d]: queue overflow (QD %0d too small)", SELF, QD);
  // synopsys translate_on
endmodule
