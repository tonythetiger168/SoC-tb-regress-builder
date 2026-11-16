// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_aon_tb_top -- unit bench of rtl/phone/phone_aon_arb (three AXI4
// managers of the always-on cluster onto one port)
// ----------------------------------------------------------------------------
// In the phone SoC the arbiter only sees the three open-ip AON IPs (sensor
// hub, interrupt controller, timer), which use fixed IDs and short bursts.
// Here three random managers drive every field (IDs, addresses, lengths up to
// 256 beats, sizes, burst types, AxPROT, data, strobes) with random VALID gaps
// and READY stalls, and a random subordinate answers with random responses,
// data and stalls. Phases: free flow, heavy stalls, one manager alone, a
// mid-run reset. Checks every cycle:
//  * an o_* handshake happens exactly when one manager's handshake does, and
//    carries that manager's fields (AW, W, AR) or returns the port's (B, R)
//  * a manager gets B / R only for its own outstanding burst, R beats
//    end with RLAST after AxLEN + 1 beats
//  * at the end every burst got its response
// Prints SB_PASS checks=<n>. The phone SoC benches waive the arbiter's points
// citing this bench (scripts/cov/exclude/phone.txt).
// ============================================================================
`timescale 1ns/1ps
module phone_aon_tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  localparam int N = 3;

  logic clk = 1'b0, rst_n = 1'b0;
  always #1 clk = ~clk;

  logic [3:0]  awid [N], bid [N], arid [N], rid [N];
  logic [31:0] awaddr [N], wdata [N], araddr [N], rdata [N];
  logic [7:0]  awlen [N], arlen [N];
  logic [2:0]  awsize [N], arsize [N], awprot [N], arprot [N];
  logic [1:0]  awburst [N], arburst [N], bresp [N], rresp [N];
  logic [3:0]  wstrb [N];
  logic        awvalid [N], awready [N], wlast [N], wvalid [N], wready [N];
  logic        bvalid [N], bready [N], arvalid [N], arready [N];
  logic        rlast [N], rvalid [N], rready [N];

  logic [3:0]  o_awid, o_bid, o_arid, o_rid;
  logic [31:0] o_awaddr, o_wdata, o_araddr, o_rdata;
  logic [7:0]  o_awlen, o_arlen;
  logic [2:0]  o_awsize, o_arsize, o_awprot, o_arprot;
  logic [1:0]  o_awburst, o_arburst, o_bresp, o_rresp;
  logic [3:0]  o_wstrb;
  logic        o_awvalid, o_awready, o_wlast, o_wvalid, o_wready, o_bvalid, o_bready;
  logic        o_arvalid, o_arready, o_rlast, o_rvalid, o_rready;

  phone_aon_arb #(.N(N)) dut (.*);

  // ---------------- knobs (per phase) ----------------
  int unsigned p_go     = 60;     // % chance a manager starts a burst in a cycle
  int unsigned p_ready  = 70;     // % of cycles a READY is high
  int unsigned p_rvalid = 80;     // % of cycles the subordinate offers an R beat / B
  int unsigned max_len  = 15;     // AxLEN upper bound (255 sometimes)
  bit          only0    = 1'b0;   // only manager 0 issues
  bit          stop     = 1'b0;   // no new bursts (drain)
  int unsigned n_checks;

  function automatic bit pct(int unsigned p);
    return ($urandom_range(99) < p);
  endfunction

  task automatic chk(bit ok, string msg);
    n_checks++;
    if (!ok) `uvm_error("AON_TB", msg)
  endtask

  // ---------------- managers ----------------
  int unsigned w_left [N];              // W beats still to send of the current write
  int unsigned w_out [N], r_out [N];    // bursts awaiting B / last R
  int unsigned r_beats [N];             // R beats received of the outstanding read
  logic [7:0]  r_len [N];
  logic        w_pend [N];              // AW done, W beats or B pending

  function automatic logic [7:0] rnd_len();
    return pct(10) ? 8'd255 : 8'($urandom_range(max_len));
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < N; i++) begin
        awvalid[i] <= 0; wvalid[i] <= 0; arvalid[i] <= 0; bready[i] <= 0; rready[i] <= 0;
        awid[i] <= '0; awaddr[i] <= '0; awlen[i] <= '0; awsize[i] <= '0; awburst[i] <= '0; awprot[i] <= '0;
        arid[i] <= '0; araddr[i] <= '0; arlen[i] <= '0; arsize[i] <= '0; arburst[i] <= '0; arprot[i] <= '0;
        wdata[i] <= '0; wstrb[i] <= '0; wlast[i] <= 0;
        w_left[i] = 0; w_out[i] = 0; r_out[i] = 0; r_beats[i] = 0; w_pend[i] = 0;
      end
    end else
      for (int i = 0; i < N; i++) begin
        bit act;
        act = !stop && (!only0 || i == 0);
        // AW: one write at a time per manager (the arbiter holds the grant to B)
        if (awvalid[i] && awready[i]) begin
          awvalid[i] <= 0;
          w_left[i] = awlen[i] + 1;
          w_pend[i] = 1;
          w_out[i]++;
        end else if (!awvalid[i] && !w_pend[i] && act && pct(p_go)) begin
          awvalid[i] <= 1;
          awid[i] <= 4'($urandom); awaddr[i] <= $urandom; awlen[i] <= rnd_len();
          awsize[i] <= 3'($urandom); awburst[i] <= 2'($urandom); awprot[i] <= 3'($urandom);
        end
        // W
        if (wvalid[i] && wready[i]) begin
          w_left[i]--;
          wvalid[i] <= 0;
        end
        if (w_left[i] > 0 && (!wvalid[i] || wready[i]) && pct(p_rvalid)) begin
          wvalid[i] <= 1; wdata[i] <= $urandom; wstrb[i] <= 4'($urandom); wlast[i] <= (w_left[i] == 1);
        end
        // B
        if (bvalid[i] && bready[i]) begin
          chk(w_out[i] == 1 && w_left[i] == 0, $sformatf("m%0d: B with no write waiting for it", i));
          w_out[i]--;
          w_pend[i] = 0;
        end
        bready[i] <= pct(p_ready);
        // AR: one read at a time per manager
        if (arvalid[i] && arready[i]) begin
          arvalid[i] <= 0;
          r_out[i]++;
          r_len[i] = arlen[i];
          r_beats[i] = 0;
        end else if (!arvalid[i] && r_out[i] == 0 && act && pct(p_go)) begin
          arvalid[i] <= 1;
          arid[i] <= 4'($urandom); araddr[i] <= $urandom; arlen[i] <= rnd_len();
          arsize[i] <= 3'($urandom); arburst[i] <= 2'($urandom); arprot[i] <= 3'($urandom);
        end
        // R
        if (rvalid[i] && rready[i]) begin
          chk(r_out[i] == 1, $sformatf("m%0d: R beat with no read outstanding", i));
          chk(rlast[i] == (r_beats[i] == r_len[i]), $sformatf("m%0d: RLAST %0b at beat %0d of %0d", i,
              rlast[i], r_beats[i], r_len[i] + 1));
          r_beats[i]++;
          if (rlast[i]) r_out[i] = 0;
        end
        rready[i] <= pct(p_ready);
      end

  // ---------------- subordinate ----------------
  int unsigned s_wbeats, s_rleft;
  logic        s_bpend;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      o_awready <= 0; o_wready <= 0; o_bvalid <= 0; o_bid <= '0; o_bresp <= '0;
      o_arready <= 0; o_rvalid <= 0; o_rid <= '0; o_rdata <= '0; o_rresp <= '0; o_rlast <= 0;
      s_bpend = 0; s_rleft = 0;
    end else begin
      o_awready <= pct(p_ready);
      o_wready  <= pct(p_ready);
      o_arready <= pct(p_ready) && s_rleft == 0;
      if (o_wvalid && o_wready && o_wlast) s_bpend = 1;
      if (o_bvalid && o_bready) o_bvalid <= 0;
      else if (s_bpend && !o_bvalid && pct(p_rvalid)) begin
        o_bvalid <= 1; o_bid <= o_awid; o_bresp <= 2'($urandom); s_bpend = 0;
      end
      if (o_arvalid && o_arready) s_rleft = o_arlen + 1;
      if (o_rvalid && o_rready) begin
        o_rvalid <= 0;
        if (o_rlast) s_rleft = 0;
      end
      if (s_rleft > 0 && (!o_rvalid || o_rready) && pct(p_rvalid)) begin
        o_rvalid <= 1; o_rid <= o_arid; o_rdata <= $urandom; o_rresp <= 2'($urandom);
        o_rlast <= (s_rleft == 1);
        s_rleft--;
      end
    end

  // ---------------- checks: the port mirrors exactly one manager ----------
  always @(negedge clk) if (rst_n) begin
    int naw, nw, nb, nar, nr;
    naw = 0; nw = 0; nb = 0; nar = 0; nr = 0;
    for (int i = 0; i < N; i++) begin
      if (awvalid[i] && awready[i]) begin
        naw++;
        chk(o_awvalid && o_awready && o_awid == awid[i] && o_awaddr == awaddr[i] && o_awlen == awlen[i] &&
            o_awsize == awsize[i] && o_awburst == awburst[i] && o_awprot == awprot[i],
            $sformatf("m%0d AW handshake not mirrored on the port", i));
      end
      if (wvalid[i] && wready[i]) begin
        nw++;
        chk(o_wvalid && o_wready && o_wdata == wdata[i] && o_wstrb == wstrb[i] && o_wlast == wlast[i],
            $sformatf("m%0d W beat not mirrored on the port", i));
      end
      if (bvalid[i] && bready[i]) begin
        nb++;
        chk(o_bvalid && o_bready && bid[i] == o_bid && bresp[i] == o_bresp, $sformatf("m%0d B differs from the port", i));
      end
      if (arvalid[i] && arready[i]) begin
        nar++;
        chk(o_arvalid && o_arready && o_arid == arid[i] && o_araddr == araddr[i] && o_arlen == arlen[i] &&
            o_arsize == arsize[i] && o_arburst == arburst[i] && o_arprot == arprot[i],
            $sformatf("m%0d AR handshake not mirrored on the port", i));
      end
      if (rvalid[i] && rready[i]) begin
        nr++;
        chk(o_rvalid && o_rready && rid[i] == o_rid && rdata[i] == o_rdata && rresp[i] == o_rresp &&
            rlast[i] == o_rlast, $sformatf("m%0d R beat differs from the port", i));
      end
    end
    chk(naw == int'(o_awvalid && o_awready) && nw == int'(o_wvalid && o_wready) &&
        nb == int'(o_bvalid && o_bready) && nar == int'(o_arvalid && o_arready) &&
        nr == int'(o_rvalid && o_rready), "port handshake without exactly one manager handshake");
  end

  // ---------------- phases ----------------
  task automatic run(int unsigned cycles);
    repeat (cycles) @(posedge clk);
  endtask

  task automatic drain();
    stop = 1;
    for (int k = 0; k < 200000; k++) begin
      if (w_out[0] + w_out[1] + w_out[2] + r_out[0] + r_out[1] + r_out[2] == 0 &&
          !awvalid[0] && !awvalid[1] && !awvalid[2] && !arvalid[0] && !arvalid[1] && !arvalid[2]) break;
      @(posedge clk);
    end
    if (w_out[0] + w_out[1] + w_out[2] + r_out[0] + r_out[1] + r_out[2] != 0)
      `uvm_error("AON_TB", $sformatf("bursts still outstanding after the drain: w %0d %0d %0d r %0d %0d %0d",
                 w_out[0], w_out[1], w_out[2], r_out[0], r_out[1], r_out[2],
                 "; ws=%0d wg=%0d rs=%0d rg=%0d w_left=%0d,%0d,%0d s_bpend=%0b s_rleft=%0d o_bvalid=%0b o_rvalid=%0b",
                 dut.ws, dut.wg, dut.rs, dut.rg, w_left[0], w_left[1], w_left[2], s_bpend, s_rleft, o_bvalid, o_rvalid))
    stop = 0;
  endtask

  initial begin
    run_test();
  end

  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
    // free flow
    p_ready = 100; p_rvalid = 100; p_go = 100; run(4000);
    // stalls, long bursts
    p_ready = 50; p_rvalid = 60; p_go = 40; max_len = 255; run(20000);
    // heavy stalls, short bursts
    p_ready = 20; p_rvalid = 30; p_go = 70; max_len = 3; run(10000);
    drain();
    // one manager alone (the round robin wraps to itself)
    only0 = 1; p_ready = 80; p_rvalid = 80; run(4000);
    drain();
    only0 = 0;
    // mid-run reset with bursts in flight
    p_ready = 50; run(3000);
    rst_n <= 1'b0;
    run(3);
    rst_n <= 1'b1;
    p_ready = 90; p_rvalid = 90; max_len = 31; run(6000);
    drain();
    $display("SB_PASS checks=%0d", n_checks);
    phone_aon_test_pkg::done = 1'b1;
  end
endmodule
