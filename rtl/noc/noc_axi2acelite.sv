// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_axi2acelite -- test shim: an AXI4 VIP master drives an ACE-Lite port
// ----------------------------------------------------------------------------
// Bench-only (the generated tb_top puts it between the AXI4 VIP and the NoC's
// ACE-Lite port). The VIP's bursts pass through with:
//  * AxDOMAIN inner shareable on coherent memory (ReadOnce / WriteUnique;
//    WriteLineUnique for an aligned whole-line write), else non-shareable or
//    system by ID bit 0 (ReadNoSnoop / WriteNoSnoop).
//  * every EVERY-th VIP read / write, the shim inserts a transaction of its
//    own and swallows its response: on AR in turn a read barrier,
//    CleanShared, CleanInvalid and MakeInvalid (on the line of the last
//    coherent VIP read); on AW a write barrier.
// Responses come back in issue order, so a FIFO of "own" flags per direction
// tells the shim's responses from the VIP's.
// ============================================================================
module noc_axi2acelite
  import noc_cfg_pkg::*;
#(
  parameter int IDW   = 4,
  parameter int EVERY = 8
)(
  input  logic            clk, rst_n,
  // ---------------- AXI4 slave port (from the VIP) ----------------
  input  logic [IDW-1:0]  s_awid,
  input  logic [31:0]     s_awaddr,
  input  logic [7:0]      s_awlen,
  input  logic [2:0]      s_awsize,
  input  logic [1:0]      s_awburst,
  input  logic [2:0]      s_awprot,
  input  logic            s_awvalid,
  output logic            s_awready,
  input  logic [31:0]     s_wdata,
  input  logic [3:0]      s_wstrb,
  input  logic            s_wlast,
  input  logic            s_wvalid,
  output logic            s_wready,
  output logic [IDW-1:0]  s_bid,
  output logic [1:0]      s_bresp,
  output logic            s_bvalid,
  input  logic            s_bready,
  input  logic [IDW-1:0]  s_arid,
  input  logic [31:0]     s_araddr,
  input  logic [7:0]      s_arlen,
  input  logic [2:0]      s_arsize,
  input  logic [1:0]      s_arburst,
  input  logic [2:0]      s_arprot,
  input  logic            s_arvalid,
  output logic            s_arready,
  output logic [IDW-1:0]  s_rid,
  output logic [31:0]     s_rdata,
  output logic [1:0]      s_rresp,
  output logic            s_rlast,
  output logic            s_rvalid,
  input  logic            s_rready,
  // ---------------- ACE-Lite master port (to the NoC) ----------------
  output logic [IDW-1:0]  awid,
  output logic [31:0]     awaddr,
  output logic [7:0]      awlen,
  output logic [2:0]      awsize,
  output logic [1:0]      awburst,
  output logic [2:0]      awprot,
  output logic [2:0]      awsnoop,
  output logic [1:0]      awdomain,
  output logic [1:0]      awbar,
  output logic            awvalid,
  input  logic            awready,
  output logic [31:0]     wdata,
  output logic [3:0]      wstrb,
  output logic            wlast,
  output logic            wvalid,
  input  logic            wready,
  input  logic [IDW-1:0]  bid,
  input  logic [1:0]      bresp,
  input  logic            bvalid,
  output logic            bready,
  output logic [IDW-1:0]  arid,
  output logic [31:0]     araddr,
  output logic [7:0]      arlen,
  output logic [2:0]      arsize,
  output logic [1:0]      arburst,
  output logic [2:0]      arprot,
  output logic [3:0]      arsnoop,
  output logic [1:0]      ardomain,
  output logic [1:0]      arbar,
  output logic            arvalid,
  input  logic            arready,
  input  logic [IDW-1:0]  rid,
  input  logic [31:0]     rdata,
  input  logic [1:0]      rresp,
  input  logic            rlast,
  input  logic            rvalid,
  output logic            rready
);
  localparam int QD = 64;                 // in-flight transactions per direction (>= NI MAXB * 2)
  localparam int QB = $clog2(QD);

  // ---------------- read side ----------------
  logic [7:0]     r_cnt;                  // VIP reads since the last own one
  logic [1:0]     r_kind;                 // next own read: barrier, CleanShared, CleanInvalid, MakeInvalid
  logic [31:0]    r_line;                 // line of the last coherent VIP read
  logic           r_have;
  logic           r_own;                  // presenting an own AR
  logic [QD-1:0]  rq;                     // own flag per AR in flight, in order
  logic [QB-1:0]  rq_wp, rq_rp;
  wire  r_coh  = cacheable(s_araddr);

  always_comb begin
    if (r_own) begin
      arid = '0; arprot = 3'b000; arburst = 2'b01; arsize = 3'd2;
      if (r_kind == 2'd0) begin           // barrier
        araddr = '0; arlen = 8'd0; arsnoop = 4'b0000; ardomain = 2'b01; arbar = 2'b01;
      end else begin                      // cache maintenance on the last coherent line
        araddr = r_line; arlen = 8'd15; ardomain = 2'b01; arbar = 2'b00;
        arsnoop = r_kind == 2'd1 ? 4'b1000 : r_kind == 2'd2 ? 4'b1001 : 4'b1101;
      end
    end else begin
      arid = s_arid; araddr = s_araddr; arlen = s_arlen; arsize = s_arsize; arburst = s_arburst;
      arprot = s_arprot; arsnoop = 4'b0000; arbar = 2'b00;
      ardomain = r_coh ? 2'b01 : (s_arid[0] ? 2'b11 : 2'b00);
    end
  end
  assign arvalid   = r_own || s_arvalid;
  assign s_arready = !r_own && arready;

  wire r_head_own = rq[rq_rp];
  assign rready   = r_head_own || s_rready;
  assign s_rvalid = rvalid && !r_head_own;
  assign s_rid    = rid;
  assign s_rdata  = rdata;
  assign s_rresp  = rresp;
  assign s_rlast  = rlast;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      r_cnt <= '0; r_kind <= '0; r_line <= '0; r_have <= 1'b0; r_own <= 1'b0;
      rq <= '0; rq_wp <= '0; rq_rp <= '0;
    end else begin
      if (arvalid && arready) begin
        rq[rq_wp] <= r_own; rq_wp <= rq_wp + 1'b1;
        if (r_own) begin r_own <= 1'b0; r_kind <= r_kind + 1'b1; r_cnt <= '0; end
        else begin
          r_cnt <= r_cnt + 1'b1;
          if (r_coh) begin r_line <= {s_araddr[31:6], 6'd0}; r_have <= 1'b1; end
        end
      end
      // the own AR goes out between two VIP ARs (CMOs once a coherent line is known)
      if (!r_own && !(s_arvalid && !arready) && int'(r_cnt) >= EVERY && (r_kind == 2'd0 || r_have)) r_own <= 1'b1;
      if (rvalid && rready && rlast) rq_rp <= rq_rp + 1'b1;
    end

  // ---------------- write side ----------------
  logic [7:0]     w_cnt;
  logic           w_own;
  logic [QD-1:0]  wq;
  logic [QB-1:0]  wq_wp, wq_rp;
  wire  w_coh  = cacheable(s_awaddr);
  wire  w_line = w_coh && s_awaddr[5:0] == 6'd0 && s_awsize == 3'd2 && s_awlen == 8'd15 && s_awburst == 2'b01;
  // a W beat must not be taken for an AW that has not been forwarded yet only
  // matters to the NI, which holds W until its burst; pass W straight through
  assign wdata   = s_wdata;
  assign wstrb   = s_wstrb;
  assign wlast   = s_wlast;
  assign wvalid  = s_wvalid;
  assign s_wready = wready;

  always_comb begin
    if (w_own) begin
      awid = '0; awaddr = '0; awlen = 8'd0; awsize = 3'd2; awburst = 2'b01; awprot = 3'b000;
      awsnoop = 3'b000; awdomain = 2'b01; awbar = 2'b01;
    end else begin
      awid = s_awid; awaddr = s_awaddr; awlen = s_awlen; awsize = s_awsize; awburst = s_awburst;
      awprot = s_awprot; awbar = 2'b00;
      awsnoop  = w_line ? 3'b001 : 3'b000;
      awdomain = w_coh ? 2'b01 : (s_awid[0] ? 2'b11 : 2'b00);
    end
  end
  assign awvalid   = w_own || s_awvalid;
  assign s_awready = !w_own && awready;

  wire w_head_own = wq[wq_rp];
  assign bready   = w_head_own || s_bready;
  assign s_bvalid = bvalid && !w_head_own;
  assign s_bid    = bid;
  assign s_bresp  = bresp;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      w_cnt <= '0; w_own <= 1'b0; wq <= '0; wq_wp <= '0; wq_rp <= '0;
    end else begin
      if (awvalid && awready) begin
        wq[wq_wp] <= w_own; wq_wp <= wq_wp + 1'b1;
        if (w_own) begin w_own <= 1'b0; w_cnt <= '0; end
        else w_cnt <= w_cnt + 1'b1;
      end
      if (!w_own && !(s_awvalid && !awready) && int'(w_cnt) >= EVERY) w_own <= 1'b1;
      if (bvalid && bready) wq_rp <= wq_rp + 1'b1;
    end
endmodule
