// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// axi4_pkg -- AXI4 UVM VIP: item, config, master driver, slave memory
// responder, monitor, coverage, latency
// recorder, agent, sequences. Interface: axi4_if.sv;
// protocol assertions: axi4_sva.sv.
// ============================================================================
`ifndef AXI4_PKG_SV
`define AXI4_PKG_SV
package axi4_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  // fcov_pkg / lat_pkg (vip/common) must be compiled before this package

  typedef enum bit [1:0] { AXI4_FIXED = 2'b00, AXI4_INCR = 2'b01, AXI4_WRAP = 2'b10 } axi4_burst_e;
  typedef enum bit [1:0] { AXI4_OKAY = 2'b00, AXI4_EXOKAY = 2'b01,
                           AXI4_SLVERR = 2'b10, AXI4_DECERR = 2'b11 } axi4_resp_e;
  typedef enum int { AXI4_MASTER = 0, AXI4_SLAVE = 1 } axi4_role_e;

  `include "axi4_item.svh"
  `include "axi4_cfg.svh"
  `include "axi4_master_driver.svh"
  `include "axi4_slave_driver.svh"
  `include "axi4_monitor.svh"
  `include "axi4_coverage.svh"
  `include "axi4_latency.svh"
  `include "axi4_agent.svh"
  `include "axi4_seq_lib.svh"
endpackage
`endif
