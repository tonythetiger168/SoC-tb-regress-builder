// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ipcam_axi_dn64 -- AXI4 data-width downsizer, 64-bit master -> 32-bit fabric,
// for masters that only issue single-beat, full-width, ID-0 bursts (the c1p
// codec's c1p_axi_mst: AxLEN 0, AxSIZE 3, WSTRB 0xFF, INCR, 8-byte aligned).
// ----------------------------------------------------------------------------
//  * AW / AR: forwarded with AxLEN 1, AxSIZE 2 (two 32-bit beats, low word first).
//  * W: each 64-bit beat becomes two 32-bit beats; the upstream WREADY is
//    given on the second one. W may lead AW (no dependency, as in AXI).
//  * R: two 32-bit beats are merged into one 64-bit beat (RRESP = worst of
//    the two). Upstream RREADY is assumed 1 (c1p_axi_mst ties it high), but
//    the merge only advances on a downstream handshake, so it stays legal
//    with any RREADY.
//  * B: passed through.
//  * Several outstanding bursts are fine: ID 0 keeps responses in order, and
//    the beat splitting / merging has no per-burst state beyond a beat phase.
// A burst outside that envelope (AxLEN != 0 or AxSIZE != 3) is flagged by an
// assertion; it would otherwise be forwarded with the wrong length.
// ============================================================================
module ipcam_axi_dn64 #(
  parameter int IDW = 4
)(
  input  logic           clk,
  input  logic           rst_n,
  // ---- upstream: 64-bit AXI4 master side (we are its slave) ----
  input  logic [IDW-1:0] u_awid,
  input  logic [31:0]    u_awaddr,
  input  logic [7:0]     u_awlen,
  input  logic [2:0]     u_awsize,
  input  logic [1:0]     u_awburst,
  input  logic [3:0]     u_awcache,
  input  logic [2:0]     u_awprot,
  input  logic           u_awvalid,
  output logic           u_awready,
  input  logic [63:0]    u_wdata,
  input  logic [7:0]     u_wstrb,
  input  logic           u_wlast,
  input  logic           u_wvalid,
  output logic           u_wready,
  output logic [IDW-1:0] u_bid,
  output logic [1:0]     u_bresp,
  output logic           u_bvalid,
  input  logic           u_bready,
  input  logic [IDW-1:0] u_arid,
  input  logic [31:0]    u_araddr,
  input  logic [7:0]     u_arlen,
  input  logic [2:0]     u_arsize,
  input  logic [1:0]     u_arburst,
  input  logic [3:0]     u_arcache,
  input  logic [2:0]     u_arprot,
  input  logic           u_arvalid,
  output logic           u_arready,
  output logic [IDW-1:0] u_rid,
  output logic [63:0]    u_rdata,
  output logic [1:0]     u_rresp,
  output logic           u_rlast,
  output logic           u_rvalid,
  input  logic           u_rready,
  // ---- downstream: 32-bit AXI4 master port into the fabric ----
  output logic [IDW-1:0] d_awid,
  output logic [31:0]    d_awaddr,
  output logic [7:0]     d_awlen,
  output logic [2:0]     d_awsize,
  output logic [1:0]     d_awburst,
  output logic [3:0]     d_awcache,
  output logic [2:0]     d_awprot,
  output logic           d_awvalid,
  input  logic           d_awready,
  output logic [31:0]    d_wdata,
  output logic [3:0]     d_wstrb,
  output logic           d_wlast,
  output logic           d_wvalid,
  input  logic           d_wready,
  input  logic [IDW-1:0] d_bid,
  input  logic [1:0]     d_bresp,
  input  logic           d_bvalid,
  output logic           d_bready,
  output logic [IDW-1:0] d_arid,
  output logic [31:0]    d_araddr,
  output logic [7:0]     d_arlen,
  output logic [2:0]     d_arsize,
  output logic [1:0]     d_arburst,
  output logic [3:0]     d_arcache,
  output logic [2:0]     d_arprot,
  output logic           d_arvalid,
  input  logic           d_arready,
  input  logic [IDW-1:0] d_rid,
  input  logic [31:0]    d_rdata,
  input  logic [1:0]     d_rresp,
  input  logic           d_rlast,
  input  logic           d_rvalid,
  output logic           d_rready
);
  // ---------------- AW / AR: combinational, length/size rewritten ----------
  assign d_awid    = u_awid;
  assign d_awaddr  = u_awaddr;
  assign d_awlen   = 8'd1;
  assign d_awsize  = 3'd2;
  assign d_awburst = u_awburst;
  assign d_awcache = u_awcache;
  assign d_awprot  = u_awprot;
  assign d_awvalid = u_awvalid;
  assign u_awready = d_awready;

  assign d_arid    = u_arid;
  assign d_araddr  = u_araddr;
  assign d_arlen   = 8'd1;
  assign d_arsize  = 3'd2;
  assign d_arburst = u_arburst;
  assign d_arcache = u_arcache;
  assign d_arprot  = u_arprot;
  assign d_arvalid = u_arvalid;
  assign u_arready = d_arready;

  // ---------------- W: split one 64-bit beat into two ----------------------
  logic w_hi;                                   // 0: sending the low word
  assign d_wdata  = w_hi ? u_wdata[63:32] : u_wdata[31:0];
  assign d_wstrb  = w_hi ? u_wstrb[7:4]   : u_wstrb[3:0];
  assign d_wlast  = w_hi;
  assign d_wvalid = u_wvalid;
  assign u_wready = d_wready & w_hi;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) w_hi <= 1'b0;
    else if (d_wvalid && d_wready) w_hi <= ~w_hi;

  // ---------------- B: pass-through ----------------------------------------
  assign u_bid    = d_bid;
  assign u_bresp  = d_bresp;
  assign u_bvalid = d_bvalid;
  assign d_bready = u_bready;

  // ---------------- R: merge two 32-bit beats ------------------------------
  logic        r_hi;                            // 1: low word captured
  logic [31:0] r_lo;
  logic [1:0]  r_lo_resp;
  assign u_rid    = d_rid;
  assign u_rdata  = {d_rdata, r_lo};
  assign u_rresp  = (d_rresp > r_lo_resp) ? d_rresp : r_lo_resp;
  assign u_rlast  = d_rlast;
  assign u_rvalid = d_rvalid & r_hi;
  assign d_rready = r_hi ? u_rready : 1'b1;    // the low word is always taken
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      r_hi      <= 1'b0;
      r_lo      <= '0;
      r_lo_resp <= 2'b00;
    end else if (d_rvalid && d_rready) begin
      if (!r_hi) begin
        r_lo      <= d_rdata;
        r_lo_resp <= d_rresp;
      end
      r_hi <= ~r_hi;
    end

  // ---------------- envelope checks ----------------------------------------
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    if (u_awvalid && (u_awlen != 8'd0 || u_awsize != 3'd3))
      $error("ipcam_axi_dn64: AW len=%0d size=%0d outside the single-beat 64-bit envelope", u_awlen, u_awsize);
    if (u_arvalid && (u_arlen != 8'd0 || u_arsize != 3'd3))
      $error("ipcam_axi_dn64: AR len=%0d size=%0d outside the single-beat 64-bit envelope", u_arlen, u_arsize);
    if (u_wvalid && !u_wlast)
      $error("ipcam_axi_dn64: upstream W beat without WLAST (multi-beat burst)");
  end
`endif
endmodule
