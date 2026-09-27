"""The prepared-protocol census's ORIGINAL lexing primitives, frozen verbatim.

Task 5330 step 3 moved the census's brace, unittest and declaration questions
onto tools/dspans (see dspans_client.py). These are the definitions it replaced,
copied unchanged from tools/prepared_writer_census.py and
tools/check_prepared_protocol.py at 9bf5cbf5, so that tools/dspans/compare.py
can keep comparing the old answers with the census's new ones on every text the
census reads. Nothing in the census imports this module.
"""
import re


def _mask_comments(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/", lambda m: " " * len(m.group()),
                  text, flags=re.S)

def _mask_unittests(text):
    masked = list(text)
    for match in list(re.finditer(r"(?:\bversion\s*\(\s*unittest\s*\)\s*|\bunittest\s*)\{", _mask_comments(text)))[::-1]:
        try: end = _balanced(text, match.end())
        except ValueError: continue
        masked[match.start():end] = " " * (end - match.start())
    return "".join(masked)

def _balanced(text, start):
    depth = 1
    i = start
    quote = None
    comment = None
    while i < len(text) and depth:
        c = text[i]
        if comment == "//":
            if c == "\n": comment = None
        elif comment in ("/*", "/+"):
            close = "*/" if comment == "/*" else "+/"
            if text.startswith(close, i): comment = None; i += 2; continue
        elif quote:
            if c == "\\": i += 2; continue
            if c == quote: quote = None
        elif text.startswith("//", i): comment = "//"; i += 2; continue
        elif text.startswith("/*", i): comment = "/*"; i += 2; continue
        elif text.startswith("/+", i): comment = "/+"; i += 2; continue
        elif c in "\"'": quote = c
        elif c == "{" : depth += 1
        elif c == "}" : depth -= 1
        i += 1
    if depth: raise ValueError("unbalanced D source")
    return i

def _balanced_parentheses(text, open_pos):
    """Return the offset after the parenthesis paired with open_pos."""
    if open_pos >= len(text) or text[open_pos] != "(":
        raise ValueError("expected opening parenthesis")
    depth = 1
    i = open_pos + 1
    quote = None
    comment = None
    while i < len(text) and depth:
        c = text[i]
        if comment == "//":
            if c == "\n": comment = None
        elif comment in ("/*", "/+"):
            close = "*/" if comment == "/*" else "+/"
            if text.startswith(close, i): comment = None; i += 2; continue
        elif quote:
            if c == "\\": i += 2; continue
            if c == quote: quote = None
        elif text.startswith("//", i): comment = "//"; i += 2; continue
        elif text.startswith("/*", i): comment = "/*"; i += 2; continue
        elif text.startswith("/+", i): comment = "/+"; i += 2; continue
        elif c in "\"'": quote = c
        elif c == "(": depth += 1
        elif c == ")": depth -= 1
        i += 1
    if depth: raise ValueError("unbalanced D call expression")
    return i

def _aggregate(text, pos):
    found = "<module>"
    declarations = _mask_comments(text)
    for m in re.finditer(r"\b(?:class|struct)\s+(\w+)[^{;]*\{", declarations[:pos]):
        try:
            if _balanced(text, m.end()) > pos: found = m.group(1)
        except ValueError: pass
    return found

# Project-owned scanner identifier: exact `grep -rl -w _function_at` over the
# SDK tree returned zero files; `caller` is generic call-graph vocabulary there.
def _function_at(text, pos):
    """Name the innermost function declaration containing byte offset pos."""
    found = "<module>"
    declarations = _mask_comments(text)
    pattern = re.compile(
        r"(?m)^[ \t]*(?:[A-Za-z_]\w*[ \t]+)+([A-Za-z_]\w*)\s*"
        r"\([^;{}]*\)\s*[^;{]*\{")
    for match in pattern.finditer(declarations, 0, pos):
        try:
            if _balanced(text, match.end()) > pos:
                found = match.group(1)
        except ValueError:
            pass
    return found


def _private_function_body(text, name):
    """Resolve one private same-module function body by its unqualified name."""
    declarations = _mask_comments(text)
    pattern = re.compile(
        r"(?m)^[ \t]*private[ \t]+"
        r"(?:[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*[ \t]+)+"
        + re.escape(name) + r"\s*\(")
    bodies = []
    for match in pattern.finditer(declarations):
        open_pos = match.end() - 1
        params_end = _balanced_parentheses(text, open_pos)
        body_open = declarations.find("{", params_end)
        declaration_end = declarations.find(";", params_end)
        if body_open < 0 or (declaration_end >= 0 and declaration_end < body_open):
            continue
        body_end = _balanced(text, body_open + 1)
        bodies.append(text[body_open + 1:body_end - 1])
    if len(bodies) != 1:
        raise ValueError(
            f"expression factory helper {name} resolved to {len(bodies)} "
            "private same-module function bodies")
    return bodies[0]


# --- from tools/check_prepared_protocol.py ------------------------------
balanced_source = _balanced

def mask_d_noncode(source):
    """Blank comments and quoted strings while preserving source offsets."""
    pattern = re.compile(
        r'//[^\n]*|/\*.*?\*/|/\+.*?\+/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
        re.S)
    return pattern.sub(lambda match: "".join(
        "\n" if char == "\n" else " " for char in match.group()), source)

def mask_d_comments(source):
    pattern = re.compile(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/", re.S)
    return pattern.sub(lambda match: "".join(
        "\n" if char == "\n" else " " for char in match.group()), source)

def d_declaration_span(source, kind, name):
    """Return one parsed aggregate declaration span, or None on absence/ambiguity."""
    visible = mask_d_noncode(source)
    qualifier = r"(?:\b(?:private|package|protected|public|static|final)\s+)*"
    matches = list(re.finditer(
        qualifier + rf"\b{re.escape(kind)}\s+{re.escape(name)}\b[^{{;]*\{{",
        visible))
    if len(matches) != 1:
        return None
    match = matches[0]
    try:
        return match.start(), balanced_source(source, match.end())
    except ValueError:
        return None


def without_unittests(source):
    result = source
    for match in reversed(list(re.finditer(r"\bunittest\s*\{", result))):
        result = result[:match.start()] + result[balanced_source(result, match.end()):]
    return result
