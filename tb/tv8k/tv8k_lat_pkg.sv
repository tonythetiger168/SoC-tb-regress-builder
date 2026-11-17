// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_lat_pkg -- per-path latency measurement for the 8K TV SoC
// ----------------------------------------------------------------------------
// tv8k_lat_mon watches one master port (an axi4_if) and times every burst
// from its address handshake to the B handshake (write) or the RLAST
// handshake (read), in clock cycles (the convention of vip/common/lat_pkg). It works for masters with several
// bursts in flight because the NoC master NI answers in issue order. The
// target is decoded from the burst address (tv8k_noc_pkg::decode).
//
// tv8k_lat_db keeps every sample per (master, target, R/W) and at the end of
// the test prints:
//   * one line per path:  PATHLAT <master> <target> <R|W> n=.. min=.. avg=..
//                         p50=.. p90=.. p95=.. p99=.. max=.. bytes=.. mbps=..
//     plus one "dram" aggregate over the 8 DRAM ports per master,
//   * every sample also goes to lat_pkg::lat_db (the one latency format of
//     all benches: 'LAT <master> <target> <R|W> <cycles>' to +LAT_FILE or the
//     log), which regress/regress.py merges across seeds, tests and suites,
// and writes tv8k_latency.csv (every sample) and tv8k_latency_summary.csv,
// which tools/tv8k_latency_report.py turns into the heatmaps / histograms.
// ============================================================================
`ifndef TV8K_LAT_PKG_SV
`define TV8K_LAT_PKG_SV
package tv8k_lat_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import tv8k_noc_pkg::*;

  typedef struct {
    int unsigned cycles;
    int unsigned bytes;
    longint unsigned t_end;   // completion cycle
  } lat_sample_t;

  class tv8k_lat_db;
    static lat_sample_t s[string][$];          // key "<master> <target> <R|W>"
    static int unsigned target_cyc[string];    // master -> read latency budget (cycles)
    static longint unsigned t_first = 0, t_last = 0;

    static function void add(string master, string target, bit write, int unsigned cycles,
                             int unsigned bytes, longint unsigned t_end_cyc);
      string k = {master, " ", target, write ? " W" : " R"};
      lat_sample_t x;
      x.cycles = cycles; x.bytes = bytes; x.t_end = t_end_cyc;
      s[k].push_back(x);
      if (t_first == 0 || t_end_cyc < t_first) t_first = t_end_cyc;
      if (t_end_cyc > t_last) t_last = t_end_cyc;
      lat_pkg::lat_db::add(master, target, write ? "W" : "R", cycles);
    endfunction

    // right-aligned field (some simulators ignore %Nd widths on unsized ints)
    static function string rj(string v, int w);
      while (v.len() < w) v = {" ", v};
      return v;
    endfunction
    static function string lj(string v, int w);
      while (v.len() < w) v = {v, " "};
      return v;
    endfunction

    static function int unsigned pct(int unsigned v[$], int p);
      int idx;
      if (v.size() == 0) return 0;
      idx = (p * v.size() + 99) / 100 - 1;
      if (idx < 0) idx = 0;
      if (idx >= v.size()) idx = v.size() - 1;
      return v[idx];
    endfunction

    // prints the table, writes the CSVs; returns the number of paths over budget
    static function int report(real clk_ns, string csv = "tv8k_latency.csv",
                               string sum_csv = "tv8k_latency_summary.csv");
      int fd, fs, n_over = 0;
      string keys[$];
      lat_sample_t agg[string][$];
      // dram aggregate per master and direction
      foreach (s[k]) begin
        string m, t, d;
        if ($sscanf(k, "%s %s %s", m, t, d) == 3 && t.substr(0, 3) == "dram" && t.len() > 4)
          foreach (s[k][i]) agg[{m, " dram ", d}].push_back(s[k][i]);
      end
      foreach (agg[k]) foreach (agg[k][i]) s[k].push_back(agg[k][i]);
      foreach (s[k]) keys.push_back(k);
      keys.sort();
      fd = $fopen(csv, "w");
      fs = $fopen(sum_csv, "w");
      $fdisplay(fd, "master,target,dir,cycles,bytes,t_end");
      $fdisplay(fs, "master,target,dir,n,min,avg,p50,p90,p95,p99,max,bytes,mbps,budget,over");
      $display("PATHLAT ------------------------------------------------------------------------------------------");
      $display("PATHLAT %s %s D %s %s %s %s %s %s %s %s %s %s", lj("master", 7), lj("target", 10),
               rj("n", 6), rj("min", 5), rj("avg", 7), rj("p50", 5), rj("p90", 5), rj("p95", 5),
               rj("p99", 5), rj("max", 5), rj("bytes", 9), rj("MB/s", 8));
      foreach (keys[ki]) begin
        string k = keys[ki];
        string m, t, d;
        int unsigned v[$];
        longint unsigned sum = 0, bytes = 0;
        real avg, mbps, span_ns;
        int unsigned budget;
        bit over;
        void'($sscanf(k, "%s %s %s", m, t, d));
        foreach (s[k][i]) begin
          v.push_back(s[k][i].cycles);
          sum += s[k][i].cycles;
          bytes += s[k][i].bytes;
          if (t != "dram") $fdisplay(fd, "%s,%s,%s,%0d,%0d,%0d", m, t, d, s[k][i].cycles, s[k][i].bytes, s[k][i].t_end);
        end
        v.sort();
        avg = real'(sum) / v.size();
        span_ns = (t_last > t_first) ? real'(t_last - t_first) * clk_ns : 1.0;
        mbps = real'(bytes) / span_ns * 1000.0;      // bytes/ns = GB/s -> MB/s
        budget = target_cyc.exists(m) ? target_cyc[m] : 0;
        over = (budget != 0 && d == "R" && pct(v, 99) > budget);
        if (over && t == "dram") n_over++;
        $display("PATHLAT %s %s %s %s %s %s %s %s %s %s %s %s %s%s", lj(m, 7), lj(t, 10), d,
                 rj($sformatf("%0d", v.size()), 6), rj($sformatf("%0d", v[0]), 5),
                 rj($sformatf("%.1f", avg), 7), rj($sformatf("%0d", pct(v, 50)), 5),
                 rj($sformatf("%0d", pct(v, 90)), 5), rj($sformatf("%0d", pct(v, 95)), 5),
                 rj($sformatf("%0d", pct(v, 99)), 5), rj($sformatf("%0d", v[$]), 5),
                 rj($sformatf("%0d", bytes), 9), rj($sformatf("%.1f", mbps), 8),
                 over ? $sformatf("  OVER BUDGET (p99 > %0d)", budget) : "");
        $fdisplay(fs, "%s,%s,%s,%0d,%0d,%.2f,%0d,%0d,%0d,%0d,%0d,%0d,%.2f,%0d,%0d", m, t, d, v.size(), v[0], avg,
                  pct(v, 50), pct(v, 90), pct(v, 95), pct(v, 99), v[$], bytes, mbps, budget, over);
      end
      $display("PATHLAT ------------------------------------------------------------------------------------------");
      $fclose(fd);
      $fclose(fs);
      lat_pkg::lat_db::flush();
      return n_over;
    endfunction
  endclass

  // --------------------------------------------------------------------------
  class tv8k_lat_mon extends uvm_component;
    `uvm_component_utils(tv8k_lat_mon)
    virtual axi4_if vif;
    string master = "m";
    int unsigned dbytes = 4;                    // port width in bytes

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi4_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": axi4_if not set"})
    endfunction

    typedef struct { longint unsigned t0; bit [31:0] addr; int unsigned bytes; } pend_t;

    task run_phase(uvm_phase phase);
      pend_t aw_q[$], ar_q[$];
      longint unsigned cyc = 0;
      forever begin
        @(vif.mon_cb);
        cyc++;
        if (vif.aresetn !== 1'b1) begin aw_q.delete(); ar_q.delete(); continue; end
        if (vif.mon_cb.awvalid && vif.mon_cb.awready)
          aw_q.push_back('{cyc, vif.mon_cb.awaddr, (int'(vif.mon_cb.awlen) + 1) << vif.mon_cb.awsize});
        if (vif.mon_cb.arvalid && vif.mon_cb.arready)
          ar_q.push_back('{cyc, vif.mon_cb.araddr, (int'(vif.mon_cb.arlen) + 1) << vif.mon_cb.arsize});
        if (vif.mon_cb.bvalid && vif.mon_cb.bready && aw_q.size()) begin
          pend_t p = aw_q.pop_front();
          tv8k_lat_db::add(master, ep_name(decode(p.addr)), 1, int'(cyc - p.t0), p.bytes, cyc);
        end
        if (vif.mon_cb.rvalid && vif.mon_cb.rready && vif.mon_cb.rlast && ar_q.size()) begin
          pend_t p = ar_q.pop_front();
          tv8k_lat_db::add(master, ep_name(decode(p.addr)), 0, int'(cyc - p.t0), p.bytes, cyc);
        end
      end
    endtask
  endclass
endpackage
`endif
