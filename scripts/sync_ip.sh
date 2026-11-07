#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copy the reused open-ip-portfolio RTL into rtl/ip and record its commit.
set -euo pipefail
SRC="${1:?usage: scripts/sync_ip.sh <open-ip-portfolio checkout>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in AXI4_top GPIO_top GPIO_apb UART_top UART_apb; do
  cp "$SRC/rtl/$f.sv" "$REPO/rtl/ip/$f.sv"
done
rev="$(git -C "$SRC" rev-parse HEAD)"
sed -i "s/at commit \`[0-9a-f]*\`/at commit \`$rev\`/" "$REPO/rtl/ip/README.md"
echo "synced rtl/ip from $SRC @ $rev"
