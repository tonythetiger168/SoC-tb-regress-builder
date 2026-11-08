# SoC-tb-regress-builder

A SystemVerilog/UVM testbench for a small AMBA SoC, with reusable **AXI4**,
**APB4** and **memory** VIPs, a self-checking scoreboard of the whole SoC, and
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
  IOMMU registers) at 0x1000_0000, all checked through UVM RAL.

Build with `make build TB=phone` (about 4 minutes) and run e.g.
`make run TB=phone TEST=phone_camera_test`. Tests: `phone_smoke_test`,
`phone_ral_test`, `phone_iommu_test`, `phone_lpddr5_test`, the use cases
`phone_camera_test`, `phone_video_test`, `phone_gaming_test`, `phone_ai_test`,
and `phone_stress_test` (all 15 masters at once). Plusargs: `+SOC_ITEMS=<n>`,
`+SOC_TIMING=<0|1|2>`, `+LP5_SPEED=<0..3>`, `+LP5_PAGE=<0 open|1 closed>`,
`+LP5_REF=<0 all-bank|1 per-bank>`.

Every burst is a `LAT` sample (master, slave port after IOMMU translation, R/W,
cycles from the first VALID cycle at the master port to the last R beat or B),
so the regression report has the per-path latency table, the master x slave
heatmap and the histograms. The log also prints a per-path table with the
ideal NoC latency next to the measured one, per-master bandwidth and per-channel
LPDDR5 page hit / miss / conflict and refresh counts. The suites are
`phone_soc` (use cases) plus `phone_iommu`, `phone_lpddr5` and `phone_apb`
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

## Notes for Verilator users

A clocking-block drive issued by a process that woke up from something other
than the clocking event (a mailbox, `get_next_item`, a `fork`/`join`) only
takes effect one clock later in Verilator. The drivers therefore re-sync to
the clock before starting a transfer, and every handshake loop checks its own
driven VALID/READY on the interface as well as the sampled input, so a
deferred drive can never be mistaken for a completed handshake.

## License

Apache-2.0, see `LICENSE`.
