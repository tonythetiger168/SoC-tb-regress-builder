// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ipcam_soc_media_pkg -- IPCAM use-case tests on the generated SoC bench
// ----------------------------------------------------------------------------
// Adds to the socgen bench (socgen/out/ipcam_soc or ipcam_hd_soc; +define+IPCAM_HD
// picks the HD one) the tests that drive the real IPs. The CPU VIP master
// programs them over the NoC and APB bridge, the way firmware would:
//
//   <soc>_media_test   JPEG snapshot + HEVC intra encode of one NV12 frame and
//                      NPU DMA round trips, all concurrent, while every other
//                      master runs its traffic profile (the traffic test).
//                      +MEDIA_ONLY: no background traffic.
//
// Frame: +vec=<name> (regress/vectors/ipcam/<name>.yuv, +w, +h) or +in=<yuv>.
// The JPEG and HEVC output is byte-compared with the c1p reference streams
// (<name>.ref.jpg / .ref.265, or +jpg_ref / +hevc_ref). The NPU destination
// lines must equal the source lines. Buffers sit in the DDR windows the
// traffic generator assigns to the venc / jpeg / npu ports (unused by VIP
// traffic, since those ports are RTL), so background traffic cannot touch them.
// The SD and eMMC hosts run against the card / device models on their pins
// (spec pins_vip) and must end without IRQ_STATUS.ERR.
// Latency: the generated lat monitor prints a LAT line for every transaction,
// including the real IPs' bursts.
// Without the private IP RTL the ports are VIP masters and this test only
// reports that the IPs are absent (UVM_FATAL), so suites must not list it then.
// ============================================================================
`ifdef IPCAM_HD
  `define IPC(n) ipcam_hd_soc_``n
`else
  `define IPC(n) ipcam_soc_``n
