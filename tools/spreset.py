#!/usr/bin/env python3
"""Reset Emscripten's stack on the simulated main() unwind.

This deliberately patches two exact generated-code seams.  A toolchain drift
is an error, rather than silently turning the reset lane into the normal lane.
"""
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
js = source.read_text()
anchor = "  var entryFunction = _main;\n"
replacement = anchor + "  var __vibeMainStack = stackSave();\n"
catch = "  } catch (e) {\n    return handleException(e);\n"
reset_catch = "  } catch (e) {\n    stackRestore(__vibeMainStack);\n    return handleException(e);\n"
if js.count(anchor) != 1 or js.count(catch) != 1:
    raise SystemExit("SPRESET-INJECTION generated callMain seam changed")
js = js.replace(anchor, replacement).replace(catch, reset_catch)
output.write_text(js)
print("SPRESET-INJECTION stackSave=1 stackRestore=1")
