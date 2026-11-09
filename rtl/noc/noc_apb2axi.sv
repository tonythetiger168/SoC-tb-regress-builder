// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_apb2axi -- APB4 slave to AXI4 master (32-bit data)
// ----------------------------------------------------------------------------
//  * The test shim behind a NoC slave port that speaks APB: the NoC's APB
//    master (noc_axi2apb) -> this -> an AXI4 slave VIP with a memory model,
//    so APB ports are checked by the same scoreboard as AXI ports.
//  * Each APB transfer becomes one single-beat AXI transfer (ID 0, INCR,
//    32-bit). PREADY stays low until the AXI response is back; SLVERR or
//    DECERR set PSLVERR.
// ============================================================================
module noc_apb2axi #(
  parameter int IDW = 4
)(
  input  logic           clk,
  input  logic           rst_n,
  // APB4 slave
  input  logic [31:0]    paddr,
  input  logic           psel,
  input  logic           penable,
  input  logic           pwrite,
  input  logic [31:0]    pwdata,
  input  logic [3:0]     pstrb,
  input  logic [2:0]     pprot,
  output logic [31:0]    prdata,
  output logic           pready,
  output logic           pslverr,
  // AXI4 master
  output logic [IDW-1:0] m_awid,
  output logic [31:0]    m_awaddr,
  output logic [7:0]     m_awlen,
  output logic [2:0]     m_awsize,
  output logic [1:0]     m_awburst,
  output logic [2:0]     m_awprot,
  output logic           m_awvalid,
  input  logic           m_awready,
  output logic [31:0]    m_wdata,
  output logic [3:0]     m_wstrb,
  output logic           m_wlast,
  output logic           m_wvalid,
  input  logic           m_wready,
  input  logic [IDW-1:0] m_bid,
  input  logic [1:0]     m_bresp,
  input  logic           m_bvalid,
  output logic           m_bready,
  output logic [IDW-1:0] m_arid,
  output logic [31:0]    m_araddr,
  output logic [7:0]     m_arlen,
  output logic [2:0]     m_arsize,
  output logic [1:0]     m_arburst,
  output logic [2:0]     m_arprot,
  output logic           m_arvalid,
  input  logic           m_arready,
  input  logic [IDW-1:0] m_rid,
  input  logic [31:0]    m_rdata,
  input  logic [1:0]     m_rresp,
  input  logic           m_rlast,
  input  logic           m_rvalid,
  output logic           m_rready
);
  typedef enum logic [2:0] {IDLE, WR, WB, RA, RR, DONE} st_t;
  st_t st;
  logic aw_ok, w_ok, err_q;
  logic [31:0] rdata_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; aw_ok <= 1'b0; w_ok <= 1'b0; err_q <= 1'b0; rdata_q <= '0;
    end else case (st)
      IDLE: if (psel && penable) begin            // ACCESS phase
        aw_ok <= 1'b0; w_ok <= 1'b0;
        st <= pwrite ? WR : RA;
      end
      WR: begin
        if (m_awvalid && m_awready) aw_ok <= 1'b1;
        if (m_wvalid && m_wready)   w_ok  <= 1'b1;
        if ((aw_ok || m_awready) && (w_ok || m_wready)) st <= WB;
      end
      WB: if (m_bvalid) begin err_q <= m_bresp[1]; st <= DONE; end
      RA: if (m_arready) st <= RR;
      RR: if (m_rvalid) begin err_q <= m_rresp[1]; rdata_q <= m_rdata; st <= DONE; end
      DONE: st <= IDLE;                            // PREADY high this cycle
      default: st <= IDLE;
    endcase
  end

  always_comb begin
    pready    = (st == DONE);
    pslverr   = (st == DONE) && err_q;
    prdata    = rdata_q;
    m_awid    = '0;
    m_awaddr  = paddr;
    m_awlen   = 8'd0;
    m_awsize  = 3'd2;
    m_awburst = 2'b01;
    m_awprot  = pprot;
    m_awvalid = (st == WR) && !aw_ok;
    m_wdata   = pwdata;
    m_wstrb   = pstrb;
    m_wlast   = 1'b1;
    m_wvalid  = (st == WR) && !w_ok;
    m_bready  = (st == WB);
    m_arid    = '0;
    m_araddr  = paddr;
    m_arlen   = 8'd0;
    m_arsize  = 3'd2;
    m_arburst = 2'b01;
    m_arprot  = pprot;
    m_arvalid = (st == RA);
    m_rready  = (st == RR);
  end
endmodule
