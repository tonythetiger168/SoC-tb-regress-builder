// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// apb_pkg -- APB4 UVM VIP: item, config, requester (master) driver, completer
// (slave) responder backed by mem_vip_pkg::mem_model, monitor, coverage,
// agent, sequences. Interface: apb_if.sv; assertions: apb_sva.sv.
// ============================================================================
`ifndef APB_PKG_SV
`define APB_PKG_SV
package apb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum int { APB_MASTER = 0, APB_SLAVE = 1 } apb_role_e;

  // ---------------------------------------------------------------- item
  class apb_item extends uvm_sequence_item;
    `uvm_object_utils(apb_item)
    rand bit        write;
    rand bit [31:0] addr;
    rand bit [31:0] data;      // PWDATA for writes, PRDATA for reads
    rand bit [3:0]  strb = 4'hF;
    rand bit [2:0]  prot;
    bit             slverr;
    int unsigned    wait_cycles;   // ACCESS cycles with PREADY low (monitor)
    int unsigned    idle_before;   // master driver: idle cycles before SETUP
    time            t_end;

    function new(string name = "apb_item");
      super.new(name);
    endfunction

    virtual function void do_copy(uvm_object rhs);
      apb_item r;
      super.do_copy(rhs);
      if (!$cast(r, rhs)) `uvm_fatal("APB_ITEM", "do_copy: type mismatch")
      write = r.write; addr = r.addr; data = r.data; strb = r.strb; prot = r.prot;
      slverr = r.slverr; wait_cycles = r.wait_cycles; idle_before = r.idle_before; t_end = r.t_end;
    endfunction

    virtual function string convert2string();
      return $sformatf("%s addr=%08h data=%08h strb=%04b%s waits=%0d", write ? "WR" : "RD",
                       addr, data, strb, slverr ? " SLVERR" : "", wait_cycles);
    endfunction
  endclass

  // ---------------------------------------------------------------- config
  class apb_cfg extends uvm_object;
    `uvm_object_utils(apb_cfg)
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    apb_role_e   role = APB_MASTER;
    bit          has_coverage = 1;
    // completer knobs
    mem_vip_pkg::mem_model mem;      // storage; created by the agent if null
    int unsigned max_wait = 0;       // PREADY low cycles in ACCESS, [0:max_wait]
    bit [31:0]   err_lo = 32'hFFFF_FFFF, err_hi = 32'h0;  // PSLVERR window (empty by default)
    bit [31:0]   addr_mask = 32'hFFFF_FFFF;               // applied before the memory access
    function new(string name = "apb_cfg");
      super.new(name);
    endfunction
    function bit is_err(bit [31:0] a);
      return a >= err_lo && a <= err_hi;
    endfunction
  endclass

  // ---------------------------------------------------------------- master driver
  class apb_master_driver extends uvm_driver #(apb_item);
    `uvm_component_utils(apb_master_driver)
    virtual apb_if vif;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": apb_if not set"})
    endfunction
    task run_phase(uvm_phase phase);
      vif.mst_cb.psel <= 1'b0; vif.mst_cb.penable <= 1'b0; vif.mst_cb.pwrite <= 1'b0;
      vif.mst_cb.paddr <= '0; vif.mst_cb.pwdata <= '0; vif.mst_cb.pstrb <= '0; vif.mst_cb.pprot <= '0;
      @(posedge vif.pclk iff vif.presetn === 1'b1);
      forever begin
        seq_item_port.get_next_item(req);
        // re-synchronize: get_next_item can return outside the clocking event,
        // and a clocking drive issued there only matures one edge later
        @(vif.mst_cb);
        repeat (req.idle_before) @(vif.mst_cb);
        // SETUP
        vif.mst_cb.paddr   <= req.addr;
        vif.mst_cb.pwrite  <= req.write;
        vif.mst_cb.pwdata  <= req.write ? req.data : 32'h0;
        vif.mst_cb.pstrb   <= req.write ? req.strb : 4'h0;
        vif.mst_cb.pprot   <= req.prot;
        vif.mst_cb.psel    <= 1'b1;
        vif.mst_cb.penable <= 1'b0;
        @(vif.mst_cb);
        // ACCESS
        vif.mst_cb.penable <= 1'b1;
        req.wait_cycles = 0;
        do begin
          @(vif.mst_cb);
          if (vif.mst_cb.pready !== 1'b1) req.wait_cycles++;
        end while (vif.mst_cb.pready !== 1'b1);
        if (!req.write) req.data = vif.mst_cb.prdata;
        req.slverr = vif.mst_cb.pslverr;
        req.t_end = $time;
        vif.mst_cb.psel    <= 1'b0;
        vif.mst_cb.penable <= 1'b0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  // ---------------------------------------------------------------- slave driver
  class apb_slave_driver extends uvm_component;
    `uvm_component_utils(apb_slave_driver)
    virtual apb_if vif;
    apb_cfg        cfg;
    int unsigned   n_xfers;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": apb_if not set"})
      if (!uvm_config_db#(apb_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", {get_full_name(), ": apb_cfg not set"})
    endfunction
    task run_phase(uvm_phase phase);
      vif.slv_cb.pready <= 1'b0; vif.slv_cb.pslverr <= 1'b0; vif.slv_cb.prdata <= '0;
      @(posedge vif.pclk iff vif.presetn === 1'b1);
      forever begin
        @(vif.slv_cb);
        if (vif.slv_cb.psel === 1'b1 && vif.slv_cb.penable !== 1'b1) begin
          // SETUP sampled: answer during ACCESS
          bit [31:0] a   = vif.slv_cb.paddr;
          bit        wr  = vif.slv_cb.pwrite;
          bit [31:0] wd  = vif.slv_cb.pwdata;
          bit [3:0]  st  = vif.slv_cb.pstrb;
          bit        err = cfg.is_err(a);
          int unsigned w = (cfg.max_wait == 0) ? 0 : $urandom_range(cfg.max_wait, 0);
          if (w) begin
            vif.slv_cb.pready <= 1'b0;
            repeat (w) @(vif.slv_cb);
          end
          vif.slv_cb.pready  <= 1'b1;
          vif.slv_cb.pslverr <= err;
          vif.slv_cb.prdata  <= (!wr && !err) ? 32'(cfg.mem.read_bus(a & cfg.addr_mask, 4)) : 32'h0;
          if (wr && !err) cfg.mem.write_bus(a & cfg.addr_mask, 64'(wd), 8'(st), 4);
          @(vif.slv_cb);     // transfer completes on this edge
          vif.slv_cb.pready  <= 1'b0;
          vif.slv_cb.pslverr <= 1'b0;
          vif.slv_cb.prdata  <= '0;
          n_xfers++;
        end
      end
    endtask
    function void report_phase(uvm_phase phase);
      `uvm_info("APB_SDRV", $sformatf("%s: served %0d transfers; %s", get_full_name(), n_xfers,
                cfg.mem.convert2string()), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- monitor
  class apb_monitor extends uvm_monitor;
    `uvm_component_utils(apb_monitor)
    virtual apb_if vif;
    uvm_analysis_port #(apb_item) ap;
    int unsigned n_xfers;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": apb_if not set"})
    endfunction
    task run_phase(uvm_phase phase);
      int unsigned waits = 0;
      forever begin
        @(vif.mon_cb);
        if (vif.presetn !== 1'b1) begin waits = 0; continue; end
        if (vif.mon_cb.psel && vif.mon_cb.penable) begin
          if (vif.mon_cb.pready) begin
            apb_item t = apb_item::type_id::create("apb_mon");
            t.write = vif.mon_cb.pwrite; t.addr = vif.mon_cb.paddr; t.strb = vif.mon_cb.pstrb;
            t.prot = vif.mon_cb.pprot;
            t.data = vif.mon_cb.pwrite ? vif.mon_cb.pwdata : vif.mon_cb.prdata;
            t.slverr = vif.mon_cb.pslverr; t.wait_cycles = waits; t.t_end = $time;
            waits = 0;
            n_xfers++;
            `uvm_info("APB_MON", {get_full_name(), ": ", t.convert2string()}, UVM_HIGH)
            ap.write(t);
          end else waits++;
        end
      end
    endtask
    function void report_phase(uvm_phase phase);
      `uvm_info("APB_MON", $sformatf("%s: %0d transfers", get_full_name(), n_xfers), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- coverage
  class apb_coverage extends uvm_subscriber #(apb_item);
    `uvm_component_utils(apb_coverage)
    bit cv_write, cv_slverr;
    int unsigned cv_waits;
    bit [3:0] cv_strb;
    int unsigned n_sampled;
    covergroup cg;
      option.per_instance = 1;
      cp_dir:   coverpoint cv_write  { bins rd = {0}; bins wr = {1}; }
      cp_err:   coverpoint cv_slverr { bins ok = {0}; bins err = {1}; }
      cp_waits: coverpoint cv_waits  { bins none = {0}; bins one = {1}; bins few = {[2:4]}; bins many = {[5:$]}; }
      cp_strb:  coverpoint cv_strb iff (cv_write) { bins full = {4'hF}; bins partial = {[4'h1:4'hE]}; bins none = {0}; }
      x_dir_err:   cross cp_dir, cp_err;
      x_dir_waits: cross cp_dir, cp_waits;
    endgroup
    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction
    function void write(apb_item t);
      cv_write = t.write; cv_slverr = t.slverr; cv_waits = t.wait_cycles; cv_strb = t.strb;
      n_sampled++;
      cg.sample();
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("APB_COV", $sformatf("%s: %0d transfers sampled, coverage %0.1f%%", get_full_name(),
                n_sampled, cg.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- agent
  typedef uvm_sequencer #(apb_item) apb_sequencer;

  class apb_agent extends uvm_agent;
    `uvm_component_utils(apb_agent)
    apb_cfg           cfg;
    apb_sequencer     sqr;
    apb_master_driver mdrv;
    apb_slave_driver  sdrv;
    apb_monitor       mon;
    apb_coverage      cov;
    uvm_analysis_port #(apb_item) ap;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(apb_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", {get_full_name(), ": apb_cfg not set"})
      uvm_config_db#(apb_cfg)::set(this, "*", "cfg", cfg);
      mon = apb_monitor::type_id::create("mon", this);
      if (cfg.has_coverage) cov = apb_coverage::type_id::create("cov", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        if (cfg.role == APB_MASTER) begin
          sqr  = apb_sequencer::type_id::create("sqr", this);
          mdrv = apb_master_driver::type_id::create("drv", this);
        end else begin
          if (cfg.mem == null) cfg.mem = mem_vip_pkg::mem_model::type_id::create({get_name(), "_mem"});
          sdrv = apb_slave_driver::type_id::create("drv", this);
        end
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      ap = mon.ap;
      if (cov != null) mon.ap.connect(cov.analysis_export);
      if (mdrv != null) mdrv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ---------------------------------------------------------------- sequences
  class apb_single_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(apb_single_seq)
    apb_item item;
    function new(string name = "apb_single_seq");
      super.new(name);
    endfunction
    task body();
      start_item(item);
      finish_item(item);
    endtask
  endclass

  class apb_api;
    static task write(apb_sequencer sqr, bit [31:0] addr, bit [31:0] data, output bit slverr,
                      input bit [3:0] strb = 4'hF);
      apb_single_seq s = apb_single_seq::type_id::create("s");
      s.item = apb_item::type_id::create("w");
      s.item.write = 1; s.item.addr = addr; s.item.data = data; s.item.strb = strb;
      s.start(sqr);
      slverr = s.item.slverr;
    endtask
    static task read(apb_sequencer sqr, bit [31:0] addr, output bit [31:0] data, output bit slverr);
      apb_single_seq s = apb_single_seq::type_id::create("s");
      s.item = apb_item::type_id::create("r");
      s.item.write = 0; s.item.addr = addr; s.item.strb = 0;
      s.start(sqr);
      data = s.item.data;
      slverr = s.item.slverr;
    endtask
  endclass

  // random word accesses in [lo, hi]
  class apb_random_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(apb_random_seq)
    int unsigned n_items = 30;
    bit [31:0]   lo = 0, hi = 32'hFFF;
    function new(string name = "apb_random_seq");
      super.new(name);
    endfunction
    task body();
      repeat (n_items) begin
        apb_item t = apb_item::type_id::create("t");
        t.write = $urandom_range(1, 0);
        t.addr  = (lo + $urandom_range(hi - lo, 0)) & ~32'h3;
        t.data  = $urandom();
        t.strb  = t.write ? (($urandom_range(3, 0) == 0) ? 4'($urandom()) : 4'hF) : 4'h0;
        t.idle_before = $urandom_range(2, 0);
        start_item(t);
        finish_item(t);
      end
    endtask
  endclass
endpackage
`endif
