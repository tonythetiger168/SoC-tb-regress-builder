// 8K TV SoC NoC testbench with the xuanji-core orca_noc_router mesh.
// ext/xuanji-core is private: scripts/fetch_private_ip.sh fetches it at build
// time and it is never committed here. Without it use sim/tv8k_noc_open.f.
+incdir+ext/xuanji-core/rtl/common
ext/xuanji-core/rtl/common/clock_gate.sv
ext/xuanji-core/rtl/noc/orca_noc_router.sv
-f sim/tv8k_noc_common.f
