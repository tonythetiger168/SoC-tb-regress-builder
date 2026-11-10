// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_ddr4_chan: one DDR4 channel behind a NoC slave port (socgen
// memories[].model: ddr4)
// ----------------------------------------------------------------------------
//   s_* (aclk) -> AXI_Async_Bridge_top -> DDR4_JEDEC_AXI_top (ck) -> ddr4_phy_beh
//   -> NDEV x16 devices
// The CDC (AXI_Async_Bridge) and the controller are open-ip-portfolio IPs,
// copied into the generated SoC by socgen. The channel runs on its own CK (TCK_PS, default 628 ps ~ DDR4-3200) so the
// DRAM timing is real nanoseconds whatever the NoC clock is.
// Devices: Micron's DDR4 model when the build defines MICRON_DDR4 (see
// vip/micron/README.md: the files are fetched at build time, never committed),
// otherwise open-ip-portfolio's ddr4_dev_model (same pins, JEDEC checks).
// Timing parameters are in nCK at TCK_PS (defaults: DDR4-3200AA, 8 Gb x16).
// At the end of the run it prints
//   DRAM <NAME> act <n> hit <n> ref <n> rd <n> wr <n> errors <n>
// ============================================================================
`timescale 1ps/1ps
module soc_ddr4_chan #(
  parameter string NAME     = "ddr",
  parameter int    IDW      = 8,
  parameter int    NDEV     = 1,
  parameter int    TCK_PS   = 628,
  parameter int    CL       = 22,
  parameter int    CWL      = 16,
  parameter int    T_RCD    = 22,
  parameter int    T_RP     = 22,
  parameter int    T_RAS    = 52,
  parameter int    T_RC     = 74,
  parameter int    T_RRD_S  = 9,
  parameter int    T_RRD_L  = 11,
  parameter int    T_FAW    = 48,
  parameter int    T_CCD_S  = 4,
  parameter int    T_CCD_L  = 8,
  parameter int    T_WTR_S  = 4,
  parameter int    T_WTR_L  = 12,
  parameter int    T_WR     = 24,
  parameter int    T_RTP    = 12,
  parameter int    T_RFC    = 560,
  parameter int    T_REFI   = 12480,
  // power-up waits: short by default; the Micron model may want the JEDEC values
  parameter int    T_RESET  = 64,
  parameter int    T_CKE    = 64,
  parameter int    T_XPR    = 576,
  parameter int    T_ZQINIT = 1024
)(
  input  logic           aclk,
  input  logic           aresetn,
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
  input  logic           s_rready
);
  localparam int DQW = 16 * NDEV;
  localparam int BB  = DQW;

  // ---------------- DRAM clock and reset ----------------
  logic ck = 1'b0;
  always #(TCK_PS / 2) ck = ~ck;
  logic [1:0] rst_s;
  always_ff @(posedge ck or negedge aresetn)
    if (!aresetn) rst_s <= '0; else rst_s <= {rst_s[0], 1'b1};
  wire ck_rst_n = rst_s[1];

  // ---------------- CDC ----------------
  logic [IDW-1:0] awid, bid, arid, rid;
  logic [31:0]    awaddr, wdata, araddr, rdata;
  logic [7:0]     awlen, arlen;
  logic [2:0]     awsize, arsize;
  logic [1:0]     awburst, arburst, bresp, rresp;
  logic [3:0]     wstrb;
  logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rlast, rvalid, rready;

  AXI_Async_Bridge_top #(.IDW(IDW)) u_cdc (
    .s_clk(aclk), .s_rst_n(aresetn),
    .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bid, .s_bresp, .s_bvalid, .s_bready,
    .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arvalid, .s_arready,
    .s_rid, .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready,
    .m_clk(ck), .m_rst_n(ck_rst_n),
    .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
    .m_awvalid(awvalid), .m_awready(awready),
    .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
    .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
    .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
    .m_arvalid(arvalid), .m_arready(arready),
    .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready),
    .resp_err()
  );

  // ---------------- controller ----------------
  logic p_reset_n, p_cke, p_odt, p_cs_n, p_act_n, p_ras_n, p_cas_n, p_we_n, p_wr, p_rvalid;
  logic [1:0]       p_bg, p_ba;
  logic [13:0]      p_a;
  logic [8*DQW-1:0] p_wdata, p_rdata;
  logic [BB-1:0]    p_wbe;
  logic             init_done, err_irq;
  logic [15:0]      n_rd, n_wr, n_err, n_act, n_hit, n_ref;

  DDR4_JEDEC_AXI_top #(
    .NDEV(NDEV), .IDW(IDW), .CL(CL), .CWL(CWL), .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS),
    .T_RC(T_RC), .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L), .T_FAW(T_FAW), .T_CCD_S(T_CCD_S),
    .T_CCD_L(T_CCD_L), .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L), .T_WR(T_WR), .T_RTP(T_RTP),
    .T_RFC(T_RFC), .T_REFI(T_REFI), .T_XPR(T_XPR), .T_ZQINIT(T_ZQINIT),
    .T_RESET(T_RESET), .T_CKE(T_CKE)
  ) u_ctrl (
    .clk(ck), .rst_n(ck_rst_n),
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize), .s_awburst(awburst),
    .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
    .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
    .s_arvalid(arvalid), .s_arready(arready),
    .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
    .p_reset_n, .p_cke, .p_odt, .p_cs_n, .p_act_n, .p_ras_n, .p_cas_n, .p_we_n,
    .p_bg, .p_ba, .p_a, .p_wr, .p_wdata, .p_wbe, .p_rvalid, .p_rdata,
    .init_done, .n_rd, .n_wr, .n_err, .n_act, .n_hit, .n_ref, .err_irq
  );

  // ---------------- PHY and devices ----------------
  wire ck_t, ck_c, reset_n, cke, odt, cs_n, act_n, ras_n, cas_n, we_n;
  wire [1:0]       bg, ba;
  wire [13:0]      a;
  wire [DQW-1:0]   dq;
  wire [DQW/8-1:0] dqs_t, dqs_c, dm_n;

  ddr4_phy_beh #(.NDEV(NDEV), .CL(CL), .CWL(CWL), .TCK_PS(TCK_PS)) u_phy (
    .clk(ck), .p_reset_n, .p_cke, .p_odt, .p_cs_n, .p_act_n, .p_ras_n, .p_cas_n, .p_we_n,
    .p_bg, .p_ba, .p_a, .p_wr, .p_wdata, .p_wbe, .p_rvalid, .p_rdata,
    .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
    .we_n_a14(we_n), .bg, .ba, .a, .dq, .dqs_t, .dqs_c, .dm_n
  );

  // device-model violations (ddr4_dev_model ERRORS), summed over the devices;
  // tb_top turns a change into a UVM_ERROR
  int unsigned dev_err [NDEV];
  int unsigned errors;
  always_comb begin
    errors = 0;
    for (int d = 0; d < NDEV; d++) errors += dev_err[d];
  end
  for (genvar d = 0; d < NDEV; d++) begin : g_dev
`ifdef MICRON_DDR4
    micron_ddr4_dev #(.TCK_PS(TCK_PS)) u_dram (
