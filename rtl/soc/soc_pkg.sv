// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// soc_pkg -- AMBA SoC address map and shared constants
// ============================================================================
package soc_pkg;
  // AXI responses
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_EXOKAY = 2'b01;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // AXI slave indices on the interconnect (3 = internal default slave)
  localparam int S_SRAM = 0;
  localparam int S_APB  = 1;
  localparam int S_DDR  = 2;
  localparam int S_DEF  = 3;

  // ---- address map --------------------------------------------------------
  localparam logic [31:0] SRAM_BASE = 32'h0000_0000;  // 64 KB window, 1 KB SRAM
  localparam logic [31:0] SRAM_MASK = 32'hFFFF_0000;
  localparam int unsigned SRAM_BYTES = 1024;
  localparam logic [31:0] APB_BASE  = 32'h1000_0000;  // 64 KB window, 4 KB slots
  localparam logic [31:0] APB_MASK  = 32'hFFFF_0000;
  localparam logic [31:0] DDR_BASE  = 32'h8000_0000;  // 256 MB external memory
  localparam logic [31:0] DDR_MASK  = 32'hF000_0000;

  // APB slots inside the APB window (PADDR[15:12])
  localparam int APB_SLOT_GPIO = 0;   // open-ip GPIO_apb
  localparam int APB_SLOT_UART = 1;   // open-ip UART_apb
  localparam int APB_SLOT_EXT  = 2;   // external APB port (APB slave VIP)
  localparam int APB_NSLOTS    = 3;   // slots >= 3 answer PSLVERR

  function automatic logic [1:0] soc_decode(input logic [31:0] a);
    if ((a & SRAM_MASK) == SRAM_BASE) return 2'(S_SRAM);
    if ((a & APB_MASK)  == APB_BASE)  return 2'(S_APB);
    if ((a & DDR_MASK)  == DDR_BASE)  return 2'(S_DDR);
    return 2'(S_DEF);
  endfunction
endpackage
