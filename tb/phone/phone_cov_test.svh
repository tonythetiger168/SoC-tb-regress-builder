// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_cov_test -- coverage closure of the phone SoC glue (rtl/phone/)
// ----------------------------------------------------------------------------
// Directed stimulus for what the use-case tests leave out; every burst is
// still checked by the scoreboard (DRAM shadow, SRAM / APB / DECERR models,
// IOMMU translation and faults). Phases:
//   1. every master to every NoC port: all IDs, AxPROT values, sizes, burst
//      types and lengths up to 256 beats, SLVERR and DECERR pages on every
//      channel, the SRAM, both APB segments and the default slave, with
//      channel READY after VALID and master B/R back-pressure
//   2. address bits: every master walks each address bit through the
//      decoder (SRAM, APB, DRAM, default slave)
//   3. contention: all masters at once on one channel, the SRAM, the APB
//      bridge and the default slave
//   4. IOMMUs: TLB entries with complementary VPN / PPN patterns, every
//      fault kind, register errors, a CTRL write while a walk is running
//   5. APB: external slot data both ways, unmapped slots and segment 1
// ============================================================================
class phone_cov_test extends phone_base_test;
  `uvm_component_utils(phone_cov_test)
  // complementary TLB patterns (VPN = PPN), none in the APB window or the
  // page-table area, so reads and writes through them are safe
  bit [19:0] pat_a [8] = '{20'hAAAAA, 20'hCCCCC, 20'hF0F0F, 20'hFF00F, 20'h12345, 20'h6789A, 20'hBCDE1, 20'h2468A};
  string     iommu_win_regs [3] = '{"PT_BASE", "VA_BASE", "VA_SIZE"};
  localparam bit [31:0] COV_PT  = 32'hF800_0000;    // 4 MB page table per IOMMU
  localparam bit [31:0] SLV_LO  = 32'hFFF0_0000;    // SLVERR pages: 1 MB, every channel
  localparam bit [31:0] DEC_LO  = 32'hFFE0_0000;    // DECERR pages: 1 MB, every channel

  semaphore  apb_lock = new(1);        // one APB burst at a time: the scoreboard
                                       // matches APB transfers in completion order

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void configure();
    timing = 1;
    cfg.ddr_err_lo = SLV_LO;          cfg.ddr_err_hi = 32'hFFFF_FFFF;
    cfg.ddr_dec_lo = DEC_LO;          cfg.ddr_dec_hi = SLV_LO - 1;
  endfunction

  // ---------------------------------------------------------------- helpers
  function int unsigned max_id(int m);
    return (1 << cfg.pm_cfg[m].id_width) - 1;
  endfunction

  task burst(int m, bit wr, bit [31:0] a, int unsigned beats = 1, bit [2:0] size = 2,
             axi4_burst_e b = AXI4_INCR, bit [7:0] id = 0, bit [2:0] prot = 0,
             bit [31:0] fill = 32'h0, bit use_fill = 0);
    axi4_item t = axi4_api::make(wr, a, beats, size, b, id);
    bit to_apb = phone_decode(a) == S_APB;
    t.prot = prot;
    if (wr && use_fill) foreach (t.data[i]) t.data[i] = fill;
    if (to_apb) apb_lock.get();
    axi4_api::run(sqr(m), t);
    if (to_apb) apb_lock.put();
  endtask

  // DRAM address on channel c inside master m's slice (bits [21:17] = 0)
  function bit [31:0] ch_addr(int m, int c, bit [11:0] off = 0);
    return part_base(m) + (32'(c) << 12) + 32'(off);
  endfunction

  // an address of page region base that the interleaving puts on channel c
  function bit [31:0] ch_page(bit [31:0] base, int c);
    return base + (32'(c) << 12);
  endfunction

  function void set_slave_stall(bit on);
    foreach (cfg.ch_cfg[c]) begin
      cfg.ch_cfg[c].ready_after_valid = on;
      cfg.ch_cfg[c].max_aready_delay  = on ? 3 : 1;
      cfg.ch_cfg[c].max_wready_delay  = on ? 2 : 1;
    end
    foreach (cfg.pm_cfg[m]) begin
      cfg.pm_cfg[m].max_b_delay = on ? 4 : 2;
      cfg.pm_cfg[m].max_r_gap   = on ? 3 : 2;
    end
  endfunction

  // ---------------------------------------------------------------- phase 1
  // every master to every channel: both AxPROT extremes, the top and bottom
  // ID, then (one master per channel) the burst shapes and error pages
  task port_walk(int m);
    for (int c = 0; c < NCH; c++) begin
      bit [7:0] hi = 8'(max_id(m));
      burst(m, 1, ch_addr(m, c, 12'h100), 1, 2, AXI4_INCR, hi, 3'h7);
      burst(m, 0, ch_addr(m, c, 12'h100), 1, 2, AXI4_INCR, hi, 3'h7);
      burst(m, 1, ch_addr(m, c, 12'h104), 2, 2, AXI4_INCR, 0, 3'h0);
      burst(m, 0, ch_addr(m, c, 12'h104), 2, 2, AXI4_INCR, 0, 3'h0);
      if (c % NM == m) begin
        for (int wr = 1; wr >= 0; wr--) begin
          burst(m, wr, ch_addr(m, c, 12'h400), 256, 2, AXI4_INCR, 8'(c % (max_id(m) + 1)));
          burst(m, wr, ch_addr(m, c, 12'h040), 4, 2, AXI4_FIXED);
          burst(m, wr, ch_addr(m, c, 12'h084), 16, 2, AXI4_WRAP);
          burst(m, wr, ch_addr(m, c, 12'h0C3), 4, 0, AXI4_INCR);
          burst(m, wr, ch_addr(m, c, 12'h0D2), 4, 1, AXI4_INCR);
          burst(m, wr, ch_page(SLV_LO, c) + 32'h80, 4, 2, AXI4_INCR);
          burst(m, wr, ch_page(DEC_LO, c) + 32'h80, 4, 2, AXI4_INCR);
        end
      end
    end
  endtask

  // every master: every ID and AxPROT value, the shapes on its own slice, the
  // SRAM, the external APB slot and the default slave
  task master_walk(int m);
    bit [31:0] a = ch_addr(m, m, 12'h800);
    for (int id = 0; id <= max_id(m); id++) begin
      burst(m, 1, a + 4 * id, 1, 2, AXI4_INCR, 8'(id), 3'(id));
      burst(m, 0, a + 4 * id, 1, 2, AXI4_INCR, 8'(id), 3'(~id));
    end
    for (int id = 0; id <= max_id(m); id++)
      for (int wr = 1; wr >= 0; wr--) begin
        burst(m, wr, SRAM_BASE + 32'h40 * m + 4 * (id % 8), 1, 2, AXI4_INCR, 8'(id), 3'(id));
        burst(m, wr, APB_BASE + 32'h2000 + 32'h40 * m + 4 * (id % 8), 1, 2, AXI4_INCR, 8'(id), 3'(id));
        burst(m, wr, 32'h2000_0000 + 32'h1000 * m, 1, 2, AXI4_INCR, 8'(id), 3'(id));
      end
    for (int wr = 1; wr >= 0; wr--) begin
      foreach (pat_a[k]) burst(m, wr, a + 32'h100 + 4 * k, 1, 2, AXI4_INCR, 0, 0,
                               k[0] ? 32'hFFFF_FFFF : 32'h0, 1);
      burst(m, wr, a + 32'h200, 256, 2, AXI4_INCR);
      burst(m, wr, a + 32'h10, 8, 2, AXI4_FIXED);
      burst(m, wr, a + 32'h14, 1, 2, AXI4_FIXED);
      burst(m, wr, a + 32'h24, 8, 2, AXI4_WRAP);
      burst(m, wr, a + 32'h31, 3, 0, AXI4_INCR);
      burst(m, wr, a + 32'h3A, 3, 1, AXI4_INCR);
      burst(m, wr, ch_page(SLV_LO, m) + 32'h100, 2, 2, AXI4_INCR);
      burst(m, wr, ch_page(DEC_LO, m) + 32'h100, 2, 2, AXI4_INCR);
      // SRAM: OKAY bursts, a WRAP (SLVERR) and a long one (DECERR)
      burst(m, wr, SRAM_BASE + 32'h40 * m, 4, 2, AXI4_INCR);
      burst(m, wr, SRAM_BASE + 32'h40 * m, 4, 2, AXI4_FIXED);
      burst(m, wr, SRAM_BASE + 32'h40 * m + 8, 4, 2, AXI4_WRAP);
      burst(m, wr, SRAM_BASE + 32'h40 * m, 32, 2, AXI4_INCR);
      burst(m, wr, SRAM_BASE + 32'h1000, 1, 2, AXI4_INCR);          // past the 1 KB SRAM
      // external APB slot: bursts of every type, and its PSLVERR window
      burst(m, wr, APB_BASE + 32'h2000 + 32'h40 * m, 4, 2, AXI4_INCR);
      burst(m, wr, APB_BASE + 32'h2000 + 32'h40 * m, 2, 2, AXI4_FIXED);
      burst(m, wr, APB_BASE + 32'h2000 + 32'h40 * m + 4, 4, 2, AXI4_WRAP);
      burst(m, wr, APB_BASE + 32'h2F00 + 4 * m, 1, 2, AXI4_INCR);
      // default slave: DECERR on every beat of long and short bursts
      burst(m, wr, 32'h2000_0000 + 32'h1000 * m, 256, 2, AXI4_INCR);
      burst(m, wr, 32'h2000_0000 + 32'h1000 * m, 4, 2, AXI4_FIXED);
      burst(m, wr, 32'h2000_0000 + 32'h1000 * m + 4, 8, 2, AXI4_WRAP);
    end
  endtask

  // ---------------------------------------------------------------- phase 2
  // each address bit of master m through the decoder: set alone (SRAM, APB,
  // default slave), and set over the DRAM base (every channel bit)
  task addr_walk(int m);
    for (int b = 2; b < 32; b++) begin
      bit [31:0] a = 32'd1 << b;
      bit [31:0] d = DRAM_BASE | a | part_base(m);
      if (b < 10) a = SRAM_BASE | a;                    // in the 1 KB SRAM
      if (b < 31) begin                                 // bit 31 alone: DRAM, shared by all masters
        burst(m, 0, a, 1);
        burst(m, 1, a, 1);
      end
      if (b < 31 && !(d >= 32'hF800_0000)) begin      // keep out of the page tables
        burst(m, 1, d, 1);
        burst(m, 0, d, 1);
      end
    end
    burst(m, 0, 32'hFFFF_FFFC, 1);                      // every bit set (SLVERR page)
    burst(m, 1, 32'hFFFF_FFFC, 1);
  endtask

  // ---------------------------------------------------------------- phase 3
  task contention();
    bit [31:0] tgt [4] = '{0, SRAM_BASE + 32'h200, APB_BASE + 32'h2100, 32'h3000_0000};
    foreach (tgt[k])
      for (int rep = 0; rep < 2; rep++) begin
        for (int m = 0; m < NM; m++) begin
          automatic int mm = m;
          automatic bit [31:0] a = (k == 0) ? ch_addr(mm, 5, 12'h600) : tgt[k] + 8 * mm;
          fork
            begin
              burst(mm, 1, a, (k == 1 || k == 2) ? 2 : 8);
              burst(mm, 0, a, (k == 1 || k == 2) ? 2 : 8);
            end
          join_none
        end
        wait fork;
      end
  endtask

  // ---------------------------------------------------------------- phase 4
  function void poke_pte(bit [31:0] pt, bit [19:0] vbase, bit [19:0] vpn, bit [19:0] ppn,
                         bit r = 1, bit w = 1, bit v = 1);
    bit [31:0] a = pt + {10'b0, vpn - vbase, 2'b00};
    bit [31:0] pte = {ppn, 9'b0, w, r, v};
    cfg.dram_poke32(a, pte);
    env.sb.note_ddr_backdoor(a, pte);
  endfunction

  function phone_reg ir(int i, string n);
    return env.regmodel.iommu[i].r(n);
  endfunction

  task iommu_window(int i, bit [31:0] pt, bit [31:0] vb, bit [31:0] vs, bit [1:0] ctrl = 2'b11);
    reg_write(ir(i, "PT_BASE"), pt);
    reg_write(ir(i, "VA_BASE"), vb);
    reg_write(ir(i, "VA_SIZE"), vs);
    reg_write(ir(i, "CTRL"), ctrl);
  endtask

  // raw APB access to an IOMMU slot (RAL cannot make the error cases)
  task iommu_raw(int i, bit wr, bit [11:0] off, bit [3:0] strb, axi4_resp_e exp);
    axi4_item t = axi4_api::make(wr, APB_BASE + 32'h7000 + 32'h1000 * i + off, 1, 2, AXI4_INCR, 0);
    t.strb[0] = strb;
    apb_lock.get();
    axi4_api::run(sqr(cfg.host_m), t);
    apb_lock.put();
    if (t.resp[0] != exp)
      `uvm_error("TEST", $sformatf("IOMMU%0d raw %s @%03h strb %04b: %s, expected %s", i, wr ? "write" : "read",
                 off, strb, t.resp[0].name(), exp.name()))
  endtask

  task iommu_phase(int i);
    int m = master_of_iommu(i);
    bit [31:0] pt = COV_PT + 32'h0040_0000 * i;
    bit [31:0] own = ch_addr(m, 9, 12'h0);
    // registers: every offset, misaligned, partial strobes, read-only writes
    for (int o = 0; o <= 12; o++) iommu_raw(i, 0, 12'(4 * o), 4'hF, o > 10 ? AXI4_SLVERR : AXI4_OKAY);
    iommu_raw(i, 0, 12'hFFC, 4'hF, AXI4_SLVERR);
    iommu_raw(i, 0, 12'h006, 4'hF, AXI4_SLVERR);
    iommu_raw(i, 1, 12'h006, 4'hF, AXI4_SLVERR);
    iommu_raw(i, 0, 12'h005, 4'hF, AXI4_SLVERR);           // PADDR[0]
    iommu_raw(i, 1, 12'h004, 4'h3, AXI4_SLVERR);
    foreach (pat_a[k]) if (k < 5) iommu_raw(i, 1, 12'(k == 0 ? 0 : 4 * (k + 6)), 4'hF, AXI4_SLVERR);
    // window registers through complementary patterns (EN off), read back
    for (int round = 0; round < 3; round++) begin
      bit [31:0] v = round[0] ? 32'h5555_5000 : 32'hAAAA_A000;
      uvm_reg_data_t d;
      reg_write(ir(i, "CTRL"), 0);
      foreach (iommu_win_regs[r]) begin
        reg_write(ir(i, iommu_win_regs[r]), v);
        reg_read(ir(i, iommu_win_regs[r]), d);
      end
    end
    // full window: TLB entries through the patterns, then their complements
    // (no access rights: the walk fills the entry, then the access faults)
    iommu_window(i, pt, 32'h0, 32'hFFFF_F000);
    for (int round = 0; round < 3; round++) begin
      reg_write(ir(i, "INV"), 1);
      foreach (pat_a[k]) begin
        bit [19:0] p = round[0] ? ~pat_a[k] : pat_a[k];
        bit [11:0] off = round[0] ? 12'h554 : 12'hAA8;
        poke_pte(pt, 0, p, p, !round[0], !round[0]);
        burst(m, 0, {p, off}, 1, 2, AXI4_INCR, 8'(k), 3'(k));
        burst(m, 1, {p, off}, 1, 2, AXI4_INCR, 8'(k), 3'(~k), round[0] ? 32'h0 : 32'hFFFF_FFFF, 1);
      end
    end
    // faults: out of the window (top page), PTE not valid, no read, no write
    burst(m, 0, 32'hFFFF_F000, 1);
    burst(m, 1, 32'hFFFF_F004, 1);
    poke_pte(pt, 0, 20'h00011, own[31:12], 1, 1, 0);
    burst(m, 0, 32'h0001_1000, 1);
    poke_pte(pt, 0, 20'h00012, own[31:12], 0, 1, 1);
    burst(m, 1, 32'h0001_2008, 2);                      // walk, TLB fill (write allowed)
    burst(m, 0, 32'h0001_2008, 2);                      // hit, read not allowed
    poke_pte(pt, 0, 20'h00013, own[31:12], 1, 0, 1);
    burst(m, 0, 32'h0001_3010, 2);                      // walk, TLB fill (read allowed)
    burst(m, 1, 32'h0001_3010, 2);                      // hit, write not allowed
    // a read and a write fault in the same cycle
    fork
      burst(m, 0, 32'hFFFF_F010, 1);
      burst(m, 1, 32'hFFFF_F020, 1);
    join
    reg_write(ir(i, "FAULT_STATUS"), 0);                // W1C with 0: stays set
    clear_iommu_fault(i);
    burst(m, 1, 32'hFFFF_F030, 1);                      // first fault a write (out of window)
    clear_iommu_fault(i);
    poke_pte(pt, 0, 20'h00014, own[31:12], 1, 1, 0);
    burst(m, 1, 32'h0001_4000, 1);                      // write walk, PTE not valid
    clear_iommu_fault(i);
    burst(m, 0, 32'h0001_2000, 1);                      // latched: a permission fault ...
    clear_iommu_fault(i);
    burst(m, 0, 32'hFFFF_F000, 256);                    // ... then a translation fault, 256 beats
    clear_iommu_fault(i);
    // event counters: 260 walks (9 pages round robin over the 8 entries, some
    // at odd byte addresses), 260 TLB hits, 260 faults
    for (int k = 0; k < 9; k++) poke_pte(pt, 0, 20'h00100 + 20'(k), own[31:12] + 20'(k));
    for (int k = 0; k < 261; k++)
      burst(m, 0, {20'h00100 + 20'(k % 9), 12'(4 * k + (k % 4 == 3 ? 3 : 0))}, 1, (k % 4 == 3) ? 0 : 2);
    for (int k = 0; k < 260; k++) burst(m, 0, {20'h00108, 12'(4 * k)}, 1);
    for (int k = 0; k < 260; k++) burst(m, k[0], 32'hFFFF_F000 + 4 * k, 1);
    clear_iommu_fault(i);
    // small window above IOVA 0: below it is out of the window too
    iommu_window(i, pt, 32'h0004_0000, 32'h0000_4000);
    burst(m, 0, 32'h0003_F000, 1);
    burst(m, 1, 32'h0003_F000, 1);
    clear_iommu_fault(i);
    // FAULT_ADDR through complementary patterns (narrow, odd addresses)
    for (int round = 0; round < 4; round++) begin
      uvm_reg_data_t d;
      burst(m, 0, round == 3 ? 32'hAAAA_AAA8 : round[0] ? 32'h5555_5555 : 32'hAAAA_AAAB, 1, 0);
      reg_read(ir(i, "FAULT_ADDR"), d);
      clear_iommu_fault(i);
    end
    check_iommu_regs(i);
    reg_write(ir(i, "CTRL"), 0);
  endtask

  // a read that hits the TLB while a write's (slow) walk holds the walker,
  // then CTRL.EN cleared under it: the read waits, first as a hit, then
  // bypassed (both need the walker idle); both map VA = PA
  task iommu_bypass_race(int i);
    int m = master_of_iommu(i);
    bit [31:0] pt = COV_PT + 32'h0040_0000 * i;
    bit [31:0] va = ch_addr(m, 11, 12'h200), vb = ch_addr(m, 13, 12'h300);
    int c = dram_channel(pt + {10'b0, vb[31:12] - 20'h80000, 2'b00});
    iommu_window(i, pt, 32'h8000_0000, 32'h7000_0000);
    poke_pte(pt, 20'h80000, va[31:12], va[31:12]);
    poke_pte(pt, 20'h80000, vb[31:12], vb[31:12]);
    burst(m, 0, va, 1);                                 // page A into the TLB
    cfg.ch_cfg[c].access_latency = 4000;                // slow PTE read of page B
    cfg.pm_cfg[m].max_outstanding = 3;                  // the reads go out during the write
    fork
      burst(m, 1, vb, 1);                               // walk for page B
      begin #60ns;  burst(m, 0, va + 4, 1); end         // hit, waits for the walker
      begin                                             // ... then bypassed, still waiting
        #120ns; reg_write(ir(i, "CTRL"), 0);
        burst(m, 0, va + 8, 1);                         // a bypass read during the walk
      end
    join
    cfg.pm_cfg[m].max_outstanding = 1;
    cfg.ch_cfg[c].access_latency = 0;
  endtask

  // several bursts in flight per master (the IOMMU / NoC hold AWREADY and
  // ARREADY), with long B / R back-pressure from the masters
  task pipelined(int m);
    cfg.pm_cfg[m].max_outstanding = 4;
    cfg.pm_cfg[m].max_b_delay = 80;
    cfg.pm_cfg[m].max_r_gap = 40;
    for (int k = 0; k < 4; k++) begin
      automatic int kk = k;
      fork
        begin
          burst(m, 1, ch_addr(m, 20 + kk, 12'h900), 4);
          burst(m, 0, ch_addr(m, 20 + kk, 12'h900), 4);
        end
      join_none
    end
    wait fork;
    cfg.pm_cfg[m].max_outstanding = 1;
    cfg.pm_cfg[m].max_b_delay = 2;
    cfg.pm_cfg[m].max_r_gap = 2;
  endtask

  // ---------------------------------------------------------------- phase 5
  task apb_phase();
    int m = cfg.host_m;
    axi4_item t;
    cfg.apbx_cfg.max_wait = 8;
    for (int k = 0; k < 8; k++) begin
      burst(m, 1, APB_BASE + 32'h2100 + 4 * k, 1);
      burst(m, 0, APB_BASE + 32'h2100 + 4 * k, 1);
    end
    t = axi4_api::make(1, APB_BASE + 32'h2140, 1, 2, AXI4_INCR, 0);   // write with no byte strobe
    t.strb[0] = 4'h0;
    apb_lock.get();
    axi4_api::run(sqr(m), t);
    apb_lock.put();
    cfg.apbx_cfg.max_wait = 2;
    for (int p = 0; p < 2; p++) begin
      burst(m, 1, APB_BASE + 32'h2080, 1, 2, AXI4_INCR, 0, 0, p ? 32'h0 : 32'hFFFF_FFFF, 1);
      burst(m, 0, APB_BASE + 32'h2080, 1);
    end
    for (int s = APB_NSLOTS; s < 16; s++) begin       // unmapped slots
      burst(m, 1, APB_BASE + 32'h1000 * s, 1);
      burst(m, 0, APB_BASE + 32'h1000 * s + 32'hFFC, 1);
    end
    for (int s = 0; s < APB_EXT; s++) burst(m, 0, APB_BASE + 32'h1000 * s + 32'hFFC, 1);
    for (int s = APB_EXT + 1; s < APB_IOMMU; s++) burst(m, 0, APB_BASE + 32'h1000 * s + 32'hFFC, 1);
    for (int s = 0; s < 16; s++) begin                // segment 1
      burst(m, 1, APB_SS_BASE + 32'h1000 * s + 32'h4 * s, 1);
      burst(m, 0, APB_SS_BASE + 32'h1000 * s + 32'hFFC, 1);
    end
    burst(m, 0, APB_BASE + 32'h2084, 1);              // back to segment 0
    burst(m, 1, APB_BASE + 32'h2105, 1, 0, AXI4_INCR, 0, 0, 32'h5A5A_5A5A, 1);   // odd byte: PADDR[0]
    burst(m, 0, APB_BASE + 32'h2105, 1, 0);
  endtask

  task main();
    `uvm_info("COV_PHASE", "ports", UVM_LOW)
    set_slave_stall(1);
    for (int m = 0; m < NM; m++) begin
      automatic int mm = m;
      fork port_walk(mm); join_none
    end
    wait fork;
    set_slave_stall(0);
    for (int m = 0; m < NM; m++) begin
      automatic int mm = m;
      fork master_walk(mm); join_none
    end
    wait fork;
    // one master at a time: the single-bit addresses are shared by all masters
    for (int m = 0; m < NM; m++) addr_walk(m);
    `uvm_info("COV_PHASE", "pipelined", UVM_LOW)
    for (int m = 0; m < NM; m++) pipelined(m);
    `uvm_info("COV_PHASE", "contention", UVM_LOW)
    contention();
    `uvm_info("COV_PHASE", "iommu", UVM_LOW)
    for (int i = 0; i < NIOMMU; i++) iommu_phase(i);
    for (int i = 0; i < NIOMMU; i++) iommu_bypass_race(i);
    `uvm_info("COV_PHASE", "apb", UVM_LOW)
    apb_phase();
  endtask
endclass
