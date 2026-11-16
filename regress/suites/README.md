# Regression suites

Every `*.yaml` file here is one suite. `regress/regress.py` discovers them all,
builds each distinct bench once (with code coverage), runs every test x seed,
and merges code coverage, functional coverage and per-path latency per suite and
across suites. See the top-level README for the report.

## Suite file

```yaml
name: amba_sram            # unique; also the output directory name
level: subsystem           # soc | subsystem | vip
soc: amba                  # which SoC the suite belongs to (roll-ups group by it)
subsystem: sram            # subsystem suites: which block
description: one line for the report
filelist: sim/soc.f        # Verilator filelist, relative to root
top: soc_tb_top            # testbench top module
list:                      # test list, or one per profile (--profile nightly)
  default: regress/lists/amba_sram.txt
  nightly: regress/lists/amba_sram_nightly.txt
# optional
root: .                    # directory the filelist paths are relative to
plusargs: [+SOC_TIMING=1]  # added to every run
defines: [MY_DEFINE]       # +define+ for the build
incdirs: [some/dir]
filter: regex              # only tests whose name matches
cov_include: ["*rtl/*"]    # source files counted for code coverage (fnmatch on the path)
pass_markers: [SB_PASS, RAL_PASS]
timeout: 900               # seconds per run
uvm: true                  # compile Accellera uvm-core in
enabled: true              # false: run only when named with --suite
requires: [path, ...]      # files that must exist (e.g. a private IP checkout)
fallback:                  # applied when a 'requires' path is missing; without
  defines: [USE_TRAFFIC_MODEL]   # a fallback the suite is skipped and reported as not run
zip: path/to/X-UVM-VIP.zip # unpack a packaged VIP bench and run it from there
```

Suites that share `filelist`, `top`, `defines` and `cov_include` share one
build. That is how the AMBA subsystem suites run on the SoC bench: each owns
the tests aimed at its block, and the roll-ups add them up with the SoC-level
suite.

Test list lines are `<test> <seeds> [plusargs...]`. The old
`<tb> <test> <seeds> [plusargs...]` form is accepted too (the `tb` column is
ignored inside a suite). `#` starts a comment.

## What a bench prints

A run passes when the simulator exits 0, the UVM report has `UVM_ERROR : 0`
and `UVM_FATAL : 0`, and the log has a pass marker (`SB_PASS checks=<n>` with
n > 0, or `RAL_PASS`).

**Functional coverage.** Open-source simulators record covergroups only
partly, so coverage models also count their bins through
`vip/common/fcov_pkg.sv`, which prints one line per bin at the end of the run:

```
FCOV <model> <inst> <point> <bin> <hits>      # fcov_pkg form
FCOV <group> <point> <bin> <hits>             # short form, also accepted
```

Declare every bin (so unhit bins count as holes), hit them on sample, and call
`dump()` in `report_phase`. `axi4_coverage` and `apb_coverage` are examples.

**Latency.** One sample per completed transaction through
`vip/common/lat_pkg.sv`:

```systemverilog
lat_pkg::lat_db::add("CPU", "LPDDR5_07", "R", cycles);
```

or a log line `LAT <master> <slave> <R|W> <cycles>`. Cycles are counted from
the address handshake to the last R beat (reads) or the B handshake (writes).
`axi4_latency` (in `vip/axi4`) does this for any AXI4 master-side monitor;
override `slave_of()` with the SoC's address map, as `soc_latency` does in
`tb/soc/soc_env_pkg.sv`. The runner passes `+LAT_FILE=<path>` so samples go
to a file instead of the log.

**Code coverage** needs nothing from the bench. The build turns Verilator
line, toggle, branch and assertion coverage on, switches it off for uvm-core,
`vip/` and `tb/`, and the report keeps only files matching `cov_include`.
