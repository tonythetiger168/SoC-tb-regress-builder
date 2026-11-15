// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_acelite2axi -- ACE-Lite (IO-coherent) master port -> the master NI
// ----------------------------------------------------------------------------
// ACE-Lite = AXI4 + AxDOMAIN, AxSNOOP and AxBAR. The NI serves every coherent
// address through its home (HN-F), which snoops the RN-F caches: that is
// ReadOnce / WriteUnique. This adapter adds:
//  * shareability: AxDOMAIN non-shareable (00) or system (11) with AxSNOOP 0
//    (ReadNoSnoop / WriteNoSnoop) sets nosnp, so the NI sends the burst
//    straight to the slave port and the home is bypassed (no snoops: software
//    keeps such lines out of the caches). Inner / outer shareable (01 / 10)
//    goes through the home.
//  * WriteLineUnique (AWSNOOP 001) is a snooped write like WriteUnique.
//  * cache maintenance on AR: CleanShared (1000), CleanInvalid (1001),
//    MakeInvalid (1101). Each becomes a one-word snooped read of the line at
//    its home: the home snoops the unique holder SnpCleanShared and writes a
//    dirty line back to memory, which is CleanShared. CleanInvalid and
//    MakeInvalid get the same clean but do NOT invalidate the RN-F copies
//    (the home has no invalidating dataless request yet; documented gap).
//    The master gets the single R beat (data to be ignored).
//  * barriers (AxBAR[0] = 1): held until every earlier transaction of that
//    direction has its response, then answered here (one R beat with RLAST /
//    one B), so later transactions are issued only after the barrier.
// Responses keep the NI's order (in order per port), so a barrier never
// overtakes a response.
// ============================================================================
module noc_acelite2axi #(
  parameter int IDW = 4
)(
  input  logic            clk, rst_n,
  // ---------------- ACE-Lite slave port (from the master) ----------------
  input  logic [IDW-1:0]  s_awid,
  input  logic [31:0]     s_awaddr,
  input  logic [7:0]      s_awlen,
  input  logic [2:0]      s_awsize,
  input  logic [1:0]      s_awburst,
  input  logic [2:0]      s_awprot,
  input  logic [2:0]      s_awsnoop,
  input  logic [1:0]      s_awdomain,
  input  logic [1:0]      s_awbar,
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
  input  logic [3:0]      s_arsnoop,
  input  logic [1:0]      s_ardomain,
  input  logic [1:0]      s_arbar,
  input  logic            s_arvalid,
  output logic            s_arready,
  output logic [IDW-1:0]  s_rid,
  output logic [31:0]     s_rdata,
  output logic [1:0]      s_rresp,
  output logic            s_rlast,
  output logic            s_rvalid,
  input  logic            s_rready,
  // ---------------- AXI4 master port (to noc_ni_mst) ----------------
  output logic [IDW-1:0]  m_awid,
  output logic [31:0]     m_awaddr,
  output logic [7:0]      m_awlen,
  output logic [2:0]      m_awsize,
  output logic [1:0]      m_awburst,
  output logic [2:0]      m_awprot,
  output logic            m_awnosnp,
  output logic            m_awvalid,
  input  logic            m_awready,
  output logic [31:0]     m_wdata,
  output logic [3:0]      m_wstrb,
  output logic            m_wlast,
  output logic            m_wvalid,
  input  logic            m_wready,
  input  logic [IDW-1:0]  m_bid,
  input  logic [1:0]      m_bresp,
  input  logic            m_bvalid,
  output logic            m_bready,
  output logic [IDW-1:0]  m_arid,
  output logic [31:0]     m_araddr,
  output logic [7:0]      m_arlen,
  output logic [2:0]      m_arsize,
  output logic [1:0]      m_arburst,
  output logic [2:0]      m_arprot,
  output logic            m_arnosnp,
  output logic            m_arvalid,
  input  logic            m_arready,
  input  logic [IDW-1:0]  m_rid,
  input  logic [31:0]     m_rdata,
  input  logic [1:0]      m_rresp,
  input  logic            m_rlast,
  input  logic            m_rvalid,
  output logic            m_rready
);
  function automatic logic shareable(logic [1:0] d);
    return d == 2'b01 || d == 2'b10;
  endfunction

  // ---------------- read side ----------------
  logic [7:0]     r_out;                  // ARs sent to the NI without their last R beat yet
  logic           br_pend;                // a read barrier's R beat to return
  logic [IDW-1:0] br_id;
  wire  ar_bar = s_arbar[0];
  wire  ar_cmo = s_arsnoop == 4'b1000 || s_arsnoop == 4'b1001 || s_arsnoop == 4'b1101;

  assign m_arid    = s_arid;
  assign m_araddr  = ar_cmo ? {s_araddr[31:6], 6'd0} : s_araddr;
  assign m_arlen   = ar_cmo ? 8'd0 : s_arlen;
  assign m_arsize  = ar_cmo ? 3'd2 : s_arsize;
  assign m_arburst = ar_cmo ? 2'b01 : s_arburst;
  assign m_arprot  = s_arprot;
  assign m_arnosnp = !ar_cmo && !shareable(s_ardomain);
  assign m_arvalid = s_arvalid && !ar_bar && !br_pend;
  assign s_arready = !br_pend && (ar_bar ? r_out == '0 : m_arready);

  assign s_rvalid = br_pend || m_rvalid;
  assign s_rid    = br_pend ? br_id : m_rid;
  assign s_rdata  = br_pend ? '0 : m_rdata;
  assign s_rresp  = br_pend ? 2'b00 : m_rresp;
  assign s_rlast  = br_pend || m_rlast;
  assign m_rready = !br_pend && s_rready;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      r_out <= '0; br_pend <= 1'b0; br_id <= '0;
    end else begin
      r_out <= r_out + 8'(m_arvalid && m_arready) - 8'(m_rvalid && m_rready && m_rlast);
      if (s_arvalid && s_arready && ar_bar) begin br_pend <= 1'b1; br_id <= s_arid; end
      else if (br_pend && s_rready) br_pend <= 1'b0;
    end

  // ---------------- write side ----------------
  logic [7:0]     w_out;                  // AWs sent to the NI without their B yet
  logic           bw_pend;                // a write barrier's B to return
  logic [IDW-1:0] bw_id;
  wire  aw_bar = s_awbar[0];

  assign m_awid    = s_awid;
  assign m_awaddr  = s_awaddr;
  assign m_awlen   = s_awlen;
  assign m_awsize  = s_awsize;
  assign m_awburst = s_awburst;
  assign m_awprot  = s_awprot;
  assign m_awnosnp = s_awsnoop == 3'b000 && !shareable(s_awdomain);
  assign m_awvalid = s_awvalid && !aw_bar && !bw_pend;
  assign s_awready = !bw_pend && (aw_bar ? w_out == '0 : m_awready);
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign m_wlast   = s_wlast;
  assign m_wvalid  = s_wvalid;
  assign s_wready  = m_wready;

  assign s_bvalid = bw_pend || m_bvalid;
  assign s_bid    = bw_pend ? bw_id : m_bid;
  assign s_bresp  = bw_pend ? 2'b00 : m_bresp;
  assign m_bready = !bw_pend && s_bready;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      w_out <= '0; bw_pend <= 1'b0; bw_id <= '0;
    end else begin
      w_out <= w_out + 8'(m_awvalid && m_awready) - 8'(m_bvalid && m_bready);
      if (s_awvalid && s_awready && aw_bar) begin bw_pend <= 1'b1; bw_id <= s_awid; end
      else if (bw_pend && s_bready) bw_pend <= 1'b0;
    end

`ifndef SYNTHESIS
  // ---------------- ACE-Lite port rules (ARM IHI 0022, ACE-Lite subset) ----------------
  // read: ReadNoSnoop / ReadOnce (0000), CleanShared, CleanInvalid, MakeInvalid; barrier = AxSNOOP 0, one beat
  a_arsnoop: assert property (@(posedge clk) disable iff (!rst_n)
    s_arvalid |-> s_arsnoop inside {4'b0000, 4'b1000, 4'b1001, 4'b1101});
  a_awsnoop: assert property (@(posedge clk) disable iff (!rst_n)
    s_awvalid |-> s_awsnoop inside {3'b000, 3'b001});
  a_arbar: assert property (@(posedge clk) disable iff (!rst_n)
    s_arvalid && s_arbar[0] |-> s_arsnoop == 4'b0000 && s_arlen == 8'd0);
  a_awbar: assert property (@(posedge clk) disable iff (!rst_n)
    s_awvalid && s_awbar[0] |-> s_awsnoop == 3'b000 && s_awlen == 8'd0);
  // CMOs and WriteLineUnique are shareable whole-line transactions
  a_cmo: assert property (@(posedge clk) disable iff (!rst_n)
    s_arvalid && ar_cmo |-> shareable(s_ardomain) && s_araddr[5:0] == 6'd0);
  a_wlu: assert property (@(posedge clk) disable iff (!rst_n)
    s_awvalid && s_awsnoop == 3'b001 |-> shareable(s_awdomain) && s_awaddr[5:0] == 6'd0 &&
                                          (32'(s_awlen) + 1) << s_awsize == 32'd64);
  // request stable until accepted
  a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_arvalid && !s_arready |=> s_arvalid && $stable({s_arid, s_araddr, s_arlen, s_arsnoop, s_ardomain, s_arbar}));
  a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
    s_awvalid && !s_awready |=> s_awvalid && $stable({s_awid, s_awaddr, s_awlen, s_awsnoop, s_awdomain, s_awbar}));
  c_readonce:   cover property (@(posedge clk) s_arvalid && s_arready && !ar_bar && !ar_cmo && shareable(s_ardomain));
  c_readnosnp:  cover property (@(posedge clk) s_arvalid && s_arready && !ar_bar && !ar_cmo && !shareable(s_ardomain));
  c_cleanshared: cover property (@(posedge clk) s_arvalid && s_arready && s_arsnoop == 4'b1000);
  c_cleaninv:   cover property (@(posedge clk) s_arvalid && s_arready && s_arsnoop == 4'b1001);
  c_makeinv:    cover property (@(posedge clk) s_arvalid && s_arready && s_arsnoop == 4'b1101);
  c_rbar:       cover property (@(posedge clk) s_arvalid && s_arready && ar_bar);
  c_wunique:    cover property (@(posedge clk) s_awvalid && s_awready && s_awsnoop == 3'b000 && shareable(s_awdomain));
  c_wlu:        cover property (@(posedge clk) s_awvalid && s_awready && s_awsnoop == 3'b001);
  c_wnosnp:     cover property (@(posedge clk) s_awvalid && s_awready && !aw_bar && !shareable(s_awdomain));
  c_wbar:       cover property (@(posedge clk) s_awvalid && s_awready && aw_bar);
  c_rbar_wait:  cover property (@(posedge clk) s_arvalid && ar_bar && r_out != '0);
  c_wbar_wait:  cover property (@(posedge clk) s_awvalid && aw_bar && w_out != '0);
`endif
  wire unused = ^{s_arbar[1], s_awbar[1]};
endmodule
