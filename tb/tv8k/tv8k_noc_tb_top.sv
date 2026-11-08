// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_noc_tb_top -- the 8K TV SoC NoC (4x4 router mesh + NIs) on its own:
// AXI4 master VIPs on the 12 master NIs, AXI4 memory VIPs on the 12 slave NIs
// ============================================================================
`timescale 1ns/1ps
module tv8k_noc_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import tv8k_noc_pkg::*;
  import tv8k_noc_test_pkg::*;

  logic aclk = 1'b0, aresetn = 1'b0;
  // simulated at 100 MHz (the VIP clocking blocks drive with #1 skew); every
  // latency is counted in cycles and reported for the 1 GHz NoC clock
  always #5 aclk = ~aclk;
  initial begin
    repeat (20) @(posedge aclk);
    aresetn <= 1'b1;
  end

  tv8k_flit_t inj_flit [NEP], ej_flit [NEP];
  logic       inj_valid [NEP], inj_ready [NEP], ej_valid [NEP], ej_ready [NEP];
  logic       noc_busy;

  tv8k_noc u_noc (.clk(aclk), .rst_n(aresetn), .inj_flit, .inj_valid, .inj_ready,
                  .ej_flit, .ej_valid, .ej_ready, .busy(noc_busy));

  axi4_if m_if [NM] (.aclk(aclk), .aresetn(aresetn));
  axi4_if s_if [NS] (.aclk(aclk), .aresetn(aresetn));

  for (genvar m = 0; m < NM; m++) begin : g_m
    tv8k_ni_mst #(.SELF(m), .DW(32), .IDW(4), .MAXB(4), .MAXO(8)) u_ni (
      .clk(aclk), .rst_n(aresetn),
      .s_awid(m_if[m].awid[3:0]), .s_awaddr(m_if[m].awaddr), .s_awlen(m_if[m].awlen),
      .s_awsize(m_if[m].awsize), .s_awburst(m_if[m].awburst), .s_awprot(m_if[m].awprot),
      .s_awvalid(m_if[m].awvalid), .s_awready(m_if[m].awready),
      .s_wdata(m_if[m].wdata), .s_wstrb(m_if[m].wstrb), .s_wlast(m_if[m].wlast),
      .s_wvalid(m_if[m].wvalid), .s_wready(m_if[m].wready),
      .s_bid(m_if[m].bid[3:0]), .s_bresp(m_if[m].bresp), .s_bvalid(m_if[m].bvalid), .s_bready(m_if[m].bready),
      .s_arid(m_if[m].arid[3:0]), .s_araddr(m_if[m].araddr), .s_arlen(m_if[m].arlen),
      .s_arsize(m_if[m].arsize), .s_arburst(m_if[m].arburst), .s_arprot(m_if[m].arprot),
      .s_arvalid(m_if[m].arvalid), .s_arready(m_if[m].arready),
      .s_rid(m_if[m].rid[3:0]), .s_rdata(m_if[m].rdata), .s_rresp(m_if[m].rresp), .s_rlast(m_if[m].rlast),
      .s_rvalid(m_if[m].rvalid), .s_rready(m_if[m].rready),
      .inj_flit(inj_flit[m]), .inj_valid(inj_valid[m]), .inj_ready(inj_ready[m]),
      .ej_flit(ej_flit[m]), .ej_valid(ej_valid[m]), .ej_ready(ej_ready[m]));
    assign m_if[m].bid[7:4] = '0;
    assign m_if[m].rid[7:4] = '0;
    axi4_sva #(.NAME($sformatf("m_%s", ep_name(m)))) u_sva (m_if[m]);
    initial begin
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_agent*", m), "vif", m_if[m]);
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_lat", m), "vif", m_if[m]);
    end
  end

  for (genvar s = 0; s < NS; s++) begin : g_s
    tv8k_ni_slv #(.SELF(NM + s), .QD(NM * 8), .OUTS(4)) u_ni (
      .clk(aclk), .rst_n(aresetn),
      .m_awid(s_if[s].awid[3:0]), .m_awaddr(s_if[s].awaddr), .m_awlen(s_if[s].awlen),
      .m_awsize(s_if[s].awsize), .m_awburst(s_if[s].awburst), .m_awprot(s_if[s].awprot),
      .m_awvalid(s_if[s].awvalid), .m_awready(s_if[s].awready),
      .m_wdata(s_if[s].wdata), .m_wstrb(s_if[s].wstrb), .m_wlast(s_if[s].wlast),
      .m_wvalid(s_if[s].wvalid), .m_wready(s_if[s].wready),
      .m_bresp(s_if[s].bresp), .m_bvalid(s_if[s].bvalid), .m_bready(s_if[s].bready),
      .m_arid(s_if[s].arid[3:0]), .m_araddr(s_if[s].araddr), .m_arlen(s_if[s].arlen),
      .m_arsize(s_if[s].arsize), .m_arburst(s_if[s].arburst), .m_arprot(s_if[s].arprot),
      .m_arvalid(s_if[s].arvalid), .m_arready(s_if[s].arready),
      .m_rdata(s_if[s].rdata), .m_rresp(s_if[s].rresp), .m_rlast(s_if[s].rlast),
      .m_rvalid(s_if[s].rvalid), .m_rready(s_if[s].rready),
      .inj_flit(inj_flit[NM + s]), .inj_valid(inj_valid[NM + s]), .inj_ready(inj_ready[NM + s]),
      .ej_flit(ej_flit[NM + s]), .ej_valid(ej_valid[NM + s]), .ej_ready(ej_ready[NM + s]));
    assign s_if[s].awid[7:4] = '0;
    assign s_if[s].arid[7:4] = '0;
    assign s_if[s].awlock = 1'b0; assign s_if[s].arlock = 1'b0;
    assign s_if[s].awcache = '0;  assign s_if[s].arcache = '0;
    axi4_sva #(.NAME($sformatf("s_%s", ep_name(NM + s)))) u_sva (s_if[s]);
    initial uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.s%0d_agent*", s), "vif", s_if[s]);
  end

  // +NOC_TRACE: one line per flit injected / ejected at every endpoint
  for (genvar e = 0; e < NEP; e++) begin : g_trace
    always @(posedge aclk) if ($test$plusargs("NOC_TRACE") && aresetn) begin
      if (inj_valid[e] && inj_ready[e]) begin
        automatic pkt_t p = pkt_of(inj_flit[e]);
        $display("NOC %t INJ %-9s op=%0d dst=%-9s tag=%0d addr=%h", $time, ep_name(e), p.op, ep_name(p.dst_ep), p.tag, p.addr);
      end
      if (ej_valid[e] && ej_ready[e]) begin
        automatic pkt_t p = pkt_of(ej_flit[e]);
        $display("NOC %t EJ  %-9s op=%0d src=%-9s tag=%0d addr=%h", $time, ep_name(e), p.op, ep_name(p.src_ep), p.tag, p.addr);
      end
    end
  end

  initial run_test();
  initial begin
    #50ms;
    `uvm_fatal("TB", "watchdog timeout")
  end
  initial if ($test$plusargs("HEARTBEAT")) forever begin
    #10us;
    $display("HEARTBEAT %t", $time);
  end
  initial if ($test$plusargs("VCD")) begin
    $dumpfile("tv8k_noc_tb.vcd");
    $dumpvars(0, tv8k_noc_tb_top);
  end
endmodule
