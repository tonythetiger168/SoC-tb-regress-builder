# SPDX-License-Identifier: Apache-2.0
# Boot for the xuanji core on the tv8k NoC (reset PC 0x8000_0000 = DRAM base)
  .section .text.start
  .globl _start
_start:
  li    sp, 0x80020000          # stack below 128 KB, in the CPU's DRAM slice
  call  main
  fence.i                       # write the dirty L1D lines (results) back
  li    t0, 0x80010000          # signature block
  li    t1, 0x600D600D
  sd    t1, 32(t0)              # DONE word, after the results are out
  fence.i
1: j    1b                      # end: self loop
