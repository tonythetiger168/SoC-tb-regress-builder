# Vendored IP

These files are copied unchanged from
[open-ip-portfolio](https://github.com/tonythetiger168/open-ip-portfolio)
(Apache-2.0) at commit `b1cfc02463bdce7246837c16893ed962e3fc2505` (branch
`claude/project-thread-jb4irm`, open-ip-portfolio PR #33, which adds the
phone subsystem IPs; re-sync from main once it merges):

| File | Role in the SoC |
|---|---|
| `AXI4_top.sv` | on-chip SRAM, AXI4 slave S0 (256 x 32-bit) |
| `GPIO_top.sv`, `GPIO_apb.sv` | APB slot 0 |
| `UART_top.sv`, `UART_apb.sv` | APB slot 1 (TX looped back to RX in the testbench) |
| `I2C_*`, `SPI_*`, `PWM_*`, `TRNG_*` | phone SoC APB slots 3..6 |
| `soc_ss_axi_engine.sv` | AXI4 manager engine shared by the subsystem IPs below |
| `CPU_Cluster_*`, `GPU_*`, `NPU_*`, `ISP_*`, `Display_Controller_*`, `Video_Codec_*`, `Modem_*`, `DMA_*`, `Audio_DSP_*`, `Sensor_Hub_*`, `Interrupt_Controller_*`, `Timer_WDT_*` | phone SoC subsystem IPs (`rtl/phone/phone_ss_ips.sv`, real-IP build): AXI4 manager on a NoC master port, APB4 registers in the 0x1001_0000 segment |

Re-sync with `scripts/sync_ip.sh <path to open-ip-portfolio>`; it also regenerates
`tb/phone/phone_ss_ral.svh` (RAL blocks) from the IPs' `docs/ip/<P>.md` register tables.

Known limitations of `AXI4_top` that the scoreboard models (not bugs of the
testbench): ID must be 0 (the interconnect presents ID 0 and restores the
master ID), WRAP bursts answer SLVERR, AxLEN > 15 answers DECERR, and every
INCR beat advances the address by 4 bytes whatever AxSIZE is, so the tests
drive word-sized bursts to the SRAM only.
