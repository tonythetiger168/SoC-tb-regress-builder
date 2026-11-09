// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_d2d_phy -- behavioural die-to-die physical layer between two UCIe
// adapters (UCIe_top): main band and sideband in each direction, DELAY
// clocks each way, link always up.
// ----------------------------------------------------------------------------
// Simulation only: +D2D_ERR_EVERY=<n> flips one bit of every n-th main-band
// flit from die 0 to die 1 (and of every n-th one back), so the adapters'
// CRC check and Retry (Nak, replay) are exercised. 0 (default): no errors.
// ============================================================================
module noc_d2d_phy #(
  parameter int DELAY = 4                 // clocks, >= 1
)(
  input  logic         clk,
  input  logic         rst_n,
  // die 0 adapter
  input  logic         a_lt_valid,
  input  logic [543:0] a_lt_flit,
  output logic         a_lr_valid,
  output logic [543:0] a_lr_flit,
  input  logic         a_sb_tx_valid,
  input  logic [15:0]  a_sb_tx_msg,
  output logic         a_sb_rx_valid,
  output logic [15:0]  a_sb_rx_msg,
  // die 1 adapter
  input  logic         b_lt_valid,
  input  logic [543:0] b_lt_flit,
  output logic         b_lr_valid,
  output logic [543:0] b_lr_flit,
  input  logic         b_sb_tx_valid,
  input  logic [15:0]  b_sb_tx_msg,
  output logic         b_sb_rx_valid,
  output logic [15:0]  b_sb_rx_msg,
  // flits corrupted so far (simulation error injection)
  output logic [31:0]  n_err
);
  logic         ab_v  [DELAY], ba_v  [DELAY], abs_v [DELAY], bas_v [DELAY];
  logic [543:0] ab_f  [DELAY], ba_f  [DELAY];
  logic [15:0]  abs_m [DELAY], bas_m [DELAY];
  int unsigned  every = 0, n_ab = 0, n_ba = 0;

  // synopsys translate_off
  initial void'($value$plusargs("D2D_ERR_EVERY=%d", every));
  // synopsys translate_on

  function automatic logic [543:0] hit(logic [543:0] f, int unsigned n);
    return (every != 0 && n % every == every - 1) ? f ^ (544'd1 << (100 + n % 300)) : f;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DELAY; i++) begin
        ab_v[i] <= 1'b0; ba_v[i] <= 1'b0; abs_v[i] <= 1'b0; bas_v[i] <= 1'b0;
        ab_f[i] <= '0; ba_f[i] <= '0; abs_m[i] <= '0; bas_m[i] <= '0;
      end
      n_err <= '0;
    end else begin
      ab_v[0] <= a_lt_valid; ab_f[0] <= a_lt_valid ? hit(a_lt_flit, n_ab) : a_lt_flit;
      ba_v[0] <= b_lt_valid; ba_f[0] <= b_lt_valid ? hit(b_lt_flit, n_ba) : b_lt_flit;
      if (a_lt_valid) begin
        n_ab <= n_ab + 1;
        if (every != 0 && n_ab % every == every - 1) n_err <= n_err + 1;
      end
      if (b_lt_valid) begin
        n_ba <= n_ba + 1;
        if (every != 0 && n_ba % every == every - 1) n_err <= n_err + 1;
      end
      abs_v[0] <= a_sb_tx_valid; abs_m[0] <= a_sb_tx_msg;
      bas_v[0] <= b_sb_tx_valid; bas_m[0] <= b_sb_tx_msg;
      for (int i = 1; i < DELAY; i++) begin
        ab_v[i] <= ab_v[i-1];   ab_f[i] <= ab_f[i-1];
        ba_v[i] <= ba_v[i-1];   ba_f[i] <= ba_f[i-1];
        abs_v[i] <= abs_v[i-1]; abs_m[i] <= abs_m[i-1];
        bas_v[i] <= bas_v[i-1]; bas_m[i] <= bas_m[i-1];
      end
    end
  end

  assign b_lr_valid    = ab_v[DELAY-1];
  assign b_lr_flit     = ab_f[DELAY-1];
  assign a_lr_valid    = ba_v[DELAY-1];
  assign a_lr_flit     = ba_f[DELAY-1];
  assign b_sb_rx_valid = abs_v[DELAY-1];
  assign b_sb_rx_msg   = abs_m[DELAY-1];
  assign a_sb_rx_valid = bas_v[DELAY-1];
  assign a_sb_rx_msg   = bas_m[DELAY-1];
endmodule
