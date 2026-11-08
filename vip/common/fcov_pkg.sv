// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// fcov_pkg -- simulator-neutral functional coverage bins
// ----------------------------------------------------------------------------
// The open-source flow (Verilator) does not collect SystemVerilog covergroups, so coverage models
// mirror their coverpoints here. Every bin is declared up front (so a bin that
// is never hit still counts as a hole) and counted on each sample. At the end
// of the run each group prints one line per bin:
//
//     FCOV <model> <inst> <point> <bin> <hits>
//
// regress/regress.py merges these lines over every seed, test and suite.
// Names must not contain spaces. Keep the real covergroups too: commercial
// simulators collect both.
//
//   fcov_group g = fcov_db::group("axi4_coverage", get_full_name());
//   g.add_bins("cp_dir", '{"rd", "wr"});                // declare
//   g.hit("cp_dir", write ? "wr" : "rd");                // sample
//   g.dump();                                            // report_phase
// ============================================================================
`ifndef FCOV_PKG_SV
`define FCOV_PKG_SV
package fcov_pkg;

  class fcov_group;
    string       model, inst;
    int unsigned hits[string];     // "<point> <bin>" -> hits
    string       order[$];         // declaration order, for stable output
    bit          dumped;

    function new(string model, string inst);
      this.model = model;
      this.inst  = inst;
    endfunction

    function void bin(string point, string name);
      string k = {point, " ", name};
      if (!hits.exists(k)) begin
        hits[k] = 0;
        order.push_back(k);
      end
    endfunction

    // declare several bins of one point at once
    function void add_bins(string point, string names[]);
      foreach (names[i]) bin(point, names[i]);
    endfunction

    // declare the cross of two already-declared points as "<a>.<b>" bins
    function void cross2(string point, string pa, string a[], string pb, string b[]);
      foreach (a[i]) foreach (b[j]) bin(point, {a[i], ".", b[j]});
    endfunction

    // drop a declared bin that cannot occur (like an ignore_bins); later hits still report it
    function void ignore(string point, string name);
      string k = {point, " ", name};
      if (hits.exists(k) && hits[k] == 0) begin
        hits.delete(k);
        foreach (order[i]) if (order[i] == k) begin order.delete(i); break; end
      end
    endfunction

    function void hit(string point, string name);
      string k = {point, " ", name};
      if (!hits.exists(k)) order.push_back(k);   // undeclared bins are still reported
      hits[k] = hits.exists(k) ? hits[k] + 1 : 1;
    endfunction

    function int unsigned n_bins();
      return order.size();
    endfunction

    function int unsigned n_covered();
      int unsigned n = 0;
      foreach (order[i]) if (hits[order[i]] > 0) n++;
      return n;
    endfunction

    function real percent();
      return order.size() ? 100.0 * n_covered() / order.size() : 0.0;
    endfunction

    function void dump();
      if (dumped) return;
      dumped = 1;
      foreach (order[i]) $display("FCOV %s %s %s %0d", model, inst, order[i], hits[order[i]]);
    endfunction
  endclass

  class fcov_db;
    static fcov_group groups[string];
    static string     names[$];

    static function fcov_group group(string model, string inst);
      string k = {model, " ", inst};
      if (!groups.exists(k)) begin
        groups[k] = new(model, inst);
        names.push_back(k);
      end
      return groups[k];
    endfunction

    // print every group not printed yet (for benches without report_phase hooks)
    static function void dump_all();
      foreach (names[i]) groups[names[i]].dump();
    endfunction
  endclass

endpackage
`endif
