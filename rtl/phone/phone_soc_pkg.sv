// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_soc_pkg -- phone SoC: masters, NoC mesh placement, address map,
// LPDDR5 channel interleaving, APB slots. Shared by the RTL and the testbench.
// ============================================================================
package phone_soc_pkg;
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // ---------------------------------------------------------------- masters
  // One AXI4 manager port per subsystem (generic names).
  localparam int NM = 15;
  localparam int M_CPU   = 0;   // CPU cluster (big.LITTLE behind its DSU / L3)
  localparam int M_GPU   = 1;   // GPU (own MMU, not modeled)
  localparam int M_APU   = 2;   // AI processing unit / NPU          (IOMMU 0)
  localparam int M_ISP   = 3;   // camera image signal processor     (IOMMU 1)
  localparam int M_ICP   = 4;   // camera control processor          (IOMMU 2)
  localparam int M_VDEC  = 5;   // video decoder                     (IOMMU 3)
  localparam int M_VENC  = 6;   // video encoder                     (IOMMU 4)
  localparam int M_DISP  = 7;   // display / MDP                     (IOMMU 5)
  localparam int M_ADSP  = 8;   // audio DSP
  localparam int M_MODEM = 9;   // cellular modem
  localparam int M_CONN  = 10;  // connectivity: WiFi / BT / GNSS
  localparam int M_SCP   = 11;  // sensor hub
  localparam int M_UFS   = 12;  // storage / IO: UFS host DMA
  localparam int M_SEC   = 13;  // security: crypto engine DMA
  localparam int M_DMA   = 14;  // system DMA / command engine

  localparam int NIOMMU = 6;
  // IOMMU index of a master, -1 when the master has none
  function automatic int iommu_of(int m);
    case (m)
      M_APU:  return 0;
      M_ISP:  return 1;
      M_ICP:  return 2;
      M_VDEC: return 3;
      M_VENC: return 4;
      M_DISP: return 5;
      default: return -1;
    endcase
  endfunction
  function automatic int master_of_iommu(int i);
    case (i)
      0: return M_APU;  1: return M_ISP;  2: return M_ICP;
      3: return M_VDEC; 4: return M_VENC; default: return M_DISP;
    endcase
  endfunction

  // ---------------------------------------------------------------- slaves
  localparam int NCH    = 32;          // LPDDR5 channel ports
  localparam int S_SRAM = NCH;         // 32: boot SRAM (open-ip AXI4_top)
  localparam int S_APB  = NCH + 1;     // 33: AXI-to-APB bridge (infra / peri)
  localparam int NS     = NCH + 2;     // AXI slave ports on the NoC
  localparam int S_DEF  = NS;          // 34: NoC default slave (DECERR)

  // ---------------------------------------------------------------- address map
  localparam logic [31:0] SRAM_BASE = 32'h0000_0000;   // 64 KB window, 1 KB SRAM
  localparam logic [31:0] APB_BASE  = 32'h1000_0000;   // 128 KB: two 64 KB segments of 16 x 4 KB slots
  localparam logic [31:0] APB_SS_BASE = 32'h1001_0000; // segment 1: subsystem IP registers (ss APB port)
  localparam logic [31:0] DRAM_BASE = 32'h8000_0000;   // 2 GB LPDDR5, 32 channels
  localparam int unsigned CH_BYTES  = 32'h0400_0000;   // 64 MB per channel

  // Channel interleaving: 4 KB granules (an AXI burst never crosses 4 KB, so a
  // burst always lands on one channel). ch = addr[16:12], XOR-folded with
  // addr[21:17] when INTLV_HASH is set so that power-of-two strides spread.
  localparam int INTLV_LSB  = 12;
  localparam int INTLV_BITS = 5;
  localparam bit INTLV_HASH = 1'b1;

  function automatic logic [4:0] dram_channel(logic [31:0] a);
    logic [4:0] ch;
    ch = a[16:12];
    if (INTLV_HASH) ch = ch ^ a[21:17];
    return ch;
  endfunction

  // address inside the channel (what the channel's controller sees): the
  // channel-select bits are squeezed out of the DRAM offset
  function automatic logic [31:0] dram_local(logic [31:0] a);
    logic [31:0] off;
    off = a - DRAM_BASE;
    return {6'b0, off[30:17], off[11:0]};
  endfunction

  // NoC port (slave index) of an address
  function automatic int unsigned phone_decode(logic [31:0] a);
    if (a[31:16] == SRAM_BASE[31:16]) return S_SRAM;
    if (a[31:17] == APB_BASE[31:17])  return S_APB;
    if (a[31])                        return int'(dram_channel(a));
    return S_DEF;
  endfunction

  // ---------------------------------------------------------------- APB slots
  localparam int APB_GPIO  = 0;   // open-ip GPIO_apb
  localparam int APB_UART  = 1;   // open-ip UART_apb
  localparam int APB_EXT   = 2;   // external APB port (APB slave VIP)
  localparam int APB_I2C   = 3;   // open-ip I2C_apb (target)
  localparam int APB_SPI   = 4;   // open-ip SPI_apb (target)
  localparam int APB_PWM   = 5;   // open-ip PWM_apb
  localparam int APB_TRNG  = 6;   // open-ip TRNG_apb
  localparam int APB_IOMMU = 7;   // 7..12: IOMMU 0..5 register blocks
  localparam int APB_NSLOTS = APB_IOMMU + NIOMMU;   // 13; slots 13..15 answer PSLVERR

  // Segment 1 (APB_SS_BASE, PADDR[16] = 1) goes out on the ss APB port to the
  // subsystem IP cluster (phone_ss_ips, open-ip *_apb wrappers, real-IP build).
  // Without the cluster the testbench answers PSLVERR there.
  localparam int SS_CPU   = 0;   // CPU_Cluster          -> M_CPU
  localparam int SS_GPU   = 1;   // GPU                  -> M_GPU
  localparam int SS_NPU   = 2;   // NPU                  -> M_APU   (IOMMU 0)
  localparam int SS_ISP   = 3;   // ISP                  -> M_ISP   (IOMMU 1)
  localparam int SS_DISP  = 4;   // Display_Controller   -> M_DISP  (IOMMU 5)
  localparam int SS_VDEC  = 5;   // Video_Codec (decode) -> M_VDEC  (IOMMU 3)
  localparam int SS_VENC  = 6;   // Video_Codec (encode) -> M_VENC  (IOMMU 4)
  localparam int SS_MODEM = 7;   // Modem                -> M_MODEM
  localparam int SS_DMA   = 8;   // DMA                  -> M_DMA
  localparam int SS_ADSP  = 9;   // Audio_DSP            -> M_ADSP
  localparam int SS_SENS  = 10;  // Sensor_Hub           -> M_SCP (always-on cluster)
  localparam int SS_INTC  = 11;  // Interrupt_Controller -> M_SCP (always-on cluster)
  localparam int SS_TMR   = 12;  // Timer_WDT            -> M_SCP (always-on cluster)
  localparam int SS_NSLOTS = 13;

  function automatic int ss_master(int s);
    //               CPU    GPU    NPU    ISP    DISP    VDEC    VENC    MODEM    DMA    ADSP    SENS   INTC   TMR
    int ms[SS_NSLOTS] = '{M_CPU, M_GPU, M_APU, M_ISP, M_DISP, M_VDEC, M_VENC, M_MODEM, M_DMA, M_ADSP, M_SCP, M_SCP, M_SCP};
    return ms[s];
  endfunction
  // master ports driven by the subsystem IP cluster in the real-IP build
  function automatic bit ss_drives(int m);
    for (int s = 0; s < SS_NSLOTS; s++) if (ss_master(s) == m) return 1;
    return 0;
  endfunction

  // ---------------------------------------------------------------- NoC mesh
  // 4 x 4 mesh, XY routing. Rows 0 and 3 carry the memory controllers
  // (DRAM PHYs on two die edges, 4 channels per router); rows 1 and 2 carry
  // the subsystems. Latency of one traversal = NI + router per node + link
  // per hop, in NoC clock cycles.
  localparam int MESH_X = 4, MESH_Y = 4;
  localparam int NOC_NI_LAT = 1, NOC_ROUTER_LAT = 1, NOC_LINK_LAT = 1;

  function automatic int master_x(int m);
    //                CPU GPU APU ISP ICP VDEC VENC DISP ADSP MODEM CONN SCP UFS SEC DMA
    int xs[NM] = '{   1,  2,  2,  0,  0,   3,   3,   3,   1,    0,   0,  1,  2,  1,  2};
    return xs[m];
  endfunction
  function automatic int master_y(int m);
    int ys[NM] = '{   1,  1,  2,  2,  2,   2,   2,   1,   2,    1,   1,  2,  2,  1,  1};
    return ys[m];
  endfunction
  function automatic int slave_x(int s);
    if (s < 16)     return s / 4;
    if (s < NCH)    return (s - 16) / 4;
    if (s == S_SRAM) return 1;
    return 2;                                       // APB bridge, default slave
  endfunction
  function automatic int slave_y(int s);
    if (s < 16)  return 0;
    if (s < NCH) return 3;
    return (s == S_SRAM) ? 1 : 2;
  endfunction

  function automatic int mesh_hops(int m, int s);
    int dx = master_x(m) - slave_x(s);
    int dy = master_y(m) - slave_y(s);
    return (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
  endfunction

  // one-way NoC latency (cycles) between master m and slave port s
  function automatic int noc_lat(int m, int s);
    int h = mesh_hops(m, s);
    return 2 * NOC_NI_LAT + (h + 1) * NOC_ROUTER_LAT + h * NOC_LINK_LAT;
  endfunction

  function automatic string master_name(int m);
    string n[NM] = '{"CPU", "GPU", "APU", "ISP", "ICP", "VDEC", "VENC", "DISP",
                     "ADSP", "MODEM", "CONN", "SCP", "UFS", "SEC", "DMA"};
    return n[m];
  endfunction
endpackage
