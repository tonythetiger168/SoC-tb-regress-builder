// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ipcam_ip_tb_top -- unit bench for the IPCAM real-IP AXI masters, before they
// go into the SoC: c1p HEVC encoder (ipcam_venc_c1p), c1p JPEG encoder
// (ipcam_jpeg_c1p) and the xuanji NPU subsystem (ipcam_npu_xj).
//   * one APB requester agent drives a 3-slot APB bus (slot = PADDR[13:12]:
//     0 VENC, 1 JPEG, 2 NPU)
//   * each IP's 32-bit AXI master port goes to its own AXI4 slave agent; the
//     three share one mem_model, so a test pokes frames once (backdoor)
//   * axi4_sva on every AXI port, apb_sva on the APB bus
// ============================================================================
`timescale 1ns/1ps
module ipcam_ip_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import ipcam_ip_test_pkg::*;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  always #1 aclk = ~aclk;                   // 500 MHz, the IPCAM system clock
  initial begin
    repeat (10) @(posedge aclk);
    aresetn <= 1'b1;
  end

  axi4_if ax [3] (.aclk(aclk), .aresetn(aresetn));     // 0 VENC, 1 JPEG, 2 NPU
  apb_if  apb    (.pclk(aclk), .presetn(aresetn));

  // ---------------- APB slot decode ----------------
  logic        s_psel [3], s_pready [3], s_pslverr [3];
  logic [31:0] s_prdata [3];
  wire  [1:0]  slot = apb.paddr[13:12];
  always_comb begin
    apb.pready  = 1'b1;
    apb.prdata  = 32'h0;
    apb.pslverr = apb.psel & apb.penable;   // slot 3: unmapped
    for (int i = 0; i < 3; i++) begin
      s_psel[i] = apb.psel && slot == 2'(i);
      if (slot == 2'(i)) begin
        apb.pready  = s_pready[i];
        apb.prdata  = s_prdata[i];
        apb.pslverr = s_pslverr[i];
      end
    end
  end

  logic irq_venc, irq_jpeg, irq_npu, busy_venc, busy_jpeg, busy_npu;
  logic [15:0] npu_rd_err, npu_wr_err;

  // ---------------- DUTs ----------------
`define IPCAM_AXI_PORTS(I) \
    .awid(ax[I].awid[3:0]), .awaddr(ax[I].awaddr), .awlen(ax[I].awlen), .awsize(ax[I].awsize), \
    .awburst(ax[I].awburst), .awvalid(ax[I].awvalid), .awready(ax[I].awready), \
    .wdata(ax[I].wdata), .wstrb(ax[I].wstrb), .wlast(ax[I].wlast), .wvalid(ax[I].wvalid), .wready(ax[I].wready), \
    .bid(ax[I].bid[3:0]), .bresp(ax[I].bresp), .bvalid(ax[I].bvalid), .bready(ax[I].bready), \
    .arid(ax[I].arid[3:0]), .araddr(ax[I].araddr), .arlen(ax[I].arlen), .arsize(ax[I].arsize), \
    .arburst(ax[I].arburst), .arvalid(ax[I].arvalid), .arready(ax[I].arready), \
    .rid(ax[I].rid[3:0]), .rdata(ax[I].rdata), .rresp(ax[I].rresp), .rlast(ax[I].rlast), \
    .rvalid(ax[I].rvalid), .rready(ax[I].rready)

`define IPCAM_APB_PORTS(I) \
    .psel(s_psel[I]), .penable(apb.penable), .pwrite(apb.pwrite), .paddr(apb.paddr[11:0]), \
    .pwdata(apb.pwdata), .pstrb(apb.pstrb), .pready(s_pready[I]), .prdata(s_prdata[I]), .pslverr(s_pslverr[I])

  ipcam_venc_c1p u_venc (.clk(aclk), .rst_n(aresetn), `IPCAM_APB_PORTS(0), .irq(irq_venc), .busy(busy_venc),
                         .awcache(ax[0].awcache), .awprot(ax[0].awprot), .arcache(ax[0].arcache), .arprot(ax[0].arprot),
                         `IPCAM_AXI_PORTS(0));
  ipcam_jpeg_c1p u_jpeg (.clk(aclk), .rst_n(aresetn), `IPCAM_APB_PORTS(1), .irq(irq_jpeg), .busy(busy_jpeg),
                         .awcache(ax[1].awcache), .awprot(ax[1].awprot), .arcache(ax[1].arcache), .arprot(ax[1].arprot),
                         `IPCAM_AXI_PORTS(1));
  ipcam_npu_xj   u_npu  (.clk(aclk), .rst_n(aresetn), `IPCAM_APB_PORTS(2), .irq(irq_npu), .busy(busy_npu),
                         .bus_rd_err(npu_rd_err), .bus_wr_err(npu_wr_err), `IPCAM_AXI_PORTS(2));
  assign ax[2].awcache = 4'h0; assign ax[2].arcache = 4'h0;
  assign ax[2].awprot  = 3'h0; assign ax[2].arprot  = 3'h0;

  for (genvar i = 0; i < 3; i++) begin : g_ax
    assign ax[i].awid[7:4] = 4'h0;
    assign ax[i].arid[7:4] = 4'h0;
    assign ax[i].awlock = 1'b0;
    assign ax[i].arlock = 1'b0;
    axi4_sva #(.NAME($sformatf("ax%0d", i))) u_sva (ax[i]);
  end
  apb_sva #(.NAME("apb")) u_apb_sva (apb);

  // irq / busy levels for the tests
  ipcam_ip_sig_if sig (.clk(aclk));
  assign sig.irq  = {irq_npu, irq_jpeg, irq_venc};
  assign sig.busy = {busy_npu, busy_jpeg, busy_venc};
  assign sig.npu_bus_err = npu_rd_err | npu_wr_err;

  initial begin
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.env.mem0*", "vif", ax[0]);
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.env.mem1*", "vif", ax[1]);
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.env.mem2*", "vif", ax[2]);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.env.apb*", "vif", apb);
    uvm_config_db#(virtual ipcam_ip_sig_if)::set(null, "uvm_test_top*", "sig", sig);
    run_test();
  end

  initial begin
    #20ms;
    `uvm_fatal("TB", "watchdog timeout")
  end

  initial if ($test$plusargs("VCD")) begin
    $dumpfile("ipcam_ip_tb.vcd");
    $dumpvars(0, ipcam_ip_tb_top);
  end
endmodule
