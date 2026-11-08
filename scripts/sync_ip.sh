#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copy the reused open-ip-portfolio RTL into rtl/ip and record its commit.
set -euo pipefail
SRC="${1:?usage: scripts/sync_ip.sh <open-ip-portfolio checkout>}"
# phone SoC subsystem IPs (AXI4 manager + APB4 registers)
SS_IPS="CPU_Cluster GPU NPU ISP Display_Controller Video_Codec Modem DMA Audio_DSP Sensor_Hub Interrupt_Controller Timer_WDT"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in AXI4_top GPIO_top GPIO_apb UART_top UART_apb I2C_top I2C_apb SPI_top SPI_apb PWM_top PWM_apb TRNG_top TRNG_apb \
         soc_ss_axi_engine $(for p in $SS_IPS; do echo ${p}_top ${p}_apb; done); do
  cp "$SRC/rtl/$f.sv" "$REPO/rtl/ip/$f.sv"
done
rev="$(git -C "$SRC" rev-parse HEAD)"
sed -i "s/at commit \`[0-9a-f]*\`/at commit \`$rev\`/" "$REPO/rtl/ip/README.md"
python3 "$REPO/scripts/gen_phone_ss_ral.py" "$SRC" > "$REPO/tb/phone/phone_ss_ral.svh"
echo "synced rtl/ip from $SRC @ $rev"
