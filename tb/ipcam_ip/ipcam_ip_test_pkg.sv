// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ipcam_ip_test_pkg -- tests for the IPCAM real-IP unit bench (ipcam_ip_tb_top)
// ----------------------------------------------------------------------------
//   ipcam_ip_jpeg_test  NV12 frame (+in=<yuv> +w +h) -> JPEG at +out=<file>
//   ipcam_ip_venc_test  NV12 frame -> HEVC intra bitstream at +out=<file>
//                       (+qp, +level; reconstruction written but not dumped)
//   ipcam_ip_npu_test   NPU DMA_LD / DMA_ST round trips through the line->AXI
//                       bridge, data checked in memory, completions via APB
//   ipcam_ip_all_test   all three at once (JPEG and VENC on the same frame)
// The bitstreams are compared to the c1p Python reference models and decoded
// with ffmpeg by scripts/ipcam_ip_check.py. Every AXI burst prints a
// 'LAT <master> <slave> <R|W> <cycles>' line (request handshake to last
// R beat / B) for the regression's latency report.
// Plusargs: +IP_LAT=<n> memory read/B latency upper bound in cycles (default 30)
//           +IP_BP=<n>  READY back-pressure upper bound (default 2)
// ============================================================================
`ifndef IPCAM_IP_SIG_IF
`define IPCAM_IP_SIG_IF
interface ipcam_ip_sig_if (input logic clk);
  logic [2:0]  irq;
  logic [2:0]  busy;
  logic [15:0] npu_bus_err;
