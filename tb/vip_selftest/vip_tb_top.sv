// SPDX-License-Identifier: Apache-2.0
// vip_tb_top -- VIP loopback testbench: AXI4 master <-> AXI4 slave and
// APB requester <-> APB completer on shared interfaces, with the SVA checkers.
`timescale 1ns/1ps
module vip_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vip_test_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
  end

  axi4_if axi (.aclk(clk), .aresetn(rst_n));
  apb_if  apb (.pclk(clk), .presetn(rst_n));

  axi4_sva #(.NAME("axi")) u_axi_sva (axi);
  apb_sva  #(.NAME("apb")) u_apb_sva (apb);

  initial begin
    uvm_config_db#(virtual axi4_if)::set(null, "uvm_test_top.axi_*", "vif", axi);
    uvm_config_db#(virtual apb_if)::set(null, "uvm_test_top.apb_*", "vif", apb);
    run_test();
  end

  initial begin
    #5ms;
    `uvm_fatal("TB", "watchdog timeout")
  end
endmodule
