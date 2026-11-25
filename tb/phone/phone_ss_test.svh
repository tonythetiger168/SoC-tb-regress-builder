// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_ss_test -- the real-IP build: every open-ip subsystem IP runs a job
// ----------------------------------------------------------------------------
// Needs +define+PHONE_REAL_IPS (suite phone_real). Software runs on the SEC
// port (cfg.host_m) and programs each IP through the RAL; the IPs then move
// data through the NoC, the IOMMUs and the 32 LPDDR5 channels while the
// scoreboard checks every burst and the latency collector records every path.
// After each job the test compares the IP's output buffer (read through the
// memory backdoor) and its result registers with a reference model written
// from the IP's datasheet (open-ip docs/ip/<P>.md):
//
//   CPU_Cluster  WRITE pattern, CHECK it (MISMATCHES = 0), COPY
//   GPU          COPY, FILL, BLEND, INVERT
//   NPU          int8 4-tap convolution, bias, ReLU, shift, SATURATIONS
//   ISP          test pattern, black level, gain, STAT_SUM
//   Display      scan-out, FRAME_CRC (CRC-32 of the pixels)
//   Video_Codec  VENC encodes through IOMMU 4 (IOVA), VDEC decodes: the
//                decoded frame equals the source, CHECKSUMs match
//   Modem        scramble + CRC, descramble gives the block back
//   DMA          4 channels at once, COPY and FILL, CHECKSUM
//   Audio_DSP    stereo gain with saturation, PEAK / CLIPS, MUTE
//   Sensor_Hub   averaged batch, LAST_AVG
//   Timer_WDT    periodic timestamp records in memory
//   Interrupt_Controller  every job's DONE interrupt shows up in its event log
// Plusargs: +SS_LEN=<words per job> (default 256).
// ============================================================================
class phone_ss_test extends phone_base_test;
  `uvm_component_utils(phone_ss_test)
  int unsigned len = 256;
  int unsigned n_fail;
  int unsigned n_jobs;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void configure();
    int v;
    if ($value$plusargs("SS_LEN=%d", v)) len = v;
  endfunction

  // ---------------------------------------------------------------- helpers
  function void put(bit [31:0] a, bit [31:0] w[$]);
    foreach (w[i]) begin
      cfg.dram_poke32(a + 4 * i, w[i]);
      env.sb.note_ddr_backdoor(a + 4 * i, w[i]);
    end
  endfunction

  function void rand_buf(bit [31:0] a, int unsigned n, ref bit [31:0] w[$]);
    w.delete();
    repeat (n) w.push_back($urandom());
    put(a, w);
  endfunction

  function void get(bit [31:0] a, int unsigned n, ref bit [31:0] w[$]);
    w.delete();
    for (int unsigned i = 0; i < n; i++) w.push_back(cfg.dram_peek32(a + 4 * i));
  endfunction

  function void expect_buf(string what, bit [31:0] a, bit [31:0] exp[$]);
    bit [31:0] got[$];
    int unsigned bad = 0;
    get(a, exp.size(), got);
    foreach (exp[i])
      if (got[i] !== exp[i]) begin
        if (bad < 4) `uvm_error("SS", $sformatf("%s: word %0d at %08h = %08h, expected %08h", what, i,
                                                  a + 4 * i, got[i], exp[i]))
        bad++;
      end
    if (bad) n_fail++;
    else `uvm_info("SS", $sformatf("%s: %0d words match the reference model", what, exp.size()), UVM_LOW)
  endfunction

  function void expect_val(string what, bit [31:0] got, bit [31:0] exp);
    if (got !== exp) begin
      `uvm_error("SS", $sformatf("%s = %08h, expected %08h", what, got, exp))
      n_fail++;
    end else `uvm_info("SS", $sformatf("%s = %08h as expected", what, got), UVM_LOW)
  endfunction

  task w(phone_ip_block b, string r, bit [31:0] d);
    reg_write(b.r(r), d);
  endtask

  task rd(phone_ip_block b, string r, output bit [31:0] d);
    uvm_reg_data_t v;
    reg_read(b.r(r), v);
    d = 32'(v);
  endtask

  // start a job (CMD bit), wait until STATUS & busy_mask clears, check the error bit
  task run_job(phone_ip_block b, string what, bit [31:0] cmd = 1, bit [31:0] busy_mask = 1,
               bit [31:0] err_mask = 2);
    bit [31:0] st;
    int unsigned polls = 0;
    w(b, "CMD", cmd);
    n_jobs++;
    do begin
      #1us;
      rd(b, "STATUS", st);
      if (++polls > 2000) begin
        `uvm_error("SS", $sformatf("%s: still busy after 2 ms (STATUS %08h)", what, st))
        n_fail++;
        return;
      end
    end while (st & busy_mask);
    if (st & err_mask) begin
      `uvm_error("SS", $sformatf("%s: job ended with an AXI error (STATUS %08h)", what, st))
      n_fail++;
    end
  endtask

  // ---------------------------------------------------------------- models
  static function bit [31:0] crc32(bit [31:0] q[$]);
    bit [31:0] c = '1;
    foreach (q[i])
      for (int b = 0; b < 4; b++) begin
        c ^= 32'(q[i][8*b +: 8]);
        repeat (8) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : c >> 1;
      end
    return ~c;
  endfunction

  static function bit [7:0] sat8(int v);
    return (v > 127) ? 8'h7F : (v < -128) ? 8'h80 : 8'(v);
  endfunction

  static function bit [15:0] sat16(int v);
    return (v > 32767) ? 16'h7FFF : (v < -32768) ? 16'h8000 : 16'(v);
  endfunction

  // ---------------------------------------------------------------- jobs
  task job_cpu();
    phone_ip_block b = env.regmodel.ss_cpu;
    bit [31:0] a = dram(M_CPU, 32'h10_0000), c = dram(M_CPU, 32'h20_0000), seed = $urandom();
    bit [31:0] exp[$], res;
    for (int unsigned i = 0; i < len; i++) exp.push_back(seed ^ {~16'(i), 16'(i)});
    w(b, "IRQ_ENABLE", 1);
    w(b, "DST_ADDR", a); w(b, "LEN", len); w(b, "SEED", seed); w(b, "CTRL", 0);   // WRITE
    run_job(b, "CPU WRITE");
    expect_buf("CPU WRITE pattern", a, exp);
    w(b, "SRC_ADDR", a); w(b, "CTRL", 1);                                         // CHECK
    run_job(b, "CPU CHECK");
    rd(b, "RESULT", res);
    expect_val("CPU CHECK RESULT.MISMATCHES", res[15:0], 0);
    w(b, "DST_ADDR", c); w(b, "CTRL", 2);                                         // COPY
    run_job(b, "CPU COPY");
    expect_buf("CPU COPY", c, exp);
  endtask

  task job_gpu();
    phone_ip_block b = env.regmodel.ss_gpu;
    bit [31:0] src = dram(M_GPU, 32'h10_0000), dst = dram(M_GPU, 32'h20_0000);
    bit [31:0] s[$], exp[$], color = $urandom(), px;
    int unsigned alpha = $urandom_range(0, 256);
    rand_buf(src, len, s);
    w(b, "IRQ_ENABLE", 1);
    w(b, "SRC_ADDR", src); w(b, "LEN", len); w(b, "COLOR", color);
    for (int mode = 0; mode < 4; mode++) begin
      bit [31:0] d = dst + mode * 32'h1_0000;
      exp.delete();
      foreach (s[i]) begin
        case (mode)
          0: px = s[i];
          1: px = color;
          2: for (int ch = 0; ch < 4; ch++)
               px[8*ch +: 8] = 8'((int'(s[i][8*ch +: 8]) * int'(alpha) +
                                   int'(color[8*ch +: 8]) * (256 - int'(alpha))) >> 8);
          default: px = {s[i][31:24], ~s[i][23:0]};
        endcase
        exp.push_back(px);
      end
      w(b, "DST_ADDR", d); w(b, "CTRL", {21'b0, 9'(alpha), 2'(mode)});
      run_job(b, $sformatf("GPU mode %0d", mode));
      begin
        string mn[4] = '{"COPY", "FILL", "BLEND", "INVERT"};
        expect_buf({"GPU ", mn[mode]}, d, exp);
      end
    end
  endtask

  task job_npu();
    phone_ip_block b = env.regmodel.ss_npu;
    bit [31:0] src = dram(M_APU, 32'h10_0000), dst = dram(M_APU, 32'h20_0000);
    bit [31:0] s[$], exp[$], sat;
    byte x[$];
    byte wt[4];
    shortint bias = shortint'($urandom_range(0, 2000)) - 16'sd1000;
    int unsigned shift = $urandom_range(2, 7), n_sat = 0;
    bit relu = $urandom_range(0, 1);
    foreach (wt[k]) wt[k] = byte'($urandom());
    rand_buf(src, len, s);
    foreach (s[i]) for (int k = 0; k < 4; k++) x.push_back(byte'(s[i][8*k +: 8]));
    foreach (x[n]) begin
      int acc = bias;
      bit [7:0] y;
      for (int k = 0; k < 4; k++) if (n - k >= 0) acc += int'(wt[k]) * int'(x[n - k]);
      if (relu && acc < 0) acc = 0;
      acc = acc >>> shift;
      y = sat8(acc);
      if (acc > 127 || acc < -128) n_sat++;
      if (n % 4 == 0) exp.push_back(0);
      exp[n / 4][8 * (n % 4) +: 8] = y;
    end
    w(b, "IRQ_ENABLE", 1);
    w(b, "SRC_ADDR", src); w(b, "DST_ADDR", dst); w(b, "LEN", len);
    w(b, "WEIGHTS", {wt[3], wt[2], wt[1], wt[0]});
    w(b, "CTRL", {11'b0, relu, 4'(shift), bias});
    run_job(b, "NPU conv");
    expect_buf("NPU conv", dst, exp);
    rd(b, "SATURATIONS", sat);
    expect_val("NPU SATURATIONS", sat[15:0], (n_sat > 16'hFFFF) ? 16'hFFFF : n_sat);
  endtask

  task job_isp();
    phone_ip_block b = env.regmodel.ss_isp;
    bit [31:0] dst = dram(M_ISP, 32'h10_0000), exp[$], sum = 0, got_sum;
    bit [7:0]  seed = $urandom(), black = $urandom_range(0, 40), gain = $urandom_range(8, 40);
    int unsigned lw = 64;
    for (int unsigned i = 0; i < len; i++) begin
      bit [31:0] wd;
      int unsigned x = i % lw, y = i / lw;
      for (int p = 0; p < 4; p++) begin
        int px = int'(8'((4 * x + p + y) % 256) ^ seed);
        int o = ((px > black ? px - black : 0) * gain) >> 4;
        if (o > 255) o = 255;
        wd[8*p +: 8] = 8'(o);
        sum += o;
      end
      exp.push_back(wd);
    end
    w(b, "IRQ_ENABLE", 1);
    w(b, "DST_ADDR", dst); w(b, "LEN", len); w(b, "LINE", lw);
    w(b, "CTRL", {7'b0, gain, black, seed, 1'b0});     // test pattern
    run_job(b, "ISP frame");
    expect_buf("ISP frame", dst, exp);
    rd(b, "STAT_SUM", got_sum);
    expect_val("ISP STAT_SUM", got_sum, sum);
  endtask

  task job_disp();
    phone_ip_block b = env.regmodel.ss_disp;
    bit [31:0] src = dram(M_DISP, 32'h10_0000), s[$], crc;
    rand_buf(src, len, s);
    w(b, "IRQ_ENABLE", 1);
    w(b, "SRC_ADDR", src); w(b, "LEN", len); w(b, "LINE", 32);
    run_job(b, "Display scan-out");
    rd(b, "FRAME_CRC", crc);
    expect_val("Display FRAME_CRC", crc, crc32(s));
  endtask

  // VENC (behind IOMMU 4) encodes through IOVAs; VDEC decodes the physical bitstream
  task job_video();
    phone_ip_block be = env.regmodel.ss_venc, bd = env.regmodel.ss_vdec;
    int mi = iommu_of(M_VENC);
    int unsigned lw = 32, npg = (len * 4 + 32'hFFF) / 32'h1000;
    bit [31:0] src = dram(M_VENC, 32'h10_0000), bs = dram(M_VENC, 32'h20_0000), out = dram(M_VDEC, 32'h10_0000);
    bit [31:0] s[$], exp[$], cs_e, cs_d, sum = 0;
    rand_buf(src, len, s);
    // residuals: out = x - pred, pred = previous sample, 128 at the start of each line
    foreach (s[i]) begin
      bit [31:0] r;
      bit [7:0] pred;
      if (i % lw == 0) pred = 8'd128;
      else pred = s[i - 1][31:24];
      for (int k = 0; k < 4; k++) begin
        r[8*k +: 8] = s[i][8*k +: 8] - pred;
        pred = s[i][8*k +: 8];
      end
      exp.push_back(r);
      sum += s[i];
    end
    // IOVA pages 0..npg-1 = src, npg..2*npg-1 = bitstream
    for (int unsigned k = 0; k < npg; k++) begin
      map_page(mi, k, src + k * 32'h1000);
      map_page(mi, npg + k, bs + k * 32'h1000);
    end
    iommu_enable(mi, 2 * npg);
    w(be, "IRQ_ENABLE", 1);
    w(be, "SRC_ADDR", iova(0)); w(be, "DST_ADDR", iova(npg)); w(be, "LEN", len);
    w(be, "LINE", lw); w(be, "CTRL", 0);                   // ENCODE
    run_job(be, "VENC encode (IOMMU)");
    expect_buf("VENC bitstream", bs, exp);
    w(bd, "IRQ_ENABLE", 1);
    w(bd, "SRC_ADDR", bs); w(bd, "DST_ADDR", out); w(bd, "LEN", len);
    w(bd, "LINE", lw); w(bd, "CTRL", 1);                   // DECODE
    run_job(bd, "VDEC decode");
    expect_buf("VDEC decode(encode(frame)) = frame", out, s);
    rd(be, "CHECKSUM", cs_e);
    rd(bd, "CHECKSUM", cs_d);
    expect_val("VENC CHECKSUM", cs_e, sum);
    expect_val("VDEC CHECKSUM", cs_d, sum);
  endtask

  task job_modem();
    phone_ip_block b = env.regmodel.ss_modem;
    bit [31:0] a = dram(M_MODEM, 32'h10_0000), sc = dram(M_MODEM, 32'h20_0000), dsc = dram(M_MODEM, 32'h30_0000);
    bit [31:0] s[$], exp[$], seed = $urandom() | 1, st, crc;
    rand_buf(a, len, s);
    st = seed;
    foreach (s[i]) begin
      bit [31:0] key;
      for (int k = 0; k < 32; k++) begin
        key[k] = st[0];
        st = st[0] ? (st >> 1) ^ 32'h8020_0003 : st >> 1;
      end
      exp.push_back(s[i] ^ key);
    end
    w(b, "IRQ_ENABLE", 1);
    w(b, "SRC_ADDR", a); w(b, "DST_ADDR", sc); w(b, "LEN", len); w(b, "SEED", seed);
    w(b, "CTRL", 0);                                       // transmit: CRC of the payload
    run_job(b, "Modem scramble");
    expect_buf("Modem scrambled block", sc, exp);
    rd(b, "CRC", crc);
    expect_val("Modem TX CRC", crc, crc32(s));
    w(b, "SRC_ADDR", sc); w(b, "DST_ADDR", dsc); w(b, "CTRL", 1);   // receive: CRC of the output
    run_job(b, "Modem descramble");
    expect_buf("Modem descrambled block", dsc, s);
    rd(b, "CRC", crc);
    expect_val("Modem RX CRC", crc, crc32(s));
  endtask

  task job_dma();
    phone_ip_block b = env.regmodel.ss_dma;
    bit [31:0] src[4], dst[4], fill[4], s[4][$], exp[$], cs, st;
    bit [3:0]  mode = 4'b1010;                             // channels 1, 3 FILL
    w(b, "IRQ_ENABLE", 1);
    for (int c = 0; c < 4; c++) begin
      src[c]  = dram(M_DMA, 32'h10_0000 + c * 32'h1_0000);
      dst[c]  = dram(M_DMA, 32'h20_0000 + c * 32'h1_0000);
      fill[c] = $urandom();
      if (!mode[c]) rand_buf(src[c], len, s[c]);
      w(b, $sformatf("SRC%0d", c), src[c]); w(b, $sformatf("DST%0d", c), dst[c]);
      w(b, $sformatf("LEN%0d", c), len);    w(b, $sformatf("FILL%0d", c), fill[c]);
    end
    w(b, "MODE", mode);
    run_job(b, "DMA 4 channels", 4'hF, 32'h1F, 32'h80);   // queue all four
    for (int c = 0; c < 4; c++) begin
      exp.delete();
      for (int unsigned i = 0; i < len; i++) exp.push_back(mode[c] ? fill[c] : s[c][i]);
      expect_buf($sformatf("DMA ch%0d %s", c, mode[c] ? "FILL" : "COPY"), dst[c], exp);
    end
    rd(b, "CHECKSUM", cs);
    rd(b, "STATUS", st);
    begin                                                  // CHECKSUM: words written by the last job
      int c = st[6:5];
      bit [31:0] sum = 0;
      for (int unsigned i = 0; i < len; i++) sum += mode[c] ? fill[c] : s[c][i];
      expect_val($sformatf("DMA CHECKSUM (last job, ch%0d)", c), cs, sum);
    end
  endtask

  task job_audio();
    phone_ip_block b = env.regmodel.ss_adsp;
    bit [31:0] src = dram(M_ADSP, 32'h10_0000), dst = dram(M_ADSP, 32'h20_0000);
    bit [31:0] s[$], exp[$], zero[$], meter;
    shortint gl = 16'sh0180, gr = -16'sh0100;              // +3.5 dB, -1.0 (inverted)
    int unsigned peak = 0, clips = 0;
    rand_buf(src, len, s);
    foreach (s[i]) begin
      int y[2];
      y[0] = (int'(signed'(s[i][15:0])) * int'(gl)) >>> 8;
      y[1] = (int'(signed'(s[i][31:16])) * int'(gr)) >>> 8;
      for (int c = 0; c < 2; c++) begin
        int v = int'(signed'(sat16(y[c])));
        if (y[c] > 32767 || y[c] < -32768) clips++;
        if ((v < 0 ? -v : v) > peak) peak = (v < 0 ? -v : v);
      end
      exp.push_back({sat16(y[1]), sat16(y[0])});
      zero.push_back(0);
    end
    w(b, "IRQ_ENABLE", 1);
    w(b, "SRC_ADDR", src); w(b, "DST_ADDR", dst); w(b, "LEN", len);
    w(b, "GAIN", {gr, gl}); w(b, "CTRL", 0);
    run_job(b, "Audio gain");
    expect_buf("Audio gain", dst, exp);
    rd(b, "METER", meter);
    expect_val("Audio METER.PEAK", meter[15:0], peak);
    expect_val("Audio METER.CLIPS", meter[31:16], clips);
    w(b, "DST_ADDR", dst + 32'h1_0000); w(b, "CTRL", 2);  // MUTE
    run_job(b, "Audio mute");
    expect_buf("Audio mute", dst + 32'h1_0000, zero);
  endtask

  task job_sensor();
    phone_ip_block b = env.regmodel.ss_sens;
    bit [31:0] dst = dram(M_SCP, 32'h10_0000), got[$], smp, init[$];
    int unsigned n = 32;
    repeat (n) init.push_back(32'hDEAD_BEEF);
    put(dst, init);
    w(b, "IRQ_ENABLE", 1);
    w(b, "DST_ADDR", dst); w(b, "LEN", n); w(b, "CTRL", 2);   // average 4 samples
    run_job(b, "Sensor hub batch");
    get(dst, n, got);
    rd(b, "SAMPLE", smp);
    expect_val("Sensor hub DROPS", smp[31:16], 0);
    expect_val("Sensor hub LAST_AVG = last average written", smp[15:0], got[n - 1][31:16]);
    foreach (got[i]) if (got[i] == 32'hDEAD_BEEF) begin
      `uvm_error("SS", $sformatf("Sensor hub: word %0d of the batch was not written", i))
      n_fail++;
      break;
    end
  endtask

  // ---------------------------------------------------------------- main
  task main();
    phone_ip_block blks[$];
    bit [31:0] ts_base = dram(M_SCP, 32'h20_0000), log_base = dram(M_SCP, 32'h30_0000);
    bit [31:0] d, rec[$], wp, claim;
    if (!cfg.real_ips) begin
      `uvm_fatal("SS", "phone_ss_test needs the real-IP build (+define+PHONE_REAL_IPS, suite phone_real)")
    end
    // every subsystem IP answers with its ID
    foreach (env.regmodel.ss[i]) begin
      rd(env.regmodel.ss[i], "ID", d);
      expect_val({env.regmodel.ss[i].get_name(), " ID"}, d, 32'(env.regmodel.ss[i].r("ID").get_reset()));
    end
    // interrupt controller: log every subsystem interrupt (sources 13..24)
    w(env.regmodel.ss_intc, "ENABLE", 32'h01FF_E000);
    w(env.regmodel.ss_intc, "LOG_BASE", log_base);
    w(env.regmodel.ss_intc, "LOG_CTRL", {15'd0, 16'd64, 1'b1});
    // timer: an event every 50 ticks of 4 clocks, timestamp records
    w(env.regmodel.ss_tmr, "IRQ_ENABLE", 1);
    w(env.regmodel.ss_tmr, "PERIOD", 49);
    w(env.regmodel.ss_tmr, "TS_BASE", ts_base);
    w(env.regmodel.ss_tmr, "TS_WORDS", 16);
    w(env.regmodel.ss_tmr, "CTRL", {13'b0, 1'b0, 1'b1, 1'b1, 16'd3});   // TS_EN, TMR_EN, prescale 3
    fork
      job_cpu();
      job_gpu();
      job_npu();
      job_isp();
      job_disp();
      job_video();
      job_modem();
      job_dma();
      job_audio();
      job_sensor();
    join
    // stop the timer, check its records: consecutive events 50 ticks apart
    w(env.regmodel.ss_tmr, "CTRL", 32'd3);
    #2us;
    rd(env.regmodel.ss_tmr, "TS_STATE", wp);
    if (wp[15:0] < 2) begin
      `uvm_error("SS", $sformatf("Timer wrote %0d timestamp records", wp[15:0])) n_fail++;
    end else begin
      // ring of 16 words: the oldest record still there is record max(0, wp - 16)
      int unsigned n = (wp[15:0] > 16) ? 16 : wp[15:0], first = wp[15:0] - n;
      get(ts_base, 16, rec);
      for (int unsigned k = first + 1; k < first + n; k++)
        if (rec[k % 16] - rec[(k - 1) % 16] != 50) begin
          `uvm_error("SS", $sformatf("Timer record %0d = %0d, record %0d = %0d: not 50 ticks apart",
                                     k - 1, rec[(k - 1) % 16], k, rec[k % 16]))
          n_fail++;
          break;
        end
      `uvm_info("SS", $sformatf("Timer: %0d timestamp records (%0d missed)", wp[15:0], wp[31:16]), UVM_LOW)
    end
    // interrupt controller: one log record per subsystem interrupt source
    #2us;
    rd(env.regmodel.ss_intc, "STATE", wp);
    get(log_base, 64, rec);
    begin
      bit [31:0] seen = 0;
      for (int unsigned k = 0; k < wp[15:0] && k < 64; k++) seen[rec[k][4:0]] = 1;
      expect_val("Interrupt controller: sources logged", seen, 32'h01FF_E000);
      expect_val("Interrupt controller: cpu_irq", wp[16], 1);
      rd(env.regmodel.ss_intc, "CLAIM", claim);
      expect_val("Interrupt controller: CLAIM", claim, 32'h8000_000D);   // lowest pending: CPU_Cluster
    end
    `uvm_info("SS", $sformatf("%0d jobs on 12 subsystem IPs, %0d reference-model mismatches", n_jobs, n_fail),
              UVM_NONE)
  endtask
endclass
