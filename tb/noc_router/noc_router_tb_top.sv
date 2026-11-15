// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_router_tb_top -- unit bench of rtl/noc/noc_router_open (the open mesh
// router every generated mesh NoC uses), centre router [1, 1] of the
// tv8k_soc_mesh 4x4 noc_cfg_pkg, so flits route to all five ports.
// ----------------------------------------------------------------------------
// Five random flit sources and five output sinks with per-port random ready
// stalls, in phases: free flow, light stalls, long stalls that fill every input
// FIFO (back-pressure on every rx_ready), one output blocked while the others
// run, and a mid-run reset with the FIFOs full. The scoreboard keeps, per
// (input, output) pair, the flits in arrival order (XY routing: dir_of) and
// checks every tx flit against the head of its pair; at the end every queue
// must be empty. Checks: tx_valid only while tx_ready, no flit lost or
// reordered, busy == any input FIFO not empty. Prints SB_PASS checks=<n>.
// The SoC benches waive router back-pressure as not reached; this bench
// closes it (scripts/cov/run_cov.sh noc_router regress/noc_router_testlist.txt).
// ============================================================================
`timescale 1ns/1ps
module noc_router_tb_top;
  import noc_cfg_pkg::*;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  localparam int NP = 5, X0 = 1, Y0 = 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #1 clk = ~clk;

  logic [FLIT_W-1:0] rx_d [NP], tx_d [NP];
  logic              rx_v [NP], rx_r [NP], tx_v [NP], tx_r [NP];
  logic              busy;

  noc_router_open #(.X_POS(X0), .Y_POS(Y0)) dut (
    .clk, .rst_n, .test_en(1'b0),
    .north_rx_data(rx_d[0]), .north_rx_valid(rx_v[0]), .north_rx_ready(rx_r[0]),
    .north_tx_data(tx_d[0]), .north_tx_valid(tx_v[0]), .north_tx_ready(tx_r[0]),
    .south_rx_data(rx_d[1]), .south_rx_valid(rx_v[1]), .south_rx_ready(rx_r[1]),
    .south_tx_data(tx_d[1]), .south_tx_valid(tx_v[1]), .south_tx_ready(tx_r[1]),
    .east_rx_data(rx_d[2]),  .east_rx_valid(rx_v[2]),  .east_rx_ready(rx_r[2]),
    .east_tx_data(tx_d[2]),  .east_tx_valid(tx_v[2]),  .east_tx_ready(tx_r[2]),
    .west_rx_data(rx_d[3]),  .west_rx_valid(rx_v[3]),  .west_rx_ready(rx_r[3]),
    .west_tx_data(tx_d[3]),  .west_tx_valid(tx_v[3]),  .west_tx_ready(tx_r[3]),
    .local_rx_data(rx_d[4]), .local_rx_valid(rx_v[4]), .local_rx_ready(rx_r[4]),
    .local_tx_data(tx_d[4]), .local_tx_valid(tx_v[4]), .local_tx_ready(tx_r[4]),
    .busy
  );

  // ---------------- reference: XY routing (same rule as the router) -------
  function automatic int route(logic [FLIT_W-1:0] d);
    noc_flit_t f = noc_flit_t'(d);
    int r;
    if      (int'(f.dest_x) > X0) r = 2;
    else if (int'(f.dest_x) < X0) r = 3;
    else if (int'(f.dest_y) > Y0) r = 0;
    else if (int'(f.dest_y) < Y0) r = 1;
    else                          r = 4;
    return r;
  endfunction

  // ---------------- stimulus knobs (set per phase) ----------------
  int unsigned p_valid  = 70;          // % of cycles a source offers a flit
  int unsigned p_ready [NP] = '{default: 100};   // % of cycles a sink is ready
  int unsigned want_dir = 5;           // 5: random destination; else bias to this output
  bit          sources_on = 1'b0;

  // ---------------- scoreboard ----------------
  logic [FLIT_W-1:0] q [NP][NP][$];     // [input][output] in arrival order
  int unsigned n_checks = 0, n_err = 0, serial = 0;

  function automatic logic [FLIT_W-1:0] new_flit(int unsigned bias);
    logic [FLIT_W+31:0] r;
    logic [FLIT_W-1:0] d;
    noc_flit_t f;
    for (int b = 0; b < FLIT_W; b += 32) r[b +: 32] = $urandom;   // every bit toggles
    d = r[FLIT_W-1:0];
    f = noc_flit_t'(d);
    if (bias < 5 && $urandom_range(3, 0) != 0) begin
      // steer to one output: x/y relative to [1, 1]
      f.dest_x = XB'(bias == 2 ? $urandom_range(3, 2) : bias == 3 ? 0 : X0);
      f.dest_y = YB'(bias == 0 ? $urandom_range(3, 2) : bias == 1 ? 0 : Y0);
    end
    d = FLIT_W'(f);
    d[FLIT_W-1 -: 16] = 16'(serial++);  // unique tag in the top payload bits
    return d;
  endfunction

  // sources: hold data stable while valid and not ready (valid/ready handshake)
  for (genvar p = 0; p < NP; p++) begin : g_src
    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        rx_v[p] <= 1'b0; rx_d[p] <= '0;
      end else begin
        if (rx_v[p] && rx_r[p]) begin
          q[p][route(rx_d[p])].push_back(rx_d[p]);
          rx_v[p] <= 1'b0;
        end
        if ((!rx_v[p] || rx_r[p]) && sources_on && $urandom_range(99, 0) < p_valid) begin
          rx_v[p] <= 1'b1;
          rx_d[p] <= new_flit(want_dir);
        end
      end
    end
    always @(posedge clk or negedge rst_n)
      if (!rst_n) tx_r[p] <= 1'b1;
      else        tx_r[p] <= ($urandom_range(99, 0) < p_ready[p]);
  end

  // sinks: check every delivered flit
  always @(negedge clk) if (rst_n) begin
    for (int o = 0; o < NP; o++) begin
      if (tx_v[o] && !tx_r[o]) begin
        n_err++; `uvm_error("RTR_SB", $sformatf("output %0d: tx_valid while tx_ready is low", o))
      end
      if (tx_v[o]) begin
        automatic bit found = 1'b0;
        for (int i = 0; i < NP; i++)
          if (!found && q[i][o].size() != 0 && q[i][o][0] === tx_d[o]) begin
            void'(q[i][o].pop_front()); found = 1; n_checks++;
          end
        if (!found) begin
          n_err++; `uvm_error("RTR_SB", $sformatf("output %0d: flit %h is not the oldest of any input for this output", o, tx_d[o]))
        end
        if (route(tx_d[o]) != o) begin
          n_err++; `uvm_error("RTR_SB", $sformatf("output %0d: flit %h routes to %0d", o, tx_d[o], route(tx_d[o])))
        end
      end
    end
    if (busy !== |{dut.g_in[0].cnt, dut.g_in[1].cnt, dut.g_in[2].cnt, dut.g_in[3].cnt, dut.g_in[4].cnt}) begin
      n_err++; `uvm_error("RTR_SB", $sformatf("busy = %b with input FIFO counts %0d %0d %0d %0d %0d", busy,
        dut.g_in[0].cnt, dut.g_in[1].cnt, dut.g_in[2].cnt, dut.g_in[3].cnt, dut.g_in[4].cnt))
    end
  end

  // ---------------- functional coverage ----------------
  int unsigned max_cnt [NP];
  covergroup cg_port with function sample(int p, int cnt, bit stalled, bit full);
    cp_port : coverpoint p { bins port[] = {[0:4]}; }
    // input FIFO occupancy 0..8 on every port, encoded as port*9 + count
    cp_occ  : coverpoint p * 9 + cnt { bins occ[] = {[0:44]}; }
    // every output seen stalled with a flit waiting, every input seen full
    cp_stall: coverpoint p * 2 + int'(stalled) { bins s[] = {[0:9]}; }
    cp_full : coverpoint p * 2 + int'(full) { bins f[] = {[0:9]}; }
  endgroup
  cg_port cg = new;
  always @(posedge clk) if (rst_n)
    for (int p = 0; p < NP; p++) begin
      automatic int c = 0;
      automatic bit waiting = 0;
      case (p)
        0: c = dut.g_in[0].cnt; 1: c = dut.g_in[1].cnt; 2: c = dut.g_in[2].cnt;
        3: c = dut.g_in[3].cnt; default: c = dut.g_in[4].cnt;
      endcase
      for (int i = 0; i < NP; i++) if (q[i][p].size() != 0) waiting = 1;
      cg.sample(p, c, waiting && !tx_r[p], !rx_r[p]);
    end

  // ---------------- phases ----------------
  task automatic drain();
    sources_on = 0;
    p_ready = '{default: 100};
    repeat (40) @(posedge clk);
  endtask

  task automatic phase(int unsigned cycles, int unsigned pv, int unsigned pr, int unsigned dir = 5);
    p_valid = pv; want_dir = dir; sources_on = 1;
    for (int c = 0; c < cycles; c++) begin
      @(posedge clk);
      if (c % 50 == 0) foreach (p_ready[o]) p_ready[o] = $urandom_range(pr, pr / 4);
    end
  endtask

  initial begin
    int unsigned left;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    phase(2000, 60, 100);                       // free flow
    phase(4000, 80, 70);                        // light random stalls
    for (int o = 0; o < NP; o++) begin          // every output hot, stalled hard
      phase(1500, 95, 20, o);
      drain();
    end
    phase(3000, 100, 8);                        // everything stalled: all FIFOs fill
    for (int o = 0; o < NP; o++) begin          // one output blocked, the rest free
      p_valid = 90; want_dir = 5; sources_on = 1;
      foreach (p_ready[k]) p_ready[k] = (k == o) ? 0 : 100;
      repeat (800) @(posedge clk);
      drain();
    end
    drain();
    left = 0;
    for (int i = 0; i < NP; i++) for (int o = 0; o < NP; o++) left += q[i][o].size();
    if (left != 0) begin n_err++; `uvm_error("RTR_SB", $sformatf("%0d flits never left the router", left)) end
    // reset with traffic in flight: the router comes back empty
    phase(500, 100, 10);
    @(negedge clk) rst_n = 1'b0;
    for (int i = 0; i < NP; i++) for (int o = 0; o < NP; o++) q[i][o].delete();
    repeat (3) @(posedge clk);
    if (busy !== 1'b0) begin n_err++; `uvm_error("RTR_SB", $sformatf("busy after reset")) end
    @(negedge clk) rst_n = 1'b1;
    phase(1000, 70, 80);
    drain();
    left = 0;
    for (int i = 0; i < NP; i++) for (int o = 0; o < NP; o++) left += q[i][o].size();
    if (left != 0) begin n_err++; `uvm_error("RTR_SB", $sformatf("%0d flits never left the router after reset", left)) end
    if (n_err == 0 && n_checks > 0) $display("SB_PASS checks=%0d", n_checks);
    else $display("SB_FAIL errors=%0d checks=%0d", n_err, n_checks);
    noc_router_test_pkg::done = 1'b1;
  end
  initial run_test();
endmodule
