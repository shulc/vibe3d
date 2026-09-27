"""The prepared-protocol census's view of D source through libdparse (task 5330).

The census (`tools/check_prepared_protocol.py`, `tools/prepared_writer_census.py`)
used to find brace pairs, unittest blocks and declarations with its own
character scanner, which loses sync on a backtick string holding `"`, an
r-string ending in `\\`, a nested `/+ +/`, a `unittest {` written inside a
comment, and `unittest // note` with its `{` on the next line -- all five
measured on this tree by `tools/dspans/compare.py`. This module answers those
questions from `tools/dspans` (a libdparse-based span printer) instead.

BUILD AND CACHE. The binary is built on first use with `dub build` and kept
under `$XDG_CACHE_HOME/vibe3d/dspans/<key>/` (default `~/.cache`), where the
key hashes the package's `dub.json` (which pins libdparse EXACTLY) and every
file under its `source/`. A build that cannot run -- no `dub`, no network for
the first libdparse fetch, a compile error -- is a LOUD failure of the census:
there is deliberately no fallback to the old scanner, because a census that
silently changes its lexer is the defect this replaced.

OFFSETS are Unicode code points (a Python `str` index); see
`tools/dspans/source/app.d`, "UNITS".
"""
from __future__ import annotations

import atexit
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

try:
    import select  # POSIX pipes; on Windows replies are read without a timeout
    if os.name == "nt":
        select = None
except ImportError:
    select = None

try:
    import fcntl  # POSIX; on Windows the build is unlocked and the install is still atomic
except ImportError:
    fcntl = None

PACKAGE = pathlib.Path(__file__).resolve().parent
EXE_NAME = "dspans.exe" if os.name == "nt" else "dspans"
CACHE_ROOT = pathlib.Path(os.environ.get("XDG_CACHE_HOME") or pathlib.Path.home() / ".cache") \
    / "vibe3d" / "dspans"


def _fail(message, remedy="fix the build (`dub build --force --root tools/dspans`)"):
    raise SystemExit("dspans: " + message + "\n  The census has NO fallback to its old "
                     f"scanner; {remedy}.")


# A hung dspans must not hang the gate: each reply must arrive within this
# many seconds (the largest text the census sends parses in well under 1 s).
REPLY_TIMEOUT = float(os.environ.get("VIBE3D_DSPANS_TIMEOUT", "60"))