`endif

package ipcam_soc_media_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4_pkg::*;
  import mem_vip_pkg::*;
  import `IPC(pkg)::*;
  import `IPC(env_pkg)::*;
  import `IPC(test_pkg)::*;

  class ipcam_soc_media_test extends `IPC(traffic_test);
    `uvm_component_utils(ipcam_soc_media_test)

    // DDR windows of the RTL ports (see get_windows in the env package)
    bit [31:0] venc_win, jpeg_win, npu_win;
    bit [31:0] y_base, c_base, jpg_out, hve_out, rec_y, rec_c;
    int w, h, ys, cs;
    int unsigned n_media;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      window_t q[$];
      super.end_of_elaboration_phase(phase);
      uvm_root::get().set_timeout(200ms, 1);
      if (vip_master(M_VENC) || vip_master(M_JPEG) || vip_master(M_NPU))
        `uvm_fatal("MEDIA", "venc / jpeg / npu are VIP masters (private IP RTL not fetched): run scripts/fetch_ext_ip.sh and regenerate")
      get_windows(-1, M_VENC, q); venc_win = q[0].base;
      get_windows(-1, M_JPEG, q); jpeg_win = q[0].base;
      get_windows(-1, M_NPU, q);  npu_win  = q[0].base;
      y_base  = venc_win;
      hve_out = venc_win + 32'h0100_0000;
      rec_y   = venc_win + 32'h0200_0000;
      rec_c   = venc_win + 32'h0280_0000;
      jpg_out = jpeg_win;
    endfunction

    // ---------------------------------------------------------- helpers
    function bit [31:0] slot(int s);
      return APB_BASE + (s << 12);
    endfunction
    task wr32(bit [31:0] a, bit [31:0] d);
      axi4_resp_e r;
      axi4_api::write32(env.m_agent[M_CPU].sqr, a, d, r);
      if (r != AXI4_OKAY) `uvm_error("MEDIA", $sformatf("CPU write %08h = %08h: %s", a, d, r.name()))
    endtask
    task rd32(bit [31:0] a, output bit [31:0] d);
      axi4_resp_e r;
      axi4_api::read32(env.m_agent[M_CPU].sqr, a, d, r);
      if (r != AXI4_OKAY) `uvm_error("MEDIA", $sformatf("CPU read %08h: %s", a, r.name()))
    endtask
    function void check(string what, longint got, longint exp);
      n_media++;
      if (got != exp) `uvm_error("MEDIA", $sformatf("%s: got %0h, expected %0h", what, got, exp))
    endfunction
    // DDR backdoor: each channel model holds the bytes of its own addresses
    function mem_model ddr(bit [31:0] a);
      return cfg.s_mem[S_DDR_FIRST + dram_channel(a)];
    endfunction
    function void poke(bit [31:0] a, byte unsigned b);
      ddr(a).write_byte(a, b);
    endfunction
    function byte unsigned peek(bit [31:0] a);
      return ddr(a).read_byte(a);
    endfunction
    // poll a W1C/level status register until (v & mask) != 0
    task wait_bit(string what, bit [31:0] a, bit [31:0] mask, int unsigned max_us);
      bit [31:0] v;
      realtime t0 = $realtime;
      do begin
        #(200 * TCK * 1ns);
        rd32(a, v);
      end while ((v & mask) == 0 && $realtime - t0 < max_us * 1us);
      if ((v & mask) == 0) `uvm_error("MEDIA", $sformatf("%s: no completion after %0d us", what, max_us))
      else `uvm_info("MEDIA", $sformatf("%s done after %0.1f us", what, ($realtime - t0) / 1us), UVM_LOW)
    endtask

    function string vec_file(string plusarg, string suffix);
      string f, v;
      if ($value$plusargs({plusarg, "=%s"}, f)) return f;
      if ($value$plusargs("vec=%s", v)) return {"regress/vectors/ipcam/", v, suffix};
      return "";
    endfunction

    function void load_frame();
      string fin = vec_file("in", ".yuv");
      int fd;
      if (fin == "") `uvm_fatal("MEDIA", "+vec=<name> or +in=<nv12 file> missing")
      if (!$value$plusargs("w=%d", w)) w = 64;
      if (!$value$plusargs("h=%d", h)) h = 48;
      ys = (w + 7) / 8 * 8;
      cs = ys;
      c_base = (y_base + ys * h + 32'h1000) & ~32'h7;
      fd = $fopen(fin, "rb");
      if (fd == 0) `uvm_fatal("MEDIA", {"cannot open ", fin})
      for (int r = 0; r < h; r++)
        for (int x = 0; x < w; x++) poke(y_base + r * ys + x, 8'($fgetc(fd)));
      for (int r = 0; r < h / 2; r++)
        for (int x = 0; x < w; x++) poke(c_base + r * cs + x, 8'($fgetc(fd)));
      $fclose(fd);
      `uvm_info("MEDIA", $sformatf("frame %0dx%0d from %s: Y %08h C %08h", w, h, fin, y_base, c_base), UVM_LOW)
    endfunction

    function void compare_ref(string what, string plusarg, string suffix, bit [31:0] base, int unsigned nbytes);
      string f = vec_file(plusarg, suffix);
      int fd, c;
      int unsigned i;
      if (f == "") return;
      fd = $fopen(f, "rb");
      if (fd == 0) begin `uvm_error("MEDIA", {"cannot open reference ", f}) return; end
      n_media++;
      for (i = 0; i < nbytes; i++) begin
        c = $fgetc(fd);
        if (c < 0) begin `uvm_error("MEDIA", $sformatf("%s: %0d bytes, reference %s is shorter", what, nbytes, f)) break; end
        if (8'(c) !== peek(base + i)) begin
          `uvm_error("MEDIA", $sformatf("%s: byte %0d is %02h, reference %02h (%s)", what, i, peek(base + i), 8'(c), f))
          break;
        end
      end
      if (i == nbytes) begin
        if ($fgetc(fd) >= 0) `uvm_error("MEDIA", $sformatf("%s: %0d bytes, reference %s is longer", what, nbytes, f))
        else `uvm_info("MEDIA", $sformatf("%s: %0d bytes match %s", what, nbytes, f), UVM_LOW)
      end
      $fclose(fd);
    endfunction

    // ---------------------------------------------------------- JPEG (c1p_jpe_regs)
    task run_jpeg();
      bit [31:0] v, nbytes, B = slot(APB_SLOT_JPEG_CFG);
      rd32(B + 'hF8, v); check("JPE_ID", v, 32'h4A50_4501);
      wr32(B + 'h10, 0);                                   // NV12
      wr32(B + 'h14, {2'b0, 14'(h), 2'b0, 14'(w)});
      wr32(B + 'h18, y_base);
      wr32(B + 'h1C, c_base);
      wr32(B + 'h20, {16'(cs), 16'(ys)});
      wr32(B + 'h24, jpg_out);
      wr32(B + 'h28, 32'h0010_0000);
      wr32(B + 'h2C, 0);
      wr32(B + 'h0C, 32'h3);
      wr32(B + 'h00, 32'h1);                               // start
      wait_bit("JPEG", B + 'h08, 32'h3, 20000);
      rd32(B + 'h08, v); check("JPE_IRQ_STATUS", v & 32'h3, 32'h1);
      wr32(B + 'h08, 32'h3);
      rd32(B + 'h04, v); check("JPE_STATUS idle, no error", v & 32'hF1, 0);
      rd32(B + 'h30, nbytes);
      rd32(B + 'h34, v);
      `uvm_info("MEDIA", $sformatf("JPEG: %0d bytes in %0d cycles", nbytes, v), UVM_LOW)
      compare_ref("JPEG", "jpg_ref", ".ref.jpg", jpg_out, nbytes);
    endtask

    // ---------------------------------------------------------- HEVC (c1p_hve_regs)
    task run_venc();
      bit [31:0] v, nbytes, B = slot(APB_SLOT_VENC_CFG);
      int qp, level, cw16;
      if (!$value$plusargs("qp=%d", qp)) qp = 30;
      if (!$value$plusargs("level=%d", level)) level = 30;
      cw16 = (w + 15) / 16 * 16;
      rd32(B + 'hF8, v); check("HVE_ID", v, 32'h4856_4501);
      wr32(B + 'h10, {2'b0, 14'(h), 2'b0, 14'(w)});
      wr32(B + 'h14, y_base);
      wr32(B + 'h18, c_base);
      wr32(B + 'h1C, {16'(cs), 16'(ys)});
      wr32(B + 'h20, rec_y);
      wr32(B + 'h24, rec_c);
      wr32(B + 'h28, {16'(cw16), 16'(cw16)});
      wr32(B + 'h2C, hve_out);
      wr32(B + 'h30, 32'h0010_0000);
      wr32(B + 'h34, {8'(level), 2'b0, 6'd19, 5'd0, 1'b0, 1'b1, 1'b1, 2'b0, 6'(qp)});  // IDR, VPS/SPS/PPS, rec
      wr32(B + 'h38, 0);
      wr32(B + 'h3C, 32'h4444_4447);
      wr32(B + 'h40, 32'h4);
      wr32(B + 'h0C, 32'h7);
      wr32(B + 'h00, 32'h1);
      wait_bit("VENC", B + 'h08, 32'h3, 40000);
      rd32(B + 'h08, v); check("HVE_IRQ_STATUS", v & 32'h3, 32'h1);
      wr32(B + 'h08, 32'h7);
      rd32(B + 'h04, v); check("HVE_STATUS idle, no error", v & 32'hF1, 0);
      rd32(B + 'h48, nbytes);
      rd32(B + 'h50, v);
      `uvm_info("MEDIA", $sformatf("VENC: %0d bytes in %0d cycles", nbytes, v), UVM_LOW)
      compare_ref("HEVC", "hevc_ref", ".ref.265", hve_out, nbytes);
    endtask

    // ---------------------------------------------------------- NPU (npu_ss_regs)
    task run_npu();
      bit [31:0] v, B = slot(APB_SLOT_NPU_CFG);
      bit [31:0] src = npu_win, dst = npu_win + 32'h0100_0000;
      int nl, rounds;
      if (!$value$plusargs("npu_lines=%d", nl)) nl = 16;
      if (!$value$plusargs("npu_rounds=%d", rounds)) rounds = 2;
      rd32(B + 'h000, v); check("NPU ID", v, 32'h584E_0200);
      for (int r = 0; r < rounds; r++) begin
        bit [31:0] s = src + r * nl * 64, d = dst + r * nl * 64;
        bit [7:0] got [$];
        int unsigned bad = 0;
        for (int i = 0; i < nl * 64; i++) poke(s + i, 8'($urandom));
        wr32(B + 'h060, {16'(nl), 8'(2 * r + 1), 2'b00, 1'b0, 2'b00, 1'b0, 2'd1});   // DMA_LD ext -> L2 0
        wr32(B + 'h064, s >> 6);
        wr32(B + 'h068, 0);
        wr32(B + 'h06C, 0);
        wr32(B + 'h074, 0);
        wr32(B + 'h060, {16'(nl), 8'(2 * r + 2), 2'b00, 1'b0, 2'b00, 1'b1, 2'd2});   // DMA_ST (wait) L2 0 -> ext
        wr32(B + 'h064, d >> 6);
        wr32(B + 'h074, 0);
        for (int tries = 0; got.size() < 2 && tries < 400; tries++) begin
          rd32(B + 'h080, v);                               // CPL_POP
          if (v[31]) got.push_back(v[7:0]);
          else #(100 * TCK * 1ns);
        end
        check($sformatf("NPU round %0d completions", r), got.size(), 2);
        if (got.size() == 2) begin
          check("NPU completion id LD", got[0], 2 * r + 1);
          check("NPU completion id ST", got[1], 2 * r + 2);
        end
        for (int i = 0; i < nl * 64; i++) if (peek(s + i) !== peek(d + i)) bad++;
        check($sformatf("NPU round %0d: bytes differing between src and dst", r), bad, 0);
      end
      rd32(B + 'h010, v); check("NPU IRQ_STATUS errors", v & 32'h8000_0006, 0);
    endtask

    task body();
      load_frame();
      fork
        if (!$test$plusargs("MEDIA_ONLY")) super.body();
        run_jpeg();
        run_venc();
        run_npu();
      join
      check_sd();
    endtask

    // SD and eMMC hosts (open-ip SD / eMMC) run init and write/read-back rounds on its own
    // against the device models (sdc_model / emd_model, spec pins_vip); any CRC,
    // timeout or compare problem sets IRQ_STATUS.ERR.
    task check_sd();
      bit [31:0] v, B = slot(APB_SLOT_SD);
      rd32(B + 'h000, v); check("SD ID", v, 32'h5344_0200);
      rd32(B + 'h004, v); check("SD IRQ_STATUS.ERR (card model on the pins)", v & 32'h1, 0);
      B = slot(APB_SLOT_EMMC_CTL);
      rd32(B + 'h000, v); check("eMMC ID", v, 32'h654D_0300);
      rd32(B + 'h004, v); check("eMMC IRQ_STATUS.ERR (device model on the pins)", v & 32'h1, 0);
    endtask

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("MEDIA", $sformatf("%0d media checks", n_media), UVM_LOW)
    endfunction
  endclass
endpackage
