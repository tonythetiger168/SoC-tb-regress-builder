// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_noc_test_pkg -- UVM tests of the 8K TV SoC NoC on its own
// ----------------------------------------------------------------------------
// 12 AXI4 master agents (one per master NI) and 12 AXI4 memory-responder
// agents (one per slave NI: 8 DRAM ports, boot SRAM, APB, VDEC and GPU
// register windows). All responders share one mem_model, so the whole 4 GB
// address space behaves as one memory and the scoreboard can check end to
// end through the NoC: every completed burst on a master port is predicted
// from a byte shadow (unwritten bytes = mem_model init pattern) and the
// address map (DECERR outside it). Each master works in its own address
// slices, so per-byte order is that master's program order.
// Each slave responder also checks that only bursts for its own port reach
// it (DRAM channel = interleave hash of the address).
// ============================================================================
`ifndef TV8K_NOC_TEST_PKG_SV
`define TV8K_NOC_TEST_PKG_SV
package tv8k_noc_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;
  import tv8k_noc_pkg::*;
  import tv8k_lat_pkg::*;

  // address slice of master m in each region
  function automatic bit [31:0] slice_lo(int m, int s);
    case (s)
      S_SRAM:  return SRAM_BASE  + m * 32'h1000;
      S_APB:   return APB_BASE   + m * 32'h2000;
      S_VDECR: return VDECR_BASE + m * 32'h1000;
      S_GPUR:  return GPUR_BASE  + m * 32'h1000;
      default: return DRAM_BASE  + m * 32'h0400_0000;   // 64 MB apart
    endcase
  endfunction
  function automatic bit [31:0] slice_hi(int m, int s, int unsigned dram_bytes = 32'h1_0000);
    case (s)
      S_SRAM, S_VDECR, S_GPUR: return slice_lo(m, s) + 32'hFFF;
      S_APB:                   return slice_lo(m, s) + 32'h1FFF;
      default:                 return slice_lo(m, s) + dram_bytes - 1;
    endcase
  endfunction

  // --------------------------------------------------------------------------
  `uvm_analysis_imp_decl(_mst)
  class tv8k_noc_sb extends uvm_scoreboard;
    `uvm_component_utils(tv8k_noc_sb)
    uvm_analysis_imp_mst #(axi4_item, tv8k_noc_sb) mst_imp;
    mem_model mem;
    bit       skip_ep[int];      // endpoints whose bursts are not predicted (RTL register blocks)
    byte unsigned shadow[bit [31:0]];
    int unsigned n_checks, n_errors, n_bursts, n_decerr;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      mst_imp = new("mst_imp", this);
    endfunction

    function void check(bit ok, string what);
      n_checks++;
      if (!ok) begin n_errors++; `uvm_error("NOC_SB", what) end
    endfunction

    function byte unsigned exp_byte(bit [31:0] a);
      if (shadow.exists(a)) return shadow[a];
      return mem_model::init_byte(mem.init_kind, mem_addr_t'(a));
    endfunction

    virtual function void write_mst(axi4_item t);
      string tag = $sformatf("%s %s", ep_name(t.port), t.convert2string());
      if (skip_ep.exists(int'(decode(t.addr)))) return;
      n_bursts++;
      if (decode(t.addr) == EP_NONE) begin
        n_decerr++;
        foreach (t.resp[i]) check(t.resp[i] == AXI4_DECERR, {tag, ": expected DECERR"});
        return;
      end
      foreach (t.resp[i]) check(t.resp[i] == AXI4_OKAY, $sformatf("%s: resp[%0d]=%s", tag, i, t.resp[i].name()));
      for (int unsigned i = 0; i < t.beats(); i++) begin
        bit [31:0] ba = t.beat_addr(i) & ~32'h3;
        bit [3:0]  ln = t.lanes(i);
        for (int b = 0; b < 4; b++) begin
          if (!ln[b]) continue;
          if (t.write) begin
            if (t.strb[i][b]) shadow[ba + b] = t.data[i][8*b +: 8];
          end else
            check(t.data[i][8*b +: 8] == exp_byte(ba + b),
                  $sformatf("%s: beat %0d byte %08h read %02h expected %02h", tag, i, ba + b,
                            t.data[i][8*b +: 8], exp_byte(ba + b)));
        end
      end
    endfunction

    function void check_phase(uvm_phase phase);
      if (n_checks == 0) `uvm_error("NOC_SB", "no checks were made")
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("NOC_SB", $sformatf("bursts=%0d (DECERR %0d) checks=%0d errors=%0d", n_bursts, n_decerr,
                n_checks, n_errors), UVM_NONE)
      if (n_errors == 0 && n_checks > 0) $display("SB_PASS checks=%0d", n_checks);
    endfunction
  endclass

  // slave-side check: a burst reaching port s must decode to s
  class tv8k_route_chk extends uvm_subscriber #(axi4_item);
    `uvm_component_utils(tv8k_route_chk)
    int unsigned n;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void write(axi4_item t);
      n++;
      if (int'(decode(t.addr)) != t.port)
        `uvm_error("ROUTE", $sformatf("%s received %s, which decodes to %s", ep_name(t.port),
                   t.convert2string(), ep_name(decode(t.addr))))
    endfunction
  endclass

  // --------------------------------------------------------------------------
  class tv8k_noc_env extends uvm_env;
    `uvm_component_utils(tv8k_noc_env)
    axi4_agent      m_agent [NM];
    axi4_cfg        m_cfg   [NM];
    tv8k_lat_mon    lat     [NM];
    axi4_agent      s_agent [NS];
    axi4_cfg        s_cfg   [NS];
    tv8k_route_chk  rchk;
    tv8k_noc_sb     sb;
    mem_model       mem;
    bit             c1p_vdec = 0;   // the c1p decoder RTL is the VDEC master and S_VDECR slave

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      int unsigned tmode = 1;
      super.build_phase(phase);
      void'($value$plusargs("SOC_TIMING=%d", tmode));
      mem = mem_model::type_id::create("mem");
      for (int m = 0; m < NM; m++) begin
        m_cfg[m] = axi4_cfg::type_id::create($sformatf("m%0d_cfg", m));
        m_cfg[m].role = AXI4_MASTER; m_cfg[m].port = m; m_cfg[m].id_width = 4;
        m_cfg[m].max_b_delay = tmode; m_cfg[m].max_r_gap = tmode;
        m_agent[m] = axi4_agent::type_id::create($sformatf("m%0d_agent", m), this);
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("m%0d_agent", m), "cfg", m_cfg[m]);
        lat[m] = tv8k_lat_mon::type_id::create($sformatf("m%0d_lat", m), this);
        lat[m].master = ep_name(m);
        if (c1p_vdec && m == M_VDEC) begin       // RTL master: monitor only (64-bit beats)
          m_cfg[m].is_active = UVM_PASSIVE; m_cfg[m].has_coverage = 0; lat[m].dbytes = 8;
        end
      end
      for (int s = 0; s < NS; s++) begin
        s_cfg[s] = axi4_cfg::type_id::create($sformatf("s%0d_cfg", s));
        s_cfg[s].role = AXI4_SLAVE; s_cfg[s].port = NM + s; s_cfg[s].mem = mem; s_cfg[s].has_coverage = 0;
        if (NM + s < S_SRAM) begin                  // DRAM ports: memory-like latency
          s_cfg[s].max_r_latency = 20 * tmode; s_cfg[s].max_b_latency = 10 * tmode;
          s_cfg[s].max_aready_delay = 2 * tmode; s_cfg[s].max_wready_delay = tmode;
        end else begin
          s_cfg[s].max_r_latency = 4 * tmode; s_cfg[s].max_b_latency = 2 * tmode;
          s_cfg[s].max_aready_delay = tmode; s_cfg[s].max_wready_delay = tmode;
          s_cfg[s].max_rvalid_gap = tmode;
        end
        if (c1p_vdec && NM + s == S_VDECR) s_cfg[s].is_active = UVM_PASSIVE;   // c1p registers answer
        s_agent[s] = axi4_agent::type_id::create($sformatf("s%0d_agent", s), this);
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("s%0d_agent", s), "cfg", s_cfg[s]);
      end
      rchk = tv8k_route_chk::type_id::create("rchk", this);
      sb = tv8k_noc_sb::type_id::create("sb", this);
      sb.mem = mem;
      if (c1p_vdec) sb.skip_ep[S_VDECR] = 1;
    endfunction

    function void connect_phase(uvm_phase phase);
      foreach (m_agent[m]) if (!(c1p_vdec && m == M_VDEC)) m_agent[m].ap.connect(sb.mst_imp);
      foreach (s_agent[s]) s_agent[s].ap.connect(rchk.analysis_export);
    endfunction
  endclass

  // --------------------------------------------------------------------------
  // random bursts spread over a master's slices: DRAM weighted by dram_pct
  class tv8k_mix_seq extends uvm_sequence #(axi4_item);
    `uvm_object_utils(tv8k_mix_seq)
    int m = 0;
    int unsigned n_items = 50, dram_pct = 70, decerr_pct = 2, max_beats = 16, wr_pct = 50;
    int unsigned dram_bytes = 32'h1_0000;
    bit narrow = 1;
    function new(string name = "tv8k_mix_seq"); super.new(name); endfunction
    task body();
      axi4_random_seq g = axi4_random_seq::type_id::create("g");
      g.max_beats = max_beats; g.wr_pct = wr_pct; g.max_delay = 1;
      g.allow_narrow = narrow; g.allow_fixed = narrow; g.allow_wrap = narrow; g.allow_partial_strb = narrow;
      repeat (n_items) begin
        axi4_item t;
        int unsigned r = $urandom_range(99, 0);
        int s;
        if (r < decerr_pct) begin
          g.lo = 32'h2000_0000 + m * 32'h1000; g.hi = g.lo + 32'hFFF;
        end else begin
          s = (r < decerr_pct + dram_pct) ? S_DRAM0 : S_SRAM + $urandom_range(3, 0);
          g.lo = slice_lo(m, s); g.hi = slice_hi(m, s, dram_bytes);
        end
        t = g.gen();
        start_item(t);
        finish_item(t);
      end
    endtask
  endclass

  // --------------------------------------------------------------------------
  class tv8k_noc_base_test extends uvm_test;
    `uvm_component_utils(tv8k_noc_base_test)
    tv8k_noc_env env;
    int unsigned items = 60;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("SOC_ITEMS=%d", items));
      env = tv8k_noc_env::type_id::create("env", this);
      // read-latency budgets (cycles) of the real-time masters, from
      // socgen/specs/tv8k_soc.yaml masters[].qos.latency_target
      tv8k_lat_db::target_cyc["cpu"]    = 150;
      tv8k_lat_db::target_cyc["pq"]     = 250;
      tv8k_lat_db::target_cyc["disp"]   = 200;
      tv8k_lat_db::target_cyc["hdmirx"] = 250;
      tv8k_lat_db::target_cyc["tsd"]    = 300;
      tv8k_lat_db::target_cyc["adsp"]   = 200;
    endfunction
    // per-master traffic; override
    virtual task traffic(int m);
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      #1us;
      for (int m = 0; m < NM; m++) begin
        automatic int mm = m;
        fork traffic(mm); join_none
      end
      wait fork;
      #2us;
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      int n_over = tv8k_lat_db::report(1.0);
      // the NoC bench has no QoS arbitration yet, so a missed budget is reported, not failed
      if (n_over) `uvm_warning("LAT_BUDGET", $sformatf("%0d master->dram read paths over their p99 budget", n_over))
    endfunction
  endclass

  // every master touches every slave and a hole
  class tv8k_noc_smoke_test extends tv8k_noc_base_test;
    `uvm_component_utils(tv8k_noc_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual task traffic(int m);
      axi4_resp_e r;
      bit [31:0] d;
      for (int s = NM; s < NEP; s++) begin
        bit [31:0] a = slice_lo(m, s);
        if (s < S_SRAM) begin                       // land on DRAM channel s
          while (int'(decode(a)) != s) a += 32'h1000;
        end
        axi4_api::write32(env.m_agent[m].sqr, a + 4, 32'hA500_0000 | (m << 8) | s, r);
        axi4_api::read32(env.m_agent[m].sqr, a + 4, d, r);
      end
      axi4_api::read32(env.m_agent[m].sqr, 32'h2000_0000, d, r);
      axi4_api::write32(env.m_agent[m].sqr, 32'h4000_0000, d, r);
    endtask
  endclass

  // all masters at once, random bursts (narrow, FIXED, WRAP, strobes)
  class tv8k_noc_rand_test extends tv8k_noc_base_test;
    `uvm_component_utils(tv8k_noc_rand_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual task traffic(int m);
      tv8k_mix_seq s = tv8k_mix_seq::type_id::create($sformatf("mix%0d", m));
      s.m = m; s.n_items = items;
      s.start(env.m_agent[m].sqr);
    endtask
  endclass

  // long full-width bursts (up to 256 beats) from every master into DRAM
  class tv8k_noc_bw_test extends tv8k_noc_base_test;
    `uvm_component_utils(tv8k_noc_bw_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual task traffic(int m);
      tv8k_mix_seq s = tv8k_mix_seq::type_id::create($sformatf("bw%0d", m));
      s.m = m; s.n_items = items / 2; s.dram_pct = 100; s.decerr_pct = 0; s.max_beats = 256; s.narrow = 0;
      s.dram_bytes = 32'h4_0000;
      s.start(env.m_agent[m].sqr);
    endtask
  endclass

  // every master hammers the same DRAM channel and the APB window: contention
  class tv8k_noc_hotspot_test extends tv8k_noc_base_test;
    `uvm_component_utils(tv8k_noc_hotspot_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual task traffic(int m);
      for (int i = 0; i < items; i++) begin
        axi4_item t;
        bit [31:0] a = slice_lo(m, S_DRAM0) + 32'h1000 * $urandom_range(63, 0);
        while (decode(a) != EPB'(S_DRAM0)) a += 32'h1000;       // channel 0 only
        if ($urandom_range(3, 0) == 0) a = slice_lo(m, S_APB);
        t = axi4_api::make($urandom_range(1, 0), a + 4 * $urandom_range(15, 0), $urandom_range(16, 1), 2,
                           AXI4_INCR, 8'($urandom_range(15, 0)));
        if (t.last_addr()[31:12] != t.addr[31:12]) t.len = 0;
        axi4_api::run(env.m_agent[m].sqr, t);
      end
    endtask
  endclass

  // --------------------------------------------------------------------------
  // VDEC subsystem: the c1p decoder (RTL) decodes an HEVC stream on the NoC.
  // Build with sim/tv8k_vdec.f. scripts/tv8k_vdec_prep.sh makes, per stream,
  // the firmware register script (.apb, c1p's fw/host/c1p_hevc_fw_dump) and the
  // reference planes (.mlf.raw, c1p's scripts/c1p_hevc_model.py).
  //   +C1P_BS=<s.265> +C1P_APB=<s.apb> +C1P_REF=<s.mlf.raw>  [+VDEC_BG=<items>]
  // The CPU master VIP replays the script into the decoder's registers through
  // the NoC (S_VDECR, AXI4 -> AXI4-Lite); the stream is fed on the decoder's
  // AXI4-Stream port; the decoder writes the final pictures through its 64-bit
  // master NI into DRAM (frame buffers relocated from the script's 0x0100_0000
  // to this master's DRAM slice). Every sample is then compared with the model.
  // The other masters run random background traffic (+VDEC_BG items each).
  class tv8k_vdec_hevc_test extends tv8k_noc_base_test;
    `uvm_component_utils(tv8k_vdec_hevc_test)
    typedef struct { int w, h, bd, mono; int unsigned yb, cbb, crb, ys, cs; } pic_t;
    pic_t pics[$];
    bit [31:0] fb_off;
    int unsigned bg_items = 40;
    bit fw_done;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env.c1p_vdec = 1;
      void'($value$plusargs("VDEC_BG=%d", bg_items));
      fb_off = slice_lo(M_VDEC, S_DRAM0) - 32'h0100_0000;
    endfunction

    task wr(bit [15:0] a, bit [31:0] d);
      axi4_resp_e r;
      axi4_api::write32(env.m_agent[M_CPU].sqr, VDECR_BASE + a, d, r);
      if (r != AXI4_OKAY) `uvm_error("VDEC_FW", $sformatf("write %04h=%08h: %s", a, d, r.name()))
    endtask
    task rd(bit [15:0] a, output bit [31:0] d);
      axi4_resp_e r;
      axi4_api::read32(env.m_agent[M_CPU].sqr, VDECR_BASE + a, d, r);
      if (r != AXI4_OKAY) `uvm_error("VDEC_FW", $sformatf("read %04h: %s", a, r.name()))
    endtask
    task poll(bit [15:0] a, bit [31:0] m, bit [31:0] v, string what);
      bit [31:0] d;
      repeat (200000) begin
        rd(a, d);
        if ((d & m) == v) return;
      end
      `uvm_fatal("VDEC_FW", $sformatf("timeout polling %s (%04h = %08h)", what, a, d))
    endtask

    // replay the firmware script (same ops as c1p's tb_hevc_file)
    task firmware();
      string f, op;
      int fd, typ, n, k, n_slice = 0, n_nal = 0;
      int unsigned a, d, m, v;
      bit [31:0] r;
      if (!$value$plusargs("C1P_APB=%s", f)) `uvm_fatal("VDEC_FW", "+C1P_APB=<script.apb> not given")
      fd = $fopen(f, "r");
      if (fd == 0) `uvm_fatal("VDEC_FW", {"cannot open ", f})
      wr(16'h0010, 32'h0000_0201);          // CTRL: fmt = HEVC, front end on
      wr(16'h0404, 32'h0000_0064);          // IRQ_ENABLE: nal_hdr, hevc_done, hevc_err
      while (!$feof(fd)) begin
        if ($fscanf(fd, "%s", op) != 1) break;
        case (op)
          "N": begin
            void'($fscanf(fd, "%d", typ));
            poll(16'h0400, 32'h4, 32'h4, "IRQ_STATUS.nal_hdr");
            rd(16'h0200, r);
            if (int'((r[7:0] >> 1) & 8'h3F) != typ)
              `uvm_error("VDEC_FW", $sformatf("NAL %0d type %0d, expected %0d", n_nal, (r[7:0] >> 1) & 8'h3F, typ))
            wr(16'h0400, 32'h4);
            n_nal++;
          end
          "K": begin
            void'($fscanf(fd, "%d", n));
            wr(16'h0224, 32'(n));
            poll(16'h0218, 32'h8, 32'h0, "CABAC_STAT.skip");
          end
          "F": begin
            pic_t p;
            int unsigned dy, dcb, dcr;
            void'($fscanf(fd, "%d %d %d %d %d %h %h %h %d %d %h %h %h", k, p.w, p.h, p.bd, p.mono, p.yb, p.cbb,
                          p.crb, p.ys, p.cs, dy, dcb, dcr));
            p.yb = p.yb + fb_off; p.cbb = p.cbb + fb_off; p.crb = p.crb + fb_off;
            pics.push_back(p);
          end
          "W": begin
            void'($fscanf(fd, "%h %h", a, d));
            if (a inside {'h1420, 'h1424, 'h1428}) d = d + fb_off;      // frame buffer bases -> DRAM
            wr(16'(a), d);
            if (a == 'h1400 && d[0]) n_slice++;
          end
          "P": begin
            void'($fscanf(fd, "%h %h %h", a, m, v));
            poll(16'(a), m, v, $sformatf("P %04h", a));
            if (a == 'h1404 && m == 'h6) begin
              rd(16'h1404, r);
              if (r[2]) `uvm_error("VDEC_FW", $sformatf("slice %0d HEVC_STATUS=%08h", n_slice, r))
              rd(16'h0400, r);
              if (r[6] || !r[5]) `uvm_error("VDEC_FW", $sformatf("slice %0d IRQ_STATUS=%08h", n_slice, r))
              wr(16'h0400, 32'h60);
            end
          end
          "X": wr(16'h0208, 32'h4);
          default: `uvm_fatal("VDEC_FW", {"bad script op ", op})
        endcase
      end
      $fclose(fd);
      `uvm_info("VDEC_FW", $sformatf("script done: %0d NALs, %0d slices, %0d pictures", n_nal, n_slice,
                pics.size()), UVM_NONE)
      #20us;                                // last frame-buffer writes drain through the NoC
      fw_done = 1;
    endtask

    virtual task traffic(int m);
      if (m == M_CPU) firmware();
      else if (m != M_VDEC && bg_items != 0) begin
        tv8k_mix_seq s = tv8k_mix_seq::type_id::create($sformatf("bg%0d", m));
        s.m = m; s.n_items = bg_items; s.decerr_pct = 0;
        s.start(env.m_agent[m].sqr);
      end
    endtask

    function int unsigned rd16(bit [31:0] a);
      return {env.mem.read_byte(mem_addr_t'(a + 1)), env.mem.read_byte(mem_addr_t'(a))};
    endfunction

    // the decoded planes in DRAM against the model's final (loop-filtered) planes
    function void check_phase(uvm_phase phase);
      string f;
      int fd, n_bad = 0, i = 0;
      byte unsigned raw[];
      int unsigned n_ref;
      super.check_phase(phase);
      if (!fw_done) begin `uvm_error("VDEC", "firmware script did not finish") return; end
      if (!$value$plusargs("C1P_REF=%s", f)) begin `uvm_error("VDEC", "+C1P_REF=<planes.raw> not given") return; end
      fd = $fopen(f, "rb");
      if (fd == 0) begin `uvm_error("VDEC", {"cannot open ", f}) return; end
      void'($fseek(fd, 0, 2)); n_ref = $ftell(fd) / 2; void'($fseek(fd, 0, 0));
      raw = new[n_ref * 2];
      foreach (raw[j]) raw[j] = byte'($fgetc(fd));
      $fclose(fd);
      foreach (pics[pi]) begin
        pic_t p = pics[pi];
        for (int pl = 0; pl < (p.mono ? 1 : 3); pl++) begin
          int w = pl ? p.w / 2 : p.w, h = pl ? p.h / 2 : p.h;
          int unsigned base = (pl == 0) ? p.yb : (pl == 1) ? p.cbb : p.crb;
          int unsigned stride = pl ? p.cs : p.ys;
          for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) begin
              int unsigned got = rd16(base + y * stride + 2 * x), exp;
              if (i >= n_ref) begin i++; continue; end
              exp = {raw[2 * i + 1], raw[2 * i]};
              if (got != exp && n_bad++ < 10)
                `uvm_error("VDEC", $sformatf("pic %0d plane %0d (%0d,%0d) @%08h: %03h, model %03h", pi, pl, x, y,
                           base + y * stride + 2 * x, got, exp))
              env.sb.n_checks++;
              i++;
            end
        end
      end
      if (n_bad > 10) `uvm_error("VDEC", $sformatf("%0d samples differ in total", n_bad))
      if (i != n_ref) `uvm_error("VDEC", $sformatf("%0d samples decoded, the model has %0d", i, n_ref))
      `uvm_info("VDEC", $sformatf("%0d pictures, %0d samples compared with the model, %0d differ", pics.size(), i,
                n_bad), UVM_NONE)
    endfunction
  endclass
endpackage
`endif
