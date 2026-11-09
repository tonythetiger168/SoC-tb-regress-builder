#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""regress.py -- build the testbenches once, run a test list over seeds in
parallel, and report.

  python3 regress/regress.py [--list regress/testlist.txt] [--sim verilator]
                             [--jobs N] [--seeds N] [--filter REGEX] [--no-build]
                             [--out regress_out] [--timeout SEC]

Test list lines: ``<tb> <test> <seeds> [plusargs...]`` (``#`` comments).
A run PASSES when the simulator exits 0, the log has ``UVM_ERROR : 0`` and
``UVM_FATAL : 0``, and the scoreboard printed ``SB_PASS checks=<n>`` with n > 0.
Outputs in --out: one log per run (<tb>/<test>__s<seed>.log), summary.csv,
summary.md and junit.xml. Exit status 1 if any run fails or a build fails.
"""
import argparse, concurrent.futures as cf, csv, os, re, subprocess, sys, time
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_list(path, seeds_override, filt):
    runs = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 3:
                sys.exit(f"{path}:{n}: expected '<tb> <test> <seeds> [plusargs]'")
            tb, test, nseeds, plus = parts[0], parts[1], int(parts[2]), parts[3:]
            if filt and not re.search(filt, test):
                continue
            for s in range(1, (seeds_override or nseeds) + 1):
                runs.append(dict(tb=tb, test=test, seed=s, plus=plus))
    return runs


def build(tb, sim, jobs):
    t0 = time.time()
    p = subprocess.run(["make", "-s", "build", f"TB={tb}", f"SIM={sim}", f"JOBS={jobs}"],
                       cwd=ROOT, capture_output=True, text=True)
    print(f"build {tb:4s} {'ok' if p.returncode == 0 else 'FAILED'} ({time.time() - t0:.0f}s)", flush=True)
    if p.returncode:
        print(p.stdout[-3000:], p.stderr[-3000:])
    return p.returncode == 0


def classify(rc, log):
    errs = re.search(r"^UVM_ERROR\s*:\s*(\d+)", log, re.M)
    fats = re.search(r"^UVM_FATAL\s*:\s*(\d+)", log, re.M)
    sb = re.search(r"^SB_PASS checks=(\d+)", log, re.M)
    checks = int(sb.group(1)) if sb else 0
    first = next((l for l in log.splitlines() if l.startswith(("UVM_ERROR ", "UVM_FATAL "))), "")
    if rc != 0 and not first:
        first = f"simulator exit {rc}"
    if errs is None or fats is None:
        return "FAIL", checks, first or "no UVM report summary (crash or timeout?)"
    if int(errs.group(1)) or int(fats.group(1)):
        return "FAIL", checks, first
    if rc != 0:
        return "FAIL", checks, first
    if checks == 0:
        return "FAIL", 0, "no SB_PASS line"
    return "PASS", checks, ""


def run_one(r, sim, out, timeout):
    logdir = os.path.join(out, r["tb"])
    os.makedirs(logdir, exist_ok=True)
    tag = r["test"] + ("__" + "_".join(p.lstrip("+").replace("=", "") for p in r["plus"]) if r["plus"] else "")
    logf = os.path.join(logdir, f"{tag}__s{r['seed']}.log")
    cmd = ["make", "-s", "run", f"TB={r['tb']}", f"SIM={sim}", f"TEST={r['test']}",
           f"SEED={r['seed']}", "PLUSARGS=" + " ".join(r["plus"])]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        rc, log = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        rc, log = 124, (e.stdout or b"").decode(errors="replace") + "\nTIMEOUT\n"
    with open(logf, "w") as f:
        f.write(log)
    status, checks, detail = classify(rc, log)
    return dict(r, tag=tag, status=status, checks=checks, detail=detail[:300],
                secs=time.time() - t0, log=os.path.relpath(logf, ROOT))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", default=os.path.join(ROOT, "regress", "testlist.txt"))
    ap.add_argument("--sim", default=os.environ.get("SIM", "verilator"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    ap.add_argument("--seeds", type=int, default=0, help="override the seed count of every line")
    ap.add_argument("--filter", default="", help="only tests whose name matches this regex")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--out", default=os.path.join(ROOT, "regress_out"))
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()

    runs = parse_list(a.list, a.seeds, a.filter)
    if not runs:
        sys.exit("no runs selected")
    tbs = sorted({r["tb"] for r in runs})
    if not a.no_build:
        if not all(build(tb, a.sim, a.jobs) for tb in tbs):
            sys.exit(1)

    t0 = time.time()
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(run_one, r, a.sim, a.out, a.timeout) for r in runs]
        for fu in cf.as_completed(futs):
            res = fu.result()
            results.append(res)
            print(f"{res['status']:4s} {res['tb']}/{res['tag']} seed={res['seed']} checks={res['checks']} "
                  f"({res['secs']:.1f}s) {res['detail']}", flush=True)
    results.sort(key=lambda x: (x["tb"], x["tag"], x["seed"]))
    wall = time.time() - t0
    npass = sum(r["status"] == "PASS" for r in results)

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["tb", "test", "plusargs", "seed", "status", "checks", "seconds", "detail", "log"])
        for r in results:
            w.writerow([r["tb"], r["test"], " ".join(r["plus"]), r["seed"], r["status"], r["checks"],
                        f"{r['secs']:.1f}", r["detail"], r["log"]])
    # per-test roll-up
    agg = {}
    for r in results:
        k = (r["tb"], r["tag"])
        g = agg.setdefault(k, dict(n=0, p=0, checks=0, fails=[]))
        g["n"] += 1; g["p"] += r["status"] == "PASS"; g["checks"] += r["checks"]
        if r["status"] != "PASS":
            g["fails"].append(f"s{r['seed']}")
    with open(os.path.join(a.out, "summary.md"), "w") as f:
        f.write(f"# Regression summary\n\n{npass}/{len(results)} runs passed "
                f"(simulator `{a.sim}`, list `{os.path.relpath(a.list, ROOT)}`, {wall:.0f}s wall).\n\n")
        f.write("| TB | Test | Seeds passed | Scoreboard checks | Failing seeds |\n|---|---|---|---|---|\n")
        for (tb, tag), g in sorted(agg.items()):
            f.write(f"| {tb} | {tag} | {g['p']}/{g['n']} | {g['checks']} | {' '.join(g['fails']) or '-'} |\n")
    with open(os.path.join(a.out, "junit.xml"), "w") as f:
        f.write(f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="soc-regression" '
                f'tests="{len(results)}" failures="{len(results) - npass}" time="{wall:.1f}">\n')
        for r in results:
            f.write(f'  <testcase classname="{r["tb"]}.{escape(r["tag"])}" name="seed{r["seed"]}" '
                    f'time="{r["secs"]:.1f}">')
            if r["status"] != "PASS":
                f.write(f'<failure message="{escape(r["detail"], {chr(34): "&quot;"})}">{escape(r["log"])}</failure>')
            f.write("</testcase>\n")
        f.write("</testsuite>\n")
    print(f"\n{npass}/{len(results)} passed in {wall:.0f}s -- {os.path.relpath(a.out, ROOT)}/summary.md")
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
