// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axil_if -- AXI4-Lite interface (32-bit address, 32-bit data)
// ----------------------------------------------------------------------------
// Clocking blocks: mst_cb (manager side), slv_cb (subordinate side),
// mon_cb (passive sampling). AXI4-Lite has no IDs, no bursts and no LAST.
// ============================================================================
`ifndef AXIL_IF_SV
`define AXIL_IF_SV
interface axil_if (input logic aclk, input logic aresetn);
  logic [31:0] awaddr;
  logic [2:0]  awprot;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [31:0] araddr;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  clocking mst_cb @(posedge aclk);
    default input #1step output #1;
    output awaddr, awprot, awvalid, wdata, wstrb, wvalid, bready, araddr, arprot, arvalid, rready;
    input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #1;
    input  awaddr, awprot, awvalid, wdata, wstrb, wvalid, bready, araddr, arprot, arvalid, rready;
    output awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awaddr, awprot, awvalid, awready, wdata, wstrb, wvalid, wready, bresp, bvalid, bready;
    input araddr, arprot, arvalid, arready, rdata, rresp, rvalid, rready;
  endclocking
endinterface
`endif
