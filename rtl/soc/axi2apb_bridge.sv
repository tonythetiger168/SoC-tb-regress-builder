// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axi2apb_bridge -- AXI4 slave to APB4 master bridge (32-bit data)
// ----------------------------------------------------------------------------
//  * One AXI burst at a time; reads and writes alternate when both wait.
//  * Each AXI beat becomes one APB transfer (SETUP, ACCESS, wait for PREADY).
//    FIXED, INCR and WRAP bursts are supported; WSTRB drives PSTRB.
//  * Write response: SLVERR if any beat saw PSLVERR. Read response per beat:
//    SLVERR when that beat saw PSLVERR. PRDATA is returned unmodified.
//  * The PROT of the AXI request is forwarded on PPROT.
// ============================================================================
module axi2apb_bridge #(
  parameter int IDW = 5
)(
  input  logic           clk,
  input  logic           rst_n,
  // AXI4 slave
  input  logic [IDW-1:0] awid,
  input  logic [31:0]    awaddr,
  input  logic [7:0]     awlen,
  input  logic [2:0]     awsize,
  input  logic [1:0]     awburst,
  input  logic [2:0]     awprot,
  input  logic           awvalid,
  output logic           awready,
  input  logic [31:0]    wdata,
  input  logic [3:0]     wstrb,
  input  logic           wlast,
  input  logic           wvalid,
  output logic           wready,
  output logic [IDW-1:0] bid,
  output logic [1:0]     bresp,
  output logic           bvalid,
  input  logic           bready,
  input  logic [IDW-1:0] arid,
  input  logic [31:0]    araddr,
  input  logic [7:0]     arlen,
  input  logic [2:0]     arsize,
  input  logic [1:0]     arburst,
  input  logic [2:0]     arprot,
  input  logic           arvalid,
  output logic           arready,
  output logic [IDW-1:0] rid,
  output logic [31:0]    rdata,
  output logic [1:0]     rresp,
  output logic           rlast,
  output logic           rvalid,
  input  logic           rready,
  // APB4 master
  output logic [31:0]    paddr,
  output logic           psel,
  output logic           penable,
  output logic           pwrite,
  output logic [31:0]    pwdata,
  output logic [3:0]     pstrb,
  output logic [2:0]     pprot,
  input  logic [31:0]    prdata,
  input  logic           pready,
  input  logic           pslverr
);

  typedef enum logic [2:0] {IDLE, WDATA, SETUP, ACCESS, BRESP, RDATA} st_t;
  st_t st;

  logic           is_wr;
  logic [IDW-1:0] id_q;
  logic [31:0]    addr_q, start_q;
  logic [7:0]     len_q, beat_q;
  logic [2:0]     size_q;
  logic [1:0]     burst_q;
  logic [2:0]     prot_q;
  logic [31:0]    wdata_q, rdata_q;
  logic [3:0]     wstrb_q;
  logic           err_q;       // sticky write error / current read beat error
  logic           last_rd;     // last transfer direction was a read (fairness)

  // next beat address (AXI4 A3.4.1)
  function automatic logic [31:0] next_addr(input logic [31:0] a, input logic [31:0] start,
                                            input logic [2:0] size, input logic [1:0] burst,
                                            input logic [7:0] len);
    logic [31:0] nb, aligned, wsize, wbase;
    nb      = 32'd1 << size;
    aligned = a & ~(nb - 32'd1);
    case (burst)
      2'b00:   next_addr = a;                         // FIXED
      2'b10: begin                                    // WRAP
        wsize = nb * (32'(len) + 32'd1);
        wbase = start & ~(wsize - 32'd1);
        next_addr = aligned + nb;
        if (next_addr >= wbase + wsize) next_addr = wbase;
      end
      default: next_addr = aligned + nb;              // INCR
    endcase
  endfunction

  wire take_wr = awvalid && (!arvalid || last_rd);
  wire take_rd = arvalid && !take_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; is_wr <= 1'b0; id_q <= '0; addr_q <= '0; start_q <= '0;
      len_q <= '0; beat_q <= '0; size_q <= '0; burst_q <= '0; prot_q <= '0;
      wdata_q <= '0; wstrb_q <= '0; rdata_q <= '0; err_q <= 1'b0; last_rd <= 1'b0;
    end else begin
      case (st)
        IDLE: begin
          if (take_wr) begin
            is_wr <= 1'b1; id_q <= awid; addr_q <= awaddr; start_q <= awaddr;
            len_q <= awlen; size_q <= awsize; burst_q <= awburst; prot_q <= awprot;
            beat_q <= 8'd0; err_q <= 1'b0; last_rd <= 1'b0;
            st <= WDATA;
          end else if (take_rd) begin
            is_wr <= 1'b0; id_q <= arid; addr_q <= araddr; start_q <= araddr;
            len_q <= arlen; size_q <= arsize; burst_q <= arburst; prot_q <= arprot;
            beat_q <= 8'd0; err_q <= 1'b0; last_rd <= 1'b1;
            st <= SETUP;
          end
        end
        WDATA: if (wvalid) begin
          wdata_q <= wdata; wstrb_q <= wstrb;
          st <= SETUP;
        end
        SETUP: st <= ACCESS;
        ACCESS: if (pready) begin
          if (is_wr) begin
            err_q <= err_q | pslverr;
            if (beat_q == len_q) st <= BRESP;
            else begin
              beat_q <= beat_q + 8'd1;
              addr_q <= next_addr(addr_q, start_q, size_q, burst_q, len_q);
              st <= WDATA;
            end
          end else begin
            rdata_q <= prdata;
            err_q   <= pslverr;
            st      <= RDATA;
          end
        end
        BRESP: if (bready) st <= IDLE;
        RDATA: if (rready) begin
          if (beat_q == len_q) st <= IDLE;
          else begin
            beat_q <= beat_q + 8'd1;
            addr_q <= next_addr(addr_q, start_q, size_q, burst_q, len_q);
            st <= SETUP;
          end
        end
        default: st <= IDLE;
      endcase
    end
  end

  always_comb begin
    awready = (st == IDLE) && take_wr;
    arready = (st == IDLE) && take_rd;
    wready  = (st == WDATA);
    bvalid  = (st == BRESP);
    bid     = id_q;
    bresp   = err_q ? 2'b10 : 2'b00;
    rvalid  = (st == RDATA);
    rid     = id_q;
    rdata   = rdata_q;
    rresp   = err_q ? 2'b10 : 2'b00;
    rlast   = (st == RDATA) && (beat_q == len_q);
    psel    = (st == SETUP) || (st == ACCESS);
    penable = (st == ACCESS);
    paddr   = addr_q;
    pwrite  = is_wr;
    pwdata  = is_wr ? wdata_q : 32'h0;
    pstrb   = is_wr ? wstrb_q : 4'h0;
    pprot   = prot_q;
  end

  // WLAST must mark the final beat; the bridge counts beats from AWLEN and
  // ignores WLAST, so a mismatch is only flagged in simulation.
  // synthesis translate_off
  always @(posedge clk)
    if (rst_n && st == WDATA && wvalid && (wlast != (beat_q == len_q)))
      $display("%t axi2apb_bridge: WLAST mismatch on beat %0d of %0d", $time, beat_q, len_q);
  // synthesis translate_on
endmodule
