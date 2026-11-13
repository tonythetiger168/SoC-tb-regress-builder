// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ipcam_npu_xj -- IPCAM NPU: xuanji-core NPU subsystem (orca_npu_ss_apb:
// npu_ss_regs + orca_npu_ss, GEMM / VEC / DMA command queue, on-chip L2)
// with its 64-byte-line external memory port bridged to the 32-bit SoC
// fabric by ipcam_line2axi (one line = one 16-beat INCR burst).
// The xuanji RTL is not in this repo: scripts/fetch_ext_ip.sh clones
// tonythetiger168/xuanji-core at a pinned commit into ext/ (git-ignored).
// Register map: xuanji-core docs/apb.md, "NPU Subsystem" (4 KB window).
// DMA addresses are LINE addresses: byte address = line << 6.
// Retention: clk_aon = clk, por_n = rst_n, no save/restore (no power domains
// in the IPCAM TB).
// ============================================================================
module ipcam_npu_xj #(
  parameter int N      = 8,      // npu_products.sv: Xuanji-X1 defaults
  parameter int NCU    = 4,
  parameter int NB     = 4,
  parameter int DEPTH  = 1024,
  parameter int QD     = 8,
  parameter int OUT    = 32,
  parameter int RD_OUT = 4       // AXI reads in flight from the bridge
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  output logic        pready,
  output logic [31:0] prdata,
  output logic        pslverr,
  output logic        irq,
  output logic        busy,
  output logic [15:0] bus_rd_err,
  output logic [15:0] bus_wr_err,
  output logic [3:0]  awid,
  output logic [31:0] awaddr,
  output logic [7:0]  awlen,
  output logic [2:0]  awsize,
  output logic [1:0]  awburst,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wlast,
  output logic        wvalid,
  input  logic        wready,
  input  logic [3:0]  bid,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready,
  output logic [3:0]  arid,
  output logic [31:0] araddr,
  output logic [7:0]  arlen,
  output logic [2:0]  arsize,
  output logic [1:0]  arburst,
  output logic        arvalid,
  input  logic        arready,
  input  logic [3:0]  rid,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rlast,
  input  logic        rvalid,
  output logic        rready
);
  logic         m_rd_req, m_rd_gnt, m_rd_rvalid, m_wr_req, m_wr_gnt, ss_busy, br_busy;
  logic [31:0]  m_rd_addr, m_wr_addr;
  logic [511:0] m_rd_rdata, m_wr_data;

  orca_npu_ss_apb #(.N(N), .NCU(NCU), .NB(NB), .DEPTH(DEPTH), .QD(QD), .OUT(OUT)) u_npu (
    .clk, .rst_n, .test_en(1'b0),
    .clk_aon(clk), .por_n(rst_n), .ret_save(1'b0), .ret_restore(1'b0),
    .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pready, .prdata, .pslverr,
    .irq, .busy(ss_busy),
    .m_rd_req, .m_rd_addr, .m_rd_gnt, .m_rd_rvalid, .m_rd_rdata,
    .m_wr_req, .m_wr_addr, .m_wr_data, .m_wr_gnt
  );

  ipcam_line2axi #(.IDW(4), .RD_OUT(RD_OUT)) u_br (
    .clk, .rst_n,
    .m_rd_req, .m_rd_addr, .m_rd_gnt, .m_rd_rvalid, .m_rd_rdata,
    .m_wr_req, .m_wr_addr, .m_wr_data, .m_wr_gnt,
    .rd_err(bus_rd_err), .wr_err(bus_wr_err), .busy(br_busy),
    .awid, .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bid, .bresp, .bvalid, .bready,
    .arid, .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
    .rid, .rdata, .rresp, .rlast, .rvalid, .rready
  );

  assign busy = ss_busy | br_busy;
endmodule
