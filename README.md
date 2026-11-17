# SoC-tb-regress-builder

A SystemVerilog/UVM testbench for a small AMBA SoC, with reusable **AXI4**,
**AXI4-Lite**, **APB4** and **memory** VIPs, a self-checking scoreboard of the whole SoC, and
a seed-sweeping regression runner. It runs on the open-source flow (Verilator
5.052 + Accellera uvm-core 2020.3.1, the same versions as
[open-vip-portfolio](https://github.com/tonythetiger168/open-vip-portfolio)),
and the Makefile has entries for VCS, Xcelium and Questa.

## The DUT: `amba_soc_top`

```
  m0 AXI4 (CPU) --+                       +--> S0 SRAM 1 KB        open-ip AXI4_top
                  +--> soc_axi_ic 2x3 ----+--> S1 axi2apb_bridge --> apb_decoder
  m1 AXI4 (DMA) --+   round-robin,        |       slot 0 GPIO_apb  (open-ip)
                      1 burst in flight   |       slot 1 UART_apb  (open-ip, TX->RX loop)
                      per direction       |       slot 2 external APB port
                                          +--> S2 external AXI4 port ("DDR")
```

| Region | Address | Target |
|---|---|---|
| SRAM | `0x0000_0000`-`0x0000_FFFF` | 1 KB SRAM; the rest of the window answers SLVERR |
| APB  | `0x1000_0000`-`0x1000_FFFF` | 4 KB slots: GPIO `0x1000_0000`, UART `0x1000_1000`, external `0x1000_2000`; slots 3-15 answer SLVERR |
| DDR  | `0x8000_0000`-`0x8FFF_FFFF` | external AXI4 port (5-bit IDs = {master, ID}) |
| other | | DECERR from the interconnect's default slave |

New RTL is in `rtl/soc/` (interconnect, AXI-to-APB bridge, APB decoder, top);
the SRAM, GPIO and UART are reused unchanged from
[open-ip-portfolio](https://github.com/tonythetiger168/open-ip-portfolio)
(`rtl/ip/`, see its README for the commit and the SRAM's known limitations).

## VIPs (`vip/`)

| VIP | Contents |
|---|---|
| `vip/axi4` | `axi4_if`; `axi4_agent` in master role (driver + sequencer) or slave role (reactive memory responder); monitor (W-before-AW, several outstanding bursts, per-ID ordering); coverage; latency recorder (`axi4_latency`); `axi4_sva` (VALID/READY handshake and payload stability, reset, WRAP length, 4 KB crossing); random burst sequence (FIXED/INCR/WRAP, narrow, unaligned, partial strobes) and directed `axi4_api` helpers |
| `vip/apb`  | `apb_if`; `apb_agent` as requester (master), completer (slave, with random wait states and a PSLVERR window) or passive monitor; coverage; `apb_sva` (SETUP->ACCESS, stability while waiting, PSTRB on reads, X checks) |
| `vip/axi4lite` | `axil_if`; `axil_agent` as master (AW/W in either order with skew, random BREADY/RREADY) or slave (memory responder with wait states and SLVERR/DECERR windows); monitor; coverage; `axil_sva`; `axil_scoreboard`; random sequence and directed `axil_api` helpers. Self-test: `make build TB=axil && make run TB=axil TEST=axil_loopback_test` |
| `vip/mem`  | `mem_model`: sparse byte memory shared by the AXI4/APB responders, with bus-word access, backdoor peek/poke/fill/load/dump, and a deterministic init pattern for unwritten bytes so models can predict them |

All randomization uses `$urandom`, so nothing depends on a constraint solver.
The VIPs are checked against each other by the loopback self-tests in
`tb/vip_selftest/` (AXI master <-> AXI memory slave, APB requester <-> completer).

The VIPs were written for this SoC rather than taken from
open-vip-portfolio's AMBA zips: those share one combined AXI+AHB+APB
interface, model a single-ID master, and have no slave/memory side, which a
multi-port SoC testbench needs. Their checker ideas (handshake stability,
WLAST/RLAST accounting) carried over.

## Testbench (`tb/soc/`)

`soc_env` has two AXI4 master agents on m0/m1, an AXI4 slave agent with a
`mem_model` on the DDR port, an APB slave agent with a `mem_model` on the
external slot, a passive APB agent on the internal APB bus, SVA checkers on
every port, and `soc_scoreboard`, a reference model of the whole SoC:

* **SRAM**: models `AXI4_top` exactly (response codes, partial out-of-range bursts, byte strobes).
* **DDR**: shadow memory per byte; each burst must also appear unchanged on the external port with ID `{master, id}`.
* **APB**: every AXI beat must be one APB transfer with the same address, data and strobes; RRESP/BRESP must follow PSLVERR; read data, errors and side effects are predicted for unmapped slots/offsets, the ID and SCRATCH registers of GPIO and UART, and the external slot.
* **Unmapped**: DECERR on every beat.

| Test | What it does |
|---|---|
| `soc_smoke_test` | one directed access to every target, including error cases and the DDR backdoor |
| `soc_sram_test` | random bursts in the SRAM, then over its edge (WRAP, long bursts, out of range) |
| `soc_ddr_test` | random FIXED/INCR/WRAP, narrow and strobed bursts up to 256 beats, plus the DDR error window |
| `soc_apb_test` | bridge traffic to GPIO, UART, the external slot (wait states, PSLVERR) and unmapped slots |
| `soc_decerr_test` | bursts into unmapped holes of the map |
| `soc_concurrent_test` | both masters at once over every target |
| `soc_stress_test` | concurrent traffic with heavy back-pressure on every channel |
| `soc_cov_test` | directed coverage closure: AxPROT/IDs, address-bit toggles, 256-beat bursts, DDR DECERR window, long APB bursts, GPIO pins and IRQ, UART loopback, mid-test reset |

Plusargs: `+SOC_ITEMS=<n>` (traffic per test), `+SOC_TIMING=0|1|2` (delay
profile), `+VCD` (waveform dump). A run prints `SB_PASS checks=<n>` when the
scoreboard saw no mismatch.

## Running

```sh
bash scripts/install_tools.sh               # Verilator v5.052 + ./uvm-core (once)
export PATH=/opt/verilator-5.052/bin:$PATH

make build                                  # ~2 min with Verilator (uvm-core is compiled in)
make run TEST=soc_stress_test SEED=7
make regress                                # every suite, merged coverage + latency report
make regress PROFILE=nightly                # longer lists
make regress LEVEL=subsystem SOC=amba       # or SUITE='amba_*'
make suites                                 # list the suites
python3 regress/regress.py --list regress/testlist.txt   # the old single-list mode still works
```

`SIM=vcs|xrun|questa` switches simulator in the Makefile (those flows use the
simulator's own UVM library and are not exercised by CI; the regression runner
drives them for the legacy `soc`/`vip` benches without code-coverage merging).

## Regression suites and cumulative coverage

Suites live in `regress/suites/*.yaml` (schema and bench contract:
[regress/suites/README.md](regress/suites/README.md)). Each one has a level
(`soc`, `subsystem` or `vip`), the SoC it belongs to, a bench (filelist + top)
and a test list per profile. Today's suites:

| Suite | Level | Tests |
|---|---|---|
| `amba_soc` | SoC | smoke, concurrent and stress traffic from both masters to every target |
| `amba_sram` | subsystem `sram` | SRAM window and its edges |
| `amba_ddr` | subsystem `ddr` | external DDR port bursts and error window |
| `amba_apb` | subsystem `apb_periph` | AXI-to-APB bridge, GPIO, UART, external slot |
| `amba_noc` | subsystem `interconnect` | address decode and DECERR |
| `vip_selftest` | VIP | AXI4 and APB VIP loopbacks |

The phone, 8K TV and IP-camera SoCs (generated from the common SoC spec) and
the subsystem VIP benches from open-vip-portfolio join by adding their own
suite files; nothing in the runner changes.

What each run collects, and how it adds up:

* **Code coverage**: benches are built with Verilator line, branch, toggle and
  assertion coverage, limited to design RTL (`cov_include`, default `*rtl/*`).
  Per-run `coverage.dat` files merge into each suite's, and suites merge per RTL
  module and source line, so an IP exercised by its subsystem suite and by the
  SoC suite is credited once with the union of both.
* **Functional coverage**: coverage models count their bins through
  `vip/common/fcov_pkg.sv` (`FCOV` lines; Verilator's own covergroup data is
  reported alongside). Bins merge per bench and instance, and are also folded
  per coverage model across all benches.
* **Per-path latency**: `vip/common/lat_pkg.sv` takes one sample per completed
  transaction (master, slave, R/W, cycles); `axi4_latency` feeds it from any AXI
  master monitor. The report gives min/avg/p50/p95/p99/max per path with a
  read/write split, a master x slave heatmap, per-path range bars and
  histograms of the busiest paths.

`regress_out/` then holds `index.html` (the cumulative dashboard: suites,
roll-ups by level and by SoC, coverage by RTL module with the uncovered lines,
functional coverage holes, latency charts), a page per suite with its runs and
logs, `summary.md`, `summary.csv`, `junit.xml`, and `cumulative/` with the
merged `coverage.dat` (feed it to `verilator_coverage --annotate`),
`fcov.json` and `latency.json`.

`regress/covmerge.py out1 out2 ... -o merged` adds several output directories
together (CI shards, several nights, a local run plus CI). CI
(`.github/workflows/regress.yml`) runs the SoC, subsystem and VIP suites as
three parallel jobs and merges them into one `regress_cumulative` artifact; the
nightly schedule uses the `nightly` profile.

## Tiled many-core SoCs (`socgen` manycore specs)

A spec with a `manycore:` section describes an OpenPiton-style chip instead of
an AMBA SoC: an X x Y mesh of tiles, each with a RISC-V core, private RAM, a
write-through L1, a slice of the shared L2 with a limited-pointer coherence
directory, and three NoC routers (requests; data, acks and invalidations;
invalidation acks). The cores talk to each other through coherent shared
memory: every core runs rounds of computation, a barrier and an exchange
with tiles i+1 and i+X.

```sh
python3 socgen/socgen.py socgen/specs/manycore_4x4.yaml --minisim-root ../minisim
make build TB=manycore_4x4
make run TB=manycore_4x4 TEST=manycore_4x4_random_test SEED=3
make regress SUITE=manycore_4x4
```

The RTL comes from minisim's `bench/gen_manycore.py`, so one generator serves
both projects (`--minisim-root` or `MINISIM_ROOT`; the generated RTL is checked
in under `socgen/out/`, so building does not need minisim). The default core
is `mcrv`, a small RV32I core of minisim's; `picorv32`, `femtorv32`, `cva6`
(OpenHW CVA6) or mixes need their sources in `manycore.core_files`.
`socgen/lib/manycore.py` writes the UVM bench:

* **NoC monitor**: probes on every tile's local router ports. Functional
  coverage (`FCOV`) of message types per network, request hop counts, which
  L2 slice serves requests, and invalidation fan-out per write (none, one,
  two up to the pointer count, broadcast). One latency sample per request
  (`LAT T<tile> L2_<home> R|W <cycles>`), so the report's heatmap is
  requesting tile x home slice.
* **Scoreboard**: a SystemVerilog model of the program. At the end it reads
  every core's final value out of the L2 slices and compares it, plus the
  checksum core 0 computed: N + N + 1 checks, `SB_PASS checks=<n>`.
* **Tests**: the test writes the program's round count and work per round
  into every tile's RAM before reset, so seeds vary the run.

| Test | Rounds / work |
|---|---|
| `<soc>_smoke_test` | 2 / 8 |
| `<soc>_random_test` | 1-6 / 1-64 per seed |
| `<soc>_barrier_test` | 8 / 1: barriers and invalidations back to back |
| `<soc>_long_test` | 4 / 96: most cores wait while the slowest compute |

`+MC_ROUNDS=` and `+MC_WORK=` override them. Specs: `manycore_4x4` (in the
default regression) and `manycore_8x8` (64 tiles, `make regress
SUITE=manycore_8x8`). On Verilator 5.054 all four tests pass on 4x4
(66 checks each).

## Phone SoC bench (`rtl/phone/`, `tb/phone/`)

`phone_soc_top` is a phone-class SoC built around 32 LPDDR5 AXI slave VIPs:

- **15 AXI4 masters** (traffic models for now): CPU, GPU, APU, ISP, ICP, VDEC,
  VENC, DISP, ADSP, MODEM, CONN, SCP, UFS, SEC, DMA.
- **6 IOMMUs** (`phone_iommu`) in front of APU, ISP, ICP, VDEC, VENC and DISP:
  single-level page table in DRAM, 4 KB pages, 8-entry TLB, page walker,
  permission and range faults (SLVERR), APB register block.
- **NoC** (`phone_noc`): a behavioural 4x4 XY mesh with per-slave round-robin
  arbitration and hop latency `2*NI + (h+1)*R + h*L` cycles each way.
- **32 LPDDR5 channels** (`vip/lpddr5`): 64 MB each at 0x8000_0000, 4 KB
  interleave with an XOR hash, per-channel bank/page/refresh timing for
  5500/6400/7500/8533 MT/s, open or closed page, all-bank or per-bank refresh.
- SRAM at 0x0 and the APB peripherals (GPIO, UART, I2C, SPI, PWM, TRNG, the
  IOMMU registers) at 0x1000_0000, all checked through UVM RAL. The segment
  at 0x1001_0000 is the subsystem IPs' register space (ss APB port).

Build with `make build TB=phone` (about 4 minutes) and run e.g.
`make run TB=phone TEST=phone_camera_test`. Tests: `phone_smoke_test`,
`phone_ral_test`, `phone_iommu_test`, `phone_lpddr5_test`, the use cases
`phone_camera_test`, `phone_video_test`, `phone_gaming_test`, `phone_ai_test`,
and `phone_stress_test` (all 15 masters at once). Plusargs: `+SOC_ITEMS=<n>`,
`+SOC_TIMING=<0|1|2>`, `+LP5_SPEED=<0..3>`, `+LP5_PAGE=<0 open|1 closed>`,
`+LP5_REF=<0 all-bank|1 per-bank>`.

**Real-IP build** (`make build TB=phone_real`, i.e. `+define+PHONE_REAL_IPS`;
suite `phone_real`): `phone_ss_ips` puts the open-ip-portfolio subsystem IPs on
the master ports instead of the traffic models: CPU_Cluster on CPU, GPU, NPU on
APU, ISP, Display_Controller on DISP, two Video_Codec instances on VDEC and
VENC, Modem, DMA, Audio_DSP on ADSP, and Sensor_Hub, Interrupt_Controller and
Timer_WDT sharing the SCP port through `phone_aon_arb`. Their registers sit in
a second APB segment at 0x1001_0000 (RAL blocks generated from the IP
datasheets by `scripts/gen_phone_ss_ral.py`). The agents on those ports become
monitors, and software (RAL, job setup) runs on the SEC port.
`phone_ss_test` runs 18 jobs on the 12 IPs at once, VENC through IOMMU 4, and
compares every output buffer and result register (CRCs, checksums,
saturation counters, interrupt log) with a reference model taken from the
IP's datasheet. ICP, CONN, UFS and SEC stay traffic models.

Every burst is a `LAT` sample (master, slave port after IOMMU translation, R/W,
cycles from the first VALID cycle at the master port to the last R beat or B),
so the regression report has the per-path latency table, the master x slave
heatmap and the histograms. The log also prints a per-path table with the
ideal NoC latency next to the measured one, per-master bandwidth and per-channel
LPDDR5 page hit / miss / conflict and refresh counts. The suites are
`phone_soc` (use cases), `phone_real` (real-IP build) plus `phone_iommu`,
`phone_lpddr5` and `phone_apb`
(`python3 regress/regress.py --soc phone`).

## Results

On Verilator 5.052, the default profile passes 36/36 runs over 6 suites and
the nightly profile 136/136 runs (about 800,000 scoreboard checks). Cumulative
coverage of the AMBA SoC RTL after the nightly profile: line 86.0%, branch
75.5%, toggle 85.8%; functional bins 97.0% counted per coverage instance, and every bin of the AXI4
and APB coverage models is hit by at least one instance. The SoC-level suite alone
reaches 86.0% / 72.5% / 79.4%; adding the subsystem suites lifts branch and
toggle coverage, which is the point of running both.
As a sanity check of the checker itself, forcing the bridge's PSTRB to 4'hF or
dropping the master bit from the DDR-port ID makes `soc_apb_test` and
`soc_concurrent_test` fail.

## Coverage

```sh
make cov                                    # = scripts/cov/run_cov.sh soc regress/testlist.txt
```

`scripts/cov/run_cov.sh` builds the bench with Verilator line/branch, toggle
and user coverage plus assertions, runs the test list, merges the runs into
`build/cov/<tb>/merged.dat` (annotated sources next to it) and scores it with
`scripts/cov/score_cov.py`:

* code coverage (line, branch, toggle) of the SoC RTL in `rtl/soc/`;
* SVA coverage: the cover properties in `axi4_sva` / `apb_sva` (each
  assertion's antecedent must occur on every checked port);
* functional coverage: every covergroup bin of the AXI4 and APB agents.

Points that cannot be reached are waived in `scripts/cov/exclude/soc.txt`, one
regex per line with its reason; the score fails on any unhit point that is not
waived and on a waiver that no longer matches anything. With the default list
all five metrics are at 100% (line 36, branch 78, toggle 6436, SVA cover 46,
covergroup bins 63; 302 points waived): AxSIZE[2] on a 32-bit bus, PADDR[31:16]
inside the 64 KB APB window, RESP[0] of the APB bridge (OKAY/SLVERR only), the
SRAM-side IDs the interconnect ties to 0, FSM `default:` arms, and the bridge's
simulation-only WLAST-mismatch message, which the interconnect makes
unreachable. The vendored peripherals in `rtl/ip/` (AXI4 SRAM, GPIO, UART) are
closed at 100% by their own benches in open-ip-portfolio.

The socgen benches have a generated `<soc>_cov_test` in their test lists and
a generated waiver list, `socgen/out/<soc>/doc/<soc>_cov_waivers.txt`, which
`run_cov.sh` reads next to `scripts/cov/exclude/<soc>.txt`:

```sh
make cov TB=mini_soc LIST=regress/mini_soc_testlist.txt
```

The score covers the generated SoC glue (`<soc>_apb_subsys`, the register
files, the AXI-to-APB bridge), the SVA covers on every NoC port and the AXI4
and APB covergroups. The IPs' own logic and their external pins are measured
by their benches in open-ip-portfolio, so their pins are waived here. On
Verilator 5.052 all five metrics reach 100% for `mini_soc`, `phone_soc`,
`ipcam_soc` and `ipcam_hd_soc` (IPCAM measured on the traffic-model build, since the private
codec and CPU repos are fetched at build time).

## Notes for Verilator users

A clocking-block drive issued by a process that woke up from something other
than the clocking event (a mailbox, `get_next_item`, a `fork`/`join`) only
takes effect one clock later in Verilator. The drivers therefore re-sync to
the clock before starting a transfer, and every handshake loop checks its own
driven VALID/READY on the interface as well as the sampled input, so a
deferred drive can never be mistaken for a completed handshake.

## License

Apache-2.0, see `LICENSE`.
