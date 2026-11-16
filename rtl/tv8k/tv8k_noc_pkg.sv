// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tv8k_noc_pkg -- 8K TV SoC NoC: endpoints, placement, address map and the
// network-interface (NI) packet formats carried in router flits.
// ----------------------------------------------------------------------------
// The mesh is built from xuanji-core's orca_noc_router (5-port, XY routing,
// single-flit packets, 525-bit flit = orca_pkg::flit_t). tv8k_flit_t below has
// exactly the same bit layout, so the NIs do not depend on orca_pkg and an
// open router with the same ports can stand in when xuanji-core is not
// available.
//
// Every AXI burst is cut by the master-side NI into chunks of up to 8 32-bit
// words (32 bytes, one LPDDR5 BL16 x16 access). One chunk = one flit:
//   request  RD: header only            WR: header + 8 words + 32 strobes
//   response RD: 8 words + 8 RRESP      WR: BRESP
// Deadlock freedom is end-to-end: a master NI only issues a chunk when it has
// reserved the slot for its response, and a slave NI's request queue holds
// every chunk all masters can have outstanding, so both ends always eject.
// ============================================================================
package tv8k_noc_pkg;

  // ---------------- mesh ----------------
  localparam int MESH_X = 4;
  localparam int MESH_Y = 4;
  localparam int XB = 2, YB = 2;          // orca_pkg NOC_X_BITS / NOC_Y_BITS
  localparam int PAYLOAD_W = 512;         // orca_pkg NOC_DATA_WIDTH

  typedef enum logic [1:0] { FT_HEAD = 2'd0, FT_BODY = 2'd1, FT_TAIL = 2'd2, FT_SINGLE = 2'd3 } ftype_e;

  typedef struct packed {
    logic [PAYLOAD_W-1:0] payload;
    logic [XB-1:0]        dest_x;
    logic [YB-1:0]        dest_y;
    logic [XB-1:0]        src_x;
    logic [YB-1:0]        src_y;
    logic [1:0]           vc_id;
    ftype_e               ftype;
    logic                 valid;
  } tv8k_flit_t;                          // 525 bits, same layout as orca_pkg::flit_t
  localparam int FLIT_W = $bits(tv8k_flit_t);

  localparam logic [1:0] VC_REQ = 2'd0;
  localparam logic [1:0] VC_RSP = 2'd1;

  // ---------------- endpoints ----------------
  // masters 0..NM-1, then slaves
  localparam int NM = 12;
  localparam int M_CPU = 0, M_GPU = 1, M_NPU = 2, M_VDEC = 3, M_PQ = 4, M_DISP = 5,
                 M_HDMIRX = 6, M_TSD = 7, M_ADSP = 8, M_DMA = 9, M_SEC = 10, M_NETIO = 11;
  localparam int NDRAM = 8;
  localparam int S_DRAM0  = NM;                 // 12..19
  localparam int S_SRAM   = NM + NDRAM;         // 20
  localparam int S_APB    = S_SRAM + 1;         // 21
  localparam int S_VDECR  = S_SRAM + 2;         // 22 c1p decoder registers (AXI4-Lite)
  localparam int S_GPUR   = S_SRAM + 3;         // 23 OH-1 GPU registers (AXI4-Lite)
  localparam int S_NPUR   = S_SRAM + 4;         // 24 NPU subsystem registers (APB4, xuanji npu_ss_regs)
  localparam int NEP      = S_SRAM + 5;         // 25
  localparam int NS       = NEP - NM;           // 13
  localparam int EPB      = 5;                  // endpoint id width
  localparam logic [EPB-1:0] EP_NONE = '1;      // decode miss: DECERR from the master NI

  // node [x, y] of every endpoint (see socgen/specs/tv8k_soc.yaml)
  localparam int EP_X [NEP] = '{
    1, 2, 1, 2, 3, 3, 0, 0, 0, 1, 2, 3,        // cpu gpu npu vdec pq disp hdmirx tsd adsp dma sec netio
    0, 1, 2, 3, 0, 1, 2, 3,                    // dram0..7: y=0 row, then y=3 row
    1, 0, 2, 2, 1 };                           // boot_sram periph vdec_regs gpu_regs npu_regs
  localparam int EP_Y [NEP] = '{
    1, 1, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 3, 3, 3, 3,
    1, 2, 2, 1, 2 };

  function automatic string ep_name(int e);
    case (e)
      M_CPU: return "cpu";    M_GPU: return "gpu";     M_NPU: return "npu";   M_VDEC: return "vdec";
      M_PQ: return "pq";      M_DISP: return "disp";   M_HDMIRX: return "hdmirx"; M_TSD: return "tsd";
      M_ADSP: return "adsp";  M_DMA: return "dma";     M_SEC: return "sec";   M_NETIO: return "netio";
      S_SRAM: return "boot_sram"; S_APB: return "periph"; S_VDECR: return "vdec_regs"; S_GPUR: return "gpu_regs";
      S_NPUR: return "npu_regs";
      default: return (e >= S_DRAM0 && e < S_DRAM0 + NDRAM) ? $sformatf("dram%0d", e - S_DRAM0) : "none";
    endcase
  endfunction

  // ---------------- address map ----------------
  localparam logic [31:0] SRAM_BASE  = 32'h0000_0000, SRAM_MASK  = 32'hFFFF_0000;  // 64 KB
  localparam logic [31:0] APB_BASE   = 32'h1000_0000, APB_MASK   = 32'hFFFE_0000;  // 128 KB, 32 slots
  localparam logic [31:0] VDECR_BASE = 32'h1100_0000, VDECR_MASK = 32'hFFFF_0000;  // 64 KB
  localparam logic [31:0] GPUR_BASE  = 32'h1101_0000, GPUR_MASK  = 32'hFFFF_0000;  // 64 KB
  localparam logic [31:0] NPUR_BASE  = 32'h1102_0000, NPUR_MASK  = 32'hFFFF_0000;  // 64 KB (4 KB used)
  localparam logic [31:0] DRAM_BASE  = 32'h8000_0000, DRAM_MASK  = 32'h8000_0000;  // 2 GB
  localparam int GRAN_LOG2 = 12;                                                   // 4 KB interleave

  // DRAM channel: 3 bits above the granule, XOR-hashed with the next 3 bits
  function automatic logic [2:0] dram_channel(logic [31:0] a);
    return a[GRAN_LOG2 +: 3] ^ a[GRAN_LOG2 + 3 +: 3];
  endfunction

  function automatic logic [EPB-1:0] decode(logic [31:0] a);
    if ((a & DRAM_MASK)  == DRAM_BASE)  return EPB'(S_DRAM0 + int'(dram_channel(a)));
    if ((a & SRAM_MASK)  == SRAM_BASE)  return EPB'(S_SRAM);
    if ((a & APB_MASK)   == APB_BASE)   return EPB'(S_APB);
    if ((a & VDECR_MASK) == VDECR_BASE) return EPB'(S_VDECR);
    if ((a & GPUR_MASK)  == GPUR_BASE)  return EPB'(S_GPUR);
    if ((a & NPUR_MASK)  == NPUR_BASE)  return EPB'(S_NPUR);
    return EP_NONE;
  endfunction

  // ---------------- NI packet (flit payload) ----------------
  typedef enum logic [1:0] { OP_RD = 2'd0, OP_WR = 2'd1, OP_RDATA = 2'd2, OP_WRSP = 2'd3 } op_e;
  localparam int CW = 8;                  // 32-bit words per chunk
  localparam int TAGW = 6;                // master NI slot / burst tag

  typedef struct packed {
    op_e               op;
    logic [EPB-1:0]    dst_ep;
    logic [EPB-1:0]    src_ep;
    logic [TAGW-1:0]   tag;
    logic [31:0]       addr;              // first word address (requests)
    logic [2:0]        nm1;               // words - 1
    logic [2:0]        size;              // AxSIZE of each word access (<= 2)
    logic              fixed;             // FIXED burst (else INCR)
    logic [2:0]        prot;
    logic [1:0]        resp;              // WRSP: BRESP
    logic [CW-1:0][1:0]  rresp;           // RDATA: RRESP per word
    logic [CW-1:0][3:0]  strb;            // WR: WSTRB per word
    logic [CW-1:0][31:0] data;            // WR / RDATA
  } pkt_t;
  localparam int PKT_W = $bits(pkt_t);

  function automatic tv8k_flit_t mk_flit(pkt_t p, int src, logic [1:0] vc);
    tv8k_flit_t f;
    f = '0;
    f.payload = PAYLOAD_W'(p);
    f.dest_x  = XB'(EP_X[p.dst_ep]);
    f.dest_y  = YB'(EP_Y[p.dst_ep]);
    f.src_x   = XB'(EP_X[src]);
    f.src_y   = YB'(EP_Y[src]);
    f.vc_id   = vc;
    f.ftype   = FT_SINGLE;
    f.valid   = 1'b1;
    return f;
  endfunction

  function automatic pkt_t pkt_of(tv8k_flit_t f);
    return pkt_t'(f.payload[PKT_W-1:0]);
  endfunction
endpackage
