# tv8k_soc: a common 8K HDTV SoC testbench

Second instance of the common SoC spec (`socgen/specs/tv8k_soc.yaml`), after
the phone SoC. Every block is a generic model: no vendor internals.

## Block diagram

```
        y=0   DRAM0      DRAM1      DRAM2      DRAM3        (LPDDR5 ports, top die edge)
              [0,0]------[1,0]------[2,0]------[3,0]
                |          |          |          |
        y=1   TSD,ADSP   CPU,DMA    GPU,SEC    DISP,NETIO
              [0,1]------[1,1]------[2,1]------[3,1]
                |        boot_sram    |          |
        y=2   HDMIRX*    NPU*       VDEC*      PQ*          (* = behind an IOMMU)
              [0,2]------[1,2]------[2,2]------[3,2]
              APB bridge   |          |          |
                |          |          |          |
        y=3   DRAM4      DRAM5      DRAM6      DRAM7        (LPDDR5 ports, bottom die edge)
              [0,3]------[1,3]------[2,3]------[3,3]
```

4x4 mesh NoC, XY routing. DRAM 0x8000_0000-0xFFFF_FFFF is interleaved over
the 8 ports in 4 KB granules with an XOR hash. Boot SRAM at 0x0000_0000; APB
peripherals at 0x1000_0000 in 4 KB slots.

## Masters

| Master | Block | QoS | IOMMU | Typical 8K60 traffic |
|---|---|---|---|---|
| cpu | CPU cluster | nrt, prio 10 | | cache-line reads/writes, CSR access |
| gpu | GPU (UI/OSD/games) | nrt | | tile reads/writes |
| npu | AI-PQ NPU (scene detect, super-resolution) | nrt | yes | long weight/feature reads |
| vdec | 8K HEVC/VVC/AV1 decoder | nrt, prio 8 | yes | 2D reference-block reads, reconstructed-frame writes |
| pq | PQ engine: MEMC, HDR tone map, scaler | rt | yes | 2 frames in, 1 out |
| disp | display planes + TCON feed | rt, prio 15 | yes | 8K60 scanout, long linear reads |
| hdmirx | HDMI 2.1 RX capture DMA | rt | yes | 4K120 / 8K60 linear writes |
| tsd | TS demux + descrambler | rt | | 188-byte packet writes, section reads |
| adsp | audio DSP | rt | | small periodic reads/writes |
| dma | system DMA | be | | memcpy |
| sec | security / DRM engine | nrt | | key ladder, content decrypt |
| netio | USB / Ethernet / Wi-Fi / eMMC DMA | be | | packet bursts |

## APB peripherals (RAL from the open-ip register maps)

GPIO, UART, APB slave VIP slot, I2C (DDC/EDID, tuner), SPI (boot NOR), PWM
(backlight), TRNG, HDMI_2_1, HDCP_2_3, I2S_Audio, Crypto, Ethernet, USB2_0,
eMMC, and 5 IOMMU register blocks (slots 14-18).

## Use cases (real-world GB/s, read / write)

| Use case | Traffic |
|---|---|
| 8K60 playback | TSD 0.02/0.02, SEC 0.05/0.05, VDEC 4.0/3.0, PQ 6.0/3.0, DISP 8.0/0, GPU 0.5/0.3, CPU 0.6/0.3, NPU 0.8/0.2, ADSP 0.03/0.03 |
| HDMI 2.1 gaming (4K120 VRR, ALLM) | HDMIRX 0/4.0, PQ 4.0/4.0 (MEMC off), DISP 8.0/0, CPU 0.4/0.2, GPU 0.2/0.1 |
| AI upscale 4K -> 8K | VDEC 1.5/1.0, NPU 5.0/4.0, PQ 4.0/2.0, DISP 8.0/0, CPU 0.5/0.2 |
| Smart-TV UI over 4K video | CPU 2.0/1.0, GPU 3.0/2.0, VDEC 1.0/0.8, DISP 8.0/0, NETIO 0.1/0.1, DMA 0.5/0.5 |
| Stress | every master above its use-case peak |

The TB's ports are 32 bits at 1 GHz, so the spec scales these by 0.25.

## IP / VIP gaps for a TV SoC

Already in the portfolios: HDMI 2.1 (TX slice), HDCP 2.3, I2S, Ethernet,
USB 2.0, eMMC, SPI/I2C/UART/GPIO/PWM, TRNG, crypto, root of trust (IPs and
VIPs). The phone SoC work adds CPU, GPU, NPU, video codec, display, audio
DSP, DMA, IOMMU, interrupt controller and timers.

Missing, requested from the IP / VIP portfolio threads:

| Block | IP | VIP |
|---|---|---|
| PQ / MEMC / HDR / scaler engine | missing | reference model |
| HDMI 2.1 RX with capture DMA | missing (TX only) | HDMI source role |
| TS demux + descrambler | missing | MPEG-TS / TSI source |
| TCON + panel link (V-by-One HS / LVDS) | missing | panel-link sink |
| CEC | missing | missing |
| IR remote receiver | missing | missing |
| S/PDIF + eARC audio out | missing | missing |
| Memory firewall (DRM secure video path) | missing | n/a |

Until they land, those masters are AXI master VIP traffic models.

## The NoC bench (built now)

The TV SoC interconnect is a 4x4 mesh of xuanji-core `orca_noc_router`s
(5 ports, XY routing, 4 VCs) with AXI4 network interfaces
(`rtl/tv8k/`). Requests use VC0 and responses VC1. Every master NI reserves
its response slots before it issues, and every slave NI can queue every chunk
all masters can have in flight, so both ends always eject and the mesh cannot
deadlock. xuanji-core is private: `scripts/fetch_private_ip.sh` fetches a
pinned commit into `ext/` (gitignored, never committed). Without it the build
uses `tv8k_router_open` (same ports and routing, no VCs).

```sh
scripts/fetch_private_ip.sh                    # optional: xuanji router, c1p codec, PQ pipeline
make build TB=tv8k_noc                         # xuanji router if fetched, else the open router
make run TB=tv8k_noc TEST=tv8k_noc_rand_test SEED=3
python3 tools/tv8k_latency_report.py build/.../tv8k_latency.csv -o tv8k_latency.html \
        --spec socgen/specs/tv8k_soc.yaml
python3 regress/regress.py --suite 'tv8k_*'    # suites tv8k_noc, tv8k_noc_perf
```

Tests: `tv8k_noc_smoke_test` (every master to every slave port and a hole),
`tv8k_noc_rand_test` (random narrow / FIXED / WRAP bursts, partial strobes,
DECERR holes), `tv8k_noc_bw_test` (long bursts from all masters),
`tv8k_noc_hotspot_test` (all masters on DRAM channel 0 plus APB).

Every run prints a `PATHLAT` table (n, min, avg, p50/p90/p95/p99, max, bytes,
MB/s per master, target and direction, plus a DRAM aggregate per master) and
flags read paths whose p99 exceeds the master's `latency_target`. It writes
`tv8k_latency.csv` (every burst) and `tv8k_latency_summary.csv`, and sends every
sample to `lat_pkg` (`LAT` lines) for the regression runner's merged report.
`tools/tv8k_latency_report.py` turns one or more runs into an HTML page: avg
read, avg write and p99 read heatmaps (master x target), the DRAM read range
per master against its budget, bandwidth per master, and per-master CDFs.
The NoC bench has no QoS arbitration yet, so the hotspot test misses the
real-time budgets on purpose; that is reported as a warning.
