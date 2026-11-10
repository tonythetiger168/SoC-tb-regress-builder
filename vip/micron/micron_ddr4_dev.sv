// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// micron_ddr4_dev: Micron DDR4 SDRAM model behind ddr4_dev_model's pins
// ----------------------------------------------------------------------------
// Compiled only with +define+MICRON_DDR4 (scripts/fetch_micron_models.sh
// writes ext/micron/micron.f with the define and Micron's files). The
// Micron files are license restricted: they are fetched at build time and
// never committed to this repository.
//
// UNVERIFIED until the model files are available: the interface and parameter
// names below follow Micron's DDR4 model package (DDR4_if, ddr4_model,
// arch_package) as other vendors' example designs use it. Adjust the
// MICRON_DDR4_* macros if the downloaded version differs. Micron's DQ / DQS
// / DM_n are interface wires; they are joined to the pins with `alias`
// (no tran, which Verilator does not support).
// ============================================================================
`timescale 1ps/1ps
`ifndef MICRON_DDR4_DENSITY
  `define MICRON_DDR4_DENSITY _8G
`endif
module micron_ddr4_dev #(
  parameter int TCK_PS = 628
)(
  input  logic        ck_t,
  input  logic        ck_c,
  input  logic        reset_n,
  input  logic        cke,
  input  logic        odt,
  input  logic        cs_n,
  input  logic        act_n,
  input  logic        ras_n_a16,
  input  logic        cas_n_a15,
  input  logic        we_n_a14,
  input  logic [1:0]  bg,
  input  logic [1:0]  ba,
  input  logic [13:0] a,
  inout  wire  [15:0] dq,
  inout  wire  [1:0]  dqs_t,
  inout  wire  [1:0]  dqs_c,
  inout  wire  [1:0]  dm_n
);
  import arch_package::*;
  int unsigned ERRORS = 0;          // Micron reports its own violations in the log

  DDR4_if #(.CONFIGURED_DQ_BITS(16)) iDDR4 ();
  assign iDDR4.CK        = {ck_t, ck_c};      // CK[1] = CK_t, CK[0] = CK_c
  assign iDDR4.RESET_n   = reset_n;
  assign iDDR4.CKE       = cke;
  assign iDDR4.ODT       = odt;
  assign iDDR4.CS_n      = cs_n;
  assign iDDR4.ACT_n     = act_n;
  assign iDDR4.RAS_n_A16 = ras_n_a16;
  assign iDDR4.CAS_n_A15 = cas_n_a15;
  assign iDDR4.WE_n_A14  = we_n_a14;
  assign iDDR4.BG        = bg[0];             // x16: one bank-group bit
  assign iDDR4.BA        = ba;
  assign iDDR4.ADDR      = a;
  assign iDDR4.ADDR_17   = 1'b0;
  assign iDDR4.C         = '0;
  assign iDDR4.PARITY    = 1'b0;
  assign iDDR4.TEN       = 1'b0;
  assign iDDR4.ZQ        = 1'b1;
  assign iDDR4.PWR       = 1'b1;
  assign iDDR4.VREF_CA   = 1'b1;
  assign iDDR4.VREF_DQ   = 1'b1;
  alias dq    = iDDR4.DQ;
  alias dqs_t = iDDR4.DQS_t;
  alias dqs_c = iDDR4.DQS_c;
  alias dm_n  = iDDR4.DM_n;

  ddr4_model #(
    .CONFIGURED_DQ_BITS(16),
    .CONFIGURED_DENSITY(`MICRON_DDR4_DENSITY)
  ) u_model (
    .model_enable(1'b1),
    .iDDR4(iDDR4)
  );
endmodule
