// SPDX-License-Identifier: Apache-2.0
// axi4_coverage -- functional coverage of monitored bursts
class axi4_coverage extends uvm_subscriber #(axi4_item);
  `uvm_component_utils(axi4_coverage)

  bit          cv_write;
  axi4_burst_e cv_burst;
  int unsigned cv_len;
  bit [2:0]    cv_size;
  axi4_resp_e  cv_resp;
  bit          cv_partial_strb;
  bit          cv_unaligned;
  int unsigned cv_burst_len;   // burst * 4 + length class (0 single, 1 short, 2 mid, 3 long)
  int unsigned n_sampled;

  covergroup cg;
    option.per_instance = 1;
    cp_dir:   coverpoint cv_write { bins rd = {0}; bins wr = {1}; }
    cp_burst: coverpoint cv_burst { bins fixed = {AXI4_FIXED}; bins incr = {AXI4_INCR}; bins wrap = {AXI4_WRAP}; }
    cp_len:   coverpoint cv_len   { bins single = {0}; bins short_b = {[1:3]}; bins mid = {[4:15]};
                                    bins long_b = {[16:255]}; }
    cp_size:  coverpoint cv_size  { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; }
    cp_resp:  coverpoint cv_resp  { bins okay = {AXI4_OKAY}; bins slverr = {AXI4_SLVERR};
                                    bins decerr = {AXI4_DECERR}; }
    cp_pstrb: coverpoint cv_partial_strb { bins full = {0}; bins partial = {1}; }
    cp_unal:  coverpoint cv_unaligned { bins aligned = {0}; bins unaligned = {1}; }
    x_dir_burst: cross cp_dir, cp_burst;
    x_dir_resp:  cross cp_dir, cp_resp;
    // burst type x length class. Only the AXI4-legal pairs are bins: FIXED is
    // at most 16 beats, WRAP is 2, 4, 8 or 16 beats (AXI4 A3.4.1). Written as
    // one coverpoint because Verilator has no cross-bin selection.
    cp_burst_len: coverpoint cv_burst_len {
      bins fixed_single = {0}; bins fixed_short = {1}; bins fixed_mid = {2};
      bins incr_single  = {4}; bins incr_short  = {5}; bins incr_mid  = {6}; bins incr_long = {7};
      bins wrap_short   = {9}; bins wrap_mid    = {10};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg = new();
  endfunction

  function void write(axi4_item t);
    cv_write = t.write;
    cv_burst = t.burst;
    cv_len   = t.len;
    cv_burst_len = 4 * int'(t.burst) + ((t.len == 0) ? 0 : (t.len <= 3) ? 1 : (t.len <= 15) ? 2 : 3);
    cv_size  = t.size;
    cv_resp  = t.worst_resp();
    cv_unaligned = (t.addr & ((32'd1 << t.size) - 1)) != 0;
    cv_partial_strb = 0;
    if (t.write) foreach (t.strb[i]) if (t.strb[i] != t.lanes(i)) cv_partial_strb = 1;
    n_sampled++;
    cg.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("AXI4_COV", $sformatf("%s: %0d bursts sampled, coverage %0.1f%%", get_full_name(),
              n_sampled, cg.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
