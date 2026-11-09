# socgen SoC spec, version 1

One YAML file describes a whole SoC. `socgen.py` validates it and writes the
testbench configuration from it. Sizes and addresses take integers in any
YAML form (`0x8000_0000`, `65536`) or a suffix string (`"64K"`, `"2G"`).
Unknown keys are an error, so a typo never passes silently.

Instances in this repo: `specs/phone_soc.yaml` (15 masters, 6 IOMMUs, 4x4
mesh, 32 LPDDR5 ports) and `specs/mini_soc.yaml` (small, for CI).

## Top level

| Key | Required | Meaning |
|---|---|---|
| `socgen` | yes | schema version, `1` |
| `soc` | yes | `name` (SV identifier, also the output directory), `prefix` (function prefix, default `name`), `desc` |
| `clock` | no | `name` (default `aclk`), `period_ns` (default 2.0, at least 2: the VIPs drive 1 ns after the edge) |
| `bus` | no | `addr_width` (32), `data_width` (32), `id_width` (4). The bundled VIPs are 32/32. |
| `noc` | yes | interconnect, see below |
| `traffic` | no | named traffic profiles masters refer to |
| `masters` | yes | AXI masters |
| `iommus` | no | IOMMUs in front of masters |
| `memories` | no | interleaved memories, one NoC slave port per channel |
| `slaves` | no | other slave ports: `memory`, `apb_bridge`, `vip` |
| `register_blocks` | no | register tables for blocks without open-ip RTL |
| `chiplet` | no | two dies joined by UCIe (`noc.model: mesh`), see below |
| `chi` | no | CHI coherence: home node and coherent memory (`noc.model: mesh`), see below |
| `regress` | no | test lists |
| `report` | no | latency report settings |

## `noc`

| Key | Default | Meaning |
|---|---|---|
| `topology` | | `mesh` or `crossbar` (a crossbar is a 1x1 mesh: every path is 0 hops) |
| `rows`, `cols` | | mesh size; nodes are `[x, y]`, x = column, y = row |
| `routing` | `xy` | `xy` (dimension ordered) |
| `timing` | | `ni_cycles`, `router_cycles`, `link_cycles`. One way over `h` hops costs `2*ni + (h+1)*router + h*link`; request and response each pay it. |
| `model` | `behavioral` | `behavioral`: the TB's NoC component routes the traffic. `rtl`: tb_top instantiates `rtl_module` and the component is not built. `mesh`: socgen generates the NoC RTL (`<soc>_noc`, see "Generated NoC" below) and tb_top instantiates it. |
| `rtl_module` | | DUT module name for `model: rtl` |
| `router` | `orca` | `model: mesh`: `orca` = xuanji-core `orca_noc_router` (private, fetched into `ext/` by `scripts/fetch_private_ip.sh`; 2-bit coordinates, so at most 4x4); without the fetch, or with `open`, the open `rtl/noc/noc_router_open.sv` (same ports and routing, no VCs, any mesh size) |
| `buf_depth`, `num_vc` | 8, 4 | `model: mesh`: router input FIFO depth and orca virtual channels |
| `ni` | | `model: mesh`: `max_bursts` (4, AXI bursts per direction a master NI accepts), `max_chunks` (8, 32-byte chunks per direction in flight per master), `slave_outstanding` (4, bursts a slave NI keeps open at its slave). Powers of two, 2..32 |

With `model: mesh` the `timing` key is not used: the ideal latency tables come
from the generated RTL's measured zero-load timing (one single-beat read =
5 + 4 + 2 x hops + access cycles, plus 2 for each AXI4-Lite adapter on the
path, 4 for AHB-Lite, 5 for APB; writes about 2 more). The mesh has no IOMMU
model, so `tlb_hit_cycles` is not added. `socgen.py --noc-model mesh` builds a
spec on the mesh without editing it: the SoC is renamed `<name>_mesh`, so its
bench and suite sit next to the behavioural one for a latency comparison.

## `traffic.<profile>`

| Key | Default | Meaning |
|---|---|---|
| `read_pct` | 50 | share of reads |
| `beats` | `[1, 16]` | burst length range, INCR, full width |
| `targets` | all memories | slave or memory names this master reaches in the traffic test |
| `outstanding` | 1 | bursts in flight per master (the bundled AXI VIP drives 1) |
| `bandwidth_mbps` | | requested bandwidth; the report shows achieved vs requested |
| `pace` | false | space burst starts so the master issues at `bandwidth_mbps` (bytes x 1000 / MB/s ns per burst); `+SOC_PACE` turns it on for every profile with `bandwidth_mbps`. Not with `gap` |
| `gap` | 0 | idle cycles after each burst |

