# Vendored IP

These files are copied unchanged from
[open-ip-portfolio](https://github.com/tonythetiger168/open-ip-portfolio)
(Apache-2.0) at commit `359f40a67051a7da5dba4d0bf57c01e67bdcf2fa`:

| File | Role in the SoC |
|---|---|
| `AXI4_top.sv` | on-chip SRAM, AXI4 slave S0 (256 x 32-bit) |
| `GPIO_top.sv`, `GPIO_apb.sv` | APB slot 0 |
| `UART_top.sv`, `UART_apb.sv` | APB slot 1 (TX looped back to RX in the testbench) |

Re-sync with `scripts/sync_ip.sh <path to open-ip-portfolio>`.

Known limitations of `AXI4_top` that the scoreboard models (not bugs of the
testbench): ID must be 0 (the interconnect presents ID 0 and restores the
master ID), WRAP bursts answer SLVERR, AxLEN > 15 answers DECERR, and every
INCR beat advances the address by 4 bytes whatever AxSIZE is, so the tests
drive word-sized bursts to the SRAM only.
