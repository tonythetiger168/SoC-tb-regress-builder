#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install the open-source flow: Verilator (built from source) and Accellera
# uvm-core (cloned into ./uvm-core). Same versions as open-vip-portfolio.
# Env: VERILATOR_VERSION (default v5.052), VERILATOR_PREFIX (default
#      /opt/verilator-<ver>), UVM_CORE_TAG (default 2020.3.1)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${VERILATOR_VERSION:-v5.052}"
PREFIX="${VERILATOR_PREFIX:-/opt/verilator-${VER#v}}"
UVM_TAG="${UVM_CORE_TAG:-2020.3.1}"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

if [ ! -x "$PREFIX/bin/verilator" ]; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq git autoconf flex bison help2man libfl-dev make g++ perl python3 ccache >/dev/null
  src="$(mktemp -d)"
  git clone -q --depth 1 --branch "$VER" https://github.com/verilator/verilator.git "$src"
  (cd "$src" && autoconf && ./configure --prefix="$PREFIX" >/dev/null \
     && make -j"$(nproc)" >/dev/null && $SUDO make install >/dev/null)
  rm -rf "$src"
fi
"$PREFIX/bin/verilator" --version

if [ ! -f "$REPO/uvm-core/src/uvm_pkg.sv" ]; then
  git clone -q --depth 1 --branch "$UVM_TAG" https://github.com/accellera-official/uvm-core.git "$REPO/uvm-core"
fi
echo "export PATH=$PREFIX/bin:\$PATH"
