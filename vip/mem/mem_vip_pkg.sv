// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// mem_vip_pkg -- memory VIP: sparse byte-addressed memory model
// ----------------------------------------------------------------------------
// mem_model is a uvm_object shared by reference between components:
//   * the AXI4 / APB slave (responder) drivers use it as their storage,
//   * scoreboards and tests use the backdoor API (peek/poke/load/dump),
//   * unwritten bytes read back as a deterministic function of the address
//     (init_kind), so a reference model can predict them without sharing the
//     instance.
// Bus helpers (read_bus / write_bus) map a bus word onto the byte lanes of
// the aligned address, the way AXI and APB lay data out (little endian).
// ============================================================================
`ifndef MEM_VIP_PKG_SV
`define MEM_VIP_PKG_SV
package mem_vip_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef longint unsigned mem_addr_t;
  typedef enum int { MEM_INIT_ZERO = 0, MEM_INIT_ONES = 1, MEM_INIT_PATTERN = 2 } mem_init_e;

  class mem_model extends uvm_object;
    `uvm_object_utils(mem_model)

    mem_init_e        init_kind = MEM_INIT_PATTERN;
    protected byte unsigned m_mem[mem_addr_t];
    longint unsigned  n_byte_writes, n_byte_reads;

    function new(string name = "mem_model");
      super.new(name);
    endfunction

    // value of a byte that was never written
    static function byte unsigned init_byte(mem_init_e kind, mem_addr_t addr);
      logic [63:0] a;
      a = addr;
      case (kind)
        MEM_INIT_ZERO: return 8'h00;
        MEM_INIT_ONES: return 8'hFF;
        default:       return a[7:0] ^ a[15:8] ^ a[23:16] ^ a[31:24] ^ 8'h5A;
      endcase
    endfunction

    // ---------------- byte access ----------------
    function byte unsigned read_byte(mem_addr_t addr);
      n_byte_reads++;
      if (m_mem.exists(addr)) return m_mem[addr];
      return init_byte(init_kind, addr);
    endfunction

    function void write_byte(mem_addr_t addr, byte unsigned data);
      n_byte_writes++;
      m_mem[addr] = data;
    endfunction

    function bit is_written(mem_addr_t addr);
      return m_mem.exists(addr);
    endfunction

    // ---------------- bus-word access ----------------
    // nbytes: bus width in bytes (power of two, <= 8). Lane i of the returned
    // word is the byte at (addr aligned down to nbytes) + i.
    function bit [63:0] read_bus(mem_addr_t addr, int nbytes = 4);
      mem_addr_t base = addr & ~(mem_addr_t'(nbytes) - 1);
      bit [63:0] d = '0;
      for (int i = 0; i < nbytes; i++) d[8*i +: 8] = read_byte(base + i);
      return d;
    endfunction

    function void write_bus(mem_addr_t addr, bit [63:0] data, bit [7:0] strb, int nbytes = 4);
      mem_addr_t base = addr & ~(mem_addr_t'(nbytes) - 1);
      for (int i = 0; i < nbytes; i++)
        if (strb[i]) write_byte(base + i, data[8*i +: 8]);
    endfunction

    // ---------------- backdoor ----------------
    function bit [31:0] peek32(mem_addr_t addr);
      return 32'(read_bus(addr, 4));
    endfunction

    function void poke32(mem_addr_t addr, bit [31:0] data);
      write_bus(addr, 64'(data), 8'h0F, 4);
    endfunction

    function void fill(mem_addr_t base, int unsigned nbytes, byte unsigned value);
      for (int unsigned i = 0; i < nbytes; i++) m_mem[base + i] = value;
    endfunction

    function void clear();
      m_mem.delete();
      n_byte_writes = 0;
      n_byte_reads  = 0;
    endfunction

    function int unsigned num_written();
      return m_mem.num();
    endfunction

    // $readmemh-style file of 32-bit words, one per line, loaded from base.
    function int load_hex32(string file, mem_addr_t base);
      int fd, n = 0;
      bit [31:0] w;
      fd = $fopen(file, "r");
      if (fd == 0) begin
        `uvm_error("MEM", {"cannot open ", file})
        return 0;
      end
      while ($fscanf(fd, "%h", w) == 1) begin
        poke32(base + 4 * n, w);
        n++;
      end
      $fclose(fd);
      return n;
    endfunction

    // every written byte as "addr data" lines, ascending address
    function void dump(string file);
      int fd = $fopen(file, "w");
      mem_addr_t a;
      if (fd == 0) begin
        `uvm_error("MEM", {"cannot open ", file})
        return;
      end
      if (m_mem.first(a))
        do $fdisplay(fd, "%016h %02h", a, m_mem[a]); while (m_mem.next(a));
      $fclose(fd);
    endfunction

    virtual function string convert2string();
      return $sformatf("mem_model %s: %0d bytes written, init=%s", get_name(),
                       m_mem.num(), init_kind.name());
    endfunction
  endclass

endpackage
`endif