## `masters[]`

| Key | Default | Meaning |
|---|---|---|
| `name` | | identifier, unique; SV index `M_<NAME>` |
| `node` | | `[x, y]` router |
| `traffic` | | profile name, or an inline profile |
| `iommu` | | name from `iommus` |
| `qos.class` | `nrt` | `rt` (real-time, deadline), `nrt` (throughput), `be` (best effort) |
| `qos.priority` | 0 | 0..15; higher wins slave-port arbitration in the behavioural NoC |
| `qos.latency_target` | | read latency budget in cycles; the report flags any path from this master whose worst percentile is over it |
| `kind` | `vip` | `vip`: AXI master agent drives the port; `rtl`: an IP master (port left to the DUT) |
| `protocol` | `axi4` | protocol of the master port: `axi4`, `axi4lite`, `ahb` (AHB-Lite), `chi` (CHI RN-F, needs the `chi` section). Others than `axi4` need `noc.model: mesh`; the bench drives them from the AXI4 VIP through a test shim (`noc_axi2lite` / `noc_axi2ahb` / the `noc_chi_rnf` cache) |

## `iommus[]`

`name`, `tlb_hit_cycles` (added to the request path of its masters),
`tlb_entries`, `regs` (register block name, default `iommu`). Each IOMMU gets
one APB slot in the first `apb_bridge` slave, after its listed peripherals.

## `memories[]`

| Key | Meaning |
|---|---|
| `name`, `kind` | `kind`: `lpddr5`, `ddr`, `hbm` or `sram` (informational; picks the VIP) |
| `base`, `size` | address window |
| `channels` | power of two; channel `c` is NoC slave port `S_<NAME><c>` |
| `interleave.granule` | power of two, at least 4 KB, so a burst never spans channels |
| `interleave.hash` | `none`: `ch = a[g+n-1:g]`; `xor`: `ch = a[g+n-1:g] ^ a[g+2n-1:g+n]` |
| `access_cycles` | zero-load access time, used by the ideal-latency table and the behavioural NoC |
| `timing` | preset name handed to the memory VIP (`lpddr5-6400`) |
| `placement` | `rows: [..]` and `fill: block` (consecutive channels share a router) or `fill: round_robin`; or `nodes: [[x, y], ...]` one per channel |
| `protocol` | `axi4` (default), `axi4lite`, `ahb` or `apb` for every channel port, as for `slaves[]` |

`<prefix>_dram_channel(a)` and `<prefix>_dram_local(a)` (the channel-local
address with the channel bits removed) are generated for each memory.

## `slaves[]`

| Key | Meaning |
|---|---|
| `name`, `kind` | `memory` (VIP memory responder), `apb_bridge`, `vip` (generic AXI slave VIP) |
| `base`, `size`, `node`, `access_cycles` | as above |
| `slot_size` | `apb_bridge` only: slot window (default 4 KB) |
| `peripherals` | `apb_bridge` only, see below |
| `protocol` | `memory` and `vip` slaves: `axi4` (default), `axi4lite`, `ahb` (AHB-Lite) or `apb` (APB4) port on the generated NoC (`noc.model: mesh`); the bench answers through a shim to the AXI4 memory VIP. `apb_bridge` and `rtl` slaves are `axi4` |

### `peripherals[]`

| Key | Meaning |
|---|---|
| `name` | instance name |
| `slot` | slot number; default the next free one |
| `ip` | open-ip-portfolio IP name: RTL `rtl/<IP>_apb.sv` + `<IP>_top.sv`, RAL from `docs/ip/<IP>.md` |
| `regs` | a `register_blocks` name: socgen writes an APB register file and its RAL |
| `vip` | `apb`: an APB slave VIP backed by a memory model |
| `params` | wrapper parameter overrides |
| `pins` | pass-through input pin -> SV expression (default `'0`); outputs become wires `<name>_<pin>` |

## `register_blocks.<name>`

`desc`, and `regs[]`: `name`, `offset`, `access` (`RO`, `RW`, `W1C`, `WO`),
`reset`, `volatile`, `desc`, `fields[]` (`name`, `bits` "msb:lsb" or "n",
`access`, `reset`). Without `fields`, the register is one 32-bit field.

## `regress`

`ral_master` (master whose sequencer runs the RAL frontdoor, default the
first master), and `lists.<listname>[]` of `test`, `seeds`, `plusargs`.
Tests: `smoke`, `ral`, `path_latency`, `traffic`, `scenario`, and `coherence`
(needs `chi`; in the default list when `chi` is set). Each list is written to
`regress/<soc>_<listname>.txt` in the format `regress/regress.py` reads.

