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
| `regress` | no | test lists |
| `report` | no | latency report settings |

## `noc`

| Key | Default | Meaning |
|---|---|---|
| `topology` | | `mesh` or `crossbar` (a crossbar is a 1x1 mesh: every path is 0 hops) |
| `rows`, `cols` | | mesh size; nodes are `[x, y]`, x = column, y = row |
| `routing` | `xy` | `xy` (dimension ordered) |
| `timing` | | `ni_cycles`, `router_cycles`, `link_cycles`. One way over `h` hops costs `2*ni + (h+1)*router + h*link`; request and response each pay it. |
| `model` | `behavioral` | `behavioral`: the TB's NoC component routes the traffic. `rtl`: tb_top instantiates `rtl_module` and the component is not built. |
| `rtl_module` | | DUT module name for `model: rtl` |

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

`<prefix>_dram_channel(a)` and `<prefix>_dram_local(a)` (the channel-local
address with the channel bits removed) are generated for each memory.

## `slaves[]`

| Key | Meaning |
|---|---|
| `name`, `kind` | `memory` (VIP memory responder), `apb_bridge`, `vip` (generic AXI slave VIP), `rtl` (an `rtl` block module), `periph` (the AXI port of an APB peripheral) |
| `periph`, `prefix` | `periph` only: the `ip` peripheral (by name) whose AXI4 subordinate pins serve this port, and their prefix (default `s_`). The APB subsystem exports the pins as `<periph>_axi_<sig>` and tb_top wires them to the NoC port; narrower IDs are zero-extended. Example: QSPI_XIP's XIP window. The scoreboard has no reference model for it (the media test checks the data), and the NoC model adds no `access_cycles` (the IP takes its own time); `access_cycles` is then only the zero-load latency bound |
| `base`, `size`, `node`, `access_cycles` | as above |
| `slot_size` | `apb_bridge` only: slot window (default 4 KB) |
| `peripherals` | `apb_bridge` only, see below |

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
| `pins_vip` | a pin-level device model on the IP's pins (`ip` peripherals only), see below |

#### `peripherals[].pins_vip`

Puts a behavioural device (an SD card, a flash, a sensor, a PHY) on an IP's
pins inside the APB subsystem, e.g. open-vip-portfolio's `sdc_model` on SD's
`sd_clk`/`cmd`/`dat`:

```yaml
- {name: sd, ip: SD, pins_vip: {model: sdc_model, vip: SD_Card-UVM-VIP, inout: [cmd, dat]}}
```

| Key | Default | Meaning |
|---|---|---|
| `model` | | device model module name |
| `vip` | | open-vip-portfolio VIP: socgen cuts `module <model>` out of `vips/<vip>/tb/top_tb.sv` (or `vips/<vip>.zip`) into `out/rtl/vip/<model>.sv`; root from `--vip-root` / `OPEN_VIP_ROOT`, default `../open-vip-portfolio` |
| `files` | | instead of `vip`: SV files that define the model (repo-relative or absolute) |
| `params` | | model parameter overrides |
| `inout` | `[]` | the IP's inout pins the model shares (see below): `pin`, a slice `pin[n]` / `pin[msb:lsb]`, or `{pin: "dat[0]", port: dat0}` when the model's port prefix differs (eMMC `emd_model` on bit 0 of eMMC's `dat[7:0]`); `out` / `oe` name the drive and enable outputs when they are not `<port>_s` / `<port>_s_oe` (`{pin: io, out: fl_io, oe: fl_oe}` for `snor_model`); bits outside the slice keep the pull-up |
| `map` | | model port -> IP pin name or SV expression. Model inputs default to the IP pin of the same name; outputs mapped to an IP input pin drive it (not with `pins` on that pin) |
| `clock`, `reset` | `clk`, `rst_n` | model ports tied to the subsystem clock and active-low reset |

An unconnected model input is an error; an unmapped model output is left on a
wire `<name>_vip_<port>`. For each `inout` pin `p` the model's ports are found
by name. With `p_s`/`p_s_oe` outputs the model drives `p` bit by bit when
`p_s_oe` is high; `p_m` gets the resolved wire and `p_m_oe` gets `'1`, so the
model reads the bus as the wire actually is. With an open-drain `p_s_lo` output
the model pulls `p` low, and `p_m_lo` gets `~p`. Otherwise `p` keeps its pull-up.

## `register_blocks.<name>`

`desc`, and `regs[]`: `name`, `offset`, `access` (`RO`, `RW`, `W1C`, `WO`),
`reset`, `volatile`, `desc`, `fields[]` (`name`, `bits` "msb:lsb" or "n",
`access`, `reset`). Without `fields`, the register is one 32-bit field.

## `regress`

`ral_master` (master whose sequencer runs the RAL frontdoor, default the
first master), and `lists.<listname>[]` of `test`, `seeds`, `plusargs`.
Tests: `smoke`, `ral`, `path_latency`, `traffic`, `scenario`, `cov`. Each list
is written to `regress/<soc>_<listname>.txt` in the format `regress/regress.py`
reads. `cov` is the coverage-closure test: every master drives every burst
shape (FIXED, WRAP, narrow, unaligned, partial strobes, 64-beat) to one
target in turn, every RTL slave sees an address-bit walk and 256-beat bursts,
the APB port sees 256-beat and racing bursts, the RAL runs a bit-bash plus a
read of every register, and the NoC and slave VIPs raise READY only after
VALID so the handshake-wait covers fire. Run it with `make cov` (see the
README).

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
| `tb/<soc>_env_pkg.sv` | env: master agents, slave agents, behavioural NoC, scoreboard, per-path latency monitor |
| `tb/<soc>_test_pkg.sv`, `tb/<soc>_tb_top.sv` | tests and top |
| `sim/files.f`, `socgen.mk` | file list; `make build TB=<soc>` works from the repo root |
| `regress/<soc>_<list>.txt` | regression lists |
| `doc/<soc>.md`, `doc/<soc>_memmap.h`, `doc/<soc>_paths.csv` | address map, mesh placement, ideal latency per path, C header |
| `doc/<soc>_cov_waivers.txt` | coverage points that the SoC cannot reach by construction (constant APB-window address bits, unused ID bits, OKAY/SLVERR-only bridge responses, register bits a field map never drives, IP pins left to the IP's own bench), one regex per line with its reason; `scripts/cov/run_cov.sh` reads it |

## Path latency report

Every simulation prints one `PATHLAT` line per master-target-direction with
traffic (count, min, avg, max, the percentiles, ideal, and the master's
target if any), plus a table in the UVM report. `tools/latency_report.py <log>`
turns them into `path_latency.csv`, `path_latency.md` and an SVG heatmap of
average read latency (masters x targets).
