"""Contract cells for the prepared-protocol census's dspans-backed primitives.

Task 5330. The census's own gates never exercise the edge cases of the
contracts its primitives inherited (an unpaired `{`, a `{` in a comment, a
`version(unittest)` branch, an interface nested in a class, a private overload,
an ambiguous declaration, nested unittests, the innermost of two aggregates):
mutating any of those left the census green (sweeps of 2026-09-27, C2..C14 and
the review's P1..P7). So the census calls `run()` at its end and fails with the
first cell's message; `tools/dspans/compare.py --controls` runs the same cells.

Every cell calls the function the census calls -- passed in by the census --
never a stand-in built here. Cost: ~0.06 s.

`production_lexer_census()` is the other half of the contract dspans states in
its header: a text with lexer diagnostics must not be trusted silently. The
census reads mutants it builds itself (deliberately invalid D, e.g. a `/*`
left open), so the refusal is applied to the TREE's files, where a new
diagnostic means libdparse mis-reads valid D (or the file is broken) and the
census's spans for it cannot be trusted.
"""
import dspans_client

# Known libdparse defect on valid D: `#version 330 core` inside a `q{}` token
# string (GLSL sources) lexes as "Invalid identifier" -- dmd accepts the file.
# The token-string span itself is right, so the census's answers for this file
# are unaffected; any OTHER file, or a different count here, is a refusal.
KNOWN_LEX_ERRORS = {"source/subpatch_osd.d": 4}

# Population floor for cells(), measured; enforce() refuses any other count, so
# a deleted cell reddens the census itself (review round 3, M1).
CONTRACT_CELLS = 21


def production_lexer_census(root):
    """Failures: tree files under source/ whose lexer diagnostics differ from
    KNOWN_LEX_ERRORS, and any file with a parse error."""
    found, parse = {}, []
    files = sorted((root / "source").rglob("*.d"))
    for path in files:
        rel = path.relative_to(root).as_posix()
        sp = dspans_client.spans(path.read_text(), parse=True)
        if sp.lex_errors:
            found[rel] = len(sp.lex_errors)
        if sp.parse_errors:
            parse.append(f"{rel}: {sp.parse_errors[0]}")
    failures = []
    if len(files) < 500:
        failures.append(f"dspans lexer census read only {len(files)} files under source/ "
                        "(measured 577 on 2026-09-27)")
    if found != KNOWN_LEX_ERRORS:
        failures.append(f"dspans lexer diagnostics on tree files {found}, expected exactly "
                        f"{KNOWN_LEX_ERRORS}: the census cannot trust its spans for a file "
                        "libdparse does not lex cleanly")
    if parse:
        failures.append("dspans parse errors on tree files: " + "; ".join(parse[:5]))
    return failures


def _raised(fn, *args):
    try:
        return ("returned", fn(*args))
    except ValueError as error:
        return ("ValueError", str(error))


def _value(fn, *args):
    """fn(*args), or a description of what it raised: a cell reports a broken
    primitive as a cell failure, never as a traceback out of the census."""
    try:
        return fn(*args)
    except Exception as error:  # noqa: BLE001 -- reported as the cell's value
        return f"<raised {type(error).__name__}: {error}>"


