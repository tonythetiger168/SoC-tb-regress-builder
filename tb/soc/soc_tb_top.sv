// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_tb_top -- top module of the AMBA SoC UVM testbench
// ============================================================================
`timescale 1ns/1ps
module soc_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import soc_test_pkg::*;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  always #5 aclk = ~aclk;                 // 100 MHz
  initial begin
    repeat (10) @(posedge aclk);
    aresetn <= 1'b1;
  end

  // ---------------- interfaces ----------------
  axi4_if m_if [2] (.aclk(aclk), .aresetn(aresetn));   // DUT AXI slave ports m0/m1
  axi4_if ddr_if   (.aclk(aclk), .aresetn(aresetn));   // DUT external memory port
  apb_if  apbx_if  (.pclk(aclk), .presetn(aresetn));   // DUT external APB slot
  apb_if  apbi_if  (.pclk(aclk), .presetn(aresetn));   // internal APB bus (monitor only)

  // ---------------- DUT ----------------
  logic [3:0]  m_awid [2], m_bid [2], m_arid [2], m_rid [2];
  logic [31:0] m_awaddr [2], m_wdata [2], m_araddr [2], m_rdata [2];
  logic [7:0]  m_awlen [2], m_arlen [2];
  logic [2:0]  m_awsize [2], m_arsize [2], m_awprot [2], m_arprot [2];
  logic [1:0]  m_awburst [2], m_arburst [2], m_bresp [2], m_rresp [2];
  logic [3:0]  m_wstrb [2];
  logic        m_awvalid [2], m_awready [2], m_wlast [2], m_wvalid [2], m_wready [2];
  logic        m_bvalid [2], m_bready [2], m_arvalid [2], m_arready [2];
  logic        m_rlast [2], m_rvalid [2], m_rready [2];
  logic [4:0]  ddr_awid, ddr_bid, ddr_arid, ddr_rid;
  tri   [7:0]  gpio;
  logic        uart_txd;
  logic [2:0]  irq;

  for (genvar i = 0; i < 2; i++) begin : g_m
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

    axi4_sva #(.NAME($sformatf("m%0d", i))) u_sva (m_if[i]);
    initial uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_agent*", i),
                                                 "vif", m_if[i]);
  end

  amba_soc_top dut (
    .aclk, .aresetn,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready,
    .ddr_awid, .ddr_awaddr(ddr_if.awaddr), .ddr_awlen(ddr_if.awlen), .ddr_awsize(ddr_if.awsize),
    .ddr_awburst(ddr_if.awburst), .ddr_awprot(ddr_if.awprot), .ddr_awvalid(ddr_if.awvalid),
    .ddr_awready(ddr_if.awready),
    .ddr_wdata(ddr_if.wdata), .ddr_wstrb(ddr_if.wstrb), .ddr_wlast(ddr_if.wlast),
    .ddr_wvalid(ddr_if.wvalid), .ddr_wready(ddr_if.wready),
    .ddr_bid, .ddr_bresp(ddr_if.bresp), .ddr_bvalid(ddr_if.bvalid), .ddr_bready(ddr_if.bready),
    .ddr_arid, .ddr_araddr(ddr_if.araddr), .ddr_arlen(ddr_if.arlen), .ddr_arsize(ddr_if.arsize),
    .ddr_arburst(ddr_if.arburst), .ddr_arprot(ddr_if.arprot), .ddr_arvalid(ddr_if.arvalid),
    .ddr_arready(ddr_if.arready),
    .ddr_rid, .ddr_rdata(ddr_if.rdata), .ddr_rresp(ddr_if.rresp), .ddr_rlast(ddr_if.rlast),
    .ddr_rvalid(ddr_if.rvalid), .ddr_rready(ddr_if.rready),
    .apbx_paddr(apbx_if.paddr), .apbx_psel(apbx_if.psel), .apbx_penable(apbx_if.penable),
    .apbx_pwrite(apbx_if.pwrite), .apbx_pwdata(apbx_if.pwdata), .apbx_pstrb(apbx_if.pstrb),
    .apbx_pprot(apbx_if.pprot), .apbx_prdata(apbx_if.prdata), .apbx_pready(apbx_if.pready),
    .apbx_pslverr(apbx_if.pslverr),
    .gpio, .uart_rxd(uart_txd), .uart_txd, .irq                 // UART looped back
  );

  // DDR port: 5-bit IDs into the 8-bit container
  assign ddr_if.awid = {3'b0, ddr_awid};
  assign ddr_if.arid = {3'b0, ddr_arid};
  assign ddr_bid = ddr_if.bid[4:0];
  assign ddr_rid = ddr_if.rid[4:0];
  assign ddr_if.awlock = 1'b0;  assign ddr_if.arlock = 1'b0;
  assign ddr_if.awcache = 4'h0; assign ddr_if.arcache = 4'h0;

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

  // ---------------- protocol checkers ----------------
  axi4_sva #(.NAME("ddr"))  u_ddr_sva  (ddr_if);
  apb_sva  #(.NAME("apbx")) u_apbx_sva (apbx_if);
  apb_sva  #(.NAME("apbi")) u_apbi_sva (apbi_if);

  initial begin
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.env.ddr_agent*", "vif", ddr_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apbx_agent*", "vif", apbx_if);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb_mon_agent*", "vif", apbi_if);
    run_test();
  end

  // watchdog
  initial begin
    #10ms;
    `uvm_fatal("TB", "watchdog timeout")
  end

  initial if ($test$plusargs("VCD")) begin
    $dumpfile("soc_tb.vcd");
    $dumpvars(0, soc_tb_top);
  end
endmodule
