# Micron vendor memory models

Tony's rule (2026-11-09): the SoC testbenches use Micron's simulation models
for external memories. Micron licenses them per user, so this repository
never contains them. They are fetched at build time, and when they are
missing the bench falls back to the open models.

| Product | DRAM | Flash | Micron model | Fallback |
|---|---|---|---|---|
| Phone | LPDDR5X-8533 (MT62F) | UFS (not simulated) | LPDDR5X model, NDA / FAE | AXI slave VIP |
| 8K TV | DDR4-3200 x16, 4 devices (MT40A512M16) | eMMC 5.1 | DDR4 model, Micron login | `ddr4_dev_model` |
| IPCAM 4K | LPDDR4X (MT53E) | SPI-NOR MT25QL256 | LPDDR4X model, NDA / FAE; MT25Q model, login | AXI slave VIP; `snor_model` |
| IPCAM HD | DDR4-2666 x16, 1 device per port (MT40A512M16) | SPI-NOR MT25QL128 | DDR4 model, login | `ddr4_dev_model`; `snor_model` |

Micron has no public eMMC or UFS models, so the bench keeps `emd_model` for them.

## Where the files go

1. Download each model from the Simulation Models section of the part's page
   on micron.com. This needs a Micron login, and LPDDR4X / LPDDR5X also need an
   NDA, requested through a Micron FAE.
2. Commit the unpacked files to a **private** repository. The default is
   `tonythetiger168/micron-sim-models`; set `MICRON_REPO` to use another. Lay it out as:

   ```
   ddr4/      arch_package.sv proj_package.sv interface.sv StateTable*.sv MemoryArray.sv ddr4_model.sv ...
   mt25q/     N25Qxxx.v (or the MT25Q top) + its include/ directory
   lpddr4x/   (when available)
   lpddr5x/   (when available)
   ```

   Before you store the files there, check that Micron's license allows it.
3. `scripts/fetch_micron_models.sh` clones that repository into `ext/micron/`,
   which is git-ignored. It then writes `ext/micron/micron.f`, which holds the
   `+define+MICRON_DDR4` define, the Micron files in compile order, and
   `vip/micron/micron_ddr4_dev.sv`. The Makefile adds that file list to
   every build when it exists (`MICRON_F`).

## Status

- DDR4: `memories[].model: ddr4` works today with `ddr4_dev_model`. That model
  has the same pins as Micron's, and its JEDEC checks run on every command.
  `micron_ddr4_dev.sv` has not been run yet, because nobody has the files yet.
  Micron's model uses `#` delays, classes and interface `inout` wires, so it
  may need small changes to build under Verilator `--timing`.
- MT25Q, LPDDR4X, LPDDR5X: these are waiting for the model files and for a
  JEDEC LPDDR4X / LPDDR5X controller in open-ip-portfolio.