def cache_key():
    digest = hashlib.sha256()
    files = [PACKAGE / "dub.json"] + sorted((PACKAGE / "source").rglob("*.d"))
    for path in files:
        digest.update(path.relative_to(PACKAGE).as_posix().encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()[:24]


def binary():
    """The cached dspans binary for the current sources, built if absent."""
    exe = CACHE_ROOT / cache_key() / EXE_NAME
    if exe.exists():
        return exe
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    with open(CACHE_ROOT / "build.lock", "w") as lock:
        if fcntl is not None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        if exe.exists():
            return exe
        try:
            # --force: dub decides "up to date" by timestamps, so without it a
            # stale bin/dspans could be installed under a key that names
            # different sources. A cache miss therefore always compiles.
            run = subprocess.run(["dub", "build", "--force", "-q", "--root", str(PACKAGE)],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        except FileNotFoundError:
            _fail("`dub` is not on PATH, so tools/dspans cannot be built")
        built = PACKAGE / "bin" / EXE_NAME
        if run.returncode or not built.exists():
            _fail(f"`dub build --root {PACKAGE}` failed (exit {run.returncode}):\n" + run.stdout)
        exe.parent.mkdir(parents=True, exist_ok=True)
        staging = exe.with_name(EXE_NAME + f".tmp{os.getpid()}")
        try:
            shutil.copy2(built, staging)
            os.replace(staging, exe)
        finally:
            if staging.exists():
                staging.unlink()
    return exe


class Spans:
    """One text's spans. `parsed` is False for a lex-only answer."""

    def __init__(self, rec, parsed):
        self.parsed = parsed
        self.brace_close = {o: c for o, c in rec["braces"]}
        self.paren_close = {o: c for o, c in rec["parens"]}
        self.unmatched = set(rec["unmatched"])
        self.comments = [tuple(c) for c in rec["comments"]]
        self.strings = [(s, e) for s, e, _k in rec["strings"]]
        self.aggregates = rec["aggregates"]
        self.functions = rec["functions"]
        self.unittests = rec["unittests"]
        self.version_unittests = rec["versionUnittest"]
        self.lex_errors = rec["lexErrors"]
        self.parse_errors = rec["parseErrors"]


class _Server:
    def __init__(self):
        self.proc = None
        self.cache = {}
        self.requests = 0

    def _start(self):
        exe = binary()
        self.proc = subprocess.Popen([str(exe), "--serve"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE)
        atexit.register(self.close)

    def close(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.wait()

    def spans(self, text, parse):
        key = hashlib.sha1(text.encode("utf-8", "surrogatepass")).digest()
        hit = self.cache.get(key)
        if hit is not None and (hit.parsed or not parse):
            return hit
        if self.proc is None:
            self._start()
        data = text.encode("utf-8", "surrogatepass")
        try:
            self.proc.stdin.write(f"{'P' if parse else 'L'} {len(data)}\n".encode() + data)
            self.proc.stdin.flush()
            if select is not None:
                ready, _w, _x = select.select([self.proc.stdout], [], [], REPLY_TIMEOUT)
                if not ready:
                    self.proc.kill()
                    _fail(f"the --serve process gave no reply within {REPLY_TIMEOUT:g} s "
                          f"(a {len(data)}-byte text); killed it",
                          "reproduce with `tools/dspans/bin/dspans <file>` and fix dspans")
            line = self.proc.stdout.readline()
        except BrokenPipeError:
            line = b""
        if not line:
            _fail(f"the --serve process died (exit {self.proc.poll()}) on a "
                  f"{len(data)}-byte text",
                  "reproduce with `tools/dspans/bin/dspans <file>` and fix dspans")
        self.requests += 1
        sp = Spans(json.loads(line), parse)
        self.cache[key] = sp
        return sp


_SERVER = _Server()


def spans(text, parse=False):
    return _SERVER.spans(text, parse)


def request_count():
    return _SERVER.requests


# ---------------------------------------------------------------------------
# The census's questions, with the contracts of the primitives they replace
# ---------------------------------------------------------------------------
def balanced(text, start):
    """Offset after the `}` paired with the `{` at start - 1 (the old
    `_balanced` contract: callers pass the offset just past the brace).
    ValueError("unbalanced D source") when that `{` has no partner; a
    ValueError with the same prefix when start - 1 is not a `{` TOKEN at all
    (the character sits inside a comment or a literal, or is not a brace)."""
    sp = spans(text)
    open_pos = start - 1
    close = sp.brace_close.get(open_pos)
    if close is not None:
        return close + 1
    if open_pos in sp.unmatched:
        raise ValueError("unbalanced D source")
    raise ValueError(f"unbalanced D source: offset {open_pos} is not a `{{` token")


def balanced_parentheses(text, open_pos):
    """Offset after the `)` paired with the `(` at open_pos."""
    if open_pos >= len(text) or text[open_pos] != "(":
        raise ValueError("expected opening parenthesis")
    sp = spans(text)
    close = sp.paren_close.get(open_pos)
    if close is not None:
        return close + 1
    if open_pos in sp.unmatched:
        raise ValueError("unbalanced D call expression")
    raise ValueError(f"unbalanced D call expression: offset {open_pos} is not a `(` token")


def unittest_ranges(text, with_version=False):
    """[keyword, `}` + 1) of every `unittest` block and, with with_version,
    of every braced `version(unittest)` true branch (from `version`)."""
    sp = spans(text, parse=True)
    ranges = [tuple(u["span"]) for u in sp.unittests]
    if with_version:
        ranges += [(v["span"][0], v["trueBody"][1]) for v in sp.version_unittests if v["trueBody"]]
    return ranges


def outermost(ranges):
    out = []
    for s, e in sorted(ranges):
        if out and s < out[-1][1]:
            continue
        out.append((s, e))
    return out


def aggregates(text):
    return spans(text, parse=True).aggregates


def functions(text):
    return spans(text, parse=True).functions
