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
| `vip/axi4` | `axi4_if`; `axi4_agent` in master role (driver + sequencer) or slave role (reactive memory responder); monitor (W-before-AW, several outstanding bursts, per-ID ordering); coverage; `axi4_sva` (VALID/READY handshake and payload stability, reset, WRAP length, 4 KB crossing); random burst sequence (FIXED/INCR/WRAP, narrow, unaligned, partial strobes) and directed `axi4_api` helpers |
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
make regress                                # regress/testlist.txt, all CPUs
python3 regress/regress.py --list regress/nightly.txt --jobs 8
python3 regress/regress.py --filter apb --seeds 20 --no-build
```

`SIM=vcs|xrun|questa` switches simulator in the Makefile (those flows use the
simulator's own UVM library and are not exercised by CI).

The regression runner builds each testbench once, runs every `<test> x seed`
in parallel and writes `regress_out/`: one log per run, `summary.csv`,
`summary.md` and `junit.xml`. A run passes when the simulator exits cleanly,
`UVM_ERROR` and `UVM_FATAL` are 0 and the scoreboard printed `SB_PASS`.
CI (`.github/workflows/regress.yml`) runs the default list on every push and
the nightly list on a schedule.

## Results

On Verilator 5.052: `regress/testlist.txt` passes 38/38 runs and
`regress/nightly.txt` passes 136/136 runs (about 800,000 scoreboard checks).
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
