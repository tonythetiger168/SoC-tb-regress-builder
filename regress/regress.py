#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""regress.py -- SoC and subsystem regression suites with merged coverage.

  python3 regress/regress.py                         # every suite in regress/suites/
  python3 regress/regress.py --suite amba_soc --suite 'amba_*'
  python3 regress/regress.py --level subsystem --soc amba --profile nightly
  python3 regress/regress.py --list regress/testlist.txt   # legacy: one test list
  python3 regress/regress.py --list-suites

Suites are YAML files in regress/suites/ (see regress/suites/README.md):

  name: amba_sram            level: soc | subsystem | vip
  soc: amba                  subsystem: sram
  filelist: sim/soc.f        top: soc_tb_top
  list: regress/lists/amba_sram.txt      # or {default: ..., nightly: ...}

Each distinct (filelist, top, defines) is built once, with Verilator line,
toggle, branch and SVA coverage restricted to the design RTL (``cov_include``,
default ``*rtl/*``). Every <test> x <seed> runs in parallel. Each run writes
its own coverage.dat, its FCOV lines (functional coverage) and its LAT
samples (per-path latency). They are merged per suite and then across all
suites into a cumulative report:

  <out>/index.html         cumulative dashboard: suites, rollups by level and
                           SoC, code + functional coverage, latency charts
  <out>/summary.md         the same tables in Markdown (CI step summary)
  <out>/summary.csv        one row per run;  <out>/junit.xml
  <out>/cumulative/        merged coverage.dat, fcov.json, latency.json
  <out>/suites/<suite>/    logs/, cov/ per-run .dat, suite.json, coverage.dat,
                           fcov.json, latency.json, index.html

regress/covmerge.py merges several output directories (e.g. CI shards or
yesterday's nightly) into one cumulative report.

A run PASSES when the simulator exits 0, the log has ``UVM_ERROR : 0`` and
``UVM_FATAL : 0``, and it printed a pass marker (``SB_PASS checks=<n>`` with
n > 0, or ``RAL_PASS``; see ``pass_markers``). Exit status 1 if any run or
build fails.
"""
import argparse, concurrent.futures as cf, csv, fnmatch, glob, hashlib, json, os, re, shutil
import subprocess, sys, time, zipfile
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import covlib  # noqa: E402
import report  # noqa: E402

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

LEGACY_TB = {"soc": ("sim/soc.f", "soc_tb_top"), "vip": ("sim/vip.f", "vip_tb_top")}
DEFAULT_PASS = ["SB_PASS", "RAL_PASS"]


# --------------------------------------------------------------------------- suites
def load_yaml(path):
    with open(path) as f:
        text = f.read()
    if yaml is not None:
        return yaml.safe_load(text) or {}
    return json.loads(text)          # suites may also be written as JSON


def norm_suite(d, path):
    s = dict(d)
    s.setdefault("name", os.path.splitext(os.path.basename(path or "suite"))[0])
    s.setdefault("level", "soc")
    s.setdefault("soc", s["name"].split("_")[0])
    s.setdefault("subsystem", "")
    s.setdefault("description", "")
    s.setdefault("plusargs", [])
    s.setdefault("defines", [])
    s.setdefault("incdirs", [])
    s.setdefault("cov_include", ["*rtl/*"])
    s.setdefault("pass_markers", DEFAULT_PASS)
    s.setdefault("filter", "")
    s.setdefault("uvm", True)
    s.setdefault("timeout", 0)
    s.setdefault("enabled", True)
    s["root"] = os.path.normpath(os.path.join(ROOT, s.get("root", ".")))
    s["_path"] = os.path.relpath(path, ROOT) if path else "(command line)"
    for k in ("filelist", "top", "list"):
        if k not in s and not (k == "list" and "tests" in s):
            sys.exit(f"{path}: suite '{s['name']}' needs '{k}'")
    if s["level"] not in ("soc", "subsystem", "vip"):
        sys.exit(f"{path}: level must be soc, subsystem or vip")
    return s


def discover(suite_dir):
    out = []
    for p in sorted(glob.glob(os.path.join(suite_dir, "*.yaml")) + glob.glob(os.path.join(suite_dir, "*.yml"))
                    + glob.glob(os.path.join(suite_dir, "*.json"))):
        d = load_yaml(p)
        for entry in (d if isinstance(d, list) else d.get("suites", [d])):
            out.append(norm_suite(entry, p))
    names = [s["name"] for s in out]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        sys.exit(f"duplicate suite names: {', '.join(sorted(dup))}")
    return out


def resolve_requirements(s, build_root):
    """Unpack a VIP zip and apply the fallback when a requirement is missing.
    Returns (suite, note) where note says what was skipped or substituted."""
    note = ""
    if s.get("zip"):
        z = os.path.join(ROOT, s["zip"])
        if not os.path.exists(z):
            return None, f"zip {s['zip']} not found"
        dest = os.path.join(build_root, "ext", s["name"])
        stamp = os.path.join(dest, ".zip_mtime")
        mt = str(os.path.getmtime(z))
        if not (os.path.exists(stamp) and open(stamp).read() == mt):
            shutil.rmtree(dest, ignore_errors=True)
            with zipfile.ZipFile(z) as zf:
                zf.extractall(dest)
            open(stamp, "w").write(mt)
        # a zip usually holds one top directory; root the suite there
        entries = [e for e in os.listdir(dest) if not e.startswith(".")]
        inner = os.path.join(dest, entries[0]) if len(entries) == 1 and os.path.isdir(os.path.join(dest, entries[0])) else dest
        s = dict(s, root=os.path.normpath(os.path.join(inner, s.get("zip_root", "."))))
    missing = [r for r in s.get("requires", []) if not os.path.exists(os.path.join(ROOT, r))]
    if missing:
        fb = s.get("fallback")
        if not fb:
            return None, "missing " + ", ".join(missing)
        s = dict(s)
        for k, v in fb.items():
            s[k] = (s.get(k, []) + v) if k in ("defines", "plusargs") else v
        note = "fallback (missing " + ", ".join(missing) + ")"
    if not os.path.exists(os.path.join(s["root"], s["filelist"])):
        return None, f"filelist {s['filelist']} not found"
    return s, note


def list_path(s, profile):
    """Test list for a profile; relative paths are looked up in the repo, then
    in the suite root (so a packaged bench can use its own sim/testlist.txt)."""
    lst = s.get("list")
    if isinstance(lst, dict):
        lst = lst.get(profile) or lst.get("default")
    if not lst:
        return None
    for base in (ROOT, s["root"]):
        if os.path.exists(os.path.join(base, lst)):
            return os.path.join(base, lst)
    sys.exit(f"{s['_path']}: test list {lst} not found")


def parse_list(path, seeds_override, filt):
    """'<tb> <test> <seeds> [plusargs]' (tb ignored in suites) or '<test> <seeds> [plusargs]'."""
    runs = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                tb, test, nseeds, plus = None, parts[0], int(parts[1]), parts[2:]
            elif len(parts) >= 3 and parts[2].isdigit():
                tb, test, nseeds, plus = parts[0], parts[1], int(parts[2]), parts[3:]
            else:
                sys.exit(f"{path}:{n}: expected '[<tb>] <test> <seeds> [plusargs]'")
            if filt and not re.search(filt, test):
                continue
            for sd in range(1, (seeds_override or nseeds) + 1):
                runs.append(dict(tb=tb, test=test, seed=sd, plus=plus))
    return runs


def suite_runs(s, profile, seeds_override, filt):
    if "tests" in s:
        runs = []
        for t in s["tests"]:
            if (filt and not re.search(filt, t["test"])) or (s["filter"] and not re.search(s["filter"], t["test"])):
                continue
            for sd in range(1, (seeds_override or int(t.get("seeds", 1))) + 1):
                runs.append(dict(tb=None, test=t["test"], seed=sd, plus=list(t.get("plusargs", []))))
        return runs
    runs = parse_list(list_path(s, profile), seeds_override, filt)
    if s["filter"]:
        runs = [r for r in runs if re.search(s["filter"], r["test"])]
    return runs


# --------------------------------------------------------------------------- build
def mem_gb():
    """Available memory in GB (cgroup limit if tighter), or a large number if unknown."""
    avail = 1e9
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) / 1048576
    except OSError:
        pass
    for p in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
        try:
            v = open(p).read().strip()
            if v.isdigit():
                avail = min(avail, int(v) / 1073741824)
        except OSError:
            pass
    return avail


def build_key(s, sim, cov):
    h = hashlib.sha1(json.dumps([sim, s["root"], s["filelist"], s["top"], s["defines"], s["incdirs"],
                                 s["cov_include"] if cov else None, s["uvm"]]).encode()).hexdigest()[:8]
    return f"{s['top']}-{h}"


def vlt_text(cov_include):
    # Verilator applies coverage_off/on per file. Turn coverage off for every
    # file in the build that does not match cov_include. (A blanket
    # 'coverage_off -file "*"' followed by coverage_on does not re-enable it.)
    return "`verilator_config\n" + "".join(f'coverage_off -file "{g}"\n' for g in
                                           ("*uvm-core/*", "*/verilator/include/*", "*vip/*", "*tb/*", "*tb_top*"))


def build(s, sim, jobs, cov, build_root, uvm_home):
    key = build_key(s, sim, cov)
    bdir = os.path.join(build_root, sim, key)
    os.makedirs(bdir, exist_ok=True)
    t0 = time.time()
    if sim != "verilator":
        # commercial simulators: reuse the Makefile entries (legacy benches only)
        tb = next((k for k, v in LEGACY_TB.items() if v == (s["filelist"], s["top"])), None)
        if tb is None:
            print(f"build {key}: SIM={sim} is only wired for the legacy soc/vip benches", flush=True)
            return None
        p = subprocess.run(["make", "-s", "build", f"TB={tb}", f"SIM={sim}", f"JOBS={jobs}"],
                           cwd=ROOT, capture_output=True, text=True)
        ok = p.returncode == 0
        exe = None
    else:
        vlt = os.path.join(bdir, "cov.vlt")
        with open(vlt, "w") as f:
            f.write(vlt_text(s["cov_include"]))
        cmd = ["verilator", "--binary", "--timing", "-j", str(jobs), "-Wno-fatal", "-Wno-lint", "-Wno-style",
               "--timescale", "1ns/1ps", "--top-module", s["top"], "-Mdir", os.path.join(bdir, "obj")]
        if cov:
            cmd += ["--coverage-line", "--coverage-toggle", "--coverage-user", vlt]
        cmd += [f"+define+{d}" for d in s["defines"]] + [f"+incdir+{i}" for i in s["incdirs"]]
        if s["uvm"]:
            cmd += ["+define+UVM_NO_DPI", f"+incdir+{uvm_home}", os.path.join(uvm_home, "uvm_pkg.sv")]
        cmd += ["-f", s["filelist"]]
        with open(os.path.join(bdir, "build.cmd"), "w") as f:
            f.write(" ".join(cmd) + "\n")
        p = subprocess.run(cmd, cwd=s["root"], capture_output=True, text=True)
        with open(os.path.join(bdir, "build.log"), "w") as f:
            f.write(p.stdout + p.stderr)
        ok = p.returncode == 0
        exe = os.path.join(bdir, "obj", "V" + s["top"])
    print(f"build {key:28s} {'ok' if ok else 'FAILED'} ({time.time() - t0:.0f}s)", flush=True)
    if not ok:
        errs = [l for l in (p.stdout + p.stderr).splitlines() if l.startswith("%Error")]
        print("\n".join(errs[:20]) or (p.stdout + p.stderr)[-3000:])
        return None
    return dict(key=key, dir=bdir, exe=exe)


# --------------------------------------------------------------------------- run
def classify(rc, log, markers):
    errs = re.search(r"^UVM_ERROR\s*:\s*(\d+)", log, re.M)
    fats = re.search(r"^UVM_FATAL\s*:\s*(\d+)", log, re.M)
    mk = re.search(r"^(?:%s)\b(?:\s+checks=(\d+))?" % "|".join(map(re.escape, markers)), log, re.M)
    checks = int(mk.group(1)) if mk and mk.group(1) else (1 if mk else 0)
    first = next((l for l in log.splitlines() if l.startswith(("UVM_ERROR ", "UVM_FATAL "))), "")
    if rc != 0 and not first:
        first = f"simulator exit {rc}"
    if errs is None or fats is None:
        return "FAIL", checks, first or "no UVM report summary (crash or timeout?)"
    if int(errs.group(1)) or int(fats.group(1)) or rc != 0:
        return "FAIL", checks, first
    if not mk or checks == 0:
        return "FAIL", 0, f"no {' / '.join(markers)} line"
    return "PASS", checks, ""


def run_tag(r):
    """File-name-safe tag of a run: test name plus its plusargs (a plusarg may hold a path)."""
    tag = r["test"] + ("__" + "_".join(p.lstrip("+").replace("=", "") for p in r["plus"]) if r["plus"] else "")
    tag = re.sub(r"[^A-Za-z0-9_.=-]+", "_", tag).strip("._")
    return tag[:150] if len(tag) <= 150 else tag[:141] + "_" + hashlib.sha1(tag.encode()).hexdigest()[:8]


def run_one(r, s, b, sim, sdir, timeout, cov):
    tag = run_tag(r)
    base = f"{tag}__s{r['seed']}"
    logf = os.path.join(sdir, "logs", base + ".log")
    datf = os.path.join(sdir, "cov", base + ".dat")
    latf = os.path.join(sdir, "lat", base + ".lat")
    plus = list(s["plusargs"]) + r["plus"] + [f"+LAT_FILE={latf}"]
    if sim == "verilator":
        cmd = [b["exe"], f"+UVM_TESTNAME={r['test']}", f"+verilator+seed+{r['seed']}"]
        if cov:
            cmd.append(f"+verilator+coverage+file+{datf}")
        cmd += plus
        cwd = s["root"]
    else:
        tb = next(k for k, v in LEGACY_TB.items() if v == (s["filelist"], s["top"]))
        cmd = ["make", "-s", "run", f"TB={tb}", f"SIM={sim}", f"TEST={r['test']}", f"SEED={r['seed']}",
               "PLUSARGS=" + " ".join(plus)]
        cwd = ROOT
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        rc, log = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout or b""
        rc, log = 124, (out.decode(errors="replace") if isinstance(out, bytes) else out) + "\nTIMEOUT\n"
    with open(logf, "w") as f:
        f.write(log)
    status, checks, detail = classify(rc, log, s["pass_markers"])
    fc = covlib.FuncCov()
    nf = fc.add_log(log)
    lt = covlib.Latency()
    lt.add_text(log)
    lt.add_file(latf)
    return dict(suite=s["name"], test=r["test"], tag=tag, seed=r["seed"], plus=r["plus"], status=status,
                checks=checks, detail=detail[:300], secs=time.time() - t0, log=os.path.relpath(logf, ROOT),
                dat=datf if os.path.exists(datf) else "", fcov=fc, lat=lt, n_fcov=nf)


# --------------------------------------------------------------------------- per-suite merge
def finish_suite(s, results, sdir, note, build_key_, keep_run_cov=False):
    cc = covlib.CodeCov(s["cov_include"])
    fc = covlib.FuncCov()
    lt = covlib.Latency()
    for r in results:
        if r["dat"]:
            cc.add_dat(r["dat"])
        fc.merge(r["fcov"])
        lt.merge(r["lat"])
    cc.write_dat(os.path.join(sdir, "coverage.dat"))
    if not keep_run_cov:
        shutil.rmtree(os.path.join(sdir, "cov"), ignore_errors=True)
        for r in results:
            r["dat"] = ""
    covlib.save_json(os.path.join(sdir, "fcov.json"), fc.to_json())
    covlib.save_json(os.path.join(sdir, "latency.json"), lt.to_json())
    meta = {k: s[k] for k in ("name", "level", "soc", "subsystem", "description", "filelist", "top",
                              "cov_include", "_path")}
    meta.update(build=build_key_, note=note, runs=[{k: v for k, v in r.items() if k not in ("fcov", "lat")}
                                                    for r in results])
    covlib.save_json(os.path.join(sdir, "suite.json"), meta)
    return meta


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", action="append", default=[], help="suite name or glob (repeatable)")
    ap.add_argument("--level", choices=["soc", "subsystem", "vip"], action="append", default=[])
    ap.add_argument("--soc", action="append", default=[], help="only suites of this SoC (repeatable)")
    ap.add_argument("--suites-dir", default=os.path.join(ROOT, "regress", "suites"))
    ap.add_argument("--profile", default="default", help="test-list profile, e.g. nightly")
    ap.add_argument("--list", help="legacy: run one '<tb> <test> <seeds>' list (tb = soc | vip)")
    ap.add_argument("--list-suites", action="store_true")
    ap.add_argument("--sim", default=os.environ.get("SIM", "verilator"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    ap.add_argument("--seeds", type=int, default=0, help="override the seed count of every line")
    ap.add_argument("--filter", default="", help="only tests whose name matches this regex")
    ap.add_argument("--no-cov", action="store_true", help="build without code coverage (faster)")
    ap.add_argument("--no-build", action="store_true", help="reuse the existing builds")
    ap.add_argument("--keep-run-cov", action="store_true",
                    help="keep each run's coverage.dat (default: delete once merged into the suite's)")
    ap.add_argument("--out", default=os.path.join(ROOT, "regress_out"))
    ap.add_argument("--build-dir", default=os.path.join(ROOT, "build", "suites"))
    ap.add_argument("--uvm-home", default=os.environ.get("UVM_HOME", os.path.join(ROOT, "uvm-core", "src")))
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--build-jobs", type=int, default=0,
                    help="compiler processes over all builds (default: CPUs, capped at 1 per 2.5 GB of memory)")
    a = ap.parse_args()
    cov = not a.no_cov and a.sim == "verilator"

    if a.list:
        suites = []
        runs = parse_list(a.list, a.seeds, a.filter)
        for tb in sorted({r["tb"] for r in runs}):
            if tb not in LEGACY_TB:
                sys.exit(f"{a.list}: unknown tb '{tb}' (use a suite yaml for new benches)")
            fl, top = LEGACY_TB[tb]
            s = norm_suite(dict(name=f"{tb}", level="vip" if tb == "vip" else "soc", soc="amba",
                                filelist=fl, top=top, tests=[]), None)
            s["_runs"] = [r for r in runs if r["tb"] == tb]
            suites.append(s)
    else:
        suites = discover(a.suites_dir)
        if a.list_suites:
            print(f"{'suite':22s} {'level':10s} {'soc':8s} {'subsystem':14s} bench")
            for s in suites:
                print(f"{s['name']:22s} {s['level']:10s} {s['soc']:8s} {s['subsystem'] or '-':14s} "
                      f"{s['filelist']} :: {s['top']}{'' if s['enabled'] else '  (disabled)'}")
            return
        if a.suite:
            suites = [s for s in suites if any(fnmatch.fnmatch(s["name"], g) for g in a.suite)]
        elif not (a.level or a.soc):
            suites = [s for s in suites if s["enabled"]]
        if a.level:
            suites = [s for s in suites if s["level"] in a.level]
        if a.soc:
            suites = [s for s in suites if s["soc"] in a.soc]
    if not suites:
        sys.exit("no suites selected (see --list-suites)")

    if os.path.isdir(a.out):
        shutil.rmtree(a.out)
    os.makedirs(a.out)

    # resolve, build each distinct bench once
    plan, skipped, builds = [], [], {}
    for s in suites:
        s2, note = resolve_requirements(s, a.build_dir)
        if s2 is None:
            print(f"skip  {s['name']}: {note}", flush=True)
            skipped.append(dict(name=s["name"], level=s["level"], soc=s["soc"], subsystem=s["subsystem"], note=note))
            continue
        runs = s2.get("_runs") or suite_runs(s2, a.profile, a.seeds, a.filter)
        if not runs:
            skipped.append(dict(name=s["name"], level=s["level"], soc=s["soc"], subsystem=s["subsystem"],
                                note="no tests selected"))
            continue
        plan.append((s2, runs, note))
    build_failed = []
    todo = {}
    for s, runs, note in plan:
        k = build_key(s, a.sim, cov)
        if k in todo or k in builds:
            continue
        if a.no_build and a.sim == "verilator":
            bdir = os.path.join(a.build_dir, a.sim, k)
            exe = os.path.join(bdir, "obj", "V" + s["top"])
            builds[k] = dict(key=k, dir=bdir, exe=exe) if os.path.exists(exe) else None
        else:
            todo[k] = s
    # several benches build at once, each with a share of the CPUs
    # (a Verilator+UVM C++ compile needs about 2 GB per compiler process, so
    # the total is capped by memory as well as by CPUs)
    total = a.build_jobs or max(1, min(a.jobs, os.cpu_count() or 1, int(mem_gb() // 2.5) or 1))
    par = max(1, min(len(todo), total // 4)) if a.sim == "verilator" else 1
    per = max(1, total // par)
    with cf.ThreadPoolExecutor(max_workers=par) as ex:
        futs = {k: ex.submit(build, s, a.sim, per, cov, a.build_dir, a.uvm_home) for k, s in todo.items()}
        for k, fu in futs.items():
            builds[k] = fu.result()
    build_failed = [k for k, b in builds.items() if b is None]

    t0 = time.time()
    results = {s["name"]: [] for s, _, _ in plan}
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = []
        for s, runs, note in plan:
            b = builds[build_key(s, a.sim, cov)]
            sdir = os.path.join(a.out, "suites", s["name"])
            for d in ("logs", "cov", "lat"):
                os.makedirs(os.path.join(sdir, d), exist_ok=True)
            if b is None:
                for r in runs:
                    results[s["name"]].append(dict(suite=s["name"], test=r["test"], tag=run_tag(r), seed=r["seed"],
                                                   plus=r["plus"], status="FAIL", checks=0, detail="build failed",
                                                   secs=0.0, log="", dat="", fcov=covlib.FuncCov(),
                                                   lat=covlib.Latency(), n_fcov=0))
                continue
            for r in runs:
                futs.append(ex.submit(run_one, r, s, b, a.sim, sdir, s["timeout"] or a.timeout, cov))
        for fu in cf.as_completed(futs):
            res = fu.result()
            results[res["suite"]].append(res)
            print(f"{res['status']:4s} {res['suite']}/{res['tag']} seed={res['seed']} checks={res['checks']} "
                  f"({res['secs']:.1f}s) {res['detail']}", flush=True)
    wall = time.time() - t0

    metas = []
    all_runs = []
    for s, runs, note in plan:
        rs = sorted(results[s["name"]], key=lambda x: (x["tag"], x["seed"]))
        all_runs += rs
        metas.append(finish_suite(s, rs, os.path.join(a.out, "suites", s["name"]), note,
                                  build_key(s, a.sim, cov), a.keep_run_cov))
    info = dict(sim=a.sim, profile=a.profile, wall=wall, code_cov=cov, generated=time.strftime("%Y-%m-%d %H:%M:%S"),
                skipped=skipped)
    covlib.save_json(os.path.join(a.out, "run_info.json"), info)

    # flat outputs (unchanged from the single-list runner)
    npass = sum(r["status"] == "PASS" for r in all_runs)
    with open(os.path.join(a.out, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["suite", "test", "plusargs", "seed", "status", "checks", "seconds", "detail", "log"])
        for r in all_runs:
            w.writerow([r["suite"], r["test"], " ".join(r["plus"]), r["seed"], r["status"], r["checks"],
                        f"{r['secs']:.1f}", r["detail"], r["log"]])
    with open(os.path.join(a.out, "junit.xml"), "w") as f:
        f.write(f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="soc-regression" '
                f'tests="{len(all_runs)}" failures="{len(all_runs) - npass}" time="{wall:.1f}">\n')
        for m in metas:
            rs = [r for r in all_runs if r["suite"] == m["name"]]
            nf = sum(r["status"] != "PASS" for r in rs)
            f.write(f'  <testsuite name="{escape(m["name"])}" tests="{len(rs)}" failures="{nf}">\n')
            for r in rs:
                f.write(f'    <testcase classname="{escape(m["name"])}.{escape(r["tag"])}" name="seed{r["seed"]}" '
                        f'time="{r["secs"]:.1f}">')
                if r["status"] != "PASS":
                    f.write(f'<failure message="{escape(r["detail"], {chr(34): "&quot;"})}">{escape(r["log"])}</failure>')
                f.write("</testcase>\n")
            f.write("  </testsuite>\n")
        f.write("</testsuites>\n")

    report.write_reports([a.out], a.out)
    print(f"\n{npass}/{len(all_runs)} passed in {wall:.0f}s -- {os.path.relpath(a.out, ROOT)}/index.html")
    if skipped:
        print("skipped suites: " + ", ".join(f"{x['name']} ({x['note']})" for x in skipped))
    sys.exit(0 if npass == len(all_runs) and not build_failed else 1)


if __name__ == "__main__":
    main()
