// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// apb_if -- APB4 interface (32-bit address and data, one PSEL)
// ============================================================================
`ifndef APB_IF_SV
`define APB_IF_SV
interface apb_if (input logic pclk, input logic presetn);
  logic [31:0] paddr;
  logic        psel;
  logic        penable;
  logic        pwrite;
  logic [31:0] pwdata;
  logic [3:0]  pstrb;
  logic [2:0]  pprot;
  logic [31:0] prdata;
  logic        pready;
  logic        pslverr;

  clocking mst_cb @(posedge pclk);
    default input #1step output #1;
    output paddr, psel, penable, pwrite, pwdata, pstrb, pprot;
    input  prdata, pready, pslverr;
  endclocking

  clocking slv_cb @(posedge pclk);
    default input #1step output #1;
    input  paddr, psel, penable, pwrite, pwdata, pstrb, pprot;
    output prdata, pready, pslverr;
  endclocking

  clocking mon_cb @(posedge pclk);
    default input #1step;
    input paddr, psel, penable, pwrite, pwdata, pstrb, pprot, prdata, pready, pslverr;
  endclocking
endinterface
`endif
