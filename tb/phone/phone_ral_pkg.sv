// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// phone_ral_pkg -- UVM register model of the phone SoC's APB peripherals
// ----------------------------------------------------------------------------
//  phone_reg_block (map "apb", base 0x1000_0000, 4 KB per slot)
//    gpio  @0x0000  uart @0x1000  i2c @0x3000  spi @0x4000  pwm @0x5000
//    trng  @0x6000  iommu[0..5] @0x7000 + i * 0x1000
//
//  * open-ip peripherals share the generated APB4 wrapper header
//    (ID, IRQ_STATUS W1C, IRQ_ENABLE, FLAGS, SCRATCH at 0x000-0x010) and add
//    their core registers from 0x014 (register maps: open-ip docs/ip/<P>.md).
//  * Registers the hardware changes (core registers, pops, status, counters)
//    are volatile: the mirror is not compared for them.
//  * Frontdoor: reg2axi_adapter turns register operations into single-beat
//    AXI4 bursts on a master port (the CPU), through NoC + AXI-to-APB bridge.
//  * Prediction: explicit, from the internal APB bus (apb2reg_adapter +
//    uvm_reg_predictor on the passive APB monitor), so accesses by any
//    master update the mirror.
// ============================================================================
`ifndef PHONE_RAL_PKG_SV
`define PHONE_RAL_PKG_SV
package phone_ral_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4_pkg::*;
  import apb_pkg::*;

  // ==========================================================================
  // generic one-field register
  // ==========================================================================
  class phone_reg extends uvm_reg;
    `uvm_object_utils(phone_reg)
    uvm_reg_field f;
    function new(string name = "phone_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction
    function void setup(int unsigned lsb, int unsigned width, string access,
                        uvm_reg_data_t reset, bit volatile_, bit has_reset = 1);
      f = uvm_reg_field::type_id::create("f");
      f.configure(this, width, lsb, access, volatile_, reset, has_reset, 0, 0);
    endfunction
  endclass

  // ==========================================================================
  // base block: register table helpers
  // ==========================================================================
  class phone_ip_block extends uvm_reg_block;
    `uvm_object_utils(phone_ip_block)
    phone_reg regs[string];

    function new(string name = "phone_ip_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction

    function phone_reg add(string name, uvm_reg_addr_t off, int unsigned width, string access,
                           uvm_reg_data_t reset = 0, bit volatile_ = 0, int unsigned lsb = 0,
                           bit has_reset = 1);
      phone_reg r = phone_reg::type_id::create(name);
      r.configure(this, null, "");
      r.setup(lsb, width, access, reset, volatile_, has_reset);
      default_map.add_reg(r, off, (access == "WO") ? "WO" : (access == "RO") ? "RO" : "RW");
      regs[name] = r;
      // only plain read/write registers are bit-bashed
      if (access != "RW" || volatile_)
        uvm_resource_db#(bit)::set({"REG::", r.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
      if (!has_reset || volatile_)
        uvm_resource_db#(bit)::set({"REG::", r.get_full_name()}, "NO_REG_HW_RESET_TEST", 1, this);
      return r;
    endfunction

    // open-ip APB4 wrapper header
    function void add_header(bit [31:0] id, int unsigned n_irq, int unsigned n_flags);
      add("ID",         'h000, 32, "RO", id);
      add("IRQ_STATUS", 'h004, n_irq, "W1C", 0, 1);
      add("IRQ_ENABLE", 'h008, n_irq, "RW", 0);
      add("FLAGS",      'h00C, (n_flags == 0) ? 1 : n_flags, "RO", 0, n_flags != 0);
      add("SCRATCH",    'h010, 32, "RW", 0);
    endfunction

    function phone_reg r(string name);
      if (!regs.exists(name)) `uvm_fatal("RAL", {get_full_name(), ": no register ", name})
      return regs[name];
    endfunction
  endclass

  // ---------------------------------------------------------------- open-ip
  class gpio_block extends phone_ip_block;
    `uvm_object_utils(gpio_block)
    function new(string name = "gpio_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add_header(32'h4750_0200, 1, 0);
      add("OE",  'h014, 8, "RW", 0);
      add("OUT", 'h018, 8, "RW", 0, 1, 0, 0);      // core register
      add("IN",  'h01C, 8, "RO", 0, 1, 0, 0);
    endfunction
  endclass

  class uart_block extends phone_ip_block;
    `uvm_object_utils(uart_block)
    function new(string name = "uart_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add_header(32'h5541_0200, 5, 2);
      add("TXDATA", 'h014, 8, "RW", 0, 1);           // starts a transmission
      add("RXDATA", 'h018, 8, "RO", 0, 1);           // pop
    endfunction
  endclass

  class i2c_block extends phone_ip_block;
    `uvm_object_utils(i2c_block)
    function new(string name = "i2c_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add_header(32'h4943_0200, 3, 1);
      add("TX",     'h014, 8, "RW", 0);
      add("RX",     'h018, 8, "RO", 0, 1);
      add("STATUS", 'h01C, 1, "RO", 0, 1, 0, 0);
    endfunction
  endclass

  class spi_block extends phone_ip_block;
    `uvm_object_utils(spi_block)
    function new(string name = "spi_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add_header(32'h5350_0200, 1, 0);
      add("TX", 'h014, 8, "RW", 0, 1, 0, 0);         // core register
      add("RX", 'h018, 8, "RO", 0, 1, 0, 0);
    endfunction
  endclass

  class pwm_block extends phone_ip_block;
    `uvm_object_utils(pwm_block)
    function new(string name = "pwm_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add_header(32'h5057_0200, 1, 0);
      add("PERIOD", 'h014, 32, "WO", 0, 0, 0, 0);    // core registers, read 0
      add("DUTY",   'h018, 32, "WO", 0, 0, 0, 0);
    endfunction
  endclass

  class trng_block extends phone_ip_block;
    `uvm_object_utils(trng_block)
    function new(string name = "trng_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add_header(32'h5452_0100, 3, 1);
      add("CTRL",      'h014, 13, "RW", 'h8);
      add("HEALTH",    'h018, 19, "RW", 'h31929);
      add("LFSR_SEED", 'h01C, 32, "RW", 'h1);
      add("ENT",       'h020, 32, "RO", 0, 1);
      add("STATUS",    'h024, 7,  "RO", 0, 1, 0, 0);
      add("FAILS",     'h028, 16, "RO", 0, 1, 0, 0);
      add("WATERMARK", 'h02C, 19, "RO", 0, 1, 0, 0);
    endfunction
  endclass

  // ---------------------------------------------------------------- IOMMU
  class iommu_block extends phone_ip_block;
    `uvm_object_utils(iommu_block)
    function new(string name = "iommu_block"); super.new(name); endfunction
    function void build();
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
      add("ID",           'h000, 32, "RO", 32'h494F_0100);
      add("CTRL",         'h004, 2,  "RW", 0);
      add("PT_BASE",      'h008, 20, "RW", 0, 0, 12);
      add("VA_BASE",      'h00C, 20, "RW", 0, 0, 12);
      add("VA_SIZE",      'h010, 20, "RW", 0, 0, 12);
      add("INV",          'h014, 32, "WO", 0, 0, 0, 0);
      add("FAULT_STATUS", 'h018, 3,  "W1C", 0, 1);
      add("FAULT_ADDR",   'h01C, 32, "RO", 0, 1);
      add("FAULT_CNT",    'h020, 32, "RO", 0, 1);
      add("TLB_HITS",     'h024, 32, "RO", 0, 1);
      add("TLB_MISSES",   'h028, 32, "RO", 0, 1);
    endfunction
  endclass

  // ==========================================================================
  class phone_reg_block extends uvm_reg_block;
    `uvm_object_utils(phone_reg_block)
    gpio_block  gpio;
    uart_block  uart;
    i2c_block   i2c;
    spi_block   spi;
    pwm_block   pwm;
    trng_block  trng;
    iommu_block iommu[6];

    function new(string name = "phone_reg_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction

    function void build(uvm_reg_addr_t base = 32'h1000_0000);
      default_map = create_map("apb", base, 4, UVM_LITTLE_ENDIAN);
      gpio = gpio_block::type_id::create("gpio"); gpio.configure(this); gpio.build();
      uart = uart_block::type_id::create("uart"); uart.configure(this); uart.build();
      i2c  = i2c_block::type_id::create("i2c");   i2c.configure(this);  i2c.build();
      spi  = spi_block::type_id::create("spi");   spi.configure(this);  spi.build();
      pwm  = pwm_block::type_id::create("pwm");   pwm.configure(this);  pwm.build();
      trng = trng_block::type_id::create("trng"); trng.configure(this); trng.build();
      default_map.add_submap(gpio.default_map, 'h0000);
      default_map.add_submap(uart.default_map, 'h1000);
      default_map.add_submap(i2c.default_map,  'h3000);
      default_map.add_submap(spi.default_map,  'h4000);
      default_map.add_submap(pwm.default_map,  'h5000);
      default_map.add_submap(trng.default_map, 'h6000);
      foreach (iommu[i]) begin
        iommu[i] = iommu_block::type_id::create($sformatf("iommu%0d", i));
        iommu[i].configure(this);
        iommu[i].build();
        default_map.add_submap(iommu[i].default_map, 'h7000 + 'h1000 * i);
      end
      lock_model();
      reset();
    endfunction

    function void ip_blocks(ref phone_ip_block q[$]);
      q = '{gpio, uart, i2c, spi, pwm, trng};
      foreach (iommu[i]) q.push_back(iommu[i]);
    endfunction
  endclass

  // ==========================================================================
  // adapters
  // ==========================================================================
  // frontdoor: one register access = one single-beat 32-bit AXI4 burst
  class reg2axi_adapter extends uvm_reg_adapter;
    `uvm_object_utils(reg2axi_adapter)
    bit [7:0] id = 0;
    function new(string name = "reg2axi_adapter");
      super.new(name);
      supports_byte_enable = 1;
      provides_responses   = 0;
    endfunction
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      axi4_item t = axi4_api::make(rw.kind == UVM_WRITE, 32'(rw.addr), 1, 2, AXI4_INCR, id);
      if (rw.kind == UVM_WRITE) begin
        t.data[0] = 32'(rw.data);
        t.strb[0] = (rw.byte_en[3:0] == 0) ? 4'hF : rw.byte_en[3:0];
      end
      return t;
    endfunction
    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
      axi4_item t;
      if (!$cast(t, bus_item)) `uvm_fatal("RAL", "reg2axi_adapter: not an axi4_item")
      rw.kind   = t.write ? UVM_WRITE : UVM_READ;
      rw.addr   = t.addr;
      rw.data   = t.data.size() ? t.data[0] : 0;
      rw.status = (t.resp.size() && t.resp[0] == AXI4_OKAY) ? UVM_IS_OK : UVM_NOT_OK;
    endfunction
  endclass

  // prediction from the APB bus
  class apb2reg_adapter extends uvm_reg_adapter;
    `uvm_object_utils(apb2reg_adapter)
    function new(string name = "apb2reg_adapter");
      super.new(name);
      supports_byte_enable = 1;
    endfunction
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      apb_item t = apb_item::type_id::create("t");
      t.write = (rw.kind == UVM_WRITE); t.addr = 32'(rw.addr); t.data = 32'(rw.data);
      return t;
    endfunction
    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
      apb_item t;
      if (!$cast(t, bus_item)) `uvm_fatal("RAL", "apb2reg_adapter: not an apb_item")
      rw.kind    = t.write ? UVM_WRITE : UVM_READ;
      rw.addr    = t.addr;
      rw.data    = t.data;
      rw.byte_en = t.write ? t.strb : 4'hF;
      rw.status  = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
    endfunction
  endclass
endpackage
`endif
