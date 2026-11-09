#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Prepare HEVC vectors for tv8k_vdec_hevc_test from the fetched c1p-codec
# (ext/c1p-codec, private; see scripts/fetch_private_ip.sh):
#   <out>/<name>.265      the stream (copied)
#   <out>/<name>.apb      firmware register script (c1p fw/host/c1p_hevc_fw_dump)
#   <out>/<name>.mlf.raw  reference final planes (c1p scripts/c1p_hevc_model.py)
#   <out>/<name>.args     the plusargs for the test
# usage: scripts/tv8k_vdec_prep.sh <out_dir> [stream names, default: base lft4k]
# Names are c1p vectors (c1p/tb/hevc/vectors/<name>.265), plus generated ones:
#   w8k10  7680x64 Main10 4:2:0 strip, CTB 64, deblocking + SAO, QP 30, WPP: an 8K-wide
#          picture row band (needs ffmpeg with libx265; skipped otherwise)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C1P=$ROOT/ext/c1p-codec/c1p
[ -d "$C1P" ] || { echo "ext/c1p-codec not fetched (scripts/fetch_private_ip.sh)"; exit 2; }
OUT=$(mkdir -p "$1" && cd "$1" && pwd); shift
NAMES=${*:-base lft4k}
make -s -C "$C1P/fw/hevc" host > /dev/null
gen() {   # name -> generated stream in $OUT, or return 1
  case $1 in
    w8k10)
      case "$(ffmpeg -hide_banner -encoders 2>/dev/null)" in *libx265*) ;; *) return 1 ;; esac
      ffmpeg -hide_banner -loglevel error -y -f lavfi \
        -i "testsrc2=size=7680x64:rate=60,noise=alls=10:allf=t" -frames 1 -pix_fmt yuv420p10le \
        -c:v libx265 -profile:v main10 \
        -x265-params "log-level=error:keyint=1:ctu=64:sao=1:deblock=0,0:qp=30:wpp=1:aq-mode=0:info=0" \
        -f hevc "$OUT/$1.src.265" ;;
    *) return 1 ;;
  esac
}
for n in $NAMES; do
  s=$C1P/tb/hevc/vectors/$n.265
  if [ ! -f "$s" ]; then
    if gen "$n"; then s=$OUT/$n.src.265; else echo "no vector $n (skipped)"; continue; fi
  fi
  cp "$s" "$OUT/$n.265"
  "$C1P/sim/fw/c1p_hevc_fw_dump" "$s" "$OUT/$n.apb" > /dev/null 2>&1
  python3 "$C1P/scripts/c1p_hevc_model.py" decode "$s" "$OUT/$n.m.yuv" --lf "$OUT/$n.mlf.yuv" \
          --lf-raw "$OUT/$n.mlf.raw" > /dev/null
  echo "+C1P_VEC=$n" > "$OUT/$n.args"
  echo "$n: $(grep -c '^F' "$OUT/$n.apb") pictures -> $OUT/$n.args"
done
