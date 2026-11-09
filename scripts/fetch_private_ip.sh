#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fetch the private IP repos the 8K TV SoC (tv8k) uses into ./ext/ at pinned
# commits. Their RTL is never copied into this (public) repository.
# Needs read access to the repos: a GitHub login with access (gh auth / git
# credential helper / GITHUB_TOKEN). Repos that cannot be fetched are skipped;
# the tv8k build then uses the open fallbacks (TV8K_OPEN_ROUTER, AXI traffic
# VIPs instead of the IPs) -- see sim/tv8k.mk.
#   scripts/fetch_private_ip.sh            fetch / update all
#   EXT=<dir> scripts/fetch_private_ip.sh  other destination
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="${EXT:-$REPO/ext}"
mkdir -p "$EXT"
URL_BASE="${URL_BASE:-https://github.com/tonythetiger168}"
if [ -n "${GITHUB_TOKEN:-}" ]; then URL_BASE="https://x-access-token:${GITHUB_TOKEN}@github.com/tonythetiger168"; fi

# name  pinned commit                              used for
PINS="
xuanji-core    4140b7eda903eea17f0f2a429827b091cc0ca63f  NoC router (orca_noc_router), NPU subsystem, CPU core
c1p-codec      c24a6ec88b5409222a960bc202b8068fd9e06a2f  video decoder (c1p_dec_axi_top)
pq-pipeline-sv 508427e629b52f907a6ceae1a83da686ffa8bbcb  PQ / MEMC pipeline (pq_top)
"
ok=0; miss=0
while read -r name sha _; do
  [ -z "$name" ] && continue
  d="$EXT/$name"
  if [ ! -d "$d/.git" ]; then
    git init -q "$d" && git -C "$d" remote add origin "$URL_BASE/$name.git"
  fi
  if git -C "$d" fetch -q --depth 1 origin "$sha" 2>/dev/null && git -C "$d" checkout -q --detach FETCH_HEAD; then
    echo "[fetch] $name @ ${sha:0:10}"; ok=$((ok+1))
  else
    echo "[fetch] $name: no access, skipped (open fallback will be used)"; rm -rf "$d"; miss=$((miss+1))
  fi
done <<< "$PINS"
echo "[fetch] $ok fetched, $miss skipped -> $EXT"
