#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# run_cov.sh -- coverage regression of a bench with Verilator, merged and scored
#   scripts/cov/run_cov.sh [tb] [testlist]      (defaults: soc regress/testlist.txt)
# Builds with line/branch, toggle, user (SVA cover) coverage and assertions,
# runs every "<tb> <test> <seeds> [plusargs]" line of the test list, merges the
# runs into build/cov/<tb>/merged.dat, writes an annotated source tree and
# scores the result with score_cov.py against scripts/cov/exclude/<tb>.txt and,
# for a socgen bench, the generated <out>/doc/<tb>_cov_waivers.txt.
# Scope of code coverage: COV_SCOPE (regex on source paths); default rtl/<tb>/,
# or socgen/out/<tb>/rtl/<tb>_* for a socgen bench (sim/<tb>.f absent).
# FLIST, TOP and UVM_HOME can be overridden the same way.
set -u
TB=${1:-soc}; LIST=${2:-regress/testlist.txt}
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
TOP=${TOP:-${TB}_tb_top}            # soc -> soc_tb_top
if [ -f "sim/$TB.f" ] || [ ! -f "socgen/out/$TB/sim/files.f" ]; then
  FLIST=${FLIST:-sim/$TB.f}; SCOPE=${COV_SCOPE:-^rtl/$TB/}
else                                # socgen bench
  FLIST=${FLIST:-socgen/out/$TB/sim/files.f}; SCOPE=${COV_SCOPE:-socgen/out/$TB/rtl/${TB}_}
fi
UVM_HOME=${UVM_HOME:-$ROOT/uvm-core/src}
D=build/cov/$TB
rm -rf "$D"; mkdir -p "$D"
[ -f "$UVM_HOME/uvm_pkg.sv" ] || make -s uvm
verilator --binary --timing -j "$(nproc)" -Wno-fatal -Wno-lint -Wno-style --timescale 1ns/1ps \
  --top-module "$TOP" -Mdir "$D/obj" --coverage-line --coverage-toggle --coverage-user --assert \
  +define+UVM_NO_DPI +incdir+"$UVM_HOME" "$UVM_HOME/uvm_pkg.sv" -f "$FLIST" > "$D/build.log" 2>&1 \
  || { grep -m10 '^%Error' "$D/build.log"; exit 1; }
fail=0
while read -r tb t n args; do
  [ "$tb" = "$TB" ] || continue
  for s in $(seq 1 "$n"); do
    log=$D/run_${t}_$s.log
    (cd "$D" && ./obj/V"$TOP" +UVM_TESTNAME="$t" +verilator+seed+"$s" $args > "$(basename "$log")" 2>&1
     mv coverage.dat "cov_${t}_$s.dat")
    if grep -qE 'UVM_(ERROR|FATAL) [^:]*@' "$log" || ! grep -q 'PASS' "$log"; then
      echo "FAIL $t seed $s ($log)"; fail=1
    else echo "pass $t seed $s"; fi
  done
done < <(grep -v '^#' "$LIST")
verilator_coverage --write "$D/merged.dat" "$D"/cov_*.dat > /dev/null && rm -f "$D"/cov_*.dat
verilator_coverage --annotate "$D/annotated" --annotate-min 1 "$D/merged.dat" > /dev/null
EXC=scripts/cov/exclude/$TB.txt
GEN=$(dirname "$FLIST")/../doc/${TB}_cov_waivers.txt      # socgen benches: generated waivers
python3 scripts/cov/score_cov.py "$D/merged.dat" --scope "$SCOPE" \
  $( [ -f "$EXC" ] && echo --exclude "$EXC" ) $( [ -f "$GEN" ] && echo --exclude-opt "$GEN" ) \
  --json "$D/score.json" || fail=1
exit $fail
