#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""covmerge.py -- merge regression output directories into one cumulative report.

  python3 regress/covmerge.py regress_out_soc regress_out_subsys -o regress_cumulative
  python3 regress/covmerge.py nightly/*/regress_out -o trend

Every input is a regress.py --out directory. Suites with the same name in
several inputs (CI shards, repeated nights) are merged run by run; code
coverage, functional bins and latency histograms all add up. The output
directory gets the same index.html / summary.md / cumulative/ as a single
regression (per-suite pages link to logs only for suites of the first input).
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    for d in a.inputs:
        if not os.path.isdir(os.path.join(d, "suites")):
            sys.exit(f"{d}: not a regress.py output directory (no suites/)")
    os.makedirs(a.out, exist_ok=True)
    report.write_reports(a.inputs, a.out)
    print(f"merged {len(a.inputs)} directories -> {os.path.join(a.out, 'index.html')}")


if __name__ == "__main__":
    main()
