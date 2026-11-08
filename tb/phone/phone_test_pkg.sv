// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_test_pkg -- tests for phone_soc_top (+UVM_TESTNAME=<name>)
// ----------------------------------------------------------------------------
//   phone_smoke_test     every master on every LPDDR5 channel, SRAM, DECERR,
//                        ECC-error page, RAL ID / SCRATCH of every APB block
//   phone_ral_test       RAL: hardware reset values, bit-bash, IOMMU registers
//   phone_iommu_test     6 IOMMUs: shuffled page tables, read-only pages,
//                        holes, out-of-window IOVAs, TLB flush; FAULT_* and
//                        TLB counters checked against the scoreboard
//   phone_lpddr5_test    page hit < miss < conflict latency on one channel,
//                        refresh on every channel
//   phone_camera_test    ISP -> frame buffers -> VENC encode + DISP preview,
//                        ICP / CPU / ADSP / MODEM in the background
//   phone_video_test     UFS -> bitstream -> VDEC -> frames -> DISP, + audio, WiFi
//   phone_gaming_test    GPU render / DISP scan-out ping-pong, CPU, MODEM, SCP
//   phone_ai_test        CPU loads weights, APU inference, ISP frames, SEC, DMA
//   phone_stress_test    all 15 masters at once, heavy back-pressure, faults
//   phone_ss_test        real-IP build only: every open-ip subsystem IP runs
//                        jobs checked against reference models
// Plusargs: +SOC_ITEMS=<n>, +SOC_TIMING=<0|1|2>, +LP5_SPEED=<0..3>
// (5500 / 6400 / 7500 / 8533), +LP5_PAGE=<0 open|1 closed>,
// +LP5_REF=<0 all-bank|1 per-bank>.
// ============================================================================
`ifndef PHONE_TEST_PKG_SV
`define PHONE_TEST_PKG_SV
package phone_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;
  import apb_pkg::*;
  import lpddr5_pkg::*;
  import soc_env_pkg::*;
  import phone_soc_pkg::*;
  import phone_ral_pkg::*;
  import phone_env_pkg::*;

  // ==========================================================================
  // traffic profiles: the usual shape of each subsystem's DRAM traffic
  // ==========================================================================
  class phone_profile;
    int unsigned wr_pct, min_beats, max_beats;
    bit stream, narrow, wrap, pstrb;
    function new(int unsigned wr = 50, int unsigned mn = 1, int unsigned mx = 16,
                 bit st = 0, bit nar = 0, bit wp = 0, bit ps = 1);
      wr_pct = wr; min_beats = mn; max_beats = mx; stream = st; narrow = nar; wrap = wp; pstrb = ps;
    endfunction
    static function phone_profile mk(int unsigned wr = 50, int unsigned mn = 1, int unsigned mx = 16,
                                     bit st = 0, bit nar = 0, bit wp = 0, bit ps = 1);
      phone_profile p = new(wr, mn, mx, st, nar, wp, ps);
      return p;
    endfunction
    function phone_profile with_wr(int unsigned wr);
      phone_profile p = new(wr, min_beats, max_beats, stream, narrow, wrap, pstrb);
      return p;
    endfunction
  endclass

  function automatic phone_profile profile_of(int m);
    phone_profile p;
    case (m)
      M_CPU:   p = new(35,   1,  16, 0, 1, 1);   // cache-line fills (WRAP 16), narrow, random
      M_GPU:   p = new(40,   8,  64, 0);         // tiles / textures
      M_APU:   p = new(20,  64, 256, 1);         // weight streaming
      M_ISP:   p = new(90, 128, 256, 1);         // frame writes
      M_ICP:   p = new(50,   1,  16, 0);         // statistics, control
      M_VDEC:  p = new(60,  16, 128, 1);
      M_VENC:  p = new(30,  32, 256, 1);
      M_DISP:  p = new( 0, 256, 256, 1);         // scan-out
      M_ADSP:  p = new(50,   4,  16, 0, 1);      // audio buffers
      M_MODEM: p = new(50,   1,  32, 0, 1);
      M_CONN:  p = new(50,   1,  32, 0, 1);
      M_SCP:   p = new(50,   1,   8, 0, 1);
      M_UFS:   p = new(50,  64, 128, 1);
      M_SEC:   p = new(50,  16,  64, 1);
      default: p = new(50,  64, 256, 1);         // system DMA
    endcase
    return p;
  endfunction

  // random or streaming bursts inside [lo, hi]
  class phone_traffic_seq extends uvm_sequence #(axi4_item);
    `uvm_object_utils(phone_traffic_seq)
    bit [31:0]    lo, hi;
    int unsigned  n_items = 20, id_width = 4, max_delay = 2;
    phone_profile prof;
    bit [31:0]    cur;

    function new(string name = "phone_traffic_seq");
      super.new(name);
    endfunction

    function axi4_item gen();
      axi4_item t;
      for (int tries = 0; tries < 200; tries++) begin
        bit [2:0] size = (prof.narrow && $urandom_range(3, 0) == 0) ? 3'($urandom_range(1, 0)) : 3'd2;
        int unsigned nb = 1 << size;
        int unsigned beats = $urandom_range(prof.max_beats, prof.min_beats);
        axi4_burst_e burst = AXI4_INCR;
        bit [31:0] a;
        if (prof.stream) begin
          a = cur;
          size = 2; nb = 4;
        end else begin
          if (prof.wrap && $urandom_range(3, 0) == 0) begin
            int unsigned wl[$] = '{4, 8, 16};
            burst = AXI4_WRAP;
            beats = wl[$urandom_range(2, 0)];
          end
          if (hi - lo + 1 < beats * nb) continue;
          a = (lo + $urandom_range(hi - lo + 1 - beats * nb, 0)) & ~(32'(nb) - 1);
          if (burst == AXI4_WRAP) begin
            bit [31:0] wb = a & ~(32'(beats * nb) - 1);
            if (wb < lo) continue;
          end
        end
        if (burst == AXI4_INCR) begin
          int unsigned room = (32'h1000 - (a & 32'hFFF)) / nb;
          int unsigned left = (hi - a + 1) / nb;
          if (room < beats) beats = room;
          if (left < beats) beats = left;
          if (beats == 0) begin cur = lo; continue; end
        end
        t = axi4_api::make($urandom_range(99, 0) < prof.wr_pct, a, beats, size, burst,
                           8'($urandom_range((1 << id_width) - 1, 0)));
        if (t.write && prof.pstrb)
          foreach (t.strb[i]) if ($urandom_range(7, 0) == 0) t.strb[i] = t.lanes(i) & 4'($urandom());
        t.aw_delay = $urandom_range(max_delay, 0);
        t.w_gap = max_delay;
        t.r_gap = max_delay;
        if (prof.stream) begin
          cur = a + beats * nb;
          if (cur > hi || cur < lo) cur = lo;
        end
        return t;
      end
      `uvm_fatal("PHONE_SEQ", $sformatf("cannot fit a burst in [%08h, %08h]", lo, hi))
      return null;
    endfunction

    task body();
      cur = lo;
      repeat (n_items) begin
        axi4_item t = gen();
        start_item(t);
        finish_item(t);
      end
    endtask
  endclass

  // one traffic job of a phase
  class phone_job;
    int m;
    bit [31:0] lo, hi;
    int unsigned n;
    phone_profile prof;
    function new(int m_, bit [31:0] lo_, bit [31:0] hi_, int unsigned n_, phone_profile p = null);
      m = m_; lo = lo_; hi = hi_; n = n_; prof = (p == null) ? profile_of(m_) : p;
    endfunction
    static function phone_job mk(int m_, bit [31:0] lo_, bit [31:0] hi_, int unsigned n_, phone_profile p = null);
      phone_job j = new(m_, lo_, hi_, n_, p);
      return j;
    endfunction
  endclass

  // ==========================================================================
  class phone_base_test extends uvm_test;
    `uvm_component_utils(phone_base_test)
    phone_env_cfg cfg;
    phone_env     env;
    int unsigned  n_items = 30;
    int           timing  = 1;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void configure();
    endfunction

    function void build_phase(uvm_phase phase);
      int v;
      super.build_phase(phase);
      cfg = phone_env_cfg::type_id::create("cfg");
      begin
        bit r;
        if (uvm_config_db#(bit)::get(this, "", "real_ips", r)) cfg.set_real_ips(r);
      end
      configure();
      if ($value$plusargs("SOC_ITEMS=%d", v))  n_items = v;
      if ($value$plusargs("SOC_TIMING=%d", v)) timing = v;
      if ($value$plusargs("LP5_SPEED=%d", v))  cfg.set_speed(lpddr5_speed_e'(v));
      if ($value$plusargs("LP5_PAGE=%d", v))   cfg.set_page_policy(lpddr5_page_policy_e'(v));
      if ($value$plusargs("LP5_REF=%d", v))    cfg.set_ref_mode(lpddr5_ref_mode_e'(v));
      cfg.set_phone_timing(timing);
      cfg.apply_error_windows();
      uvm_config_db#(phone_env_cfg)::set(this, "env", "cfg", cfg);
      env = phone_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      `uvm_info("TEST", $sformatf("%s: items=%0d timing=%0d", get_type_name(), n_items, timing), UVM_NONE)
    endfunction

    virtual task main();
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      main();
      #500ns;
      phase.drop_objection(this);
    endtask

    function axi4_sequencer sqr(int m);
      return env.m_agent[m].sqr;
    endfunction

    // ---------------------------------------------------------------- AXI
    task wr32(int m, bit [31:0] a, bit [31:0] d, axi4_resp_e exp = AXI4_OKAY);
      axi4_resp_e r;
      axi4_api::write32(sqr(m), a, d, r, 4'hF, 8'(m % 8));
      if (r != exp) `uvm_error("TEST", $sformatf("%s write %08h: resp %s, expected %s", master_name(m), a,
                                                  r.name(), exp.name()))
    endtask

    task rd32(int m, bit [31:0] a, output bit [31:0] d, input axi4_resp_e exp = AXI4_OKAY);
      axi4_resp_e r;
      axi4_api::read32(sqr(m), a, d, r, 8'(m % 8));
      if (r != exp) `uvm_error("TEST", $sformatf("%s read %08h: resp %s, expected %s", master_name(m), a,
                                                  r.name(), exp.name()))
    endtask

    task traffic(int m, bit [31:0] lo, bit [31:0] hi, int unsigned n, phone_profile p = null);
      phone_traffic_seq s = phone_traffic_seq::type_id::create($sformatf("traffic_%s", master_name(m)));
      s.lo = lo; s.hi = hi; s.n_items = n;
      s.prof = (p == null) ? profile_of(m) : p;
      s.id_width = cfg.pm_cfg[m].id_width;
      s.max_delay = cfg.max_delay;
      s.start(sqr(m));
    endtask

    // run jobs in parallel (one job per master)
    task run_phase_jobs(phone_job jobs[$]);
      foreach (jobs[i]) begin
        automatic phone_job j = jobs[i];
        fork
          traffic(j.m, j.lo, j.hi, j.n, j.prof);
        join_none
      end
      wait fork;
    endtask

    // ---------------------------------------------------------------- RAL
    task reg_write(phone_reg r, uvm_reg_data_t d);
      uvm_status_e st;
      r.write(st, d);
      if (st != UVM_IS_OK) `uvm_error("TEST", {"RAL write failed: ", r.get_full_name()})
    endtask

    task reg_read(phone_reg r, output uvm_reg_data_t d);
      uvm_status_e st;
      r.read(st, d);
      if (st != UVM_IS_OK) `uvm_error("TEST", {"RAL read failed: ", r.get_full_name()})
    endtask

    task reg_expect(phone_reg r, uvm_reg_data_t exp);
      uvm_reg_data_t d;
      reg_read(r, d);
      if (d != exp) `uvm_error("TEST", $sformatf("%s = %08h, expected %08h", r.get_full_name(), d, exp))
    endtask

    // ---------------------------------------------------------------- IOMMU
    function void map_page(int i, int unsigned vpage, bit [31:0] pa, bit r = 1, bit w = 1, bit v = 1);
      bit [31:0] pte = {pa[31:12], 9'b0, w, r, v};
      bit [31:0] a = pt_base_of(i) + vpage * 4;
      cfg.dram_poke32(a, pte);
      env.sb.note_ddr_backdoor(a, pte);
    endfunction

    function bit [31:0] pte_of(int i, int unsigned vpage);
      return cfg.dram_peek32(pt_base_of(i) + vpage * 4);
    endfunction

    // map npages IOVA pages onto npages physical pages from pa_base, shuffled;
    // every ro_every-th page read-only, every hole_every-th page unmapped
    function void map_shuffled(int i, int unsigned npages, bit [31:0] pa_base,
                               int unsigned ro_every = 0, int unsigned hole_every = 0,
                               int unsigned vfirst = 0);
      int unsigned perm[$];
      for (int unsigned k = 0; k < npages; k++) perm.push_back(k);
      perm.shuffle();
      for (int unsigned k = 0; k < npages; k++) begin
        bit hole = hole_every && (k % hole_every == hole_every - 1);
        bit ro   = ro_every && (k % ro_every == ro_every - 1);
        map_page(i, vfirst + k, pa_base + perm[k] * 32'h1000, 1, !ro, !hole);
      end
    endfunction

    // same physical pages as IOMMU src (shared buffer), optionally read-only
    function void map_shared(int i, int unsigned vfirst, int src, int unsigned src_first,
                             int unsigned npages, bit read_only);
      for (int unsigned k = 0; k < npages; k++) begin
        bit [31:0] pte = pte_of(src, src_first + k);
        map_page(i, vfirst + k, {pte[31:12], 12'h0}, 1, !read_only && pte[2], pte[0]);
      end
    endfunction

    task iommu_enable(int i, int unsigned npages, bit en = 1);
      reg_write(env.regmodel.iommu[i].r("PT_BASE"), pt_base_of(i));
      reg_write(env.regmodel.iommu[i].r("VA_BASE"), IOVA_BASE);
      reg_write(env.regmodel.iommu[i].r("VA_SIZE"), npages * 32'h1000);
      reg_write(env.regmodel.iommu[i].r("CTRL"), {en, en});     // EN, IRQ_EN
    endtask

    function bit [31:0] iova(int unsigned vpage);
      return IOVA_BASE + vpage * 32'h1000;
    endfunction

    // DRAM address of master m at offset off of its slice
    function bit [31:0] dram(int m, bit [31:0] off);
      return part_base(m) + off;
    endfunction

    // compare each IOMMU's fault registers and counters with the scoreboard
    task check_iommu_regs(int i);
      uvm_reg_data_t st, fa, fc, miss;
      reg_read(env.regmodel.iommu[i].r("FAULT_STATUS"), st);
      reg_read(env.regmodel.iommu[i].r("FAULT_ADDR"), fa);
      reg_read(env.regmodel.iommu[i].r("FAULT_CNT"), fc);
      reg_read(env.regmodel.iommu[i].r("TLB_MISSES"), miss);
      if (st[0] != env.sb.f_valid[i])
        `uvm_error("TEST", $sformatf("IOMMU%0d FAULT_STATUS.VALID=%0b, scoreboard %0b", i, st[0], env.sb.f_valid[i]))
      else if (st[0] && (st[1] != env.sb.f_write[i] || st[2] != env.sb.f_perm[i] || fa != env.sb.f_addr[i]))
        `uvm_error("TEST", $sformatf("IOMMU%0d fault: STATUS=%0h ADDR=%08h, scoreboard write=%0b perm=%0b addr=%08h",
                   i, st, fa, env.sb.f_write[i], env.sb.f_perm[i], env.sb.f_addr[i]))
      if (fc != env.sb.n_faults[i])
        `uvm_error("TEST", $sformatf("IOMMU%0d FAULT_CNT=%0d, scoreboard saw %0d faulting bursts", i, fc, env.sb.n_faults[i]))
      if (miss != env.sb.n_walks[i])
        `uvm_error("TEST", $sformatf("IOMMU%0d TLB_MISSES=%0d, %0d walks seen on the channels", i, miss, env.sb.n_walks[i]))
      `uvm_info("TEST", $sformatf("IOMMU%0d (%s): FAULT_STATUS=%0h FAULT_ADDR=%08h FAULT_CNT=%0d TLB_MISSES=%0d",
                i, master_name(master_of_iommu(i)), st, fa, fc, miss), UVM_LOW)
    endtask

    task clear_iommu_fault(int i);
      reg_write(env.regmodel.iommu[i].r("FAULT_STATUS"), 1);
      env.sb.clear_fault(i);
    endtask
  endclass

  // ==========================================================================
  class phone_smoke_test extends phone_base_test;
    `uvm_component_utils(phone_smoke_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task main();
      phone_ip_block blks[$];
      bit [31:0] d;
      uvm_status_e st;
      // RAL: ID and SCRATCH of every APB block (CPU frontdoor, APB prediction)
      env.regmodel.ip_blocks(blks);
      foreach (blks[i]) begin
        blks[i].r("ID").mirror(st, UVM_CHECK);
        if (blks[i].regs.exists("SCRATCH")) begin
          bit [31:0] v = $urandom();
          reg_write(blks[i].r("SCRATCH"), v);
          blks[i].r("SCRATCH").mirror(st, UVM_CHECK);
        end
      end
      // every master on every channel (32 consecutive 4 KB granules = 32 channels)
      begin
        phone_job jobs[$];
        for (int m = 0; m < NM; m++) begin
          automatic int mm = m;
          fork begin
            for (int g = 0; g < NCH; g++) begin
              bit [31:0] a = dram(mm, g * 32'h1000 + 32'h40 * mm);
              bit [31:0] v = {8'(mm), 8'(g), 16'hA55A};
              wr32(mm, a, v);
              rd32(mm, a, d);
              if (d != v) `uvm_error("TEST", $sformatf("%s %08h = %08h, expected %08h", master_name(mm), a, d, v))
            end
          end join_none
        end
        wait fork;
      end
      foreach (env.sb.n_per_ch[c])
        if (env.sb.n_per_ch[c] < 2 * NM) `uvm_error("TEST", $sformatf("channel %0d got %0d bursts", c, env.sb.n_per_ch[c]))
      // backdoor through the channel memory
      cfg.dram_poke32(dram(M_CPU, 32'h8000), 32'h0BAD_F00D);
      env.sb.note_ddr_backdoor(dram(M_CPU, 32'h8000), 32'h0BAD_F00D);
      rd32(M_CPU, dram(M_CPU, 32'h8000), d);
      if (d != 32'h0BAD_F00D) `uvm_error("TEST", "DRAM backdoor preload not read back")
      // boot SRAM, ECC-error page, unmapped
      wr32(M_CPU, SRAM_BASE + 32'h20, 32'h1234_5678);
      rd32(M_DMA, SRAM_BASE + 32'h20, d);
      if (d != 32'h1234_5678) `uvm_error("TEST", "SRAM readback")
      wr32(M_CPU, LP5_ERR_LO + 32'h10, 32'h1, AXI4_SLVERR);
      rd32(M_GPU, LP5_ERR_LO, d, AXI4_SLVERR);
      rd32(M_CPU, 32'h4000_0000, d, AXI4_DECERR);       // IOVA space is unmapped for the NoC
      wr32(M_MODEM, 32'h2000_0000, 32'h1, AXI4_DECERR);
      rd32(M_CPU, APB_BASE + 32'hE000, d, AXI4_SLVERR);   // unmapped APB slot
      rd32(M_CPU, APB_SS_BASE, d, AXI4_SLVERR);           // subsystem IP segment, no IP cluster
    endtask
  endclass

  // ==========================================================================
  class phone_ral_test extends phone_base_test;
    `uvm_component_utils(phone_ral_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task main();
      uvm_reg_hw_reset_seq   rst_seq;
      uvm_reg_bit_bash_seq   bash_seq;
      phone_ip_block blks[$];
      uvm_status_e st;
      rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq");
      rst_seq.model = env.regmodel;
      rst_seq.start(null);
      bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq");
      bash_seq.model = env.regmodel;
      bash_seq.start(null);
      // functional register checks
      env.regmodel.ip_blocks(blks);
      foreach (blks[i]) begin
        if (!blks[i].regs.exists("IRQ_ENABLE")) continue;      // IOMMUs have none
        reg_write(blks[i].r("IRQ_ENABLE"), '1);
        blks[i].r("IRQ_ENABLE").mirror(st, UVM_CHECK);
        reg_write(blks[i].r("IRQ_ENABLE"), 0);
      end
      // PWM core registers (write-only) and TRNG configuration
      reg_write(env.regmodel.pwm.r("PERIOD"), 100);
      reg_write(env.regmodel.pwm.r("DUTY"), 25);
      reg_write(env.regmodel.trng.r("HEALTH"), 32'h0003_1929);
      env.regmodel.trng.r("HEALTH").mirror(st, UVM_CHECK);
      // IOMMU: INV reads 0, FAULT registers clear, unaligned window base ignored
      foreach (env.regmodel.iommu[i]) begin
        reg_write(env.regmodel.iommu[i].r("VA_BASE"), 32'h4000_0ABC);
        reg_expect(env.regmodel.iommu[i].r("VA_BASE"), 32'h4000_0000);
        reg_write(env.regmodel.iommu[i].r("INV"), 32'hFFFF_FFFF);
        reg_expect(env.regmodel.iommu[i].r("FAULT_STATUS"), 0);
        reg_expect(env.regmodel.iommu[i].r("FAULT_CNT"), 0);
      end
      // a short burst of the RAL mirror against a raw AXI read
      begin
        bit [31:0] d;
        rd32(cfg.host_m, APB_BASE + 32'h7000 + 32'h00C, d);
        if (d != 32'h4000_0000) `uvm_error("TEST", $sformatf("raw read of IOMMU0 VA_BASE = %08h", d))
      end
    endtask
  endclass

  // ==========================================================================
  class phone_iommu_test extends phone_base_test;
    `uvm_component_utils(phone_iommu_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task main();
      int unsigned np = 64;
      phone_job jobs[$];
      // page tables first (backdoor), then RAL programming
      for (int i = 0; i < NIOMMU; i++) begin
        map_shuffled(i, np, dram(master_of_iommu(i), 0), 7, 11);
        iommu_enable(i, np);
      end
      // traffic over the window and one page past its end
      for (int i = 0; i < NIOMMU; i++) begin
        int m = master_of_iommu(i);
        phone_profile p = new(50, 1, 16, 0, 1, 0);
        jobs.push_back(phone_job::mk(m, iova(0), iova(np + 1) - 1, n_items, p));
      end
      run_phase_jobs(jobs);
      for (int i = 0; i < NIOMMU; i++) begin
        check_iommu_regs(i);
        if (env.sb.n_walks[i] == 0) `uvm_error("TEST", $sformatf("IOMMU%0d never walked", i))
        clear_iommu_fault(i);
      end
      // flush the TLBs, remap the read-only pages writable, traffic again
      for (int i = 0; i < NIOMMU; i++) begin
        for (int unsigned k = 6; k < np; k += 7)
          map_page(i, k, {pte_of(i, k)[31:12], 12'h0}, 1, 1, 1);
        reg_write(env.regmodel.iommu[i].r("INV"), 1);
      end
      jobs.delete();
      for (int i = 0; i < NIOMMU; i++)
        jobs.push_back(phone_job::mk(master_of_iommu(i), iova(0), iova(np) - 1, n_items));
      run_phase_jobs(jobs);
      for (int i = 0; i < NIOMMU; i++) check_iommu_regs(i);
      // bypass: IOMMU 0 off, its master reaches DRAM with physical addresses
      reg_write(env.regmodel.iommu[0].r("CTRL"), 0);
      traffic(M_APU, dram(M_APU, 32'h0010_0000), dram(M_APU, 32'h0010_7FFF), n_items / 2);
    endtask
  endclass

  // ==========================================================================
  class phone_lpddr5_test extends phone_base_test;
    `uvm_component_utils(phone_lpddr5_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void configure();
      timing = 0;
    endfunction

    // an address in the CPU slice on channel ch, bank b, row r (-1 = any row != avoid_row)
    function bit [31:0] find_addr(int ch, int b, int r, int avoid_row = -1);
      lpddr5_cfg lc = cfg.lp_cfg[ch];
      for (int unsigned g = 0; g < 32'h8000; g++)
        for (int h = 0; h < 2; h++) begin
          bit [31:0] a = dram(M_CPU, g * 32'h1000 + h * 32'h800);
          longint unsigned la = lc.local_addr(a);
          if (dram_channel(a) == ch && lc.bank_of(la) == b &&
              (r >= 0 ? lc.row_of(la) == r : lc.row_of(la) != avoid_row))
            return a;
        end
      `uvm_fatal("TEST", $sformatf("no address for ch%0d bank %0d row %0d", ch, b, r))
      return 0;
    endfunction

    task lat_read(bit [31:0] a, output real ns);
      axi4_item t = axi4_api::make(0, a, 1, 2, AXI4_INCR, 0);
      axi4_api::run(sqr(M_CPU), t);
      ns = real'(t.t_end - t.t_start);
    endtask

    task main();
      int ch = 5;
      lpddr5_cfg lc = cfg.lp_cfg[ch];
      real l_miss, l_hit, l_conf, best_miss = 1e9, best_hit = 1e9, best_conf = 1e9;
      bit [31:0] d;
      // three rounds on fresh banks; the minimum filters out refresh collisions
      for (int k = 0; k < 3; k++) begin
        bit [31:0] a = find_addr(ch, 2 + 4 * k, 3);
        bit [31:0] c = find_addr(ch, 2 + 4 * k, -1, 3);
        #200ns;
        lat_read(a, l_miss);              // bank closed: ACT + RD
        #200ns;
        lat_read(a + 32'h40, l_hit);       // same row
        #200ns;
        lat_read(c, l_conf);              // other row: PRE + ACT + RD
        `uvm_info("TEST", $sformatf("round %0d ch%0d bank %0d: miss %.1f ns, hit %.1f ns, conflict %.1f ns",
                  k, ch, 2 + 4 * k, l_miss, l_hit, l_conf), UVM_LOW)
        if (l_miss < best_miss) best_miss = l_miss;
        if (l_hit < best_hit)   best_hit = l_hit;
        if (l_conf < best_conf) best_conf = l_conf;
      end
      if (cfg.lp_cfg[0].page_policy == PAGE_OPEN) begin
        if (!(best_hit + lc.t_rcd - 2 * lc.tck_axi <= best_miss))
          `uvm_error("TEST", $sformatf("page miss %.1f ns is not tRCD (%.1f) slower than a hit %.1f ns",
                     best_miss, lc.t_rcd, best_hit))
        if (!(best_miss + lc.t_rp - 2 * lc.tck_axi <= best_conf))
          `uvm_error("TEST", $sformatf("page conflict %.1f ns is not tRP (%.1f) slower than a miss %.1f ns",
                     best_conf, lc.t_rp, best_miss))
      end else if (best_hit + 2 * lc.tck_axi < best_miss)
        `uvm_error("TEST", $sformatf("closed page: same-row read %.1f ns faster than a miss %.1f ns", best_hit, best_miss))
      // let several refresh intervals pass, then touch every channel
      #(2 * lc.t_refi * 1ns);
      for (int g = 0; g < NCH; g++) rd32(M_DMA, dram(M_DMA, g * 32'h1000), d);
      foreach (env.ch_agent[c])
        if (env.ch_agent[c].model().n_ref == 0) `uvm_error("TEST", $sformatf("channel %0d never refreshed", c))
      // sustained streaming on all masters
      begin
        phone_job jobs[$];
        for (int m = 0; m < NM; m++)
          if (iommu_of(m) < 0) jobs.push_back(phone_job::mk(m, dram(m, 0), dram(m, 32'h3_FFFF), n_items));
        run_phase_jobs(jobs);
      end
    endtask
  endclass

  // ==========================================================================
  // use cases: page tables are set up for the multimedia masters, then the
  // traffic runs in phases; a buffer is never written while it is read.
  // ==========================================================================
  class phone_usecase_test extends phone_base_test;
    `uvm_component_utils(phone_usecase_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    // background traffic of the always-on subsystems
    function void background(ref phone_job jobs[$], input int ms[$]);
      foreach (ms[k]) jobs.push_back(phone_job::mk(ms[k], dram(ms[k], 0), dram(ms[k], 32'hF_FFFF), n_items));
    endfunction
  endclass

  class phone_camera_test extends phone_usecase_test;
    `uvm_component_utils(phone_camera_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      int unsigned fp = 32;                          // pages per frame buffer
      int I_ISP = iommu_of(M_ISP), I_ICP = iommu_of(M_ICP), I_VENC = iommu_of(M_VENC), I_DISP = iommu_of(M_DISP);
      // ISP: FB0 = IOVA pages [0, fp), FB1 = [fp, 2fp), in the ISP's slice
      map_shuffled(I_ISP, 2 * fp, dram(M_ISP, 0));
      // VENC: FB0/FB1 shared read-only, bitstream pages [2fp, 3fp) in its slice
      map_shared(I_VENC, 0, I_ISP, 0, 2 * fp, 1);
      map_shuffled(I_VENC, fp, dram(M_VENC, 0), 0, 0, 2 * fp);
      // DISP: FB0/FB1 shared read-only (preview)
      map_shared(I_DISP, 0, I_ISP, 0, 2 * fp, 1);
      map_shuffled(I_ICP, fp, dram(M_ICP, 0));
      iommu_enable(I_ISP, 2 * fp);
      iommu_enable(I_VENC, 3 * fp);
      iommu_enable(I_DISP, 2 * fp);
      iommu_enable(I_ICP, fp);
      for (int f = 0; f < 3; f++) begin
        phone_job jobs[$];
        int unsigned wfb = f % 2, rfb = 1 - wfb;
        jobs.push_back(phone_job::mk(M_ISP, iova(wfb * fp), iova((wfb + 1) * fp) - 1, n_items, profile_of(M_ISP).with_wr(100)));
        jobs.push_back(phone_job::mk(M_ICP, iova(0), iova(fp) - 1, n_items));
        if (f > 0) begin
          jobs.push_back(phone_job::mk(M_VENC, iova(rfb * fp), iova((rfb + 1) * fp) - 1, n_items, profile_of(M_VENC).with_wr(0)));
          jobs.push_back(phone_job::mk(M_DISP, iova(rfb * fp), iova((rfb + 1) * fp) - 1, n_items / 2));
        end
        background(jobs, '{M_CPU, M_ADSP, M_MODEM});
        run_phase_jobs(jobs);
        // encoder writes the bitstream of the frame it read
        if (f > 0) traffic(M_VENC, iova(2 * fp), iova(3 * fp) - 1, n_items / 2, profile_of(M_VENC).with_wr(100));
      end
      foreach (env.sb.n_faults[i])
        if (env.sb.n_faults[i]) `uvm_error("TEST", $sformatf("IOMMU%0d faulted in a fault-free use case", i))
    endtask
  endclass

  class phone_video_test extends phone_usecase_test;
    `uvm_component_utils(phone_video_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      int unsigned bp = 16, fp = 32;
      int I_VDEC = iommu_of(M_VDEC), I_DISP = iommu_of(M_DISP);
      bit [31:0] bs = dram(M_UFS, 32'h0040_0000);   // bitstream buffer, filled by UFS
      // VDEC: bitstream pages [0, bp) read-only on the UFS buffer, frames
      // F0 = [bp, bp+fp), F1 = [bp+fp, bp+2fp) in its slice
      for (int unsigned k = 0; k < bp; k++) map_page(I_VDEC, k, bs + k * 32'h1000, 1, 0, 1);
      map_shuffled(I_VDEC, 2 * fp, dram(M_VDEC, 0), 0, 0, bp);
      map_shared(I_DISP, 0, I_VDEC, bp, 2 * fp, 1);
      iommu_enable(I_VDEC, bp + 2 * fp);
      iommu_enable(I_DISP, 2 * fp);
      // storage reads the clip into the bitstream buffer
      begin
        phone_job jobs[$];
        jobs.push_back(phone_job::mk(M_UFS, bs, bs + bp * 32'h1000 - 1, n_items, profile_of(M_UFS).with_wr(100)));
        background(jobs, '{M_CPU, M_CONN});
        run_phase_jobs(jobs);
      end
      for (int f = 0; f < 3; f++) begin
        phone_job jobs[$];
        int unsigned wf = bp + (f % 2) * fp, rf = bp + (1 - f % 2) * fp;
        // decode: parse the bitstream, then write the frame
        traffic(M_VDEC, iova(0), iova(bp) - 1, n_items / 2, profile_of(M_VDEC).with_wr(0));
        jobs.push_back(phone_job::mk(M_VDEC, iova(wf), iova(wf + fp) - 1, n_items, profile_of(M_VDEC).with_wr(100)));
        if (f > 0) jobs.push_back(phone_job::mk(M_DISP, iova(rf - bp), iova(rf - bp + fp) - 1, n_items / 2));
        background(jobs, '{M_ADSP, M_CONN, M_CPU});
        run_phase_jobs(jobs);
      end
      foreach (env.sb.n_faults[i])
        if (env.sb.n_faults[i]) `uvm_error("TEST", $sformatf("IOMMU%0d faulted in a fault-free use case", i))
    endtask
  endclass

  class phone_gaming_test extends phone_usecase_test;
    `uvm_component_utils(phone_gaming_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      int unsigned fp = 32;
      int I_DISP = iommu_of(M_DISP);
      // GPU renders FB0 / FB1 (physical, 128 KB each) in its slice; DISP scans them out
      for (int unsigned k = 0; k < 2 * fp; k++) map_page(I_DISP, k, dram(M_GPU, k * 32'h1000), 1, 0, 1);
      iommu_enable(I_DISP, 2 * fp);
      for (int f = 0; f < 4; f++) begin
        phone_job jobs[$];
        int unsigned wfb = f % 2, rfb = 1 - wfb;
        jobs.push_back(phone_job::mk(M_GPU, dram(M_GPU, wfb * fp * 32'h1000), dram(M_GPU, (wfb + 1) * fp * 32'h1000) - 1, n_items));
        if (f > 0) jobs.push_back(phone_job::mk(M_DISP, iova(rfb * fp), iova((rfb + 1) * fp) - 1, n_items / 2));
        background(jobs, '{M_CPU, M_MODEM, M_SCP, M_ADSP});
        run_phase_jobs(jobs);
      end
    endtask
  endclass

  class phone_ai_test extends phone_usecase_test;
    `uvm_component_utils(phone_ai_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task main();
      int unsigned wp = 32, ap = 16;
      int I_APU = iommu_of(M_APU), I_ISP = iommu_of(M_ISP);
      bit [31:0] wts = dram(M_CPU, 32'h0080_0000);    // weights, loaded by the CPU
      // APU: weights read-only [0, wp), activations [wp, wp+ap) in its slice
      for (int unsigned k = 0; k < wp; k++) map_page(I_APU, k, wts + k * 32'h1000, 1, 0, 1);
      map_shuffled(I_APU, ap, dram(M_APU, 0), 0, 0, wp);
      map_shuffled(I_ISP, ap, dram(M_ISP, 0));
      iommu_enable(I_APU, wp + ap);
      iommu_enable(I_ISP, ap);
      // CPU loads the model
      traffic(M_CPU, wts, wts + wp * 32'h1000 - 1, n_items, phone_profile::mk(100, 16, 64, 1));
      for (int r = 0; r < 3; r++) begin
        phone_job jobs[$];
        // inference: weight streaming and activation read/write in turn
        fork
          begin
            traffic(M_APU, iova(0), iova(wp) - 1, n_items, profile_of(M_APU).with_wr(0));
            traffic(M_APU, iova(wp), iova(wp + ap) - 1, n_items / 2, phone_profile::mk(50, 16, 64, 1));
          end
        join_none
        jobs.push_back(phone_job::mk(M_ISP, iova(0), iova(ap) - 1, n_items / 2));
        jobs.push_back(phone_job::mk(M_SEC, dram(M_SEC, 0), dram(M_SEC, 32'h1_FFFF), n_items / 2));
        jobs.push_back(phone_job::mk(M_DMA, dram(M_DMA, 0), dram(M_DMA, 32'h3_FFFF), n_items / 2));
        background(jobs, '{M_SCP});
        run_phase_jobs(jobs);
      end
    endtask
  endclass

  // ==========================================================================
  class phone_stress_test extends phone_base_test;
    `uvm_component_utils(phone_stress_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void configure();
      timing  = 2;
      n_items = 40;
    endfunction
    task main();
      phone_job jobs[$];
      int unsigned np = 48;
      for (int i = 0; i < NIOMMU; i++) begin
        map_shuffled(i, np, dram(master_of_iommu(i), 0), 9, 13);
        iommu_enable(i, np);
      end
      for (int m = 0; m < NM; m++)
        if (iommu_of(m) >= 0) jobs.push_back(phone_job::mk(m, iova(0), iova(np) - 1, n_items));
        else                  jobs.push_back(phone_job::mk(m, dram(m, 0), dram(m, 32'h7_FFFF), n_items));
      // the CPU also pokes the peripherals while everything runs
      fork
        begin
          uvm_status_e st;
          repeat (10) begin
            reg_write(env.regmodel.gpio.r("SCRATCH"), $urandom());
            env.regmodel.uart.r("SCRATCH").mirror(st, UVM_CHECK);
          end
        end
      join_none
      run_phase_jobs(jobs);
      for (int i = 0; i < NIOMMU; i++) check_iommu_regs(i);
    endtask
  endclass

  `include "phone_ss_test.svh"
endpackage
`endif
