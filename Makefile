# SPDX-License-Identifier: Apache-2.0
# AMBA SoC UVM testbench -- build and run
#   make build                       compile the SoC testbench (Verilator by default)
#   make run TEST=soc_smoke_test SEED=1
#   make regress [LIST=regress/testlist.txt JOBS=4]
#   make cov [TB=soc LIST=...]       coverage regression, scored against waivers
#   make vip_build / make vip_run TEST=vip_axi4_loopback_test
#   make build TB=<soc> for a socgen-generated bench (socgen/out/<soc>/socgen.mk)
# SIM=verilator (default) | vcs | xrun | questa
SIM      ?= verilator
TEST     ?= soc_smoke_test
SEED     ?= 1
TB       ?= soc
UVM_HOME ?= $(CURDIR)/uvm-core/src
BUILD    := build/$(SIM)/$(TB)
TOP_soc  := soc_tb_top
TOP_vip  := vip_tb_top
-include $(wildcard socgen/out/*/socgen.mk)
TOP_ipcam_ip := ipcam_ip_tb_top
TOP_ipcam_soc_media    := ipcam_soc_tb_top
TOP_ipcam_hd_soc_media := ipcam_hd_soc_tb_top
TOP      := $(TOP_$(TB))
FLIST    := $(or $(FLIST_$(TB)),sim/$(TB).f)
JOBS     ?= $(shell nproc)
PLUSARGS ?=

.PHONY: build run regress cov vip_build vip_run uvm clean

uvm: $(UVM_HOME)/uvm_pkg.sv
$(UVM_HOME)/uvm_pkg.sv:
	git clone -q --depth 1 --branch 2020.3.1 https://github.com/accellera-official/uvm-core.git uvm-core

ifeq ($(SIM),verilator)
EXE := $(BUILD)/obj/V$(TOP)
build: uvm
	mkdir -p $(BUILD)
	verilator --binary --timing -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style \
	  --timescale 1ns/1ps --top-module $(TOP) -Mdir $(BUILD)/obj +define+UVM_NO_DPI \
	  +incdir+$(UVM_HOME) $(UVM_HOME)/uvm_pkg.sv -f $(FLIST) > $(BUILD)/build.log 2>&1 \
	  || (grep -E '^%Error' $(BUILD)/build.log | head -20; exit 1)
RUN_CMD = $(EXE) +UVM_TESTNAME=$(TEST) +verilator+seed+$(SEED) $(PLUSARGS)
else ifeq ($(SIM),vcs)
build: uvm
	mkdir -p $(BUILD) && cd $(BUILD) && vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 \
	  -top $(TOP) -f $(CURDIR)/$(FLIST) -o simv -l build.log
RUN_CMD = cd $(BUILD) && ./simv +UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED) $(PLUSARGS)
else ifeq ($(SIM),xrun)
build: uvm
	mkdir -p $(BUILD) && cd $(BUILD) && xrun -elaborate -uvm -uvmhome CDNS-1.2 -timescale 1ns/1ps \
	  -top $(TOP) -f $(CURDIR)/$(FLIST) -l build.log
RUN_CMD = cd $(BUILD) && xrun -R +UVM_TESTNAME=$(TEST) -svseed $(SEED) $(PLUSARGS)
else ifeq ($(SIM),questa)
build: uvm
	mkdir -p $(BUILD) && cd $(BUILD) && vlib work && vlog -sv -timescale 1ns/1ps \
	  +incdir+$(UVM_HOME) $(UVM_HOME)/uvm_pkg.sv -f $(CURDIR)/$(FLIST) -l build.log
RUN_CMD = cd $(BUILD) && vsim -c -sv_seed $(SEED) $(TOP) +UVM_TESTNAME=$(TEST) $(PLUSARGS) -do "run -all; quit -f"
endif

run:
	$(RUN_CMD)

regress:
	python3 regress/regress.py --sim $(SIM) --jobs $(JOBS) $(if $(LIST),--list $(LIST),)

# coverage regression (Verilator): merged, annotated, scored against waivers
cov:
	scripts/cov/run_cov.sh $(TB) $(or $(LIST),regress/testlist.txt)

vip_build:
	$(MAKE) build TB=vip
vip_run:
	$(MAKE) run TB=vip TEST=$(TEST)

clean:
	rm -rf build regress_out
