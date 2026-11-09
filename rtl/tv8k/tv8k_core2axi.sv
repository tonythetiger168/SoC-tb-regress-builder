// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_core2axi -- xuanji RV64 core L2 line port to AXI4 (32-bit, NoC master NI)
// ----------------------------------------------------------------------------
// The core (orca_v63_cpu_core) holds l2_req_valid / l2_req_addr until it is
// served and takes l2_fill_valid in cycle t+1 as the answer to the request it
// made in cycle t (it compares the line address). Its write port (L1D write-
// back, a whole 64-byte line) has no back-pressure.
//   read : one line at a time: a 16-beat INCR read of the requested line; when
//          the line is in, fill_valid is raised in a cycle that follows a cycle
//          requesting that same line (if the requester moved to another line,
//          the data is dropped and the new line fetched).
//   write: lines are queued (WQ deep) and sent as 16-beat writes. Reads wait
//          until every queued write has its B response, so a read never
//          overtakes an older write-back. A full queue is an error (flagged).
// ============================================================================
module tv8k_core2axi #(
  parameter int WQ = 16
)(
  input  logic         clk,
  input  logic         rst_n,
  // core L2 port
  input  logic [63:0]  l2_req_addr,
  input  logic         l2_req_valid,
  output logic [511:0] l2_fill_line,
  output logic         l2_fill_valid,
  input  logic         l2_wr_valid,
  input  logic [63:0]  l2_wr_addr,
  input  logic [511:0] l2_wr_line,
  // AXI4 manager
  output logic [31:0]  awaddr,
  output logic         awvalid,
  input  logic         awready,
  output logic [31:0]  wdata,
  output logic         wlast,
  output logic         wvalid,
  input  logic         wready,
  input  logic [1:0]   bresp,
  input  logic         bvalid,
  output logic [31:0]  araddr,
  output logic         arvalid,
  input  logic         arready,
  input  logic [31:0]  rdata,
  input  logic [1:0]   rresp,
  input  logic         rlast,
  input  logic         rvalid,
  // status
  output logic         wq_overflow,          // sticky
  output logic         bus_err               // sticky: a non-OKAY response
);
  localparam int WB = $clog2(WQ);

  // ---------------- write-back queue ----------------
  logic [25:0]  wq_line [WQ];
  logic [511:0] wq_data [WQ];
  logic [WB:0]  wq_cnt;
  logic [WB-1:0] wq_wp, wq_rp;
  logic [WB:0]  b_owed;                       // writes sent, B not yet received
  logic         aw_done;
  logic [3:0]   w_k;
  wire          wq_push = l2_wr_valid;
  assign awaddr  = {wq_line[wq_rp], 6'd0};
  assign awvalid = (wq_cnt != 0) && !aw_done;
  assign wvalid  = (wq_cnt != 0) && aw_done;
  assign wdata   = wq_data[wq_rp][32 * w_k +: 32];
  assign wlast   = (w_k == 4'd15);
  wire          w_end = wvalid && wready && wlast;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      wq_cnt <= '0; wq_wp <= '0; wq_rp <= '0; b_owed <= '0; aw_done <= 1'b0; w_k <= '0;
      wq_overflow <= 1'b0; bus_err <= 1'b0;
    end else begin
      if (wq_push) begin
        if (wq_cnt == (WB+1)'(WQ)) wq_overflow <= 1'b1;
        else begin
          wq_line[wq_wp] <= l2_wr_addr[31:6];
          wq_data[wq_wp] <= l2_wr_line;
          wq_wp <= (int'(wq_wp) == WQ - 1) ? '0 : wq_wp + 1'b1;
        end
      end
      if (awvalid && awready) aw_done <= 1'b1;
      if (wvalid && wready) w_k <= w_k + 4'd1;
      if (w_end) begin
        aw_done <= 1'b0;
        wq_rp <= (int'(wq_rp) == WQ - 1) ? '0 : wq_rp + 1'b1;
      end
      wq_cnt <= wq_cnt + (WB+1)'(wq_push && wq_cnt != (WB+1)'(WQ)) - (WB+1)'(w_end);
      b_owed <= b_owed + (WB+1)'(w_end) - (WB+1)'(bvalid);
      if (bvalid && bresp != 2'b00) bus_err <= 1'b1;
      if (rvalid && rresp != 2'b00) bus_err <= 1'b1;
    end

  // ---------------- line reads ----------------
  typedef enum logic [1:0] {R_IDLE, R_ADDR, R_DATA, R_HAVE} rst_t;
  rst_t         rs;
  logic [25:0]  r_line;
  logic [511:0] r_buf;
  logic [3:0]   r_k;
  wire  [25:0]  req_line = l2_req_addr[31:6];
  wire          wr_quiet = (wq_cnt == 0) && (b_owed == 0) && !wq_push;
  assign araddr  = {r_line, 6'd0};
  assign arvalid = (rs == R_ADDR);
  assign l2_fill_line = r_buf;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rs <= R_IDLE; r_line <= '0; r_buf <= '0; r_k <= '0; l2_fill_valid <= 1'b0;
    end else begin
      l2_fill_valid <= 1'b0;
      case (rs)
        // (not in the fill cycle: the request still showing then is the one being answered)
        R_IDLE: if (l2_req_valid && wr_quiet && !l2_fill_valid) begin r_line <= req_line; rs <= R_ADDR; end
        R_ADDR: if (arready) begin rs <= R_DATA; r_k <= '0; end
        R_DATA: if (rvalid) begin
          r_buf[32 * r_k +: 32] <= rdata;
          r_k <= r_k + 4'd1;
          if (rlast) rs <= R_HAVE;
        end
        R_HAVE:
          if (l2_req_valid && req_line == r_line) begin
            // answer in the next cycle, after a cycle that requests this line
            l2_fill_valid <= 1'b1;
            rs <= R_IDLE;
          end else if (l2_req_valid) rs <= R_IDLE;          // the requester moved on: fetch its line
        default: rs <= R_IDLE;
      endcase
    end
endmodule
