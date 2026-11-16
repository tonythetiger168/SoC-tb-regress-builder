// 8K TV SoC CPU subsystem bench: the xuanji-core RV64IMAC core (orca_v63_cpu_core) as the
// CPU master on the xuanji NoC, through tv8k_core2axi. ext/xuanji-core is private:
// scripts/fetch_private_ip.sh fetches it at build time; it is never committed.
+define+TV8K_CPU
ext/xuanji-core/rtl/cpu/orca_v63_cpu_core.sv
ext/xuanji-core/rtl/cpu/frontend/ifu_bpu.sv
ext/xuanji-core/rtl/cpu/frontend/ifu_btb.sv
ext/xuanji-core/rtl/cpu/frontend/ifu_fetch.sv
ext/xuanji-core/rtl/cpu/frontend/ifu_icache.sv
ext/xuanji-core/rtl/cpu/frontend/ifu_pred.sv
ext/xuanji-core/rtl/cpu/frontend/ifu_tlb.sv
ext/xuanji-core/rtl/cpu/decode/idu_decoder.sv
ext/xuanji-core/rtl/cpu/decode/idu_rvc_expand.sv
ext/xuanji-core/rtl/cpu/decode/idu_uop_queue.sv
ext/xuanji-core/rtl/cpu/rename/rnu_freelist.sv
ext/xuanji-core/rtl/cpu/rename/rnu_rat.sv
ext/xuanji-core/rtl/cpu/rename/rnu_remap.sv
ext/xuanji-core/rtl/cpu/scheduler/isu_fp.sv
ext/xuanji-core/rtl/cpu/scheduler/isu_int.sv
ext/xuanji-core/rtl/cpu/scheduler/isu_mem.sv
ext/xuanji-core/rtl/cpu/scheduler/isu_wake.sv
ext/xuanji-core/rtl/cpu/execution/exu_alu.sv
ext/xuanji-core/rtl/cpu/execution/exu_bru.sv
ext/xuanji-core/rtl/cpu/execution/exu_crypto.sv
ext/xuanji-core/rtl/cpu/execution/exu_fpu.sv
ext/xuanji-core/rtl/cpu/execution/exu_mul.sv
ext/xuanji-core/rtl/cpu/execution/exu_vec.sv
ext/xuanji-core/rtl/cpu/execution/prf.sv
ext/xuanji-core/rtl/cpu/memory/lsu_dcache.sv
ext/xuanji-core/rtl/cpu/memory/lsu_dtlb.sv
ext/xuanji-core/rtl/cpu/memory/lsu_ld.sv
ext/xuanji-core/rtl/cpu/memory/lsu_mshr.sv
ext/xuanji-core/rtl/cpu/memory/lsu_st.sv
ext/xuanji-core/rtl/cpu/memory/lsu_unit.sv
ext/xuanji-core/rtl/cpu/cache/dcache.sv
ext/xuanji-core/rtl/cpu/cache/icache.sv
ext/xuanji-core/rtl/cpu/cache/l2cache.sv
ext/xuanji-core/rtl/cpu/cache/l3cache.sv
ext/xuanji-core/rtl/cpu/commit/cmt_archreg.sv
ext/xuanji-core/rtl/cpu/commit/cmt_rob.sv
ext/xuanji-core/rtl/cpu/commit/cmt_trap.sv
ext/xuanji-core/rtl/cpu/commit/csr_unit.sv
rtl/tv8k/tv8k_core2axi.sv
-f sim/tv8k_noc.f
