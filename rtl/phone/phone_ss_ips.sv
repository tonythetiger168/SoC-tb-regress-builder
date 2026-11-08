// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_ss_ips -- the phone SoC's subsystem IP cluster (real-IP build)
// ----------------------------------------------------------------------------
// 13 open-ip-portfolio subsystem IPs (each an APB4 register wrapper around a
// core with an AXI4 manager port), on the phone SoC's ss APB port
// (0x1001_0000, one 4 KB slot each, SS_* in phone_soc_pkg) and on the NoC
// master ports they replace the traffic models of:
//
//   CPU_Cluster -> CPU      GPU -> GPU          NPU -> APU (IOMMU 0)
//   ISP -> ISP (IOMMU 1)    Display -> DISP (IOMMU 5)
//   Video_Codec x2 -> VDEC (IOMMU 3), VENC (IOMMU 4)
//   Modem -> MODEM          DMA -> DMA          Audio_DSP -> ADSP
//   Sensor_Hub + Interrupt_Controller + Timer_WDT -> SCP, through
//   phone_aon_arb (the always-on cluster)
//
// ICP, CONN, UFS and SEC stay traffic models. The interrupt controller takes
// the SoC's peripheral / IOMMU interrupts (irq_in) and every subsystem IP's
// interrupt, and drives cpu_irq. m_* outputs of ports this cluster does not
// drive (ss_drives(m) = 0) are 0.
// ============================================================================
module phone_ss_ips
  import phone_soc_pkg::*;
