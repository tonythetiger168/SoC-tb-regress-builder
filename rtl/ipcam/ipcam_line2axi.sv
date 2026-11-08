// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ipcam_line2axi -- 64-byte line memory port -> 32-bit AXI4 master
// ----------------------------------------------------------------------------
// For the xuanji-core NPU subsystem's external memory port (npu_ss_dma):
//   read:  m_rd_req held until m_rd_gnt; data returns in request order on
//          m_rd_rvalid, at least one clock after the grant, no backpressure.
//   write: m_wr_req held until m_wr_gnt; the write counts as done at the grant.
//   addresses are LINE addresses (64 B units).
// Each line becomes one INCR burst of 16 x 32-bit beats at byte address
// {line[25:0], 6'b0} (4 GB space, the line address wraps modulo 2^26).
//
//  * Reads: AR is the grant (m_rd_gnt = AR handshake), so a read is granted
//    only when the fabric accepts it. Up to RD_OUT reads may be outstanding;
//    R beats of one burst are packed into a line and returned in order
//    (single ID, so the fabric returns bursts in order).
//  * Writes: AW and the 16 W beats are sent from the held request; the
//    grant is the B handshake, so a granted write is already in memory
//    (one write in flight; the line port treats a write as done at its
//    grant, and software reads DRAM after the DMA_ST completion).
//  * Read-after-write: no read is issued while a write is in flight.
//  * Error responses (SLVERR / DECERR) are counted in rd_err / wr_err; the
//    line port has no error signalling, so the data is passed as received.
// ============================================================================
module ipcam_line2axi #(
  parameter int IDW    = 4,
  parameter int RD_OUT = 4                      // outstanding reads (2..16)
)(
  input  logic           clk,
  input  logic           rst_n,
  // ---- line port (from the NPU subsystem) ----
  input  logic           m_rd_req,
  input  logic [31:0]    m_rd_addr,
  output logic           m_rd_gnt,
  output logic           m_rd_rvalid,
  output logic [511:0]   m_rd_rdata,
  input  logic           m_wr_req,
  input  logic [31:0]    m_wr_addr,
  input  logic [511:0]   m_wr_data,
  output logic           m_wr_gnt,
  // ---- status ----
  output logic [15:0]    rd_err,
  output logic [15:0]    wr_err,
  output logic           busy,
  // ---- AXI4 master ----
  output logic [IDW-1:0] awid,
  output logic [31:0]    awaddr,
  output logic [7:0]     awlen,
  output logic [2:0]     awsize,
  output logic [1:0]     awburst,
  output logic           awvalid,
  input  logic           awready,
  output logic [31:0]    wdata,
  output logic [3:0]     wstrb,
  output logic           wlast,
  output logic           wvalid,
  input  logic           wready,
  input  logic [IDW-1:0] bid,
  input  logic [1:0]     bresp,
  input  logic           bvalid,
  output logic           bready,
  output logic [IDW-1:0] arid,
  output logic [31:0]    araddr,
  output logic [7:0]     arlen,
  output logic [2:0]     arsize,
  output logic [1:0]     arburst,
  output logic           arvalid,
  input  logic           arready,
  input  logic [IDW-1:0] rid,
  input  logic [31:0]    rdata,
  input  logic [1:0]     rresp,
  input  logic           rlast,
  input  logic           rvalid,
  output logic           rready
);
  localparam int OCW = $clog2(RD_OUT + 1);

  function automatic logic [31:0] byte_addr(input logic [31:0] line);
    return {line[25:0], 6'b0};
  endfunction

  // ======================= write path =======================================
  // The NPU holds m_wr_req / m_wr_addr / m_wr_data until the grant, so the
  // bridge sends AW and the 16 W beats straight from them and grants only
  // when the B response comes back. A write is therefore in memory when the
  // NPU sees it as done (its DMA_ST completion means the data has landed).
  logic          aw_sent, w_sent;               // AW / all 16 W beats of the current write accepted
  logic [3:0]    w_beat;
  logic          aw_hs, w_hs, b_hs;

  assign awid     = '0;
  assign awaddr   = byte_addr(m_wr_addr);
  assign awlen    = 8'd15;
  assign awsize   = 3'd2;
  assign awburst  = 2'b01;
  assign awvalid  = m_wr_req && !aw_sent;
  assign wdata    = m_wr_data[32*w_beat +: 32];
  assign wstrb    = 4'hF;
  assign wlast    = (w_beat == 4'd15);
  assign wvalid   = m_wr_req && !w_sent;
  assign bready   = 1'b1;
  assign aw_hs    = awvalid && awready;
  assign w_hs     = wvalid && wready;
  assign b_hs     = bvalid && bready;
  assign m_wr_gnt = b_hs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_sent <= 1'b0;
      w_sent  <= 1'b0;
      w_beat  <= '0;
      wr_err  <= '0;
    end else begin
      if (b_hs) begin
        aw_sent <= 1'b0;
        w_sent  <= 1'b0;
        w_beat  <= '0;
        if (bresp != 2'b00) wr_err <= wr_err + 16'd1;
      end else begin
        if (aw_hs) aw_sent <= 1'b1;
        if (w_hs) begin
          w_beat <= w_beat + 4'd1;
          if (wlast) w_sent <= 1'b1;
        end
      end
    end
  end

  // ======================= read path ========================================
  logic [OCW-1:0] r_out;                        // bursts issued, line not yet returned
  logic [3:0]     r_beat;
  logic [511:0]   r_line;
  logic           wr_pending;
  assign wr_pending = m_wr_req;              // a write is in flight until its grant

  assign arid     = '0;
  assign araddr   = byte_addr(m_rd_addr);
  assign arlen    = 8'd15;
  assign arsize   = 3'd2;
  assign arburst  = 2'b01;
  assign arvalid  = m_rd_req && !wr_pending && (r_out < OCW'(RD_OUT));
  assign m_rd_gnt = arvalid && arready;
  assign rready   = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_out       <= '0;
      r_beat      <= '0;
      r_line      <= '0;
      m_rd_rvalid <= 1'b0;
      m_rd_rdata  <= '0;
      rd_err      <= '0;
    end else begin
      m_rd_rvalid <= 1'b0;
      if (rvalid && rready) begin
        r_line[32*r_beat +: 32] <= rdata;
        r_beat <= r_beat + 4'd1;
        if (rresp != 2'b00) rd_err <= rd_err + 16'd1;
        if (rlast) begin
          m_rd_rvalid <= 1'b1;
          m_rd_rdata  <= r_line;
          m_rd_rdata[32*r_beat +: 32] <= rdata;
          r_beat <= '0;
        end
      end
      r_out <= r_out + OCW'(m_rd_gnt) - OCW'(rvalid && rready && rlast);
    end
  end

  assign busy = wr_pending || (r_out != '0);

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && rvalid && rready && rlast && r_beat != 4'd15)
    $error("ipcam_line2axi: RLAST on beat %0d of a 16-beat line read", r_beat);
`endif
endmodule
