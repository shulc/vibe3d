#!/usr/bin/env python3
"""Apply the one known ImFontAtlas ABI correction, rejecting any drift."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
OLD = "bool ImFontAtlas_Build(ImFontAtlas* self)\n{\n    return self->Build();\n}"
NEW = "void ImFontAtlas_Build(ImFontAtlas* self)\n{\n    (void)self->Build();\n}"
if text.count(OLD) != 1 or text.count(NEW) != 0:
    raise SystemExit(
        "ImFontAtlas_Build ABI preimage drift: expected exactly one unpatched "
        f"wrapper, found old={text.count(OLD)} patched={text.count(NEW)}")
patched = text.replace(OLD, NEW)
if patched.count(NEW) != 1 or patched.count(OLD) != 0:
    raise SystemExit("ImFontAtlas_Build ABI substitution was not exactly one")
path.write_text(patched)
