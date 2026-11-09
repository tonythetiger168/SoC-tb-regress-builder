// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_test_pkg -- tests for amba_soc_top (select with +UVM_TESTNAME=<name>)
// ----------------------------------------------------------------------------
//   soc_smoke_test        one access to every target, directed value checks
//   soc_sram_test         random bursts on the on-chip SRAM, incl. errors
//   soc_ddr_test          random FIXED/INCR/WRAP, narrow, strobed DDR bursts
//   soc_apb_test          bridge + peripherals + external APB slot
//   soc_decerr_test       unmapped addresses
//   soc_concurrent_test   both masters at once over all targets
//   soc_stress_test       concurrent traffic with heavy back-pressure
// Plusargs: +SOC_ITEMS=<n> scales random traffic, +SOC_TIMING=<0|1|2>
// overrides the timing profile.
// ============================================================================
`ifndef SOC_TEST_PKG_SV
`define SOC_TEST_PKG_SV
package soc_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;
  import apb_pkg::*;
  import soc_env_pkg::*;

  // ==========================================================================
  class soc_base_test extends uvm_test;
    `uvm_component_utils(soc_base_test)
    soc_env_cfg cfg;
    soc_env     env;
    int unsigned n_items = 40;
    int          timing  = 1;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // override to change the configuration before the env is built
    virtual function void configure();
    endfunction

    function void build_phase(uvm_phase phase);
      int v;
      super.build_phase(phase);
      cfg = soc_env_cfg::type_id::create("cfg");
      configure();
      if ($value$plusargs("SOC_ITEMS=%d", v)) n_items = v;
      if ($value$plusargs("SOC_TIMING=%d", v)) timing = v;
      cfg.set_timing(timing);
      cfg.apply_error_windows();
      uvm_config_db#(soc_env_cfg)::set(this, "env", "cfg", cfg);
      env = soc_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      `uvm_info("TEST", $sformatf("%s: items=%0d timing=%0d", get_type_name(), n_items, timing), UVM_NONE)
    endfunction

    virtual task main();
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      main();
      #100ns;
      phase.drop_objection(this);
    endtask

    function axi4_sequencer sqr(int m);
      return env.m_agent[m].sqr;
    endfunction

    // directed helpers with an optional expected value
    task wr32(int m, bit [31:0] a, bit [31:0] d, axi4_resp_e exp = AXI4_OKAY, bit [3:0] strb = 4'hF);
      axi4_resp_e r;
      axi4_api::write32(sqr(m), a, d, r, strb, 8'(m + 1));
      if (r != exp) `uvm_error("TEST", $sformatf("write %08h: resp %s, expected %s", a, r.name(), exp.name()))
    endtask

    task rd32(int m, bit [31:0] a, output bit [31:0] d, input axi4_resp_e exp = AXI4_OKAY);
      axi4_resp_e r;
      axi4_api::read32(sqr(m), a, d, r, 8'(m + 1));
      if (r != exp) `uvm_error("TEST", $sformatf("read %08h: resp %s, expected %s", a, r.name(), exp.name()))
    endtask

    task rd32_expect(int m, bit [31:0] a, bit [31:0] exp_d, axi4_resp_e exp = AXI4_OKAY);
      bit [31:0] d;
      rd32(m, a, d, exp);
      if (d !== exp_d) `uvm_error("TEST", $sformatf("read %08h = %08h, expected %08h", a, d, exp_d))
    endtask

    // random traffic on master m inside [lo, hi]
    task random_traffic(int m, bit [31:0] lo, bit [31:0] hi, int unsigned n,
                        int unsigned max_beats = 16, bit narrow = 1, bit wrap = 1, bit fixed = 1);
      axi4_random_seq s = axi4_random_seq::type_id::create($sformatf("rand_m%0d", m));
      s.n_items = n; s.lo = lo; s.hi = hi; s.max_beats = max_beats;
      s.allow_narrow = narrow; s.allow_partial_strb = 1; s.allow_wrap = wrap; s.allow_fixed = fixed;
      s.max_delay = (timing == 0) ? 0 : (timing == 1) ? 2 : 5;
      s.start(sqr(m));
    endtask

    // one random APB-window burst for the bridge (word or narrow), slot chosen
    // among GPIO / UART / external / unmapped. Peripheral accesses stay on the
    // registers the scoreboard models (ID, SCRATCH, unmapped offsets).
    task apb_random_burst(int m, bit [11:0] ext_lo = 12'h000, bit [11:0] ext_hi = 12'hFFF);
      int unsigned slot = $urandom_range(9, 0);
      axi4_item t;
      if (slot < 2 || slot == 9) begin
        bit [31:0] base = (slot == 9) ? 32'h1000_3000 + 32'h1000 * $urandom_range(12, 0)
                                      : (slot == 0) ? GPIO_BASE : UART_BASE;
        bit [11:0] offs[$] = '{12'h000, 12'h010, 12'h010, 12'h040, 12'hFFC, 12'h012};
        bit [11:0] off = offs[$urandom_range(offs.size() - 1, 0)];
        bit [2:0]  sz  = (off[1:0] != 0) ? 3'd1 : 3'd2;
        t = axi4_api::make($urandom_range(1, 0), base + off, 1, sz, AXI4_INCR, 8'(m));
        if (t.write && $urandom_range(3, 0) == 0) t.strb[0] = t.lanes(0) & 4'($urandom());
      end else begin
        axi4_random_seq g = axi4_random_seq::type_id::create("g");
        g.lo = APBX_BASE + ext_lo; g.hi = APBX_BASE + ext_hi; g.max_beats = 8;
        g.id_width = 4;
        t = g.gen();
      end
      axi4_api::run(sqr(m), t);
    endtask
  endclass

  // ==========================================================================
  class soc_smoke_test extends soc_base_test;
    `uvm_component_utils(soc_smoke_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      bit [31:0] d;
      rd32_expect(0, GPIO_BASE + REG_ID, GPIO_ID);
      rd32_expect(0, UART_BASE + REG_ID, UART_ID);
      wr32(0, GPIO_BASE + REG_SCRATCH, 32'hCAFE_0001);
      wr32(1, UART_BASE + REG_SCRATCH, 32'hCAFE_0002);
      rd32_expect(1, GPIO_BASE + REG_SCRATCH, 32'hCAFE_0001);
      rd32_expect(0, UART_BASE + REG_SCRATCH, 32'hCAFE_0002);
      rd32(0, GPIO_BASE + 12'h100, d, AXI4_SLVERR);           // unmapped register
      rd32(0, 32'h1000_7000, d, AXI4_SLVERR);                  // unmapped APB slot
      wr32(0, SRAM_BASE + 32'h10, 32'h1234_5678);
      rd32_expect(1, SRAM_BASE + 32'h10, 32'h1234_5678);
      wr32(0, SRAM_BASE + 32'h400, 32'h0, AXI4_SLVERR);        // beyond the 1 KB SRAM
      wr32(1, DDR_BASE + 32'h100, 32'hA5A5_5A5A);
      rd32_expect(0, DDR_BASE + 32'h100, 32'hA5A5_5A5A);
      if (cfg.ddr_mem.peek32(DDR_BASE + 32'h100) != 32'hA5A5_5A5A)
        `uvm_error("TEST", "DDR backdoor does not hold the written word")
      cfg.ddr_mem.poke32(DDR_BASE + 32'h200, 32'h0BAD_F00D);   // backdoor preload
      env.sb.note_ddr_backdoor(DDR_BASE + 32'h200, 32'h0BAD_F00D);
      rd32_expect(1, DDR_BASE + 32'h200, 32'h0BAD_F00D);
      wr32(0, APBX_BASE + 32'h20, 32'hFEED_BEEF);
      rd32_expect(1, APBX_BASE + 32'h20, 32'hFEED_BEEF);
      wr32(0, cfg.apbx_err_lo, 32'h1, AXI4_SLVERR);            // external slot PSLVERR
      wr32(0, cfg.ddr_err_lo, 32'h1, AXI4_SLVERR);             // DDR model SLVERR
      rd32(1, 32'h4000_0000, d, AXI4_DECERR);                  // unmapped
      wr32(1, 32'hF000_0000, 32'h1, AXI4_DECERR);
    endtask
  endclass

  // ==========================================================================
  class soc_sram_test extends soc_base_test;
    `uvm_component_utils(soc_sram_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      // word-sized bursts only: open-ip AXI4_top steps every beat by 4 bytes
      // whatever AxSIZE says (documented limitation of that IP)
      random_traffic(0, SRAM_BASE, SRAM_BASE + 32'h3FF, n_items, 16, 0, 0, 1);
      random_traffic(0, SRAM_BASE, SRAM_BASE + 32'h7FF, n_items, 20, 0, 1, 1);  // errors too
    endtask
  endclass

  // ==========================================================================
  class soc_ddr_test extends soc_base_test;
    `uvm_component_utils(soc_ddr_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      random_traffic(0, DDR_BASE, DDR_BASE + 32'h1FFF, n_items, 64);
      random_traffic(1, DDR_BASE + 32'h0100_0000, DDR_BASE + 32'h0100_0FFF, n_items / 2, 256);
      random_traffic(0, cfg.ddr_err_lo - 32'h1000, cfg.ddr_err_hi, n_items / 4, 16);  // error window
    endtask
  endclass

  // ==========================================================================
  class soc_apb_test extends soc_base_test;
    `uvm_component_utils(soc_apb_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void configure();
      timing = 2;   // external slot with wait states
    endfunction
    task main();
      repeat (n_items) apb_random_burst($urandom_range(1, 0));
    endtask
  endclass

  // ==========================================================================
  class soc_decerr_test extends soc_base_test;
    `uvm_component_utils(soc_decerr_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      bit [31:0] holes[$] = '{32'h0001_0000, 32'h0FFF_F000, 32'h1001_0000, 32'h2000_0000,
                              32'h7FFF_F000, 32'h9000_0000, 32'hFFFF_F000};
      foreach (holes[i]) random_traffic(i % 2, holes[i], holes[i] + 32'hFFF, 4, 16);
    endtask
  endclass

  // ==========================================================================
  // both masters at once; SRAM / DDR / external-APB addresses are partitioned
  // per master (scoreboard concurrency contract); peripheral SCRATCH registers
  // are shared, which the scoreboard handles (APB accesses are serialized).
  class soc_concurrent_test extends soc_base_test;
    `uvm_component_utils(soc_concurrent_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task traffic(int m);
      bit [31:0] sram_lo = m ? 32'h200 : 32'h000;
      bit [31:0] ddr_lo  = DDR_BASE + (m ? 32'h0001_0000 : 32'h0);
      bit [11:0] ext_lo  = m ? 12'h800 : 12'h000;
      for (int unsigned i = 0; i < n_items; i++)
        case ($urandom_range(3, 0))
          0: random_traffic(m, sram_lo, sram_lo + 32'h1FF, 1, 16, 0, 0, 1);
          1: random_traffic(m, ddr_lo, ddr_lo + 32'h1FFF, 1, 32);
          2: apb_random_burst(m, ext_lo, ext_lo + 12'h7FF);
          3: random_traffic(m, 32'h2000_0000 + 32'h1000 * m, 32'h2000_0FFF + 32'h1000 * m, 1, 4);
        endcase
    endtask
    task main();
      fork
        traffic(0);
        traffic(1);
      join
    endtask
  endclass

  // ==========================================================================
  class soc_stress_test extends soc_concurrent_test;
    `uvm_component_utils(soc_stress_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void configure();
      timing  = 2;
      n_items = 80;
    endfunction
  endclass
endpackage
`endif
