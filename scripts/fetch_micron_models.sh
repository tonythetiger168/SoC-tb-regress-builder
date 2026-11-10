#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fetch Micron's (license-restricted) memory models from a private repository
# into ext/micron/ and write ext/micron/micron.f for the Makefile.
# Nothing is committed: ext/ is git-ignored. Without access (or without the
# files) the bench keeps the open fallback models.
#   MICRON_REPO  default https://github.com/tonythetiger168/micron-sim-models.git
#   MICRON_REF   default main
#   MICRON_DIR   use an existing local directory instead of cloning
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$ROOT/ext/micron"
REPO="${MICRON_REPO:-https://github.com/tonythetiger168/micron-sim-models.git}"
REF="${MICRON_REF:-main}"
mkdir -p "$ROOT/ext"
if [ -n "${MICRON_DIR:-}" ]; then
  rm -rf "$DST"; ln -s "$(cd "$MICRON_DIR" && pwd)" "$DST"
elif [ -d "$DST/.git" ]; then
  git -C "$DST" fetch -q origin "$REF" && git -C "$DST" checkout -q FETCH_HEAD || echo "micron: fetch failed, keeping $DST"
elif ! git clone -q --depth 1 --branch "$REF" "$REPO" "$DST" 2>/dev/null; then
  echo "micron: cannot clone $REPO (no access?) -- using the open fallback models"
  rm -f "$DST/micron.f"
  exit 0
fi

F="$DST/micron.f"
: > "$F.tmp"
if [ -f "$DST/ddr4/ddr4_model.sv" ]; then
  D="$DST/ddr4"
  {
    echo "+define+MICRON_DDR4"
    echo "+incdir+$D"
    # package and interface first, then everything else, model last
    for f in arch_package.sv proj_package.sv interface.sv; do [ -f "$D/$f" ] && echo "$D/$f"; done
    for f in "$D"/*.sv; do
      case "$(basename "$f")" in arch_package.sv|proj_package.sv|interface.sv|ddr4_model.sv|*tb*.sv) ;; *) echo "$f";; esac
    done
    echo "$D/ddr4_model.sv"
    echo "$ROOT/vip/micron/micron_ddr4_dev.sv"
  } >> "$F.tmp"
  echo "micron: DDR4 model found ($D)"
else
  echo "micron: no ddr4/ddr4_model.sv -- DDR4 channels use ddr4_dev_model"
fi
for m in mt25q lpddr4x lpddr5x; do
  [ -d "$DST/$m" ] && echo "micron: $m present (not wired into the benches yet)"
done
if [ -s "$F.tmp" ]; then mv "$F.tmp" "$F"; else rm -f "$F.tmp" "$F"; fi
