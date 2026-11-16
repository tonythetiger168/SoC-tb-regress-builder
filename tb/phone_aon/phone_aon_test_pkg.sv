// SPDX-License-Identifier: Apache-2.0
// phone_aon_test_pkg -- UVM wrapper of the phone_aon_arb unit bench: the
// stimulus and checks live in phone_aon_tb_top; the test keeps the run open
// until the bench is done, so the UVM report summary closes the log as in
// every other bench.
package phone_aon_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  bit done = 1'b0;

  class phone_aon_random extends uvm_test;
    `uvm_component_utils(phone_aon_random)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      wait (done);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
