// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_soc_top -- phone SoC DUT for the UVM testbench
// ----------------------------------------------------------------------------
//
//  15 subsystem AXI4 ports (testbench AXI master VIPs = traffic models)
//    CPU GPU ADSP MODEM CONN SCP UFS SEC DMA ----------------------+
//    APU ISP ICP VDEC VENC DISP --> phone_iommu (x6, TLB + walker) -+
//                                                                  |
//                                   phone_noc (4x4 mesh model) <---+
//                                     |            |          |
//            32 x LPDDR5 channel ports (AXI4)   boot SRAM   AXI->APB bridge
//            (testbench LPDDR5 slave VIPs)     (open-ip)        |
//                                                      apb_decoder, 4 KB slots:
//              0 GPIO  1 UART  2 ext APB (VIP)  3 I2C  4 SPI  5 PWM  6 TRNG
//              7..12 IOMMU 0..5 registers            (GPIO..TRNG: open-ip IPs)
//              0x1001_0000 segment: ss APB port (subsystem IP cluster registers)
//
// One clock (aclk), one active-low async reset. Master ports use 4-bit IDs;
// the IOMMU-backed masters must keep IDs below 8 (8..15 are the page-table
// walker's). LPDDR5 ports carry 8-bit IDs {master index, ID}.
// ============================================================================
module phone_soc_top
  import phone_soc_pkg::*;
