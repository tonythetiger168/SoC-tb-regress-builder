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
// (spec pins_vip) and must end without IRQ_STATUS.ERR. The CSI-2 receiver,
// GbE MAC and I2S port are fed by sensor / PHY / codec models
// (tb/ipcam_soc/devices) and their received data is checked.
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
    function void chk(string what, longint got, longint exp);
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
      rd32(B + 'hF8, v); chk("JPE_ID", v, 32'h4A50_4501);
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
      rd32(B + 'h08, v); chk("JPE_IRQ_STATUS", v & 32'h3, 32'h1);
      wr32(B + 'h08, 32'h3);
      rd32(B + 'h04, v); chk("JPE_STATUS idle, no error", v & 32'hF1, 0);
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
      rd32(B + 'hF8, v); chk("HVE_ID", v, 32'h4856_4501);
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
      rd32(B + 'h08, v); chk("HVE_IRQ_STATUS", v & 32'h3, 32'h1);
      wr32(B + 'h08, 32'h7);
      rd32(B + 'h04, v); chk("HVE_STATUS idle, no error", v & 32'hF1, 0);
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
      rd32(B + 'h000, v); chk("NPU ID", v, 32'h584E_0200);
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
        chk($sformatf("NPU round %0d completions", r), got.size(), 2);
        if (got.size() == 2) begin
          chk("NPU completion id LD", got[0], 2 * r + 1);
          chk("NPU completion id ST", got[1], 2 * r + 2);
        end
        for (int i = 0; i < nl * 64; i++) if (peek(s + i) !== peek(d + i)) bad++;
        chk($sformatf("NPU round %0d: bytes differing between src and dst", r), bad, 0);
      end
      rd32(B + 'h010, v); chk("NPU IRQ_STATUS errors", v & 32'h8000_0006, 0);
    endtask

    task body();
      load_frame();
      setup_eth();
      fork
        if (!$test$plusargs("MEDIA_ONLY")) super.body();
        run_jpeg();
        run_venc();
        run_npu();
      join
      check_sd();
      check_csi2();
      check_eth();
      check_i2s();
      check_xip();
      check_sccb();
    endtask

    // SD and eMMC hosts (open-ip SD / eMMC) run init and write/read-back rounds on its own
    // against the device models (sdc_model / emd_model, spec pins_vip); any CRC,
    // timeout or compare problem sets IRQ_STATUS.ERR.
    task check_sd();
      bit [31:0] v, B = slot(APB_SLOT_SD);
      rd32(B + 'h000, v); chk("SD ID", v, 32'h5344_0200);
      rd32(B + 'h004, v); chk("SD IRQ_STATUS.ERR (card model on the pins)", v & 32'h1, 0);
      B = slot(APB_SLOT_EMMC_CTL);
      rd32(B + 'h000, v); chk("eMMC ID", v, 32'h654D_0300);
      rd32(B + 'h004, v); chk("eMMC IRQ_STATUS.ERR (device model on the pins)", v & 32'h1, 0);
    endtask

    // CSI-2 receiver fed by csi2_tx_model (2 frames x 4 RAW8 lines of 16 B):
    // frame / line counts, no errors, and the last line in the line buffer
    // (pixel j of line l, frame f = j ^ l*37 ^ f*101, l and f counted from 1).
    task check_csi2();
      bit [31:0] v, B = slot(APB_SLOT_CSI2);
      rd32(B + 'h000, v); chk("CSI2 ID", v, 32'h4332_0200);
      rd32(B + 'h018, v); chk("CSI2 frames received", v[15:0], 2);
                          chk("CSI2 lines in the last frame", v[31:16], 4);
      rd32(B + 'h014, v); chk("CSI2 err_flags", v[4:1], 0);
                          chk("CSI2 line buffer length", v[20:5], 16);
      rd32(B + 'h01C, v); chk("CSI2 last header is Frame End (VC 0, DT 0x01)", v[7:0], 8'h01);
      for (int j = 0; j < 16; j++) begin
        wr32(B + 'h020, j);
        rd32(B + 'h024, v);
        chk($sformatf("CSI2 last line byte %0d", j), v[7:0], 8'(j) ^ 8'(4 * 37) ^ 8'(2 * 101));   // line 4 of frame 2
      end
    endtask

    // GbE MAC with gmii_phy_model: the PHY sends 2 frames to the MAC's
    // address (set by setup_eth). Nobody drains RX during the media run, so
    // RX keeps the first beat it captured (later ones overflow): it must be
    // the first DA byte of a frame for this station, with no fragment seen.
    task setup_eth();
      bit [31:0] B = slot(APB_SLOT_ETH_MAC);
      wr32(B + 'h018, 32'h5E10_0001);
      wr32(B + 'h01C, 32'h0000_0200);
    endtask

    task check_eth();
      bit [31:0] v, B = slot(APB_SLOT_ETH_MAC);
      rd32(B + 'h000, v); chk("ETH ID", v, 32'h4554_0200);
      rd32(B + 'h004, v); chk("ETH RX_AVAIL", v[5], 1);
                          chk("ETH RX_FRAG", v[2], 0);
      rd32(B + 'h024, v); chk("ETH RX first byte is DA[47:40] of the station address", v[7:0], 8'h02);
                          chk("ETH RX first beat is not rx_last", v[8], 0);
    endtask

    // I2S port, i2s_codec_model is the clock master: frames arrive and the
    // received left / right words are the codec's ADC pattern for some frame
    // n (low 16 bits of n*0x10123 ^ 0x3C3C left, ^ 0xA55A right).
    task check_i2s();
      bit [31:0] v, l, r, B = slot(APB_SLOT_I2S);
      bit hit = 0;
      rd32(B + 'h000, v); chk("I2S ID", v, 32'h4932_0200);
      rd32(B + 'h004, v); chk("I2S FRAME irq", v[0], 1);
      rd32(B + 'h01C, l);
      rd32(B + 'h020, r);
      for (int unsigned n = 1; n < 20000 && !hit; n++)
        if (l[15:0] == (16'(n * 32'h10123) ^ 16'h3C3C)) hit = 1;
      chk($sformatf("I2S RX_LEFT %04h is a codec ADC word", l[15:0]), hit, 1);
      hit = 0;
      for (int unsigned n = 1; n < 20000 && !hit; n++)
        if (r[15:0] == (16'(n * 32'h10123) ^ 16'hA55A)) hit = 1;
      chk($sformatf("I2S RX_RIGHT %04h is a codec ADC word", r[15:0]), hit, 1);
    endtask

    // Boot flash: QSPI_XIP serves the spi_nor window from snor_model (spec pins_vip), whose
    // array holds mem[i] = i ^ (i >> 8) ^ 0xA5 (16-bit addresses, so the window wraps every
    // 64 KB). XIP reads go over the NoC; the command port reads the JEDEC ID.
    function bit [7:0] flash_byte(bit [31:0] a);
      bit [15:0] i = a[15:0];
      return 8'(i) ^ 8'(i >> 8) ^ 8'hA5;
    endfunction
    task check_xip();
      bit [31:0] v, n0, B = slot(APB_SLOT_QSPI_XIP);
      bit [31:0] offs[5] = '{32'h0000_0000, 32'h0000_0104, 32'h0000_1234, 32'h0012_FFFC, 32'h0000_0108};
      rd32(B + 'h000, v); chk("QSPI_XIP ID", v, 32'h5C53_0100);
      rd32(B + 'h030, n0);
      foreach (offs[k]) begin
        bit [31:0] a = SPI_NOR_BASE + (offs[k] & ~32'h3);
        rd32(a, v);
        chk($sformatf("XIP word at flash %06h", a[23:0]), v,
              {flash_byte(a + 3), flash_byte(a + 2), flash_byte(a + 1), flash_byte(a)});
      end
      rd32(B + 'h030, v);
      chk("XIP_CMDS counts the reads", v[15:0] - n0[15:0] inside {[4:5]}, 1);   // 0x104 -> 0x108 may continue the stream
      wr32(B + 'h004, 32'h1);                                       // clear PC_DONE
      wr32(B + 'h018, 32'h9F | (3 << 12));                          // 0x9F read ID, 3 bytes in
      wr32(B + 'h024, 32'h1);
      wait_bit("QSPI_XIP 0x9F", B + 'h004, 32'h1, 200);
      rd32(B + 'h028, v); chk("SPI-NOR JEDEC ID (EF 40 18)", v[23:0], 24'h1840EF);
    endtask

    // Sensor control: I2C_Host on i2c_sns talks SCCB to sccb_model (spec pins_vip) at 0x3C:
    // 16-bit register pointer, chip ID 0x5A31 at 0x0000, RW registers from 0x0002.
    localparam bit [7:0] SCCB_ADDR = 8'h3C << 1;
    task sccb_cmd(bit [31:0] B, bit [7:0] tx, bit [5:0] cmd, string what);
      wr32(B + 'h004, 32'h1);
      wr32(B + 'h018, tx);
      wr32(B + 'h01C, cmd);
      wait_bit(what, B + 'h004, 32'h1, 200);
    endtask
    task sccb_wr(bit [31:0] B, bit [7:0] tx, bit sta, bit sto, string what);
      bit [31:0] v;
      sccb_cmd(B, tx, 6'h05 | (sta << 1) | (sto << 4), what);   // valid | wr (| sta) (| sto)
      rd32(B + 'h020, v); chk({what, " ACK"}, v[8], 0);
    endtask
    task sccb_read(bit [31:0] B, bit [15:0] r, int n, output bit [7:0] d[$]);
      bit [31:0] v;
      d.delete();
      sccb_wr(B, SCCB_ADDR, 1, 0, $sformatf("SCCB addr W (rd %04h)", r));
      sccb_wr(B, r[15:8], 0, 0, "SCCB reg hi");
      sccb_wr(B, r[7:0], 0, 0, "SCCB reg lo");
      sccb_wr(B, SCCB_ADDR | 8'h1, 1, 0, "SCCB addr R");
      for (int k = 0; k < n; k++) begin
        bit last = k == n - 1;
        sccb_cmd(B, 0, 6'h09 | (last << 5) | (last << 4), "SCCB read byte");   // valid | rd (| nack | sto)
        rd32(B + 'h020, v);
        d.push_back(v[7:0]);
      end
    endtask
    task check_sccb();
      bit [31:0] v, B = slot(APB_SLOT_I2C_SNS);
      bit [7:0] d[$];
      rd32(B + 'h000, v); chk("I2C_Host ID", v, 32'h5C51_0100);
      wr32(B + 'h014, 32'h4);                                       // quarter SCL = 5 clocks
      sccb_read(B, 16'h0000, 2, d);
      chk("SCCB chip ID", {d[0], d[1]}, 16'h5A31);
      sccb_wr(B, SCCB_ADDR, 1, 0, "SCCB addr W (wr 0100)");
      sccb_wr(B, 8'h01, 0, 0, "SCCB reg hi");
      sccb_wr(B, 8'h00, 0, 0, "SCCB reg lo");
      sccb_wr(B, 8'hC3, 0, 0, "SCCB data 0");
      sccb_wr(B, 8'h5E, 0, 1, "SCCB data 1");
      sccb_read(B, 16'h0100, 2, d);
      chk("SCCB reg 0100 read back", d[0], 8'hC3);
      chk("SCCB reg 0101 read back", d[1], 8'h5E);
      rd32(B + 'h024, v); chk("I2C bus released", v[1:0], 0);
    endtask

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("MEDIA", $sformatf("%0d media checks", n_media), UVM_LOW)
    endfunction
  endclass
endpackage
