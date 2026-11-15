// SPDX-License-Identifier: Apache-2.0
// axi4_master_driver -- drives one burst at a time. AW and W are issued
// concurrently (W may lead AW), then the response is collected. The response
// (read data, RRESP/BRESP) is written back into the request item before
// item_done, so a sequence reads it from its own handle.
// While cfg.max_outstanding > 1 (checked per burst, so a test can switch it)
// the driver only serialises the address (and write data) phase: B and R are
// collected in the background, matched to the oldest outstanding burst with
// that ID, and item.done is set when the response is complete (axi4_single_seq
// waits for it). Run several sequences on the sequencer at once to have
// several bursts in flight. Code that reads the response right after
// finish_item (a RAL adapter) needs max_outstanding = 1.
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
    fork r_collect(); b_collect(); w_send(); join_none
    forever begin
      seq_item_port.get_next_item(req);
      if (cfg.max_outstanding > 1) begin
        issue_pipelined(req);
        seq_item_port.item_done();
        continue;
      end
      wait (rd_q.size() == 0 && wr_q.size() == 0);   // earlier pipelined bursts finish first
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
      req.done = 1;
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
  // ---------------- several bursts in flight (cfg.max_outstanding > 1) ----------------
  axi4_item rd_q[$], wr_q[$];            // outstanding, in issue order
  int unsigned rd_beat[$];               // beats received per rd_q entry

  task issue_pipelined(axi4_item t);
    if (t.data.size() != t.beats() || t.strb.size() != t.beats()) begin
      bit [31:0] d[] = t.data;
      bit [3:0]  s[] = t.strb;
      t.data = new[t.beats()](d);
      t.strb = new[t.beats()](s);
    end
    wait (rd_q.size() + wr_q.size() < cfg.max_outstanding);
    t.t_start = $time;
    if (t.write) begin
      // AW goes ahead; the W beats follow in AW order from w_send(), so the
      // next AW can be accepted while earlier W data is still going out
      issue_aw(t);
      wr_q.push_back(t);
      w_mb.put(t);
    end else begin
      t.resp = new[t.beats()];
      rd_q.push_back(t);                 // queued before AR, so an early R finds it
      rd_beat.push_back(0);
      issue_ar(t);
    end
  endtask

  task issue_ar(axi4_item t);
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
  endtask

  // AW of one pipelined burst (its W beats go out from w_send)
  task issue_aw(axi4_item t);
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
  endtask

  task issue_w(axi4_item t);
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
  endtask

  function void finish(axi4_item t);
    t.t_end = $time;
    t.done = 1;
    `uvm_info("AXI4_MDRV", {"done: ", t.convert2string()}, UVM_HIGH)
  endfunction

  // W beats of the pipelined writes, in AW order
  mailbox #(axi4_item) w_mb = new();
  task w_send();
    axi4_item t;
    forever begin
      w_mb.get(t);
      issue_w(t);
    end
  endtask

  task b_collect();
    forever begin
      int k;
      axi4_item t;
      wait (wr_q.size() != 0);
      do @(vif.mst_cb); while (vif.mst_cb.bvalid !== 1'b1);
      repeat (axi4_cfg::rand_delay(cfg.max_b_delay)) @(vif.mst_cb);
      vif.mst_cb.bready <= 1'b1;
      do @(vif.mst_cb); while (!(vif.mst_cb.bvalid === 1'b1 && vif.bready === 1'b1));
      vif.mst_cb.bready <= 1'b0;
      k = -1;
      foreach (wr_q[i]) if (k < 0 && wr_q[i].id == vif.mst_cb.bid) k = i;
      if (k < 0) begin
        `uvm_error("AXI4_MDRV", $sformatf("B with ID %0h and no outstanding write", vif.mst_cb.bid))
        continue;
      end
      t = wr_q[k];
      wr_q.delete(k);
      t.resp = new[1];
      t.resp[0] = axi4_resp_e'(vif.mst_cb.bresp);
      finish(t);
    end
  endtask

  task r_collect();
    forever begin
      int k;
      axi4_item t;
      int unsigned gap = axi4_cfg::rand_delay(cfg.max_r_gap);
      wait (rd_q.size() != 0);
      do @(vif.mst_cb); while (vif.mst_cb.rvalid !== 1'b1);
      repeat (gap) @(vif.mst_cb);
      vif.mst_cb.rready <= 1'b1;
      do @(vif.mst_cb); while (!(vif.mst_cb.rvalid === 1'b1 && vif.rready === 1'b1));
      vif.mst_cb.rready <= 1'b0;
      k = -1;
      foreach (rd_q[i]) if (k < 0 && rd_q[i].id == vif.mst_cb.rid) k = i;
      if (k < 0) begin
        `uvm_error("AXI4_MDRV", $sformatf("R with ID %0h and no outstanding read", vif.mst_cb.rid))
        continue;
      end
      t = rd_q[k];
      t.data[rd_beat[k]] = vif.mst_cb.rdata;
      t.strb[rd_beat[k]] = t.lanes(rd_beat[k]);
      t.resp[rd_beat[k]] = axi4_resp_e'(vif.mst_cb.rresp);
      if (vif.mst_cb.rlast !== (rd_beat[k] == t.len))
        `uvm_error("AXI4_MDRV", $sformatf("RLAST=%0b on beat %0d of %0d", vif.mst_cb.rlast, rd_beat[k], t.beats()))
      if (rd_beat[k] == t.len) begin
        rd_q.delete(k);
        rd_beat.delete(k);
        finish(t);
      end else rd_beat[k]++;
    end
  endtask
endclass