(
  input  logic        aclk,
  input  logic        aresetn,
  // ss APB port (from phone_soc_top)
  input  logic [31:0] paddr,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  // AXI4 manager ports, indexed like phone_soc_top's m_* ports
  output logic [3:0]  m_awid     [NM],
  output logic [31:0] m_awaddr   [NM],
  output logic [7:0]  m_awlen    [NM],
  output logic [2:0]  m_awsize   [NM],
  output logic [1:0]  m_awburst  [NM],
  output logic [2:0]  m_awprot   [NM],
  output logic        m_awvalid  [NM],
  input  logic        m_awready  [NM],
  output logic [31:0] m_wdata    [NM],
  output logic [3:0]  m_wstrb    [NM],
  output logic        m_wlast    [NM],
  output logic        m_wvalid   [NM],
  input  logic        m_wready   [NM],
  input  logic [3:0]  m_bid      [NM],
  input  logic [1:0]  m_bresp    [NM],
  input  logic        m_bvalid   [NM],
  output logic        m_bready   [NM],
  output logic [3:0]  m_arid     [NM],
  output logic [31:0] m_araddr   [NM],
  output logic [7:0]  m_arlen    [NM],
  output logic [2:0]  m_arsize   [NM],
  output logic [1:0]  m_arburst  [NM],
  output logic [2:0]  m_arprot   [NM],
  output logic        m_arvalid  [NM],
  input  logic        m_arready  [NM],
  input  logic [3:0]  m_rid      [NM],
  input  logic [31:0] m_rdata    [NM],
  input  logic [1:0]  m_rresp    [NM],
  input  logic        m_rlast    [NM],
  input  logic        m_rvalid   [NM],
  output logic        m_rready   [NM],
  // interrupts
  input  logic [12:0] irq_in,
  output logic        cpu_irq,
  output logic        wdt_reset,
  output logic [SS_NSLOTS-1:0] ss_irq,
  // ISP sensor stream, display panel, sensor-hub samples
  input  logic        isp_sns_valid,
  input  logic [31:0] isp_sns_data,
  output logic        isp_sns_ready,
  output logic        pix_valid,
  output logic [31:0] pix_data,
  output logic        pix_hsync,
  output logic        pix_vsync,
  input  logic        pix_ready,
  input  logic        sh_sns_valid,
  input  logic [15:0] sh_sns_data
);
  // ---------------------------------------------------------------- APB
  logic        s_psel    [SS_NSLOTS];
  logic [31:0] s_prdata  [SS_NSLOTS];
  logic        s_pready  [SS_NSLOTS];
  logic        s_pslverr [SS_NSLOTS];
  apb_decoder #(.NSLOTS(SS_NSLOTS)) u_dec (
    .psel, .penable, .paddr, .prdata, .pready, .pslverr,
    .s_psel, .s_prdata, .s_pready, .s_pslverr
  );

  // ---------------------------------------------------------------- per-IP AXI

  logic [3:0]  a_awid     [SS_NSLOTS];
  logic [31:0] a_awaddr   [SS_NSLOTS];
  logic [7:0]  a_awlen    [SS_NSLOTS];
  logic [2:0]  a_awsize   [SS_NSLOTS];
  logic [1:0]  a_awburst  [SS_NSLOTS];
  logic [2:0]  a_awprot   [SS_NSLOTS];
  logic        a_awvalid  [SS_NSLOTS];
  logic        a_awready  [SS_NSLOTS];
  logic [31:0] a_wdata    [SS_NSLOTS];
  logic [3:0]  a_wstrb    [SS_NSLOTS];
  logic        a_wlast    [SS_NSLOTS];
  logic        a_wvalid   [SS_NSLOTS];
  logic        a_wready   [SS_NSLOTS];
  logic [3:0]  a_bid      [SS_NSLOTS];
  logic [1:0]  a_bresp    [SS_NSLOTS];
  logic        a_bvalid   [SS_NSLOTS];
  logic        a_bready   [SS_NSLOTS];
  logic [3:0]  a_arid     [SS_NSLOTS];
  logic [31:0] a_araddr   [SS_NSLOTS];
  logic [7:0]  a_arlen    [SS_NSLOTS];
  logic [2:0]  a_arsize   [SS_NSLOTS];
  logic [1:0]  a_arburst  [SS_NSLOTS];
  logic [2:0]  a_arprot   [SS_NSLOTS];
  logic        a_arvalid  [SS_NSLOTS];
  logic        a_arready  [SS_NSLOTS];
  logic [3:0]  a_rid      [SS_NSLOTS];
  logic [31:0] a_rdata    [SS_NSLOTS];
  logic [1:0]  a_rresp    [SS_NSLOTS];
  logic        a_rlast    [SS_NSLOTS];
  logic        a_rvalid   [SS_NSLOTS];
  logic        a_rready   [SS_NSLOTS];

  logic [31:0] intc_src;
  // irq_src: 0..12 SoC (SRAM, GPIO..TRNG, IOMMU 0..5), 13.. subsystem IPs except the controller itself
  // (SS_INTC = 11 is the last slot but one: 13..23 = slots 0..10, 24 = slot 12)
  assign intc_src = {7'b0, ss_irq[SS_TMR], ss_irq[SS_SENS:SS_CPU], irq_in};

  CPU_Cluster_apb u_cpu (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_CPU]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_CPU]),
    .PREADY(s_pready[SS_CPU]), .PSLVERR(s_pslverr[SS_CPU]), .irq(ss_irq[SS_CPU]),
    .m_awid(a_awid[SS_CPU]), .m_awaddr(a_awaddr[SS_CPU]), .m_awlen(a_awlen[SS_CPU]), .m_awsize(a_awsize[SS_CPU]),
    .m_awburst(a_awburst[SS_CPU]), .m_awprot(a_awprot[SS_CPU]), .m_awvalid(a_awvalid[SS_CPU]), .m_awready(a_awready[SS_CPU]),
    .m_wdata(a_wdata[SS_CPU]), .m_wstrb(a_wstrb[SS_CPU]), .m_wlast(a_wlast[SS_CPU]), .m_wvalid(a_wvalid[SS_CPU]),
    .m_wready(a_wready[SS_CPU]), .m_bid(a_bid[SS_CPU]), .m_bresp(a_bresp[SS_CPU]), .m_bvalid(a_bvalid[SS_CPU]),
    .m_bready(a_bready[SS_CPU]), .m_arid(a_arid[SS_CPU]), .m_araddr(a_araddr[SS_CPU]), .m_arlen(a_arlen[SS_CPU]),
    .m_arsize(a_arsize[SS_CPU]), .m_arburst(a_arburst[SS_CPU]), .m_arprot(a_arprot[SS_CPU]), .m_arvalid(a_arvalid[SS_CPU]),
    .m_arready(a_arready[SS_CPU]), .m_rid(a_rid[SS_CPU]), .m_rdata(a_rdata[SS_CPU]), .m_rresp(a_rresp[SS_CPU]),
    .m_rlast(a_rlast[SS_CPU]), .m_rvalid(a_rvalid[SS_CPU]), .m_rready(a_rready[SS_CPU])
  );

  GPU_apb u_gpu (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_GPU]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_GPU]),
    .PREADY(s_pready[SS_GPU]), .PSLVERR(s_pslverr[SS_GPU]), .irq(ss_irq[SS_GPU]),
    .m_awid(a_awid[SS_GPU]), .m_awaddr(a_awaddr[SS_GPU]), .m_awlen(a_awlen[SS_GPU]), .m_awsize(a_awsize[SS_GPU]),
    .m_awburst(a_awburst[SS_GPU]), .m_awprot(a_awprot[SS_GPU]), .m_awvalid(a_awvalid[SS_GPU]), .m_awready(a_awready[SS_GPU]),
    .m_wdata(a_wdata[SS_GPU]), .m_wstrb(a_wstrb[SS_GPU]), .m_wlast(a_wlast[SS_GPU]), .m_wvalid(a_wvalid[SS_GPU]),
    .m_wready(a_wready[SS_GPU]), .m_bid(a_bid[SS_GPU]), .m_bresp(a_bresp[SS_GPU]), .m_bvalid(a_bvalid[SS_GPU]),
    .m_bready(a_bready[SS_GPU]), .m_arid(a_arid[SS_GPU]), .m_araddr(a_araddr[SS_GPU]), .m_arlen(a_arlen[SS_GPU]),
    .m_arsize(a_arsize[SS_GPU]), .m_arburst(a_arburst[SS_GPU]), .m_arprot(a_arprot[SS_GPU]), .m_arvalid(a_arvalid[SS_GPU]),
    .m_arready(a_arready[SS_GPU]), .m_rid(a_rid[SS_GPU]), .m_rdata(a_rdata[SS_GPU]), .m_rresp(a_rresp[SS_GPU]),
    .m_rlast(a_rlast[SS_GPU]), .m_rvalid(a_rvalid[SS_GPU]), .m_rready(a_rready[SS_GPU])
  );

  NPU_apb u_npu (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_NPU]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_NPU]),
    .PREADY(s_pready[SS_NPU]), .PSLVERR(s_pslverr[SS_NPU]), .irq(ss_irq[SS_NPU]),
    .m_awid(a_awid[SS_NPU]), .m_awaddr(a_awaddr[SS_NPU]), .m_awlen(a_awlen[SS_NPU]), .m_awsize(a_awsize[SS_NPU]),
    .m_awburst(a_awburst[SS_NPU]), .m_awprot(a_awprot[SS_NPU]), .m_awvalid(a_awvalid[SS_NPU]), .m_awready(a_awready[SS_NPU]),
    .m_wdata(a_wdata[SS_NPU]), .m_wstrb(a_wstrb[SS_NPU]), .m_wlast(a_wlast[SS_NPU]), .m_wvalid(a_wvalid[SS_NPU]),
    .m_wready(a_wready[SS_NPU]), .m_bid(a_bid[SS_NPU]), .m_bresp(a_bresp[SS_NPU]), .m_bvalid(a_bvalid[SS_NPU]),
    .m_bready(a_bready[SS_NPU]), .m_arid(a_arid[SS_NPU]), .m_araddr(a_araddr[SS_NPU]), .m_arlen(a_arlen[SS_NPU]),
    .m_arsize(a_arsize[SS_NPU]), .m_arburst(a_arburst[SS_NPU]), .m_arprot(a_arprot[SS_NPU]), .m_arvalid(a_arvalid[SS_NPU]),
    .m_arready(a_arready[SS_NPU]), .m_rid(a_rid[SS_NPU]), .m_rdata(a_rdata[SS_NPU]), .m_rresp(a_rresp[SS_NPU]),
    .m_rlast(a_rlast[SS_NPU]), .m_rvalid(a_rvalid[SS_NPU]), .m_rready(a_rready[SS_NPU])
  );

  ISP_apb u_isp (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_ISP]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_ISP]),
    .PREADY(s_pready[SS_ISP]), .PSLVERR(s_pslverr[SS_ISP]), .irq(ss_irq[SS_ISP]),
    .sns_valid(isp_sns_valid), .sns_data(isp_sns_data), .sns_ready(isp_sns_ready),
    .m_awid(a_awid[SS_ISP]), .m_awaddr(a_awaddr[SS_ISP]), .m_awlen(a_awlen[SS_ISP]), .m_awsize(a_awsize[SS_ISP]),
    .m_awburst(a_awburst[SS_ISP]), .m_awprot(a_awprot[SS_ISP]), .m_awvalid(a_awvalid[SS_ISP]), .m_awready(a_awready[SS_ISP]),
    .m_wdata(a_wdata[SS_ISP]), .m_wstrb(a_wstrb[SS_ISP]), .m_wlast(a_wlast[SS_ISP]), .m_wvalid(a_wvalid[SS_ISP]),
    .m_wready(a_wready[SS_ISP]), .m_bid(a_bid[SS_ISP]), .m_bresp(a_bresp[SS_ISP]), .m_bvalid(a_bvalid[SS_ISP]),
    .m_bready(a_bready[SS_ISP]), .m_arid(a_arid[SS_ISP]), .m_araddr(a_araddr[SS_ISP]), .m_arlen(a_arlen[SS_ISP]),
    .m_arsize(a_arsize[SS_ISP]), .m_arburst(a_arburst[SS_ISP]), .m_arprot(a_arprot[SS_ISP]), .m_arvalid(a_arvalid[SS_ISP]),
    .m_arready(a_arready[SS_ISP]), .m_rid(a_rid[SS_ISP]), .m_rdata(a_rdata[SS_ISP]), .m_rresp(a_rresp[SS_ISP]),
    .m_rlast(a_rlast[SS_ISP]), .m_rvalid(a_rvalid[SS_ISP]), .m_rready(a_rready[SS_ISP])
  );

  Display_Controller_apb u_disp (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_DISP]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_DISP]),
    .PREADY(s_pready[SS_DISP]), .PSLVERR(s_pslverr[SS_DISP]), .irq(ss_irq[SS_DISP]),
    .pix_valid(pix_valid), .pix_data(pix_data), .pix_hsync(pix_hsync), .pix_vsync(pix_vsync), .pix_ready(pix_ready),
    .m_awid(a_awid[SS_DISP]), .m_awaddr(a_awaddr[SS_DISP]), .m_awlen(a_awlen[SS_DISP]), .m_awsize(a_awsize[SS_DISP]),
    .m_awburst(a_awburst[SS_DISP]), .m_awprot(a_awprot[SS_DISP]), .m_awvalid(a_awvalid[SS_DISP]), .m_awready(a_awready[SS_DISP]),
    .m_wdata(a_wdata[SS_DISP]), .m_wstrb(a_wstrb[SS_DISP]), .m_wlast(a_wlast[SS_DISP]), .m_wvalid(a_wvalid[SS_DISP]),
    .m_wready(a_wready[SS_DISP]), .m_bid(a_bid[SS_DISP]), .m_bresp(a_bresp[SS_DISP]), .m_bvalid(a_bvalid[SS_DISP]),
    .m_bready(a_bready[SS_DISP]), .m_arid(a_arid[SS_DISP]), .m_araddr(a_araddr[SS_DISP]), .m_arlen(a_arlen[SS_DISP]),
    .m_arsize(a_arsize[SS_DISP]), .m_arburst(a_arburst[SS_DISP]), .m_arprot(a_arprot[SS_DISP]), .m_arvalid(a_arvalid[SS_DISP]),
    .m_arready(a_arready[SS_DISP]), .m_rid(a_rid[SS_DISP]), .m_rdata(a_rdata[SS_DISP]), .m_rresp(a_rresp[SS_DISP]),
    .m_rlast(a_rlast[SS_DISP]), .m_rvalid(a_rvalid[SS_DISP]), .m_rready(a_rready[SS_DISP])
  );

  Video_Codec_apb u_vdec (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_VDEC]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_VDEC]),
    .PREADY(s_pready[SS_VDEC]), .PSLVERR(s_pslverr[SS_VDEC]), .irq(ss_irq[SS_VDEC]),
    .m_awid(a_awid[SS_VDEC]), .m_awaddr(a_awaddr[SS_VDEC]), .m_awlen(a_awlen[SS_VDEC]), .m_awsize(a_awsize[SS_VDEC]),
    .m_awburst(a_awburst[SS_VDEC]), .m_awprot(a_awprot[SS_VDEC]), .m_awvalid(a_awvalid[SS_VDEC]), .m_awready(a_awready[SS_VDEC]),
    .m_wdata(a_wdata[SS_VDEC]), .m_wstrb(a_wstrb[SS_VDEC]), .m_wlast(a_wlast[SS_VDEC]), .m_wvalid(a_wvalid[SS_VDEC]),
    .m_wready(a_wready[SS_VDEC]), .m_bid(a_bid[SS_VDEC]), .m_bresp(a_bresp[SS_VDEC]), .m_bvalid(a_bvalid[SS_VDEC]),
    .m_bready(a_bready[SS_VDEC]), .m_arid(a_arid[SS_VDEC]), .m_araddr(a_araddr[SS_VDEC]), .m_arlen(a_arlen[SS_VDEC]),
    .m_arsize(a_arsize[SS_VDEC]), .m_arburst(a_arburst[SS_VDEC]), .m_arprot(a_arprot[SS_VDEC]), .m_arvalid(a_arvalid[SS_VDEC]),
    .m_arready(a_arready[SS_VDEC]), .m_rid(a_rid[SS_VDEC]), .m_rdata(a_rdata[SS_VDEC]), .m_rresp(a_rresp[SS_VDEC]),
    .m_rlast(a_rlast[SS_VDEC]), .m_rvalid(a_rvalid[SS_VDEC]), .m_rready(a_rready[SS_VDEC])
  );

  Video_Codec_apb u_venc (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_VENC]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_VENC]),
    .PREADY(s_pready[SS_VENC]), .PSLVERR(s_pslverr[SS_VENC]), .irq(ss_irq[SS_VENC]),
    .m_awid(a_awid[SS_VENC]), .m_awaddr(a_awaddr[SS_VENC]), .m_awlen(a_awlen[SS_VENC]), .m_awsize(a_awsize[SS_VENC]),
    .m_awburst(a_awburst[SS_VENC]), .m_awprot(a_awprot[SS_VENC]), .m_awvalid(a_awvalid[SS_VENC]), .m_awready(a_awready[SS_VENC]),
    .m_wdata(a_wdata[SS_VENC]), .m_wstrb(a_wstrb[SS_VENC]), .m_wlast(a_wlast[SS_VENC]), .m_wvalid(a_wvalid[SS_VENC]),
    .m_wready(a_wready[SS_VENC]), .m_bid(a_bid[SS_VENC]), .m_bresp(a_bresp[SS_VENC]), .m_bvalid(a_bvalid[SS_VENC]),
    .m_bready(a_bready[SS_VENC]), .m_arid(a_arid[SS_VENC]), .m_araddr(a_araddr[SS_VENC]), .m_arlen(a_arlen[SS_VENC]),
    .m_arsize(a_arsize[SS_VENC]), .m_arburst(a_arburst[SS_VENC]), .m_arprot(a_arprot[SS_VENC]), .m_arvalid(a_arvalid[SS_VENC]),
    .m_arready(a_arready[SS_VENC]), .m_rid(a_rid[SS_VENC]), .m_rdata(a_rdata[SS_VENC]), .m_rresp(a_rresp[SS_VENC]),
    .m_rlast(a_rlast[SS_VENC]), .m_rvalid(a_rvalid[SS_VENC]), .m_rready(a_rready[SS_VENC])
  );

  Modem_apb u_modem (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_MODEM]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_MODEM]),
    .PREADY(s_pready[SS_MODEM]), .PSLVERR(s_pslverr[SS_MODEM]), .irq(ss_irq[SS_MODEM]),
    .m_awid(a_awid[SS_MODEM]), .m_awaddr(a_awaddr[SS_MODEM]), .m_awlen(a_awlen[SS_MODEM]), .m_awsize(a_awsize[SS_MODEM]),
    .m_awburst(a_awburst[SS_MODEM]), .m_awprot(a_awprot[SS_MODEM]), .m_awvalid(a_awvalid[SS_MODEM]), .m_awready(a_awready[SS_MODEM]),
    .m_wdata(a_wdata[SS_MODEM]), .m_wstrb(a_wstrb[SS_MODEM]), .m_wlast(a_wlast[SS_MODEM]), .m_wvalid(a_wvalid[SS_MODEM]),
    .m_wready(a_wready[SS_MODEM]), .m_bid(a_bid[SS_MODEM]), .m_bresp(a_bresp[SS_MODEM]), .m_bvalid(a_bvalid[SS_MODEM]),
    .m_bready(a_bready[SS_MODEM]), .m_arid(a_arid[SS_MODEM]), .m_araddr(a_araddr[SS_MODEM]), .m_arlen(a_arlen[SS_MODEM]),
    .m_arsize(a_arsize[SS_MODEM]), .m_arburst(a_arburst[SS_MODEM]), .m_arprot(a_arprot[SS_MODEM]), .m_arvalid(a_arvalid[SS_MODEM]),
    .m_arready(a_arready[SS_MODEM]), .m_rid(a_rid[SS_MODEM]), .m_rdata(a_rdata[SS_MODEM]), .m_rresp(a_rresp[SS_MODEM]),
    .m_rlast(a_rlast[SS_MODEM]), .m_rvalid(a_rvalid[SS_MODEM]), .m_rready(a_rready[SS_MODEM])
  );

  DMA_apb u_dma (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_DMA]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_DMA]),
    .PREADY(s_pready[SS_DMA]), .PSLVERR(s_pslverr[SS_DMA]), .irq(ss_irq[SS_DMA]),
    .m_awid(a_awid[SS_DMA]), .m_awaddr(a_awaddr[SS_DMA]), .m_awlen(a_awlen[SS_DMA]), .m_awsize(a_awsize[SS_DMA]),
    .m_awburst(a_awburst[SS_DMA]), .m_awprot(a_awprot[SS_DMA]), .m_awvalid(a_awvalid[SS_DMA]), .m_awready(a_awready[SS_DMA]),
    .m_wdata(a_wdata[SS_DMA]), .m_wstrb(a_wstrb[SS_DMA]), .m_wlast(a_wlast[SS_DMA]), .m_wvalid(a_wvalid[SS_DMA]),
    .m_wready(a_wready[SS_DMA]), .m_bid(a_bid[SS_DMA]), .m_bresp(a_bresp[SS_DMA]), .m_bvalid(a_bvalid[SS_DMA]),
    .m_bready(a_bready[SS_DMA]), .m_arid(a_arid[SS_DMA]), .m_araddr(a_araddr[SS_DMA]), .m_arlen(a_arlen[SS_DMA]),
    .m_arsize(a_arsize[SS_DMA]), .m_arburst(a_arburst[SS_DMA]), .m_arprot(a_arprot[SS_DMA]), .m_arvalid(a_arvalid[SS_DMA]),
    .m_arready(a_arready[SS_DMA]), .m_rid(a_rid[SS_DMA]), .m_rdata(a_rdata[SS_DMA]), .m_rresp(a_rresp[SS_DMA]),
    .m_rlast(a_rlast[SS_DMA]), .m_rvalid(a_rvalid[SS_DMA]), .m_rready(a_rready[SS_DMA])
  );

  Audio_DSP_apb u_adsp (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_ADSP]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_ADSP]),
    .PREADY(s_pready[SS_ADSP]), .PSLVERR(s_pslverr[SS_ADSP]), .irq(ss_irq[SS_ADSP]),
    .m_awid(a_awid[SS_ADSP]), .m_awaddr(a_awaddr[SS_ADSP]), .m_awlen(a_awlen[SS_ADSP]), .m_awsize(a_awsize[SS_ADSP]),
    .m_awburst(a_awburst[SS_ADSP]), .m_awprot(a_awprot[SS_ADSP]), .m_awvalid(a_awvalid[SS_ADSP]), .m_awready(a_awready[SS_ADSP]),
    .m_wdata(a_wdata[SS_ADSP]), .m_wstrb(a_wstrb[SS_ADSP]), .m_wlast(a_wlast[SS_ADSP]), .m_wvalid(a_wvalid[SS_ADSP]),
    .m_wready(a_wready[SS_ADSP]), .m_bid(a_bid[SS_ADSP]), .m_bresp(a_bresp[SS_ADSP]), .m_bvalid(a_bvalid[SS_ADSP]),
    .m_bready(a_bready[SS_ADSP]), .m_arid(a_arid[SS_ADSP]), .m_araddr(a_araddr[SS_ADSP]), .m_arlen(a_arlen[SS_ADSP]),
    .m_arsize(a_arsize[SS_ADSP]), .m_arburst(a_arburst[SS_ADSP]), .m_arprot(a_arprot[SS_ADSP]), .m_arvalid(a_arvalid[SS_ADSP]),
    .m_arready(a_arready[SS_ADSP]), .m_rid(a_rid[SS_ADSP]), .m_rdata(a_rdata[SS_ADSP]), .m_rresp(a_rresp[SS_ADSP]),
    .m_rlast(a_rlast[SS_ADSP]), .m_rvalid(a_rvalid[SS_ADSP]), .m_rready(a_rready[SS_ADSP])
  );

  Sensor_Hub_apb u_sens (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_SENS]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_SENS]),
    .PREADY(s_pready[SS_SENS]), .PSLVERR(s_pslverr[SS_SENS]), .irq(ss_irq[SS_SENS]),
    .sns_valid(sh_sns_valid), .sns_data(sh_sns_data),
    .m_awid(a_awid[SS_SENS]), .m_awaddr(a_awaddr[SS_SENS]), .m_awlen(a_awlen[SS_SENS]), .m_awsize(a_awsize[SS_SENS]),
    .m_awburst(a_awburst[SS_SENS]), .m_awprot(a_awprot[SS_SENS]), .m_awvalid(a_awvalid[SS_SENS]), .m_awready(a_awready[SS_SENS]),
    .m_wdata(a_wdata[SS_SENS]), .m_wstrb(a_wstrb[SS_SENS]), .m_wlast(a_wlast[SS_SENS]), .m_wvalid(a_wvalid[SS_SENS]),
    .m_wready(a_wready[SS_SENS]), .m_bid(a_bid[SS_SENS]), .m_bresp(a_bresp[SS_SENS]), .m_bvalid(a_bvalid[SS_SENS]),
    .m_bready(a_bready[SS_SENS]), .m_arid(a_arid[SS_SENS]), .m_araddr(a_araddr[SS_SENS]), .m_arlen(a_arlen[SS_SENS]),
    .m_arsize(a_arsize[SS_SENS]), .m_arburst(a_arburst[SS_SENS]), .m_arprot(a_arprot[SS_SENS]), .m_arvalid(a_arvalid[SS_SENS]),
    .m_arready(a_arready[SS_SENS]), .m_rid(a_rid[SS_SENS]), .m_rdata(a_rdata[SS_SENS]), .m_rresp(a_rresp[SS_SENS]),
    .m_rlast(a_rlast[SS_SENS]), .m_rvalid(a_rvalid[SS_SENS]), .m_rready(a_rready[SS_SENS])
  );

  Interrupt_Controller_apb u_intc (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_INTC]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_INTC]),
    .PREADY(s_pready[SS_INTC]), .PSLVERR(s_pslverr[SS_INTC]), .irq(ss_irq[SS_INTC]),
    .irq_src(intc_src), .cpu_irq(cpu_irq),
    .m_awid(a_awid[SS_INTC]), .m_awaddr(a_awaddr[SS_INTC]), .m_awlen(a_awlen[SS_INTC]), .m_awsize(a_awsize[SS_INTC]),
    .m_awburst(a_awburst[SS_INTC]), .m_awprot(a_awprot[SS_INTC]), .m_awvalid(a_awvalid[SS_INTC]), .m_awready(a_awready[SS_INTC]),
    .m_wdata(a_wdata[SS_INTC]), .m_wstrb(a_wstrb[SS_INTC]), .m_wlast(a_wlast[SS_INTC]), .m_wvalid(a_wvalid[SS_INTC]),
    .m_wready(a_wready[SS_INTC]), .m_bid(a_bid[SS_INTC]), .m_bresp(a_bresp[SS_INTC]), .m_bvalid(a_bvalid[SS_INTC]),
    .m_bready(a_bready[SS_INTC]), .m_arid(a_arid[SS_INTC]), .m_araddr(a_araddr[SS_INTC]), .m_arlen(a_arlen[SS_INTC]),
    .m_arsize(a_arsize[SS_INTC]), .m_arburst(a_arburst[SS_INTC]), .m_arprot(a_arprot[SS_INTC]), .m_arvalid(a_arvalid[SS_INTC]),
    .m_arready(a_arready[SS_INTC]), .m_rid(a_rid[SS_INTC]), .m_rdata(a_rdata[SS_INTC]), .m_rresp(a_rresp[SS_INTC]),
    .m_rlast(a_rlast[SS_INTC]), .m_rvalid(a_rvalid[SS_INTC]), .m_rready(a_rready[SS_INTC])
  );

  Timer_WDT_apb u_tmr (
    .PCLK(aclk), .PRESETN(aresetn), .PSEL(s_psel[SS_TMR]), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr[11:0]), .PWDATA(pwdata), .PSTRB(pstrb), .PRDATA(s_prdata[SS_TMR]),
    .PREADY(s_pready[SS_TMR]), .PSLVERR(s_pslverr[SS_TMR]), .irq(ss_irq[SS_TMR]),
    .wdt_reset(wdt_reset),
    .m_awid(a_awid[SS_TMR]), .m_awaddr(a_awaddr[SS_TMR]), .m_awlen(a_awlen[SS_TMR]), .m_awsize(a_awsize[SS_TMR]),
    .m_awburst(a_awburst[SS_TMR]), .m_awprot(a_awprot[SS_TMR]), .m_awvalid(a_awvalid[SS_TMR]), .m_awready(a_awready[SS_TMR]),
    .m_wdata(a_wdata[SS_TMR]), .m_wstrb(a_wstrb[SS_TMR]), .m_wlast(a_wlast[SS_TMR]), .m_wvalid(a_wvalid[SS_TMR]),
    .m_wready(a_wready[SS_TMR]), .m_bid(a_bid[SS_TMR]), .m_bresp(a_bresp[SS_TMR]), .m_bvalid(a_bvalid[SS_TMR]),
    .m_bready(a_bready[SS_TMR]), .m_arid(a_arid[SS_TMR]), .m_araddr(a_araddr[SS_TMR]), .m_arlen(a_arlen[SS_TMR]),
    .m_arsize(a_arsize[SS_TMR]), .m_arburst(a_arburst[SS_TMR]), .m_arprot(a_arprot[SS_TMR]), .m_arvalid(a_arvalid[SS_TMR]),
    .m_arready(a_arready[SS_TMR]), .m_rid(a_rid[SS_TMR]), .m_rdata(a_rdata[SS_TMR]), .m_rresp(a_rresp[SS_TMR]),
    .m_rlast(a_rlast[SS_TMR]), .m_rvalid(a_rvalid[SS_TMR]), .m_rready(a_rready[SS_TMR])
  );

  // ---------------------------------------------------------------- ports
  localparam int NAON = 3;
  localparam int AON[NAON] = '{SS_SENS, SS_INTC, SS_TMR};

  for (genvar m = 0; m < NM; m++) begin : g_port
    if (m == M_SCP) begin : g_aon
      logic [3:0]  awid[NAON], arid[NAON], bid[NAON], rid[NAON], wstrb[NAON];
      logic [31:0] awaddr[NAON], araddr[NAON], wdata[NAON], rdata[NAON];
      logic [7:0]  awlen[NAON], arlen[NAON];
      logic [2:0]  awsize[NAON], arsize[NAON], awprot[NAON], arprot[NAON];
      logic [1:0]  awburst[NAON], arburst[NAON], bresp[NAON], rresp[NAON];
      logic        awvalid[NAON], awready[NAON], wlast[NAON], wvalid[NAON], wready[NAON];
      logic        bvalid[NAON], bready[NAON], arvalid[NAON], arready[NAON];
      logic        rlast[NAON], rvalid[NAON], rready[NAON];
      for (genvar k = 0; k < NAON; k++) begin : g_k

        assign awid[k] = a_awid[AON[k]];
        assign awaddr[k] = a_awaddr[AON[k]];
        assign awlen[k] = a_awlen[AON[k]];
        assign awsize[k] = a_awsize[AON[k]];
        assign awburst[k] = a_awburst[AON[k]];
        assign awprot[k] = a_awprot[AON[k]];
        assign awvalid[k] = a_awvalid[AON[k]];
        assign a_awready[AON[k]] = awready[k];
        assign wdata[k] = a_wdata[AON[k]];
        assign wstrb[k] = a_wstrb[AON[k]];
        assign wlast[k] = a_wlast[AON[k]];
        assign wvalid[k] = a_wvalid[AON[k]];
        assign a_wready[AON[k]] = wready[k];
        assign a_bid[AON[k]] = bid[k];
        assign a_bresp[AON[k]] = bresp[k];
        assign a_bvalid[AON[k]] = bvalid[k];
        assign bready[k] = a_bready[AON[k]];
        assign arid[k] = a_arid[AON[k]];
        assign araddr[k] = a_araddr[AON[k]];
        assign arlen[k] = a_arlen[AON[k]];
        assign arsize[k] = a_arsize[AON[k]];
        assign arburst[k] = a_arburst[AON[k]];
        assign arprot[k] = a_arprot[AON[k]];
        assign arvalid[k] = a_arvalid[AON[k]];
        assign a_arready[AON[k]] = arready[k];
        assign a_rid[AON[k]] = rid[k];
        assign a_rdata[AON[k]] = rdata[k];
        assign a_rresp[AON[k]] = rresp[k];
        assign a_rlast[AON[k]] = rlast[k];
        assign a_rvalid[AON[k]] = rvalid[k];
        assign rready[k] = a_rready[AON[k]];
      end
      phone_aon_arb #(.N(NAON)) u_aon_arb (
        .clk(aclk), .rst_n(aresetn),
        .awid, .awaddr, .awlen, .awsize, .awburst, .awprot, .awvalid, .awready, .wdata, .wstrb, .wlast, .wvalid, .wready, .bid, .bresp, .bvalid, .bready, .arid, .araddr, .arlen, .arsize, .arburst, .arprot, .arvalid, .arready, .rid, .rdata, .rresp, .rlast, .rvalid, .rready,
        .o_awid(m_awid[m]), .o_awaddr(m_awaddr[m]), .o_awlen(m_awlen[m]), .o_awsize(m_awsize[m]), .o_awburst(m_awburst[m]), .o_awprot(m_awprot[m]), .o_awvalid(m_awvalid[m]), .o_awready(m_awready[m]), .o_wdata(m_wdata[m]), .o_wstrb(m_wstrb[m]), .o_wlast(m_wlast[m]), .o_wvalid(m_wvalid[m]), .o_wready(m_wready[m]), .o_bid(m_bid[m]), .o_bresp(m_bresp[m]), .o_bvalid(m_bvalid[m]), .o_bready(m_bready[m]), .o_arid(m_arid[m]), .o_araddr(m_araddr[m]), .o_arlen(m_arlen[m]), .o_arsize(m_arsize[m]), .o_arburst(m_arburst[m]), .o_arprot(m_arprot[m]), .o_arvalid(m_arvalid[m]), .o_arready(m_arready[m]), .o_rid(m_rid[m]), .o_rdata(m_rdata[m]), .o_rresp(m_rresp[m]), .o_rlast(m_rlast[m]), .o_rvalid(m_rvalid[m]), .o_rready(m_rready[m])
      );
    end else begin : g_one
      localparam int S = (m == M_CPU) ? SS_CPU : (m == M_GPU) ? SS_GPU : (m == M_APU) ? SS_NPU :
                         (m == M_ISP) ? SS_ISP : (m == M_DISP) ? SS_DISP : (m == M_VDEC) ? SS_VDEC :
                         (m == M_VENC) ? SS_VENC : (m == M_MODEM) ? SS_MODEM : (m == M_DMA) ? SS_DMA :
                         (m == M_ADSP) ? SS_ADSP : -1;
      if (S >= 0) begin : g_ip
        assign m_awid[m] = a_awid[S];
        assign m_awaddr[m] = a_awaddr[S];
        assign m_awlen[m] = a_awlen[S];
        assign m_awsize[m] = a_awsize[S];
        assign m_awburst[m] = a_awburst[S];
        assign m_awprot[m] = a_awprot[S];
        assign m_awvalid[m] = a_awvalid[S];
        assign a_awready[S] = m_awready[m];
        assign m_wdata[m] = a_wdata[S];
        assign m_wstrb[m] = a_wstrb[S];
        assign m_wlast[m] = a_wlast[S];
        assign m_wvalid[m] = a_wvalid[S];
        assign a_wready[S] = m_wready[m];
        assign a_bid[S] = m_bid[m];
        assign a_bresp[S] = m_bresp[m];
        assign a_bvalid[S] = m_bvalid[m];
        assign m_bready[m] = a_bready[S];
        assign m_arid[m] = a_arid[S];
        assign m_araddr[m] = a_araddr[S];
        assign m_arlen[m] = a_arlen[S];
        assign m_arsize[m] = a_arsize[S];
        assign m_arburst[m] = a_arburst[S];
        assign m_arprot[m] = a_arprot[S];
        assign m_arvalid[m] = a_arvalid[S];
        assign a_arready[S] = m_arready[m];
        assign a_rid[S] = m_rid[m];
        assign a_rdata[S] = m_rdata[m];
        assign a_rresp[S] = m_rresp[m];
        assign a_rlast[S] = m_rlast[m];
        assign a_rvalid[S] = m_rvalid[m];
        assign m_rready[m] = a_rready[S];
      end else begin : g_none
        assign m_awid[m] = '0;
        assign m_awaddr[m] = '0;
        assign m_awlen[m] = '0;
        assign m_awsize[m] = '0;
        assign m_awburst[m] = '0;
        assign m_awprot[m] = '0;
        assign m_awvalid[m] = '0;
        assign m_wdata[m] = '0;
        assign m_wstrb[m] = '0;
        assign m_wlast[m] = '0;
        assign m_wvalid[m] = '0;
        assign m_bready[m] = '0;
        assign m_arid[m] = '0;
        assign m_araddr[m] = '0;
        assign m_arlen[m] = '0;
        assign m_arsize[m] = '0;
        assign m_arburst[m] = '0;
        assign m_arprot[m] = '0;
        assign m_arvalid[m] = '0;
        assign m_rready[m] = '0;
      end
    end
  end
endmodule
