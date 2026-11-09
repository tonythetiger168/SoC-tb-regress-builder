// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_axi2ahb -- AXI4 slave (bursts) to AHB-Lite master (32-bit data)
// ----------------------------------------------------------------------------
//  * Used on a NoC slave port whose slave speaks AHB-Lite, and on a NoC
//    master port's test shim (AXI4 VIP -> this -> the NoC's AHB-Lite port).
//  * One burst at a time; reads and writes alternate when both wait. Each
//    beat becomes one NONSEQ SINGLE transfer (address phase, then a data
//    phase that ends when HREADY is high). HSIZE = AxSIZE, HADDR = the beat
//    address (FIXED / INCR / WRAP). AHB-Lite has no write strobes: a beat
//    writes the HSIZE bytes at HADDR, so a narrow write must use a narrow
//    AxSIZE (WSTRB is not looked at).
//  * HRESP = ERROR on a beat gives SLVERR (BRESP: any beat; RRESP: that beat).
// ============================================================================
module noc_axi2ahb #(
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
  // AHB-Lite master (single slave: HREADY in = the slave's HREADYOUT)
  output logic [31:0]    haddr,
  output logic [1:0]     htrans,
  output logic           hwrite,
  output logic [2:0]     hsize,
  output logic [2:0]     hburst,
  output logic [3:0]     hprot,
  output logic [31:0]    hwdata,
  input  logic [31:0]    hrdata,
  input  logic           hready,
  input  logic           hresp
);
  typedef enum logic [2:0] {IDLE, WDATA, ADDR, DATA, BRESP, RDATA} st_t;
  st_t st;

  logic           is_wr, last_rd;
  logic [IDW-1:0] id_q;
  logic [31:0]    addr_q, start_q, wdata_q, rdata_q;
  logic [7:0]     len_q, beat_q;
  logic [2:0]     size_q, prot_q;
  logic [1:0]     burst_q;
  logic           err_q;

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
      st <= IDLE; is_wr <= 1'b0; last_rd <= 1'b0; id_q <= '0; addr_q <= '0; start_q <= '0;
      wdata_q <= '0; rdata_q <= '0; len_q <= '0; beat_q <= '0; size_q <= '0; prot_q <= '0;
      burst_q <= '0; err_q <= 1'b0;
    end else begin
      case (st)
        IDLE: if (take_wr) begin
          is_wr <= 1'b1; id_q <= s_awid; addr_q <= s_awaddr; start_q <= s_awaddr; len_q <= s_awlen;
          size_q <= s_awsize; burst_q <= s_awburst; prot_q <= s_awprot; beat_q <= '0; err_q <= 1'b0;
          last_rd <= 1'b0; st <= WDATA;
        end else if (take_rd) begin
          is_wr <= 1'b0; id_q <= s_arid; addr_q <= s_araddr; start_q <= s_araddr; len_q <= s_arlen;
          size_q <= s_arsize; burst_q <= s_arburst; prot_q <= s_arprot; beat_q <= '0; err_q <= 1'b0;
          last_rd <= 1'b1; st <= ADDR;
        end
        WDATA: if (s_wvalid) begin wdata_q <= s_wdata; st <= ADDR; end
        ADDR:  if (hready) st <= DATA;          // address phase accepted
        DATA:  if (hready) begin                // data phase done
          if (is_wr) begin
            err_q <= err_q | hresp;
            if (beat_q == len_q) st <= BRESP;
            else begin
              beat_q <= beat_q + 8'd1;
              addr_q <= next_addr(addr_q, start_q, size_q, burst_q, len_q);
              st <= WDATA;
            end
          end else begin
            rdata_q <= hrdata; err_q <= hresp; st <= RDATA;
          end
        end
        BRESP: if (s_bready) st <= IDLE;
        RDATA: if (s_rready) begin
          if (beat_q == len_q) st <= IDLE;
          else begin
            beat_q <= beat_q + 8'd1;
            addr_q <= next_addr(addr_q, start_q, size_q, burst_q, len_q);
            st <= ADDR;
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
    s_bresp   = err_q ? 2'b10 : 2'b00;
    s_rvalid  = (st == RDATA);
    s_rid     = id_q;
    s_rdata   = rdata_q;
    s_rresp   = err_q ? 2'b10 : 2'b00;
    s_rlast   = (beat_q == len_q);
    haddr     = addr_q;
    htrans    = (st == ADDR) ? 2'b10 : 2'b00;   // NONSEQ / IDLE
    hwrite    = is_wr;
    hsize     = size_q;
    hburst    = 3'b000;                         // SINGLE
    hprot     = {1'b0, 1'b0, prot_q[0], !prot_q[2]};
    hwdata    = wdata_q;
  end
endmodule