endinterface
`endif

package ipcam_ip_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4_pkg::*;
  import apb_pkg::*;
  import mem_vip_pkg::*;

  localparam bit [31:0] SLOT_VENC = 32'h0000_0000;
  localparam bit [31:0] SLOT_JPEG = 32'h0000_1000;
  localparam bit [31:0] SLOT_NPU  = 32'h0000_2000;
  localparam real       CLK_NS    = 2.0;
  localparam string     PORT_NAME [3] = '{"venc", "jpeg", "npu"};

  // ---------------------------------------------------------------- latency
  class ipcam_ip_lat extends uvm_subscriber #(axi4_item);
    `uvm_component_utils(ipcam_ip_lat)
    string       master;
    int unsigned n [2];
    longint      sum [2], mn [2], mx [2];
    function new(string name, uvm_component parent);
      super.new(name, parent);
      foreach (n[i]) begin n[i] = 0; sum[i] = 0; mn[i] = 64'h7FFF_FFFF; mx[i] = 0; end
    endfunction
    function void write(axi4_item t);
      longint c = longint'((t.t_end - t.t_start) / (CLK_NS * 1ns));
      int d = t.write;
      $display("LAT %s ddr %s %0d", master, t.write ? "W" : "R", c);
      n[d]++; sum[d] += c;
      if (c < mn[d]) mn[d] = c;
      if (c > mx[d]) mx[d] = c;
    endfunction
    function void report_phase(uvm_phase phase);
      foreach (n[d]) if (n[d])
        `uvm_info("LAT", $sformatf("%s -> ddr %s: %0d bursts, min %0d avg %0.1f max %0d cycles",
                  master, d ? "W" : "R", n[d], mn[d], real'(sum[d]) / n[d], mx[d]), UVM_LOW)
    endfunction
  endclass

  // ---------------------------------------------------------------- env
  class ipcam_ip_env extends uvm_env;
    `uvm_component_utils(ipcam_ip_env)
    apb_agent    apb;
    axi4_agent   mem_ag [3];
    ipcam_ip_lat lat [3];
    mem_model    mem;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      apb_cfg acfg;
      int unsigned rl, bp;
      super.build_phase(phase);
      if (!$value$plusargs("IP_LAT=%d", rl)) rl = 30;
      if (!$value$plusargs("IP_BP=%d", bp)) bp = 2;
      mem = mem_model::type_id::create("ddr_mem");
      acfg = apb_cfg::type_id::create("acfg");
      acfg.role = APB_MASTER;
      acfg.has_coverage = 0;
      uvm_config_db#(apb_cfg)::set(this, "apb", "cfg", acfg);
      apb = apb_agent::type_id::create("apb", this);
      foreach (mem_ag[i]) begin
        axi4_cfg c = axi4_cfg::type_id::create($sformatf("mcfg%0d", i));
        c.role = AXI4_SLAVE;
        c.port = i;
        c.mem = mem;
        c.has_coverage = 0;
        c.max_aready_delay = bp;
        c.max_wready_delay = bp;
        c.max_b_latency    = rl;
        c.max_r_latency    = rl;
        c.max_rvalid_gap   = bp;
        uvm_config_db#(axi4_cfg)::set(this, $sformatf("mem%0d", i), "cfg", c);
        mem_ag[i] = axi4_agent::type_id::create($sformatf("mem%0d", i), this);
        lat[i] = ipcam_ip_lat::type_id::create($sformatf("lat%0d", i), this);
        lat[i].master = PORT_NAME[i];
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      foreach (mem_ag[i]) mem_ag[i].ap.connect(lat[i].analysis_export);
    endfunction
  endclass

  // ---------------------------------------------------------------- base test
  class ipcam_ip_base_test extends uvm_test;
    `uvm_component_utils(ipcam_ip_base_test)
    ipcam_ip_env env;
    virtual ipcam_ip_sig_if sig;
    int unsigned n_checks, n_fail;
    // frame buffers (byte addresses in the DDR window)
    bit [31:0] y_base   = 32'h8000_0000;
    bit [31:0] c_base;
    bit [31:0] jpg_out  = 32'h8100_0000;
    bit [31:0] hve_out  = 32'h8200_0000;
    bit [31:0] rec_y    = 32'h8300_0000;
    bit [31:0] rec_c    = 32'h8340_0000;
    int w, h, ys, cs;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = ipcam_ip_env::type_id::create("env", this);
      if (!uvm_config_db#(virtual ipcam_ip_sig_if)::get(this, "", "sig", sig))
        `uvm_fatal("NOSIG", "ipcam_ip_sig_if not set")
    endfunction

    task wr(bit [31:0] a, bit [31:0] d);
      bit e;
      apb_api::write(env.apb.sqr, a, d, e);
      if (e) fail($sformatf("APB write %08h = %08h: PSLVERR", a, d));
    endtask
    task rd(bit [31:0] a, output bit [31:0] d);
      bit e;
      apb_api::read(env.apb.sqr, a, d, e);
      if (e) fail($sformatf("APB read %08h: PSLVERR", a));
    endtask
    function void check(string what, longint got, longint exp);
      n_checks++;
      if (got != exp) fail($sformatf("%s: got %0h expected %0h", what, got, exp));
    endfunction
    function void fail(string msg);
      n_fail++;
      `uvm_error("IPCAM_IP", msg)
    endfunction

    // File named by +<plusarg>=<path>; with +vec=<name> the regression vector
    // regress/vectors/ipcam/<name><suffix> is the default (keeps paths out of
    // the plusargs, which name the run).
    function string vec_file(string plusarg, string suffix);
      string f, v;
      if ($value$plusargs({plusarg, "=%s"}, f)) return f;
      if ($value$plusargs("vec=%s", v)) return {"regress/vectors/ipcam/", v, suffix};
      return "";
    endfunction

    // NV12 frame from +in (w x h, planes packed) into DDR with strides ys / cs
    function void load_frame();
      string fin;
      int fd;
      fin = vec_file("in", ".yuv");
      if (fin == "") `uvm_fatal("IPCAM_IP", "+in=<nv12 file> or +vec=<name> missing")
      if (!$value$plusargs("w=%d", w)) w = 64;
      if (!$value$plusargs("h=%d", h)) h = 48;
      ys = (w + 7) / 8 * 8;
      cs = ys;
      c_base = (y_base + ys * h + 32'h1000) & ~32'h7;
      fd = $fopen(fin, "rb");
      if (fd == 0) `uvm_fatal("IPCAM_IP", {"cannot open ", fin})
      for (int r = 0; r < h; r++)
        for (int x = 0; x < w; x++) env.mem.write_byte(y_base + r * ys + x, 8'($fgetc(fd)));
      for (int r = 0; r < h / 2; r++)
        for (int x = 0; x < w; x++) env.mem.write_byte(c_base + r * cs + x, 8'($fgetc(fd)));
      $fclose(fd);
      `uvm_info("IPCAM_IP", $sformatf("frame %0dx%0d loaded: Y %08h C %08h", w, h, y_base, c_base), UVM_LOW)
    endfunction

    function void dump(string plusarg, bit [31:0] base, int unsigned nbytes);
      string f;
      int fd;
      if (!$value$plusargs({plusarg, "=%s"}, f)) return;
      fd = $fopen(f, "wb");
      for (int unsigned i = 0; i < nbytes; i++) $fwrite(fd, "%c", env.mem.read_byte(base + i));
      $fclose(fd);
      `uvm_info("IPCAM_IP", $sformatf("%0d bytes written to %s", nbytes, f), UVM_LOW)
    endfunction

    // Byte-compare nbytes at base with the reference file named by +<plusarg>
    // or +vec (made by the c1p Python model), when given.
    function void compare_ref(string plusarg, bit [31:0] base, int unsigned nbytes);
      string f;
      int fd, c;
      int unsigned i;
      f = vec_file(plusarg, plusarg == "jpg_ref" ? ".ref.jpg" : ".ref.265");
      if (f == "") return;
      fd = $fopen(f, "rb");
      if (fd == 0) begin fail({"cannot open reference ", f}); return; end
      n_checks++;
      for (i = 0; i < nbytes; i++) begin
        c = $fgetc(fd);
        if (c < 0) begin fail($sformatf("%s: output longer than reference (%0d bytes)", f, i)); break; end
        if (8'(c) !== env.mem.read_byte(base + i)) begin
          fail($sformatf("%s: byte %0d is %02h, reference %02h", f, i, env.mem.read_byte(base + i), 8'(c)));
          break;
        end
      end
      if (i == nbytes && $fgetc(fd) >= 0) fail($sformatf("%s: output shorter than reference (%0d bytes)", f, nbytes));
      $fclose(fd);
      if (n_fail == 0) `uvm_info("IPCAM_IP", $sformatf("%0d bytes match %s", nbytes, f), UVM_LOW)
    endfunction

    task wait_irq(int idx, string what, int unsigned max_cycles);
      int unsigned c = 0;
      while (sig.irq[idx] !== 1'b1 && c < max_cycles) begin @(posedge sig.clk); c++; end
      if (sig.irq[idx] !== 1'b1) fail($sformatf("%s: no interrupt after %0d cycles", what, max_cycles));
      else `uvm_info("IPCAM_IP", $sformatf("%s: interrupt after %0d cycles", what, c), UVM_LOW)
    endtask

    // ---- JPEG encoder: c1p_jpe_regs map ----
    task run_jpeg();
      bit [31:0] v, nbytes;
      bit [31:0] B = SLOT_JPEG;
      rd(B + 'hF8, v); check("JPE_ID", v, 32'h4A50_4501);
      wr(B + 'h10, 0);                                 // FMT NV12
      wr(B + 'h14, {2'b0, 14'(h), 2'b0, 14'(w)});
      wr(B + 'h18, y_base);
      wr(B + 'h1C, c_base);
      wr(B + 'h20, {16'(cs), 16'(ys)});
      wr(B + 'h24, jpg_out);
      wr(B + 'h28, 32'h0010_0000);                     // 1 MB cap
      wr(B + 'h2C, 0);                                 // no restart markers
      wr(B + 'h0C, 32'h3);
      wr(B + 'h00, 32'h1);                             // start
      wait_irq(1, "JPEG", 2_000_000);
      rd(B + 'h04, v);  check("JPE_STATUS (idle, no error)", v & 32'hF1, 0);
      rd(B + 'h08, v);  check("JPE_IRQ_STATUS done", v & 32'h3, 32'h1);
      wr(B + 'h08, 32'h3);
      rd(B + 'h30, nbytes);
      rd(B + 'h34, v);
      `uvm_info("IPCAM_IP", $sformatf("JPEG: %0d bytes, %0d cycles", nbytes, v), UVM_LOW)
      n_checks++;
      if (nbytes < 100) fail($sformatf("JPEG output only %0d bytes", nbytes));
      check("JPEG SOI", {env.mem.read_byte(jpg_out), env.mem.read_byte(jpg_out + 1)}, 16'hFFD8);
      check("JPEG EOI", {env.mem.read_byte(jpg_out + nbytes - 2), env.mem.read_byte(jpg_out + nbytes - 1)}, 16'hFFD9);
      dump("jpg_out", jpg_out, nbytes);
      compare_ref("jpg_ref", jpg_out, nbytes);
    endtask

    // ---- HEVC encoder: c1p_hve_regs map ----
    task run_venc();
      bit [31:0] v, nbytes;
      bit [31:0] B = SLOT_VENC;
      int qp, level, cw16, ch16;
      if (!$value$plusargs("qp=%d", qp)) qp = 30;
      if (!$value$plusargs("level=%d", level)) level = 93;
      cw16 = (w + 15) / 16 * 16;
      ch16 = (h + 15) / 16 * 16;
      wr(B + 'h10, {2'b0, 14'(h), 2'b0, 14'(w)});
      wr(B + 'h14, y_base);
      wr(B + 'h18, c_base);
      wr(B + 'h1C, {16'(cs), 16'(ys)});
      wr(B + 'h20, rec_y);
      wr(B + 'h24, rec_c);
      wr(B + 'h28, {16'(cw16), 16'(cw16)});
      wr(B + 'h2C, hve_out);
      wr(B + 'h30, 32'h0010_0000);
      wr(B + 'h34, {8'(level), 2'b0, 6'd19, 5'd0, 1'b0, 1'b1, 1'b1, 2'b0, 6'(qp)});  // IDR_W_RADL, ps, rec
      wr(B + 'h38, 0);                                 // one slice, POC 0
      wr(B + 'h3C, 32'h4444_4447);                     // reset mode masks
      wr(B + 'h40, 32'h4);
      wr(B + 'h0C, 32'h7);
      wr(B + 'h00, 32'h1);
      wait_irq(0, "VENC", 4_000_000);
      rd(B + 'h04, v);  check("HVE_STATUS (idle, no error)", v & 32'hF1, 0);
      rd(B + 'h08, v);  check("HVE_IRQ_STATUS done", v & 32'h3, 32'h1);
      wr(B + 'h08, 32'h7);
      rd(B + 'h48, nbytes);
      rd(B + 'h50, v);
      `uvm_info("IPCAM_IP", $sformatf("VENC: %0d bytes, %0d cycles", nbytes, v), UVM_LOW)
      n_checks++;
      if (nbytes < 32) fail($sformatf("HEVC output only %0d bytes", nbytes));
      check("HEVC start code", {env.mem.read_byte(hve_out), env.mem.read_byte(hve_out + 1),
                                env.mem.read_byte(hve_out + 2), env.mem.read_byte(hve_out + 3)}, 32'h0000_0001);
      dump("hevc_out", hve_out, nbytes);
      compare_ref("hevc_ref", hve_out, nbytes);
    endtask

    // ---- NPU subsystem: npu_ss_regs map, DMA through the line bridge ----
    task run_npu();
      bit [31:0] v;
      bit [31:0] B = SLOT_NPU;
      bit [31:0] src = 32'h8800_0000, dst = 32'h8900_0000;   // byte addresses, 64 B aligned
      int nl, rounds;
      if (!$value$plusargs("npu_lines=%d", nl)) nl = 16;
      if (!$value$plusargs("npu_rounds=%d", rounds)) rounds = 3;
      rd(B + 'h000, v); check("NPU ID", v, 32'h584E_0200);
      wr(B + 'h014, 32'h8000_0007);
      for (int r = 0; r < rounds; r++) begin
        bit [31:0] s = src + r * nl * 64, d = dst + r * nl * 64;
        bit [31:0] got [$];
        for (int i = 0; i < nl * 64; i++) env.mem.write_byte(s + i, 8'($urandom));
        // DMA_LD nl lines ext -> L2 0, then DMA_ST (wait) L2 0 -> ext
        wr(B + 'h060, {16'(nl), 8'(2 * r + 1), 2'b00, 1'b0, 2'b00, 1'b0, 2'd1});
        wr(B + 'h064, s >> 6);
        wr(B + 'h068, 0);
        wr(B + 'h06C, 0);
        wr(B + 'h074, 0);
        wr(B + 'h060, {16'(nl), 8'(2 * r + 2), 2'b00, 1'b0, 2'b00, 1'b1, 2'd2});
        wr(B + 'h064, d >> 6);
        wr(B + 'h074, 0);
        // collect both completions
        while (got.size() < 2) begin
          wait_irq(2, $sformatf("NPU round %0d", r), 400_000);
          rd(B + 'h080, v);
          if (v[31]) got.push_back(v[7:0]);
          else if (sig.irq[2] !== 1'b1) break;
        end
        check($sformatf("NPU round %0d completions", r), got.size(), 2);
        if (got.size() == 2) begin
          check("NPU completion id LD", got[0], 2 * r + 1);
          check("NPU completion id ST", got[1], 2 * r + 2);
        end
        for (int i = 0; i < nl * 64; i += 4) begin
          bit [31:0] a = env.mem.peek32(s + i), b = env.mem.peek32(d + i);
          n_checks++;
          if (a !== b) begin fail($sformatf("NPU round %0d: dst %08h = %08h, src %08h = %08h", r, d + i, b, s + i, a)); break; end
        end
      end
      rd(B + 'h010, v); check("NPU IRQ_STATUS errors", v & 32'h8000_0006, 0);
      check("NPU line bridge bus errors", sig.npu_bus_err, 0);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      if (n_fail == 0 && rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0)
        $display("SB_PASS checks=%0d", n_checks);
      else
        $display("SB_FAIL checks=%0d failures=%0d", n_checks, n_fail);
    endfunction
  endclass

  class ipcam_ip_jpeg_test extends ipcam_ip_base_test;
    `uvm_component_utils(ipcam_ip_jpeg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      load_frame();
      @(posedge sig.clk iff sig.busy === 3'b000);
      repeat (20) @(posedge sig.clk);
      run_jpeg();
      phase.drop_objection(this);
    endtask
  endclass

  class ipcam_ip_venc_test extends ipcam_ip_base_test;
    `uvm_component_utils(ipcam_ip_venc_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      load_frame();
      repeat (20) @(posedge sig.clk);
      run_venc();
      phase.drop_objection(this);
    endtask
  endclass

  class ipcam_ip_npu_test extends ipcam_ip_base_test;
    `uvm_component_utils(ipcam_ip_npu_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      repeat (20) @(posedge sig.clk);
      run_npu();
      phase.drop_objection(this);
    endtask
  endclass

  // The three engines share the APB sequencer; each program step is atomic
  // per APB transfer, so interleaving them is legal.
  class ipcam_ip_all_test extends ipcam_ip_base_test;
    `uvm_component_utils(ipcam_ip_all_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      load_frame();
      repeat (20) @(posedge sig.clk);
      fork
        run_jpeg();
        run_venc();
        run_npu();
      join
      phase.drop_objection(this);
    endtask
  endclass
endpackage
