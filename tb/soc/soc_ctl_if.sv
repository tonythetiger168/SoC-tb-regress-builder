// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_ctl_if -- testbench controls a test drives through config_db
// ("ctl_vif"): rst_req pulses aresetn low for a few clocks mid-test; clk and
// rstn let the test wait on the bench clock and reset.
// ============================================================================
interface soc_ctl_if (input logic clk, input logic rstn);
  logic rst_req = 1'b0;
endinterface
