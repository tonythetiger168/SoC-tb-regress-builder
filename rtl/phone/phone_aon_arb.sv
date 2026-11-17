// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_aon_arb -- N AXI4 managers onto one AXI4 port (always-on cluster)
// ----------------------------------------------------------------------------
// Write and read paths are arbitrated independently, round robin, one burst
// at a time per direction: a write grant holds from AW to the B handshake, a
// read grant from AR to the last R beat. IDs pass through unchanged, so the
// managers must use distinct IDs (the open-ip AON IPs use 9, 10 and 11).
// ============================================================================
module phone_aon_arb #(
  parameter int N = 3
)(
  input  logic        clk,
  input  logic        rst_n,
  // managers
  input  logic [3:0]  awid    [N],
  input  logic [31:0] awaddr  [N],
  input  logic [7:0]  awlen   [N],
  input  logic [2:0]  awsize  [N],
  input  logic [1:0]  awburst [N],
  input  logic [2:0]  awprot  [N],
  input  logic        awvalid [N],
  output logic        awready [N],
  input  logic [31:0] wdata   [N],
  input  logic [3:0]  wstrb   [N],
  input  logic        wlast   [N],
  input  logic        wvalid  [N],
  output logic        wready  [N],
  output logic [3:0]  bid     [N],
  output logic [1:0]  bresp   [N],
  output logic        bvalid  [N],
  input  logic        bready  [N],
  input  logic [3:0]  arid    [N],
  input  logic [31:0] araddr  [N],
  input  logic [7:0]  arlen   [N],
  input  logic [2:0]  arsize  [N],
  input  logic [1:0]  arburst [N],
  input  logic [2:0]  arprot  [N],
  input  logic        arvalid [N],
  output logic        arready [N],
  output logic [3:0]  rid     [N],
  output logic [31:0] rdata   [N],
  output logic [1:0]  rresp   [N],
  output logic        rlast   [N],
  output logic        rvalid  [N],
  input  logic        rready  [N],
  // shared port
  output logic [3:0]  o_awid, output logic [31:0] o_awaddr, output logic [7:0] o_awlen,
  output logic [2:0]  o_awsize, output logic [1:0] o_awburst, output logic [2:0] o_awprot,
  output logic        o_awvalid, input logic o_awready,
  output logic [31:0] o_wdata, output logic [3:0] o_wstrb, output logic o_wlast,
  output logic        o_wvalid, input logic o_wready,
  input  logic [3:0]  o_bid, input logic [1:0] o_bresp, input logic o_bvalid, output logic o_bready,
  output logic [3:0]  o_arid, output logic [31:0] o_araddr, output logic [7:0] o_arlen,
  output logic [2:0]  o_arsize, output logic [1:0] o_arburst, output logic [2:0] o_arprot,
  output logic        o_arvalid, input logic o_arready,
  input  logic [3:0]  o_rid, input logic [31:0] o_rdata, input logic [1:0] o_rresp,
  input  logic        o_rlast, input logic o_rvalid, output logic o_rready
);
  localparam int GW = (N > 1) ? $clog2(N) : 1;

  // ---------------------------------------------------------------- write
  typedef enum logic [1:0] {W_IDLE, W_AW, W_DATA, W_RESP} w_st_e;
  w_st_e       ws;
  logic [GW-1:0] wg, wnext;
  logic        w_any;

  always_comb begin
    w_any = 1'b0; wnext = wg;
    for (int k = 1; k <= N; k++) begin
      automatic int c = (int'(wg) + k) % N;
      if (!w_any && awvalid[c]) begin w_any = 1'b1; wnext = GW'(c); end
    end
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin ws <= W_IDLE; wg <= '0; end
    else case (ws)
      W_IDLE: if (w_any) begin wg <= wnext; ws <= W_AW; end
      W_AW:   if (o_awready) ws <= W_DATA;
      W_DATA: if (o_wvalid && o_wready && o_wlast) ws <= W_RESP;
      W_RESP: if (o_bvalid && o_bready) ws <= W_IDLE;
      default: ws <= W_IDLE;
    endcase

  assign o_awid    = awid[wg];
  assign o_awaddr  = awaddr[wg];
  assign o_awlen   = awlen[wg];
  assign o_awsize  = awsize[wg];
  assign o_awburst = awburst[wg];
  assign o_awprot  = awprot[wg];
  assign o_awvalid = (ws == W_AW) && awvalid[wg];
  assign o_wdata   = wdata[wg];
  assign o_wstrb   = wstrb[wg];
  assign o_wlast   = wlast[wg];
  assign o_wvalid  = (ws == W_DATA) && wvalid[wg];
  assign o_bready  = (ws == W_RESP) && bready[wg];
  always_comb
    for (int i = 0; i < N; i++) begin
      awready[i] = (ws == W_AW)   && (GW'(i) == wg) && o_awready;
      wready[i]  = (ws == W_DATA) && (GW'(i) == wg) && o_wready;
      bvalid[i]  = (ws == W_RESP) && (GW'(i) == wg) && o_bvalid;
      bid[i]     = o_bid;
      bresp[i]   = o_bresp;
    end

  // ---------------------------------------------------------------- read
  typedef enum logic [1:0] {R_IDLE, R_AR, R_DATA} r_st_e;
  r_st_e       rs;
  logic [GW-1:0] rg, rnext;
  logic        r_any;

  always_comb begin
    r_any = 1'b0; rnext = rg;
    for (int k = 1; k <= N; k++) begin
      automatic int c = (int'(rg) + k) % N;
      if (!r_any && arvalid[c]) begin r_any = 1'b1; rnext = GW'(c); end
    end
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin rs <= R_IDLE; rg <= '0; end
    else case (rs)
      R_IDLE: if (r_any) begin rg <= rnext; rs <= R_AR; end
      R_AR:   if (o_arready) rs <= R_DATA;
      R_DATA: if (o_rvalid && o_rready && o_rlast) rs <= R_IDLE;
      default: rs <= R_IDLE;
    endcase

  assign o_arid    = arid[rg];
  assign o_araddr  = araddr[rg];
  assign o_arlen   = arlen[rg];
  assign o_arsize  = arsize[rg];
  assign o_arburst = arburst[rg];
  assign o_arprot  = arprot[rg];
  assign o_arvalid = (rs == R_AR) && arvalid[rg];
  assign o_rready  = (rs == R_DATA) && rready[rg];
  always_comb
    for (int i = 0; i < N; i++) begin
      arready[i] = (rs == R_AR)   && (GW'(i) == rg) && o_arready;
      rvalid[i]  = (rs == R_DATA) && (GW'(i) == rg) && o_rvalid;
      rid[i]     = o_rid;
      rdata[i]   = o_rdata;
      rresp[i]   = o_rresp;
      rlast[i]   = o_rlast;
    end
endmodule
