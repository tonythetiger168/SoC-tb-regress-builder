#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fetch the real IPs the IPCAM SoC uses from Tony's private repositories, at
# pinned commits, into ext/ (git-ignored). Their RTL is never committed here.
#   c1p-codec   : HEVC intra encoder (c1p_hve), JPEG encoder (c1p_jpe), c1p_axi_mst
#   xuanji-core : NPU subsystem (orca_npu_ss_apb)
# Needs GitHub access to those repos (gh auth, a credential helper or a token
# in the URL). Without it the script exits 1 and the IPCAM TB falls back to
# AXI VIP traffic models for VENC / JPEG / NPU (see sim/ipcam/README).
# Env: EXT_DIR (default ./ext), C1P_REV, XJ_REV, GH_BASE (default https://github.com/tonythetiger168)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="${EXT_DIR:-$REPO/ext}"
BASE="${GH_BASE:-https://github.com/tonythetiger168}"
C1P_REV="${C1P_REV:-c24a6ec88b5409222a960bc202b8068fd9e06a2f}"
XJ_REV="${XJ_REV:-4140b7eda903eea17f0f2a429827b091cc0ca63f}"
mkdir -p "$EXT"
ok=1
fetch() {   # name rev
  local d="$EXT/$1"
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$2" ]; then
    echo "[fetch_ext_ip] $1 @ ${2:0:12} already present"; return 0
  fi
  rm -rf "$d"; mkdir -p "$d"
  if git -C "$d" init -q && git -C "$d" remote add origin "$BASE/$1.git" \
     && git -C "$d" fetch -q --depth 1 origin "$2" && git -C "$d" checkout -q FETCH_HEAD; then
    echo "[fetch_ext_ip] $1 @ ${2:0:12}"
  else
    echo "[fetch_ext_ip] cannot fetch $1 (no access?): IPCAM uses VIP traffic models instead" >&2
    rm -rf "$d"; ok=0
  fi
}
fetch c1p-codec   "$C1P_REV"
fetch xuanji-core "$XJ_REV"
[ $ok = 1 ] || exit 1
# The generated IPCAM SoC benches point their RTL masters at ext/ipcam_ext.f:
# it exists only after a successful fetch, so without access socgen falls back
# to VIP traffic models (rtl.fallback: vip in the spec).
cp "$REPO/sim/ipcam/ext_ip.f" "$REPO/ext/ipcam_ext.f"
echo "[fetch_ext_ip] wrote ext/ipcam_ext.f"
