// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// vip_test_pkg -- VIP self-tests: each master agent talks straight to the
// matching slave agent (no DUT), so the VIPs are checked against each other
// and against the memory model.
//   vip_axi4_loopback_test   random AXI4 bursts, master <-> memory responder
//   vip_apb_loopback_test    random APB transfers, requester <-> completer
// Pass: every read returns what an independent shadow model predicts, the
// monitors agree with the drivers, and the memory backdoor holds the data.
// ============================================================================
`ifndef VIP_TEST_PKG_SV
`define VIP_TEST_PKG_SV
package vip_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;
  import apb_pkg::*;

  `uvm_analysis_imp_decl(_axi_m)
  `uvm_analysis_imp_decl(_axi_s)
  `uvm_analysis_imp_decl(_apb_m)
  `uvm_analysis_imp_decl(_apb_s)

  // shadow-memory checker for both loopbacks
  class vip_checker extends uvm_scoreboard;
    `uvm_component_utils(vip_checker)
    uvm_analysis_imp_axi_m #(axi4_item, vip_checker) axi_m_imp;
    uvm_analysis_imp_axi_s #(axi4_item, vip_checker) axi_s_imp;
    uvm_analysis_imp_apb_m #(apb_item, vip_checker)  apb_m_imp;
    uvm_analysis_imp_apb_s #(apb_item, vip_checker)  apb_s_imp;
    mem_model  axi_mem, apb_mem;
    axi4_cfg   axi_slv_cfg;
    apb_cfg    apb_slv_cfg;
    byte unsigned axi_shadow[bit [31:0]], apb_shadow[bit [31:0]];
    axi4_item  axi_m_q[$], axi_s_q[$];
    apb_item   apb_m_q[$], apb_s_q[$];
    int unsigned n_checks, n_errors;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      axi_m_imp = new("axi_m_imp", this);
      axi_s_imp = new("axi_s_imp", this);
      apb_m_imp = new("apb_m_imp", this);
      apb_s_imp = new("apb_s_imp", this);
    endfunction

    function void chk(bit ok, string what);
      n_checks++;
      if (!ok) begin n_errors++; `uvm_error("VIP_CHK", what) end
    endfunction

    function byte unsigned axi_exp(bit [31:0] a);
      return axi_shadow.exists(a) ? axi_shadow[a] : mem_model::init_byte(axi_mem.init_kind, a);
    endfunction
    function byte unsigned apb_exp(bit [31:0] a);
      return apb_shadow.exists(a) ? apb_shadow[a] : mem_model::init_byte(apb_mem.init_kind, a);
    endfunction

    // the master-side monitor sees each AXI burst once: predict from it
    virtual function void write_axi_m(axi4_item t);
      axi4_resp_e exp = axi_slv_cfg.resp_for(t.addr);
      for (int unsigned i = 0; i < t.beats(); i++) begin
        bit [31:0] base = t.beat_addr(i) & ~32'h3;
        if (t.write) begin
          if (exp == AXI4_OKAY)
            for (int b = 0; b < 4; b++) if (t.strb[i][b]) axi_shadow[base + b] = t.data[i][8*b +: 8];
        end else begin
          chk(t.resp[i] == exp, $sformatf("AXI %s beat %0d resp %s, expected %s", t.convert2string(), i,
                t.resp[i].name(), exp.name()));
          if (exp == AXI4_OKAY)
            for (int b = 0; b < 4; b++) if (t.lanes(i)[b])
              chk(t.data[i][8*b +: 8] == axi_exp(base + b),
                    $sformatf("AXI %s beat %0d byte %0d = %02h, expected %02h", t.convert2string(), i, b,
                              t.data[i][8*b +: 8], axi_exp(base + b)));
        end
      end
      if (t.write) chk(t.resp[0] == exp, $sformatf("AXI %s BRESP, expected %s", t.convert2string(), exp.name()));
      axi_m_q.push_back(t);
      match_axi();
    endfunction

    virtual function void write_axi_s(axi4_item t);
      axi_s_q.push_back(t);
      match_axi();
    endfunction

    // both monitors watch the same wires: they must report identical bursts
    function void match_axi();
      while (axi_m_q.size() && axi_s_q.size()) begin
        axi4_item m = axi_m_q.pop_front(), s = axi_s_q.pop_front();
        bit ok = m.write == s.write && m.addr == s.addr && m.len == s.len && m.id == s.id &&
                 m.data == s.data && m.resp == s.resp;
        chk(ok, $sformatf("AXI monitors disagree: {%s} vs {%s}", m.convert2string(), s.convert2string()));
      end
    endfunction

    virtual function void write_apb_m(apb_item t);
      bit [31:0] base = t.addr & ~32'h3;
      bit err = apb_slv_cfg.is_err(t.addr);
      chk(t.slverr == err, $sformatf("APB %s: PSLVERR expected %0b", t.convert2string(), err));
      if (t.write && !err)
        for (int b = 0; b < 4; b++) if (t.strb[b]) apb_shadow[base + b] = t.data[8*b +: 8];
      if (!t.write && !err)
        for (int b = 0; b < 4; b++)
          chk(t.data[8*b +: 8] == apb_exp(base + b), $sformatf("APB %s: byte %0d expected %02h",
                t.convert2string(), b, apb_exp(base + b)));
      apb_m_q.push_back(t);
      while (apb_m_q.size() && apb_s_q.size()) begin
        apb_item a = apb_m_q.pop_front(), c = apb_s_q.pop_front();
        chk(a.addr == c.addr && a.data == c.data && a.write == c.write && a.slverr == c.slverr,
              $sformatf("APB monitors disagree: {%s} vs {%s}", a.convert2string(), c.convert2string()));
      end
    endfunction

    virtual function void write_apb_s(apb_item t);
      apb_s_q.push_back(t);
    endfunction

    function void check_phase(uvm_phase phase);
      // backdoor: the memory model must hold exactly what the shadow holds
      foreach (axi_shadow[a]) chk(axi_mem.read_byte(a) == axi_shadow[a],
                                    $sformatf("AXI memory backdoor at %08h", a));
      foreach (apb_shadow[a]) chk(apb_mem.read_byte(a) == apb_shadow[a],
                                    $sformatf("APB memory backdoor at %08h", a));
      if (n_checks == 0) `uvm_error("VIP_CHK", "no checks were made")
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("VIP_CHK", $sformatf("checks=%0d errors=%0d", n_checks, n_errors), UVM_NONE)
      if (n_errors == 0 && n_checks > 0) $display("SB_PASS checks=%0d", n_checks);
    endfunction
  endclass

  // ==========================================================================
  class vip_base_test extends uvm_test;
    `uvm_component_utils(vip_base_test)
    axi4_cfg    axi_m_cfg, axi_s_cfg;
    apb_cfg     apb_m_cfg, apb_s_cfg;
    axi4_agent  axi_m, axi_s;
    apb_agent   apb_m, apb_s;
    vip_checker chk;
    int unsigned n_items = 200;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      int v;
      super.build_phase(phase);
      if ($value$plusargs("SOC_ITEMS=%d", v)) n_items = v;
      axi_m_cfg = axi4_cfg::type_id::create("axi_m_cfg");
      axi_m_cfg.max_b_delay = 3; axi_m_cfg.max_r_gap = 3;
      axi_s_cfg = axi4_cfg::type_id::create("axi_s_cfg");
      axi_s_cfg.role = AXI4_SLAVE; axi_s_cfg.port = 1;
      axi_s_cfg.max_aready_delay = 3; axi_s_cfg.max_wready_delay = 3; axi_s_cfg.max_b_latency = 4;
      axi_s_cfg.max_r_latency = 6; axi_s_cfg.max_rvalid_gap = 3;
      axi_s_cfg.mem = mem_model::type_id::create("axi_mem");
      axi_s_cfg.add_err_range(32'h0000_F000, 32'h0000_FFFF, AXI4_SLVERR);
      axi_s_cfg.add_err_range(32'h0001_0000, 32'h0001_0FFF, AXI4_DECERR);
      apb_m_cfg = apb_cfg::type_id::create("apb_m_cfg");
      apb_s_cfg = apb_cfg::type_id::create("apb_s_cfg");
      apb_s_cfg.role = APB_SLAVE; apb_s_cfg.max_wait = 4;
      apb_s_cfg.mem = mem_model::type_id::create("apb_mem");
      apb_s_cfg.mem.init_kind = MEM_INIT_ZERO;
      apb_s_cfg.err_lo = 32'h0000_0F00; apb_s_cfg.err_hi = 32'h0000_0FFF;
      uvm_config_db#(axi4_cfg)::set(this, "axi_m", "cfg", axi_m_cfg);
      uvm_config_db#(axi4_cfg)::set(this, "axi_s", "cfg", axi_s_cfg);
      uvm_config_db#(apb_cfg)::set(this, "apb_m", "cfg", apb_m_cfg);
      uvm_config_db#(apb_cfg)::set(this, "apb_s", "cfg", apb_s_cfg);
      axi_m = axi4_agent::type_id::create("axi_m", this);
      axi_s = axi4_agent::type_id::create("axi_s", this);
      apb_m = apb_agent::type_id::create("apb_m", this);
      apb_s = apb_agent::type_id::create("apb_s", this);
      chk   = vip_checker::type_id::create("chk", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      axi_m.ap.connect(chk.axi_m_imp);
      axi_s.ap.connect(chk.axi_s_imp);
      apb_m.ap.connect(chk.apb_m_imp);
      apb_s.ap.connect(chk.apb_s_imp);
      chk.axi_mem = axi_s_cfg.mem; chk.axi_slv_cfg = axi_s_cfg;
      chk.apb_mem = apb_s_cfg.mem; chk.apb_slv_cfg = apb_s_cfg;
    endfunction

    virtual task main();
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      main();
      #100ns;
      phase.drop_objection(this);
    endtask
  endclass

  class vip_axi4_loopback_test extends vip_base_test;
    `uvm_component_utils(vip_axi4_loopback_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      axi4_random_seq s = axi4_random_seq::type_id::create("s");
      s.n_items = n_items; s.lo = 32'h0000_0000; s.hi = 32'h0001_0FFF; s.max_beats = 32;
      s.id_width = 8; s.max_delay = 3;
      s.start(axi_m.sqr);
      // directed: WRAP read back of a known pattern
      begin
        axi4_item w = axi4_api::make(1, 32'h100, 4, 2, AXI4_INCR), r;
        axi4_api::run(axi_m.sqr, w);
        r = axi4_api::make(0, 32'h108, 4, 2, AXI4_WRAP);
        axi4_api::run(axi_m.sqr, r);
        if (r.data[0] != w.data[2] || r.data[1] != w.data[3] || r.data[2] != w.data[0] || r.data[3] != w.data[1])
          `uvm_error("TEST", "WRAP read did not wrap at the 16-byte boundary")
      end
    endtask
  endclass

  class vip_apb_loopback_test extends vip_base_test;
    `uvm_component_utils(vip_apb_loopback_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      apb_random_seq s = apb_random_seq::type_id::create("s");
      bit [31:0] d;
      bit err;
      s.n_items = n_items; s.lo = 0; s.hi = 32'hFFF;
      s.start(apb_m.sqr);
      apb_api::write(apb_m.sqr, 32'h40, 32'h1122_3344, err);
      apb_api::write(apb_m.sqr, 32'h40, 32'hAA00_0000, err, 4'b1000);
      apb_api::read(apb_m.sqr, 32'h40, d, err);
      if (d != 32'hAA22_3344 || err) `uvm_error("TEST", $sformatf("strobed write read back %08h", d))
    endtask
  endclass
endpackage
`endif
