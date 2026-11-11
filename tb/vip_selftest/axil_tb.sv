// SPDX-License-Identifier: Apache-2.0
// AXI4-Lite VIP self-test: master agent <-> memory responder on one
// interface, with the protocol checker and the VIP's scoreboard.
//   axil_loopback_test  random accesses (AW/W order, skew, strobes, waits,
//                       SLVERR / DECERR windows), then directed strobe checks
`timescale 1ns/1ps
package axil_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axil_pkg::*;

  class axil_loopback_test extends uvm_test;
    `uvm_component_utils(axil_loopback_test)
    axil_cfg        m_cfg, s_cfg;
    axil_agent      m, s;
    axil_scoreboard sb, sb_s;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      m_cfg = axil_cfg::type_id::create("m_cfg");
      s_cfg = axil_cfg::type_id::create("s_cfg");
      s_cfg.role = AXIL_SLAVE;
      s_cfg.max_aready_delay = 3; s_cfg.max_wready_delay = 3; s_cfg.max_resp_delay = 4;
      s_cfg.mem = mem_model::type_id::create("mem");
      s_cfg.add_err_range(32'h0000_0F00, 32'h0000_0FFF, AXIL_SLVERR);
      s_cfg.add_err_range(32'h0000_1000, 32'h0000_10FF, AXIL_DECERR);
      uvm_config_db#(axil_cfg)::set(this, "m", "cfg", m_cfg);
      uvm_config_db#(axil_cfg)::set(this, "s", "cfg", s_cfg);
      m = axil_agent::type_id::create("m", this);
      s = axil_agent::type_id::create("s", this);
      sb = axil_scoreboard::type_id::create("sb", this);
      sb_s = axil_scoreboard::type_id::create("sb_s", this);
      sb.slv_cfg = s_cfg; sb_s.slv_cfg = s_cfg;
    endfunction
    function void connect_phase(uvm_phase phase);
      m.ap.connect(sb.analysis_export);
      s.ap.connect(sb_s.analysis_export);
    endfunction
    task run_phase(uvm_phase phase);
      axil_random_seq seq = axil_random_seq::type_id::create("seq");
      bit [31:0] d;
      axil_resp_e r;
      phase.raise_objection(this);
      seq.n_items = 300; seq.lo = 0; seq.hi = 32'h10FF;
      seq.start(m.sqr);
      axil_api::write(m.sqr, 32'h40, 32'h1122_3344, r);
      axil_api::write(m.sqr, 32'h40, 32'hAA00_00BB, r, 4'b1001);
      axil_api::read(m.sqr, 32'h40, d, r);
      if (d != 32'hAA22_33BB || r != AXIL_OKAY) `uvm_error("TEST", $sformatf("strobed write read back %08h %s", d, r.name()))
      axil_api::read(m.sqr, 32'hF00, d, r);
      if (r != AXIL_SLVERR) `uvm_error("TEST", "no SLVERR in the error window")
      axil_api::read(m.sqr, 32'h1000, d, r);
      if (r != AXIL_DECERR) `uvm_error("TEST", "no DECERR in the decode-error window")
      #100ns;
      phase.drop_objection(this);
    endtask
    function void check_phase(uvm_phase phase);
      // the responder's memory must hold what the scoreboard predicted
      foreach (sb.shadow[a])
        if (s_cfg.mem.read_byte(a) != sb.shadow[a]) `uvm_error("TEST", $sformatf("memory backdoor at %08h", a))
      if (sb.n_checks != sb_s.n_checks) `uvm_error("TEST", "the two monitors saw different traffic")
    endfunction
    function void report_phase(uvm_phase phase);
      uvm_report_server srv = uvm_report_server::get_server();
      if (sb.n_checks > 0 && srv.get_severity_count(UVM_ERROR) == 0 && srv.get_severity_count(UVM_FATAL) == 0)
        $display("SB_PASS checks=%0d", sb.n_checks);
    endfunction
  endclass
endpackage

module axil_tb;
  import uvm_pkg::*;
  import axil_test_pkg::*;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
  end
  axil_if bus (.aclk(clk), .aresetn(rst_n));
  axil_sva #(.NAME("axil")) u_sva (bus);
  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.*", "vif", bus);
    run_test();
  end
  initial begin
    #20ms;
    $display("watchdog timeout");
    $finish;
  end
endmodule