## `report.latency`

| Key | Default | Meaning |
|---|---|---|
| `percentiles` | `[50, 90, 99]` | percentiles per path |
| `split_rw` | true | separate read and write rows |
| `zero_load_slack` | 12 | `path_latency` test: allowed cycles over ideal (plus one per extra beat) |

## What gets generated (`out/<soc>/`)

| File | Content |
|---|---|
| `rtl/<soc>_pkg.sv` | `NM`, `NS`, `M_*`, `S_*`, `S_DEF`, address map, `<prefix>_decode()`, `<prefix>_dram_channel()`, `<prefix>_dram_local()`, node coordinates, `HOPS[m][s]`, `<prefix>_noc_lat(m,s)`, ideal read/write latency tables, `<prefix>_iommu_of(m)`, APB slot map, QoS tables |
| `rtl/<soc>_apb_subsys.sv` | AXI-to-APB bridge, slot decoder, every peripheral wrapper and generated register file |
| `rtl/<soc>_<block>_regs.sv` | APB register file for each `register_blocks` entry |
| `tb/<soc>_ral_pkg.sv` | UVM RAL: one block per APB slot, a top block with the SoC map, AXI adapter |
| `tb/<soc>_env_pkg.sv` | env: master agents, slave agents, behavioural NoC (`model: behavioral`), scoreboard, per-path latency monitor |
| `rtl/noc_cfg_pkg.sv`, `rtl/<soc>_noc.sv` | `model: mesh` only: the generated NoC, see below |
| `tb/<soc>_test_pkg.sv`, `tb/<soc>_tb_top.sv` | tests and top |
| `sim/files.f`, `socgen.mk` | file list; `make build TB=<soc>` works from the repo root |
| `regress/<soc>_<list>.txt` | regression lists |
| `doc/<soc>.md`, `doc/<soc>_memmap.h`, `doc/<soc>_paths.csv` | address map, mesh placement, ideal latency per path, C header |

## `chiplet` (optional, `noc.model: mesh`)

Two dies, one mesh each (both `rows` x `cols`), joined by a UCIe die-to-die
link. Masters, memories and slaves take `die: 0 | 1` (default 0); `node` is
the router on that die.

| Key | Default | Meaning |
|---|---|---|
| `dies` | | 2 |
| `link` | `ucie` | open-ip-portfolio `UCIe_top` (D2D adapter: 64-byte flits, CRC, Retry) on each die |
| `gateways` | | `[[x, y], [x, y]]`: the router of each die's die-to-die gateway |
| `phy_cycles` | 4 | PHY delay each way (`rtl/noc/noc_d2d_phy.sv`, a behavioural PHY) |
| `retry` | true | UCIe Retry on (`cfg_retry`) |

A flit for an endpoint on the other die is ejected at the local gateway
(`noc_d2d_gw`), carried as one UCIe flit, and injected on the far die. A
cross-die path costs the hops to the local gateway plus the far gateway's hops
to the target, and 5 + `phy_cycles` cycles each way across the link. The
gateways hold every packet that can be in flight (2 x masters x `max_chunks`),
so the link needs no credits and never back-pressures the meshes. The VIPs
start when both adapters reach ACTIVE. `+D2D_ERR_EVERY=<n>` makes the PHY model
corrupt every n-th flit to exercise CRC and Retry; the log ends with the
corrupted-flit and replay counts. `specs/chiplet_soc.yaml` is the example.

## `chi` (optional, `noc.model: mesh`, one die)

CHI coherence on the generated NoC: masters with `protocol: chi` are RN-Fs, the
other masters are RN-Is, and one HN-F on the mesh is the home of the coherent
memory.

| Key | Default | Meaning |
|---|---|---|
| `home` | | `[x, y]`: the HN-F's router |
| `coherent` | | memories (or slaves of kind `memory`) the home keeps coherent |
| `cache_lines` | 64 | lines of each RN-F cache (64-byte, direct-mapped, power of two 4..1024); also sizes the snoop filter |

- RN-F port: the CHI channels TXREQ / TXRSP / TXDAT and RXRSP / RXDAT / RXSNP
  as `noc_cfg_pkg` flit structs (CHI Issue B fields, narrowed: one home, so no
  node IDs; 256-bit data, a line is two DAT flits; valid / ready on TX instead
  of L-Credits, and the RN-F always accepts on RX). In the bench the AXI4 VIP
  is the CPU and `noc_chi_rnf` its cache: MESI (I / SC / UC / UD), ReadShared,
  ReadUnique, CleanUnique, WriteBackFull, Evict, CompAck; ReadNoSnp /
  WriteNoSnpPtl (one beat each) for addresses outside the coherent memory.
