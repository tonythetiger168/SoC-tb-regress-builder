# SPDX-License-Identifier: Apache-2.0
# AMBA SoC UVM testbench -- build and run
#   make build                       compile the SoC testbench (Verilator by default)
#   make run TEST=soc_smoke_test SEED=1
#   make regress                     every suite in regress/suites/, merged coverage + latency report
#   make regress SUITE='amba_*' LEVEL=subsystem PROFILE=nightly
#   make regress LIST=regress/testlist.txt     (legacy single test list)
#   make suites                      list the suites
#   make covmerge DIRS="out1 out2" OUT=cumulative
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
TOP_tv8k_noc := tv8k_noc_tb_top
TOP_tv8k_noc_open := tv8k_noc_tb_top
-include $(wildcard socgen/out/*/socgen.mk)
TOP      := $(TOP_$(TB))
FLIST    := $(or $(FLIST_$(TB)),sim/$(TB).f)
# TB=tv8k_noc needs the xuanji-core router (scripts/fetch_private_ip.sh puts it
# in ext/); without it the build falls back to the open stand-in router
ifeq ($(TB),tv8k_noc)
ifeq ($(wildcard ext/xuanji-core/rtl/noc/orca_noc_router.sv),)
$(info ext/xuanji-core not fetched: building tv8k_noc with the open router (sim/tv8k_noc_open.f))
FLIST    := sim/tv8k_noc_open.f
endif
endif
JOBS     ?= $(shell nproc)
PLUSARGS ?=

.PHONY: build run regress suites covmerge vip_build vip_run uvm clean
SUITE   ?=
LEVEL   ?=
SOC     ?=
PROFILE ?= default
OUT     ?= regress_out

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
	python3 regress/regress.py --sim $(SIM) --jobs $(JOBS) --profile $(PROFILE) --out $(OUT) \
	  $(if $(LIST),--list $(LIST),) $(foreach s,$(SUITE),--suite '$(s)') $(foreach l,$(LEVEL),--level $(l)) \
	  $(foreach c,$(SOC),--soc $(c))

suites:
	python3 regress/regress.py --list-suites

covmerge:
	python3 regress/covmerge.py $(DIRS) -o $(OUT)

vip_build:
	$(MAKE) build TB=vip
vip_run:
	$(MAKE) run TB=vip TEST=$(TEST)

clean:
	rm -rf build regress_out
