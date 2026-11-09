// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// apb_decoder -- one APB4 requester to N completers, 4 KB slots on PADDR[15:12]
// ----------------------------------------------------------------------------
// A slot number >= NSLOTS selects no completer: the decoder itself answers
// with PREADY=1, PSLVERR=1, PRDATA=0 (zero wait states).
// ============================================================================
module apb_decoder #(
  parameter int NSLOTS = 3
)(
  input  logic        psel,
  input  logic        penable,
  input  logic [31:0] paddr,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  output logic        s_psel    [NSLOTS],
  input  logic [31:0] s_prdata  [NSLOTS],
  input  logic        s_pready  [NSLOTS],
  input  logic        s_pslverr [NSLOTS]
);
  wire [3:0] slot = paddr[15:12];
  always_comb begin
    prdata  = 32'h0;
    pready  = 1'b1;
    pslverr = psel & penable;     // unmapped slot
    for (int i = 0; i < NSLOTS; i++) begin
      s_psel[i] = psel && (slot == 4'(i));
      if (slot == 4'(i)) begin
        prdata  = s_prdata[i];
        pready  = s_pready[i];
        pslverr = s_pslverr[i];
      end
    end
  end
endmodule