- HN-F (`noc_hnf`): exact inclusive snoop filter (a copy of every RN-F's tags),
  one transaction at a time; SnpShared / SnpUnique / SnpCleanShared; dirty
  data written back or passed on as UD_PD.
- RN-I: an AMBA master's chunks to coherent memory go to the home, which snoops
  (reads: the unique holder, SnpCleanShared; writes: every holder, SnpUnique),
  writes dirty lines back, and forwards the chunk to memory.
- Latency: a CHI master's paths, and an AMBA master's paths to coherent memory,
  go master -> home -> slave -> home -> master. `path_latency` does not check a
  CHI master's lower bound (cache hits).
- `coherence` test: false sharing, dirty lines migrating between caches and
  RN-Is (bursts across line boundaries), producer / consumer for every pair.

`specs/chi_mesh_soc.yaml` is the example. Not yet: DMT / DCT, retry and
P-Credits, atomics, CMOs, more than one home, chiplet.

## Generated NoC (`noc.model: mesh`)

socgen (`lib/nocgen.py`) writes two more files into `rtl/`:

| File | Content |
|---|---|
| `rtl/noc_cfg_pkg.sv` | package `noc_cfg_pkg`: mesh size, endpoint list (masters, then NoC slave ports), the router of each, `decode()` (wraps `<prefix>_decode`), flit and packet formats |
| `rtl/<soc>_noc.sv` | module `<soc>_noc #(ID_WIDTH)`: `clk`, `rst_n`, and one named port group per endpoint, `<name>_<signal>`, in the endpoint's protocol. The NoC is the slave on master ports and the master on slave ports |

The generic RTL it configures is in `rtl/noc/`:

| File | Role |
|---|---|
| `noc_mesh.sv` | MESH_X x MESH_Y routers (orca or `noc_router_open` with `+define+NOC_OPEN_ROUTER`), a node mux per router for the endpoints placed on it |
| `noc_ni_mst.sv` | master NI: AXI4 bursts cut into 32-byte chunks, one single-flit request each; responses back in order |
| `noc_ni_slv.sv` | slave NI: chunks become AXI4 bursts of up to 8 beats, ID 0, `slave_outstanding` in flight |
| `noc_axi2lite.sv` | AXI4 -> AXI4-Lite (slave ports; master-port test shim) |
| `noc_axi2ahb.sv` | AXI4 -> AHB-Lite master, one NONSEQ SINGLE per beat (slave ports; test shim) |
| `noc_ahb2axi.sv` | AHB-Lite slave -> AXI4, one single-beat AXI transfer per AHB transfer (master ports; test shim) |
| `noc_apb2axi.sv` | APB4 slave -> AXI4 (test shim for APB slave ports) |
| `noc_d2d_gw.sv`, `noc_d2d_phy.sv` | chiplet: die-to-die gateway (mesh <-> UCIe adapter) and the behavioural PHY between the two adapters |
| `noc_ni_chi.sv` | CHI: RN-F network interface (CHI channels <-> packets to the home) |
| `noc_hnf.sv` | CHI: home node, snoop filter, RN-I chunks to coherent memory |
| `noc_chi_rnf.sv` | CHI: RN-F cache (AXI4 slave -> cache -> CHI port), the bench's shim for `protocol: chi` |
| `rtl/soc/axi2apb_bridge.sv` | AXI4 -> APB4 on APB slave ports |

Protocol notes: AHB-Lite has no write strobes (a narrow write needs a narrow
HSIZE) and one error response (DECERR and SLVERR both become ERROR, and an AHB
master sees a decode miss as SLVERR). AXI4-Lite master ports use ID 0. Deadlock
freedom is end to end, as in the tv8k mesh: a master NI only issues a chunk
when its response slot is free, and each slave NI queues every chunk all
masters can have in flight (masters x `max_chunks`).

`specs/mini_mesh_soc.yaml` uses every protocol. `+define+NOC_OPEN_ROUTER` (or
building without `ext/xuanji-core`) gives the open router.

## Path latency report

Every simulation prints one `PATHLAT` line per master-target-direction with
traffic (count, min, avg, max, the percentiles, ideal, and the master's
target if any), plus a table in the UVM report. `tools/latency_report.py <log>`
turns them into `path_latency.csv`, `path_latency.md` and an SVG heatmap of
average read latency (masters x targets).
