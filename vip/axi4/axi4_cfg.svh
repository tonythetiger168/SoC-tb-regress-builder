// SPDX-License-Identifier: Apache-2.0
// axi4_cfg -- agent configuration
class axi4_err_range extends uvm_object;
  `uvm_object_utils(axi4_err_range)
  bit [31:0]  lo, hi;
  axi4_resp_e resp = AXI4_SLVERR;
  function new(string name = "axi4_err_range");
    super.new(name);
  endfunction
endclass

class axi4_cfg extends uvm_object;
  `uvm_object_utils(axi4_cfg)

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  axi4_role_e   role = AXI4_MASTER;
  int           port = 0;            // tag copied into monitored items
  bit           has_coverage = 1;
  int unsigned  id_width = 8;        // IDs the master may use / slave echoes

  // ---- master knobs (upper bounds of random delays, in clocks) ----
  int unsigned  max_b_delay = 0;     // BREADY low before the response
  int unsigned  max_r_gap   = 0;     // RREADY low between beats

  // ---- slave (memory responder) knobs ----
  mem_vip_pkg::mem_model mem;        // storage; created by the agent if null
  int unsigned  max_aready_delay = 0; // AWREADY/ARREADY low cycles
  int unsigned  max_wready_delay = 0; // WREADY low cycles per beat
  int unsigned  max_b_latency    = 0; // cycles from WLAST to BVALID
  int unsigned  max_r_latency    = 0; // cycles from AR to first RVALID
  int unsigned  max_rvalid_gap   = 0; // RVALID low cycles between beats
  axi4_err_range err_ranges[$];       // start address in range -> resp

  function new(string name = "axi4_cfg");
    super.new(name);
  endfunction

  function void add_err_range(bit [31:0] lo, bit [31:0] hi, axi4_resp_e resp = AXI4_SLVERR);
    axi4_err_range r = axi4_err_range::type_id::create("err_range");
    r.lo = lo; r.hi = hi; r.resp = resp;
    err_ranges.push_back(r);
  endfunction

  function axi4_resp_e resp_for(bit [31:0] addr);
    foreach (err_ranges[i])
      if (addr >= err_ranges[i].lo && addr <= err_ranges[i].hi) return err_ranges[i].resp;
    return AXI4_OKAY;
  endfunction

  // delays are drawn uniformly in [0:max], biased to 0 half of the time
  static function int unsigned rand_delay(int unsigned max);
    if (max == 0 || $urandom_range(1, 0) == 0) return 0;
    return $urandom_range(max, 0);
  endfunction
endclass
