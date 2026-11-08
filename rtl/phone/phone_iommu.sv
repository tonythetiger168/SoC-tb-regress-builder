// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_iommu -- IOMMU (translation unit) in front of one multimedia master
// ----------------------------------------------------------------------------
// Upstream: AXI4 subordinate port (I/O virtual addresses, IOVA) from the
// master. Downstream: AXI4 manager port (physical addresses) into the NoC.
// APB4 completer: register block (4 KB slot). Single-level page table of
// 4 KB pages held in DRAM, walked through the downstream port.
//
//   IOVA window  [VA_BASE, VA_BASE + VA_SIZE)   (VA_SIZE in bytes, 4 KB units)
//   PTE address  PT_BASE + ((iova - VA_BASE) >> 12) * 4
//   PTE (32 bit) [31:12] PPN  [2] write allowed  [1] read allowed  [0] valid
//   PA           {PPN, iova[11:0]}
//
// * CTRL.EN = 0: bypass, PA = IOVA, no checks.
// * TLB: TLB_N entries, fully associative, round-robin replacement; flushed
//   by writing INV, or by writing CTRL / PT_BASE / VA_BASE / VA_SIZE.
// * A miss walks the table: one 1-beat read on the downstream AR channel
//   with ID WALK_ID (upper half of the ID space; the master uses IDs below
//   it). Reads have priority for the downstream read channel; the walker
//   uses it only while no master read is forwarded.
// * Faults (outside the window, PTE not valid, permission): the burst is not
//   forwarded; it is answered SLVERR on every beat (a write's W beats are
//   consumed). The first fault is latched in FAULT_STATUS / FAULT_ADDR until
//   cleared (W1C); FAULT_CNT counts all faults. irq = FAULT_STATUS.VALID &
//   CTRL.IRQ_EN.
// * An AXI burst never crosses 4 KB, so one translation covers a burst.
//
// Registers (byte offsets in the slot):
//   0x000 ID          RO   0x494F_0100 ("IO", v1.0)
//   0x004 CTRL        RW   [0] EN  [1] IRQ_EN
//   0x008 PT_BASE     RW   [31:12] (4 KB aligned)
//   0x00C VA_BASE     RW   [31:12]
//   0x010 VA_SIZE     RW   [31:12] window size in bytes
//   0x014 INV         WO   write any value: flush the TLB (reads 0)
//   0x018 FAULT_STATUS W1C [0] VALID [1] WRITE [2] PERM (0: translation, 1: permission)
//   0x01C FAULT_ADDR  RO   IOVA of the latched fault
//   0x020 FAULT_CNT   RO   faults since reset
//   0x024 TLB_HITS    RO   bursts translated without a walk
//   0x028 TLB_MISSES  RO   walks
// Other offsets / misaligned / partial (PSTRB != F) writes: PSLVERR.
// ============================================================================
module phone_iommu #(
  parameter int IDW   = 4,
  parameter int TLB_N = 8
)(
  input  logic           clk,
  input  logic           rst_n,
  // ---------------- upstream (IOVA) ----------------
  input  logic [IDW-1:0] u_awid,
  input  logic [31:0]    u_awaddr,
  input  logic [7:0]     u_awlen,
  input  logic [2:0]     u_awsize,
  input  logic [1:0]     u_awburst,
  input  logic [2:0]     u_awprot,
  input  logic           u_awvalid,
  output logic           u_awready,
  input  logic [31:0]    u_wdata,
  input  logic [3:0]     u_wstrb,
  input  logic           u_wlast,
  input  logic           u_wvalid,
  output logic           u_wready,
  output logic [IDW-1:0] u_bid,
  output logic [1:0]     u_bresp,
  output logic           u_bvalid,
  input  logic           u_bready,
  input  logic [IDW-1:0] u_arid,
  input  logic [31:0]    u_araddr,
  input  logic [7:0]     u_arlen,
  input  logic [2:0]     u_arsize,
  input  logic [1:0]     u_arburst,
  input  logic [2:0]     u_arprot,
  input  logic           u_arvalid,
  output logic           u_arready,
  output logic [IDW-1:0] u_rid,
  output logic [31:0]    u_rdata,
  output logic [1:0]     u_rresp,
  output logic           u_rlast,
  output logic           u_rvalid,
  input  logic           u_rready,
  // ---------------- downstream (PA) ----------------
  output logic [IDW-1:0] d_awid,
  output logic [31:0]    d_awaddr,
  output logic [7:0]     d_awlen,
  output logic [2:0]     d_awsize,
  output logic [1:0]     d_awburst,
  output logic [2:0]     d_awprot,
  output logic           d_awvalid,
  input  logic           d_awready,
  output logic [31:0]    d_wdata,
  output logic [3:0]     d_wstrb,
  output logic           d_wlast,
  output logic           d_wvalid,
  input  logic           d_wready,
  input  logic [IDW-1:0] d_bid,
  input  logic [1:0]     d_bresp,
  input  logic           d_bvalid,
  output logic           d_bready,
  output logic [IDW-1:0] d_arid,
  output logic [31:0]    d_araddr,
  output logic [7:0]     d_arlen,
  output logic [2:0]     d_arsize,
  output logic [1:0]     d_arburst,
  output logic [2:0]     d_arprot,
  output logic           d_arvalid,
  input  logic           d_arready,
  input  logic [IDW-1:0] d_rid,
  input  logic [31:0]    d_rdata,
  input  logic [1:0]     d_rresp,
  input  logic           d_rlast,
  input  logic           d_rvalid,
  output logic           d_rready,
  // ---------------- APB4 completer ----------------
  input  logic           psel,
  input  logic           penable,
  input  logic           pwrite,
  input  logic [11:0]    paddr,
  input  logic [31:0]    pwdata,
  input  logic [3:0]     pstrb,
  output logic [31:0]    prdata,
  output logic           pready,
  output logic           pslverr,
  output logic           irq
);
  localparam logic [IDW-1:0] WALK_ID = IDW'(1) << (IDW - 1);
  localparam logic [31:0] ID_VALUE = 32'h494F_0100;
  localparam logic [1:0] SLVERR = 2'b10;

  // ==========================================================================
  // registers
  // ==========================================================================
  logic        en, irq_en;
  logic [19:0] pt_base, va_base, va_size;   // [31:12] of each
  logic        f_valid, f_write, f_perm;
  logic [31:0] f_addr, f_cnt, n_hits, n_miss;
  logic        tlb_flush;

  wire acc = psel & penable;
  wire [9:0] widx = paddr[11:2];
  logic hit_reg;
  always_comb begin
    hit_reg = (paddr[1:0] == 2'b00) && (widx <= 10'd10);
    prdata = '0;
    if (acc && !pwrite && hit_reg)
      case (widx)
        10'd0:  prdata = ID_VALUE;
        10'd1:  prdata = {30'b0, irq_en, en};
        10'd2:  prdata = {pt_base, 12'b0};
        10'd3:  prdata = {va_base, 12'b0};
        10'd4:  prdata = {va_size, 12'b0};
        10'd6:  prdata = {29'b0, f_perm, f_write, f_valid};
        10'd7:  prdata = f_addr;
        10'd8:  prdata = f_cnt;
        10'd9:  prdata = n_hits;
        10'd10: prdata = n_miss;
        default: prdata = '0;
      endcase
  end
  assign pready  = 1'b1;
  assign pslverr = acc & (!hit_reg | (pwrite & (pstrb != 4'hF)) | (pwrite & (widx == 10'd0 ||
                   widx == 10'd7 || widx == 10'd8 || widx == 10'd9 || widx == 10'd10)));
  wire reg_wr = acc & pwrite & hit_reg & (pstrb == 4'hF);
  assign irq = f_valid & irq_en;

  // fault capture request from the read / write paths
  logic        fault_r, fault_w, fault_r_perm, fault_w_perm;
  logic [31:0] fault_r_addr, fault_w_addr;
  logic        cnt_hit, cnt_miss;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      en <= 1'b0; irq_en <= 1'b0; pt_base <= '0; va_base <= '0; va_size <= '0;
      f_valid <= 1'b0; f_write <= 1'b0; f_perm <= 1'b0; f_addr <= '0; f_cnt <= '0;
      n_hits <= '0; n_miss <= '0;
    end else begin
      if (reg_wr)
        case (widx)
          10'd1: begin en <= pwdata[0]; irq_en <= pwdata[1]; end
          10'd2: pt_base <= pwdata[31:12];
          10'd3: va_base <= pwdata[31:12];
          10'd4: va_size <= pwdata[31:12];
          10'd6: if (pwdata[0]) f_valid <= 1'b0;
          default: ;
        endcase
      if (fault_r || fault_w) begin
        f_cnt <= f_cnt + ((fault_r && fault_w) ? 32'd2 : 32'd1);
        if (!f_valid || (reg_wr && widx == 10'd6 && pwdata[0])) begin
          f_valid <= 1'b1;
          f_write <= !fault_r;
          f_perm  <= fault_r ? fault_r_perm : fault_w_perm;
          f_addr  <= fault_r ? fault_r_addr : fault_w_addr;
        end
      end
      if (cnt_hit)  n_hits <= n_hits + 32'd1;
      if (cnt_miss) n_miss <= n_miss + 32'd1;
    end
  end
  assign tlb_flush = reg_wr && (widx >= 10'd1 && widx <= 10'd5);

  // ==========================================================================
  // TLB
  // ==========================================================================
  logic        tv [TLB_N];
  logic [19:0] tvpn [TLB_N], tppn [TLB_N];
  logic        tr [TLB_N], tw [TLB_N];
  logic [$clog2(TLB_N)-1:0] tptr;

  // window check (in pages); lookups are written out in always_comb blocks
  // below so that every TLB register is in their sensitivity
  wire [20:0] win_lo = {1'b0, va_base};
  wire [20:0] win_hi = {1'b0, va_base} + {1'b0, va_size};

  // ==========================================================================
  // page-table walker (shared by both paths)
  // ==========================================================================
  typedef enum logic [1:0] {K_IDLE, K_AR, K_R} kst_t;
  kst_t        kst;
  logic        k_for_w;         // walk requested by the write path
  logic [31:0] k_va;
  logic        k_done_r, k_done_w;   // one-cycle pulses
  logic        k_pte_ok;             // result: PTE valid (TLB filled)
  logic        walk_req_r, walk_req_w;
  logic        rd_owns_bus, rd_take_bus;

  // ==========================================================================
  // read path
  // ==========================================================================
  typedef enum logic [2:0] {R_IDLE, R_LOOK, R_WALK, R_FWD, R_DATA, R_ERR} rst_t;
  rst_t        rs;
  logic [IDW-1:0] r_id;
  logic [31:0] r_va, r_pa;
  logic [7:0]  r_len, r_beat;
  logic [2:0]  r_size, r_prot;
  logic [1:0]  r_burst;
  logic        r_hit, r_rok, r_wok;
  logic [19:0] r_ppn;
  logic        r_walked;      // this burst already walked (do not count the re-lookup as a hit)

  always_comb begin
    r_hit = 1'b0; r_ppn = '0; r_rok = 1'b0; r_wok = 1'b0;
    for (int i = 0; i < TLB_N; i++)
      if (tv[i] && tvpn[i] == r_va[31:12]) begin
        r_hit = 1'b1; r_ppn = tppn[i]; r_rok = tr[i]; r_wok = tw[i];
      end
  end

  // R_LOOK outcome
  logic r_bypass, r_oow;
  assign r_bypass = !en;
  assign r_oow    = en && !(({1'b0, r_va[31:12]} >= win_lo) && ({1'b0, r_va[31:12]} < win_hi));
  assign rd_take_bus = (rs == R_LOOK) && (kst == K_IDLE) &&
                       (r_bypass || (!r_oow && r_hit && r_rok));
  assign rd_owns_bus = (rs == R_FWD) || (rs == R_DATA);
  assign walk_req_r  = (rs == R_WALK) && !k_done_r;   // not in the cycle its result lands

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs <= R_IDLE; r_id <= '0; r_va <= '0; r_pa <= '0; r_len <= '0; r_beat <= '0;
      r_size <= '0; r_prot <= '0; r_burst <= '0; r_walked <= 1'b0;
    end else begin
      if (rs == R_WALK) r_walked <= 1'b1;
      if (rs == R_IDLE) r_walked <= 1'b0;
      case (rs)
        R_IDLE: if (u_arvalid) begin
          r_id <= u_arid; r_va <= u_araddr; r_len <= u_arlen; r_size <= u_arsize;
          r_burst <= u_arburst; r_prot <= u_arprot; r_beat <= '0;
          rs <= R_LOOK;
        end
        R_LOOK:
          if (r_bypass) begin
            if (kst == K_IDLE) begin r_pa <= r_va; rs <= R_FWD; end
          end else if (r_oow) rs <= R_ERR;
          else if (r_hit) begin
            if (!r_rok) rs <= R_ERR;
            else if (kst == K_IDLE) begin r_pa <= {r_ppn, r_va[11:0]}; rs <= R_FWD; end
          end else rs <= R_WALK;
        R_WALK: if (k_done_r) rs <= k_pte_ok ? R_LOOK : R_ERR;
        R_FWD:  if (d_arready) rs <= R_DATA;
        R_DATA: if (d_rvalid && u_rready && d_rlast) rs <= R_IDLE;
        R_ERR:  if (u_rready) begin
          r_beat <= r_beat + 8'd1;
          if (r_beat == r_len) rs <= R_IDLE;
        end
        default: rs <= R_IDLE;
      endcase
    end
  end
  assign fault_r      = (rs == R_LOOK) && !r_bypass && (r_oow || (r_hit && !r_rok)) ||
                        (rs == R_WALK) && k_done_r && !k_pte_ok;
  assign fault_r_perm = (rs == R_LOOK) && r_hit && !r_rok && !r_oow;
  assign fault_r_addr = r_va;

  assign u_arready = (rs == R_IDLE);
  always_comb begin
    u_rid = r_id; u_rdata = '0; u_rresp = '0; u_rlast = 1'b0; u_rvalid = 1'b0;
    if (rs == R_DATA) begin
      u_rdata = d_rdata; u_rresp = d_rresp; u_rlast = d_rlast; u_rvalid = d_rvalid;
    end else if (rs == R_ERR) begin
      u_rresp = SLVERR; u_rlast = (r_beat == r_len); u_rvalid = 1'b1;
    end
  end

  // ==========================================================================
  // write path
  // ==========================================================================
  typedef enum logic [2:0] {W_IDLE, W_LOOK, W_WALK, W_FWD, W_DATA, W_RESP, W_ERRD, W_ERRB} wst_t;
  wst_t        ws;
  logic [IDW-1:0] w_id;
  logic [31:0] w_va, w_pa;
  logic [7:0]  w_len;
  logic [2:0]  w_size, w_prot;
  logic [1:0]  w_burst;
  logic        w_hit, w_rok, w_wok;
  logic [19:0] w_ppn;
  logic        w_walked;

  always_comb begin
    w_hit = 1'b0; w_ppn = '0; w_rok = 1'b0; w_wok = 1'b0;
    for (int i = 0; i < TLB_N; i++)
      if (tv[i] && tvpn[i] == w_va[31:12]) begin
        w_hit = 1'b1; w_ppn = tppn[i]; w_rok = tr[i]; w_wok = tw[i];
      end
  end
  logic w_bypass, w_oow;
  assign w_bypass = !en;
  assign w_oow    = en && !(({1'b0, w_va[31:12]} >= win_lo) && ({1'b0, w_va[31:12]} < win_hi));
  assign walk_req_w = (ws == W_WALK) && !k_done_w;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ws <= W_IDLE; w_id <= '0; w_va <= '0; w_pa <= '0; w_len <= '0;
      w_size <= '0; w_prot <= '0; w_burst <= '0; w_walked <= 1'b0;
    end else begin
      if (ws == W_WALK) w_walked <= 1'b1;
      if (ws == W_IDLE) w_walked <= 1'b0;
      case (ws)
        W_IDLE: if (u_awvalid) begin
          w_id <= u_awid; w_va <= u_awaddr; w_len <= u_awlen; w_size <= u_awsize;
          w_burst <= u_awburst; w_prot <= u_awprot;
          ws <= W_LOOK;
        end
        W_LOOK:
          if (w_bypass) begin w_pa <= w_va; ws <= W_FWD; end
          else if (w_oow) ws <= W_ERRD;
          else if (w_hit) begin
            if (!w_wok) ws <= W_ERRD;
            else begin w_pa <= {w_ppn, w_va[11:0]}; ws <= W_FWD; end
          end else ws <= W_WALK;
        W_WALK: if (k_done_w) ws <= k_pte_ok ? W_LOOK : W_ERRD;
        W_FWD:  if (d_awready) ws <= W_DATA;
        W_DATA: if (u_wvalid && d_wready && u_wlast) ws <= W_RESP;
        W_RESP: if (d_bvalid && u_bready) ws <= W_IDLE;
        W_ERRD: if (u_wvalid && u_wlast) ws <= W_ERRB;
        W_ERRB: if (u_bready) ws <= W_IDLE;
        default: ws <= W_IDLE;
      endcase
    end
  end
  assign fault_w      = (ws == W_LOOK) && !w_bypass && (w_oow || (w_hit && !w_wok)) ||
                        (ws == W_WALK) && k_done_w && !k_pte_ok;
  assign fault_w_perm = (ws == W_LOOK) && w_hit && !w_wok && !w_oow;
  assign fault_w_addr = w_va;
  assign cnt_hit  = ((rs == R_LOOK) && !r_walked && !r_bypass && !r_oow && r_hit && (r_rok ? kst == K_IDLE : 1'b1)) ||
                    ((ws == W_LOOK) && !w_walked && !w_bypass && !w_oow && w_hit);
  assign cnt_miss = (kst == K_IDLE) && !rd_owns_bus && !rd_take_bus && (walk_req_r || walk_req_w);

  assign u_awready = (ws == W_IDLE);
  assign u_wready  = (ws == W_DATA) ? d_wready : (ws == W_ERRD);
  always_comb begin
    u_bid = w_id; u_bresp = '0; u_bvalid = 1'b0;
    if (ws == W_RESP) begin u_bresp = d_bresp; u_bvalid = d_bvalid; end
    else if (ws == W_ERRB) begin u_bresp = SLVERR; u_bvalid = 1'b1; end
  end

  assign d_awid    = w_id;
  assign d_awaddr  = w_pa;
  assign d_awlen   = w_len;
  assign d_awsize  = w_size;
  assign d_awburst = w_burst;
  assign d_awprot  = w_prot;
  assign d_awvalid = (ws == W_FWD);
  assign d_wdata   = u_wdata;
  assign d_wstrb   = u_wstrb;
  assign d_wlast   = u_wlast;
  assign d_wvalid  = (ws == W_DATA) && u_wvalid;
  assign d_bready  = (ws == W_RESP) && u_bready;

  // synthesis translate_off
  always @(posedge clk) if ($test$plusargs("IOMMU_DEBUG")) begin
    if (ws == W_LOOK) $display("%t %m W_LOOK va=%h hit=%b ppn=%h r=%b w=%b oow=%b en=%b", $time, w_va, w_hit, w_ppn, w_rok, w_wok, w_oow, en);
    if (rs == R_LOOK) $display("%t %m R_LOOK va=%h hit=%b ppn=%h r=%b w=%b oow=%b kst=%0d", $time, r_va, r_hit, r_ppn, r_rok, r_wok, r_oow, kst);
    if (kst == K_R && d_rvalid) $display("%t %m WALK va=%h pte_addr=%h pte=%h resp=%b for_w=%b", $time, k_va, k_pte_addr, d_rdata, d_rresp, k_for_w);
    if (fault_r || fault_w) $display("%t %m FAULT r=%b w=%b", $time, fault_r, fault_w);
    if (ws == W_FWD && d_awready) $display("%t %m W_FWD pa=%h", $time, d_awaddr);
  end
  // synthesis translate_on

  // ==========================================================================
  // walker FSM + downstream read channel mux
  // ==========================================================================
  wire [31:0] k_pte_addr = {pt_base, 12'b0} + {10'b0, (k_va[31:12] - va_base), 2'b00};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kst <= K_IDLE; k_for_w <= 1'b0; k_va <= '0; k_done_r <= 1'b0; k_done_w <= 1'b0;
      k_pte_ok <= 1'b0; tptr <= '0;
      for (int i = 0; i < TLB_N; i++) begin
        tv[i] <= 1'b0; tvpn[i] <= '0; tppn[i] <= '0; tr[i] <= 1'b0; tw[i] <= 1'b0;
      end
    end else begin
      k_done_r <= 1'b0;
      k_done_w <= 1'b0;
      case (kst)
        K_IDLE: if (!rd_owns_bus && !rd_take_bus && (walk_req_r || walk_req_w)) begin
          k_for_w <= !walk_req_r;          // the read path has priority
          k_va    <= walk_req_r ? r_va : w_va;
          kst     <= K_AR;
        end
        K_AR: if (d_arready) kst <= K_R;
        K_R:  if (d_rvalid) begin
          k_pte_ok <= d_rvalid && d_rresp == 2'b00 && d_rdata[0];
          if (d_rresp == 2'b00 && d_rdata[0]) begin
            tv[tptr] <= 1'b1; tvpn[tptr] <= k_va[31:12]; tppn[tptr] <= d_rdata[31:12];
            tr[tptr] <= d_rdata[1]; tw[tptr] <= d_rdata[2];
            tptr <= tptr + 1'b1;
          end
          if (k_for_w) k_done_w <= 1'b1; else k_done_r <= 1'b1;
          kst <= K_IDLE;
        end
        default: kst <= K_IDLE;
      endcase
      if (tlb_flush)
        for (int i = 0; i < TLB_N; i++) tv[i] <= 1'b0;
    end
  end

  always_comb begin
    if (kst != K_IDLE) begin
      d_arid = WALK_ID; d_araddr = k_pte_addr; d_arlen = 8'd0; d_arsize = 3'd2;
      d_arburst = 2'b01; d_arprot = 3'b010;   // non-secure data access
      d_arvalid = (kst == K_AR);
      d_rready  = (kst == K_R);
    end else begin
      d_arid = r_id; d_araddr = r_pa; d_arlen = r_len; d_arsize = r_size;
      d_arburst = r_burst; d_arprot = r_prot;
      d_arvalid = (rs == R_FWD);
      d_rready  = (rs == R_DATA) && u_rready;
    end
  end
endmodule
