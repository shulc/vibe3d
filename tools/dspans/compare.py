#!/usr/bin/env python3
"""Compare the prepared-protocol census's hand-written D lexing with dspans.

Task 5330, step 2. The census (`tools/check_prepared_protocol.py` plus
`tools/prepared_writer_census.py`) cuts D source with its own primitives:
brace/paren balancers, comment and string masks, a declaration-span regex,
unittest strippers, "which aggregate/function contains this offset", and the
comment scrubbers feeding its call lists and body digests. This script does
NOT change any of that. It runs the census exactly as `run_test.d` does, but
under `sys.monitoring`, recording every call to one of those primitives WITH
ITS ARGUMENTS -- so the set of texts and offsets compared is the set the
census really read, measured, not guessed. Afterwards it writes each distinct
text once to a scratch directory, runs `dspans` over all of them in one
process, recomputes each primitive from the parser's spans, and prints every
disagreement by name.

Usage:
  python3 tools/dspans/compare.py                 # full comparison
  python3 tools/dspans/compare.py --controls      # positive controls only
  python3 tools/dspans/compare.py --swap-trial    # census copy on dspans primitives
  python3 tools/dspans/compare.py --inject-control
        # the full comparison over a census run in which ONE file the census
        # reads carries an artificial backtick string holding `}`: proves the
        # comparison can see a divergence at all (the census itself is then
        # expected to fail -- that failure is not the point, the report is)

Exit status: 0 when the comparison ran (divergences are a REPORT, not a
failure), 3 when the census exit code differs from the one the caller
expected (`--expect-census-exit`, default 0), 4 on a tool failure.

Offsets: dspans prints CODE POINT offsets by default, which is what a Python
`str` index is (see tools/dspans/source/app.d, "UNITS"). A file with `\\r` is
refused because `read_text()` would have translated it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time
from collections import defaultdict

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOLS = ROOT / "tools"
CENSUS = TOOLS / "check_prepared_protocol.py"
WRITER = TOOLS / "prepared_writer_census.py"
DSPANS = HERE / "bin" / "dspans"

# Every lexing primitive, by (defining file, function name). `body_of` sits
# inside a retained raw-string specimen in the census and is expected to be
# called zero times; it is listed so that a zero is MEASURED.
WRITER_PRIMITIVES = {
    "_mask_comments", "_mask_unittests", "_balanced", "_balanced_parentheses",
    "_aggregate", "_function_at", "_private_function_body", "_calls",
    "_semantic_digest", "_domains",
}
CENSUS_PRIMITIVES = {
    "mask_d_noncode", "mask_d_comments", "d_declaration_span",
    "without_unittests", "body_of",
}
ALL_PRIMITIVES = sorted(WRITER_PRIMITIVES | CENSUS_PRIMITIVES)

CONTROL_FILE = "source/prepared_tool_transition.d"
CONTROL_ANCHOR = "PreparedArm prepareArm("
CONTROL_TEXT = "\n    enum dspansControl = `}`;\n"


def sha(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "surrogatepass")).hexdigest()


# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------
class Recorder:
    def __init__(self):
        self.keep = {}           # id(text) -> text (keeps ids stable)
        self.ids = {}            # id(text) -> sha
        self.texts = {}          # sha -> text
        self.calls = defaultdict(lambda: {"count": 0, "sites": set(), "parents": set()})
        self.raw_calls = defaultdict(int)
        self.targets = {str(WRITER): WRITER_PRIMITIVES, str(CENSUS): CENSUS_PRIMITIVES}

    def text_key(self, text):
        i = id(text)
        k = self.ids.get(i)
        if k is None:
            k = sha(text)
            self.keep[i] = text
            self.ids[i] = k
            self.texts.setdefault(k, text)
        return k

    def callback(self, code, offset):
        names = self.targets.get(code.co_filename)
        if names is None or code.co_name not in names:
            return sys.monitoring.DISABLE
        frame = sys._getframe(1)
        name = code.co_name
        loc = frame.f_locals
        self.raw_calls[name] += 1
        try:
            key = self.make_key(name, loc)
        except Exception as error:  # an argument shape we did not expect
            key = (name, "unkeyed", repr(error))
        entry = self.calls[key]
        entry["count"] += 1
        parent = None
        f = frame.f_back
        while f is not None:
            fn = f.f_code.co_filename
            if fn in self.targets and f.f_code.co_name in self.targets[fn]:
                parent = parent or f.f_code.co_name
                f = f.f_back
                continue
            if fn in (str(CENSUS), str(WRITER)):
                entry["sites"].add((pathlib.Path(fn).name, f.f_code.co_name, f.f_lineno))
                break
            f = f.f_back
        if parent:
            entry["parents"].add(parent)
        return None

    def make_key(self, name, loc):
        if name in ("_balanced",):
            return (name, self.text_key(loc["text"]), loc["start"])
        if name == "_balanced_parentheses":
            return (name, self.text_key(loc["text"]), loc["open_pos"])
        if name in ("_aggregate", "_function_at"):
            return (name, self.text_key(loc["text"]), loc["pos"])
        if name == "_private_function_body":
            return (name, self.text_key(loc["text"]), loc["name"])
        if name in ("_calls", "_semantic_digest", "_domains"):
            return (name, self.text_key(loc["body"]))
        if name in ("_mask_comments", "_mask_unittests"):
            return (name, self.text_key(loc["text"]))
        if name in ("mask_d_noncode", "mask_d_comments", "without_unittests"):
            return (name, self.text_key(loc["source"]))
        if name == "d_declaration_span":
            return (name, self.text_key(loc["source"]), loc["kind"], loc["name"])
        if name == "body_of":
            return (name, self.text_key(loc["text"]), loc["symbol"])
        raise KeyError(name)


def run_census(recorder: Recorder, inject: bool):
    """Execute the census as `python3 tools/check_prepared_protocol.py` would,
    under monitoring. Returns (exit code, census namespace, writer module)."""
    sys.path.insert(0, str(TOOLS))
    original_read_text = pathlib.Path.read_text
    injected = {"hits": 0}
    if inject:
        target = (ROOT / CONTROL_FILE).resolve()

        def read_text(self, *a, **kw):
            text = original_read_text(self, *a, **kw)
            if pathlib.Path(self).resolve() == target:
                at = text.find(CONTROL_ANCHOR)
                if at < 0:
                    raise SystemExit("control anchor missing: " + CONTROL_ANCHOR)
                brace = text.find("{", at)
                injected["hits"] += 1
                text = text[:brace + 1] + CONTROL_TEXT + text[brace + 1:]
            return text
        pathlib.Path.read_text = read_text

    mon = sys.monitoring
    tool = mon.PROFILER_ID
    mon.use_tool_id(tool, "dspans-compare")
    mon.register_callback(tool, mon.events.PY_START, recorder.callback)
    mon.set_events(tool, mon.events.PY_START)
    namespace = {"__name__": "__main__", "__file__": str(CENSUS)}
    code = compile(CENSUS.read_text(), str(CENSUS), "exec")
    saved_argv = sys.argv
    sys.argv = [str(CENSUS)]
    exit_code = 0
    started = time.monotonic()
    try:
        exec(code, namespace)
    except SystemExit as stop:
        c = stop.code
        if c is None:
            exit_code = 0
        elif isinstance(c, int):
            exit_code = c
        else:
            print(c, file=sys.stderr)
            exit_code = 1
    finally:
        mon.set_events(tool, 0)
        mon.register_callback(tool, mon.events.PY_START, None)
        mon.free_tool_id(tool)
        sys.argv = saved_argv
        pathlib.Path.read_text = original_read_text
    elapsed = time.monotonic() - started
    writer = sys.modules.get("prepared_writer_census")
    return exit_code, namespace, writer, elapsed, injected["hits"]


# ---------------------------------------------------------------------------
# dspans
# ---------------------------------------------------------------------------
def build_dspans():
    run = subprocess.run(["dub", "build", "-q", "--root", str(HERE)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if run.returncode or not DSPANS.exists():
        raise SystemExit("dspans build failed:\n" + run.stdout)


def dspans_for(texts: dict, scratch: pathlib.Path):
    """{sha: parsed dspans record} for every distinct text, one process."""
    scratch.mkdir(parents=True, exist_ok=True)
    paths = []
    for k, text in texts.items():
        p = scratch / f"{k}.d"
        if not p.exists():
            with open(p, "w", encoding="utf-8", newline="") as out:
                out.write(text)
        paths.append(p)
    listing = scratch / "list.txt"
    listing.write_text("".join(f"{p}\n" for p in paths))
    started = time.monotonic()
    run = subprocess.run([str(DSPANS), "--list", str(listing)],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    elapsed = time.monotonic() - started
    if run.returncode:
        raise SystemExit("dspans failed:\n" + run.stderr.decode())
    data = json.loads(run.stdout)
    out = {}
    for rec in data["files"]:
        k = pathlib.Path(rec["path"]).stem
        if rec["crlf"]:
            raise SystemExit(f"text {k} carries \\r: offsets are not comparable")
        if rec["size"] != len(texts[k]):
            raise SystemExit(f"text {k}: dspans size {rec['size']} != len {len(texts[k])}")
        out[k] = Spans(rec)
    return out, elapsed, len(paths)


class Spans:
    def __init__(self, rec):
        self.rec = rec
        self.comments = [tuple(c) for c in rec["comments"]]
        self.strings = [(s, e) for s, e, _k in rec["strings"]]
        self.brace_close = {o: c for o, c in rec["braces"]}
        self.paren_close = {o: c for o, c in rec["parens"]}
        self.aggregates = rec["aggregates"]
        self.functions = rec["functions"]
        self.unittests = rec["unittests"]
        self.version_unittests = rec["versionUnittest"]
        self.errors = rec["parseErrors"]
        self.unmatched = set(rec["unmatched"])

    def inside(self, pos, spans):
        for s, e in spans:
            if s <= pos < e:
                return (s, e)
        return None

    def owner(self, pos):
        """Innermost named declaration containing pos, for reporting."""
        best = None
        for f in self.functions:
            s, e = f["span"]
            if s <= pos < e and (best is None or s >= best[0]):
                name = (f["aggregate"] + "." if f["aggregate"] else "") + f["name"]
                best = (s, name)
        for a in self.aggregates:
            s, e = a["span"]
            if s <= pos < e and (best is None or s > best[0]):
                best = (s, f"{a['kind']} {a['name']}")
        return best[1] if best else "<module>"


# ---------------------------------------------------------------------------
# New primitives, computed from dspans spans with the OLD primitive's contract
# ---------------------------------------------------------------------------
def masked(text, spans, keep_newlines):
    chars = list(text)
    for s, e in spans:
        for i in range(s, e):
            if not (keep_newlines and chars[i] == "\n"):
                chars[i] = " "
    return "".join(chars)


def new_balanced(sp: Spans, text, start):
    open_pos = start - 1
    if open_pos in sp.brace_close:
        return sp.brace_close[open_pos] + 1
    if open_pos in sp.unmatched:
        # An unpaired `{` token: the old primitive's "unbalanced" answer.
        return ("ValueError", "unbalanced D source")
    return ("no-brace-token", open_pos)


def new_balanced_parentheses(sp: Spans, text, open_pos):
    if open_pos in sp.paren_close:
        return sp.paren_close[open_pos] + 1
    if open_pos in sp.unmatched:
        return ("ValueError", "unbalanced D call expression")
    return ("no-paren-token", open_pos)


def unittest_ranges(sp: Spans, with_version):
    ranges = [tuple(u["span"]) for u in sp.unittests]
    if with_version:
        for v in sp.version_unittests:
            if v["trueBody"]:
                ranges.append((v["span"][0], v["trueBody"][1]))
    return ranges


def outermost(ranges):
    out = []
    for s, e in sorted(ranges):
        if out and s < out[-1][1]:
            continue
        out.append((s, e))
    return out


def new_mask_unittests(sp, text):
    return masked(text, unittest_ranges(sp, True), keep_newlines=False)


def new_without_unittests(sp, text):
    result = text
    for s, e in reversed(outermost(unittest_ranges(sp, False))):
        result = result[:s] + result[e:]
    return result


def new_aggregate(sp, text, pos):
    found, found_start = "<module>", -1
    for a in sp.aggregates:
        if a["kind"] not in ("class", "struct") or not a["body"]:
            continue
        o, e = a["body"]
        if o + 1 <= pos < e and o > found_start:
            found, found_start = a["name"], o
    return found


def new_function_at(sp, text, pos):
    found, found_start = "<module>", -1
    for f in sp.functions:
        if not f["body"]:
            continue
        o, e = f["body"]
        if o + 1 <= pos < e and o > found_start:
            found, found_start = f["name"], o
    return found


def new_private_function_body(sp, text, name):
    bodies = [text[f["body"][0] + 1:f["body"][1] - 1] for f in sp.functions
              if f["name"] == name and f["body"] and "private" in f["attrs"]]
    if len(bodies) != 1:
        return ("error", len(bodies))
    return bodies[0]


def scrubbed(sp, text, with_strings):
    spans = list(sp.comments) + (list(sp.strings) if with_strings else [])
    return masked(text, spans, keep_newlines=False)


def new_calls(sp, writer, text):
    # Same regex as the old `_calls`, over a text whose comments and ALL
    # string/character literals are blanked by the lexer.
    out = []
    scrub = scrubbed(sp, text, True)
    for m in re.finditer(r"(?<!\bnew\s)(\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*\(", scrub):
        name = m.group(1)
        if name.split(".")[-1] in {"if", "for", "foreach", "while", "switch",
                                   "catch", "assert", "cast", "version"}:
            continue
        out.append(name)
    return out


def new_semantic_digest(sp, text):
    tokens = " ".join(scrubbed(sp, text, False).split())
    return hashlib.sha256(tokens.encode()).hexdigest()


def new_domains(sp, writer, text):
    saved = writer.re.sub

    # `_domains` scrubs with one regex then works on the result; feed it a
    # lexer-scrubbed body and neutralise its own scrub for this one call.
    def passthrough(pattern, repl, string, *a, **kw):
        if string is text:
            return scrubbed(sp, text, True)
        return saved(pattern, repl, string, *a, **kw)
    writer.re.sub = passthrough
    try:
        return writer._domains(text)
    finally:
        writer.re.sub = saved


def new_declaration_span(sp, text, kind, name):
    hits = [a for a in sp.aggregates if a["kind"] == kind and a["name"] == name and a["body"]]
    if len(hits) != 1:
        return None
    return (hits[0]["declStart"], hits[0]["body"][1])


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------
# The old masks' own patterns, restated so their MATCHED RANGES can be compared
# token by token (a character diff of two masked strings fragments at every
# space both sides leave alone). `compare` asserts that masking with these
# ranges reproduces the old primitive's output exactly, so a drift between the
# restatement and the census is a tool failure, not a quiet mismatch.
OLD_NONCODE = re.compile(
    r'//[^\n]*|/\*.*?\*/|/\+.*?\+/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
OLD_COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/", re.S)
AFFIX = set("rqxcwd")


def line_no(text, pos):
    return text.count("\n", 0, pos) + 1


def line_text(text, pos):
    if not isinstance(pos, int) or pos < 0 or pos > len(text):
        return ""
    b = text.rfind("\n", 0, pos) + 1
    e = text.find("\n", pos)
    e = len(text) if e < 0 else e
    snippet = text[b:e].strip()
    if len(snippet) > 150:
        col = pos - b
        lo = max(0, col - 70)
        snippet = "..." + text[b + lo:b + lo + 140].strip() + "..."
    return snippet


def ctx(text, pos):
    t = line_text(text, pos)
    return f"L{line_no(text, pos)}: {t}" if t or isinstance(pos, int) else ""


class Divergence:
    __slots__ = ("primitive", "origin", "label", "category", "symbol", "old",
                 "new", "old_pos", "new_pos", "text", "site", "verdict", "count")

    def __init__(self, **kw):
        self.count = 1
        for k in self.__slots__:
            if k != "count":
                setattr(self, k, kw.get(k))

    def signature(self):
        return (self.primitive, self.origin, self.category, self.symbol,
                line_text(self.text, self.old_pos), line_text(self.text, self.new_pos))


def literal_kind(tok):
    if tok.startswith("//"):
        return "line comment"
    if tok.startswith("/*"):
        return "block comment"
    if tok.startswith("/+"):
        return "nesting comment" + (" (NESTED)" if tok.find("/+", 2) >= 0 else "")
    head = tok[:2]
    if tok.startswith("`"):
        return "backtick string"
    if head == 'r"':
        return "r-string"
    if head == "q{":
        return "token string"
    if head == 'q"':
        return "delimited string"
    if head == 'x"':
        return "hex string"
    if tok.startswith("'"):
        return "character literal"
    if tok.startswith('"'):
        return "string" + (" with suffix" if tok[-1] in "cwd" else "")
    return "literal"


def unknown_to_old(tok):
    """Whether the old balancer/mask would mis-read this token."""
    kind = literal_kind(tok)
    if kind in ("backtick string", "token string", "delimited string"):
        return True
    if kind == "r-string":
        return "\\" in tok or '"' in tok[2:-1]
    if kind == "nesting comment (NESTED)":
        return True
    return False


def balance_cause(sp, text, open_pos, limit):
    """The first token the old balancer does not know, inside the body."""
    for s, e in sorted(sp.strings + sp.comments):
        if open_pos < s < limit and unknown_to_old(text[s:e]):
            return f"{literal_kind(text[s:e])} {text[s:e][:40]!r} at L{line_no(text, s)}"
    inside = sp.inside(open_pos, sp.comments) or sp.inside(open_pos, sp.strings)
    if inside:
        return f"the `{{` itself is inside a {literal_kind(text[inside[0]:inside[1]])} at L{line_no(text, open_pos)}"
    return "no unknown token found"


def mask_clusters(text, old_ranges, new_ranges):
    """Union overlapping old/new ranges; yield clusters that are not an exact
    one-to-one match."""
    old_set, new_set = set(old_ranges), set(new_ranges)
    items = sorted([(s, e, "old") for s, e in old_ranges if (s, e) not in new_set]
                   + [(s, e, "new") for s, e in new_ranges if (s, e) not in old_set])
    cluster = []
    end = -1
    for s, e, side in items:
        if cluster and s >= end:
            yield cluster
            cluster, end = [], -1
        cluster.append((s, e, side))
        end = max(end, e)
    if cluster:
        yield cluster


def classify_cluster(text, cluster):
    olds = [(s, e) for s, e, side in cluster if side == "old"]
    news = [(s, e) for s, e, side in cluster if side == "new"]
    if not olds:
        kinds = sorted({literal_kind(text[s:e]) for s, e in news})
        return "old leaves visible: " + ", ".join(kinds), news[0][0]
    if not news:
        return "old masks text that is not a literal/comment", olds[0][0]
    if len(olds) == 1 and len(news) == 1:
        (os_, oe), (ns, ne) = olds[0], news[0]
        if ns <= os_ and oe <= ne and set(text[ns:os_] + text[oe:ne]) <= AFFIX:
            return f"affix only ({literal_kind(text[ns:ne])} prefix/suffix)", ns
    kinds = sorted({literal_kind(text[s:e]) for s, e in news})
    return "old masks a different range around: " + ", ".join(kinds), min(olds[0][0], news[0][0])


def verdict_for(primitive, category):
    if category.startswith("affix only"):
        return "cosmetic: new right (the prefix/suffix letter belongs to the literal); no census regex keys on it"
    if category.startswith("old leaves visible"):
        return "new right: the lexer says literal/comment; old leaves it visible to the census regexes"
    if category.startswith("old masks text"):
        return "new right: old masks code (a quote/comment opener inside a literal it does not know)"
    if category.startswith("old masks a different range"):
        return "new right: old mis-reads the literal boundary"
    if category.startswith("start-only"):
        return "same declaration; spans differ only in which leading attributes count as its start"
    return None


def call_old(namespace, writer, name, text, *args):
    fn = namespace.get(name) if name in CENSUS_PRIMITIVES else getattr(writer, name)
    try:
        return fn(text, *args)
    except ValueError as error:
        return ("ValueError", str(error))
    except SystemExit as error:
        return ("SystemExit", str(error))


def outermost_old_unittests(text, namespace):
    # The ranges the OLD `without_unittests` removes, recomputed with its own
    # regex and balancer (it removes the LAST match first, so an outer block
    # swallows an inner one exactly as `outermost` keeps it).
    balanced = namespace["balanced_source"]
    out = []
    for m in re.finditer(r"\bunittest\s*\{", text):
        try:
            out.append((m.start(), balanced(text, m.end())))
        except ValueError:
            out.append((m.start(), -1))
    return outermost(out)


def compare(recorder, namespace, writer, spans, labels, origins):
    divs = []
    pairs = defaultdict(int)

    def add(**kw):
        d = Divergence(**kw)
        if d.verdict is None:
            d.verdict = verdict_for(d.primitive, d.category)
        divs.append(d)

    for key, entry in recorder.calls.items():
        name, k = key[0], key[1]
        if k == "unkeyed":
            add(primitive=name, origin="<unkeyed>", label="<unkeyed>", category="call not keyed",
                symbol=str(key[2:]), text="", site="", verdict="TOOL: argument shape not recorded")
            continue
        text = recorder.texts[k]
        sp = spans[k]
        args = key[2:]
        sites = sorted(entry["sites"])
        site = ", ".join(f"{fn}:{ln}" for _f, fn, ln in sites[:4]) + (" ..." if len(sites) > 4 else "")
        if entry["parents"]:
            site += " (via " + ",".join(sorted(entry["parents"])) + ")"
        common = dict(primitive=name, origin=origins[k], label=labels[k], text=text, site=site)

        if name in ("_balanced", "_balanced_parentheses"):
            old = call_old(namespace, writer, name, text, *args)
            open_pos = args[0] - 1 if name == "_balanced" else args[0]
            new = (new_balanced if name == "_balanced" else new_balanced_parentheses)(sp, text, args[0])
            pairs[name] += 1
            if old != new:
                limit = max(v for v in (old, new, open_pos + 1) if isinstance(v, int))
                cause = balance_cause(sp, text, open_pos, limit)
                verdict = ("new right: " + cause) if not cause.startswith("no unknown") else None
                add(category="close differs", symbol=f"{text[open_pos]!r} at L{line_no(text, open_pos)} in {sp.owner(open_pos)}",
                    old=old, new=new, old_pos=old - 1 if isinstance(old, int) else None,
                    new_pos=new - 1 if isinstance(new, int) else None, verdict=verdict, **common)
        elif name in ("_aggregate", "_function_at"):
            old = call_old(namespace, writer, name, text, *args)
            new = (new_aggregate if name == "_aggregate" else new_function_at)(sp, text, args[0])
            pairs[name] += 1
            if old != new:
                add(category="containing name differs", symbol=f"offset {args[0]} (L{line_no(text, args[0])})",
                    old=old, new=new, old_pos=args[0], new_pos=args[0], **common)
        elif name == "_private_function_body":
            old = call_old(namespace, writer, name, text, *args)
            new = new_private_function_body(sp, text, args[0])
            pairs[name] += 1
            if old != new:
                add(category="body differs", symbol=args[0], old=str(old)[:80], new=str(new)[:80], **common)
        elif name == "d_declaration_span":
            old = call_old(namespace, writer, name, text, *args)
            new = new_declaration_span(sp, text, *args)
            pairs[name] += 1
            if old != new:
                if old is not None and new is not None and old[1] == new[1]:
                    lo, hi = sorted((old[0], new[0]))
                    cat = f"start-only: {text[lo:hi].strip()!r} counted by {'new' if new[0] < old[0] else 'old'} only"
                else:
                    cat = "end or presence differs"
                add(category=cat, symbol=f"{args[0]} {args[1]}", old=old, new=new,
                    old_pos=old[0] if old else None, new_pos=new[0] if new else None, **common)
        elif name in ("mask_d_noncode", "mask_d_comments", "_mask_comments"):
            old_out = call_old(namespace, writer, name, text)
            pattern = OLD_NONCODE if name == "mask_d_noncode" else OLD_COMMENTS
            keep_nl = name != "_mask_comments"
            old_ranges = [m.span() for m in pattern.finditer(text) if m.end() > m.start()]
            if masked(text, old_ranges, keep_nl) != old_out:
                raise SystemExit(f"TOOL: restated pattern for {name} does not reproduce the census "
                                 f"output on {labels[k]}")
            new_ranges = sp.comments + (sp.strings if name == "mask_d_noncode" else [])
            pairs[name] += len(new_ranges)
            for cluster in mask_clusters(text, old_ranges, new_ranges):
                cat, pos = classify_cluster(text, cluster)
                s = min(c[0] for c in cluster)
                e = max(c[1] for c in cluster)
                add(category=cat, symbol=f"{text[s:e][:50]!r} in {sp.owner(s)}",
                    old=[(a, b) for a, b, side in cluster if side == "old"],
                    new=[(a, b) for a, b, side in cluster if side == "new"],
                    old_pos=pos, new_pos=None, **common)
        elif name == "without_unittests":
            old_out = call_old(namespace, writer, name, text)
            new_out = new_without_unittests(sp, text)
            old_r = outermost_old_unittests(text, namespace)
            new_r = outermost(unittest_ranges(sp, False))
            pairs[name] += len(new_r)
            if old_out == new_out:
                continue
            for r in [r for r in old_r if r not in new_r]:
                inner = [n for n in new_r if r[0] <= n[0] and n[1] <= r[1]]
                if sp.inside(r[0], sp.comments) or sp.inside(r[0], sp.strings):
                    cat = "old removes a `unittest {` found inside a comment/string"
                    verdict = "new right: that text is not a unittest; latent unless a counted pattern sits in the removed span"
                elif r[1] == -1 or any(n[0] == r[0] for n in new_r):
                    same = [n for n in new_r if n[0] == r[0]]
                    cat = f"old removes {r[0]}..{r[1]} where the block ends at {same[0][1] if same else '?'}"
                    cause = balance_cause(sp, text, text.find('{', r[0]), max(r[1], same[0][1] if same else 0))
                    removed_code = r[1] - (same[0][1] if same else r[1]) - sum(n[1] - n[0] for n in inner if n[0] != r[0])
                    verdict = (f"new right: {cause}; the old range swallows {len(inner) - 1} later unittest "
                               f"block(s) and ~{max(removed_code, 0)} chars of PRODUCTION code")
                else:
                    cat = "old removes a range the parser does not call a unittest"
                    verdict = None
                add(category=cat, symbol=f"unittest at L{line_no(text, r[0])}", old=r, new=None,
                    old_pos=r[0], new_pos=None, verdict=verdict, **common)
            covered = [r for r in old_r if r[1] != -1]
            for r in [r for r in new_r if r not in old_r]:
                if any(o[0] <= r[0] and r[1] <= o[1] for o in covered):
                    continue  # swallowed by an old range already reported
                head = text[r[0]:text.find("{", r[0])]
                if "//" in head or "/*" in head or "/+" in head:
                    cat = "old keeps a unittest whose keyword is followed by a comment before `{`"
                    verdict = "new right: `unittest // ...\\n{` is a unittest; old counts its body as production"
                elif "@" in head or "(" in head:
                    cat = "old keeps an attributed unittest"
                    verdict = "new right"
                else:
                    cat = "old keeps a unittest"
                    verdict = None
                add(category=cat, symbol=f"unittest at L{line_no(text, r[0])}", old=None, new=r,
                    old_pos=None, new_pos=r[0], verdict=verdict, **common)
        elif name == "_mask_unittests":
            old = call_old(namespace, writer, name, text)
            pairs[name] += 1
            if old != new_mask_unittests(sp, text):
                add(category="output differs", symbol="-", **common)
        elif name == "_calls":
            old = call_old(namespace, writer, name, text)
            new = new_calls(sp, writer, text)
            pairs[name] += 1
            if old != new:
                add(category="call list differs", symbol="-", old=sorted(set(old) - set(new)),
                    new=sorted(set(new) - set(old)), **common)
        elif name == "_semantic_digest":
            old = call_old(namespace, writer, name, text)
            new = new_semantic_digest(sp, text)
            pairs[name] += 1
            if old != new:
                old_in = re.sub(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/", lambda m: " " * len(m.group()), text, flags=re.S)
                runs = diff_runs(old_in, scrubbed(sp, text, False))
                first = runs[0][0] if runs else None
                add(category="digest differs (a frozen digest would MOVE)", symbol=f"first at L{line_no(text, first) if first is not None else '?'}",
                    old=old[:16], new=new[:16], old_pos=first, **common)
        elif name == "_domains":
            old = call_old(namespace, writer, name, text)
            new = new_domains(sp, writer, text)
            pairs[name] += 1
            if old != new:
                add(category="domain word differs", symbol="-", old=old, new=new, **common)
        elif name == "body_of":
            pairs[name] += 1
    return divs, pairs


def diff_runs(a, b):
    runs = []
    i, n = 0, min(len(a), len(b))
    while i < n:
        if a[i] != b[i]:
            j = i
            while j < n and a[j] != b[j]:
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    if len(a) != len(b):
        runs.append((n, max(len(a), len(b))))
    return runs


def label_texts(texts):
    """Name every text: a tree file it equals, else the tree file it derives
    from (a census mutant or an intermediate of a primitive shares that file's
    longest prefix), else the file it is a slice of."""
    files = {}
    for sub in ("source", "tests"):
        for p in sorted((ROOT / sub).rglob("*.d")):
            try:
                files[p.relative_to(ROOT).as_posix()] = p.read_text()
            except (OSError, UnicodeDecodeError):
                continue
    by_sha = {}
    by_head = defaultdict(list)
    for path, t in files.items():
        by_sha.setdefault(sha(t), path)
        by_head[t[:64]].append(path)
    labels, origins = {}, {}
    for k, t in texts.items():
        if k in by_sha:
            labels[k] = origins[k] = by_sha[k]
            continue
        best, best_len = None, 0
        for path in by_head.get(t[:64], []):
            ft = files[path]
            n = len(os.path.commonprefix([ft, t]))
            if n > best_len:
                best, best_len = path, n
        if best:
            labels[k] = f"derived from {best} (first difference at L{line_no(t, best_len)}; {len(t)} vs {len(files[best])} chars)"
            origins[k] = best
            continue
        probe = t[:200]
        for path, ft in files.items():
            if len(probe) >= 40 and probe in ft:
                at = ft.find(probe)
                labels[k] = f"slice of {path} from L{line_no(ft, at)} ({len(t)} chars)"
                origins[k] = path
                break
        else:
            labels[k] = f"synthetic text {k[:10]} ({len(t)} chars)"
            origins[k] = labels[k]
    return labels, origins


# ---------------------------------------------------------------------------
# Positive controls
# ---------------------------------------------------------------------------
def controls(scratch):
    """The four inputs of the card's table, plus a token-string declaration.
    Each must come out RIGHT on the new path and WRONG on the old one."""
    sys.path.insert(0, str(TOOLS))
    import prepared_writer_census as w
    ns = {"__name__": "controls"}
    src = CENSUS.read_text()
    # Only the two mask/span helpers are needed; take their source verbatim
    # rather than executing the whole census.
    start = src.index("def mask_d_noncode(source):")
    end = src.index("def has_final_class(source, name):")
    exec("import re\nfrom prepared_writer_census import _balanced as balanced_source\n"
         + src[start:end], ns)
    cases = [
        ("backtick", "void f() { auto s = `a\"b`; }\n"),
        ("raw-string", "void f() { auto s = r\"C:\\\"; }\n"),
        ("nested-comment", "void f() { /+ a /+ b +/ } +/ int x; }\n"),
        ("token-string", "void f() { auto s = q{ if (a) { b(); } }; int y; }\n"),
    ]
    texts = {sha(t): t for _n, t in cases}
    decl = "enum s = q{ class Fake { } };\nclass Real { }\n"
    texts[sha(decl)] = decl
    spans, _t, _n = dspans_for(texts, scratch / "controls")
    ok = True
    print("positive controls: _balanced on the body brace of f()")
    for name, t in cases:
        open_pos = t.index("{")
        truth = len(t) - 1  # every body closes at the file's last `}` (a '\n' follows)
        try:
            old = w._balanced(t, open_pos + 1)
        except ValueError as error:
            old = f"ValueError({error})"
        new = new_balanced(spans[sha(t)], t, open_pos + 1)
        new_right = new == truth
        old_right = old == truth
        verdict = ("new right, old WRONG" if new_right and not old_right
                   else "BOTH right (old primitive is not wrong on this input)" if new_right and old_right
                   else "NEW WRONG")
        if not new_right:
            ok = False
        print(f"  {name:15s} truth={truth:3d} old={old!s:32s} new={new!s:6s} -> {verdict}")
    print("positive control: d_declaration_span over a token string")
    old = ns["d_declaration_span"](decl, "class", "Fake")
    new = new_declaration_span(spans[sha(decl)], decl, "class", "Fake")
    print(f"  class Fake (only inside q{{}}): old={old} new={new} -> "
          + ("new right, old WRONG" if new is None and old is not None else "UNEXPECTED"))
    if new is not None:
        ok = False
    # Units: a non-ASCII comment before the brace. Code-point offsets (the
    # default) must index the Python str; byte offsets must not.
    uni = "// é → ü\nvoid g() { int z; }\n"
    (scratch / "controls").mkdir(parents=True, exist_ok=True)
    upath = scratch / "controls" / "units.d"
    with open(upath, "w", encoding="utf-8", newline="") as out:
        out.write(uni)
    per_unit = {}
    for unit in ("codepoints", "bytes"):
        run = subprocess.run([str(DSPANS), f"--units={unit}", str(upath)],
                             stdout=subprocess.PIPE, check=True)
        per_unit[unit] = json.loads(run.stdout)["files"][0]["braces"][0]
    cp_open, cp_close = per_unit["codepoints"]
    by_open, by_close = per_unit["bytes"]
    raw = uni.encode("utf-8")
    cp_ok = uni[cp_open] == "{" and uni[cp_close] == "}"
    by_ok = raw[by_open:by_open + 1] == b"{" and raw[by_close:by_close + 1] == b"}"
    print(f"units control (non-ASCII comment): codepoints brace={per_unit['codepoints']} "
          f"str[...]={uni[cp_open]!r}{uni[cp_close]!r}; bytes brace={per_unit['bytes']} "
          f"bytes[...]={raw[by_open:by_open+1]!r}{raw[by_close:by_close+1]!r}; "
          f"a byte offset used as a str index reads {uni[by_open]!r}")
    if not (cp_ok and by_ok and uni[by_open] != "{"):
        ok = False
    old_mask = ns["mask_d_noncode"](cases[0][1])
    new_mask = masked(cases[0][1], spans[sha(cases[0][1])].comments + spans[sha(cases[0][1])].strings, True)
    print(f"  mask_d_noncode backtick: old={old_mask.rstrip()!r}\n"
          f"                           new={new_mask.rstrip()!r}")
    return ok


# ---------------------------------------------------------------------------
# Swap trial: the census with every primitive answered by dspans
# ---------------------------------------------------------------------------
# NOT a replacement (task 5330 step 3 is a separate decision): the census file
# is untouched. This executes an in-memory copy whose primitive definitions are
# rebound, right after each `def`, to implementations that read dspans spans,
# and reports whether the census's own assertions still hold. A divergence the
# comparison lists is LIVE if this run fails on it and LATENT if it passes.
def swap_trial(scratch):
    import ast
    import importlib
    cache = {}
    work = scratch / "swap"
    work.mkdir(parents=True, exist_ok=True)
    stats = {"texts": 0, "secs": 0.0}

    def spans_of(text):
        k = sha(text)
        sp = cache.get(k)
        if sp is None:
            path = work / f"{k}.d"
            with open(path, "w", encoding="utf-8", newline="") as out:
                out.write(text)
            started = time.monotonic()
            run = subprocess.run([str(DSPANS), str(path)], stdout=subprocess.PIPE, check=True)
            stats["secs"] += time.monotonic() - started
            stats["texts"] += 1
            sp = cache[k] = Spans(json.loads(run.stdout)["files"][0])
        return sp

    def balanced(text, start):
        r = new_balanced(spans_of(text), text, start)
        if isinstance(r, tuple):
            raise ValueError("unbalanced D source" if r[0] == "ValueError" else f"no brace token at {r[1]}")
        return r

    def balanced_parentheses(text, open_pos):
        r = new_balanced_parentheses(spans_of(text), text, open_pos)
        if isinstance(r, tuple):
            raise ValueError("unbalanced D call expression" if r[0] == "ValueError" else f"no paren token at {r[1]}")
        return r

    def private_function_body(text, name):
        r = new_private_function_body(spans_of(text), text, name)
        if isinstance(r, tuple):
            raise ValueError(f"expression factory helper {name} resolved to {r[1]} "
                             "private same-module function bodies")
        return r

    sys.path.insert(0, str(TOOLS))
    writer = importlib.import_module("prepared_writer_census")
    writer_swap = {
        "_balanced": balanced,
        "_balanced_parentheses": balanced_parentheses,
        "_mask_comments": lambda text: masked(text, spans_of(text).comments, False),
        "_mask_unittests": lambda text: new_mask_unittests(spans_of(text), text),
        "_aggregate": lambda text, pos: new_aggregate(spans_of(text), text, pos),
        "_function_at": lambda text, pos: new_function_at(spans_of(text), text, pos),
        "_private_function_body": private_function_body,
        "_calls": lambda body: new_calls(spans_of(body), writer, body),
        "_semantic_digest": lambda body: new_semantic_digest(spans_of(body), body),
    }
    counts = defaultdict(int)
    broken = os.environ.get("DSPANS_SWAP_BREAK", "")

    def counted(name, fn):
        # A population floor for the trial (a rebinding nobody reaches passes
        # vacuously), and a break knob: DSPANS_SWAP_BREAK=<primitive> makes
        # that one primitive return a deliberately wrong answer (an empty
        # body, nothing masked, no span, a constant digest), which the census
        # must then refuse -- the trial's own positive control.
        def wrapper(*args):
            counts[name] += 1
            if name == broken:
                first = args[0]
                if name in ("_balanced", "_balanced_parentheses"):
                    return args[1] + 1
                if name in ("_mask_comments", "mask_d_noncode", "mask_d_comments",
                            "_mask_unittests", "without_unittests"):
                    return first
                if name == "d_declaration_span":
                    return None
                if name in ("_aggregate", "_function_at"):
                    return "<module>"
                if name == "_private_function_body":
                    return ""
                if name == "_semantic_digest":
                    return "0" * 64
                if name == "_calls":
                    return []
            return fn(*args)
        return wrapper

    writer_swap = {n: counted(n, f) for n, f in writer_swap.items()}
    saved = {name: getattr(writer, name) for name in writer_swap}
    for name, fn in writer_swap.items():
        setattr(writer, name, fn)
    census_swap = {n: counted(n, f) for n, f in {
        "mask_d_noncode": lambda source: masked(source, spans_of(source).comments + spans_of(source).strings, True),
        "mask_d_comments": lambda source: masked(source, spans_of(source).comments, True),
        "d_declaration_span": lambda source, kind, name: new_declaration_span(spans_of(source), source, kind, name),
        "without_unittests": lambda source: new_without_unittests(spans_of(source), source),
    }.items()}
    tree = ast.parse(CENSUS.read_text(), str(CENSUS))
    body, rebound = [], []
    for node in tree.body:
        body.append(node)
        if isinstance(node, ast.FunctionDef) and node.name in census_swap:
            body.append(ast.parse(f"{node.name} = __dspans_swap__[{node.name!r}]").body[0])
            rebound.append(node.name)
    tree.body = body
    ast.fix_missing_locations(tree)
    namespace = {"__name__": "__main__", "__file__": str(CENSUS), "__dspans_swap__": census_swap}
    started = time.monotonic()
    rc, message = 0, ""
    try:
        exec(compile(tree, str(CENSUS), "exec"), namespace)
    except SystemExit as stop:
        c = stop.code
        rc, message = (0, "") if c is None else (c, "") if isinstance(c, int) else (1, str(c))
    finally:
        for name, fn in saved.items():
            setattr(writer, name, fn)
    elapsed = time.monotonic() - started
    print(f"swap trial: rebound {len(writer_swap)} writer primitives and {len(rebound)} census "
          f"primitives ({', '.join(sorted(rebound))})")
    print(f"swap trial: census exit {rc} in {elapsed:.1f}s; dspans answered {stats['texts']} "
          f"distinct texts in {stats['secs']:.1f}s")
    print("swap trial: calls answered by dspans: " + ", ".join(
        f"{n} {counts.get(n, 0)}" for n in sorted(set(writer_swap) | set(census_swap))))
    if broken:
        print(f"swap trial: DSPANS_SWAP_BREAK={broken} (a positive control: the census must refuse)")
    if message:
        print("swap trial: census message: " + message)
    return rc


def report(recorder, spans, labels, divs, pairs):
    print("\nprimitive calls recorded: raw calls / distinct (text, args) calls / span pairs compared")
    distinct = defaultdict(int)
    for key in recorder.calls:
        distinct[key[0]] += 1
    for name in ALL_PRIMITIVES:
        print(f"  {name:24s} {recorder.raw_calls.get(name, 0):7d} / {distinct.get(name, 0):6d} / {pairs.get(name, 0):7d}")
    print(f"  {'TOTAL':24s} {sum(recorder.raw_calls.values()):7d} / {sum(distinct.values()):6d} / {sum(pairs.values()):7d}")
    keys = [k for k in recorder.calls if k[1] != "unkeyed"]
    whole = sorted({labels[k[1]] for k in keys if not labels[k[1]].startswith(("derived", "slice", "synthetic"))})
    other = {labels[k[1]] for k in keys} - set(whole)
    print(f"\ntexts read by the census: {len(whole)} whole tree files, {len(other)} derived/sliced/synthetic texts")
    parse_err = sorted(labels[k] for k, s in spans.items() if s.errors and labels[k] in whole)
    if parse_err:
        print("  whole tree files with parse errors: " + ", ".join(parse_err))

    unique = {}
    for d in divs:
        sig = d.signature()
        if sig in unique:
            unique[sig].count += 1
        else:
            unique[sig] = d
    print(f"\nDIVERGENCES: {len(divs)} raw, {len(unique)} distinct "
          "(the same divergence in a mutant or an intermediate text of the same file is counted, not repeated)")
    by = defaultdict(list)
    for d in unique.values():
        by[d.primitive].append(d)
    for name in sorted(by):
        cats = defaultdict(int)
        for d in by[name]:
            cats[d.category.split(":")[0]] += 1
        print(f"\n== {name}: {len(by[name])} distinct -- " + "; ".join(f"{c}: {n}" for c, n in sorted(cats.items())))
        for d in sorted(by[name], key=lambda d: (d.origin, d.category, str(d.symbol))):
            times = f" [x{d.count}]" if d.count > 1 else ""
            where = d.origin if d.label == d.origin else d.label
            print(f"- {where} :: {d.symbol}{times}")
            print(f"    {d.category}")
            if d.old is not None or d.new is not None:
                print(f"    old={d.old!s:.150}  new={d.new!s:.150}")
            if d.old_pos is not None:
                print(f"    old@ {ctx(d.text, d.old_pos)}")
            if d.new_pos is not None and d.new_pos != d.old_pos:
                print(f"    new@ {ctx(d.text, d.new_pos)}")
            print(f"    verdict: {d.verdict or 'OPEN -- needs a reading'}")
            if d.site:
                print(f"    census site: {d.site}")


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--controls", action="store_true")
    ap.add_argument("--inject-control", action="store_true")
    ap.add_argument("--swap-trial", action="store_true",
                    help="run an in-memory copy of the census with every primitive answered by dspans")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--scratch", default=os.environ.get("DSPANS_SCRATCH",
                    os.path.join(os.environ.get("TMPDIR", "/var/tmp"), "dspans-compare")))
    ap.add_argument("--expect-census-exit", type=int, default=None)
    opts = ap.parse_args()
    scratch = pathlib.Path(opts.scratch)
    if not opts.no_build:
        build_dspans()
    if opts.controls:
        return 0 if controls(scratch) else 4
    if opts.swap_trial:
        swap_trial(scratch)
        return 0

    recorder = Recorder()
    rc, namespace, writer, census_secs, hits = run_census(recorder, opts.inject_control)
    expect = opts.expect_census_exit
    if expect is None:
        expect = None if opts.inject_control else 0
    print(f"census exit {rc} in {census_secs:.1f}s under monitoring"
          + (f"; control injected into {CONTROL_FILE} {hits} time(s)" if opts.inject_control else ""))
    if writer is None:
        print("census never imported prepared_writer_census", file=sys.stderr)
        return 4
    spans, dspans_secs, n_texts = dspans_for(recorder.texts, scratch / "texts")
    print(f"dspans: {n_texts} distinct texts in {dspans_secs:.2f}s")
    labels, origins = label_texts(recorder.texts)
    divs, pairs = compare(recorder, namespace, writer, spans, labels, origins)
    report(recorder, spans, labels, divs, pairs)
    if expect is not None and rc != expect:
        print(f"census exit {rc} != expected {expect}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
