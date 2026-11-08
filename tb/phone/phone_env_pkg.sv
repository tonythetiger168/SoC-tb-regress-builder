// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_env_pkg -- UVM environment for phone_soc_top
// ----------------------------------------------------------------------------
//   m_agent[0..14]   axi4 master agents (traffic models of the subsystems)
//   ch_agent[0..31]  lpddr5 slave agents, one mem_model per channel
//   apbx_agent       apb slave agent on the external APB slot
//   apb_mon_agent    passive apb agent on the internal APB bus
//   regmodel         phone_reg_block (UVM RAL), frontdoor = CPU AXI port,
//                    predictor = APB monitor
//   sb               phone_scoreboard (reference model of the SoC)
//   perf             phone_perf (bandwidth / latency / LPDDR5 statistics)
// ============================================================================
`ifndef PHONE_ENV_PKG_SV
`define PHONE_ENV_PKG_SV
package phone_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;
  import apb_pkg::*;
  import lpddr5_pkg::*;
  import soc_env_pkg::*;
  import phone_soc_pkg::*;
  import phone_ral_pkg::*;

  // ---- test address plan ----
  // Each master owns a 128 MB slice of DRAM (scoreboard concurrency contract:
  // masters write disjoint bytes unless a test orders the phases).
  localparam bit [31:0] PART_BYTES = 32'h0800_0000;
  function automatic bit [31:0] part_base(int m);
    return DRAM_BASE + PART_BYTES * m;
  endfunction
  localparam bit [31:0] PT_AREA  = 32'hF800_0000;   // IOMMU page tables, 1 MB each
  localparam bit [31:0] IOVA_BASE = 32'h4000_0000;   // IOVA window of every IOMMU
  function automatic bit [31:0] pt_base_of(int i);
    return PT_AREA + 32'h0010_0000 * i;
  endfunction
  localparam bit [31:0] LP5_ERR_LO = 32'hFFFF_F000, LP5_ERR_HI = 32'hFFFF_FFFF;   // "ECC error" page

  // ==========================================================================
  class phone_env_cfg extends soc_env_cfg;
    `uvm_object_utils(phone_env_cfg)
    axi4_cfg     pm_cfg [NM];
    axi4_cfg     ch_cfg [NCH];
    lpddr5_cfg   lp_cfg [NCH];
    mem_model    ch_mem [NCH];
    int unsigned max_delay = 2;        // master-side random gaps

    function new(string name = "phone_env_cfg");
      super.new(name);
      ddr_err_lo = LP5_ERR_LO;
      ddr_err_hi = LP5_ERR_HI;
      foreach (pm_cfg[m]) begin
        pm_cfg[m] = axi4_cfg::type_id::create($sformatf("%s_cfg", master_name(m)));
        pm_cfg[m].role = AXI4_MASTER;
        pm_cfg[m].port = m;
        pm_cfg[m].id_width = (iommu_of(m) >= 0) ? 3 : 4;   // IDs 8..15 belong to the walker
      end
      foreach (ch_cfg[c]) begin
        ch_mem[c] = mem_model::type_id::create($sformatf("ch%0d_mem", c));
        ch_mem[c].init_kind = ddr_mem.init_kind;
        ch_cfg[c] = axi4_cfg::type_id::create($sformatf("ch%0d_cfg", c));
        ch_cfg[c].role = AXI4_SLAVE;
        ch_cfg[c].port = c;
        ch_cfg[c].mem  = ch_mem[c];
        ch_cfg[c].has_coverage = 0;
        lp_cfg[c] = lpddr5_cfg::type_id::create($sformatf("ch%0d_lp_cfg", c));
        lp_cfg[c].channel = c;
      end
      apply_error_windows();
    endfunction

    function void apply_error_windows();
      super.apply_error_windows();
      foreach (ch_cfg[c]) begin
        if (ch_cfg[c] == null) continue;
        ch_cfg[c].err_ranges.delete();
        ch_cfg[c].add_err_range(ddr_err_lo, ddr_err_hi, AXI4_SLVERR);
      end
    endfunction

    function void set_speed(lpddr5_speed_e s);
      foreach (lp_cfg[c]) lp_cfg[c].set_speed(s);
    endfunction
    function void set_page_policy(lpddr5_page_policy_e p);
      foreach (lp_cfg[c]) lp_cfg[c].page_policy = p;
    endfunction
    function void set_ref_mode(lpddr5_ref_mode_e r);
      foreach (lp_cfg[c]) lp_cfg[c].ref_mode = r;
    endfunction

    // level 0: no added delays; 1: moderate; 2: heavy back-pressure
    function void set_phone_timing(int level);
      int unsigned d = (level == 0) ? 0 : (level == 1) ? 2 : 6;
      set_timing(level);
      max_delay = (level == 0) ? 0 : (level == 1) ? 2 : 5;
      foreach (pm_cfg[m]) begin
        pm_cfg[m].max_b_delay = d;
        pm_cfg[m].max_r_gap   = d;
      end
      foreach (ch_cfg[c]) begin                 // controller queue back-pressure
        ch_cfg[c].max_aready_delay = d / 2;
        ch_cfg[c].max_wready_delay = d / 2;
      end
    endfunction

    // backdoor DRAM word (routes to the owning channel's memory)
    function void dram_poke32(bit [31:0] a, bit [31:0] d);
      ch_mem[dram_channel(a)].poke32(mem_addr_t'(a), d);
    endfunction
    function bit [31:0] dram_peek32(bit [31:0] a);
      return ch_mem[dram_channel(a)].peek32(mem_addr_t'(a));
    endfunction
  endclass

  // ==========================================================================
  // phone_scoreboard
  // --------------------------------------------------------------------------
  // Reuses soc_scoreboard's SRAM / APB / DECERR reference models and adds:
  //  * IOMMU: for masters behind an enabled IOMMU the IOVA is translated with
  //    the register values from the RAL mirror and the PTE read from the
  //    DRAM shadow; out-of-window / invalid / permission faults must answer
  //    SLVERR on every beat and must not reach DRAM. The first fault of each
  //    IOMMU is kept for the tests to compare with FAULT_STATUS/FAULT_ADDR.
  //  * DRAM: byte shadow over all 32 channels (unwritten = init pattern),
  //    SLVERR in the "ECC error" page; each burst must appear on exactly the
  //    channel the interleaving selects, with ID {master, id} and identical
  //    data / strobes / responses.
  //  * Page-table walks seen on a channel (ID bit 3 set) must read the PTE
  //    address of a burst's IOVA in that IOMMU's table and return the shadow.
  // ==========================================================================
  `uvm_analysis_imp_decl(_ch)
  typedef class phone_perf;

  class phone_scoreboard extends soc_scoreboard;
    `uvm_component_utils(phone_scoreboard)

    uvm_analysis_imp_ch #(axi4_item, phone_scoreboard) ch_imp;
    phone_env_cfg   pcfg;
    phone_reg_block rm;
    phone_perf      perf;

    axi4_item pend_m [NCH][$];     // predicted channel bursts (master side done)
    axi4_item pend_e [NCH][$];     // observed channel bursts not yet matched
    int unsigned n_walks [NIOMMU], n_faults [NIOMMU], n_xlat [NIOMMU];
    int unsigned n_per_ch [NCH];
    // first fault since the test last cleared it (mirrors FAULT_STATUS)
    bit          f_valid [NIOMMU];
    bit          f_write [NIOMMU], f_perm [NIOMMU];
    bit [31:0]   f_addr [NIOMMU];

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ch_imp = new("ch_imp", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$cast(pcfg, cfg)) `uvm_fatal("SB", "cfg is not a phone_env_cfg")
    endfunction

    // ---------------------------------------------------------------- IOMMU
    function bit [31:0] mir(phone_ip_block b, string r);
      return 32'(b.r(r).get_mirrored_value());
    endfunction

    function bit iommu_on(int i);
      return (rm != null) && mir(rm.iommu[i], "CTRL")[0];
    endfunction

    function bit [31:0] shadow32(bit [31:0] a);
      bit [31:0] d;
      for (int b = 0; b < 4; b++) d[8*b +: 8] = ddr_byte(a + b);
      return d;
    endfunction

    // 0 = ok (pa valid), 1 = translation fault, 2 = permission fault
    function int translate(int i, bit [31:0] va, bit wr, output bit [31:0] pa);
      bit [31:0] vb = mir(rm.iommu[i], "VA_BASE"), vs = mir(rm.iommu[i], "VA_SIZE");
      bit [31:0] pte;
      pa = va;
      if (va[31:12] < vb[31:12] || {1'b0, va[31:12]} >= {1'b0, vb[31:12]} + {1'b0, vs[31:12]}) return 1;
      pte = shadow32(pte_addr(i, va));
      if (!pte[0]) return 1;
      if (wr ? !pte[2] : !pte[1]) return 2;
      pa = {pte[31:12], va[11:0]};
      return 0;
    endfunction

    function bit [31:0] pte_addr(int i, bit [31:0] va);
      bit [31:0] vb = mir(rm.iommu[i], "VA_BASE");
      return mir(rm.iommu[i], "PT_BASE") + ((va[31:12] - vb[31:12]) << 2);
    endfunction

    function void clear_fault(int i);
      f_valid[i] = 0;
    endfunction

    // ---------------------------------------------------------------- inputs
    virtual function void write_mst(axi4_item t);
      int m = t.port;
      int i = iommu_of(m);
      axi4_item p = t;
      if (i >= 0 && iommu_on(i)) begin
        bit [31:0] pa;
        int f = translate(i, t.addr, t.write, pa);
        n_xlat[i]++;
        if (f != 0) begin
          n_faults[i]++;
          if (!f_valid[i]) begin
            f_valid[i] = 1; f_write[i] = t.write; f_perm[i] = (f == 2); f_addr[i] = t.addr;
          end
          foreach (t.resp[k])
            check(t.resp[k] == AXI4_SLVERR, $sformatf("IOMMU%0d %s fault on %s: resp[%0d] %s, expected SLVERR",
                  i, f == 2 ? "permission" : "translation", t.convert2string(), k, t.resp[k].name()));
          return;
        end
        p = axi4_item::type_id::create("pa_item");
        p.copy(t);
        p.addr = pa;
        if (t.worst_resp() != AXI4_OKAY)
          `uvm_info("PHONE_SB", $sformatf("IOMMU%0d: %s translated to %08h (PTE %08h @%08h) but got an error",
                    i, t.convert2string(), pa, shadow32(pte_addr(i, t.addr)), pte_addr(i, t.addr)), UVM_NONE)
      end
      if (perf != null) perf.record(m, phone_decode(p.addr), t);
      case (phone_decode(p.addr))
        S_SRAM: begin n_by_region[R_SRAM]++; predict_sram(p); end
        S_APB:  begin n_by_region[R_APB]++;  predict_apb(p);  end
        S_DEF:  begin n_by_region[R_DEC]++;  predict_dec(p);  end
        default: begin n_by_region[R_DDR]++; predict_dram(p, m); end
      endcase
    endfunction

    virtual function void write_ch(axi4_item t);
      int c = t.port;
      if (t.id[3] && iommu_of(t.id[7:4]) >= 0) begin      // IOMMU masters use IDs 0..7
        check_walk(t);
        return;
      end
      pend_e[c].push_back(t);
      match(c);
    endfunction

    function void check_walk(axi4_item t);
      int m = t.id[7:4];
      int i = iommu_of(m);
      string tag = $sformatf("walk ch%0d %s", t.port, t.convert2string());
      if (i < 0) begin
        check(0, {tag, ": walker ID from a master without an IOMMU"});
        return;
      end
      n_walks[i]++;
      check(!t.write && t.len == 0 && t.size == 2 && t.addr[1:0] == 0, {tag, ": not a single-word read"});
      check(int'(dram_channel(t.addr)) == t.port, {tag, ": wrong channel"});
      if (rm != null) begin
        bit [31:0] pb = mir(rm.iommu[i], "PT_BASE"), vs = mir(rm.iommu[i], "VA_SIZE");
        check(t.addr >= pb && t.addr < pb + (vs >> 10), $sformatf("%s: outside IOMMU%0d's table [%08h, +%0h)",
              tag, i, pb, vs >> 10));
      end
      check(t.resp[0] == AXI4_OKAY && t.data[0] == shadow32(t.addr),
            $sformatf("%s: PTE %08h, shadow %08h", tag, t.data[0], shadow32(t.addr)));
    endfunction

    // ---------------------------------------------------------------- DRAM
    function void predict_dram(axi4_item t, int m);
      string tag = {"DRAM ", t.convert2string()};
      bit err = (t.addr >= cfg.ddr_err_lo && t.addr <= cfg.ddr_err_hi);
      axi4_resp_e exp = err ? AXI4_SLVERR : AXI4_OKAY;
      axi4_item e;
      int c = dram_channel(t.addr);
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
          if (!err) begin
            bit [31:0] exp_d = 0;
            bit [31:0] msk = 0;
            for (int b = 0; b < 4; b++)
              if (ln[b]) begin exp_d[8*b +: 8] = ddr_byte(base + b); msk[8*b +: 8] = 8'hFF; end
            check((t.data[i] & msk) == exp_d, $sformatf("%s: beat %0d data %08h, expected %08h (lanes %04b, addr %08h)",
                  tag, i, t.data[i] & msk, exp_d, ln, base));
          end
        end
      e = axi4_item::type_id::create("exp");
      e.copy(t);
      e.id = {4'(m), t.id[3:0]};
      e.port = c;
      n_per_ch[c]++;
      pend_m[c].push_back(e);
      match(c);
    endfunction

    function void match(int c);
      for (int i = 0; i < pend_m[c].size(); i++) begin
        axi4_item m = pend_m[c][i];
        for (int j = 0; j < pend_e[c].size(); j++) begin
          axi4_item e = pend_e[c][j];
          if (e.write == m.write && e.id == m.id && e.addr == m.addr && e.len == m.len) begin
            string tag = $sformatf("ch%0d: master{%s} channel{%s}", c, m.convert2string(), e.convert2string());
            bit ok = 1;
            check(e.size == m.size && e.burst == m.burst, {tag, ": size/burst differ"});
            for (int unsigned k = 0; k < m.beats(); k++)
              if (m.write ? (e.data[k] != m.data[k] || e.strb[k] != m.strb[k])
                          : (e.data[k] != m.data[k] || e.resp[k] != m.resp[k])) ok = 0;
            check(ok, {tag, ": beat data / strobes / responses differ"});
            if (m.write) check(e.resp[0] == m.resp[0], {tag, ": BRESP differs"});
            pend_m[c].delete(i);
            pend_e[c].delete(j);
            i--;
            break;
          end
        end
      end
    endfunction

    // ---------------------------------------------------------------- APB
    // slots 0..2 as in the AMBA SoC; open-ip IPs and IOMMUs are checked by
    // the RAL model (mirror), not here; slots 13..15 are unmapped
    virtual function void predict_apb_xfer(bit [31:0] a, bit wr, bit [3:0] strb, bit [31:0] wdata,
                                           output bit exp_err, output bit known, output bit [31:0] exp_rdata);
      int unsigned slot = a[15:12];
      if (slot <= APB_EXT) super.predict_apb_xfer(a, wr, strb, wdata, exp_err, known, exp_rdata);
      else if (slot < APB_NSLOTS) begin exp_err = 0; known = 0; exp_rdata = 0; end
      else begin exp_err = 1; known = 1; exp_rdata = 0; end
    endfunction

    // ---------------------------------------------------------------- end
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      foreach (pend_m[c])
        if (pend_m[c].size() || pend_e[c].size())
          check(0, $sformatf("ch%0d: %0d predicted bursts never seen on the channel, %0d channel bursts never predicted",
                c, pend_m[c].size(), pend_e[c].size()));
    endfunction

    function void report_phase(uvm_phase phase);
      string s = "";
      foreach (n_walks[i])
        s = {s, $sformatf(" IOMMU%0d(%s): xlat=%0d walks=%0d faults=%0d;", i, master_name(master_of_iommu(i)),
                          n_xlat[i], n_walks[i], n_faults[i])};
      `uvm_info("PHONE_SB", {"IOMMU:", s}, UVM_NONE)
      super.report_phase(phase);
    endfunction
  endclass

  // ==========================================================================
  // phone_perf -- per-path latency (every master -> slave port route, read
  // and write), per-master bandwidth, per-channel LPDDR5 statistics
  // --------------------------------------------------------------------------
  // Path latency = first cycle the master raised AWVALID / ARVALID to the B
  // handshake / last R beat, measured at the master port, so it includes
  // NoC arbitration, the mesh hops both ways, the IOMMU (walks included) and
  // the LPDDR5 timing. The slave port of a burst is the one its physical
  // address decodes to (after IOMMU translation). The scoreboard feeds it.
  // Every burst also goes to lat_pkg::lat_db (one LAT line per burst, in clock
  // cycles), the shared format regress/regress.py turns into per-path tables,
  // the master x slave heatmap and histograms. The log gets a summary table.
  // ==========================================================================
  class phone_perf extends uvm_component;
    `uvm_component_utils(phone_perf)
    localparam int NP = NS + 1;               // + default slave
    real             lat [NM][NP][2][$];
    real             first_sum [NM][NP];
    longint unsigned bytes [NM][2];
    lpddr5_agent     ch_agent [NCH];
    time             t_first = 0, t_last = 0;
    real             tck_ns = 2.0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    static function string slave_name(int s);
      if (s < NCH)     return $sformatf("LPDDR5_%02d", s);
      if (s == S_SRAM) return "SRAM";
      if (s == S_APB)  return "APB";
      return "DECERR";
    endfunction

    function void record(int m, int s, axi4_item t);
      real l = real'(t.t_end - t.t_req);
      if (m < 0 || m >= NM || s < 0 || s >= NP) return;
      if (t_first == 0 || t.t_req < t_first) t_first = t.t_req;
      if (t.t_end > t_last) t_last = t.t_end;
      lat[m][s][t.write].push_back(l);
      if (!t.write) first_sum[m][s] += real'(t.t_first - t.t_req);
      bytes[m][t.write] += t.beats() * (1 << t.size);
      lat_pkg::lat_db::add(master_name(m), slave_name(s), t.write ? "W" : "R",
                           longint'(l / tck_ns + 0.5));
    endfunction

    static function real pct(real q[$], real p);
      int k;
      if (q.size() == 0) return 0;
      k = int'(p / 100.0 * (q.size() - 1) + 0.5);
      return q[k];
    endfunction

    function void report_phase(uvm_phase phase);
      real span = real'(t_last - t_first);
      string s, hdr;
      longint unsigned tot_ref = 0, tot_pg[3] = '{0, 0, 0}, tot_acc = 0;
      lat_pkg::lat_db::flush();
      if (span <= 0) span = 1;

      // ---- per path ----
      hdr = "\n  path                      dir  count   min_ns   avg_ns   p50_ns   p95_ns   p99_ns   max_ns  ideal_noc_ns  first_data_ns";
      s = hdr;
      for (int m = 0; m < NM; m++)
        for (int p = 0; p < NP; p++)
          for (int d = 0; d < 2; d++) begin
            real q[$] = lat[m][p][d];
            real sum = 0, ideal = 2.0 * noc_lat(m, p) * tck_ns;
            string fdat;
            if (q.size() == 0) continue;
            q.sort();
            foreach (q[i]) sum += q[i];
            fdat = d ? "" : $sformatf("%.1f", first_sum[m][p] / q.size());
            s = {s, $sformatf("\n  %-6s -> %-14s %s %6d %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f %13.1f  %13s",
                 master_name(m), slave_name(p), d ? "wr" : "rd", q.size(), q[0], sum / q.size(),
                 pct(q, 50), pct(q, 95), pct(q, 99), q[q.size() - 1], ideal, d ? "-" : fdat)};
          end
      `uvm_info("PERF", {"per-path latency (request VALID at the master port to last beat / B):", s}, UVM_NONE)

      // ---- per master ----
      s = "\n  master  rd_bursts  rd_MB/s  rd_avg_ns | wr_bursts  wr_MB/s  wr_avg_ns";
      for (int m = 0; m < NM; m++) begin
        int unsigned n[2] = '{0, 0};
        real sm[2] = '{0.0, 0.0};
        for (int p = 0; p < NP; p++)
          for (int d = 0; d < 2; d++) begin
            n[d] += lat[m][p][d].size();
            foreach (lat[m][p][d][i]) sm[d] += lat[m][p][d][i];
          end
        if (n[0] + n[1] == 0) continue;
        s = {s, $sformatf("\n  %-6s %9d %8.1f %10.1f | %9d %8.1f %10.1f", master_name(m),
             n[0], bytes[m][0] * 1000.0 / span, n[0] ? sm[0] / n[0] : 0.0,
             n[1], bytes[m][1] * 1000.0 / span, n[1] ? sm[1] / n[1] : 0.0)};
      end
      `uvm_info("PERF", {"per-master traffic:", s}, UVM_NONE)

      // ---- LPDDR5 ----
      s = "\n  ch  rd_acc  wr_acc  hit%  miss  conflict  refresh  ref_stall  avg_rd_lat_ns";
      foreach (ch_agent[c]) begin
        lpddr5_model md = (ch_agent[c] == null) ? null : ch_agent[c].model();
        if (md == null) continue;
        tot_ref += md.n_ref;
        foreach (tot_pg[k]) tot_pg[k] += md.n_page[k];
        tot_acc += md.n_access[0] + md.n_access[1];
        if (md.n_access[0] + md.n_access[1] == 0) continue;
        s = {s, $sformatf("\n  %2d %7d %7d %5.1f %5d %9d %8d %10d %14.1f", c, md.n_access[0], md.n_access[1],
             md.hit_rate(), md.n_page[PG_MISS], md.n_page[PG_CONFLICT], md.n_ref, md.n_ref_stall,
             md.n_bursts[0] ? md.sum_lat[0] / md.n_bursts[0] : 0.0)};
      end
      `uvm_info("PERF", {"LPDDR5 channels (32-byte accesses; latency = device side, AR to first data):", s}, UVM_NONE)
      `uvm_info("PERF", $sformatf("LPDDR5 total: %0d accesses, page hit %0d / miss %0d / conflict %0d, %0d refreshes",
                tot_acc, tot_pg[0], tot_pg[1], tot_pg[2], tot_ref), UVM_NONE)
    endfunction
  endclass

  // ==========================================================================
  class phone_env extends uvm_env;
    `uvm_component_utils(phone_env)
    phone_env_cfg    cfg;
    axi4_agent       m_agent [NM];
    lpddr5_agent     ch_agent [NCH];
    apb_agent        apbx_agent;
    apb_agent        apb_mon_agent;
    phone_scoreboard sb;
    phone_perf       perf;
    phone_reg_block  regmodel;
    reg2axi_adapter  axi_adapter;
    apb2reg_adapter  apb_adapter;
    uvm_reg_predictor #(apb_item) predictor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(phone_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", "phone_env_cfg not set")
      foreach (m_agent[m]) begin
        string n = $sformatf("m%0d_agent", m);
        m_agent[m] = axi4_agent::type_id::create(n, this);
        uvm_config_db#(axi4_cfg)::set(this, n, "cfg", cfg.pm_cfg[m]);
      end
      foreach (ch_agent[c]) begin
        string n = $sformatf("ch%0d_agent", c);
        ch_agent[c] = lpddr5_agent::type_id::create(n, this);
        uvm_config_db#(axi4_cfg)::set(this, n, "cfg", cfg.ch_cfg[c]);
        uvm_config_db#(lpddr5_cfg)::set(this, n, "lp_cfg", cfg.lp_cfg[c]);
      end
      apbx_agent = apb_agent::type_id::create("apbx_agent", this);
      uvm_config_db#(apb_cfg)::set(this, "apbx_agent", "cfg", cfg.apbx_cfg);
      apb_mon_agent = apb_agent::type_id::create("apb_mon_agent", this);
      uvm_config_db#(apb_cfg)::set(this, "apb_mon_agent", "cfg", cfg.apb_mon_cfg);
      uvm_config_db#(soc_env_cfg)::set(this, "sb", "cfg", cfg);
      sb   = phone_scoreboard::type_id::create("sb", this);
      perf = phone_perf::type_id::create("perf", this);

      regmodel = phone_reg_block::type_id::create("regmodel");
      regmodel.build();
      axi_adapter = reg2axi_adapter::type_id::create("axi_adapter");
      apb_adapter = apb2reg_adapter::type_id::create("apb_adapter");
      predictor   = uvm_reg_predictor#(apb_item)::type_id::create("predictor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      foreach (m_agent[m]) begin
        m_agent[m].ap.connect(sb.mst_imp);
      end
      foreach (ch_agent[c]) begin
        ch_agent[c].ap.connect(sb.ch_imp);
        perf.ch_agent[c] = ch_agent[c];
      end
      apb_mon_agent.ap.connect(sb.apb_imp);
      sb.rm = regmodel;
      sb.perf = perf;
      regmodel.default_map.set_sequencer(m_agent[M_CPU].sqr, axi_adapter);
      regmodel.default_map.set_auto_predict(0);
      predictor.map     = regmodel.default_map;
      predictor.adapter = apb_adapter;
      apb_mon_agent.ap.connect(predictor.bus_in);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      `uvm_info("ENV", {"LPDDR5 channel config: ", cfg.lp_cfg[0].convert2string()}, UVM_NONE)
    endfunction
  endclass
endpackage
`endif
