// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// lpddr5_pkg -- LPDDR5 / LPDDR5X memory-channel VIP behind an AXI4 port
// ----------------------------------------------------------------------------
// An AXI4 slave agent (axi4_pkg) whose responder takes its timing from an
// LPDDR5 channel model instead of random delays. Storage stays a
// mem_vip_pkg::mem_model, so scoreboards and backdoor access work unchanged.
//
// What one channel models (one x16 LPDDR5 channel + its controller):
//  * 16 banks in bank-group mode (4 BG x 4 banks), one open row per bank,
//    2 KB page; open-page (default) or closed-page (auto-precharge) policy.
//  * Per 32-byte access (BL16 x16): page hit / miss (bank closed) /
//    conflict (other row open), with tRCD, tRP, tRAS, tRRD, tFAW, tWR,
//    tRTP, write-to-read (tWTR) and read-to-write turnaround, RL / WL, the
//    data-bus burst time and a controller + PHY pipeline latency.
//  * Refresh: all-bank (REFab every tREFI, channel blocked for tRFCab) or
//    per-bank (REFpb on a bank pair every tREFI/8, that pair blocked for
//    tRFCpb). Refreshes are scheduled in time whether or not traffic comes.
//  * Requests are served in arrival order per direction (FR-FCFS reordering
//    is not modeled); reads and writes share the bank and bus state.
//  * Address mapping: the channel-select bits of the system address are
//    squeezed out (cfg.chan_lsb / chan_bits), then
//    local[10:0] column (2 KB page), local[14:11] bank, local[..:15] row.
//
// Timing values are representative of the JEDEC speed bins (JESD209-5),
// not a particular vendor datasheet.
//
// Use: lpddr5_agent (an axi4_agent) with an axi4_cfg ("cfg", role AXI4_SLAVE)
// and an lpddr5_cfg ("lp_cfg") in the config DB.
// ============================================================================
`ifndef LPDDR5_PKG_SV
`define LPDDR5_PKG_SV
package lpddr5_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mem_vip_pkg::*;
  import axi4_pkg::*;

  typedef enum int { LP5_5500 = 0, LP5_6400 = 1, LP5X_7500 = 2, LP5X_8533 = 3 } lpddr5_speed_e;
  typedef enum int { PAGE_OPEN = 0, PAGE_CLOSED = 1 } lpddr5_page_policy_e;
  typedef enum int { REF_ALL_BANK = 0, REF_PER_BANK = 1 } lpddr5_ref_mode_e;
  typedef enum int { PG_HIT = 0, PG_MISS = 1, PG_CONFLICT = 2 } lpddr5_page_e;

  // ==========================================================================
  class lpddr5_cfg extends uvm_object;
    `uvm_object_utils(lpddr5_cfg)

    int                  channel = 0;
    lpddr5_speed_e       speed   = LP5_6400;
    lpddr5_page_policy_e page_policy = PAGE_OPEN;
    lpddr5_ref_mode_e    ref_mode    = REF_ALL_BANK;
    bit                  refresh_en  = 1;
    bit                  posted_writes = 1;   // B as soon as the write is buffered

    // ---- system-address -> channel-local mapping ----
    longint unsigned dram_base = 64'h8000_0000;
    int unsigned     chan_lsb  = 12;          // first channel-select bit
    int unsigned     chan_bits = 5;           // log2(channels)

    // ---- geometry ----
    int unsigned col_bits  = 11;              // 2 KB page
    int unsigned bank_bits = 4;               // 16 banks: [3:2] bank group
    int unsigned atom_bytes = 32;             // BL16 on a x16 channel

    // ---- clocks (ns) ----
    real tck_axi = 2.0;                       // AXI / NoC clock of the port
    real tck;                                 // LPDDR5 CK period
    // ---- timing (ns) ----
    real rl, wl, t_burst;
    real t_rcd = 18.0, t_rp = 18.0, t_ras = 42.0, t_wr = 34.0, t_rtp = 7.5;
    real t_rrd = 5.0, t_faw = 20.0, t_wtr = 12.0, t_rtw = 10.0;
    real t_refi = 3906.0, t_rfcab = 280.0, t_rfcpb = 140.0;
    // controller + PHY: request pipeline and read-return pipeline
    real t_ctrl_rd = 20.0, t_ctrl_wr_ack = 8.0;

    function new(string name = "lpddr5_cfg");
      super.new(name);
      set_speed(LP5_6400);
    endfunction

    // RL / WL in CK cycles per bin (BL16, DBI off, set 0), data rate in MT/s
    function void set_speed(lpddr5_speed_e s);
      int rate, rl_nck, wl_nck;
      speed = s;
      case (s)
        LP5_5500:  begin rate = 5500; rl_nck = 15; wl_nck = 8;  end
        LP5_6400:  begin rate = 6400; rl_nck = 17; wl_nck = 9;  end
        LP5X_7500: begin rate = 7500; rl_nck = 20; wl_nck = 10; end
        default:   begin rate = 8533; rl_nck = 23; wl_nck = 12; end
      endcase
      tck     = 8000.0 / rate;                // CK = data rate / 8 (WCK 4:1, DDR)
      rl      = rl_nck * tck;
      wl      = wl_nck * tck;
      t_burst = (atom_bytes * 8.0 / 16.0) * 1000.0 / rate;   // BL16 on 16 DQ
    endfunction

    // channel-local byte address
    function longint unsigned local_addr(longint unsigned a);
      longint unsigned off = a - dram_base;
      longint unsigned lo  = off & ((64'd1 << chan_lsb) - 1);
      longint unsigned hi  = off >> (chan_lsb + chan_bits);
      return (hi << chan_lsb) | lo;
    endfunction
    function int unsigned bank_of(longint unsigned la);
      return int'((la >> col_bits) & ((64'd1 << bank_bits) - 1));
    endfunction
    function int unsigned row_of(longint unsigned la);
      return int'(la >> (col_bits + bank_bits));
    endfunction

    virtual function string convert2string();
      return $sformatf("ch%0d %s %s %s: tCK %.3f RL %.2f WL %.2f tRCD %.1f tRP %.1f tRAS %.1f tREFI %.0f tRFC %.0f ns",
                       channel, speed.name(), page_policy.name(), ref_mode.name(), tck, rl, wl,
                       t_rcd, t_rp, t_ras, t_refi, ref_mode == REF_ALL_BANK ? t_rfcab : t_rfcpb);
    endfunction
  endclass

  // ==========================================================================
  // lpddr5_model -- bank / bus / refresh state of one channel (time in ns)
  // ==========================================================================
  class lpddr5_model extends uvm_object;
    `uvm_object_utils(lpddr5_model)

    lpddr5_cfg cfg;
    // per bank
    bit          b_open   [16];
    int unsigned b_row    [16];
    realtime     b_act    [16];     // last ACT
    realtime     b_ready  [16];     // earliest next RD/WR/ACT on this bank
    realtime     b_pre_ok [16];     // earliest PRE
    realtime     b_ref_until [16];  // end of the last refresh of this bank
    // channel
    realtime     act_hist[$];       // last four ACT times (tFAW)
    realtime     last_act = -1000.0;
    realtime     bus_free = 0.0;
    realtime     last_rd_cmd = -1000.0, last_wr_end = -1000.0;
    realtime     ref_block_until = 0.0;        // all-bank refresh
    realtime     next_ref = 0.0;
    int unsigned next_pb = 0;                  // next bank pair for REFpb

    // statistics
    longint unsigned n_access[2], n_page[3], n_ref, n_ref_stall;
    longint unsigned n_bursts[2];
    real             sum_lat[2], max_lat[2];

    // coverage sample
    bit           cv_write;
    lpddr5_page_e cv_page;
    int unsigned  cv_bg;
    bit           cv_ref_stall;
    covergroup cg;
      option.per_instance = 1;
      cp_dir:  coverpoint cv_write { bins rd = {0}; bins wr = {1}; }
      cp_page: coverpoint cv_page  { bins hit = {PG_HIT}; bins miss = {PG_MISS}; bins conflict = {PG_CONFLICT}; }
      cp_bg:   coverpoint cv_bg    { bins bg[] = {[0:3]}; }
      cp_ref:  coverpoint cv_ref_stall { bins no = {0}; bins stalled = {1}; }
      x_dir_page: cross cp_dir, cp_page;
      x_page_bg:  cross cp_page, cp_bg;
    endgroup

    // the same bins counted through fcov_pkg (FCOV lines, merged by regress.py)
    fcov_pkg::fcov_group fg;

    function new(string name = "lpddr5_model");
      super.new(name);
      cg = new();
    endfunction

    function void set_fcov(string inst);
      string dir[] = '{"rd", "wr"}, pg[] = '{"hit", "miss", "conflict"}, bg[] = '{"bg0", "bg1", "bg2", "bg3"};
      fg = fcov_pkg::fcov_db::group("lpddr5_model", inst);
      fg.add_bins("cp_dir", dir);
      fg.add_bins("cp_page", pg);
      fg.add_bins("cp_bg", bg);
      fg.add_bins("cp_ref", '{"no", "stalled"});
      fg.cross2("x_dir_page", "cp_dir", dir, "cp_page", pg);
      fg.cross2("x_page_bg", "cp_page", pg, "cp_bg", bg);
    endfunction

    function void init(lpddr5_cfg c);
      cfg = c;
      foreach (b_open[i]) begin
        b_open[i] = 0; b_act[i] = -1000.0; b_ready[i] = 0.0; b_pre_ok[i] = 0.0; b_ref_until[i] = 0.0;
      end
      // stagger the refresh phase of the channels
      next_ref = (cfg.ref_mode == REF_ALL_BANK ? cfg.t_refi : cfg.t_refi / 8.0) *
                 (1.0 + (cfg.channel % 8) / 8.0);
    endfunction

    static function realtime rmax(realtime a, realtime b);
      return (a > b) ? a : b;
    endfunction

    // apply every refresh due at or before t
    function void do_refresh(realtime t);
      if (!cfg.refresh_en) return;
      while (next_ref <= t) begin
        if (cfg.ref_mode == REF_ALL_BANK) begin
          realtime start = next_ref;
          foreach (b_open[i]) if (b_open[i]) start = rmax(start, b_pre_ok[i]);
          if (start > next_ref) start = start + cfg.t_rp;      // precharge-all first
          foreach (b_open[i]) begin
            b_open[i]  = 0;
            b_ready[i] = rmax(b_ready[i], start + cfg.t_rfcab);
            b_ref_until[i] = start + cfg.t_rfcab;
          end
          ref_block_until = rmax(ref_block_until, start + cfg.t_rfcab);
          next_ref += cfg.t_refi;
        end else begin
          for (int k = 0; k < 2; k++) begin                    // bank pair b, b+8
            int unsigned b = next_pb + 8 * k;
            realtime start = next_ref;
            if (b_open[b]) start = rmax(start, b_pre_ok[b]) + cfg.t_rp;
            b_open[b]  = 0;
            b_ready[b] = rmax(b_ready[b], start + cfg.t_rfcpb);
            b_ref_until[b] = start + cfg.t_rfcpb;
          end
          next_pb  = (next_pb + 1) % 8;
          next_ref += cfg.t_refi / 8.0;
        end
        n_ref++;
      end
    endfunction

    // one 32-byte access arriving at the device scheduler at time t;
    // returns the time its data is on the bus (start), data_end via ref
    function realtime access(realtime t, bit wr, longint unsigned sys_addr, ref realtime data_end);
      longint unsigned la = cfg.local_addr(sys_addr);
      int unsigned b = cfg.bank_of(la), r = cfg.row_of(la);
      realtime t0, t_act, t_cmd, d0;
      lpddr5_page_e pg;
      bit stalled;

      do_refresh(t);
      t0 = t;
      if (cfg.ref_mode == REF_ALL_BANK && ref_block_until > t0) t0 = ref_block_until;
      stalled = b_ref_until[b] > t;      // this access waits for a refresh
      t0 = rmax(t0, b_ready[b]);

      if (b_open[b] && b_row[b] == r) begin
        pg = PG_HIT;
        t_cmd = t0;
      end else begin
        realtime t_pre_done = t0;
        if (b_open[b]) begin
          pg = PG_CONFLICT;
          t_pre_done = rmax(t0, b_pre_ok[b]) + cfg.t_rp;
        end else
          pg = PG_MISS;
        t_act = rmax(t_pre_done, last_act + cfg.t_rrd);
        if (act_hist.size() >= 4) t_act = rmax(t_act, act_hist[0] + cfg.t_faw);
        act_hist.push_back(t_act);
        if (act_hist.size() > 4) void'(act_hist.pop_front());
        last_act = rmax(last_act, t_act);
        b_open[b] = 1; b_row[b] = r; b_act[b] = t_act;
        b_pre_ok[b] = t_act + cfg.t_ras;
        t_cmd = t_act + cfg.t_rcd;
      end
      // turnaround
      if (wr) t_cmd = rmax(t_cmd, last_rd_cmd + cfg.t_rtw);
      else    t_cmd = rmax(t_cmd, last_wr_end + cfg.t_wtr);
      d0 = rmax(t_cmd + (wr ? cfg.wl : cfg.rl), bus_free);
      data_end = d0 + cfg.t_burst;
      bus_free = data_end;
      if (wr) begin
        last_wr_end = data_end;
        b_pre_ok[b] = rmax(b_pre_ok[b], data_end + cfg.t_wr);
      end else begin
        last_rd_cmd = t_cmd;
        b_pre_ok[b] = rmax(b_pre_ok[b], t_cmd + cfg.t_rtp);
      end
      b_ready[b] = t_cmd + cfg.t_burst;          // tCCD ~ one burst
      if (cfg.page_policy == PAGE_CLOSED) begin    // auto-precharge
        b_open[b]  = 0;
        b_ready[b] = rmax(b_ready[b], b_pre_ok[b] + cfg.t_rp);
      end

      n_access[wr]++;
      n_page[pg]++;
      if (stalled) n_ref_stall++;
      cv_write = wr; cv_page = pg; cv_bg = (b >> 2) & 3; cv_ref_stall = stalled;
      cg.sample();
      if (fg != null) begin
        string sd = wr ? "wr" : "rd", sp = (pg == PG_HIT) ? "hit" : (pg == PG_MISS) ? "miss" : "conflict";
        string sb = $sformatf("bg%0d", (b >> 2) & 3);
        fg.hit("cp_dir", sd);
        fg.hit("cp_page", sp);
        fg.hit("cp_bg", sb);
        fg.hit("cp_ref", stalled ? "stalled" : "no");
        fg.hit("x_dir_page", {sd, ".", sp});
        fg.hit("x_page_bg", {sp, ".", sb});
      end
      return d0;
    endfunction

    // plan a burst: beat i's data is ready at avail[i] (ns, absolute)
    function void plan(realtime t, axi4_item it, ref realtime avail[], output realtime done);
      longint unsigned cur_atom = '1;
      realtime d0 = t, dend = t, tq;
      tq = t + (it.write ? 0.0 : cfg.t_ctrl_rd / 2.0);   // request side of the pipeline
      avail = new[it.beats()];
      for (int unsigned i = 0; i < it.beats(); i++) begin
        longint unsigned a = it.beat_addr(i);
        longint unsigned atom = a / cfg.atom_bytes;
        if (atom != cur_atom) begin
          d0 = access(tq, it.write, a, dend);
          cur_atom = atom;
        end
        avail[i] = (it.write ? dend : d0 + cfg.t_burst + cfg.t_ctrl_rd / 2.0);
      end
      done = it.write ? dend : avail[it.beats() - 1];
    endfunction

    function void note_latency(bit wr, real ns);
      n_bursts[wr]++;
      sum_lat[wr] += ns;
      if (ns > max_lat[wr]) max_lat[wr] = ns;
    endfunction

    function real hit_rate();
      longint unsigned n = n_page[PG_HIT] + n_page[PG_MISS] + n_page[PG_CONFLICT];
      return n ? 100.0 * n_page[PG_HIT] / n : 0.0;
    endfunction
  endclass

  // ==========================================================================
  // lpddr5_slave_driver -- axi4_slave_driver with LPDDR5 timing
  // ==========================================================================
  class lpddr5_slave_driver extends axi4_slave_driver;
    `uvm_component_utils(lpddr5_slave_driver)

    lpddr5_cfg   lp_cfg;
    lpddr5_model model;
    protected realtime r_avail[];
    protected realtime r_t0;
    protected axi4_item r_cur;
    protected realtime w_done_q[$];     // B times, in write_done order (= B order)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(lpddr5_cfg)::get(this, "", "lp_cfg", lp_cfg))
        `uvm_fatal("NOCFG", {get_full_name(), ": lpddr5_cfg not set"})
      model = lpddr5_model::type_id::create({get_name(), "_model"});
      model.init(lp_cfg);
      model.set_fcov(get_parent() != null ? get_parent().get_full_name() : get_full_name());
    endfunction

    static function int unsigned cycles_until(realtime t, real tck);
      realtime now = $realtime;
      if (t <= now) return 0;
      return int'((t - now) / tck + 0.999);
    endfunction

    function void write_done(axi4_item t);
      realtime done;
      realtime av[];
      if (t.resp[0] != AXI4_OKAY) begin
        w_done_q.push_back($realtime + lp_cfg.t_ctrl_wr_ack);
        return;
      end
      model.plan($realtime, t, av, done);
      w_done_q.push_back(lp_cfg.posted_writes ? $realtime + lp_cfg.t_ctrl_wr_ack : done + lp_cfg.t_ctrl_wr_ack);
      model.note_latency(1, done - $realtime);
    endfunction

    function int unsigned write_resp_delay(axi4_item t);
      realtime d = w_done_q.size() ? w_done_q.pop_front() : $realtime;
      return cycles_until(d, lp_cfg.tck_axi);
    endfunction

    function void read_start(axi4_item t, axi4_resp_e rsp);
      realtime done;
      r_cur = t;
      r_t0  = $realtime;
      if (rsp != AXI4_OKAY) begin
        r_avail = new[t.beats()];
        foreach (r_avail[i]) r_avail[i] = $realtime + lp_cfg.t_ctrl_rd;
        return;
      end
      model.plan($realtime, t, r_avail, done);
      model.note_latency(0, r_avail[0] - r_t0);
    endfunction

    function int unsigned read_beat_delay(axi4_item t, int unsigned i);
      return cycles_until(r_avail[i], lp_cfg.tck_axi);
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      if (model != null && model.fg != null) model.fg.dump();
    endfunction
  endclass

  // ==========================================================================
  class lpddr5_agent extends axi4_agent;
    `uvm_component_utils(lpddr5_agent)
    lpddr5_cfg lp_cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(lpddr5_cfg)::get(this, "", "lp_cfg", lp_cfg))
        `uvm_fatal("NOCFG", {get_full_name(), ": lpddr5_cfg not set"})
      uvm_config_db#(lpddr5_cfg)::set(this, "*", "lp_cfg", lp_cfg);
      axi4_slave_driver::type_id::set_inst_override(lpddr5_slave_driver::get_type(), "drv", this);
      super.build_phase(phase);
    endfunction

    function lpddr5_model model();
      lpddr5_slave_driver d;
      if (sdrv == null || !$cast(d, sdrv)) return null;
      return d.model;
    endfunction
  endclass
endpackage
`endif
