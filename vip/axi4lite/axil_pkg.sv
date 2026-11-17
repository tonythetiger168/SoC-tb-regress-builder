// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axil_pkg -- AXI4-Lite UVM VIP
// ----------------------------------------------------------------------------
//   axil_item            one read or write (addr, data, strb, prot, resp)
//   axil_cfg             agent configuration (role, timing knobs, error map)
//   axil_master_driver   one access at a time; AW/W order chosen per item
//   axil_slave_driver    reactive memory responder (mem_vip_pkg::mem_model)
//   axil_monitor         rebuilds accesses from the channels, several in flight
//   axil_coverage        direction x response x strobes x AW/W order x waits
//   axil_agent           master / slave, active / passive
//   axil_scoreboard      predicts every read from the writes before it
//   axil_api, axil_random_seq   directed helpers and a random sequence
// Interface: axil_if.sv; protocol assertions: axil_sva.sv.
// ============================================================================
`ifndef AXIL_PKG_SV
`define AXIL_PKG_SV
package axil_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum bit [1:0] { AXIL_OKAY = 2'b00, AXIL_EXOKAY = 2'b01,
                           AXIL_SLVERR = 2'b10, AXIL_DECERR = 2'b11 } axil_resp_e;
  typedef enum int { AXIL_MASTER = 0, AXIL_SLAVE = 1 } axil_role_e;
  // master: which of AW and W goes first
  typedef enum int { AXIL_AW_W_TOGETHER = 0, AXIL_AW_FIRST = 1, AXIL_W_FIRST = 2 } axil_order_e;

  // ---------------------------------------------------------------- item
  class axil_item extends uvm_sequence_item;
    `uvm_object_utils(axil_item)
    rand bit          write;
    rand bit [31:0]   addr;
    rand bit [31:0]   data;           // WDATA or RDATA
    rand bit [3:0]    strb = 4'hF;
    rand bit [2:0]    prot;
    axil_resp_e       resp;
    // master driver knobs
    axil_order_e      order = AXIL_AW_W_TOGETHER;
    int unsigned      skew;           // cycles between the first and second of AW/W
    int unsigned      resp_delay;     // BREADY/RREADY low cycles
    // filled in by the monitor
    int unsigned      latency;        // cycles from request to response handshake
    time              t_start, t_end;

    function new(string name = "axil_item");
      super.new(name);
    endfunction

    virtual function void do_copy(uvm_object rhs);
      axil_item r;
      super.do_copy(rhs);
      if (!$cast(r, rhs)) `uvm_fatal("AXIL_ITEM", "do_copy: type mismatch")
      write = r.write; addr = r.addr; data = r.data; strb = r.strb; prot = r.prot; resp = r.resp;
      order = r.order; skew = r.skew; resp_delay = r.resp_delay; latency = r.latency;
      t_start = r.t_start; t_end = r.t_end;
    endfunction

    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
      axil_item r;
      if (!$cast(r, rhs)) return 0;
      return write == r.write && addr == r.addr && data == r.data && resp == r.resp &&
             (!write || strb == r.strb) && prot == r.prot;
    endfunction

    virtual function string convert2string();
      return $sformatf("%s addr=%08h data=%08h%s prot=%0d resp=%s", write ? "WR" : "RD", addr, data,
                       write ? $sformatf(" strb=%04b", strb) : "", prot, resp.name());
    endfunction
  endclass

  // ---------------------------------------------------------------- config
  class axil_cfg extends uvm_object;
    `uvm_object_utils(axil_cfg)
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    axil_role_e   role = AXIL_MASTER;
    bit           has_coverage = 1;
    // slave knobs (upper bounds, clocks; each delay is 0 half of the time)
    mem_vip_pkg::mem_model mem;       // storage; created by the agent if null
    int unsigned  max_aready_delay = 0;
    int unsigned  max_wready_delay = 0;
    int unsigned  max_resp_delay   = 0;   // cycles before BVALID / RVALID
    bit [31:0]    err_lo[$], err_hi[$];
    axil_resp_e   err_resp[$];

    function new(string name = "axil_cfg");
      super.new(name);
    endfunction

    function void add_err_range(bit [31:0] lo, bit [31:0] hi, axil_resp_e resp = AXIL_SLVERR);
      err_lo.push_back(lo); err_hi.push_back(hi); err_resp.push_back(resp);
    endfunction

    function axil_resp_e resp_for(bit [31:0] a);
      foreach (err_lo[i]) if (a >= err_lo[i] && a <= err_hi[i]) return err_resp[i];
      return AXIL_OKAY;
    endfunction

    static function int unsigned rand_delay(int unsigned max);
      if (max == 0 || $urandom_range(1, 0) == 0) return 0;
      return $urandom_range(max, 0);
    endfunction
  endclass

  // ---------------------------------------------------------------- master driver
  class axil_master_driver extends uvm_driver #(axil_item);
    `uvm_component_utils(axil_master_driver)
    virtual axil_if vif;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": axil_if not set"})
    endfunction

    task run_phase(uvm_phase phase);
      vif.mst_cb.awvalid <= 1'b0; vif.mst_cb.wvalid <= 1'b0; vif.mst_cb.arvalid <= 1'b0;
      vif.mst_cb.bready <= 1'b0; vif.mst_cb.rready <= 1'b0;
      vif.mst_cb.awaddr <= '0; vif.mst_cb.awprot <= '0; vif.mst_cb.wdata <= '0; vif.mst_cb.wstrb <= '0;
      vif.mst_cb.araddr <= '0; vif.mst_cb.arprot <= '0;
      @(posedge vif.aclk iff vif.aresetn === 1'b1);
      forever begin
        seq_item_port.get_next_item(req);
        @(vif.mst_cb);
        req.t_start = $time;
        if (req.write) drive_write(req); else drive_read(req);
        req.t_end = $time;
        `uvm_info("AXIL_MDRV", {"done: ", req.convert2string()}, UVM_HIGH)
        seq_item_port.item_done();
      end
    endtask

    task send_aw(axil_item t);
      vif.mst_cb.awaddr <= t.addr; vif.mst_cb.awprot <= t.prot; vif.mst_cb.awvalid <= 1'b1;
      do @(vif.mst_cb); while (vif.mst_cb.awready !== 1'b1);
      vif.mst_cb.awvalid <= 1'b0;
    endtask

    task send_w(axil_item t);
      vif.mst_cb.wdata <= t.data; vif.mst_cb.wstrb <= t.strb; vif.mst_cb.wvalid <= 1'b1;
      do @(vif.mst_cb); while (vif.mst_cb.wready !== 1'b1);
      vif.mst_cb.wvalid <= 1'b0;
    endtask

    task drive_write(axil_item t);
      case (t.order)
        AXIL_AW_FIRST: fork send_aw(t); begin repeat (t.skew) @(vif.mst_cb); send_w(t); end join
        AXIL_W_FIRST:  fork send_w(t);  begin repeat (t.skew) @(vif.mst_cb); send_aw(t); end join
        default:       fork send_aw(t); send_w(t); join
      endcase
      repeat (t.resp_delay) @(vif.mst_cb);
      vif.mst_cb.bready <= 1'b1;
      do @(vif.mst_cb); while (vif.mst_cb.bvalid !== 1'b1);
      vif.mst_cb.bready <= 1'b0;
      t.resp = axil_resp_e'(vif.mst_cb.bresp);
    endtask

    task drive_read(axil_item t);
      vif.mst_cb.araddr <= t.addr; vif.mst_cb.arprot <= t.prot; vif.mst_cb.arvalid <= 1'b1;
      do @(vif.mst_cb); while (vif.mst_cb.arready !== 1'b1);
      vif.mst_cb.arvalid <= 1'b0;
      repeat (t.resp_delay) @(vif.mst_cb);
      vif.mst_cb.rready <= 1'b1;
      do @(vif.mst_cb); while (vif.mst_cb.rvalid !== 1'b1);
      vif.mst_cb.rready <= 1'b0;
      t.data = vif.mst_cb.rdata;
      t.resp = axil_resp_e'(vif.mst_cb.rresp);
    endtask
  endclass

  // ---------------------------------------------------------------- slave driver
  // Reactive: accepts AW and W independently (either may come first), writes
  // memory when it has both, then answers B; reads answer R. Erroring
  // addresses do not touch memory and read back 0.
  class axil_slave_driver extends uvm_component;
    `uvm_component_utils(axil_slave_driver)
    virtual axil_if vif;
    axil_cfg        cfg;
    mailbox #(bit [34:0]) aw_mb;          // {prot, addr}
    mailbox #(bit [35:0]) w_mb;           // {strb, data}
    mailbox #(bit [31:0]) ar_mb;
    int unsigned n_writes, n_reads;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": axil_if not set"})
      if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", {get_full_name(), ": axil_cfg not set"})
      aw_mb = new(); w_mb = new(); ar_mb = new();
    endfunction

    task run_phase(uvm_phase phase);
      vif.slv_cb.awready <= 1'b0; vif.slv_cb.wready <= 1'b0; vif.slv_cb.bvalid <= 1'b0;
      vif.slv_cb.arready <= 1'b0; vif.slv_cb.rvalid <= 1'b0;
      vif.slv_cb.bresp <= '0; vif.slv_cb.rresp <= '0; vif.slv_cb.rdata <= '0;
      @(posedge vif.aclk iff vif.aresetn === 1'b1);
      fork
        forever begin   // AW
          repeat (axil_cfg::rand_delay(cfg.max_aready_delay)) @(vif.slv_cb);
          vif.slv_cb.awready <= 1'b1;
          do @(vif.slv_cb); while (!(vif.slv_cb.awvalid === 1'b1 && vif.awready === 1'b1));
          vif.slv_cb.awready <= 1'b0;
          aw_mb.put({vif.slv_cb.awprot, vif.slv_cb.awaddr});
        end
        forever begin   // W
          repeat (axil_cfg::rand_delay(cfg.max_wready_delay)) @(vif.slv_cb);
          vif.slv_cb.wready <= 1'b1;
          do @(vif.slv_cb); while (!(vif.slv_cb.wvalid === 1'b1 && vif.wready === 1'b1));
          vif.slv_cb.wready <= 1'b0;
          w_mb.put({vif.slv_cb.wstrb, vif.slv_cb.wdata});
        end
        forever begin   // B
          bit [34:0] aw;
          bit [35:0] w;
          axil_resp_e rsp;
          aw_mb.get(aw);
          w_mb.get(w);
          rsp = cfg.resp_for(aw[31:0]);
          if (rsp == AXIL_OKAY) cfg.mem.write_bus(aw[31:0], 64'(w[31:0]), 8'(w[35:32]), 4);
          @(vif.slv_cb);
          repeat (axil_cfg::rand_delay(cfg.max_resp_delay)) @(vif.slv_cb);
          vif.slv_cb.bresp <= rsp; vif.slv_cb.bvalid <= 1'b1;
          do @(vif.slv_cb); while (!(vif.slv_cb.bready === 1'b1 && vif.bvalid === 1'b1));
          vif.slv_cb.bvalid <= 1'b0;
          n_writes++;
        end
        forever begin   // AR
          repeat (axil_cfg::rand_delay(cfg.max_aready_delay)) @(vif.slv_cb);
          vif.slv_cb.arready <= 1'b1;
          do @(vif.slv_cb); while (!(vif.slv_cb.arvalid === 1'b1 && vif.arready === 1'b1));
          vif.slv_cb.arready <= 1'b0;
          ar_mb.put(vif.slv_cb.araddr);
        end
        forever begin   // R
          bit [31:0] a;
          axil_resp_e rsp;
          ar_mb.get(a);
          rsp = cfg.resp_for(a);
          @(vif.slv_cb);
          repeat (axil_cfg::rand_delay(cfg.max_resp_delay)) @(vif.slv_cb);
          vif.slv_cb.rdata <= (rsp == AXIL_OKAY) ? 32'(cfg.mem.read_bus(a, 4)) : 32'h0;
          vif.slv_cb.rresp <= rsp; vif.slv_cb.rvalid <= 1'b1;
          do @(vif.slv_cb); while (!(vif.slv_cb.rready === 1'b1 && vif.rvalid === 1'b1));
          vif.slv_cb.rvalid <= 1'b0;
          n_reads++;
        end
      join
    endtask

    function void report_phase(uvm_phase phase);
      `uvm_info("AXIL_SDRV", $sformatf("%s: served %0d writes, %0d reads", get_full_name(),
                n_writes, n_reads), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- monitor
  class axil_monitor extends uvm_monitor;
    `uvm_component_utils(axil_monitor)
    virtual axil_if vif;
    uvm_analysis_port #(axil_item) ap;
    protected axil_item aw_q[$], wr_q[$], rd_q[$];
    protected bit [35:0] w_q[$];
    protected axil_item  w_pending_aw[$];
    int unsigned n_wr, n_rd;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", {get_full_name(), ": axil_if not set"})
    endfunction

    protected function void pair();
      while (aw_q.size() && w_q.size()) begin
        axil_item t = aw_q.pop_front();
        bit [35:0] w = w_q.pop_front();
        t.data = w[31:0]; t.strb = w[35:32];
        wr_q.push_back(t);
      end
    endfunction

    task run_phase(uvm_phase phase);
      int unsigned cyc = 0;
      forever begin
        @(vif.mon_cb);
        cyc++;
        if (vif.aresetn !== 1'b1) begin
          aw_q.delete(); wr_q.delete(); rd_q.delete(); w_q.delete();
          continue;
        end
        if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
          axil_item t = axil_item::type_id::create("mon_wr");
          t.write = 1; t.addr = vif.mon_cb.awaddr; t.prot = vif.mon_cb.awprot;
          t.t_start = $time; t.latency = cyc;
          aw_q.push_back(t);
        end
        if (vif.mon_cb.wvalid && vif.mon_cb.wready) w_q.push_back({vif.mon_cb.wstrb, vif.mon_cb.wdata});
        pair();
        if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
          if (wr_q.size() == 0)
            `uvm_error("AXIL_MON", {get_full_name(), ": B handshake without a complete write"})
          else begin
            axil_item t = wr_q.pop_front();
            t.resp = axil_resp_e'(vif.mon_cb.bresp);
            t.t_end = $time; t.latency = cyc - t.latency;
            n_wr++;
            `uvm_info("AXIL_MON", {get_full_name(), ": ", t.convert2string()}, UVM_HIGH)
            ap.write(t);
          end
        end
        if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
          axil_item t = axil_item::type_id::create("mon_rd");
          t.write = 0; t.addr = vif.mon_cb.araddr; t.prot = vif.mon_cb.arprot; t.strb = 0;
          t.t_start = $time; t.latency = cyc;
          rd_q.push_back(t);
        end
        if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
          if (rd_q.size() == 0)
            `uvm_error("AXIL_MON", {get_full_name(), ": R handshake without an outstanding read"})
          else begin
            axil_item t = rd_q.pop_front();
            t.data = vif.mon_cb.rdata; t.resp = axil_resp_e'(vif.mon_cb.rresp);
            t.t_end = $time; t.latency = cyc - t.latency;
            n_rd++;
            `uvm_info("AXIL_MON", {get_full_name(), ": ", t.convert2string()}, UVM_HIGH)
            ap.write(t);
          end
        end
      end
    endtask

    function void check_phase(uvm_phase phase);
      if (aw_q.size() || wr_q.size() || rd_q.size() || w_q.size())
        `uvm_error("AXIL_MON", $sformatf("%s: unfinished accesses at end of test (aw=%0d w=%0d b=%0d r=%0d)",
                   get_full_name(), aw_q.size(), w_q.size(), wr_q.size(), rd_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("AXIL_MON", $sformatf("%s: %0d writes, %0d reads", get_full_name(), n_wr, n_rd), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- coverage
  class axil_coverage extends uvm_subscriber #(axil_item);
    `uvm_component_utils(axil_coverage)
    bit          cv_write;
    axil_resp_e  cv_resp;
    bit [3:0]    cv_strb;
    bit [2:0]    cv_prot;
    int unsigned cv_lat;
    int unsigned n_sampled;
    covergroup cg;
      option.per_instance = 1;
      cp_dir:  coverpoint cv_write { bins rd = {0}; bins wr = {1}; }
      cp_resp: coverpoint cv_resp  { bins okay = {AXIL_OKAY}; bins slverr = {AXIL_SLVERR}; bins decerr = {AXIL_DECERR}; }
      cp_strb: coverpoint cv_strb iff (cv_write) { bins full = {4'hF}; bins none = {0};
                                                   bins byte_lane[] = {1, 2, 4, 8}; bins half[] = {3, 12};
                                                   bins other = default; }
      cp_prot: coverpoint cv_prot  { bins prot[] = {[0:7]}; }
      cp_lat:  coverpoint cv_lat   { bins fast = {[0:2]}; bins mid = {[3:5]}; bins slow = {[6:$]}; }
      x_dir_resp: cross cp_dir, cp_resp;
      x_dir_lat:  cross cp_dir, cp_lat;
    endgroup
    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction
    function void write(axil_item t);
      cv_write = t.write; cv_resp = t.resp; cv_strb = t.strb; cv_prot = t.prot; cv_lat = t.latency;
      n_sampled++;
      cg.sample();
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("AXIL_COV", $sformatf("%s: %0d accesses sampled, coverage %0.1f%%", get_full_name(),
                n_sampled, cg.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- agent
  typedef uvm_sequencer #(axil_item) axil_sequencer;

  class axil_agent extends uvm_agent;
    `uvm_component_utils(axil_agent)
    axil_cfg           cfg;
    axil_sequencer     sqr;
    axil_master_driver mdrv;
    axil_slave_driver  sdrv;
    axil_monitor       mon;
    axil_coverage      cov;
    uvm_analysis_port #(axil_item) ap;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("NOCFG", {get_full_name(), ": axil_cfg not set"})
      uvm_config_db#(axil_cfg)::set(this, "*", "cfg", cfg);
      mon = axil_monitor::type_id::create("mon", this);
      if (cfg.has_coverage) cov = axil_coverage::type_id::create("cov", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        if (cfg.role == AXIL_MASTER) begin
          sqr  = axil_sequencer::type_id::create("sqr", this);
          mdrv = axil_master_driver::type_id::create("drv", this);
        end else begin
          if (cfg.mem == null) cfg.mem = mem_vip_pkg::mem_model::type_id::create({get_name(), "_mem"});
          sdrv = axil_slave_driver::type_id::create("drv", this);
        end
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      ap = mon.ap;
      if (cov != null) mon.ap.connect(cov.analysis_export);
      if (mdrv != null) mdrv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ---------------------------------------------------------------- scoreboard
  // Predicts each read from the writes the monitor saw before it (byte
  // shadow memory; unwritten bytes come from mem_model::init_byte) and the
  // response from an optional slave config's error map.
  class axil_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(axil_scoreboard)
    uvm_analysis_imp #(axil_item, axil_scoreboard) analysis_export;
    axil_cfg  slv_cfg;                       // error map (optional)
    mem_vip_pkg::mem_init_e init_kind = mem_vip_pkg::MEM_INIT_PATTERN;
    byte unsigned shadow[bit [31:0]];
    int unsigned n_checks, n_errors, n_wr, n_rd;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      analysis_export = new("analysis_export", this);
    endfunction
    function byte unsigned expect_byte(bit [31:0] a);
      return shadow.exists(a) ? shadow[a] : mem_vip_pkg::mem_model::init_byte(init_kind, a);
    endfunction
    function void chk(bit ok, string what);
      n_checks++;
      if (!ok) begin n_errors++; `uvm_error("AXIL_SB", what) end
    endfunction
    virtual function void write(axil_item t);
      bit [31:0] base = t.addr & ~32'h3;
      axil_resp_e exp = (slv_cfg != null) ? slv_cfg.resp_for(t.addr) : AXIL_OKAY;
      chk(t.resp == exp, $sformatf("%s: response, expected %s", t.convert2string(), exp.name()));
      if (exp != AXIL_OKAY) return;
      if (t.write) begin
        n_wr++;
        for (int b = 0; b < 4; b++) if (t.strb[b]) shadow[base + b] = t.data[8*b +: 8];
      end else begin
        n_rd++;
        for (int b = 0; b < 4; b++)
          chk(t.data[8*b +: 8] == expect_byte(base + b),
                $sformatf("%s: byte %0d, expected %02h", t.convert2string(), b, expect_byte(base + b)));
      end
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("AXIL_SB", $sformatf("%s: %0d writes, %0d reads, %0d checks, %0d errors", get_full_name(),
                n_wr, n_rd, n_checks, n_errors), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- sequences
  class axil_single_seq extends uvm_sequence #(axil_item);
    `uvm_object_utils(axil_single_seq)
    axil_item item;
    function new(string name = "axil_single_seq");
      super.new(name);
    endfunction
    task body();
      start_item(item);
      finish_item(item);
    endtask
  endclass

  class axil_api;
    static task write(axil_sequencer sqr, bit [31:0] addr, bit [31:0] data, output axil_resp_e resp,
                      input bit [3:0] strb = 4'hF);
      axil_single_seq s = axil_single_seq::type_id::create("s");
      s.item = axil_item::type_id::create("w");
      s.item.write = 1; s.item.addr = addr; s.item.data = data; s.item.strb = strb;
      s.start(sqr);
      resp = s.item.resp;
    endtask
    static task read(axil_sequencer sqr, bit [31:0] addr, output bit [31:0] data, output axil_resp_e resp);
      axil_single_seq s = axil_single_seq::type_id::create("s");
      s.item = axil_item::type_id::create("r");
      s.item.write = 0; s.item.addr = addr; s.item.strb = 0;
      s.start(sqr);
      data = s.item.data;
      resp = s.item.resp;
    endtask
  endclass

  // random word accesses in [lo, hi], random AW/W order, skew and strobes
  class axil_random_seq extends uvm_sequence #(axil_item);
    `uvm_object_utils(axil_random_seq)
    int unsigned n_items = 50;
    bit [31:0]   lo = 0, hi = 32'hFFF;
    int unsigned max_delay = 3;
    function new(string name = "axil_random_seq");
      super.new(name);
    endfunction
    task body();
      repeat (n_items) begin
        axil_item t = axil_item::type_id::create("t");
        t.write = $urandom_range(1, 0);
        t.addr  = (lo + $urandom_range(hi - lo, 0)) & ~32'h3;
        t.data  = $urandom();
        t.prot  = $urandom_range(7, 0);
        t.strb  = t.write ? (($urandom_range(2, 0) == 0) ? 4'($urandom()) : 4'hF) : 4'h0;
        t.order = axil_order_e'($urandom_range(2, 0));
        t.skew  = $urandom_range(max_delay, 0);
        t.resp_delay = $urandom_range(max_delay, 0);
        start_item(t);
        finish_item(t);
      end
    endtask
  endclass
endpackage
`endif
