# SPDX-License-Identifier: Apache-2.0
"""covlib -- coverage and latency databases used by regress.py and covmerge.py.

Three kinds of data are collected per run and merged per suite and across
suites (the "cumulative" view):

* code coverage: Verilator coverage.dat files (line, toggle, branch, user/SVA)
* functional coverage: ``FCOV <model> <inst> <point> <bin> <hits>`` lines
  (or the 4-field ``FCOV <group> <point> <bin> <hits>`` form)
* latency: ``LAT <master> <slave> <R|W> <cycles>`` samples

All of it merges by addition, so any set of runs, suites or whole regression
output directories can be combined.
"""
import fnmatch, json, math, os, re
from collections import Counter, defaultdict

# --------------------------------------------------------------------------- code coverage
# A Verilator coverage.dat line is   C '<key>' <count>
# where <key> is a list of \x01<name>\x02<value> fields: f=file, l=line,
# n=column, t=type, page=v_<type>/<module>, o=comment, h=hierarchy, ...
_DAT_RE = re.compile(r"^C '(.*)' (\d+)\s*$")
TYPES = ("line", "branch", "toggle", "expr", "user")


def _fields(key):
    d = {}
    for part in key.split("\x01"):
        if "\x02" in part:
            k, v = part.split("\x02", 1)
            d[k] = v
    return d


def point_type(d):
    t = d.get("t", "")
    page = d.get("page", "")
    if not t and page.startswith("v_"):
        t = page[2:].split("/", 1)[0]
    # Verilator reports line coverage as type "line" or as "block" entries
    if t in ("block", "line"):
        return "line"
    if t.startswith("toggle"):
        return "toggle"
    if t.startswith("branch"):
        return "branch"
    if t.startswith("expr"):
        return "expr"
    return t or "user"


_PARAM_SUFFIX = re.compile(r"__[A-Z][0-9A-Za-z]{6,}$")   # Verilator's parameterized-module suffix


def module_of(d):
    page = d.get("page", "")
    mod = page.split("/", 1)[1] if "/" in page else os.path.splitext(os.path.basename(d.get("f", "?")))[0]
    return _PARAM_SUFFIX.sub("", mod)


class CodeCov:
    """Verilator coverage points: raw key -> count (per instance).

    Only points whose source file matches one of ``include`` (fnmatch globs,
    default ``*rtl/*``) are kept, so testbench, VIP and simulator-library code
    never dilutes the design numbers. Native covergroup bins (Verilator >= 5.04x
    records them in the same file) are kept apart in ``cg`` -- they are
    functional coverage, not code coverage.
    """

    def __init__(self, include=None):
        self.points = Counter()
        self.cg = Counter()
        self.include = list(include or ["*rtl/*"])

    def _keep(self, f):
        return any(fnmatch.fnmatch(f, g) for g in self.include)

    def add_dat(self, path):
        if not os.path.exists(path):
            return False
        with open(path, errors="replace") as f:
            for line in f:
                m = _DAT_RE.match(line)
                if not m:
                    continue
                key, cnt = m.group(1), int(m.group(2))
                if "\x02covergroup" in key:
                    self.cg[key] += cnt
                elif self._keep(_fields(key).get("f", "")):
                    self.points[key] += cnt
        return True

    def merge(self, other):
        self.points.update(other.points)   # keeps zero-count points
        self.cg.update(other.cg)

    def write_dat(self, path):
        with open(path, "w") as f:
            f.write("# SystemC::Coverage-3\n")
            for k in sorted(self.points):
                f.write(f"C '{k}' {self.points[k]}\n")
            for k in sorted(self.cg):
                f.write(f"C '{k}' {self.cg[k]}\n")

    def __len__(self):
        return len(self.points)

    # -- design view: the same RTL point in every instance / bench counts once
    def design_points(self):
        """(type, module, line, column, comment) -> count summed over instances."""
        out = Counter()
        for k, c in self.points.items():
            d = _fields(k)
            dk = (point_type(d), module_of(d), int(d.get("l", 0) or 0), d.get("n", ""), d.get("o", ""))
            out[dk] += c
        return out

    def summary(self, design=True):
        """{type: [covered, total]} and {module: {type: [covered, total]}}."""
        tot = {t: [0, 0] for t in TYPES}
        mods = defaultdict(lambda: {t: [0, 0] for t in TYPES})
        if design:
            pts = self.design_points()
            for (t, mod, *_), c in pts.items():
                t = t if t in tot else "user"
                tot[t][1] += 1; mods[mod][t][1] += 1
                if c > 0:
                    tot[t][0] += 1; mods[mod][t][0] += 1
        else:
            for k, c in self.points.items():
                d = _fields(k)
                t = point_type(d)
                t = t if t in tot else "user"
                mod = module_of(d)
                tot[t][1] += 1; mods[mod][t][1] += 1
                if c > 0:
                    tot[t][0] += 1; mods[mod][t][0] += 1
        return tot, dict(mods)

    def covergroup_bins(self):
        """Native covergroup bins folded over instances: (file, line, bin path) -> hits."""
        out = Counter()
        for k, c in self.cg.items():
            d = _fields(k)
            h = d.get("h", "")
            path = h.split(".", 1)[1] if "." in h else h        # drop the anonymous class name
            out[(d.get("f", ""), int(d.get("l", 0) or 0), path)] += c
        return out

    def holes(self, limit=200):
        """Uncovered design points, for the report: [(type, module, line, comment)]."""
        out = []
        for (t, mod, line, col, cmt), c in sorted(self.design_points().items(),
                                                   key=lambda kv: (kv[0][1], kv[0][2], kv[0][0])):
            if c == 0:
                out.append((t, mod, line, cmt))
        return out[:limit], len(out)


