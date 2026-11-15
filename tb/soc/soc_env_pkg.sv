// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_env_pkg -- UVM environment for amba_soc_top
// ----------------------------------------------------------------------------
//   m_agent[0..1]  axi4 master agents      -> DUT AXI ports m0 (CPU), m1 (DMA)
//   ddr_agent      axi4 slave agent        <- DUT external memory port, backed
//                                             by a mem_model ("DDR")
//   apbx_agent     apb slave agent         <- DUT external APB slot, backed by
//                                             a mem_model, wait states, PSLVERR
//   apb_mon_agent  passive apb agent       on the internal APB bus (bridge out)
//   sb             soc_scoreboard          reference model of the whole SoC
// ============================================================================
`ifndef SOC_ENV_PKG_SV
`define SOC_ENV_PKG_SV
package soc_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;
  import apb_pkg::*;

  // ---- address map (mirrors rtl/soc/soc_pkg.sv) ----
  localparam bit [31:0] SRAM_BASE  = 32'h0000_0000;
  localparam int unsigned SRAM_BYTES = 1024;
  localparam bit [31:0] APB_BASE   = 32'h1000_0000;
  localparam bit [31:0] GPIO_BASE  = 32'h1000_0000;
  localparam bit [31:0] UART_BASE  = 32'h1000_1000;
  localparam bit [31:0] APBX_BASE  = 32'h1000_2000;
  localparam bit [31:0] DDR_BASE   = 32'h8000_0000;
  localparam bit [31:0] GPIO_ID    = 32'h4750_0200;
  localparam bit [31:0] UART_ID    = 32'h5541_0200;
  localparam bit [31:0] REG_ID      = 32'h000;
  localparam bit [31:0] REG_SCRATCH = 32'h010;

  typedef enum int { R_SRAM, R_APB, R_DDR, R_DEC } soc_region_e;

  function automatic soc_region_e soc_region(bit [31:0] a);
    if (a[31:16] == 16'h0000) return R_SRAM;
    if (a[31:16] == 16'h1000) return R_APB;
    if (a[31:28] == 4'h8)     return R_DDR;
    return R_DEC;
  endfunction

  // ==========================================================================
  class soc_env_cfg extends uvm_object;
    `uvm_object_utils(soc_env_cfg)
    axi4_cfg  m_cfg[2];
    axi4_cfg  ddr_cfg;
    apb_cfg   apbx_cfg;
    apb_cfg   apb_mon_cfg;
    mem_model ddr_mem, apbx_mem;
    // error windows of the external models (absolute addresses)
    bit [31:0] ddr_err_lo  = 32'h8FFF_F000, ddr_err_hi  = 32'h8FFF_FFFF;
    bit [31:0] ddr_dec_lo  = 32'h8FFF_E000, ddr_dec_hi  = 32'h8FFF_EFFF;   // DECERR window
    bit [31:0] apbx_err_lo = 32'h1000_2F00, apbx_err_hi = 32'h1000_2FFF;

    function new(string name = "soc_env_cfg");
      super.new(name);
      foreach (m_cfg[i]) begin
        m_cfg[i] = axi4_cfg::type_id::create($sformatf("m%0d_cfg", i));
        m_cfg[i].role = AXI4_MASTER;
        m_cfg[i].port = i;
        m_cfg[i].id_width = 4;
      end
      ddr_mem  = mem_model::type_id::create("ddr_mem");
      apbx_mem = mem_model::type_id::create("apbx_mem");
      ddr_cfg = axi4_cfg::type_id::create("ddr_cfg");
      ddr_cfg.role = AXI4_SLAVE;
      ddr_cfg.port = 2;
      ddr_cfg.mem  = ddr_mem;
      apbx_cfg = apb_cfg::type_id::create("apbx_cfg");
      apbx_cfg.role = APB_SLAVE;
      apbx_cfg.mem  = apbx_mem;
      apbx_cfg.addr_mask = 32'h0000_0FFF;
      apb_mon_cfg = apb_cfg::type_id::create("apb_mon_cfg");
      apb_mon_cfg.is_active = UVM_PASSIVE;
      apply_error_windows();
    endfunction

    function void apply_error_windows();
      ddr_cfg.err_ranges.delete();
      ddr_cfg.add_err_range(ddr_err_lo, ddr_err_hi, AXI4_SLVERR);
      ddr_cfg.add_err_range(ddr_dec_lo, ddr_dec_hi, AXI4_DECERR);
      apbx_cfg.err_lo = apbx_err_lo;
      apbx_cfg.err_hi = apbx_err_hi;
    endfunction

    // timing profile: 0 = no added delays, 1 = moderate, 2 = heavy
    function void set_timing(int level);
      int unsigned d = (level == 0) ? 0 : (level == 1) ? 2 : 6;
      foreach (m_cfg[i]) begin
        m_cfg[i].max_b_delay = d;
        m_cfg[i].max_r_gap   = d;
      end
      ddr_cfg.max_aready_delay = d;
      ddr_cfg.max_wready_delay = d;
      ddr_cfg.max_b_latency    = d;
      ddr_cfg.max_r_latency    = d * 2;
      ddr_cfg.max_rvalid_gap   = d;
      apbx_cfg.max_wait        = (level == 0) ? 0 : (level == 1) ? 2 : 5;
    endfunction
  endclass

  // ==========================================================================
  // soc_scoreboard -- reference model of amba_soc_top
  // --------------------------------------------------------------------------
  // Every burst completed on m0/m1 is predicted from the address map:
  //  SRAM  model of open-ip AXI4_top: DECERR for AxLEN > 15, SLVERR for WRAP or
  //        a start outside [0, 1 KB) / not word aligned; beats step by 4 bytes;
  //        write beats stop updating memory once one falls outside the SRAM
  //        (BRESP SLVERR), read beats outside it answer SLVERR. Bytes never
  //        written read as unknown and are not compared.
  //  DDR   shadow memory (unwritten bytes = mem_model init pattern), SLVERR /
  //        DECERR in the DDR model's two error windows. In addition, each burst must appear
  //        unchanged on the external port with ID {master, id}.
  //  APB   each beat must appear as one APB transfer on the internal bus (same
  //        address, direction, data, strobes); RRESP/BRESP follow PSLVERR, read
  //        data equals PRDATA. PSLVERR and read data are predicted for: unmapped
  //        slots, GPIO/UART ID and SCRATCH registers, unmapped/misaligned
  //        peripheral offsets, and the external slot (shadow memory + error
  //        window).
  //  other DECERR on every beat.
  // Concurrency contract: the two masters use disjoint SRAM/DDR addresses (the
  // tests partition them), so per-byte ordering is per-master program order.
  // ==========================================================================
  `uvm_analysis_imp_decl(_mst)
  `uvm_analysis_imp_decl(_ddr)
  `uvm_analysis_imp_decl(_apb)

  class soc_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(soc_scoreboard)

    uvm_analysis_imp_mst #(axi4_item, soc_scoreboard) mst_imp;
    uvm_analysis_imp_ddr #(axi4_item, soc_scoreboard) ddr_imp;
    uvm_analysis_imp_apb #(apb_item,  soc_scoreboard) apb_imp;

    soc_env_cfg cfg;

    // shadow state
    byte unsigned sram[int unsigned];        // written SRAM bytes only
    byte unsigned ddr[bit [31:0]];
    byte unsigned apbx[bit [31:0]];
    bit [31:0]    scratch[2];                // GPIO, UART

    // pending matches
    axi4_item mst_ddr_q[2][$];               // [0] reads, [1] writes, master side
    axi4_item ext_ddr_q[2][$];               // same, external-port side
    apb_item  apb_q[$];

    int unsigned n_checks, n_errors;
    int unsigned n_by_region[soc_region_e];

    function new(string name, uvm_component parent);
      super.new(name, parent);
      mst_imp = new("mst_imp", this);
      ddr_imp = new("ddr_imp", this);
      apb_imp = new("apb_imp", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(soc_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", "soc_env_cfg not set")
    endfunction

    // ---------------------------------------------------------------- utils
    function void check(bit ok, string what);
      n_checks++;
      if (!ok) begin
        n_errors++;
        `uvm_error("SOC_SB", what)
      end
    endfunction

    function byte unsigned ddr_byte(bit [31:0] a);
      if (ddr.exists(a)) return ddr[a];
      return mem_model::init_byte(cfg.ddr_mem.init_kind, mem_addr_t'(a));
    endfunction

    function byte unsigned apbx_byte(bit [31:0] a);
      if (apbx.exists(a)) return apbx[a];
      return mem_model::init_byte(cfg.apbx_mem.init_kind, mem_addr_t'(a));
    endfunction

    // a test that preloads the DDR model through its backdoor tells the
    // scoreboard, which otherwise predicts the init pattern for those bytes
    function void note_ddr_backdoor(bit [31:0] a, bit [31:0] d);
      for (int b = 0; b < 4; b++) ddr[(a & ~32'h3) + b] = d[8*b +: 8];
    endfunction

    // a mid-test reset clears the peripheral SCRATCH registers; SRAM contents,
    // the DDR model and the external APB model keep their data
    function void note_reset();
      scratch = '{default: 0};
    endfunction

    // ---------------------------------------------------------------- inputs
    virtual function void write_mst(axi4_item t);
      soc_region_e r = soc_region(t.addr);
      n_by_region[r]++;
      case (r)
        R_SRAM: predict_sram(t);
        R_DDR:  predict_ddr(t);
        R_APB:  predict_apb(t);
        default: predict_dec(t);
      endcase
    endfunction

    virtual function void write_ddr(axi4_item t);
      ext_ddr_q[t.write].push_back(t);
      match_ddr(t.write);
    endfunction

    virtual function void write_apb(apb_item t);
      apb_q.push_back(t);
    endfunction

    // ---------------------------------------------------------------- SRAM
    function bit sram_in_range(bit [31:0] a);
      return a[31:10] == 0 && a[1:0] == 0;
    endfunction

    function void predict_sram(axi4_item t);
      string tag = {"SRAM ", t.convert2string()};
      axi4_resp_e exp_start;
      bit [31:0] a = t.addr;
      if (t.len > 15)                                  exp_start = AXI4_DECERR;
      else if (t.burst == AXI4_WRAP || !sram_in_range(a)) exp_start = AXI4_SLVERR;
      else                                             exp_start = AXI4_OKAY;
      if (t.write) begin
        axi4_resp_e exp = exp_start;
        if (exp == AXI4_OKAY)
          for (int unsigned i = 0; i < t.beats(); i++) begin
            if (!sram_in_range(a)) begin exp = AXI4_SLVERR; break; end
            for (int b = 0; b < 4; b++)
              if (t.strb[i][b]) sram[a[9:0] + b] = t.data[i][8*b +: 8];
            if (t.burst == AXI4_INCR) a += 4;
          end
        check(t.resp[0] == exp, $sformatf("%s: BRESP %s, expected %s", tag, t.resp[0].name(), exp.name()));
      end else begin
        for (int unsigned i = 0; i < t.beats(); i++) begin
          axi4_resp_e exp = (exp_start != AXI4_OKAY) ? exp_start :
                            sram_in_range(a) ? AXI4_OKAY : AXI4_SLVERR;
          check(t.resp[i] == exp, $sformatf("%s: beat %0d RRESP %s, expected %s", tag, i,
                t.resp[i].name(), exp.name()));
          if (exp_start == AXI4_OKAY && exp == AXI4_OKAY)
            for (int b = 0; b < 4; b++)
              if (sram.exists(a[9:0] + b))
                check(t.data[i][8*b +: 8] == sram[a[9:0] + b],
                      $sformatf("%s: beat %0d byte %0d = %02h, expected %02h (addr %08h)", tag, i, b,
                                t.data[i][8*b +: 8], sram[a[9:0] + b], a + b));
          if (exp_start == AXI4_OKAY && t.burst == AXI4_INCR) a += 4;
        end
      end
    endfunction

    // ---------------------------------------------------------------- DDR
    function void predict_ddr(axi4_item t);
      string tag = {"DDR ", t.convert2string()};
      bit slv = (t.addr >= cfg.ddr_err_lo && t.addr <= cfg.ddr_err_hi);
      bit dec = (t.addr >= cfg.ddr_dec_lo && t.addr <= cfg.ddr_dec_hi);
      bit err = slv || dec;
      axi4_resp_e exp = dec ? AXI4_DECERR : slv ? AXI4_SLVERR : AXI4_OKAY;
      if (t.write) begin
        check(t.resp[0] == exp, $sformatf("%s: BRESP %s, expected %s", tag, t.resp[0].name(), exp.name()));
        if (!err)
          for (int unsigned i = 0; i < t.beats(); i++) begin
            bit [31:0] base = t.beat_addr(i) & ~32'h3;
            for (int b = 0; b < 4; b++)
              if (t.strb[i][b]) ddr[base + b] = t.data[i][8*b +: 8];
          end
      end else
        for (int unsigned i = 0; i < t.beats(); i++) begin
          bit [31:0] base = t.beat_addr(i) & ~32'h3;
          bit [3:0]  ln   = t.lanes(i);
          check(t.resp[i] == exp, $sformatf("%s: beat %0d RRESP %s, expected %s", tag, i,
                t.resp[i].name(), exp.name()));
          if (!err)
            for (int b = 0; b < 4; b++)
              if (ln[b])
                check(t.data[i][8*b +: 8] == ddr_byte(base + b),
                      $sformatf("%s: beat %0d byte %0d = %02h, expected %02h (addr %08h)", tag, i, b,
                                t.data[i][8*b +: 8], ddr_byte(base + b), base + b));
        end
      mst_ddr_q[t.write].push_back(t);
      match_ddr(t.write);
    endfunction

    // master-side and external-port DDR bursts complete in the same order
    function void match_ddr(bit wr);
      while (mst_ddr_q[wr].size() && ext_ddr_q[wr].size()) begin
        axi4_item m = mst_ddr_q[wr].pop_front();
        axi4_item e = ext_ddr_q[wr].pop_front();
        string tag = $sformatf("DDR port: master{%s} ext{%s}", m.convert2string(), e.convert2string());
        bit ok = (e.addr == m.addr) && (e.len == m.len) && (e.size == m.size) &&
                 (e.burst == m.burst) && (e.id == {3'b0, m.port[0], m.id[3:0]});
        check(ok, {tag, ": request attributes or ID differ"});
        for (int unsigned i = 0; i < m.beats() && i < e.beats(); i++) begin
          if (wr) check(e.data[i] == m.data[i] && e.strb[i] == m.strb[i],
                        $sformatf("%s: write beat %0d data/strb differ", tag, i));
          else    check(e.data[i] == m.data[i] && e.resp[i] == m.resp[i],
                        $sformatf("%s: read beat %0d data/resp differ", tag, i));
        end
        if (wr) check(e.resp[0] == m.resp[0], {tag, ": BRESP differs"});
      end
    endfunction

    // ---------------------------------------------------------------- APB
    // expected PSLVERR for one APB transfer; `known` = read data is predictable
    function void predict_apb_xfer(bit [31:0] a, bit wr, bit [3:0] strb, bit [31:0] wdata,
                                   output bit exp_err, output bit known, output bit [31:0] exp_rdata);
      int unsigned slot = a[15:12];
      bit [11:0] off = a[11:0];
      exp_err = 0; known = 0; exp_rdata = 0;
      case (slot)
        0, 1: begin   // GPIO, UART (open-ip *_apb wrappers)
          bit [11:0] top = (slot == 0) ? 12'h020 : 12'h01C;
          if (off[1:0] != 0 || off >= top) begin
            exp_err = 1; known = 1;
          end else if (off == REG_ID) begin
            known = 1; exp_rdata = (slot == 0) ? GPIO_ID : UART_ID;
          end else if (off == REG_SCRATCH) begin
            if (wr) for (int b = 0; b < 4; b++) if (strb[b]) scratch[slot][8*b +: 8] = wdata[8*b +: 8];
            known = 1; exp_rdata = scratch[slot];
          end else if (slot == 0 && off == 12'h018 && wr && strb != 4'hF) begin
            exp_err = 1; known = 1;   // GPIO OUT takes whole words only
          end
        end
        2: begin      // external slot: APB slave VIP + mem_model (indexed by PADDR & addr_mask)
          bit [31:0] base = (a & cfg.apbx_cfg.addr_mask) & ~32'h3;
          if (a >= cfg.apbx_err_lo && a <= cfg.apbx_err_hi) begin
            exp_err = 1; known = 1;
          end else begin
            if (wr) for (int b = 0; b < 4; b++) if (strb[b]) apbx[base + b] = wdata[8*b +: 8];
            known = 1;
            for (int b = 0; b < 4; b++) exp_rdata[8*b +: 8] = apbx_byte(base + b);
          end
        end
        default: begin exp_err = 1; known = 1; end   // unmapped slot: decoder answers
      endcase
      if (exp_err) exp_rdata = 0;
    endfunction

    function void predict_apb(axi4_item t);
      string tag = {"APB ", t.convert2string()};
      bit any_err = 0;
      if (apb_q.size() < t.beats()) begin
        check(0, $sformatf("%s: %0d beats but only %0d APB transfers seen", tag, t.beats(), apb_q.size()));
        apb_q.delete();
        return;
      end
      for (int unsigned i = 0; i < t.beats(); i++) begin
        apb_item p = apb_q.pop_front();
        bit [31:0] ba = t.beat_addr(i);
        bit exp_err, known;
        bit [31:0] exp_rd;
        check(p.addr == ba && p.write == t.write,
              $sformatf("%s: beat %0d -> APB %s, expected %s addr %08h", tag, i, p.convert2string(),
                        t.write ? "WR" : "RD", ba));
        if (t.write)
          check(p.data == t.data[i] && p.strb == t.strb[i],
                $sformatf("%s: beat %0d APB PWDATA/PSTRB %08h/%04b, AXI %08h/%04b", tag, i,
                          p.data, p.strb, t.data[i], t.strb[i]));
        else begin
          check(t.data[i] == p.data, $sformatf("%s: beat %0d RDATA %08h, PRDATA %08h", tag, i, t.data[i], p.data));
          check(t.resp[i] == (p.slverr ? AXI4_SLVERR : AXI4_OKAY),
                $sformatf("%s: beat %0d RRESP %s with PSLVERR=%0b", tag, i, t.resp[i].name(), p.slverr));
        end
        any_err |= p.slverr;
        predict_apb_xfer(ba, t.write, t.strb[i], t.data[i], exp_err, known, exp_rd);
        if (known) begin
          check(p.slverr == exp_err, $sformatf("%s: beat %0d PSLVERR=%0b, expected %0b", tag, i, p.slverr, exp_err));
          if (!t.write && !exp_err)
            check(p.data == exp_rd, $sformatf("%s: beat %0d PRDATA %08h, expected %08h", tag, i, p.data, exp_rd));
        end
      end
      if (t.write)
        check(t.resp[0] == (any_err ? AXI4_SLVERR : AXI4_OKAY),
              $sformatf("%s: BRESP %s, a beat had PSLVERR=%0b", tag, t.resp[0].name(), any_err));
    endfunction

    // ---------------------------------------------------------------- DECERR
    function void predict_dec(axi4_item t);
      foreach (t.resp[i])
        check(t.resp[i] == AXI4_DECERR, $sformatf("DEC %s: resp[%0d] %s, expected DECERR",
              t.convert2string(), i, t.resp[i].name()));
    endfunction

    // ---------------------------------------------------------------- end
    function void check_phase(uvm_phase phase);
      if (apb_q.size()) check(0, $sformatf("%0d APB transfers with no AXI burst", apb_q.size()));
      for (int d = 0; d < 2; d++) begin
        if (mst_ddr_q[d].size() || ext_ddr_q[d].size())
          check(0, $sformatf("unmatched DDR %s bursts: master %0d, external port %0d",
                d ? "write" : "read", mst_ddr_q[d].size(), ext_ddr_q[d].size()));
      end
      if (n_checks == 0) `uvm_error("SOC_SB", "no checks were made")
    endfunction

    function void report_phase(uvm_phase phase);
      string s = "";
      foreach (n_by_region[r]) s = {s, $sformatf(" %s=%0d", r.name(), n_by_region[r])};
      `uvm_info("SOC_SB", $sformatf("bursts per region:%s; checks=%0d errors=%0d", s, n_checks, n_errors), UVM_NONE)
      if (n_errors == 0 && n_checks > 0) $display("SB_PASS checks=%0d", n_checks);
    endfunction
  endclass

  // ==========================================================================
  class soc_env extends uvm_env;
    `uvm_component_utils(soc_env)
    soc_env_cfg    cfg;
    axi4_agent     m_agent[2];
    axi4_agent     ddr_agent;
    apb_agent      apbx_agent;
    apb_agent      apb_mon_agent;
    soc_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(soc_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", "soc_env_cfg not set")
      foreach (m_agent[i]) begin
        m_agent[i] = axi4_agent::type_id::create($sformatf("m%0d_agent", i), this);
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("m%0d_agent", i), "cfg", cfg.m_cfg[i]);
      end
      ddr_agent = axi4_agent::type_id::create("ddr_agent", this);
      uvm_config_db#(axi4_cfg)::set(this, "ddr_agent", "cfg", cfg.ddr_cfg);
      apbx_agent = apb_agent::type_id::create("apbx_agent", this);
      uvm_config_db#(apb_cfg)::set(this, "apbx_agent", "cfg", cfg.apbx_cfg);
      apb_mon_agent = apb_agent::type_id::create("apb_mon_agent", this);
      uvm_config_db#(apb_cfg)::set(this, "apb_mon_agent", "cfg", cfg.apb_mon_cfg);
      uvm_config_db#(soc_env_cfg)::set(this, "sb", "cfg", cfg);
      sb = soc_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      foreach (m_agent[i]) m_agent[i].ap.connect(sb.mst_imp);
      ddr_agent.ap.connect(sb.ddr_imp);
      apb_mon_agent.ap.connect(sb.apb_imp);
    endfunction
  endclass
endpackage
`endif
