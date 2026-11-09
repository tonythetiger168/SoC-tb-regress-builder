// SPDX-License-Identifier: Apache-2.0
// axi4_slave_driver -- reactive memory responder (no sequencer needed).
// Stores write data in cfg.mem (mem_vip_pkg::mem_model) and returns read data
// from it. Supports FIXED/INCR/WRAP, narrow transfers and byte strobes,
// several outstanding bursts per direction (answered in order), random
// READY/VALID timing (cfg.max_*), and error responses on address ranges
// (cfg.err_ranges; an erroring burst does not touch memory).
class axi4_slave_driver extends uvm_component;
  `uvm_component_utils(axi4_slave_driver)

  virtual axi4_if vif;
  axi4_cfg        cfg;

  mailbox #(axi4_item) aw_mb, b_mb, ar_mb;
  int unsigned n_writes, n_reads;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", {get_full_name(), ": axi4_if not set"})
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", {get_full_name(), ": axi4_cfg not set"})
    aw_mb = new(); b_mb = new(); ar_mb = new();
  endfunction

  task run_phase(uvm_phase phase);
    vif.slv_cb.awready <= 1'b0; vif.slv_cb.wready <= 1'b0; vif.slv_cb.bvalid <= 1'b0; vif.slv_cb.arready <= 1'b0;
    vif.rvalid  <= 1'b0; vif.rlast  <= 1'b0; vif.slv_cb.bid <= '0; vif.slv_cb.bresp <= '0;
    vif.slv_cb.rid <= '0; vif.slv_cb.rdata <= '0; vif.slv_cb.rresp <= '0;
    @(posedge vif.aclk iff vif.aresetn === 1'b1);
    fork
      aw_thread();
      w_thread();
      b_thread();
      ar_thread();
      r_thread();
    join
  endtask

  function axi4_item capture_aw();
    axi4_item t = axi4_item::type_id::create("aw");
    t.write = 1; t.id = vif.slv_cb.awid; t.addr = vif.slv_cb.awaddr; t.len = vif.slv_cb.awlen;
    t.size = vif.slv_cb.awsize; t.burst = axi4_burst_e'(vif.slv_cb.awburst);
    t.prot = vif.slv_cb.awprot; t.cache = vif.slv_cb.awcache;
    t.alloc();
    return t;
  endfunction

  task aw_thread();
    forever begin
      repeat (axi4_cfg::rand_delay(cfg.max_aready_delay)) @(vif.slv_cb);
      vif.slv_cb.awready <= 1'b1;
      do @(vif.slv_cb); while (!(vif.slv_cb.awvalid === 1'b1 && vif.awready === 1'b1));
      vif.slv_cb.awready <= 1'b0;
      aw_mb.put(capture_aw());
    end
  endtask

  task w_thread();
    axi4_item t;
    forever begin
      aw_mb.get(t);
      t.resp[0] = cfg.resp_for(t.addr);
      for (int unsigned i = 0; i < t.beats(); i++) begin
        int unsigned d = axi4_cfg::rand_delay(cfg.max_wready_delay);
        if (d) begin
          vif.slv_cb.wready <= 1'b0;
          repeat (d) @(vif.slv_cb);
        end
        vif.slv_cb.wready <= 1'b1;
        do @(vif.slv_cb); while (!(vif.slv_cb.wvalid === 1'b1 && vif.wready === 1'b1));
        t.data[i] = vif.slv_cb.wdata;
        t.strb[i] = vif.slv_cb.wstrb;
        if (vif.slv_cb.wlast !== (i == t.len))
          `uvm_error("AXI4_SDRV", $sformatf("WLAST=%0b on beat %0d of %0d (addr %08h)",
                     vif.slv_cb.wlast, i, t.beats(), t.addr))
        if ((t.strb[i] & ~t.lanes(i)) != 0)
          `uvm_error("AXI4_SDRV", $sformatf("WSTRB %04b outside the lanes %04b of beat %0d (addr %08h size %0d)",
                     t.strb[i], t.lanes(i), i, t.beat_addr(i), t.size))
        if (t.resp[0] == AXI4_OKAY)
          cfg.mem.write_bus(t.beat_addr(i), 64'(t.data[i]), 8'(t.strb[i]), 4);
      end
      vif.slv_cb.wready <= 1'b0;
      n_writes++;
      b_mb.put(t);
    end
  endtask

  task b_thread();
    axi4_item t;
    forever begin
      b_mb.get(t);
      repeat (axi4_cfg::rand_delay(cfg.max_b_latency)) @(vif.slv_cb);
      vif.slv_cb.bid    <= t.id;
      vif.slv_cb.bresp  <= t.resp[0];
      vif.slv_cb.bvalid <= 1'b1;
      do @(vif.slv_cb); while (!(vif.slv_cb.bready === 1'b1 && vif.bvalid === 1'b1));
      vif.slv_cb.bvalid <= 1'b0;
    end
  endtask

  task ar_thread();
    forever begin
      axi4_item t;
      repeat (axi4_cfg::rand_delay(cfg.max_aready_delay)) @(vif.slv_cb);
      vif.slv_cb.arready <= 1'b1;
      do @(vif.slv_cb); while (!(vif.slv_cb.arvalid === 1'b1 && vif.arready === 1'b1));
      vif.slv_cb.arready <= 1'b0;
      t = axi4_item::type_id::create("ar");
      t.write = 0; t.id = vif.slv_cb.arid; t.addr = vif.slv_cb.araddr; t.len = vif.slv_cb.arlen;
      t.size = vif.slv_cb.arsize; t.burst = axi4_burst_e'(vif.slv_cb.arburst);
      t.prot = vif.slv_cb.arprot; t.cache = vif.slv_cb.arcache;
      t.alloc();
      ar_mb.put(t);
    end
  endtask

  task r_thread();
    axi4_item t;
    forever begin
      axi4_resp_e rsp;
      ar_mb.get(t);
      rsp = cfg.resp_for(t.addr);
      repeat (axi4_cfg::rand_delay(cfg.max_r_latency)) @(vif.slv_cb);
      for (int unsigned i = 0; i < t.beats(); i++) begin
        int unsigned g = (i == 0) ? 0 : axi4_cfg::rand_delay(cfg.max_rvalid_gap);
        if (g) begin
          vif.slv_cb.rvalid <= 1'b0;
          repeat (g) @(vif.slv_cb);
        end
        vif.slv_cb.rid    <= t.id;
        vif.slv_cb.rdata  <= (rsp == AXI4_OKAY) ? 32'(cfg.mem.read_bus(t.beat_addr(i), 4)) : 32'h0;
        vif.slv_cb.rresp  <= rsp;
        vif.slv_cb.rlast  <= (i == t.len);
        vif.slv_cb.rvalid <= 1'b1;
        do @(vif.slv_cb); while (!(vif.slv_cb.rready === 1'b1 && vif.rvalid === 1'b1));
      end
      vif.slv_cb.rvalid <= 1'b0;
      vif.slv_cb.rlast  <= 1'b0;
      n_reads++;
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("AXI4_SDRV", $sformatf("%s: served %0d writes, %0d reads; %s", get_full_name(),
              n_writes, n_reads, cfg.mem.convert2string()), UVM_LOW)
  endfunction
endclass
