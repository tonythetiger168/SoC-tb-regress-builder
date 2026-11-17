// 8K TV SoC NPU subsystem bench: xuanji-core orca_npu_ss_apb (X1) as the NPU master
// and its registers at S_NPUR, on the xuanji NoC. ext/xuanji-core is private:
// scripts/fetch_private_ip.sh fetches it at build time; it is never committed.
+define+TV8K_NPU
+incdir+ext/xuanji-core/rtl/fp
ext/xuanji-core/rtl/npu/npu_mma.sv
ext/xuanji-core/rtl/npu/npu_gemm_cu.sv
ext/xuanji-core/rtl/fp/fp_add.sv
ext/xuanji-core/rtl/fp/fp_mul.sv
ext/xuanji-core/rtl/fp/fp_narrow.sv
ext/xuanji-core/rtl/fp/fp_widen.sv
ext/xuanji-core/rtl/fp/sfu.sv
ext/xuanji-core/rtl/fp/fp_max.sv
ext/xuanji-core/rtl/fp/fp_small_dec.sv
ext/xuanji-core/rtl/fp/fp_mx_scale.sv
ext/xuanji-core/rtl/fp/fp_from_int.sv
ext/xuanji-core/rtl/npu/npu_vec.sv
ext/xuanji-core/rtl/npu/npu_vec_eng.sv
ext/xuanji-core/rtl/npu/npu_l2_arb2.sv
ext/xuanji-core/rtl/npu/npu_l2_xbar.sv
ext/xuanji-core/rtl/npu/npu_core.sv
ext/xuanji-core/rtl/npu/npu_ss_dma.sv
ext/xuanji-core/rtl/npu/orca_npu_ss.sv
ext/xuanji-core/rtl/common/ret_shadow.sv
ext/xuanji-core/rtl/npu/npu_ss_regs.sv
ext/xuanji-core/rtl/npu/orca_npu_ss_apb.sv
rtl/tv8k/tv8k_axi2apb.sv
rtl/tv8k/tv8k_line2axi.sv
-f sim/tv8k_noc.f
