// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_axi2apb -- AXI4 subordinate port to one APB4 completer
// ----------------------------------------------------------------------------
// For a register block behind a slave NI (the xuanji NPU subsystem's
// npu_ss_regs at S_NPUR). Each AXI beat becomes one APB transfer (INCR
// addresses step by 4; PADDR is the low AW bits); writes and reads are served
// one at a time, a pending write first. PSLVERR -> SLVERR; a burst's BRESP is
// the worst of its beats.
// ============================================================================
module tv8k_axi2apb #(
  parameter int AW = 12
)(
  input  logic          clk,
  input  logic          rst_n,
  // AXI4 subordinate
  input  logic [3:0]    s_awid,
  input  logic [31:0]   s_awaddr,
  input  logic [7:0]    s_awlen,
  input  logic          s_awvalid,
  output logic          s_awready,
  input  logic [31:0]   s_wdata,
  input  logic [3:0]    s_wstrb,
  input  logic          s_wlast,
  input  logic          s_wvalid,
  output logic          s_wready,
  output logic [3:0]    s_bid,
  output logic [1:0]    s_bresp,
  output logic          s_bvalid,
  input  logic          s_bready,
  input  logic [3:0]    s_arid,
  input  logic [31:0]   s_araddr,
  input  logic [7:0]    s_arlen,
  input  logic          s_arvalid,
  output logic          s_arready,
  output logic [3:0]    s_rid,
  output logic [31:0]   s_rdata,
  output logic [1:0]    s_rresp,
  output logic          s_rlast,
  output logic          s_rvalid,
  input  logic          s_rready,
  // APB4 requester
  output logic          psel,
  output logic          penable,
  output logic          pwrite,
  output logic [AW-1:0] paddr,
  output logic [31:0]   pwdata,
  output logic [3:0]    pstrb,
  input  logic          pready,
  input  logic [31:0]   prdata,
  input  logic          pslverr
);
  typedef enum logic [2:0] {IDLE, W_DATA, SETUP, ACCESS, B_RESP, R_BEAT} st_t;
  st_t         st;
  logic        wr;                         // current burst is a write
  logic [31:0] addr;
  logic [7:0]  left;
  logic [3:0]  id;
  logic [1:0]  resp;
  logic [31:0] d;
  logic [3:0]  strb;

  assign s_awready = (st == IDLE);
  assign s_arready = (st == IDLE) && !s_awvalid;      // a pending write goes first
  assign s_wready  = (st == W_DATA);
  assign s_bvalid  = (st == B_RESP);
  assign s_bid     = id;
  assign s_bresp   = resp;
  assign s_rvalid  = (st == R_BEAT);
  assign s_rid     = id;
  assign s_rdata   = d;
  assign s_rresp   = resp;
  assign s_rlast   = (left == 0);

  assign psel    = (st == SETUP) || (st == ACCESS);
  assign penable = (st == ACCESS);
  assign pwrite  = wr;
  assign paddr   = AW'(addr);
  assign pwdata  = d;
  assign pstrb   = wr ? strb : 4'h0;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st <= IDLE; wr <= 1'b0; addr <= '0; left <= '0; id <= '0; resp <= '0; d <= '0; strb <= '0;
    end else case (st)
      IDLE:
        if (s_awvalid) begin
          wr <= 1'b1; addr <= s_awaddr; left <= s_awlen; id <= s_awid; resp <= 2'b00; st <= W_DATA;
        end else if (s_arvalid) begin
          wr <= 1'b0; addr <= s_araddr; left <= s_arlen; id <= s_arid; st <= SETUP;
        end
      W_DATA: if (s_wvalid) begin d <= s_wdata; strb <= s_wstrb; st <= SETUP; end
      SETUP:  st <= ACCESS;
      ACCESS: if (pready) begin
        if (wr) begin
          if (pslverr) resp <= 2'b10;
          if (left == 0) st <= B_RESP;
          else begin left <= left - 8'd1; addr <= addr + 32'd4; st <= W_DATA; end
        end else begin
          d <= prdata; resp <= pslverr ? 2'b10 : 2'b00; st <= R_BEAT;
        end
      end
      B_RESP: if (s_bready) st <= IDLE;
      R_BEAT: if (s_rready) begin
        if (left == 0) st <= IDLE;
        else begin left <= left - 8'd1; addr <= addr + 32'd4; st <= SETUP; end
      end
      default: st <= IDLE;
    endcase
endmodule
