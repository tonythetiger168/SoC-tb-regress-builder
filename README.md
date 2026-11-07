# SoC-tb-regress-builder: UVM testbench + memory profile for AXI NoC meshes

`nocgen.py` reads a config with the mesh size, the AXI masters and slaves, the
router/link timing and an optional traffic matrix, and writes:

* `out/<name>/tb/`: a complete UVM testbench
  * `noc_params_pkg.sv`: counts, widths, address map, and the shortest-path
    latency tables `REQ_LAT[m][s]` / `RSP_LAT[m][s]`
  * `axi_if.sv`: AXI4 interface with handshake-stability assertions
  * `noc_tb_pkg.sv`: master agents (driver, monitor, sequencer), a slave memory
    responder per NoC slave port, a scoreboard, sequences and tests
  * `noc_mesh_stub.sv`: a behavioural NoC so the TB runs before your RTL
    exists. Swap it for the real mesh in `tb_top.sv`.
  * `files.f` and a `Makefile` with VCS, Xcelium and Questa targets
* `out/<name>/profile/`: the memory profile
  * `profile.md`: placement before and after, address map, per-pair latency,
    and for each master the memory regions ranked by latency (where to keep hot data)
  * `profile.json`: the same data, machine-readable
  * `noc_memmap.h`: C header with bases, sizes and each master's nearest region

```
pip install -r requirements.txt
python3 nocgen.py examples/mesh4x4.yaml -o out/soc4x4
cd out/soc4x4/tb && make vcs TEST=noc_zero_load_test
make vcs TEST=noc_traffic_test ARGS="+NOC_TXNS=1000"
```

## Checks in this repo

```
pytest -q tests                                      # profile consistency on every example
python3 scripts/lint_tb.py out/soc4x4/tb <uvm-core>/src   # elaborate a generated TB with slang + UVM
```

CI runs both on every push (`.github/workflows/ci.yml`).

## Latency model

One traversal over `h` links costs `ni + (h+1)*router + h*link` cycles. The
minimum read latency (AR handshake to first R beat) is
`request path + slave access + response path`. Writes (AW handshake to B) add
one cycle per extra W beat. The request and response paths are routed
separately, because XY routing is not symmetric once links are disabled.

* `routing: xy`: dimension-ordered. A disabled link on an XY path makes that
  pair unroutable.
* `routing: shortest`: any minimal path that avoids disabled links (BFS).

## What the testbench checks

| Check | Where | Fails when |
|---|---|---|
| Routing | slave responder | a slave port gets an address outside its range |
| Decode error | scoreboard | an unmapped address doesn't return DECERR |
| Data | scoreboard | a read doesn't return the last write (each master owns a 4 KB-aligned slice of every slave) |
| Too fast | scoreboard | measured latency is below the shortest-path minimum, so the model or the DUT is wrong |
| Zero load | `noc_zero_load_test` | with one master active at a time, latency is more than `zero_load_slack` cycles over the minimum |
| Under load | `noc_traffic_test` | latency is above `latency_tolerance` x minimum (a warning; `+NOC_SLOW_IS_ERROR` makes it an error) |

The scoreboard's report prints, for every master/slave pair and direction, the
ideal latency, the measured min/avg/max and the average excess over ideal.

Plusargs: `+NOC_TXNS=<n>`, `+NOC_TOL=<x>`, `+NOC_SLACK=<n>`, `+NOC_SLOW_IS_ERROR`.

## Memory profile

The profile minimises call-weighted minimum read latency with three levers,
searched together (each placement the search tries is scored with the best
data layout for it):

1. **Endpoint placement.** Endpoints with `node: auto` move by local search
   with random restarts (`--restarts`, default 40). Pinned endpoints stay put.
2. **Data placement.** List the data the masters call under `regions:` (stacks,
   rings, frame buffers, weights) with a size and per-master call counts.
   nocgen decides which memory holds each one, within each memory's size.
   `home` is today's layout and is the baseline, `allowed` limits where a region
   may go, and `pin: true` keeps it on `home`. With `split: <chunk>`, part of a
   big buffer can go to a faster memory.
3. **Read-only copies.** Regions marked `readonly: true` are copied into spare
   memory next to their callers. Each master gets its own base address in
   `noc_memmap.h` (`NOC_<MASTER>_<REGION>_BASE`).

Slaves with `kind: device` (registers) hold no regions; calls to them go
under `traffic:`. Without `regions:`, `traffic:` gives calls per master/slave
pair, and only lever 1 applies.

`profile.md` shows each step's result, how the average call splits between
network cycles and memory access cycles, and a loose floor (zero hops, fastest
allowed memory, unlimited memory size).

Sample results (`examples/`), average minimum read latency in cycles:

| Config | Before | Placement only | + data placement + copies |
|---|---|---|---|
| `mesh4x4.yaml` (calls per slave) | 30.0 | 26.0 | n/a |
| `mesh4x4_regions.yaml` (same calls, as 16 regions) | 30.0 | 26.0 | 21.1 (29.6% lower) |

Auto slaves get addresses biggest first, each aligned to its own power-of-two
size, so decode is a mask compare. Regions are laid out inside their memory,
biggest first and 4 KB aligned.

## Limits

* AXI4 subset: INCR bursts up to 16 beats at full data width. The TB master
  keeps one transaction in flight per port. No exclusive access, QoS or user
  signals yet.
* The latency model is zero-load: it does not account for queueing when
  several masters hit the same memory. `noc_traffic_test` measures that.
* The stub NoC is store-and-forward with one transaction at a time per slave
  port. It does not model router buffers or link contention.
* The generated code elaborates cleanly with slang 12.1 and Accellera UVM
  (uvm-core). It has not been run on VCS, Xcelium or Questa yet.
