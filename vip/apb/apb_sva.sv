// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// apb_sva -- APB4 protocol checker
// ----------------------------------------------------------------------------
//  * SETUP is followed by ACCESS (PSEL && !PENABLE |=> PSEL && PENABLE)
//  * address, direction, write data, strobes and PPROT stay stable from SETUP
//    until the transfer completes
//  * PENABLE only with PSEL; PSTRB is 0 for reads; no X on PSEL/PENABLE, and
//    no X on PREADY (and PSLVERR when PREADY) during ACCESS
// ============================================================================
`ifndef APB_SVA_SV
`define APB_SVA_SV
module apb_sva #(parameter string NAME = "apb") (apb_if vif);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  wire clk = vif.pclk;
  wire rst_n = vif.presetn;
  wire setup  = vif.psel && !vif.penable;
  wire access = vif.psel && vif.penable;

  setup_to_access: assert property (@(posedge clk) disable iff (!rst_n) setup |=> access)
    else `uvm_error({NAME, "_SVA"}, "SETUP not followed by ACCESS");
  stable_in_xfer: assert property (@(posedge clk) disable iff (!rst_n)
                    (setup || (access && !vif.pready)) |=>
                      $stable({vif.paddr, vif.pwrite, vif.pwdata, vif.pstrb, vif.pprot}))
    else `uvm_error({NAME, "_SVA"}, "request signals changed during a transfer");
  wait_holds: assert property (@(posedge clk) disable iff (!rst_n) (access && !vif.pready) |=> access)
    else `uvm_error({NAME, "_SVA"}, "PSEL/PENABLE dropped before PREADY");
  penable_needs_psel: assert property (@(posedge clk) disable iff (!rst_n) vif.penable |-> vif.psel)
    else `uvm_error({NAME, "_SVA"}, "PENABLE without PSEL");
  read_strb_zero: assert property (@(posedge clk) disable iff (!rst_n) (vif.psel && !vif.pwrite) |-> vif.pstrb == 4'h0)
    else `uvm_error({NAME, "_SVA"}, "PSTRB not 0 on a read");
  ctrl_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown({vif.psel, vif.penable}))
    else `uvm_error({NAME, "_SVA"}, "PSEL/PENABLE X/Z");
  resp_known: assert property (@(posedge clk) disable iff (!rst_n)
                access |-> !$isunknown(vif.pready) && (!vif.pready || !$isunknown(vif.pslverr)))
    else `uvm_error({NAME, "_SVA"}, "PREADY/PSLVERR X/Z during ACCESS");
endmodule
`endif
