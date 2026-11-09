// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_ahb2axi -- AHB-Lite slave to AXI4 master (32-bit data)
// ----------------------------------------------------------------------------
//  * Used on a NoC master port whose master speaks AHB-Lite (the AHB master
//    -> this -> the master NI), and on a NoC slave port's test shim.
//  * Every NONSEQ / SEQ transfer becomes one single-beat AXI transfer
//    (ID 0, AxLEN 0, AxSIZE = HSIZE, INCR); BUSY and IDLE are ignored. The
//    data phase holds HREADYOUT low until the AXI response is back, so an
//    AHB burst runs as a series of single transfers.
//  * WSTRB covers the HSIZE bytes at HADDR. SLVERR / DECERR give the
//    two-cycle AHB ERROR response.
// ============================================================================
module noc_ahb2axi #(
  parameter int IDW = 4
)(
  input  logic           clk,
  input  logic           rst_n,
  // AHB-Lite slave
  input  logic           hsel,
  input  logic [31:0]    haddr,
  input  logic [1:0]     htrans,
  input  logic           hwrite,
  input  logic [2:0]     hsize,
  input  logic [2:0]     hburst,
  input  logic [3:0]     hprot,
  input  logic [31:0]    hwdata,
  input  logic           hready,
  output logic [31:0]    hrdata,
  output logic           hreadyout,
  output logic           hresp,
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
  // IDLE: no data phase, or the last cycle of one (HREADYOUT high; with
  // err_q set it is the second ERROR cycle). WR: AW and W out (HWDATA is
  // held by the master for the whole data phase). WB: wait B. RA: AR out.
  // RR: wait R. ERR1: first ERROR cycle (HREADYOUT low, HRESP high).
  typedef enum logic [2:0] {IDLE, WR, WB, RA, RR, ERR1} st_t;
  st_t st;

  logic [31:0] addr_q, rdata_q;
  logic [2:0]  size_q, prot_q;
  logic        aw_ok, w_ok, err_q;

  wire cap = hsel && hready && htrans[1];          // address phase accepted

  function automatic logic [3:0] strb_of(logic [1:0] a, logic [2:0] s);
    case (s)
      3'd0:    return 4'b0001 << a;
      3'd1:    return a[1] ? 4'b1100 : 4'b0011;
      default: return 4'b1111;
    endcase
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; addr_q <= '0; rdata_q <= '0; size_q <= '0; prot_q <= '0;
      aw_ok <= 1'b0; w_ok <= 1'b0; err_q <= 1'b0;
    end else begin
      case (st)
        IDLE: begin
          err_q <= 1'b0;
          if (cap) begin
            addr_q <= haddr; size_q <= hsize;
            prot_q <= {!hprot[0], 1'b0, hprot[1]};   // instr/data, secure, privileged
            aw_ok <= 1'b0; w_ok <= 1'b0;
            st <= hwrite ? WR : RA;
          end
        end
        WR: begin
          if (m_awvalid && m_awready) aw_ok <= 1'b1;
          if (m_wvalid && m_wready)   w_ok  <= 1'b1;
          if ((aw_ok || m_awready) && (w_ok || m_wready)) st <= WB;
        end
        WB: if (m_bvalid) begin
          if (m_bresp[1]) st <= ERR1;
          else            st <= IDLE;
        end
        RA: if (m_arready) st <= RR;
        RR: if (m_rvalid) begin
          rdata_q <= m_rdata;
          if (m_rresp[1]) st <= ERR1;
          else            st <= IDLE;
        end
        ERR1: begin err_q <= 1'b1; st <= IDLE; end
        default: st <= IDLE;
      endcase
    end
  end

  always_comb begin
    // data phase ends in IDLE (okay or 2nd error cycle); low while busy
    hreadyout = (st == IDLE);
    hresp     = (st == ERR1) || (st == IDLE && err_q);
    hrdata    = rdata_q;
    m_awid    = '0;
    m_awaddr  = addr_q;
    m_awlen   = 8'd0;
    m_awsize  = size_q;
    m_awburst = 2'b01;
    m_awprot  = prot_q;
    m_awvalid = (st == WR) && !aw_ok;
    m_wdata   = hwdata;
    m_wstrb   = strb_of(addr_q[1:0], size_q);
    m_wlast   = 1'b1;
    m_wvalid  = (st == WR) && !w_ok;
    m_bready  = (st == WB);
    m_arid    = '0;
    m_araddr  = addr_q;
    m_arlen   = 8'd0;
    m_arsize  = size_q;
    m_arburst = 2'b01;
    m_arprot  = prot_q;
    m_arvalid = (st == RA);
    m_rready  = (st == RR);
  end
endmodule
