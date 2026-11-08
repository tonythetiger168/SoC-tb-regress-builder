#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Prepare HEVC vectors for tv8k_vdec_hevc_test from the fetched c1p-codec
# (ext/c1p-codec, private; see scripts/fetch_private_ip.sh):
#   <out>/<name>.265      the stream (copied)
#   <out>/<name>.apb      firmware register script (c1p fw/host/c1p_hevc_fw_dump)
#   <out>/<name>.mlf.raw  reference final planes (c1p scripts/c1p_hevc_model.py)
#   <out>/<name>.args     the plusargs for the test
# usage: scripts/tv8k_vdec_prep.sh <out_dir> [stream names, default: base lft4k]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C1P=$ROOT/ext/c1p-codec/c1p
[ -d "$C1P" ] || { echo "ext/c1p-codec not fetched (scripts/fetch_private_ip.sh)"; exit 2; }
OUT=$(mkdir -p "$1" && cd "$1" && pwd); shift
NAMES=${*:-base lft4k}
make -s -C "$C1P/fw/hevc" host > /dev/null
for n in $NAMES; do
  s=$C1P/tb/hevc/vectors/$n.265
  [ -f "$s" ] || { echo "no vector $n"; exit 2; }
  cp "$s" "$OUT/$n.265"
  "$C1P/sim/fw/c1p_hevc_fw_dump" "$s" "$OUT/$n.apb" > /dev/null 2>&1
  python3 "$C1P/scripts/c1p_hevc_model.py" decode "$s" "$OUT/$n.m.yuv" --lf "$OUT/$n.mlf.yuv" \
          --lf-raw "$OUT/$n.mlf.raw" > /dev/null
  echo "+C1P_BS=$OUT/$n.265 +C1P_APB=$OUT/$n.apb +C1P_REF=$OUT/$n.mlf.raw" > "$OUT/$n.args"
  echo "$n: $(grep -c '^F' "$OUT/$n.apb") pictures -> $OUT/$n.args"
done
