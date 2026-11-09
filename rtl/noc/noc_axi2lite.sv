// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_axi2lite -- AXI4 slave (bursts) to AXI4-Lite master (32-bit data)
// ----------------------------------------------------------------------------
//  * Used on a NoC slave port whose slave speaks AXI4-Lite, and on a NoC
//    master port's test shim (AXI4 VIP -> this -> the NoC's AXI4-Lite port).
//  * One burst at a time; reads and writes alternate when both wait. Each
//    beat becomes one AXI4-Lite transfer (FIXED / INCR / WRAP addresses).
//  * Write response: the worst BRESP of the beats. Read: RRESP per beat.
// ============================================================================
module noc_axi2lite #(
  parameter int IDW = 4
)(
  input  logic           clk,
  input  logic           rst_n,
  // AXI4 slave
  input  logic [IDW-1:0] s_awid,
  input  logic [31:0]    s_awaddr,
  input  logic [7:0]     s_awlen,
  input  logic [2:0]     s_awsize,
  input  logic [1:0]     s_awburst,
  input  logic [2:0]     s_awprot,
  input  logic           s_awvalid,
  output logic           s_awready,
  input  logic [31:0]    s_wdata,
  input  logic [3:0]     s_wstrb,
  input  logic           s_wlast,
  input  logic           s_wvalid,
  output logic           s_wready,
  output logic [IDW-1:0] s_bid,
  output logic [1:0]     s_bresp,
  output logic           s_bvalid,
  input  logic           s_bready,
  input  logic [IDW-1:0] s_arid,
  input  logic [31:0]    s_araddr,
  input  logic [7:0]     s_arlen,
  input  logic [2:0]     s_arsize,
  input  logic [1:0]     s_arburst,
  input  logic [2:0]     s_arprot,
  input  logic           s_arvalid,
  output logic           s_arready,
  output logic [IDW-1:0] s_rid,
  output logic [31:0]    s_rdata,
  output logic [1:0]     s_rresp,
  output logic           s_rlast,
  output logic           s_rvalid,
  input  logic           s_rready,
  // AXI4-Lite master
  output logic [31:0]    m_awaddr,
  output logic [2:0]     m_awprot,
  output logic           m_awvalid,
  input  logic           m_awready,
  output logic [31:0]    m_wdata,
  output logic [3:0]     m_wstrb,
  output logic           m_wvalid,
  input  logic           m_wready,
  input  logic [1:0]     m_bresp,
  input  logic           m_bvalid,
  output logic           m_bready,
  output logic [31:0]    m_araddr,
  output logic [2:0]     m_arprot,
  output logic           m_arvalid,
  input  logic           m_arready,
  input  logic [31:0]    m_rdata,
  input  logic [1:0]     m_rresp,
  input  logic           m_rvalid,
  output logic           m_rready
);
  typedef enum logic [2:0] {IDLE, WDATA, WADDR, WRESP, BRESP, RADDR, RRESP, RDATA} st_t;
  st_t st;

  logic           is_wr, aw_ok, w_ok, last_rd;
  logic [IDW-1:0] id_q;
  logic [31:0]    addr_q, start_q, wdata_q, rdata_q;
  logic [3:0]     wstrb_q;
  logic [7:0]     len_q, beat_q;
  logic [2:0]     size_q, prot_q;
  logic [1:0]     burst_q, resp_q, rresp_q;

  function automatic logic [31:0] next_addr(logic [31:0] a, logic [31:0] start, logic [2:0] size,
                                            logic [1:0] burst, logic [7:0] len);
    logic [31:0] nb, aligned, wsize, wbase, n;
    nb      = 32'd1 << size;
    aligned = a & ~(nb - 32'd1);
    case (burst)
      2'b00: return a;
      2'b10: begin
        wsize = nb * (32'(len) + 32'd1);
        wbase = start & ~(wsize - 32'd1);
        n = aligned + nb;
        return (n >= wbase + wsize) ? wbase : n;
      end
      default: return aligned + nb;
    endcase
  endfunction

  wire take_wr = s_awvalid && (!s_arvalid || last_rd);
  wire take_rd = s_arvalid && !take_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; is_wr <= 1'b0; aw_ok <= 1'b0; w_ok <= 1'b0; last_rd <= 1'b0;
      id_q <= '0; addr_q <= '0; start_q <= '0; wdata_q <= '0; rdata_q <= '0; wstrb_q <= '0;
      len_q <= '0; beat_q <= '0; size_q <= '0; prot_q <= '0; burst_q <= '0; resp_q <= '0; rresp_q <= '0;
    end else begin
      case (st)
        IDLE: if (take_wr) begin
          is_wr <= 1'b1; id_q <= s_awid; addr_q <= s_awaddr; start_q <= s_awaddr; len_q <= s_awlen;
          size_q <= s_awsize; burst_q <= s_awburst; prot_q <= s_awprot; beat_q <= '0; resp_q <= 2'b00;
          last_rd <= 1'b0; st <= WDATA;
        end else if (take_rd) begin
          is_wr <= 1'b0; id_q <= s_arid; addr_q <= s_araddr; start_q <= s_araddr; len_q <= s_arlen;
          size_q <= s_arsize; burst_q <= s_arburst; prot_q <= s_arprot; beat_q <= '0;
          last_rd <= 1'b1; st <= RADDR;
        end
        WDATA: if (s_wvalid) begin
          wdata_q <= s_wdata; wstrb_q <= s_wstrb; aw_ok <= 1'b0; w_ok <= 1'b0; st <= WADDR;
        end
        WADDR: begin                          // AW and W may complete in either order
          if (m_awvalid && m_awready) aw_ok <= 1'b1;
          if (m_wvalid && m_wready)   w_ok  <= 1'b1;
          if ((aw_ok || m_awready) && (w_ok || m_wready)) st <= WRESP;
        end
        WRESP: if (m_bvalid) begin
          if (m_bresp > resp_q) resp_q <= m_bresp;
          if (beat_q == len_q) st <= BRESP;
          else begin
            beat_q <= beat_q + 8'd1;
            addr_q <= next_addr(addr_q, start_q, size_q, burst_q, len_q);
            st <= WDATA;
          end
        end
        BRESP: if (s_bready) st <= IDLE;
        RADDR: if (m_arready) st <= RRESP;
        RRESP: if (m_rvalid) begin rdata_q <= m_rdata; rresp_q <= m_rresp; st <= RDATA; end
        RDATA: if (s_rready) begin
          if (beat_q == len_q) st <= IDLE;
          else begin
            beat_q <= beat_q + 8'd1;
            addr_q <= next_addr(addr_q, start_q, size_q, burst_q, len_q);
            st <= RADDR;
          end
        end
        default: st <= IDLE;
      endcase
    end
  end

  always_comb begin
    s_awready = (st == IDLE) && take_wr;
    s_arready = (st == IDLE) && take_rd;
    s_wready  = (st == WDATA);
    s_bvalid  = (st == BRESP);
    s_bid     = id_q;
    s_bresp   = resp_q;
    s_rvalid  = (st == RDATA);
    s_rid     = id_q;
    s_rdata   = rdata_q;
    s_rresp   = rresp_q;
    s_rlast   = (beat_q == len_q);
    m_awaddr  = addr_q;
    m_awprot  = prot_q;
    m_awvalid = (st == WADDR) && !aw_ok;
    m_wdata   = wdata_q;
    m_wstrb   = wstrb_q;
    m_wvalid  = (st == WADDR) && !w_ok;
    m_bready  = (st == WRESP);
    m_araddr  = addr_q;
    m_arprot  = prot_q;
    m_arvalid = (st == RADDR);
    m_rready  = (st == RRESP);
  end
endmodule
