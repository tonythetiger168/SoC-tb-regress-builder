// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_noc -- 4x4 mesh of 5-port XY routers with a node mux per router
// ----------------------------------------------------------------------------
// Router: xuanji-core orca_noc_router (fetched at build time, see
// scripts/fetch_private_ip.sh). Build with +define+TV8K_OPEN_ROUTER to use
// tv8k_router_open instead (same ports and routing, open source, no VCs).
//
// Node mux: the endpoints placed on a router (tv8k_noc_pkg::EP_X/EP_Y) share
// its local port. Injection is round-robin among them; ejection steers each
// flit to payload.dst_ep. Every endpoint NI always accepts what it ejects, so
// the local tx_ready is the AND of their (data-independent) ready signals.
// Router orientation: north = y+1, east = x+1 (orca_noc_router route_of()).
// ============================================================================
module tv8k_noc
  import tv8k_noc_pkg::*;
#(
  parameter int NUM_VC    = 4,
  parameter int BUF_DEPTH = 8
)(
  input  logic       clk,
  input  logic       rst_n,
  input  tv8k_flit_t inj_flit  [NEP],
  input  logic       inj_valid [NEP],
  output logic       inj_ready [NEP],
  output tv8k_flit_t ej_flit   [NEP],
  output logic       ej_valid  [NEP],
  input  logic       ej_ready  [NEP],
  output logic       busy
);
  localparam int NN = MESH_X * MESH_Y;
  // link wires, indexed by router n = y * MESH_X + x and direction 0 N, 1 S, 2 E, 3 W
  logic [FLIT_W-1:0] tx_d [NN][4];
  logic              tx_v [NN][4], tx_r [NN][4];
  logic [FLIT_W-1:0] rx_d [NN][4];
  logic              rx_v [NN][4], rx_r [NN][4];
  logic [FLIT_W-1:0] l_rx_d [NN], l_tx_d [NN];
  logic              l_rx_v [NN], l_rx_r [NN], l_tx_v [NN], l_tx_r [NN];
  logic [NN-1:0]     r_busy;
  assign busy = |r_busy;

  // neighbour of router n in direction d, or -1 at the mesh edge
  function automatic int nb(int n, int d);
    int x = n % MESH_X, y = n / MESH_X;
    case (d)
      0: return (y + 1 < MESH_Y) ? n + MESH_X : -1;
      1: return (y > 0)          ? n - MESH_X : -1;
      2: return (x + 1 < MESH_X) ? n + 1      : -1;
      default: return (x > 0)    ? n - 1      : -1;
    endcase
  endfunction
  function automatic int opp(int d);
    return d ^ 1;                          // N<->S, E<->W
  endfunction

  for (genvar n = 0; n < NN; n++) begin : g_r
    // links: my rx from the neighbour's tx toward me
    for (genvar d = 0; d < 4; d++) begin : g_l
      localparam int M = nb(n, d);
      if (M >= 0) begin : g_in
        assign rx_d[n][d] = tx_d[M][opp(d)];
        assign rx_v[n][d] = tx_v[M][opp(d)];
        assign tx_r[n][d] = rx_r[M][opp(d)];
      end else begin : g_edge
        assign rx_d[n][d] = '0;
        assign rx_v[n][d] = 1'b0;
        assign tx_r[n][d] = 1'b0;
      end
    end

`ifdef TV8K_OPEN_ROUTER
    tv8k_router_open #(.X_POS(n % MESH_X), .Y_POS(n / MESH_X), .BUF_DEPTH(BUF_DEPTH)) u_rt (
`else
    orca_noc_router #(.X_POS(n % MESH_X), .Y_POS(n / MESH_X), .NUM_VC(NUM_VC), .BUF_DEPTH(BUF_DEPTH),
                      .X_DIM(MESH_X), .Y_DIM(MESH_Y)) u_rt (
`endif
      .clk, .rst_n, .test_en(1'b0),
      .north_rx_data(rx_d[n][0]), .north_rx_valid(rx_v[n][0]), .north_rx_ready(rx_r[n][0]),
      .north_tx_data(tx_d[n][0]), .north_tx_valid(tx_v[n][0]), .north_tx_ready(tx_r[n][0]),
      .south_rx_data(rx_d[n][1]), .south_rx_valid(rx_v[n][1]), .south_rx_ready(rx_r[n][1]),
      .south_tx_data(tx_d[n][1]), .south_tx_valid(tx_v[n][1]), .south_tx_ready(tx_r[n][1]),
      .east_rx_data (rx_d[n][2]), .east_rx_valid (rx_v[n][2]), .east_rx_ready (rx_r[n][2]),
      .east_tx_data (tx_d[n][2]), .east_tx_valid (tx_v[n][2]), .east_tx_ready (tx_r[n][2]),
      .west_rx_data (rx_d[n][3]), .west_rx_valid (rx_v[n][3]), .west_rx_ready (rx_r[n][3]),
      .west_tx_data (tx_d[n][3]), .west_tx_valid (tx_v[n][3]), .west_tx_ready (tx_r[n][3]),
      .local_rx_data(l_rx_d[n]),  .local_rx_valid(l_rx_v[n]),  .local_rx_ready(l_rx_r[n]),
      .local_tx_data(l_tx_d[n]),  .local_tx_valid(l_tx_v[n]),  .local_tx_ready(l_tx_r[n]),
      .busy(r_busy[n])
    );

    // ---------------- node mux ----------------
    function automatic bit here(int e);
      return EP_X[e] == n % MESH_X && EP_Y[e] == n / MESH_X;
    endfunction
    logic [$clog2(NEP)-1:0] rr, pick;
    logic any;
    always_comb begin
      any  = 1'b0;
      pick = rr;
      for (int k = 0; k < NEP; k++) begin
        automatic int e = (int'(rr) + k) % NEP;
        if (!any && here(e) && inj_valid[e]) begin any = 1'b1; pick = $clog2(NEP)'(e); end
      end
    end
    assign l_rx_v[n] = any;
    assign l_rx_d[n] = inj_flit[pick];
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) rr <= '0;
      else if (any && l_rx_r[n]) rr <= $clog2(NEP)'((int'(pick) + 1) % NEP);

    always_comb begin
      l_tx_r[n] = 1'b1;
      for (int e = 0; e < NEP; e++) if (here(e) && !ej_ready[e]) l_tx_r[n] = 1'b0;
    end
  end

  // per-endpoint wiring
  for (genvar e = 0; e < NEP; e++) begin : g_ep
    localparam int N = EP_Y[e] * MESH_X + EP_X[e];
    assign inj_ready[e] = g_r[N].any && int'(g_r[N].pick) == e && l_rx_r[N];
    assign ej_flit[e]   = tv8k_flit_t'(l_tx_d[N]);
    assign ej_valid[e]  = l_tx_v[N] && int'(pkt_of(tv8k_flit_t'(l_tx_d[N])).dst_ep) == e;
  end
endmodule
