// SPDX-License-Identifier: Apache-2.0
// axi4_agent -- master (driver + sequencer) or slave (memory responder) role,
// active or passive; the monitor (and optional coverage) is always present.
// Config: uvm_config_db #(axi4_cfg) "cfg" and #(virtual axi4_if) "vif".
typedef uvm_sequencer #(axi4_item) axi4_sequencer;

class axi4_agent extends uvm_agent;
  `uvm_component_utils(axi4_agent)

  axi4_cfg           cfg;
  axi4_sequencer     sqr;
  axi4_master_driver mdrv;
  axi4_slave_driver  sdrv;
  axi4_monitor       mon;
  axi4_coverage      cov;
  uvm_analysis_port #(axi4_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", {get_full_name(), ": axi4_cfg not set"})
    uvm_config_db#(axi4_cfg)::set(this, "*", "cfg", cfg);
    mon = axi4_monitor::type_id::create("mon", this);
    if (cfg.has_coverage) cov = axi4_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == AXI4_MASTER) begin
        sqr  = axi4_sequencer::type_id::create("sqr", this);
        mdrv = axi4_master_driver::type_id::create("drv", this);
      end else begin
        if (cfg.mem == null) cfg.mem = mem_vip_pkg::mem_model::type_id::create({get_name(), "_mem"});
        sdrv = axi4_slave_driver::type_id::create("drv", this);
      end
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    ap = mon.ap;
    if (cov != null) mon.ap.connect(cov.analysis_export);
    if (mdrv != null) mdrv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
