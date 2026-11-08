// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_line2axi -- 64-byte line port (xuanji NPU subsystem DMA) to AXI4
// ----------------------------------------------------------------------------
// Line port (orca_npu_ss_apb m_rd_* / m_wr_*): addresses are line numbers
// (byte address = line x 64, low 32 bits), reads answer in order with one
// rvalid per line, writes are posted (no response).
//   read : m_rd_gnt = the AR handshake of a 16-beat 32-bit INCR burst; R beats
//          are packed into the line and returned in order (the NoC master NI
//          answers in issue order), up to RQ lines in flight.
//   write: m_wr_gnt when the line buffer is free; the line goes out as one AW
//          and 16 W beats; B responses are counted (and any error flagged).
// ============================================================================
module tv8k_line2axi #(
  parameter int RQ = 8                       // reads in flight
)(
  input  logic         clk,
  input  logic         rst_n,
  // line port
  input  logic         m_rd_req,
  input  logic [31:0]  m_rd_addr,
  output logic         m_rd_gnt,
  output logic         m_rd_rvalid,
  output logic [511:0] m_rd_rdata,
  input  logic         m_wr_req,
  input  logic [31:0]  m_wr_addr,
  input  logic [511:0] m_wr_data,
  output logic         m_wr_gnt,
  // AXI4 manager (32-bit)
  output logic [3:0]   awid,
  output logic [31:0]  awaddr,
  output logic [7:0]   awlen,
  output logic [2:0]   awsize,
  output logic [1:0]   awburst,
  output logic         awvalid,
  input  logic         awready,
  output logic [31:0]  wdata,
  output logic [3:0]   wstrb,
  output logic         wlast,
  output logic         wvalid,
  input  logic         wready,
  input  logic [1:0]   bresp,
  input  logic         bvalid,
  output logic         bready,
  output logic [3:0]   arid,
  output logic [31:0]  araddr,
  output logic [7:0]   arlen,
  output logic [2:0]   arsize,
  output logic [1:0]   arburst,
  output logic         arvalid,
  input  logic         arready,
  input  logic [31:0]  rdata,
  input  logic [1:0]   rresp,
  input  logic         rlast,
  input  logic         rvalid,
  output logic         rready,
  // status
  output logic [31:0]  n_bresp,              // write responses received
  output logic         bus_err               // any non-OKAY response (sticky)
);
  localparam int QB = $clog2(RQ + 1);

  // ---------------- read ----------------
  logic [QB-1:0] r_infl;
  logic [3:0]    r_k;
  logic [511:0]  r_line;
  assign arid    = 4'd0;
  assign araddr  = {m_rd_addr[25:0], 6'd0};
  assign arlen   = 8'd15;
  assign arsize  = 3'd2;
  assign arburst = 2'b01;
  assign arvalid = m_rd_req && (r_infl != QB'(RQ));
  assign m_rd_gnt = arvalid && arready;
  assign rready  = 1'b1;
  wire   r_end   = rvalid && rlast;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      r_infl <= '0; r_k <= '0; r_line <= '0; m_rd_rvalid <= 1'b0; m_rd_rdata <= '0;
    end else begin
      m_rd_rvalid <= 1'b0;
      if (rvalid) begin
        r_line[32 * r_k +: 32] <= rdata;
        r_k <= r_k + 4'd1;
        if (r_end) begin
          m_rd_rvalid <= 1'b1;
          m_rd_rdata  <= r_line;
          m_rd_rdata[32 * r_k +: 32] <= rdata;
          r_k <= '0;
        end
      end
      r_infl <= r_infl + QB'(m_rd_gnt) - QB'(r_end);
    end

  // ---------------- write ----------------
  logic         w_busy, aw_done;
  logic [31:0]  w_addr;
  logic [511:0] w_line;
  logic [3:0]   w_k;
  assign m_wr_gnt = m_wr_req && !w_busy;
  assign awid    = 4'd0;
  assign awaddr  = {w_addr[25:0], 6'd0};
  assign awlen   = 8'd15;
  assign awsize  = 3'd2;
  assign awburst = 2'b01;
  assign awvalid = w_busy && !aw_done;
  assign wvalid  = w_busy && aw_done;
  assign wdata   = w_line[32 * w_k +: 32];
  assign wstrb   = 4'hF;
  assign wlast   = (w_k == 4'd15);
  assign bready  = 1'b1;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      w_busy <= 1'b0; aw_done <= 1'b0; w_addr <= '0; w_line <= '0; w_k <= '0; n_bresp <= '0; bus_err <= 1'b0;
    end else begin
      if (m_wr_gnt) begin w_busy <= 1'b1; aw_done <= 1'b0; w_addr <= m_wr_addr; w_line <= m_wr_data; w_k <= '0; end
      if (awvalid && awready) aw_done <= 1'b1;
      if (wvalid && wready) begin
        w_k <= w_k + 4'd1;
        if (wlast) w_busy <= 1'b0;
      end
      if (bvalid) begin
        n_bresp <= n_bresp + 32'd1;
        if (bresp != 2'b00) bus_err <= 1'b1;
      end
      if (rvalid && rresp != 2'b00) bus_err <= 1'b1;
    end
endmodule
