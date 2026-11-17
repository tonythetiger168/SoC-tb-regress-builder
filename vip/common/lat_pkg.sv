// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// lat_pkg -- per-path latency samples, the one format every bench feeds
// ----------------------------------------------------------------------------
//   lat_pkg::lat_db::add("CPU", "LPDDR5_07", "R", 42);   // cycles
//
// One sample per completed transaction: master name, slave (target) name,
// R or W, latency in clock cycles (by convention: address handshake to the
// last R beat, or to the B handshake). Names must not contain spaces.
//
// With +LAT_FILE=<path> (regress.py passes one per run) samples are written to
// that file as "LAT <master> <slave> <R|W> <cycles>" lines; without it they go
// to the log in the same form. regress/regress.py computes min/avg/p50/p95/
// p99/max per path, the master x slave heatmap and histograms, and merges them
// across seeds, tests and suites.
// ============================================================================
`ifndef LAT_PKG_SV
`define LAT_PKG_SV
package lat_pkg;

  class lat_db;
    static int          fd = -1;      // -1: not opened yet, 0: log, else file
    static int unsigned n_samples;

    static function void open();
      string f;
      if (fd != -1) return;
      if ($value$plusargs("LAT_FILE=%s", f)) begin
        fd = $fopen(f, "w");
        if (fd == 0) $display("LAT_WARN cannot open %s, writing samples to the log", f);
      end else fd = 0;
    endfunction

    static function void add(string master, string slave, string dir, longint unsigned cycles);
      open();
      if (fd != 0) $fdisplay(fd, "LAT %s %s %s %0d", master, slave, dir, cycles);
      else         $display("LAT %s %s %s %0d", master, slave, dir, cycles);
      n_samples++;
      if (fd != 0 && n_samples % 1024 == 0) $fflush(fd);
    endfunction

    // call at the end of the run (report_phase); safe to call more than once
    static function void flush();
      if (fd > 0) $fflush(fd);
    endfunction
  endclass

endpackage
`endif
