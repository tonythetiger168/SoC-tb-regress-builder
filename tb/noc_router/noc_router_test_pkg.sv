// SPDX-License-Identifier: Apache-2.0
// noc_router_test_pkg -- UVM wrapper of the noc_router_open unit bench: the
// stimulus and scoreboard live in noc_router_tb_top; the test only keeps the
// run open until the bench is done, so the UVM report summary (UVM_ERROR /
// UVM_FATAL counts) closes the log as in every other bench.
package noc_router_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  bit done = 1'b0;

  class noc_router_random extends uvm_test;
    `uvm_component_utils(noc_router_random)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      wait (done);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
