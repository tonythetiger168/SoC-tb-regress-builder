// SPDX-License-Identifier: Apache-2.0
// axi4_master_driver -- drives one burst at a time. AW and W are issued
// concurrently (W may lead AW), then the response is collected. The response
// (read data, RRESP/BRESP) is written back into the request item before
// item_done, so a sequence reads it from its own handle.
class axi4_master_driver extends uvm_driver #(axi4_item);
  `uvm_component_utils(axi4_master_driver)

  virtual axi4_if vif;
  axi4_cfg        cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", {get_full_name(), ": axi4_if not set"})
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", {get_full_name(), ": axi4_cfg not set"})
  endfunction

  task reset_outputs();
    vif.mst_cb.awvalid <= 1'b0; vif.mst_cb.wvalid <= 1'b0; vif.mst_cb.arvalid <= 1'b0;
    vif.bready  <= 1'b0; vif.mst_cb.rready <= 1'b0; vif.wlast  <= 1'b0;
    vif.mst_cb.awid <= '0; vif.mst_cb.awaddr <= '0; vif.mst_cb.awlen <= '0; vif.mst_cb.awsize <= '0; vif.mst_cb.awburst <= '0;
    vif.mst_cb.awlock <= 1'b0; vif.mst_cb.awcache <= '0; vif.mst_cb.awprot <= '0;
    vif.mst_cb.wdata <= '0; vif.mst_cb.wstrb <= '0;
    vif.mst_cb.arid <= '0; vif.mst_cb.araddr <= '0; vif.mst_cb.arlen <= '0; vif.mst_cb.arsize <= '0; vif.mst_cb.arburst <= '0;
    vif.mst_cb.arlock <= 1'b0; vif.mst_cb.arcache <= '0; vif.mst_cb.arprot <= '0;
  endtask

  task run_phase(uvm_phase phase);
    reset_outputs();
    @(posedge vif.aclk iff vif.aresetn === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      if (req.data.size() != req.beats() || req.strb.size() != req.beats()) begin
        bit [31:0] d[] = req.data;
        bit [3:0]  s[] = req.strb;
        req.data = new[req.beats()](d);
        req.strb = new[req.beats()](s);
      end
      req.t_start = $time;
      if (req.write) drive_write(req);
      else           drive_read(req);
      req.t_end = $time;
      `uvm_info("AXI4_MDRV", {"done: ", req.convert2string()}, UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask

  task drive_write(axi4_item t);
    fork
      begin : aw_ch
        repeat (t.aw_delay) @(vif.mst_cb);
        @(vif.mst_cb);
        vif.mst_cb.awid    <= t.id;
        vif.mst_cb.awaddr  <= t.addr;
        vif.mst_cb.awlen   <= t.len;
        vif.mst_cb.awsize  <= t.size;
        vif.mst_cb.awburst <= t.burst;
        vif.mst_cb.awprot  <= t.prot;
        vif.mst_cb.awcache <= t.cache;
        vif.mst_cb.awvalid <= 1'b1;
        do @(vif.mst_cb); while (!(vif.mst_cb.awready === 1'b1 && vif.awvalid === 1'b1));
        vif.mst_cb.awvalid <= 1'b0;
      end
      begin : w_ch
        @(vif.mst_cb);
        for (int unsigned i = 0; i < t.beats(); i++) begin
          int unsigned gap = (i == 0) ? 0 : axi4_cfg::rand_delay(t.w_gap);
          if (gap) begin
            vif.mst_cb.wvalid <= 1'b0;
            repeat (gap) @(vif.mst_cb);
          end
          vif.mst_cb.wdata  <= t.data[i];
          vif.mst_cb.wstrb  <= t.strb[i];
          vif.mst_cb.wlast  <= (i == t.len);
          vif.mst_cb.wvalid <= 1'b1;
          do @(vif.mst_cb); while (!(vif.mst_cb.wready === 1'b1 && vif.wvalid === 1'b1));
        end
        vif.mst_cb.wvalid <= 1'b0;
        vif.mst_cb.wlast  <= 1'b0;
      end
    join
    if (cfg.ready_after_valid) do @(vif.mst_cb); while (vif.mst_cb.bvalid !== 1'b1);
    repeat (axi4_cfg::rand_delay(cfg.max_b_delay)) @(vif.mst_cb);
    vif.mst_cb.bready <= 1'b1;
    do @(vif.mst_cb); while (!(vif.mst_cb.bvalid === 1'b1 && vif.bready === 1'b1));
    vif.mst_cb.bready <= 1'b0;
    t.resp = new[1];
    t.resp[0] = axi4_resp_e'(vif.mst_cb.bresp);
    if (vif.mst_cb.bid !== t.id)
      `uvm_error("AXI4_MDRV", $sformatf("BID %0h does not match AWID %0h", vif.mst_cb.bid, t.id))
  endtask

  task drive_read(axi4_item t);
    repeat (t.aw_delay) @(vif.mst_cb);
    @(vif.mst_cb);
    vif.mst_cb.arid    <= t.id;
    vif.mst_cb.araddr  <= t.addr;
    vif.mst_cb.arlen   <= t.len;
    vif.mst_cb.arsize  <= t.size;
    vif.mst_cb.arburst <= t.burst;
    vif.mst_cb.arprot  <= t.prot;
    vif.mst_cb.arcache <= t.cache;
    vif.mst_cb.arvalid <= 1'b1;
    do @(vif.mst_cb); while (!(vif.mst_cb.arready === 1'b1 && vif.arvalid === 1'b1));
    vif.mst_cb.arvalid <= 1'b0;
    t.resp = new[t.beats()];
    for (int unsigned i = 0; i < t.beats(); i++) begin
      int unsigned gap = axi4_cfg::rand_delay(cfg.max_r_gap > t.r_gap ? cfg.max_r_gap : t.r_gap);
      if (cfg.ready_after_valid) begin
        vif.mst_cb.rready <= 1'b0;
        do @(vif.mst_cb); while (vif.mst_cb.rvalid !== 1'b1);
      end
      if (gap) begin
        vif.mst_cb.rready <= 1'b0;
        repeat (gap) @(vif.mst_cb);
      end
      vif.mst_cb.rready <= 1'b1;
      do @(vif.mst_cb); while (!(vif.mst_cb.rvalid === 1'b1 && vif.rready === 1'b1));
      t.data[i] = vif.mst_cb.rdata;
      t.strb[i] = t.lanes(i);
      t.resp[i] = axi4_resp_e'(vif.mst_cb.rresp);
      if (vif.mst_cb.rid !== t.id)
        `uvm_error("AXI4_MDRV", $sformatf("RID %0h does not match ARID %0h", vif.mst_cb.rid, t.id))
      if (vif.mst_cb.rlast !== (i == t.len))
        `uvm_error("AXI4_MDRV", $sformatf("RLAST=%0b on beat %0d of %0d", vif.mst_cb.rlast, i, t.beats()))
    end
    vif.mst_cb.rready <= 1'b0;
  endtask
endclass