def cells(writer, census):
    """(label, got, want) for every contract cell. `writer` is the
    prepared_writer_census module, `census` the census's own namespace (or any
    mapping holding its `d_declaration_span` and `without_unittests`)."""
    out = []
    # The four inputs of the card's table, through the census's _balanced.
    for label, text in (
            ("backtick string", "void f() { auto s = `a\"b`; }\n"),
            ("r-string ending in a backslash", "void f() { auto s = r\"C:\\\"; }\n"),
            ("nested comment holding `}`", "void f() { /+ a /+ b +/ } +/ int x; }\n"),
            ("token string", "void f() { auto s = q{ if (a) { b(); } }; int y; }\n")):
        out.append((f"_balanced over a {label}",
                    _raised(writer._balanced, text, text.index("{") + 1),
                    ("returned", len(text) - 1)))
    out += [
        ("_balanced: unpaired `{` raises the old message",
         _raised(writer._balanced, "{ {", 1), ("ValueError", "unbalanced D source")),
        ("_balanced: a `{` inside a comment is not a brace",
         _raised(writer._balanced, "// {\n{ }", 4)[0], "ValueError"),
        ("_balanced_parentheses: pairs by token, not by character",
         _raised(writer._balanced_parentheses, 'f(")", x)', 1), ("returned", 9)),
        ("_mask_unittests: version(unittest) branch blanked",
         _value(writer._mask_unittests, "version(unittest) { int x; }\nint y;"),
         " " * len("version(unittest) { int x; }") + "\nint y;"),
        ("_aggregate: an interface is not a class/struct",
         _value(writer._aggregate, "class C { interface J { int x; } }", 26), "C"),
        ("_aggregate: the INNERMOST aggregate",
         _value(writer._aggregate, "class C { struct S { int x; } }", 21), "S"),
        ("_function_at: the INNERMOST function",
         _value(writer._function_at, "void f() { void g() { int x; } }", 22), "g"),
        ("_private_function_body: only the private overload",
         _value(writer._private_function_body,
               "void helper() { a(); }\nprivate void helper(int) { b(); }", "helper"),
         " b(); "),
        ("d_declaration_span: an ambiguous name has no span",
         _value(census["d_declaration_span"],
               "struct A { struct S { } }\nstruct B { struct S { } }", "struct", "S"),
         None),
        ("d_declaration_span: a class only inside q{} is not declared",
         _value(census["d_declaration_span"], "enum s = q{ class Fake { } };\nclass Real { }\n",
               "class", "Fake"),
         None),
        ("d_declaration_span: starts at the first attribute",
         _value(census["d_declaration_span"], "private final class K { }", "class", "K"), (0, 25)),
        ("without_unittests: the OUTERMOST block is cut once",
         _value(census["without_unittests"], "unittest { struct S { unittest { } } }\nint x;\n"),
         "\nint x;\n"),
        ("without_unittests: `unittest // note` then `{` is a unittest",
         _value(census["without_unittests"], "unittest // note\n{ x(); }\nint y;"), "\nint y;"),
    ]
    # dspans itself: the three version(unittest) forms, lexer diagnostics and a
    # body the parser invents by error recovery.
    vtext = ("version(unittest) { int a; }\nversion (unittest):\nint b;\n"
             "void f() { version(unittest) { g(); } }\n")
    stmt = vtext.index("version(unittest) { g")
    out.append(("dspans versionUnittest spans (block, colon, statement)",
                [(v["span"][0], tuple(v["trueBody"]) if v["trueBody"] else None)
                 for v in dspans_client.spans(vtext, parse=True).version_unittests],
                [(0, (vtext.index("{"), vtext.index("}") + 1)),
                 (vtext.index("version (unittest):"), None),
                 (stmt, (vtext.index("{", stmt), vtext.index("}", stmt) + 1))]))
    out.append(("dspans reports an unterminated string",
                bool(dspans_client.spans('auto s = "abc\n').lex_errors), True))
    out.append(("dspans reports an unterminated comment",
                bool(dspans_client.spans("/* open\nint x;\n").lex_errors), True))
    out.append(("dspans prints no body the parser invented by recovery",
                [a["body"] for a in dspans_client.spans(
                    "class A { void f( { int x = ; }\n", parse=True).aggregates],
                [None]))
    return out


def run(writer, census, root=None):
    """Failure messages, empty when every cell holds."""
    failures = [f"census contract cell failed: {label}: got {got!r}, want {want!r}"
                for label, got, want in cells(writer, census) if got != want]
    if root is not None:
        failures += production_lexer_census(root)
    return failures


def enforce(writer, census, root):
    """The census's call: exit with every failure, else return the number of
    cells that held (the census prints it in its PASS line, so the call cannot
    be dropped without the line changing)."""
    failures = run(writer, census, root)
    if failures:
        raise SystemExit("\n".join(failures))
    n = len(cells(writer, census))
    if n != CONTRACT_CELLS:
        raise SystemExit(f"census contract cells: {n} ran, expected {CONTRACT_CELLS}")
    return n
