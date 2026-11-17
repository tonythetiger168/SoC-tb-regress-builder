// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axil_sva -- AXI4-Lite protocol checker (instantiate or bind per port)
// ----------------------------------------------------------------------------
// Per channel: VALID held until READY, payload stable while VALID && !READY,
// no X on VALID out of reset. VALIDs low in reset. No EXOKAY response
// (AXI4-Lite has no exclusive access). Failures go through `uvm_error.
// ============================================================================
`ifndef AXIL_SVA_SV
`define AXIL_SVA_SV
module axil_sva #(parameter string NAME = "axil") (axil_if vif);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  wire clk = vif.aclk;
  wire rst_n = vif.aresetn;

  aw_hold:   assert property (@(posedge clk) disable iff (!rst_n) (vif.awvalid && !vif.awready) |=> vif.awvalid)
    else `uvm_error({NAME, "_SVA"}, "AW: VALID dropped before READY")
  aw_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.awvalid && !vif.awready) |=> $stable({vif.awaddr, vif.awprot}))
    else `uvm_error({NAME, "_SVA"}, "AW: payload changed while VALID && !READY")
  w_hold:    assert property (@(posedge clk) disable iff (!rst_n) (vif.wvalid && !vif.wready) |=> vif.wvalid)
    else `uvm_error({NAME, "_SVA"}, "W: VALID dropped before READY")
  w_stable:  assert property (@(posedge clk) disable iff (!rst_n) (vif.wvalid && !vif.wready) |=> $stable({vif.wdata, vif.wstrb}))
    else `uvm_error({NAME, "_SVA"}, "W: payload changed while VALID && !READY")
  b_hold:    assert property (@(posedge clk) disable iff (!rst_n) (vif.bvalid && !vif.bready) |=> vif.bvalid)
    else `uvm_error({NAME, "_SVA"}, "B: VALID dropped before READY")
  b_stable:  assert property (@(posedge clk) disable iff (!rst_n) (vif.bvalid && !vif.bready) |=> $stable(vif.bresp))
    else `uvm_error({NAME, "_SVA"}, "B: payload changed while VALID && !READY")
  ar_hold:   assert property (@(posedge clk) disable iff (!rst_n) (vif.arvalid && !vif.arready) |=> vif.arvalid)
    else `uvm_error({NAME, "_SVA"}, "AR: VALID dropped before READY")
  ar_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.arvalid && !vif.arready) |=> $stable({vif.araddr, vif.arprot}))
    else `uvm_error({NAME, "_SVA"}, "AR: payload changed while VALID && !READY")
  r_hold:    assert property (@(posedge clk) disable iff (!rst_n) (vif.rvalid && !vif.rready) |=> vif.rvalid)
    else `uvm_error({NAME, "_SVA"}, "R: VALID dropped before READY")
  r_stable:  assert property (@(posedge clk) disable iff (!rst_n) (vif.rvalid && !vif.rready) |=> $stable({vif.rdata, vif.rresp}))
    else `uvm_error({NAME, "_SVA"}, "R: payload changed while VALID && !READY")
  valids_known: assert property (@(posedge clk) disable iff (!rst_n)
                  !$isunknown({vif.awvalid, vif.wvalid, vif.bvalid, vif.arvalid, vif.rvalid}))
    else `uvm_error({NAME, "_SVA"}, "a VALID is X/Z")
  reset_valids: assert property (@(posedge clk) !rst_n |-> !(vif.awvalid === 1'b1 || vif.wvalid === 1'b1 ||
                                  vif.arvalid === 1'b1 || vif.bvalid === 1'b1 || vif.rvalid === 1'b1))
    else `uvm_error({NAME, "_SVA"}, "VALID asserted during reset")
  no_exokay: assert property (@(posedge clk) disable iff (!rst_n)
               (vif.bvalid |-> vif.bresp != 2'b01) and (vif.rvalid |-> vif.rresp != 2'b01))
    else `uvm_error({NAME, "_SVA"}, "EXOKAY response on AXI4-Lite")
endmodule
`endif
