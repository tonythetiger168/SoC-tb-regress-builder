// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axi4_sva -- AXI4 handshake protocol checker (bind or instantiate per port)
// ----------------------------------------------------------------------------
// Checks, per channel: no X on VALID out of reset, VALID held until READY,
// payload stable while VALID && !READY. Plus: VALIDs low during reset, no
// reserved burst type, WRAP length 2/4/8/16, bursts do not cross 4 KB.
// Failures are reported through UVM (`uvm_error) so they fail the test.
// ============================================================================
`ifndef AXI4_SVA_SV
`define AXI4_SVA_SV
module axi4_sva #(parameter string NAME = "axi4") (axi4_if vif);
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  wire clk = vif.aclk;
  wire rst_n = vif.aresetn;

  function automatic bit crosses_4k(logic [31:0] a, logic [7:0] len, logic [2:0] size, logic [1:0] burst);
    logic [31:0] last;
    if (burst != 2'b01) return 0;
    last = (a & ~((32'd1 << size) - 1)) + ((32'(len)) << size);
    return a[31:12] != last[31:12];
  endfunction

  // ---- AW channel ----
  aw_hold: assert property (@(posedge clk) disable iff (!rst_n) (vif.awvalid && !vif.awready) |=> vif.awvalid)
    else `uvm_error({NAME, "_SVA"}, "AW: VALID dropped before READY")
  aw_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.awvalid && !vif.awready) |=> $stable({vif.awid, vif.awaddr, vif.awlen, vif.awsize, vif.awburst, vif.awprot}))
    else `uvm_error({NAME, "_SVA"}, "AW: payload changed while VALID && !READY")
  aw_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(vif.awvalid))
    else `uvm_error({NAME, "_SVA"}, "AW: VALID is X/Z")

  // ---- W channel ----
  w_hold: assert property (@(posedge clk) disable iff (!rst_n) (vif.wvalid && !vif.wready) |=> vif.wvalid)
    else `uvm_error({NAME, "_SVA"}, "W: VALID dropped before READY")
  w_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.wvalid && !vif.wready) |=> $stable({vif.wdata, vif.wstrb, vif.wlast}))
    else `uvm_error({NAME, "_SVA"}, "W: payload changed while VALID && !READY")
  w_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(vif.wvalid))
    else `uvm_error({NAME, "_SVA"}, "W: VALID is X/Z")

  // ---- B channel ----
  b_hold: assert property (@(posedge clk) disable iff (!rst_n) (vif.bvalid && !vif.bready) |=> vif.bvalid)
    else `uvm_error({NAME, "_SVA"}, "B: VALID dropped before READY")
  b_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.bvalid && !vif.bready) |=> $stable({vif.bid, vif.bresp}))
    else `uvm_error({NAME, "_SVA"}, "B: payload changed while VALID && !READY")
  b_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(vif.bvalid))
    else `uvm_error({NAME, "_SVA"}, "B: VALID is X/Z")

  // ---- AR channel ----
  ar_hold: assert property (@(posedge clk) disable iff (!rst_n) (vif.arvalid && !vif.arready) |=> vif.arvalid)
    else `uvm_error({NAME, "_SVA"}, "AR: VALID dropped before READY")
  ar_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.arvalid && !vif.arready) |=> $stable({vif.arid, vif.araddr, vif.arlen, vif.arsize, vif.arburst, vif.arprot}))
    else `uvm_error({NAME, "_SVA"}, "AR: payload changed while VALID && !READY")
  ar_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(vif.arvalid))
    else `uvm_error({NAME, "_SVA"}, "AR: VALID is X/Z")

  // ---- R channel ----
  r_hold: assert property (@(posedge clk) disable iff (!rst_n) (vif.rvalid && !vif.rready) |=> vif.rvalid)
    else `uvm_error({NAME, "_SVA"}, "R: VALID dropped before READY")
  r_stable: assert property (@(posedge clk) disable iff (!rst_n) (vif.rvalid && !vif.rready) |=> $stable({vif.rid, vif.rdata, vif.rresp, vif.rlast}))
    else `uvm_error({NAME, "_SVA"}, "R: payload changed while VALID && !READY")
  r_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(vif.rvalid))
    else `uvm_error({NAME, "_SVA"}, "R: VALID is X/Z")


  // VALIDs must be low while reset is asserted (checked on the clock edge)
  reset_valids: assert property (@(posedge clk) !rst_n |-> !(vif.awvalid === 1'b1 || vif.wvalid === 1'b1 ||
                                  vif.arvalid === 1'b1 || vif.bvalid === 1'b1 || vif.rvalid === 1'b1))
    else `uvm_error({NAME, "_SVA"}, "VALID asserted during reset");

  aw_burst_legal: assert property (@(posedge clk) disable iff (!rst_n)
                    vif.awvalid |-> (vif.awburst != 2'b11) &&
                                    (vif.awburst != 2'b10 || vif.awlen inside {8'd1, 8'd3, 8'd7, 8'd15}) &&
                                    !crosses_4k(vif.awaddr, vif.awlen, vif.awsize, vif.awburst))
    else `uvm_error({NAME, "_SVA"}, "illegal AW burst (reserved type, WRAP length or 4 KB crossing)");

  ar_burst_legal: assert property (@(posedge clk) disable iff (!rst_n)
                    vif.arvalid |-> (vif.arburst != 2'b11) &&
                                    (vif.arburst != 2'b10 || vif.arlen inside {8'd1, 8'd3, 8'd7, 8'd15}) &&
                                    !crosses_4k(vif.araddr, vif.arlen, vif.arsize, vif.arburst))
    else `uvm_error({NAME, "_SVA"}, "illegal AR burst (reserved type, WRAP length or 4 KB crossing)");
endmodule
`endif
