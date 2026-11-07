// SPDX-License-Identifier: Apache-2.0
// axi4 sequences. Randomization uses $urandom (no constraint solver needed,
// so they run unchanged on simulators with limited randomize() support).

// one burst, fully specified by the caller; response comes back in `item`
class axi4_single_seq extends uvm_sequence #(axi4_item);
  `uvm_object_utils(axi4_single_seq)
  axi4_item item;
  function new(string name = "axi4_single_seq");
    super.new(name);
  endfunction
  task body();
    start_item(item);
    finish_item(item);
  endtask
endclass

// helpers to build and run bursts from a test or virtual sequence
class axi4_api;
  static function axi4_item make(bit write, bit [31:0] addr, int unsigned beats = 1,
                                 bit [2:0] size = 2, axi4_burst_e burst = AXI4_INCR,
                                 bit [7:0] id = 0);
    axi4_item t = axi4_item::type_id::create("t");
    t.write = write; t.addr = addr; t.len = beats - 1; t.size = size; t.burst = burst; t.id = id;
    t.alloc();
    for (int unsigned i = 0; i < beats; i++) begin
      t.data[i] = write ? $urandom() : 0;
      t.strb[i] = t.lanes(i);
    end
    return t;
  endfunction

  static task run(axi4_sequencer sqr, axi4_item t);
    axi4_single_seq s = axi4_single_seq::type_id::create("s");
    s.item = t;
    s.start(sqr);
  endtask

  static task write32(axi4_sequencer sqr, bit [31:0] addr, bit [31:0] data,
                      output axi4_resp_e resp, input bit [3:0] strb = 4'hF, input bit [7:0] id = 0);
    axi4_item t = make(1, addr, 1, 2, AXI4_INCR, id);
    t.data[0] = data;
    t.strb[0] = strb;
    run(sqr, t);
    resp = t.resp[0];
  endtask

  static task read32(axi4_sequencer sqr, bit [31:0] addr, output bit [31:0] data,
                     output axi4_resp_e resp, input bit [7:0] id = 0);
    axi4_item t = make(0, addr, 1, 2, AXI4_INCR, id);
    run(sqr, t);
    data = t.data[0];
    resp = t.resp[0];
  endtask
endclass

// random legal bursts inside [lo, hi] (inclusive byte range)
class axi4_random_seq extends uvm_sequence #(axi4_item);
  `uvm_object_utils(axi4_random_seq)

  int unsigned n_items   = 20;
  bit [31:0]   lo        = 32'h0, hi = 32'hFFF;
  int unsigned max_beats = 16;
  bit [2:0]    max_size  = 2;
  bit          allow_fixed = 1, allow_wrap = 1, allow_narrow = 1, allow_partial_strb = 1;
  int unsigned wr_pct    = 50;
  int unsigned id_width  = 4;
  int unsigned max_delay = 2;

  function new(string name = "axi4_random_seq");
    super.new(name);
  endfunction

  // a random legal burst inside [lo, hi] that does not cross 4 KB
  function axi4_item gen();
    axi4_item t;
    int unsigned beats, nb, kind;
    bit [2:0] size;
    axi4_burst_e burst;
    bit [31:0] a, span;
    for (int tries = 0; tries < 100; tries++) begin
      size = allow_narrow ? 3'($urandom_range(max_size, 0)) : max_size;
      nb = 1 << size;
      kind = $urandom_range(9, 0);
      burst = (allow_wrap && kind == 0) ? AXI4_WRAP : (allow_fixed && kind == 1) ? AXI4_FIXED : AXI4_INCR;
      if (burst == AXI4_WRAP) begin
        int unsigned wl[$] = '{2, 4, 8, 16};
        wl = wl.find(x) with (x <= max_beats);
        if (wl.size() == 0) continue;
        beats = wl[$urandom_range(wl.size() - 1, 0)];
      end else
        beats = (max_beats > 1 && $urandom_range(3, 0) == 0) ? $urandom_range(max_beats, 1) :
                $urandom_range(max_beats < 4 ? max_beats : 4, 1);
      span = (burst == AXI4_FIXED) ? nb : beats * nb;
      if (hi - lo + 1 < span) continue;
      a = lo + $urandom_range(hi - lo + 1 - span, 0);
      a = a & ~(32'(nb) - 1);                        // aligned start
      if (burst == AXI4_INCR && allow_narrow && $urandom_range(7, 0) == 0)
        a = a + $urandom_range(nb - 1, 0);           // occasional unaligned INCR start
      if (a < lo) continue;
      t = axi4_api::make($urandom_range(99, 0) < wr_pct, a, beats, size, burst,
                         8'($urandom_range((1 << id_width) - 1, 0)));
      if (burst == AXI4_INCR && (t.last_addr() > hi || t.last_addr()[31:12] != a[31:12])) continue;
      if (burst == AXI4_WRAP) begin
        bit [31:0] wsize = beats * nb;
        bit [31:0] wbase = a & ~(wsize - 1);
        if (wbase < lo || wbase + wsize - 1 > hi) continue;
      end
      if (t.write && allow_partial_strb)
        foreach (t.strb[i]) if ($urandom_range(3, 0) == 0) t.strb[i] = t.lanes(i) & 4'($urandom());
      t.aw_delay = $urandom_range(max_delay, 0);
      t.w_gap    = max_delay;
      t.r_gap    = max_delay;
      return t;
    end
    `uvm_fatal("AXI4_SEQ", $sformatf("cannot fit a burst in [%08h, %08h]", lo, hi))
    return null;
  endfunction

  task body();
    repeat (n_items) begin
      axi4_item t = gen();
      start_item(t);
      finish_item(t);
    end
  endtask
endclass
