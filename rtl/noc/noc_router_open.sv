// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_router_open -- open stand-in for xuanji-core's orca_noc_router
// (generic copy of rtl/tv8k/tv8k_router_open.sv, importing the generated noc_cfg_pkg)
// ----------------------------------------------------------------------------
// Same ports and behaviour seen from outside: 5 ports (N, S, E, W, local),
// XY dimension-order routing (east/west first, north = y+1), single-flit
// packets, rx_ready independent of the data, tx_valid only while tx_ready.
// Simpler inside: one FIFO per input port (no virtual channels) and a
// round-robin arbiter per output port. Used when xuanji-core is not
// available (+define+NOC_OPEN_ROUTER).
// ============================================================================
module noc_router_open
  import noc_cfg_pkg::*;
#(
  parameter int X_POS = 0,
  parameter int Y_POS = 0,
  parameter int BUF_DEPTH = 8
)(
  input  logic              clk,
  input  logic              rst_n,
  input  logic              test_en,
  input  logic [FLIT_W-1:0] north_rx_data, input logic north_rx_valid, output logic north_rx_ready,
  output logic [FLIT_W-1:0] north_tx_data, output logic north_tx_valid, input logic north_tx_ready,
  input  logic [FLIT_W-1:0] south_rx_data, input logic south_rx_valid, output logic south_rx_ready,
  output logic [FLIT_W-1:0] south_tx_data, output logic south_tx_valid, input logic south_tx_ready,
  input  logic [FLIT_W-1:0] east_rx_data,  input logic east_rx_valid,  output logic east_rx_ready,
  output logic [FLIT_W-1:0] east_tx_data,  output logic east_tx_valid,  input logic east_tx_ready,
  input  logic [FLIT_W-1:0] west_rx_data,  input logic west_rx_valid,  output logic west_rx_ready,
  output logic [FLIT_W-1:0] west_tx_data,  output logic west_tx_valid,  input logic west_tx_ready,
  input  logic [FLIT_W-1:0] local_rx_data, input logic local_rx_valid, output logic local_rx_ready,
  output logic [FLIT_W-1:0] local_tx_data, output logic local_tx_valid, input logic local_tx_ready,
  output logic              busy
);
  localparam int NP = 5;                  // 0 N, 1 S, 2 E, 3 W, 4 local
  localparam int PW = $clog2(BUF_DEPTH);

  logic [FLIT_W-1:0] in_d [NP];
  logic              in_v [NP], in_r [NP], out_r [NP];
  assign in_d  = '{north_rx_data, south_rx_data, east_rx_data, west_rx_data, local_rx_data};
  assign in_v  = '{north_rx_valid, south_rx_valid, east_rx_valid, west_rx_valid, local_rx_valid};
  assign out_r = '{north_tx_ready, south_tx_ready, east_tx_ready, west_tx_ready, local_tx_ready};
  assign {north_rx_ready, south_rx_ready, east_rx_ready, west_rx_ready, local_rx_ready} =
         {in_r[0], in_r[1], in_r[2], in_r[3], in_r[4]};

  function automatic int dir_of(logic [FLIT_W-1:0] d);
    noc_flit_t f = noc_flit_t'(d);
    if (int'(f.dest_x) > X_POS) return 2;
    if (int'(f.dest_x) < X_POS) return 3;
    if (int'(f.dest_y) > Y_POS) return 0;
    if (int'(f.dest_y) < Y_POS) return 1;
    return 4;
  endfunction

  // input FIFOs
  logic [FLIT_W-1:0] head [NP];
  logic              nempty [NP], pop [NP];
  logic [NP-1:0]     ne;
  for (genvar p = 0; p < NP; p++) begin : g_in
    logic [FLIT_W-1:0] mem [BUF_DEPTH];
    logic [PW-1:0] wp, rp;
    logic [PW:0]   cnt;
    assign in_r[p]   = (cnt != (PW+1)'(BUF_DEPTH));
    assign nempty[p] = (cnt != 0);
    assign ne[p]     = nempty[p];
    assign head[p]   = mem[rp];
    wire push = in_v[p] && in_r[p];
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin wp <= '0; rp <= '0; cnt <= '0; end
      else begin
        if (push) begin mem[wp] <= in_d[p]; wp <= (int'(wp) == BUF_DEPTH - 1) ? '0 : wp + 1'b1; end
        if (pop[p]) rp <= (int'(rp) == BUF_DEPTH - 1) ? '0 : rp + 1'b1;
        cnt <= cnt + (PW+1)'(push) - (PW+1)'(pop[p]);
      end
  end
  assign busy = |ne;

  // output arbitration
  logic [2:0] rr [NP];
  logic [2:0] win [NP];
  logic       ov [NP];
  always_comb begin
    for (int p = 0; p < NP; p++) pop[p] = 1'b0;
    for (int o = 0; o < NP; o++) begin
      ov[o] = 1'b0; win[o] = '0;
      for (int k = 0; k < NP; k++) begin
        automatic int i = (int'(rr[o]) + k) % NP;
        if (!ov[o] && nempty[i] && dir_of(head[i]) == o) begin ov[o] = out_r[o]; win[o] = 3'(i); end
      end
      if (ov[o]) pop[win[o]] = 1'b1;
    end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) for (int o = 0; o < NP; o++) rr[o] <= '0;
    else for (int o = 0; o < NP; o++) if (ov[o]) rr[o] <= 3'((int'(win[o]) + 1) % NP);

  assign north_tx_valid = ov[0]; assign north_tx_data = ov[0] ? head[win[0]] : '0;
  assign south_tx_valid = ov[1]; assign south_tx_data = ov[1] ? head[win[1]] : '0;
  assign east_tx_valid  = ov[2]; assign east_tx_data  = ov[2] ? head[win[2]] : '0;
  assign west_tx_valid  = ov[3]; assign west_tx_data  = ov[3] ? head[win[3]] : '0;
  assign local_tx_valid = ov[4]; assign local_tx_data = ov[4] ? head[win[4]] : '0;
endmodule
