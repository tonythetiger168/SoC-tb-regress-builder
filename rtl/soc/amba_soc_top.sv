// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// amba_soc_top -- small AMBA SoC used as the DUT of the UVM testbench
// ----------------------------------------------------------------------------
//
//   m0 (AXI4, CPU port) ---+                        +--> S0 on-chip SRAM 1 KB  (open-ip AXI4_top)
//                          +--> soc_axi_ic (2x3) ---+--> S1 axi2apb_bridge --> apb_decoder
//   m1 (AXI4, DMA port) ---+                        |        slot0 GPIO_apb  (open-ip)
//                                                   |        slot1 UART_apb  (open-ip)
//                                                   |        slot2 external APB port
//                                                   +--> S2 external AXI4 master port (DDR)
//
// All logic runs on one clock (aclk) and one active-low async reset.
// Ports m0/m1 are AXI4 slaves with 4-bit IDs; the DDR port is an AXI4 master
// with 5-bit IDs ({master index, master ID}).
// ============================================================================
module amba_soc_top
  import soc_pkg::*;
#(
  parameter int UART_CLK_FREQ = 50_000_000,
  parameter int UART_BAUD     = 3_125_000      // 16 clocks per bit at 50 MHz
)(
  input  logic        aclk,
  input  logic        aresetn,

  // ---------------- AXI4 slave ports m0/m1 (index = master) ----------------
  input  logic [3:0]  m_awid    [2],
  input  logic [31:0] m_awaddr  [2],
  input  logic [7:0]  m_awlen   [2],
  input  logic [2:0]  m_awsize  [2],
  input  logic [1:0]  m_awburst [2],
  input  logic [2:0]  m_awprot  [2],
  input  logic        m_awvalid [2],
  output logic        m_awready [2],
  input  logic [31:0] m_wdata   [2],
  input  logic [3:0]  m_wstrb   [2],
  input  logic        m_wlast   [2],
  input  logic        m_wvalid  [2],
  output logic        m_wready  [2],
  output logic [3:0]  m_bid     [2],
  output logic [1:0]  m_bresp   [2],
  output logic        m_bvalid  [2],
  input  logic        m_bready  [2],
  input  logic [3:0]  m_arid    [2],
  input  logic [31:0] m_araddr  [2],
  input  logic [7:0]  m_arlen   [2],
  input  logic [2:0]  m_arsize  [2],
  input  logic [1:0]  m_arburst [2],
  input  logic [2:0]  m_arprot  [2],
  input  logic        m_arvalid [2],
  output logic        m_arready [2],
  output logic [3:0]  m_rid     [2],
  output logic [31:0] m_rdata   [2],
  output logic [1:0]  m_rresp   [2],
  output logic        m_rlast   [2],
  output logic        m_rvalid  [2],
  input  logic        m_rready  [2],

  // ---------------- external memory port (AXI4 master) ---------------------
  output logic [4:0]  ddr_awid,
  output logic [31:0] ddr_awaddr,
  output logic [7:0]  ddr_awlen,
  output logic [2:0]  ddr_awsize,
  output logic [1:0]  ddr_awburst,
  output logic [2:0]  ddr_awprot,
  output logic        ddr_awvalid,
  input  logic        ddr_awready,
  output logic [31:0] ddr_wdata,
  output logic [3:0]  ddr_wstrb,
  output logic        ddr_wlast,
  output logic        ddr_wvalid,
  input  logic        ddr_wready,
  input  logic [4:0]  ddr_bid,
  input  logic [1:0]  ddr_bresp,
  input  logic        ddr_bvalid,
  output logic        ddr_bready,
  output logic [4:0]  ddr_arid,
  output logic [31:0] ddr_araddr,
  output logic [7:0]  ddr_arlen,
  output logic [2:0]  ddr_arsize,
  output logic [1:0]  ddr_arburst,
  output logic [2:0]  ddr_arprot,
  output logic        ddr_arvalid,
  input  logic        ddr_arready,
  input  logic [4:0]  ddr_rid,
  input  logic [31:0] ddr_rdata,
  input  logic [1:0]  ddr_rresp,
  input  logic        ddr_rlast,
  input  logic        ddr_rvalid,
  output logic        ddr_rready,

  // ---------------- external APB completer port (slot 2) -------------------
  output logic [31:0] apbx_paddr,
  output logic        apbx_psel,
  output logic        apbx_penable,
  output logic        apbx_pwrite,
  output logic [31:0] apbx_pwdata,
  output logic [3:0]  apbx_pstrb,
  output logic [2:0]  apbx_pprot,
  input  logic [31:0] apbx_prdata,
  input  logic        apbx_pready,
  input  logic        apbx_pslverr,

  // ---------------- peripheral pins / interrupts ---------------------------
  inout  tri   [7:0]  gpio,
  input  logic        uart_rxd,
  output logic        uart_txd,
  output logic [2:0]  irq             // {UART, GPIO, SRAM protocol error}
);

  // ---------------- interconnect slave-side wires --------------------------
  logic [4:0]  s_awid [3];  logic [31:0] s_awaddr [3]; logic [7:0] s_awlen [3];
  logic [2:0]  s_awsize [3]; logic [1:0] s_awburst [3]; logic [2:0] s_awprot [3];
  logic        s_awvalid [3], s_awready [3];
  logic [31:0] s_wdata [3]; logic [3:0] s_wstrb [3]; logic s_wlast [3];
  logic        s_wvalid [3], s_wready [3];
  logic [1:0]  s_bresp [3]; logic s_bvalid [3], s_bready [3];
  logic [4:0]  s_arid [3];  logic [31:0] s_araddr [3]; logic [7:0] s_arlen [3];
  logic [2:0]  s_arsize [3]; logic [1:0] s_arburst [3]; logic [2:0] s_arprot [3];
  logic        s_arvalid [3], s_arready [3];
  logic [31:0] s_rdata [3]; logic [1:0] s_rresp [3]; logic s_rlast [3];
  logic        s_rvalid [3], s_rready [3];

  soc_axi_ic #(.MIDW(4)) u_ic (
    .clk(aclk), .rst_n(aresetn),
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready,
    .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awprot, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bresp, .s_bvalid, .s_bready,
    .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arprot, .s_arvalid, .s_arready,
    .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready
  );

  // ---------------- S0: on-chip SRAM (open-ip AXI4_top, 256 x 32) -----------
  logic [3:0] sram_bid, sram_rid;
  AXI4_top #(.DW(32), .AW(32)) u_sram (
    .clk(aclk), .rst_n(aresetn),
    .awid(s_awid[S_SRAM][3:0]), .awaddr(s_awaddr[S_SRAM]), .awlen(s_awlen[S_SRAM]),
    .awsize(s_awsize[S_SRAM]), .awburst(s_awburst[S_SRAM]),
    .awvalid(s_awvalid[S_SRAM]), .awready(s_awready[S_SRAM]),
    .wdata(s_wdata[S_SRAM]), .wstrb(s_wstrb[S_SRAM]), .wlast(s_wlast[S_SRAM]),
    .wvalid(s_wvalid[S_SRAM]), .wready(s_wready[S_SRAM]),
    .bid(sram_bid), .bresp(s_bresp[S_SRAM]), .bvalid(s_bvalid[S_SRAM]), .bready(s_bready[S_SRAM]),
    .arid(s_arid[S_SRAM][3:0]), .araddr(s_araddr[S_SRAM]), .arlen(s_arlen[S_SRAM]),
    .arsize(s_arsize[S_SRAM]), .arburst(s_arburst[S_SRAM]),
    .arvalid(s_arvalid[S_SRAM]), .arready(s_arready[S_SRAM]),
    .rid(sram_rid), .rdata(s_rdata[S_SRAM]), .rresp(s_rresp[S_SRAM]), .rlast(s_rlast[S_SRAM]),
    .rvalid(s_rvalid[S_SRAM]), .rready(s_rready[S_SRAM]),
    .irq(irq[0])
  );

  // ---------------- S1: AXI-to-APB bridge + APB subsystem -------------------
  logic [31:0] paddr, pwdata, prdata;
  logic        psel, penable, pwrite, pready, pslverr;
  logic [3:0]  pstrb;
  logic [2:0]  pprot;
  logic [4:0]  apb_bid, apb_rid;

  axi2apb_bridge #(.IDW(5)) u_bridge (
    .clk(aclk), .rst_n(aresetn),
    .awid(s_awid[S_APB]), .awaddr(s_awaddr[S_APB]), .awlen(s_awlen[S_APB]),
    .awsize(s_awsize[S_APB]), .awburst(s_awburst[S_APB]), .awprot(s_awprot[S_APB]),
    .awvalid(s_awvalid[S_APB]), .awready(s_awready[S_APB]),
    .wdata(s_wdata[S_APB]), .wstrb(s_wstrb[S_APB]), .wlast(s_wlast[S_APB]),
    .wvalid(s_wvalid[S_APB]), .wready(s_wready[S_APB]),
    .bid(apb_bid), .bresp(s_bresp[S_APB]), .bvalid(s_bvalid[S_APB]), .bready(s_bready[S_APB]),
    .arid(s_arid[S_APB]), .araddr(s_araddr[S_APB]), .arlen(s_arlen[S_APB]),
    .arsize(s_arsize[S_APB]), .arburst(s_arburst[S_APB]), .arprot(s_arprot[S_APB]),
    .arvalid(s_arvalid[S_APB]), .arready(s_arready[S_APB]),
    .rid(apb_rid), .rdata(s_rdata[S_APB]), .rresp(s_rresp[S_APB]), .rlast(s_rlast[S_APB]),
    .rvalid(s_rvalid[S_APB]), .rready(s_rready[S_APB]),
    .paddr, .psel, .penable, .pwrite, .pwdata, .pstrb, .pprot,
    .prdata, .pready, .pslverr
  );

  logic        sl_psel    [APB_NSLOTS];
  logic [31:0] sl_prdata  [APB_NSLOTS];
  logic        sl_pready  [APB_NSLOTS];
  logic        sl_pslverr [APB_NSLOTS];

  apb_decoder #(.NSLOTS(APB_NSLOTS)) u_apb_dec (
    .psel, .penable, .paddr, .prdata, .pready, .pslverr,
    .s_psel(sl_psel), .s_prdata(sl_prdata), .s_pready(sl_pready), .s_pslverr(sl_pslverr)
  );

  GPIO_apb u_gpio (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_SLOT_GPIO]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_SLOT_GPIO]), .PREADY(sl_pready[APB_SLOT_GPIO]),
    .PSLVERR(sl_pslverr[APB_SLOT_GPIO]), .irq(irq[1]), .gpio(gpio)
  );

  UART_apb #(.CLK_FREQ(UART_CLK_FREQ), .BAUD(UART_BAUD)) u_uart (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_SLOT_UART]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_SLOT_UART]), .PREADY(sl_pready[APB_SLOT_UART]),
    .PSLVERR(sl_pslverr[APB_SLOT_UART]), .irq(irq[2]), .rxd(uart_rxd), .txd(uart_txd)
  );

  // external APB completer (slot 2)
  assign apbx_paddr   = paddr;
  assign apbx_psel    = sl_psel[APB_SLOT_EXT];
  assign apbx_penable = penable & sl_psel[APB_SLOT_EXT];
  assign apbx_pwrite  = pwrite;
  assign apbx_pwdata  = pwdata;
  assign apbx_pstrb   = pstrb;
  assign apbx_pprot   = pprot;
  assign sl_prdata[APB_SLOT_EXT]  = apbx_prdata;
  assign sl_pready[APB_SLOT_EXT]  = apbx_pready;
  assign sl_pslverr[APB_SLOT_EXT] = apbx_pslverr;

  // ---------------- S2: external memory port --------------------------------
  assign ddr_awid    = s_awid[S_DDR];
  assign ddr_awaddr  = s_awaddr[S_DDR];
  assign ddr_awlen   = s_awlen[S_DDR];
  assign ddr_awsize  = s_awsize[S_DDR];
  assign ddr_awburst = s_awburst[S_DDR];
  assign ddr_awprot  = s_awprot[S_DDR];
  assign ddr_awvalid = s_awvalid[S_DDR];
  assign s_awready[S_DDR] = ddr_awready;
  assign ddr_wdata   = s_wdata[S_DDR];
  assign ddr_wstrb   = s_wstrb[S_DDR];
  assign ddr_wlast   = s_wlast[S_DDR];
  assign ddr_wvalid  = s_wvalid[S_DDR];
  assign s_wready[S_DDR] = ddr_wready;
  assign s_bresp[S_DDR]  = ddr_bresp;
  assign s_bvalid[S_DDR] = ddr_bvalid;
  assign ddr_bready  = s_bready[S_DDR];
  assign ddr_arid    = s_arid[S_DDR];
  assign ddr_araddr  = s_araddr[S_DDR];
  assign ddr_arlen   = s_arlen[S_DDR];
  assign ddr_arsize  = s_arsize[S_DDR];
  assign ddr_arburst = s_arburst[S_DDR];
  assign ddr_arprot  = s_arprot[S_DDR];
  assign ddr_arvalid = s_arvalid[S_DDR];
  assign s_arready[S_DDR] = ddr_arready;
  assign s_rdata[S_DDR]  = ddr_rdata;
  assign s_rresp[S_DDR]  = ddr_rresp;
  assign s_rlast[S_DDR]  = ddr_rlast;
  assign s_rvalid[S_DDR] = ddr_rvalid;
  assign ddr_rready  = s_rready[S_DDR];

endmodule