`else
    ddr4_dev_model #(.TCK_PS(TCK_PS), .CL(CL), .CWL(CWL), .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS),
      .T_RC(T_RC), .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L), .T_FAW(T_FAW), .T_CCD_S(T_CCD_S),
      .T_CCD_L(T_CCD_L), .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L), .T_WR(T_WR), .T_RTP(T_RTP),
      .T_RFC(T_RFC), .T_REFI(T_REFI), .T_XPR(T_XPR)) u_dram (
`endif
      .ck_t, .ck_c, .reset_n, .cke, .odt, .cs_n, .act_n, .ras_n_a16(ras_n), .cas_n_a15(cas_n),
      .we_n_a14(we_n), .bg, .ba, .a, .dq(dq[16*d +: 16]), .dqs_t(dqs_t[2*d +: 2]),
      .dqs_c(dqs_c[2*d +: 2]), .dm_n(dm_n[2*d +: 2])
    );
`ifndef MICRON_DDR4
    always @(u_dram.ERRORS) dev_err[d] = u_dram.ERRORS;
`else
    initial dev_err[d] = 0;
`endif
  end

  final begin
    $display("DRAM %s act %0d hit %0d ref %0d rd %0d wr %0d errors %0d model %s",
             NAME, n_act, n_hit, n_ref, n_rd, n_wr, errors,
`ifdef MICRON_DDR4
             "micron"
`else
             "ddr4_dev_model"
`endif
             );
  end
endmodule
