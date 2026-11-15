# IPCAM SoC: real IPs

The IP camera SoC (`socgen/specs/ipcam_soc.yaml`, 4K30, and `ipcam_hd_soc.yaml`, 1080p30) uses three real IPs as
AXI masters. They come from Tony's private repositories, so their RTL is **fetched at build time, never committed**:

```sh
bash scripts/fetch_ext_ip.sh        # clones c1p-codec and xuanji-core at pinned commits into ext/ (git-ignored)
make build TB=ipcam_ip              # unit bench for the three IPs (about 2.5 minutes)
python3 scripts/ipcam_ip_check.py   # 10 checks, summary in regress_out/ipcam_ip/summary.md
```

Without access to those repositories the fetch fails and the SoC falls back to AXI VIP traffic models for these
masters (`fallback: vip` in the spec).

| SoC master | IP (repo, pinned commit in `scripts/fetch_ext_ip.sh`) | Wrapper (`rtl/ipcam/`) | Bridge to the 32-bit fabric |
|---|---|---|---|
| `venc` | `c1p_hve` HEVC Main intra encoder + `c1p_hve_regs` + `c1p_axi_mst` (c1p-codec) | `ipcam_venc_c1p` | `ipcam_axi_dn64`: single-beat 64-bit bursts become 2-beat 32-bit bursts |
| `jpeg` | `c1p_jpe` baseline JPEG/MJPEG encoder + `c1p_jpe_regs` + `c1p_axi_mst` (c1p-codec) | `ipcam_jpeg_c1p` | `ipcam_axi_dn64` |
| `npu`  | `orca_npu_ss_apb` NPU subsystem: GEMM / VEC / DMA queue, L2 (xuanji-core) | `ipcam_npu_xj` | `ipcam_line2axi`: one 64-byte line becomes a 16-beat INCR burst; a write is granted on its B, so a DMA_ST completion means the data is in DRAM |

Each wrapper exposes a 4 KB APB slot (the IP's own register map) and an interrupt.

## Unit bench (`tb/ipcam_ip/`)

One APB requester programs the three IPs; each AXI port goes to an AXI4 slave VIP with random latency and
back-pressure, all backed by one memory model. `scripts/ipcam_ip_check.py` encodes three ffmpeg test frames
(64x48, 176x144, 96x64): JPEG and HEVC output must be byte-identical to the c1p Python reference models
(`c1p_jpe_model.py`, `c1p_hve_model.py`) and decode with ffmpeg, alone and with all three IPs running at once
on slower memory. The NPU test moves random lines DRAM -> L2 -> DRAM with DMA_LD / DMA_ST and checks the data
and the completions read through CPL_POP. Every AXI burst prints a `LAT <master> ddr <R|W> <cycles>` line.

## Why these IPs and not others

Searched: open-ip-portfolio, c1p-codec, xuanji-core, orca-ai-accelerators, openhelix-oh1, acme_soc,
jpeg-ls-codec, xuanji-ims, xianji-ipcam (and its 32-row IPCAM IP table).

* CPU: xuanji-core's ZEN++ tile talks NoC flits and needs firmware; BitStar S1 (acme_soc) has a custom bus;
  OH-1 is an AXI4-Lite slave. The IPCAM CPU stays an AXI VIP.
* ISP: xuanji-ims documents the ISP / CSI contract (IMS64) but its RTL has not started. VIP traffic.
* orca-ai-accelerators NPUs: AXI ports are stubs (no handshake). xuanji-core's NPU subsystem is used instead.
* JPEG-LS (jpeg-ls-codec, also in xianji-ipcam): pixel / byte streams with no DMA; needs a capture writer first.
* System DMA, Ethernet / SD / eMMC DMA, audio DMA, crypto DMA: no AXI-master RTL yet. VIP traffic.