# --------------------------------------------------------------------------- functional coverage
_FCOV_RE = re.compile(r"^\s*FCOV\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(\S+))?\s*$")


class FuncCov:
    """(model, inst, point, bin) -> hits."""

    def __init__(self):
        self.bins = Counter()

    def add_log(self, text):
        n = 0
        for line in text.splitlines():
            if "FCOV" not in line:
                continue
            m = _FCOV_RE.match(line)
            if not m:
                continue
            g = m.groups()
            if g[4] is None:          # FCOV <group> <point> <bin> <hits>
                model, inst, point, b, hits = g[0], g[0], g[1], g[2], g[3]
            else:
                model, inst, point, b, hits = g
            if not hits.isdigit():
                continue
            self.bins[(model, inst, point, b)] += int(hits)
            self.bins.setdefault((model, inst, point, b), 0)
            n += 1
        return n

    def merge(self, other, prefix=None):
        for (model, inst, point, b), h in other.bins.items():
            k = (model, f"{prefix}:{inst}" if prefix else inst, point, b)
            self.bins[k] += h
            self.bins.setdefault(k, 0)

    def to_json(self):
        return [[m, i, p, b, h] for (m, i, p, b), h in sorted(self.bins.items())]

    @classmethod
    def from_json(cls, rows):
        fc = cls()
        for m, i, p, b, h in rows:
            fc.bins[(m, i, p, b)] += h
            fc.bins.setdefault((m, i, p, b), 0)
        return fc

    def totals(self):
        cov = sum(1 for h in self.bins.values() if h > 0)
        return cov, len(self.bins)

    def by_group(self):
        """{(model, inst): {point: [covered, total, [holes]]}}"""
        out = defaultdict(lambda: defaultdict(lambda: [0, 0, []]))
        for (m, i, p, b), h in self.bins.items():
            e = out[(m, i)][p]
            e[1] += 1
            if h > 0:
                e[0] += 1
            else:
                e[2].append(b)
        return out

    def by_model(self):
        """Instances folded together: (model, point, bin) is covered if any instance hit it."""
        fm = Counter()
        for (m, i, p, b), h in self.bins.items():
            fm[(m, p, b)] += h
            fm.setdefault((m, p, b), 0)
        out = defaultdict(lambda: defaultdict(lambda: [0, 0, []]))
        for (m, p, b), h in fm.items():
            e = out[m][p]
            e[1] += 1
            if h > 0:
                e[0] += 1
            else:
                e[2].append(b)
        return out


# --------------------------------------------------------------------------- latency
_LAT_RE = re.compile(r"^\s*LAT\s+(\S+)\s+(\S+)\s+([RW])\s+(\d+)\s*$")


class Latency:
    """(master, slave, dir) -> Counter{cycles: n}. Exact, mergeable histograms."""

    def __init__(self):
        self.h = defaultdict(Counter)

    def add_text(self, text):
        n = 0
        for line in text.splitlines():
            if "LAT" not in line:
                continue
            m = _LAT_RE.match(line)
            if m:
                self.h[(m.group(1), m.group(2), m.group(3))][int(m.group(4))] += 1
                n += 1
        return n

    def add_file(self, path):
        if not os.path.exists(path):
            return 0
        with open(path, errors="replace") as f:
            return self.add_text(f.read())

    def merge(self, other, prefix=None):
        for (m, s, d), c in other.h.items():
            self.h[(f"{prefix}:{m}" if prefix else m, s, d)].update(c)

    def to_json(self):
        return [[m, s, d, {str(k): v for k, v in sorted(c.items())}] for (m, s, d), c in sorted(self.h.items())]

    @classmethod
    def from_json(cls, rows):
        lt = cls()
        for m, s, d, c in rows:
            lt.h[(m, s, d)].update({int(k): v for k, v in c.items()})
        return lt

    def __len__(self):
        return sum(sum(c.values()) for c in self.h.values())

    @staticmethod
    def stats(c):
        n = sum(c.values())
        if n == 0:
            return None
        vals = sorted(c.items())
        tot = sum(k * v for k, v in vals)

        def pct(p):
            want = max(1, math.ceil(p / 100.0 * n))
            run = 0
            for k, v in vals:
                run += v
                if run >= want:
                    return k
            return vals[-1][0]
        return dict(n=n, min=vals[0][0], avg=tot / n, p50=pct(50), p95=pct(95), p99=pct(99), max=vals[-1][0])

    def table(self):
        """[(master, slave, dir, stats)] sorted by master, slave, dir."""
        rows = []
        for (m, s, d), c in sorted(self.h.items()):
            st = self.stats(c)
            if st:
                rows.append((m, s, d, st))
        return rows

    def combined(self):
        """(master, slave) -> Counter with R and W folded together."""
        out = defaultdict(Counter)
        for (m, s, d), c in self.h.items():
            out[(m, s)].update(c)
        return out


def save_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1)


def load_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)
