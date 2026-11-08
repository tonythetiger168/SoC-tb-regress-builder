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

`ifdef TV8K_C1P
  // c1p decoder register port (AXI4-Lite), reached through slave port S_VDECR
  logic        c1p_awvalid, c1p_awready, c1p_wvalid, c1p_wready, c1p_bvalid, c1p_bready;
  logic        c1p_arvalid, c1p_arready, c1p_rvalid, c1p_rready;
  logic [15:0] c1p_awaddr, c1p_araddr;
  logic [31:0] c1p_wdata, c1p_rdata;
  logic [3:0]  c1p_wstrb;
  logic [1:0]  c1p_bresp, c1p_rresp;
  logic        c1p_irq;
  localparam bit C1P = 1'b1;
`else
  localparam bit C1P = 1'b0;
`endif

  for (genvar m = 0; m < NM; m++) begin : g_m
    if (!(C1P && m == M_VDEC)) begin : g_vip
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
    end
`ifdef TV8K_C1P
    else begin : g_c1p
      // the c1p decoder's 64-bit AXI4 master on a 64-bit master NI; m_if mirrors
      // its handshakes (low data lanes only) for the passive monitor and latency
      logic [3:0]  awid, arid, bid, rid;
      logic [31:0] awaddr, araddr;
      logic [7:0]  awlen, arlen;
      logic [2:0]  awsize, arsize, awprot, arprot;
      logic [1:0]  awburst, arburst, bresp, rresp;
      logic [3:0]  awcache, arcache;
      logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
      logic        arvalid, arready, rvalid, rready, rlast;
      logic [63:0] wdata, rdata;
      logic [7:0]  wstrb;
      logic [4:0]  pg_req;
      logic        dvfs_req;
      logic        bs_valid, bs_ready;
      logic [7:0]  bs_data;

      c1p_dec_axi_top #(.HEVC_MAX_W(8192)) u_c1p (
        .clk_i(aclk), .rst_ni(aresetn), .cg_te_i(1'b0),
        .pg_req_o(pg_req), .pg_ack_i(pg_req), .dvfs_req_o(dvfs_req), .dvfs_lvl_o(), .dvfs_ack_i(dvfs_req),
        .s_awvalid_i(c1p_awvalid), .s_awready_o(c1p_awready), .s_awaddr_i(c1p_awaddr),
        .s_wvalid_i(c1p_wvalid), .s_wready_o(c1p_wready), .s_wdata_i(c1p_wdata), .s_wstrb_i(c1p_wstrb),
        .s_bvalid_o(c1p_bvalid), .s_bready_i(c1p_bready), .s_bresp_o(c1p_bresp),
        .s_arvalid_i(c1p_arvalid), .s_arready_o(c1p_arready), .s_araddr_i(c1p_araddr),
        .s_rvalid_o(c1p_rvalid), .s_rready_i(c1p_rready), .s_rdata_o(c1p_rdata), .s_rresp_o(c1p_rresp),
        .s_axis_tvalid_i(bs_valid), .s_axis_tready_o(bs_ready), .s_axis_tdata_i(bs_data),
        .tok_o(), .tok_valid_o(), .tok_ready_i(1'b1),
        .oy_tvalid_o(), .oy_tready_i(1'b1), .oy_tdata_o(), .oy_tkeep_o(), .oy_tlast_o(), .oy_tuser_o(),
        .oc_tvalid_o(), .oc_tready_i(1'b1), .oc_tdata_o(), .oc_tlast_o(), .oc_tuser_o(),
        .m_awvalid_o(awvalid), .m_awready_i(awready), .m_awaddr_o(awaddr), .m_awid_o(awid),
        .m_awlen_o(awlen), .m_awsize_o(awsize), .m_awburst_o(awburst), .m_awcache_o(awcache), .m_awprot_o(awprot),
        .m_wvalid_o(wvalid), .m_wready_i(wready), .m_wdata_o(wdata), .m_wstrb_o(wstrb), .m_wlast_o(wlast),
        .m_bvalid_i(bvalid), .m_bready_o(bready), .m_bid_i(bid), .m_bresp_i(bresp),
        .m_arvalid_o(arvalid), .m_arready_i(arready), .m_araddr_o(araddr), .m_arid_o(arid),
        .m_arlen_o(arlen), .m_arsize_o(arsize), .m_arburst_o(arburst), .m_arcache_o(arcache), .m_arprot_o(arprot),
        .m_rvalid_i(rvalid), .m_rready_o(rready), .m_rid_i(rid), .m_rdata_i(rdata), .m_rresp_i(rresp),
        .m_rlast_i(rlast), .irq_o(c1p_irq));

      tv8k_ni_mst #(.SELF(m), .DW(64), .IDW(4), .MAXB(4), .MAXO(8)) u_ni (
        .clk(aclk), .rst_n(aresetn),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize), .s_awburst(awburst),
        .s_awprot(awprot), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
        .s_arprot(arprot), .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
        .inj_flit(inj_flit[m]), .inj_valid(inj_valid[m]), .inj_ready(inj_ready[m]),
        .ej_flit(ej_flit[m]), .ej_valid(ej_valid[m]), .ej_ready(ej_ready[m]));

      assign m_if[m].awid = 8'(awid);   assign m_if[m].awaddr = awaddr;   assign m_if[m].awlen = awlen;
      assign m_if[m].awsize = awsize;   assign m_if[m].awburst = awburst; assign m_if[m].awprot = awprot;
      assign m_if[m].awcache = awcache; assign m_if[m].awlock = 1'b0;     assign m_if[m].awvalid = awvalid;
      assign m_if[m].awready = awready;
      assign m_if[m].wdata = wdata[31:0]; assign m_if[m].wstrb = wstrb[3:0]; assign m_if[m].wlast = wlast;
      assign m_if[m].wvalid = wvalid;   assign m_if[m].wready = wready;
      assign m_if[m].bid = 8'(bid);     assign m_if[m].bresp = bresp;     assign m_if[m].bvalid = bvalid;
      assign m_if[m].bready = bready;
      assign m_if[m].arid = 8'(arid);   assign m_if[m].araddr = araddr;   assign m_if[m].arlen = arlen;
      assign m_if[m].arsize = arsize;   assign m_if[m].arburst = arburst; assign m_if[m].arprot = arprot;
      assign m_if[m].arcache = arcache; assign m_if[m].arlock = 1'b0;     assign m_if[m].arvalid = arvalid;
      assign m_if[m].arready = arready;
      assign m_if[m].rid = 8'(rid);     assign m_if[m].rdata = rdata[31:0]; assign m_if[m].rresp = rresp;
      assign m_if[m].rlast = rlast;     assign m_if[m].rvalid = rvalid;   assign m_if[m].rready = rready;

      // bitstream over AXI4-Stream (+C1P_BS=<file.265>), with an EOS NAL appended
      // so the decoder sees the end of the last NAL; +C1P_BS_GAP=<%> idles TVALID
      logic [7:0]  bs [$];
      int unsigned bs_i, bs_gap;
      initial begin
        string f, v, dir;
        int fd, c;
        f = ""; dir = "build/tv8k_vdec_vec";
        bs_gap = 0;
        void'($value$plusargs("C1P_BS_GAP=%d", bs_gap));
        void'($value$plusargs("C1P_DIR=%s", dir));
        if ($value$plusargs("C1P_VEC=%s", v)) f = {dir, "/", v, ".265"};
        if (f != "" || $value$plusargs("C1P_BS=%s", f)) begin
          fd = $fopen(f, "rb");
          if (fd == 0) $fatal(1, "cannot open %s", f);
          c = $fgetc(fd);
          while (c != -1) begin bs.push_back(8'(c)); c = $fgetc(fd); end
          $fclose(fd);
          bs.push_back(8'h00); bs.push_back(8'h00); bs.push_back(8'h00);
          bs.push_back(8'h01); bs.push_back(8'h48); bs.push_back(8'h01);
        end
      end
      always @(posedge aclk or negedge aresetn)
        if (!aresetn) begin bs_valid <= 1'b0; bs_i = 0; bs_data <= '0; end
        else begin
          if (bs_valid && bs_ready) bs_i = bs_i + 1;
          if (!bs_valid || bs_ready) begin
            bs_valid <= (bs_i < bs.size()) && ($urandom_range(99, 0) >= bs_gap);
            bs_data  <= (bs_i < bs.size()) ? bs[bs_i] : 8'h00;
          end
        end
    end
`endif
    initial begin
      // exact paths: a "m1_agent*" glob would also match m10_agent and m11_agent
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_agent", m), "vif", m_if[m]);
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_agent.*", m), "vif", m_if[m]);
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.m%0d_lat", m), "vif", m_if[m]);
    end
  end

`ifdef TV8K_CPU
  // xuanji-core RV64IMAC core as the CPU master: its L2 line port drives master
  // port M_CPU through tv8k_core2axi (the M_CPU agent is passive). It boots at
  // 0x8000_0000, the first byte of DRAM.
  begin : g_cpu
    logic [63:0]  l2_req_addr, l2_wr_addr;
    logic         l2_req_valid, l2_fill_valid, l2_wr_valid, halt, wq_overflow, bus_err;
    logic [511:0] l2_fill_line, l2_wr_line;
    orca_v63_cpu_core u_core (
      .clk(aclk), .rst_n(aresetn), .test_en(1'b0), .tid('0),
      .l2_req_addr, .l2_req_valid, .l2_wr_valid, .l2_wr_addr, .l2_wr_line,
      .l2_fill_line, .l2_fill_valid, .core_halt(halt));
    tv8k_core2axi #(.WQ(16)) u_bridge (
      .clk(aclk), .rst_n(aresetn),
      .l2_req_addr, .l2_req_valid, .l2_fill_line, .l2_fill_valid, .l2_wr_valid, .l2_wr_addr, .l2_wr_line,
      .awaddr(m_if[M_CPU].awaddr), .awvalid(m_if[M_CPU].awvalid), .awready(m_if[M_CPU].awready),
      .wdata(m_if[M_CPU].wdata), .wlast(m_if[M_CPU].wlast), .wvalid(m_if[M_CPU].wvalid), .wready(m_if[M_CPU].wready),
      .bresp(m_if[M_CPU].bresp), .bvalid(m_if[M_CPU].bvalid),
      .araddr(m_if[M_CPU].araddr), .arvalid(m_if[M_CPU].arvalid), .arready(m_if[M_CPU].arready),
      .rdata(m_if[M_CPU].rdata), .rresp(m_if[M_CPU].rresp), .rlast(m_if[M_CPU].rlast), .rvalid(m_if[M_CPU].rvalid),
      .wq_overflow, .bus_err);
    assign m_if[M_CPU].awid = '0;     assign m_if[M_CPU].arid = '0;
    assign m_if[M_CPU].awlen = 8'd15; assign m_if[M_CPU].arlen = 8'd15;
    assign m_if[M_CPU].awsize = 3'd2; assign m_if[M_CPU].arsize = 3'd2;
    assign m_if[M_CPU].awburst = 2'b01; assign m_if[M_CPU].arburst = 2'b01;
    assign m_if[M_CPU].awprot = '0;   assign m_if[M_CPU].arprot = '0;
    assign m_if[M_CPU].awlock = 1'b0; assign m_if[M_CPU].arlock = 1'b0;
    assign m_if[M_CPU].awcache = '0;  assign m_if[M_CPU].arcache = '0;
    assign m_if[M_CPU].wstrb = 4'hF;
    assign m_if[M_CPU].bready = 1'b1; assign m_if[M_CPU].rready = 1'b1;
    always @(posedge aclk) if (aresetn) begin
      if (wq_overflow) $error("tv8k_core2axi: write-back queue overflow");
      if (bus_err)     $error("tv8k_core2axi: error response");
    end
  end
`endif

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
`ifdef TV8K_C1P
    if (NM + s == S_VDECR) begin : g_c1p_regs
      tv8k_axi2axil #(.AW(16)) u_axil (
        .clk(aclk), .rst_n(aresetn),
        .s_awid(s_if[s].awid[3:0]), .s_awaddr(s_if[s].awaddr), .s_awlen(s_if[s].awlen),
        .s_awvalid(s_if[s].awvalid), .s_awready(s_if[s].awready),
        .s_wdata(s_if[s].wdata), .s_wstrb(s_if[s].wstrb), .s_wlast(s_if[s].wlast),
        .s_wvalid(s_if[s].wvalid), .s_wready(s_if[s].wready),
        .s_bid(s_if[s].bid[3:0]), .s_bresp(s_if[s].bresp), .s_bvalid(s_if[s].bvalid), .s_bready(s_if[s].bready),
        .s_arid(s_if[s].arid[3:0]), .s_araddr(s_if[s].araddr), .s_arlen(s_if[s].arlen),
        .s_arvalid(s_if[s].arvalid), .s_arready(s_if[s].arready),
        .s_rid(s_if[s].rid[3:0]), .s_rdata(s_if[s].rdata), .s_rresp(s_if[s].rresp), .s_rlast(s_if[s].rlast),
        .s_rvalid(s_if[s].rvalid), .s_rready(s_if[s].rready),
        .m_awvalid(c1p_awvalid), .m_awready(c1p_awready), .m_awaddr(c1p_awaddr),
        .m_wvalid(c1p_wvalid), .m_wready(c1p_wready), .m_wdata(c1p_wdata), .m_wstrb(c1p_wstrb),
        .m_bvalid(c1p_bvalid), .m_bready(c1p_bready), .m_bresp(c1p_bresp),
        .m_arvalid(c1p_arvalid), .m_arready(c1p_arready), .m_araddr(c1p_araddr),
        .m_rvalid(c1p_rvalid), .m_rready(c1p_rready), .m_rdata(c1p_rdata), .m_rresp(c1p_rresp));
      assign s_if[s].bid[7:4] = '0;
      assign s_if[s].rid[7:4] = '0;
    end
`endif
`ifdef TV8K_NPU
    if (NM + s == S_NPUR) begin : g_npu
      // xuanji NPU subsystem (orca_npu_ss_apb, X1: 8x8 array, 4 CUs): registers
      // behind S_NPUR (AXI4 -> APB4), its 64-byte line DMA port drives master
      // port M_NPU through tv8k_line2axi (the M_NPU agent is passive)
      logic        psel, penable, pwrite, pready, pslverr, irq, busy;
      logic [11:0] paddr;
      logic [31:0] pwdata, prdata;
      logic [3:0]  pstrb;
      logic        rd_req, rd_gnt, rd_rvalid, wr_req, wr_gnt;
      logic [31:0] rd_addr, wr_addr;
      logic [511:0] rd_rdata, wr_data;
      logic [31:0] n_bresp;
      logic        bus_err;
      logic [3:0]  awid4, arid4;

      tv8k_axi2apb #(.AW(12)) u_apb (
        .clk(aclk), .rst_n(aresetn),
        .s_awid(s_if[s].awid[3:0]), .s_awaddr(s_if[s].awaddr), .s_awlen(s_if[s].awlen),
        .s_awvalid(s_if[s].awvalid), .s_awready(s_if[s].awready),
        .s_wdata(s_if[s].wdata), .s_wstrb(s_if[s].wstrb), .s_wlast(s_if[s].wlast),
        .s_wvalid(s_if[s].wvalid), .s_wready(s_if[s].wready),
        .s_bid(s_if[s].bid[3:0]), .s_bresp(s_if[s].bresp), .s_bvalid(s_if[s].bvalid), .s_bready(s_if[s].bready),
        .s_arid(s_if[s].arid[3:0]), .s_araddr(s_if[s].araddr), .s_arlen(s_if[s].arlen),
        .s_arvalid(s_if[s].arvalid), .s_arready(s_if[s].arready),
        .s_rid(s_if[s].rid[3:0]), .s_rdata(s_if[s].rdata), .s_rresp(s_if[s].rresp), .s_rlast(s_if[s].rlast),
        .s_rvalid(s_if[s].rvalid), .s_rready(s_if[s].rready),
        .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pready, .prdata, .pslverr);
      assign s_if[s].bid[7:4] = '0;
      assign s_if[s].rid[7:4] = '0;

      orca_npu_ss_apb #(.TILE_ID(0)) u_npu (
        .clk(aclk), .rst_n(aresetn), .test_en(1'b0), .clk_aon(aclk), .por_n(aresetn),
        .ret_save(1'b0), .ret_restore(1'b0),
        .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pready, .prdata, .pslverr, .irq, .busy,
        .m_rd_req(rd_req), .m_rd_addr(rd_addr), .m_rd_gnt(rd_gnt), .m_rd_rvalid(rd_rvalid), .m_rd_rdata(rd_rdata),
        .m_wr_req(wr_req), .m_wr_addr(wr_addr), .m_wr_data(wr_data), .m_wr_gnt(wr_gnt));

      tv8k_line2axi #(.RQ(8)) u_line (
        .clk(aclk), .rst_n(aresetn),
        .m_rd_req(rd_req), .m_rd_addr(rd_addr), .m_rd_gnt(rd_gnt), .m_rd_rvalid(rd_rvalid), .m_rd_rdata(rd_rdata),
        .m_wr_req(wr_req), .m_wr_addr(wr_addr), .m_wr_data(wr_data), .m_wr_gnt(wr_gnt),
        .awid(awid4), .awaddr(m_if[M_NPU].awaddr), .awlen(m_if[M_NPU].awlen), .awsize(m_if[M_NPU].awsize),
        .awburst(m_if[M_NPU].awburst), .awvalid(m_if[M_NPU].awvalid), .awready(m_if[M_NPU].awready),
        .wdata(m_if[M_NPU].wdata), .wstrb(m_if[M_NPU].wstrb), .wlast(m_if[M_NPU].wlast),
        .wvalid(m_if[M_NPU].wvalid), .wready(m_if[M_NPU].wready),
        .bresp(m_if[M_NPU].bresp), .bvalid(m_if[M_NPU].bvalid), .bready(m_if[M_NPU].bready),
        .arid(arid4), .araddr(m_if[M_NPU].araddr), .arlen(m_if[M_NPU].arlen), .arsize(m_if[M_NPU].arsize),
        .arburst(m_if[M_NPU].arburst), .arvalid(m_if[M_NPU].arvalid), .arready(m_if[M_NPU].arready),
        .rdata(m_if[M_NPU].rdata), .rresp(m_if[M_NPU].rresp), .rlast(m_if[M_NPU].rlast),
        .rvalid(m_if[M_NPU].rvalid), .rready(m_if[M_NPU].rready),
        .n_bresp, .bus_err);
      always @(posedge aclk) if ($test$plusargs("NPU_TRACE") && aresetn) begin
        if (rd_gnt)    $display("NPU %t RD_GNT  line=%h", $time, rd_addr);
        if (rd_rvalid) $display("NPU %t RD_DATA", $time);
        if (wr_req)    $display("NPU %t WR_REQ  line=%h gnt=%b", $time, wr_addr, wr_gnt);
        if (psel && penable && pready) $display("NPU %t APB %s %03h %08h", $time, pwrite ? "W" : "R", paddr,
                                                 pwrite ? pwdata : prdata);
      end
      assign m_if[M_NPU].awid = 8'(awid4);
      assign m_if[M_NPU].arid = 8'(arid4);
      assign m_if[M_NPU].awprot = 3'b000; assign m_if[M_NPU].arprot = 3'b000;
      assign m_if[M_NPU].awlock = 1'b0;   assign m_if[M_NPU].arlock = 1'b0;
      assign m_if[M_NPU].awcache = 4'h0;  assign m_if[M_NPU].arcache = 4'h0;
    end
`endif
    assign s_if[s].awid[7:4] = '0;
    assign s_if[s].arid[7:4] = '0;
    assign s_if[s].awlock = 1'b0; assign s_if[s].arlock = 1'b0;
    assign s_if[s].awcache = '0;  assign s_if[s].arcache = '0;
    axi4_sva #(.NAME($sformatf("s_%s", ep_name(NM + s)))) u_sva (s_if[s]);
    initial begin
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.s%0d_agent", s), "vif", s_if[s]);
      uvm_config_db#(virtual axi4_if)::set(null, $sformatf("uvm_test_top.env.s%0d_agent.*", s), "vif", s_if[s]);
    end
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
