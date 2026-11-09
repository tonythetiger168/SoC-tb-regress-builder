"""Elaborate a generated testbench with slang (pyslang) against UVM sources.

usage: python3 scripts/lint_tb.py <out>/tb <uvm-src-dir>
"""
import os
import sys

import pyslang

tb, uvm = (os.path.abspath(a) for a in sys.argv[1:3])
os.chdir(tb)
d = pyslang.driver.Driver()
d.addStandardArgs()
args = f"slang --top tb_top --timescale 1ns/1ps -I{uvm} {uvm}/uvm_pkg.sv -f files.f"
if not d.parseCommandLine(args, pyslang.driver.CommandLineOptions()):
    sys.exit(2)
if not (d.processOptions() and d.parseAllSources()):
    sys.exit(2)
comp = d.createCompilation()
d.reportCompilation(comp, False)
errors = [x for x in comp.getAllDiagnostics() if x.isError()]
print(f"{tb}: {len(errors)} errors")
sys.exit(1 if errors else 0)
