// SPDX-License-Identifier: Apache-2.0
// axi4_latency -- feeds lat_pkg::lat_db with one sample per monitored burst.
// Connect it to a master-side monitor. Latency is counted in clock cycles from
// the address handshake to the B handshake (writes) or the last R beat
// (reads). The slave name comes from slave_of(), which an environment
// overrides with its address map (default "mem").
class axi4_latency extends uvm_subscriber #(axi4_item);
  `uvm_component_utils(axi4_latency)

  string       master = "";        // default: the parent agent's name
  int unsigned clk_period = 10;    // in the package's time unit (1 ns)
  int unsigned n_sampled;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function string slave_of(axi4_item t);
    return "mem";
  endfunction

  function void write(axi4_item t);
    longint unsigned cyc;
    if (master == "") master = (get_parent() != null) ? get_parent().get_name() : get_name();
    cyc = (t.t_end >= t.t_start) ? (t.t_end - t.t_start) / clk_period : 0;
    lat_pkg::lat_db::add(master, slave_of(t), t.write ? "W" : "R", cyc);
    n_sampled++;
  endfunction

  function void report_phase(uvm_phase phase);
    lat_pkg::lat_db::flush();
  endfunction
endclass
