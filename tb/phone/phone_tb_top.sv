// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_tb_top -- top module of the phone SoC UVM testbench
// ============================================================================
`timescale 1ns/1ps
module phone_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import phone_soc_pkg::*;
  import phone_test_pkg::*;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  always #1 aclk = ~aclk;                 // 500 MHz NoC / memory-port clock
  initial begin
    repeat (10) @(posedge aclk);
    aresetn <= 1'b1;
  end

  // ---------------- interfaces ----------------
  axi4_if m_if  [NM]  (.aclk(aclk), .aresetn(aresetn));   // subsystem ports
  axi4_if ch_if [NCH] (.aclk(aclk), .aresetn(aresetn));   // LPDDR5 channel ports
  apb_if  apbx_if     (.pclk(aclk), .presetn(aresetn));   // external APB slot
  apb_if  apbi_if     (.pclk(aclk), .presetn(aresetn));   // internal APB bus (monitor)

  // ---------------- DUT-side arrays ----------------
  logic [3:0]  m_awid [NM], m_bid [NM], m_arid [NM], m_rid [NM];
  logic [31:0] m_awaddr [NM], m_wdata [NM], m_araddr [NM], m_rdata [NM];
  logic [7:0]  m_awlen [NM], m_arlen [NM];
  logic [2:0]  m_awsize [NM], m_arsize [NM], m_awprot [NM], m_arprot [NM];
  logic [1:0]  m_awburst [NM], m_arburst [NM], m_bresp [NM], m_rresp [NM];
  logic [3:0]  m_wstrb [NM];
  logic        m_awvalid [NM], m_awready [NM], m_wlast [NM], m_wvalid [NM], m_wready [NM];
  logic        m_bvalid [NM], m_bready [NM], m_arvalid [NM], m_arready [NM];
  logic        m_rlast [NM], m_rvalid [NM], m_rready [NM];

  logic [7:0]  c_awid [NCH], c_bid [NCH], c_arid [NCH], c_rid [NCH];
  logic [31:0] c_awaddr [NCH], c_wdata [NCH], c_araddr [NCH], c_rdata [NCH];
  logic [7:0]  c_awlen [NCH], c_arlen [NCH];
  logic [2:0]  c_awsize [NCH], c_arsize [NCH], c_awprot [NCH], c_arprot [NCH];
  logic [1:0]  c_awburst [NCH], c_arburst [NCH], c_bresp [NCH], c_rresp [NCH];
  logic [3:0]  c_wstrb [NCH];
  logic        c_awvalid [NCH], c_awready [NCH], c_wlast [NCH], c_wvalid [NCH], c_wready [NCH];
  logic        c_bvalid [NCH], c_bready [NCH], c_arvalid [NCH], c_arready [NCH];
  logic        c_rlast [NCH], c_rvalid [NCH], c_rready [NCH];

  tri   [7:0]  gpio;
  tri1         i2c_sda;
  logic        uart_txd, spi_miso, pwm_out, pwm_n_out;
  logic [12:0] irq;

  // ss APB port (segment 1, 0x1001_0000)
  logic [31:0] ssp_paddr, ssp_pwdata, ssp_prdata;
  logic [3:0]  ssp_pstrb;
  logic [2:0]  ssp_pprot;
  logic        ssp_psel, ssp_penable, ssp_pwrite, ssp_pready, ssp_pslverr;

`ifdef PHONE_REAL_IPS
  // ---------------- real-IP build: subsystem IP cluster ----------------
  // The open-ip subsystem IPs drive the master ports ss_drives(m) marks; the
  // testbench's agents on those ports are passive (monitor only).
  localparam bit REAL_IPS = 1'b1;
  logic [3:0]  s_awid [NM], s_arid [NM], s_wstrb [NM];
  logic [31:0] s_awaddr [NM], s_wdata [NM], s_araddr [NM];
  logic [7:0]  s_awlen [NM], s_arlen [NM];
  logic [2:0]  s_awsize [NM], s_arsize [NM], s_awprot [NM], s_arprot [NM];
  logic [1:0]  s_awburst [NM], s_arburst [NM];
  logic        s_awvalid [NM], s_wlast [NM], s_wvalid [NM], s_bready [NM], s_arvalid [NM], s_rready [NM];
  logic        cpu_irq, wdt_reset, isp_sns_ready, pix_valid, pix_hsync, pix_vsync;
  logic [31:0] pix_data;
  logic [SS_NSLOTS-1:0] ss_irq;
  logic [15:0] sh_cnt;
  logic        sh_valid;
  // sensor-hub samples: one every 16 clocks, a slow ramp
  always_ff @(posedge aclk or negedge aresetn)
    if (!aresetn) sh_cnt <= '0; else sh_cnt <= sh_cnt + 16'd1;
  assign sh_valid = (sh_cnt[3:0] == 4'hF);

  phone_ss_ips u_ss (
    .aclk, .aresetn,
    .paddr(ssp_paddr), .psel(ssp_psel), .penable(ssp_penable), .pwrite(ssp_pwrite),
    .pwdata(ssp_pwdata), .pstrb(ssp_pstrb), .prdata(ssp_prdata), .pready(ssp_pready),
    .pslverr(ssp_pslverr),
    .m_awid(s_awid), .m_awaddr(s_awaddr), .m_awlen(s_awlen), .m_awsize(s_awsize),
    .m_awburst(s_awburst), .m_awprot(s_awprot), .m_awvalid(s_awvalid), .m_awready,
    .m_wdata(s_wdata), .m_wstrb(s_wstrb), .m_wlast(s_wlast), .m_wvalid(s_wvalid), .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready(s_bready),
    .m_arid(s_arid), .m_araddr(s_araddr), .m_arlen(s_arlen), .m_arsize(s_arsize),
    .m_arburst(s_arburst), .m_arprot(s_arprot), .m_arvalid(s_arvalid), .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready(s_rready),
    .irq_in(irq), .cpu_irq, .wdt_reset, .ss_irq,
    .isp_sns_valid(1'b0), .isp_sns_data(32'h0), .isp_sns_ready,      // ISP uses its test pattern
    .pix_valid, .pix_data, .pix_hsync, .pix_vsync, .pix_ready(1'b1),   // panel always ready
    .sh_sns_valid(sh_valid), .sh_sns_data({4'h0, sh_cnt[15:4]})
  );
`else
  localparam bit REAL_IPS = 1'b0;
  // no subsystem IP cluster: segment 1 answers PSLVERR
  assign ssp_prdata  = 32'h0;
  assign ssp_pready  = 1'b1;
  assign ssp_pslverr = 1'b1;
`endif

  for (genvar i = 0; i < NM; i++) begin : g_m
    assign m_awid[i]    = m_if[i].awid[3:0];
    assign m_awaddr[i]  = m_if[i].awaddr;
    assign m_awlen[i]   = m_if[i].awlen;
    assign m_awsize[i]  = m_if[i].awsize;
    assign m_awburst[i] = m_if[i].awburst;
    assign m_awprot[i]  = m_if[i].awprot;
    assign m_awvalid[i] = m_if[i].awvalid;
    assign m_if[i].awready = m_awready[i];
    assign m_wdata[i]   = m_if[i].wdata;
    assign m_wstrb[i]   = m_if[i].wstrb;
    assign m_wlast[i]   = m_if[i].wlast;
    assign m_wvalid[i]  = m_if[i].wvalid;
    assign m_if[i].wready = m_wready[i];
    assign m_if[i].bid    = {4'h0, m_bid[i]};
    assign m_if[i].bresp  = m_bresp[i];
    assign m_if[i].bvalid = m_bvalid[i];
    assign m_bready[i]  = m_if[i].bready;
    assign m_arid[i]    = m_if[i].arid[3:0];
    assign m_araddr[i]  = m_if[i].araddr;
    assign m_arlen[i]   = m_if[i].arlen;
    assign m_arsize[i]  = m_if[i].arsize;
    assign m_arburst[i] = m_if[i].arburst;
    assign m_arprot[i]  = m_if[i].arprot;
    assign m_arvalid[i] = m_if[i].arvalid;
    assign m_if[i].arready = m_arready[i];
    assign m_if[i].rid    = {4'h0, m_rid[i]};
    assign m_if[i].rdata  = m_rdata[i];
    assign m_if[i].rresp  = m_rresp[i];
    assign m_if[i].rlast  = m_rlast[i];
    assign m_if[i].rvalid = m_rvalid[i];
    assign m_rready[i]  = m_if[i].rready;
`ifdef PHONE_REAL_IPS
    if (ss_drives(i)) begin : g_ip       // the IP drives the port, the agent only monitors
      assign m_if[i].awid = {4'h0, s_awid[i]};   assign m_if[i].awaddr = s_awaddr[i];
      assign m_if[i].awlen = s_awlen[i];         assign m_if[i].awsize = s_awsize[i];
      assign m_if[i].awburst = s_awburst[i];     assign m_if[i].awprot = s_awprot[i];
      assign m_if[i].awvalid = s_awvalid[i];     assign m_if[i].wdata = s_wdata[i];
      assign m_if[i].wstrb = s_wstrb[i];         assign m_if[i].wlast = s_wlast[i];
      assign m_if[i].wvalid = s_wvalid[i];       assign m_if[i].bready = s_bready[i];
      assign m_if[i].arid = {4'h0, s_arid[i]};   assign m_if[i].araddr = s_araddr[i];
      assign m_if[i].arlen = s_arlen[i];         assign m_if[i].arsize = s_arsize[i];
      assign m_if[i].arburst = s_arburst[i];     assign m_if[i].arprot = s_arprot[i];
      assign m_if[i].arvalid = s_arvalid[i];     assign m_if[i].rready = s_rready[i];
      assign m_if[i].awlock = 1'b0;  assign m_if[i].arlock = 1'b0;
      assign m_if[i].awcache = 4'h0; assign m_if[i].arcache = 4'h0;
    end
`endif
    axi4_sva #(.NAME($sformatf("m%0d", i))) u_sva (m_if[i]);
    initial uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_agent*", i),
                                                 "vif", m_if[i]);
  end

  for (genvar c = 0; c < NCH; c++) begin : g_ch
    assign ch_if[c].awid    = c_awid[c];
    assign ch_if[c].awaddr  = c_awaddr[c];
    assign ch_if[c].awlen   = c_awlen[c];
    assign ch_if[c].awsize  = c_awsize[c];
    assign ch_if[c].awburst = c_awburst[c];
    assign ch_if[c].awprot  = c_awprot[c];
    assign ch_if[c].awvalid = c_awvalid[c];
    assign c_awready[c]     = ch_if[c].awready;
    assign ch_if[c].wdata   = c_wdata[c];
    assign ch_if[c].wstrb   = c_wstrb[c];
    assign ch_if[c].wlast   = c_wlast[c];
    assign ch_if[c].wvalid  = c_wvalid[c];
    assign c_wready[c]      = ch_if[c].wready;
    assign c_bid[c]         = ch_if[c].bid;
    assign c_bresp[c]       = ch_if[c].bresp;
    assign c_bvalid[c]      = ch_if[c].bvalid;
    assign ch_if[c].bready  = c_bready[c];
    assign ch_if[c].arid    = c_arid[c];
    assign ch_if[c].araddr  = c_araddr[c];
    assign ch_if[c].arlen   = c_arlen[c];
    assign ch_if[c].arsize  = c_arsize[c];
    assign ch_if[c].arburst = c_arburst[c];
    assign ch_if[c].arprot  = c_arprot[c];
    assign ch_if[c].arvalid = c_arvalid[c];
    assign c_arready[c]     = ch_if[c].arready;
    assign c_rid[c]         = ch_if[c].rid;
    assign c_rdata[c]       = ch_if[c].rdata;
    assign c_rresp[c]       = ch_if[c].rresp;
    assign c_rlast[c]       = ch_if[c].rlast;
    assign c_rvalid[c]      = ch_if[c].rvalid;
    assign ch_if[c].rready  = c_rready[c];
    assign ch_if[c].awlock = 1'b0;  assign ch_if[c].arlock = 1'b0;
    assign ch_if[c].awcache = 4'h0; assign ch_if[c].arcache = 4'h0;
    axi4_sva #(.NAME($sformatf("ch%0d", c))) u_sva (ch_if[c]);
    initial uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.ch%0d_agent*", c),
                                                 "vif", ch_if[c]);
  end

  phone_soc_top #(.UART_CLK_FREQ(500_000_000), .UART_BAUD(31_250_000)) dut (
    .aclk, .aresetn,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready,
    .ch_awid(c_awid), .ch_awaddr(c_awaddr), .ch_awlen(c_awlen), .ch_awsize(c_awsize),
    .ch_awburst(c_awburst), .ch_awprot(c_awprot), .ch_awvalid(c_awvalid), .ch_awready(c_awready),
    .ch_wdata(c_wdata), .ch_wstrb(c_wstrb), .ch_wlast(c_wlast), .ch_wvalid(c_wvalid), .ch_wready(c_wready),
    .ch_bid(c_bid), .ch_bresp(c_bresp), .ch_bvalid(c_bvalid), .ch_bready(c_bready),
    .ch_arid(c_arid), .ch_araddr(c_araddr), .ch_arlen(c_arlen), .ch_arsize(c_arsize),
    .ch_arburst(c_arburst), .ch_arprot(c_arprot), .ch_arvalid(c_arvalid), .ch_arready(c_arready),
    .ch_rid(c_rid), .ch_rdata(c_rdata), .ch_rresp(c_rresp), .ch_rlast(c_rlast), .ch_rvalid(c_rvalid),
    .ch_rready(c_rready),
    .apbx_paddr(apbx_if.paddr), .apbx_psel(apbx_if.psel), .apbx_penable(apbx_if.penable),
    .apbx_pwrite(apbx_if.pwrite), .apbx_pwdata(apbx_if.pwdata), .apbx_pstrb(apbx_if.pstrb),
    .apbx_pprot(apbx_if.pprot), .apbx_prdata(apbx_if.prdata), .apbx_pready(apbx_if.pready),
    .apbx_pslverr(apbx_if.pslverr),
    .ssp_paddr, .ssp_psel, .ssp_penable, .ssp_pwrite, .ssp_pwdata, .ssp_pstrb, .ssp_pprot,
    .ssp_prdata, .ssp_pready, .ssp_pslverr,
    .gpio, .uart_rxd(uart_txd), .uart_txd,                     // UART looped back
    .i2c_sda, .i2c_scl(1'b1),                                  // I2C bus idle
    .spi_sclk(1'b0), .spi_mosi(1'b0), .spi_miso, .spi_csn(1'b1), // SPI deselected
    .pwm_out, .pwm_n_out, .trng_ro(4'b0), .irq
  );

  // internal APB bus (bridge side of the decoder), observed only
  assign apbi_if.paddr   = dut.paddr;
  assign apbi_if.psel    = dut.psel;
  assign apbi_if.penable = dut.penable;
  assign apbi_if.pwrite  = dut.pwrite;
  assign apbi_if.pwdata  = dut.pwdata;
  assign apbi_if.pstrb   = dut.pstrb;
  assign apbi_if.pprot   = dut.pprot;
  assign apbi_if.prdata  = dut.prdata;
  assign apbi_if.pready  = dut.pready;
  assign apbi_if.pslverr = dut.pslverr;

  apb_sva #(.NAME("apbx")) u_apbx_sva (apbx_if);
  apb_sva #(.NAME("apbi")) u_apbi_sva (apbi_if);

  initial begin
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apbx_agent*", "vif", apbx_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb_mon_agent*", "vif", apbi_if);
    uvm_config_db#(bit)::set(null, "uvm_test_top*", "real_ips", REAL_IPS);
    run_test();
  end

  initial begin
    #20ms;
    `uvm_fatal("TB", "watchdog timeout")
  end

  initial if ($test$plusargs("VCD")) begin
    $dumpfile("phone_tb.vcd");
    $dumpvars(0, phone_tb_top);
  end
endmodule
