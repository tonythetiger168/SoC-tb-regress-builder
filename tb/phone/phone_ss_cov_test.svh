// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_ss_cov_test -- real-IP build: every subsystem IP's DMA settings
// ----------------------------------------------------------------------------
// Coverage closure of the IP cluster wrapper (rtl/phone/phone_ss_ips.sv) and
// the SoC's interrupt / sideband wiring. Needs +define+PHONE_REAL_IPS and
// +SS_PINS (the testbench's I2C / SPI controllers, ISP sensor stream, panel
// back-pressure and full-range sensor-hub samples).
//   1. every IP's reference-model jobs (phone_ss_test) at job lengths 256, 1,
//      2, 4, 8 and 17 words: every AxLEN the engines issue (0, 1, 3, 7, 15)
//   2. sensor-hub batches of 1..17 words, the wake interrupt, the ISP on its
//      external sensor stream
//   3. always-on IPs (sensor hub, interrupt controller, timer) through
//      complementary buffer addresses, one of them unmapped (DECERR)
//   4. every IP's read and write side on an unmapped address (DECERR), and
//      every IOMMU-backed IP through an IOMMU fault (SLVERR)
//   5. interrupts: GPIO, UART, I2C, SPI, PWM, TRNG, SRAM, the six IOMMUs and
//      all subsystem IPs raised and cleared, software interrupts 0..31 into
//      the event log, watchdog bark and bite
//   6. APB: an unmapped and two misaligned register accesses on every slot
// ============================================================================
class phone_ss_cov_test extends phone_ss_test;
  `uvm_component_utils(phone_ss_cov_test)
  localparam bit [31:0] BAD = 32'h2000_0000;       // unmapped: the default slave answers DECERR

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------- helpers
  // one unchecked access from a testbench master (the scoreboard checks it)
  task raw(int m, bit wr, bit [31:0] a);
    axi4_item t = axi4_api::make(wr, a, 1, 2, AXI4_INCR, 0);
    axi4_api::run(sqr(m), t);
  endtask

  task clear_irq(phone_ip_block b);
    w(b, "IRQ_STATUS", 32'h7);
  endtask

  // start a job and wait for it; the job is expected to end with ERR set
  task err_job(phone_ip_block b, string what, bit [31:0] cmd = 1, bit [31:0] busy_mask = 1,
               bit [31:0] err_mask = 2);
    bit [31:0] st;
    int unsigned polls = 0;
    w(b, "CMD", cmd);
    do begin
      #1us;
      rd(b, "STATUS", st);
      if (++polls > 2000) begin
        `uvm_error("SS", $sformatf("%s: still busy after 2 ms (STATUS %08h)", what, st))
        return;
      end
    end while (st & busy_mask);
    if (!(st & err_mask)) `uvm_error("SS", $sformatf("%s: no AXI error reported (STATUS %08h)", what, st))
    else `uvm_info("SS", $sformatf("%s: AXI error reported as expected", what), UVM_LOW)
    clear_irq(b);
  endtask

  task iommu_off(int i);
    reg_write(env.regmodel.iommu[i].r("CTRL"), 0);
  endtask

  // ---------------------------------------------------------------- 1, 2
  task all_jobs();
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
    foreach (env.regmodel.ss[i]) clear_irq(env.regmodel.ss[i]);
  endtask

  task sensor_batch(bit [31:0] dst, int unsigned n, bit [31:0] ctrl = 0, bit expect_err = 0);
    phone_ip_block b = env.regmodel.ss_sens;
    w(b, "DST_ADDR", dst); w(b, "LEN", n); w(b, "CTRL", ctrl);
    if (expect_err) err_job(b, $sformatf("Sensor hub batch of %0d at %08h", n, dst));
    else begin
      run_job(b, $sformatf("Sensor hub batch of %0d", n));
      clear_irq(b);
    end
  endtask

  task isp_stream();
    phone_ip_block b = env.regmodel.ss_isp;
    w(b, "DST_ADDR", dram(M_ISP, 32'h18_0000)); w(b, "LEN", 64); w(b, "LINE", 16);
    w(b, "CTRL", {7'b0, 8'd16, 8'd0, 8'd0, 1'b1});      // SRC_SEL = sensor stream, gain 1.0
    run_job(b, "ISP frame from the sensor stream");
    clear_irq(b);
  endtask

  // ---------------------------------------------------------------- 3
  task aon_addresses();
    bit [31:0] pat[3] = '{32'hAAAA_AAA8, 32'h5555_5554, 32'hAAAA_AAA8};
    phone_ip_block bi = env.regmodel.ss_intc, bt = env.regmodel.ss_tmr;
    foreach (pat[k]) begin
      bit dec = pat[k][31] == 1'b0;                     // 0x5555_xxxx: unmapped
      bit [31:0] st;
      sensor_batch(pat[k], 17, 0, dec);
      // interrupt controller: software interrupts 0..31, one log record each
      w(bi, "LOG_BASE", pat[k]); w(bi, "LOG_CTRL", {15'd0, 16'd64, 1'b1});
      w(bi, "ENABLE", 32'hFFFF_FFFF);
      for (int s = 0; s < 32; s++) begin
        w(bi, "SW_SET", 32'd1 << s);
        #200ns;
        w(bi, "SW_SET", 0);
      end
      w(bi, "LOG_CTRL", 0);
      w(bi, "ENABLE", 0);
      // timer: timestamp records every 8 ticks
      w(bt, "TS_BASE", pat[k]); w(bt, "TS_WORDS", 8); w(bt, "PERIOD", 7);
      w(bt, "IRQ_ENABLE", 7);
      w(bt, "CTRL", {13'b0, 1'b0, 1'b1, 1'b1, 16'd0});
      #2us;
      w(bt, "CTRL", 0);
      #200ns;
      clear_irq(bt); clear_irq(bi);
    end
  endtask

  // ---------------------------------------------------------------- 4
  task dma_err(bit [31:0] src, bit [31:0] dst, string what);
    phone_ip_block b = env.regmodel.ss_dma;
    w(b, "SRC0", src); w(b, "DST0", dst); w(b, "LEN0", 4); w(b, "MODE", 0);
    err_job(b, what, 1, 32'h1F, 32'h80);
  endtask

  // each IP: read side, then write side, on an unmapped address (or, with
  // iommu = 1, through an IOMMU window that does not cover the address)
  task ip_errors(bit [31:0] bad, string tag);
    phone_ip_block b;
    bit [31:0] ok;
    b = env.regmodel.ss_cpu; ok = dram(M_CPU, 32'h30_0000);
    w(b, "LEN", 4); w(b, "SRC_ADDR", bad); w(b, "DST_ADDR", ok); w(b, "CTRL", 2);
    err_job(b, {"CPU COPY read ", tag});
    w(b, "SRC_ADDR", ok); w(b, "DST_ADDR", bad);
    err_job(b, {"CPU COPY write ", tag});
    foreach (env.regmodel.ss[i]) begin
      string n;
      b = env.regmodel.ss[i];
      n = b.get_name();
      if (n inside {"ss_gpu", "ss_npu", "ss_vdec", "ss_venc", "ss_modem", "ss_adsp"}) begin
        int m = (n == "ss_gpu") ? M_GPU : (n == "ss_npu") ? M_APU : (n == "ss_vdec") ? M_VDEC :
                (n == "ss_venc") ? M_VENC : (n == "ss_modem") ? M_MODEM : M_ADSP;
        ok = dram(m, 32'h30_0000);
        w(b, "LEN", 4);
        if (n == "ss_vdec" || n == "ss_venc") begin w(b, "LINE", 4); w(b, "CTRL", n == "ss_vdec"); end
        else if (n != "ss_npu") w(b, "CTRL", 0);
        w(b, "SRC_ADDR", bad); w(b, "DST_ADDR", ok);
        err_job(b, {n, " read ", tag});
        w(b, "SRC_ADDR", ok); w(b, "DST_ADDR", bad);
        err_job(b, {n, " write ", tag});
      end
    end
    b = env.regmodel.ss_isp;
    w(b, "DST_ADDR", bad); w(b, "LEN", 4); w(b, "LINE", 4); w(b, "CTRL", 0);
    err_job(b, {"ISP write ", tag});
    b = env.regmodel.ss_disp;
    w(b, "SRC_ADDR", bad); w(b, "LEN", 4); w(b, "LINE", 4);
    err_job(b, {"Display read ", tag});
    dma_err(bad, dram(M_DMA, 32'h30_0000), {"DMA read ", tag});
    dma_err(dram(M_DMA, 32'h30_0000), bad, {"DMA write ", tag});
  endtask

  // IOMMU-backed IPs through a fault: a one-page window that misses the buffers
  task iommu_faults();
    int ips[5] = '{0, 1, 3, 4, 5};                      // IOMMUs of NPU, ISP, VDEC, VENC, Display
    bit [31:0] far = iova(8);
    foreach (ips[k]) iommu_enable(ips[k], 1);
    begin
      phone_ip_block b = env.regmodel.ss_npu;
      w(b, "LEN", 4); w(b, "SRC_ADDR", far); w(b, "DST_ADDR", far);
      err_job(b, "NPU through an IOMMU fault");
      b = env.regmodel.ss_isp;
      w(b, "DST_ADDR", far); w(b, "LEN", 4); w(b, "CTRL", 0);
      err_job(b, "ISP through an IOMMU fault");
      b = env.regmodel.ss_vdec;
      w(b, "SRC_ADDR", far); w(b, "DST_ADDR", far); w(b, "LEN", 4); w(b, "CTRL", 1);
      err_job(b, "VDEC through an IOMMU fault");
      b = env.regmodel.ss_venc;
      w(b, "SRC_ADDR", far); w(b, "DST_ADDR", far); w(b, "LEN", 4); w(b, "CTRL", 0);
      err_job(b, "VENC through an IOMMU fault");
      b = env.regmodel.ss_disp;
      w(b, "SRC_ADDR", far); w(b, "LEN", 4);
      err_job(b, "Display through an IOMMU fault");
    end
    // the camera control processor (testbench master behind IOMMU 2)
    iommu_enable(2, 1);
    raw(M_ICP, 0, far);
    #1us;
    for (int i = 0; i < 6; i++) begin
      check_iommu_regs(i);
      clear_iommu_fault(i);
      iommu_off(i);
    end
  endtask

  // ---------------------------------------------------------------- 5
  task peripheral_irqs();
    uvm_reg_data_t d;
    phone_ip_block bi = env.regmodel.ss_intc, bt = env.regmodel.ss_tmr;
    w(bi, "ENABLE", 32'hFFFF_FFFF);
    w(bi, "IRQ_ENABLE", 3);
    foreach (periph[k]) reg_write(periph[k].r("IRQ_ENABLE"), irq_mask[k]);
    reg_write(env.regmodel.spi.r("TX"), 8'hA5);
    // GPIO: drive the pins, the input stage sees them
    reg_write(env.regmodel.gpio.r("OE"), 8'hFF);
    foreach (sh_pat[k]) begin reg_write(env.regmodel.gpio.r("OUT"), sh_pat[k]); #200ns; end
    reg_write(env.regmodel.gpio.r("OE"), 8'h00);
    // UART (looped back): four bytes, each pops out of RXDATA
    foreach (sh_pat[k]) begin
      reg_write(env.regmodel.uart.r("TXDATA"), sh_pat[k]);
      #600ns;
      reg_read(env.regmodel.uart.r("RXDATA"), d);
    end
    // PWM: a few periods, then off
    reg_write(env.regmodel.pwm.r("PERIOD"), 16);
    reg_write(env.regmodel.pwm.r("DUTY"), 8);
    #1us;
    reg_write(env.regmodel.pwm.r("PERIOD"), 0);
    // SRAM: a protocol error (its sticky interrupt)
    raw(M_ICP, 0, SRAM_BASE + 32'h800);
    // TRNG: ring-oscillator source (random tb_ro), start-up test, two blocks
    // hashed into one FIPS seed (about 2,200 clocks)
    reg_write(env.regmodel.trng.r("CTRL"), 13'h9);
    // I2C and SPI: the +SS_PINS controllers send a byte every 20 us
    #45us;
    reg_read(env.regmodel.i2c.r("RX"), d);
    reg_read(env.regmodel.spi.r("RX"), d);
    reg_read(env.regmodel.trng.r("STATUS"), d);
    if (d[4:3] != 2'b11) `uvm_error("SS", $sformatf("TRNG STATUS = %0h: no FIPS entropy after start-up", d))
    repeat (9) reg_read(env.regmodel.trng.r("ENT"), d);     // the eight seed words, then empty
    reg_write(env.regmodel.trng.r("CTRL"), 13'h8);
    // watchdog: bark, then bite (wdt_reset), then a kick clears it
    w(bt, "IRQ_ENABLE", 7);
    w(bt, "WDT_LOAD", 4);
    w(bt, "CTRL", {13'b0, 1'b1, 1'b0, 1'b0, 16'd0});
    #400ns;
    begin
      bit [31:0] st;
      rd(bt, "WDT_STATE", st);
      expect_val("Timer_WDT WDT_STATE.WDT_RESET (bite)", st[0], 1);
      w(bt, "CMD", 1);
      w(bt, "CTRL", 0);
      rd(bt, "WDT_STATE", st);
      expect_val("Timer_WDT WDT_STATE.WDT_RESET after kick", st[0], 0);
    end
    clear_irq(bt);
    // every interrupt source cleared at its device: cpu_irq falls
    foreach (periph[k]) begin
      reg_write(periph[k].r("IRQ_STATUS"), irq_mask[k]);
      reg_write(periph[k].r("IRQ_ENABLE"), 0);
    end
    w(bi, "ENABLE", 0);     // first: the sticky SRAM source would re-raise the controller's CPU irq
    foreach (env.regmodel.ss[i]) clear_irq(env.regmodel.ss[i]);
    w(bi, "SW_SET", 0);
  endtask

  bit [7:0] sh_pat[4] = '{8'h55, 8'hAA, 8'hFF, 8'h00};
  phone_ip_block periph[$];
  bit [7:0] irq_mask[6] = '{8'h01, 8'h1F, 8'h07, 8'h01, 8'h01, 8'h07};   // IRQ bits of GPIO .. TRNG

  // ---------------------------------------------------------------- 7
  // ---------------------------------------------------------------- 6
  task apb_errors();
    bit [31:0] d;
    for (int s = 0; s < SS_NSLOTS; s++) begin
      bit [31:0] a = APB_SS_BASE + 32'h1000 * s;
      rd32(cfg.host_m, a + 32'hF80, d, AXI4_SLVERR);     // unmapped register
      wr32(cfg.host_m, a + 32'hF80, 32'h0, AXI4_SLVERR);
      rd32(cfg.host_m, a + 32'h001, d, AXI4_SLVERR);     // misaligned
      rd32(cfg.host_m, a + 32'h002, d, AXI4_SLVERR);
      rd32(cfg.host_m, a, d);                            // ID: PSLVERR falls
    end
  endtask

  // ---------------------------------------------------------------- main
  task main();
    int unsigned lens[6] = '{256, 1, 2, 4, 8, 17};
    if (!cfg.real_ips) `uvm_fatal("SS", "phone_ss_cov_test needs the real-IP build (suite phone_real)")
    if (!$test$plusargs("SS_PINS")) `uvm_fatal("SS", "phone_ss_cov_test needs +SS_PINS")
    periph = '{env.regmodel.gpio, env.regmodel.uart, env.regmodel.i2c, env.regmodel.spi, env.regmodel.pwm,
               env.regmodel.trng};
    `uvm_info("COV_PHASE", "job lengths", UVM_LOW)
    foreach (lens[k]) begin
      len = lens[k];
      all_jobs();
    end
    `uvm_info("COV_PHASE", "sensor hub, ISP stream", UVM_LOW)
    for (int n = 1; n <= 17; n *= 2) sensor_batch(dram(M_SCP, 32'h18_0000), n + (n == 16));
    sensor_batch(dram(M_SCP, 32'h18_0000), 8, {12'b0, 16'h0100, 1'b1, 3'd2});   // WAKE above 0x100
    isp_stream();
    `uvm_info("COV_PHASE", "always-on IP addresses", UVM_LOW)
    aon_addresses();
    `uvm_info("COV_PHASE", "AXI errors", UVM_LOW)
    for (int i = 0; i < 6; i++) iommu_off(i);
    ip_errors(BAD, "(DECERR)");
    iommu_faults();
    `uvm_info("COV_PHASE", "interrupts", UVM_LOW)
    peripheral_irqs();
    `uvm_info("COV_PHASE", "APB errors", UVM_LOW)
    apb_errors();
    `uvm_info("SS", $sformatf("%0d jobs on 12 subsystem IPs, %0d reference-model mismatches", n_jobs, n_fail),
              UVM_NONE)
  endtask
endclass
