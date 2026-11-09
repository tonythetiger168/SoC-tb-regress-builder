// SPDX-License-Identifier: Apache-2.0
// axi4_item -- one AXI4 burst (request + response), used by drivers, monitors
// and sequences. Per-beat arrays have len+1 entries; for a write, resp[0] is
// BRESP.
class axi4_item extends uvm_sequence_item;
  `uvm_object_utils(axi4_item)

  rand bit          write;
  rand bit [7:0]    id;
  rand bit [31:0]   addr;
  rand bit [7:0]    len;        // AxLEN: beats - 1
  rand bit [2:0]    size;       // AxSIZE: bytes per beat = 1 << size
  rand axi4_burst_e burst;
  bit [2:0]         prot;
  bit [3:0]         cache;
  bit [31:0]        data[];     // write data or read data, one per beat
  bit [3:0]         strb[];     // write strobes (reads: lanes the beat covers)
  axi4_resp_e       resp[];     // write: [0] = BRESP; read: RRESP per beat

  // filled in by monitors
  int               port = -1;  // agent tag (e.g. interconnect master index)
  time              t_start, t_end;

  // knobs read by the master driver
  int unsigned      aw_delay, w_gap, b_delay, r_gap;

  function new(string name = "axi4_item");
    super.new(name);
  endfunction

  function int unsigned beats();
    return int'(len) + 1;
  endfunction

  // allocate data/strb/resp arrays for the current len
  function void alloc();
    data = new[beats()];
    strb = new[beats()];
    resp = new[write ? 1 : beats()];
  endfunction

  // AXI4 A3.4.1 beat address
  static function bit [31:0] beat_addr_of(bit [31:0] addr, bit [7:0] len, bit [2:0] size,
                                          axi4_burst_e burst, int unsigned i);
    bit [31:0] nb = 32'd1 << size;
    bit [31:0] aligned = addr & ~(nb - 1);
    bit [31:0] wsize, wbase;
    case (burst)
      AXI4_FIXED: return addr;
      AXI4_WRAP: begin
        wsize = nb * (32'(len) + 1);
        wbase = addr & ~(wsize - 1);
        return wbase + ((aligned - wbase + i * nb) % wsize);
      end
      default: return (i == 0) ? addr : aligned + i * nb;
    endcase
  endfunction

  function bit [31:0] beat_addr(int unsigned i);
    return beat_addr_of(addr, len, size, burst, i);
  endfunction

  // byte lanes (of a 32-bit bus) a beat at address a with this size covers
  static function bit [3:0] lanes_of(bit [31:0] a, bit [2:0] size);
    int unsigned nb = 1 << size;
    int unsigned lo = a % 4;
    int unsigned hi = (a & ~(nb - 1)) % 4 + nb - 1;
    bit [3:0] m = '0;
    for (int unsigned b = lo; b <= hi && b < 4; b++) m[b] = 1'b1;
    return m;
  endfunction

  function bit [3:0] lanes(int unsigned i);
    return lanes_of(beat_addr(i), size);
  endfunction

  // last byte address of an INCR burst (4 KB crossing checks)
  function bit [31:0] last_addr();
    return beat_addr(len) | ((32'd1 << size) - 1);
  endfunction

  function axi4_resp_e worst_resp();
    axi4_resp_e w = AXI4_OKAY;
    foreach (resp[i]) if (resp[i] > w) w = resp[i];
    return w;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    axi4_item r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("AXI4_ITEM", "do_copy: type mismatch")
    write = r.write; id = r.id; addr = r.addr; len = r.len; size = r.size;
    burst = r.burst; prot = r.prot; cache = r.cache;
    data = r.data; strb = r.strb; resp = r.resp;
    port = r.port; t_start = r.t_start; t_end = r.t_end;
    aw_delay = r.aw_delay; w_gap = r.w_gap; b_delay = r.b_delay; r_gap = r.r_gap;
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("%s id=%0h addr=%08h len=%0d size=%0d %s", write ? "WR" : "RD", id, addr,
                  len, size, burst.name());
    if (resp.size()) s = {s, " resp=", worst_resp().name()};
    if (data.size()) s = {s, $sformatf(" data[0]=%08h", data[0])};
    if (port >= 0)   s = {s, $sformatf(" port=%0d", port)};
    return s;
  endfunction
endclass
