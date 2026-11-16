// 8K TV SoC NoC testbench, everything but the router (included by
// sim/tv8k_noc.f and sim/tv8k_noc_open.f; paths relative to the repo root)
+incdir+vip/mem
+incdir+vip/axi4
+incdir+tb/tv8k
rtl/tv8k/tv8k_noc_pkg.sv
rtl/tv8k/tv8k_router_open.sv
rtl/tv8k/tv8k_noc.sv
rtl/tv8k/tv8k_ni_mst.sv
rtl/tv8k/tv8k_ni_slv.sv
vip/axi4/axi4_if.sv
vip/axi4/axi4_sva.sv
vip/common/fcov_pkg.sv
vip/common/lat_pkg.sv
vip/mem/mem_vip_pkg.sv
vip/axi4/axi4_pkg.sv
tb/tv8k/tv8k_lat_pkg.sv
tb/tv8k/tv8k_noc_test_pkg.sv
tb/tv8k/tv8k_noc_tb_top.sv