#(
  parameter int UART_CLK_FREQ = 50_000_000,
  parameter int UART_BAUD     = 3_125_000
)(
  input  logic        aclk,
  input  logic        aresetn,

  // ---------------- subsystem AXI4 ports (DUT is the subordinate) ---------
  input  logic [3:0]  m_awid    [NM],
  input  logic [31:0] m_awaddr  [NM],
  input  logic [7:0]  m_awlen   [NM],
  input  logic [2:0]  m_awsize  [NM],
  input  logic [1:0]  m_awburst [NM],
  input  logic [2:0]  m_awprot  [NM],
  input  logic        m_awvalid [NM],
  output logic        m_awready [NM],
  input  logic [31:0] m_wdata   [NM],
  input  logic [3:0]  m_wstrb   [NM],
  input  logic        m_wlast   [NM],
  input  logic        m_wvalid  [NM],
  output logic        m_wready  [NM],
  output logic [3:0]  m_bid     [NM],
  output logic [1:0]  m_bresp   [NM],
  output logic        m_bvalid  [NM],
  input  logic        m_bready  [NM],
  input  logic [3:0]  m_arid    [NM],
  input  logic [31:0] m_araddr  [NM],
  input  logic [7:0]  m_arlen   [NM],
  input  logic [2:0]  m_arsize  [NM],
  input  logic [1:0]  m_arburst [NM],
  input  logic [2:0]  m_arprot  [NM],
  input  logic        m_arvalid [NM],
  output logic        m_arready [NM],
  output logic [3:0]  m_rid     [NM],
  output logic [31:0] m_rdata   [NM],
  output logic [1:0]  m_rresp   [NM],
  output logic        m_rlast   [NM],
  output logic        m_rvalid  [NM],
  input  logic        m_rready  [NM],

  // ---------------- LPDDR5 channel ports (DUT is the manager) -------------
  output logic [7:0]  ch_awid    [NCH],
  output logic [31:0] ch_awaddr  [NCH],
  output logic [7:0]  ch_awlen   [NCH],
  output logic [2:0]  ch_awsize  [NCH],
  output logic [1:0]  ch_awburst [NCH],
  output logic [2:0]  ch_awprot  [NCH],
  output logic        ch_awvalid [NCH],
  input  logic        ch_awready [NCH],
  output logic [31:0] ch_wdata   [NCH],
  output logic [3:0]  ch_wstrb   [NCH],
  output logic        ch_wlast   [NCH],
  output logic        ch_wvalid  [NCH],
  input  logic        ch_wready  [NCH],
  input  logic [7:0]  ch_bid     [NCH],
  input  logic [1:0]  ch_bresp   [NCH],
  input  logic        ch_bvalid  [NCH],
  output logic        ch_bready  [NCH],
  output logic [7:0]  ch_arid    [NCH],
  output logic [31:0] ch_araddr  [NCH],
  output logic [7:0]  ch_arlen   [NCH],
  output logic [2:0]  ch_arsize  [NCH],
  output logic [1:0]  ch_arburst [NCH],
  output logic [2:0]  ch_arprot  [NCH],
  output logic        ch_arvalid [NCH],
  input  logic        ch_arready [NCH],
  input  logic [7:0]  ch_rid     [NCH],
  input  logic [31:0] ch_rdata   [NCH],
  input  logic [1:0]  ch_rresp   [NCH],
  input  logic        ch_rlast   [NCH],
  input  logic        ch_rvalid  [NCH],
  output logic        ch_rready  [NCH],

  // ---------------- external APB completer port (slot 2) ------------------
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

  // ---------------- ss APB port: segment 1 (0x1001_0000, 64 KB) ----------
  output logic [31:0] ssp_paddr,
  output logic        ssp_psel,
  output logic        ssp_penable,
  output logic        ssp_pwrite,
  output logic [31:0] ssp_pwdata,
  output logic [3:0]  ssp_pstrb,
  output logic [2:0]  ssp_pprot,
  input  logic [31:0] ssp_prdata,
  input  logic        ssp_pready,
  input  logic        ssp_pslverr,

  // ---------------- pins ----------------
  inout  tri   [7:0]  gpio,
  input  logic        uart_rxd,
  output logic        uart_txd,
  inout  tri          i2c_sda,
  input  logic        i2c_scl,
  input  logic        spi_sclk,
  input  logic        spi_mosi,
  output logic        spi_miso,
  input  logic        spi_csn,
  output logic        pwm_out,
  output logic        pwm_n_out,
  input  logic [3:0]  trng_ro,
  // {IOMMU5..0, TRNG, PWM, SPI, I2C, UART, GPIO, SRAM protocol error}
  output logic [12:0] irq
);

  // ======================================================================
  // NoC master side (after the IOMMUs)
  // ======================================================================
  logic [3:0]  n_awid [NM];  logic [31:0] n_awaddr [NM]; logic [7:0] n_awlen [NM];
  logic [2:0]  n_awsize [NM]; logic [1:0] n_awburst [NM]; logic [2:0] n_awprot [NM];
  logic        n_awvalid [NM], n_awready [NM];
  logic [31:0] n_wdata [NM]; logic [3:0] n_wstrb [NM]; logic n_wlast [NM];
  logic        n_wvalid [NM], n_wready [NM];
  logic [3:0]  n_bid [NM]; logic [1:0] n_bresp [NM]; logic n_bvalid [NM], n_bready [NM];
  logic [3:0]  n_arid [NM];  logic [31:0] n_araddr [NM]; logic [7:0] n_arlen [NM];
  logic [2:0]  n_arsize [NM]; logic [1:0] n_arburst [NM]; logic [2:0] n_arprot [NM];
  logic        n_arvalid [NM], n_arready [NM];
  logic [3:0]  n_rid [NM]; logic [31:0] n_rdata [NM]; logic [1:0] n_rresp [NM];
  logic        n_rlast [NM], n_rvalid [NM], n_rready [NM];

  // IOMMU register ports
  logic        mmu_psel [NIOMMU];
  logic [31:0] mmu_prdata [NIOMMU];
  logic        mmu_pready [NIOMMU], mmu_pslverr [NIOMMU], mmu_irq [NIOMMU];
  logic [31:0] paddr, pwdata, prdata;
  logic        psel, penable, pwrite, pready, pslverr;
  logic [3:0]  pstrb;
  logic [2:0]  pprot;

  for (genvar m = 0; m < NM; m++) begin : g_m
    if (iommu_of(m) >= 0) begin : g_mmu
      localparam int I = iommu_of(m);
      phone_iommu #(.IDW(4)) u_iommu (
        .clk(aclk), .rst_n(aresetn),
        .u_awid(m_awid[m]), .u_awaddr(m_awaddr[m]), .u_awlen(m_awlen[m]), .u_awsize(m_awsize[m]),
        .u_awburst(m_awburst[m]), .u_awprot(m_awprot[m]), .u_awvalid(m_awvalid[m]), .u_awready(m_awready[m]),
        .u_wdata(m_wdata[m]), .u_wstrb(m_wstrb[m]), .u_wlast(m_wlast[m]), .u_wvalid(m_wvalid[m]),
        .u_wready(m_wready[m]),
        .u_bid(m_bid[m]), .u_bresp(m_bresp[m]), .u_bvalid(m_bvalid[m]), .u_bready(m_bready[m]),
        .u_arid(m_arid[m]), .u_araddr(m_araddr[m]), .u_arlen(m_arlen[m]), .u_arsize(m_arsize[m]),
        .u_arburst(m_arburst[m]), .u_arprot(m_arprot[m]), .u_arvalid(m_arvalid[m]), .u_arready(m_arready[m]),
        .u_rid(m_rid[m]), .u_rdata(m_rdata[m]), .u_rresp(m_rresp[m]), .u_rlast(m_rlast[m]),
        .u_rvalid(m_rvalid[m]), .u_rready(m_rready[m]),
        .d_awid(n_awid[m]), .d_awaddr(n_awaddr[m]), .d_awlen(n_awlen[m]), .d_awsize(n_awsize[m]),
        .d_awburst(n_awburst[m]), .d_awprot(n_awprot[m]), .d_awvalid(n_awvalid[m]), .d_awready(n_awready[m]),
        .d_wdata(n_wdata[m]), .d_wstrb(n_wstrb[m]), .d_wlast(n_wlast[m]), .d_wvalid(n_wvalid[m]),
        .d_wready(n_wready[m]),
        .d_bid(n_bid[m]), .d_bresp(n_bresp[m]), .d_bvalid(n_bvalid[m]), .d_bready(n_bready[m]),
        .d_arid(n_arid[m]), .d_araddr(n_araddr[m]), .d_arlen(n_arlen[m]), .d_arsize(n_arsize[m]),
        .d_arburst(n_arburst[m]), .d_arprot(n_arprot[m]), .d_arvalid(n_arvalid[m]), .d_arready(n_arready[m]),
        .d_rid(n_rid[m]), .d_rdata(n_rdata[m]), .d_rresp(n_rresp[m]), .d_rlast(n_rlast[m]),
        .d_rvalid(n_rvalid[m]), .d_rready(n_rready[m]),
        .psel(mmu_psel[I]), .penable(penable), .pwrite(pwrite), .paddr(paddr[11:0]),
        .pwdata(pwdata), .pstrb(pstrb), .prdata(mmu_prdata[I]), .pready(mmu_pready[I]),
        .pslverr(mmu_pslverr[I]), .irq(mmu_irq[I])
      );
    end else begin : g_direct
      assign n_awid[m] = m_awid[m];       assign n_awaddr[m] = m_awaddr[m];
      assign n_awlen[m] = m_awlen[m];     assign n_awsize[m] = m_awsize[m];
      assign n_awburst[m] = m_awburst[m]; assign n_awprot[m] = m_awprot[m];
      assign n_awvalid[m] = m_awvalid[m]; assign m_awready[m] = n_awready[m];
      assign n_wdata[m] = m_wdata[m];     assign n_wstrb[m] = m_wstrb[m];
      assign n_wlast[m] = m_wlast[m];     assign n_wvalid[m] = m_wvalid[m];
      assign m_wready[m] = n_wready[m];
      assign m_bid[m] = n_bid[m];         assign m_bresp[m] = n_bresp[m];
      assign m_bvalid[m] = n_bvalid[m];   assign n_bready[m] = m_bready[m];
      assign n_arid[m] = m_arid[m];       assign n_araddr[m] = m_araddr[m];
      assign n_arlen[m] = m_arlen[m];     assign n_arsize[m] = m_arsize[m];
      assign n_arburst[m] = m_arburst[m]; assign n_arprot[m] = m_arprot[m];
      assign n_arvalid[m] = m_arvalid[m]; assign m_arready[m] = n_arready[m];
      assign m_rid[m] = n_rid[m];         assign m_rdata[m] = n_rdata[m];
      assign m_rresp[m] = n_rresp[m];     assign m_rlast[m] = n_rlast[m];
      assign m_rvalid[m] = n_rvalid[m];   assign n_rready[m] = m_rready[m];
    end
  end

  // ======================================================================
  // NoC
  // ======================================================================
  logic [7:0]  s_awid [NS];  logic [31:0] s_awaddr [NS]; logic [7:0] s_awlen [NS];
  logic [2:0]  s_awsize [NS]; logic [1:0] s_awburst [NS]; logic [2:0] s_awprot [NS];
  logic        s_awvalid [NS], s_awready [NS];
  logic [31:0] s_wdata [NS]; logic [3:0] s_wstrb [NS]; logic s_wlast [NS];
  logic        s_wvalid [NS], s_wready [NS];
  logic [1:0]  s_bresp [NS]; logic s_bvalid [NS], s_bready [NS];
  logic [7:0]  s_arid [NS];  logic [31:0] s_araddr [NS]; logic [7:0] s_arlen [NS];
  logic [2:0]  s_arsize [NS]; logic [1:0] s_arburst [NS]; logic [2:0] s_arprot [NS];
  logic        s_arvalid [NS], s_arready [NS];
  logic [31:0] s_rdata [NS]; logic [1:0] s_rresp [NS]; logic s_rlast [NS];
  logic        s_rvalid [NS], s_rready [NS];

  phone_noc #(.MIDW(4)) u_noc (
    .clk(aclk), .rst_n(aresetn),
    .m_awid(n_awid), .m_awaddr(n_awaddr), .m_awlen(n_awlen), .m_awsize(n_awsize),
    .m_awburst(n_awburst), .m_awprot(n_awprot), .m_awvalid(n_awvalid), .m_awready(n_awready),
    .m_wdata(n_wdata), .m_wstrb(n_wstrb), .m_wlast(n_wlast), .m_wvalid(n_wvalid), .m_wready(n_wready),
    .m_bid(n_bid), .m_bresp(n_bresp), .m_bvalid(n_bvalid), .m_bready(n_bready),
    .m_arid(n_arid), .m_araddr(n_araddr), .m_arlen(n_arlen), .m_arsize(n_arsize),
    .m_arburst(n_arburst), .m_arprot(n_arprot), .m_arvalid(n_arvalid), .m_arready(n_arready),
    .m_rid(n_rid), .m_rdata(n_rdata), .m_rresp(n_rresp), .m_rlast(n_rlast), .m_rvalid(n_rvalid),
    .m_rready(n_rready),
    .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awprot, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bresp, .s_bvalid, .s_bready,
    .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arprot, .s_arvalid, .s_arready,
    .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready
  );

  // ======================================================================
  // LPDDR5 channel ports
  // ======================================================================
  for (genvar c = 0; c < NCH; c++) begin : g_ch
    assign ch_awid[c]    = s_awid[c];
    assign ch_awaddr[c]  = s_awaddr[c];
    assign ch_awlen[c]   = s_awlen[c];
    assign ch_awsize[c]  = s_awsize[c];
    assign ch_awburst[c] = s_awburst[c];
    assign ch_awprot[c]  = s_awprot[c];
    assign ch_awvalid[c] = s_awvalid[c];
    assign s_awready[c]  = ch_awready[c];
    assign ch_wdata[c]   = s_wdata[c];
    assign ch_wstrb[c]   = s_wstrb[c];
    assign ch_wlast[c]   = s_wlast[c];
    assign ch_wvalid[c]  = s_wvalid[c];
    assign s_wready[c]   = ch_wready[c];
    assign s_bresp[c]    = ch_bresp[c];
    assign s_bvalid[c]   = ch_bvalid[c];
    assign ch_bready[c]  = s_bready[c];
    assign ch_arid[c]    = s_arid[c];
    assign ch_araddr[c]  = s_araddr[c];
    assign ch_arlen[c]   = s_arlen[c];
    assign ch_arsize[c]  = s_arsize[c];
    assign ch_arburst[c] = s_arburst[c];
    assign ch_arprot[c]  = s_arprot[c];
    assign ch_arvalid[c] = s_arvalid[c];
    assign s_arready[c]  = ch_arready[c];
    assign s_rdata[c]    = ch_rdata[c];
    assign s_rresp[c]    = ch_rresp[c];
    assign s_rlast[c]    = ch_rlast[c];
    assign s_rvalid[c]   = ch_rvalid[c];
    assign ch_rready[c]  = s_rready[c];
  end

  // ======================================================================
  // boot SRAM (open-ip AXI4_top, 256 x 32)
  // ======================================================================
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

  // ======================================================================
  // infra / peri: AXI-to-APB bridge + APB decoder + peripherals
  // ======================================================================
  logic [7:0] apb_bid, apb_rid;
  axi2apb_bridge #(.IDW(8)) u_bridge (
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

  // segment 0 (PADDR[16] = 0): on-chip slots; segment 1: ss APB port
  logic        seg1, psel0;
  logic [31:0] prdata0;
  logic        pready0, pslverr0;
  assign seg1    = paddr[16];
  assign psel0   = psel & ~seg1;
  assign prdata  = seg1 ? ssp_prdata  : prdata0;
  assign pready  = seg1 ? ssp_pready  : pready0;
  assign pslverr = seg1 ? ssp_pslverr : pslverr0;
  assign ssp_paddr   = paddr;
  assign ssp_psel    = psel & seg1;
  assign ssp_penable = penable & seg1;
  assign ssp_pwrite  = pwrite;
  assign ssp_pwdata  = pwdata;
  assign ssp_pstrb   = pstrb;
  assign ssp_pprot   = pprot;

  apb_decoder #(.NSLOTS(APB_NSLOTS)) u_apb_dec (
    .psel(psel0), .penable, .paddr, .prdata(prdata0), .pready(pready0), .pslverr(pslverr0),
    .s_psel(sl_psel), .s_prdata(sl_prdata), .s_pready(sl_pready), .s_pslverr(sl_pslverr)
  );

  GPIO_apb u_gpio (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_GPIO]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_GPIO]), .PREADY(sl_pready[APB_GPIO]),
    .PSLVERR(sl_pslverr[APB_GPIO]), .irq(irq[1]), .gpio(gpio)
  );

  UART_apb #(.CLK_FREQ(UART_CLK_FREQ), .BAUD(UART_BAUD)) u_uart (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_UART]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_UART]), .PREADY(sl_pready[APB_UART]),
    .PSLVERR(sl_pslverr[APB_UART]), .irq(irq[2]), .rxd(uart_rxd), .txd(uart_txd)
  );

  I2C_apb u_i2c (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_I2C]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_I2C]), .PREADY(sl_pready[APB_I2C]),
    .PSLVERR(sl_pslverr[APB_I2C]), .irq(irq[3]), .sda(i2c_sda), .scl(i2c_scl)
  );

  SPI_apb u_spi (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_SPI]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_SPI]), .PREADY(sl_pready[APB_SPI]),
    .PSLVERR(sl_pslverr[APB_SPI]), .irq(irq[4]),
    .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .csn(spi_csn)
  );

  PWM_apb u_pwm (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_PWM]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_PWM]), .PREADY(sl_pready[APB_PWM]),
    .PSLVERR(sl_pslverr[APB_PWM]), .irq(irq[5]), .pwm_out(pwm_out), .pwm_n_out(pwm_n_out)
  );

  logic trng_ent_fips, trng_raw_valid, trng_raw_bit, trng_es_ok, trng_alert;
  TRNG_apb u_trng (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(sl_psel[APB_TRNG]), .PENABLE(penable),
    .PWRITE(pwrite), .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb),
    .PRDATA(sl_prdata[APB_TRNG]), .PREADY(sl_pready[APB_TRNG]),
    .PSLVERR(sl_pslverr[APB_TRNG]), .irq(irq[6]), .ro_in(trng_ro),
    .ent_fips(trng_ent_fips), .raw_valid(trng_raw_valid), .raw_bit(trng_raw_bit),
    .es_ok(trng_es_ok), .alert(trng_alert)
  );

  for (genvar i = 0; i < NIOMMU; i++) begin : g_mmu_apb
    assign mmu_psel[i]               = sl_psel[APB_IOMMU + i];
    assign sl_prdata[APB_IOMMU + i]  = mmu_prdata[i];
    assign sl_pready[APB_IOMMU + i]  = mmu_pready[i];
    assign sl_pslverr[APB_IOMMU + i] = mmu_pslverr[i];
    assign irq[7 + i]                = mmu_irq[i];
  end

  // external APB completer (slot 2)
  assign apbx_paddr   = paddr;
  assign apbx_psel    = sl_psel[APB_EXT];
  assign apbx_penable = penable & sl_psel[APB_EXT];
  assign apbx_pwrite  = pwrite;
  assign apbx_pwdata  = pwdata;
  assign apbx_pstrb   = pstrb;
  assign apbx_pprot   = pprot;
  assign sl_prdata[APB_EXT]  = apbx_prdata;
  assign sl_pready[APB_EXT]  = apbx_pready;
  assign sl_pslverr[APB_EXT] = apbx_pslverr;
endmodule
