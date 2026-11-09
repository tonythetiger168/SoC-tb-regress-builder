// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axi4_if -- AXI4 interface (32-bit address, 32-bit data, 8-bit ID container)
// ----------------------------------------------------------------------------
// The ID fields are 8 bits wide; a narrower DUT port uses the low bits and the
// testbench ties the rest to 0. Clocking blocks:
//   mst_cb  manager (master) side     slv_cb  subordinate (slave) side
//   mon_cb  passive sampling
// ============================================================================
`ifndef AXI4_IF_SV
`define AXI4_IF_SV
interface axi4_if (input logic aclk, input logic aresetn);
  // write address
  logic [7:0]  awid;
  logic [31:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst;
  logic        awlock;
  logic [3:0]  awcache;
  logic [2:0]  awprot;
  logic        awvalid;
  logic        awready;
  // write data
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wlast;
  logic        wvalid;
  logic        wready;
  // write response
  logic [7:0]  bid;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  // read address
  logic [7:0]  arid;
  logic [31:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst;
  logic        arlock;
  logic [3:0]  arcache;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;
  // read data
  logic [7:0]  rid;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rlast;
  logic        rvalid;
  logic        rready;

  clocking mst_cb @(posedge aclk);
    default input #1step output #1;
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid;
    input  awready;
    output wdata, wstrb, wlast, wvalid;
    input  wready;
    input  bid, bresp, bvalid;
    output bready;
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    input  arready;
    input  rid, rdata, rresp, rlast, rvalid;
    output rready;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #1;
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid;
    output awready;
    input  wdata, wstrb, wlast, wvalid;
    output wready;
    output bid, bresp, bvalid;
    input  bready;
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    output arready;
    output rid, rdata, rresp, rlast, rvalid;
    input  rready;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking
endinterface
`endif
