// SPDX-License-Identifier: Apache-2.0
// axi4_monitor -- passive: rebuilds complete bursts from the five channels and
// publishes each one on `ap` when it completes (B handshake / RLAST beat).
// Handles W data ahead of AW, several outstanding bursts and out-of-order
// responses across IDs (in order within an ID).
class axi4_monitor extends uvm_monitor;
  `uvm_component_utils(axi4_monitor)

  virtual axi4_if vif;
  axi4_cfg        cfg;
  uvm_analysis_port #(axi4_item) ap;

  protected axi4_item aw_q[$];        // AW seen, W burst not complete
  protected axi4_item b_wait_q[$];    // AW + all W beats seen, waiting for B
  protected axi4_item r_wait_q[$];    // AR seen, waiting for (more) R beats
  protected int unsigned r_beat[$];
  protected bit [31:0] w_data[$];     // beats of the W burst in progress
  protected bit [3:0]  w_strb[$];
  protected bit [31:0] w_early_data[$][$];   // complete W bursts not yet paired with an AW
  protected bit [3:0]  w_early_strb[$][$];

  int unsigned n_wr, n_rd;
  protected time aw_since, ar_since;  // VALID first seen, waiting for READY (0 = none)
  protected bit  aw_wait, ar_wait;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", {get_full_name(), ": axi4_if not set"})
    if (!uvm_config_db#(axi4_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", {get_full_name(), ": axi4_cfg not set"})
  endfunction

  protected function void flush();
    aw_q.delete(); b_wait_q.delete(); r_wait_q.delete(); r_beat.delete();
    w_data.delete(); w_strb.delete();
    w_early_data.delete(); w_early_strb.delete();
  endfunction

  // pair complete W bursts with their AW (W bursts arrive in AW order)
  protected function void pair_writes();
    while (aw_q.size() && w_early_data.size()) begin
      axi4_item t = aw_q.pop_front();
      bit [31:0] d[$] = w_early_data.pop_front();
      bit [3:0]  s[$] = w_early_strb.pop_front();
      if (d.size() != t.beats())
        `uvm_error("AXI4_MON", $sformatf("%s: W burst has %0d beats, AWLEN says %0d (addr %08h)",
                   get_full_name(), d.size(), t.beats(), t.addr))
      foreach (d[i]) if (i < t.beats()) begin
        t.data[i] = d[i];
        t.strb[i] = s[i];
      end
      b_wait_q.push_back(t);
    end
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.aresetn !== 1'b1) begin
        flush();
        aw_wait = 0; ar_wait = 0;
        continue;
      end
      // ---- request-issue times (path latency starts at VALID) ----
      if (vif.mon_cb.awvalid && !aw_wait) begin aw_wait = 1; aw_since = $time; end
      if (vif.mon_cb.arvalid && !ar_wait) begin ar_wait = 1; ar_since = $time; end
      // ---- AW ----
      if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
        axi4_item t = axi4_item::type_id::create("mon_wr");
        t.write = 1; t.id = vif.mon_cb.awid; t.addr = vif.mon_cb.awaddr;
        t.len = vif.mon_cb.awlen; t.size = vif.mon_cb.awsize;
        t.burst = axi4_burst_e'(vif.mon_cb.awburst); t.prot = vif.mon_cb.awprot;
        t.cache = vif.mon_cb.awcache; t.port = cfg.port; t.t_start = $time;
        t.t_req = aw_since; aw_wait = 0;
        t.alloc();
        aw_q.push_back(t);
      end
      // ---- W ----
      if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
        w_data.push_back(vif.mon_cb.wdata);
        w_strb.push_back(vif.mon_cb.wstrb);
        if (vif.mon_cb.wlast) begin
          w_early_data.push_back(w_data);
          w_early_strb.push_back(w_strb);
          w_data.delete();
          w_strb.delete();
        end
      end
      pair_writes();
      // ---- B ----
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        int idx = -1;
        foreach (b_wait_q[i]) if (b_wait_q[i].id == vif.mon_cb.bid) begin idx = i; break; end
        if (idx < 0)
          `uvm_error("AXI4_MON", $sformatf("%s: B with ID %0h and no completed write burst",
                     get_full_name(), vif.mon_cb.bid))
        else begin
          axi4_item t = b_wait_q[idx];
          b_wait_q.delete(idx);
          t.resp[0] = axi4_resp_e'(vif.mon_cb.bresp);
          t.t_end = $time;
          n_wr++;
          `uvm_info("AXI4_MON", {get_full_name(), ": ", t.convert2string()}, UVM_HIGH)
          ap.write(t);
        end
      end
      // ---- AR ----
      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
        axi4_item t = axi4_item::type_id::create("mon_rd");
        t.write = 0; t.id = vif.mon_cb.arid; t.addr = vif.mon_cb.araddr;
        t.len = vif.mon_cb.arlen; t.size = vif.mon_cb.arsize;
        t.burst = axi4_burst_e'(vif.mon_cb.arburst); t.prot = vif.mon_cb.arprot;
        t.cache = vif.mon_cb.arcache; t.port = cfg.port; t.t_start = $time;
        t.t_req = ar_since; ar_wait = 0;
        t.alloc();
        r_wait_q.push_back(t);
        r_beat.push_back(0);
      end
      // ---- R ----
      if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
        int idx = -1;
        foreach (r_wait_q[i]) if (r_wait_q[i].id == vif.mon_cb.rid) begin idx = i; break; end
        if (idx < 0)
          `uvm_error("AXI4_MON", $sformatf("%s: R with ID %0h and no outstanding read",
                     get_full_name(), vif.mon_cb.rid))
        else begin
          axi4_item t = r_wait_q[idx];
          int unsigned b = r_beat[idx];
          if (b == 0) t.t_first = $time;
          if (b < t.beats()) begin
            t.data[b] = vif.mon_cb.rdata;
            t.strb[b] = t.lanes(b);
            t.resp[b] = axi4_resp_e'(vif.mon_cb.rresp);
          end
          r_beat[idx] = b + 1;
          if (vif.mon_cb.rlast !== (b == t.len))
            `uvm_error("AXI4_MON", $sformatf("%s: RLAST=%0b on beat %0d of %0d (addr %08h)",
                       get_full_name(), vif.mon_cb.rlast, b, t.beats(), t.addr))
          if (vif.mon_cb.rlast || b >= t.len) begin
            r_wait_q.delete(idx);
            r_beat.delete(idx);
            t.t_end = $time;
            n_rd++;
            `uvm_info("AXI4_MON", {get_full_name(), ": ", t.convert2string()}, UVM_HIGH)
            ap.write(t);
          end
        end
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    if (aw_q.size() || b_wait_q.size() || r_wait_q.size() || w_data.size())
      `uvm_error("AXI4_MON", $sformatf("%s: unfinished bursts at end of test (aw=%0d b=%0d r=%0d w_beats=%0d)",
                 get_full_name(), aw_q.size(), b_wait_q.size(), r_wait_q.size(), w_data.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("AXI4_MON", $sformatf("%s: %0d writes, %0d reads", get_full_name(), n_wr, n_rd), UVM_LOW)
  endfunction
endclass
