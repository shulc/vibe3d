# This directory is retired (task 4052). Do not add a fixture here.

It held 73 `.d` files whose contract was that the compiler must REJECT them:
66 stated that a prepared token is not copyable, 7 that a prepared-effect field
shape is not owned. Nothing compiled them except
`tools/check_prepared_protocol.py`, which launched one `dmd -c` per file.
Measured on the gate host 2026-09-04, with `dmd` behind a timing wrapper: 65 of
those compiles cost **21.5 s of the scanner's 39.9 s wall**, and the scanner is
paid on every full `./run_test.d`.

Both properties are one `static assert` in D, so they moved to
**`tests/unit/prepared_tool_transition_test.d`** — `!__traits(isCopyable, T)`
over a named census of all 134 prepared tokens (the fixtures covered 76 of
them), and `!__traits(compiles, requirePreparedField!T)` for the seven shapes.
The assertions compile with the `tests` configuration. The lightweight Python
boundary check only verifies that the token module roster still matches the
production source tree; it does not pin assertion text or compiler diagnostics.

A new fixture here would have no compiler caller. Use
`static assert(!__traits(compiles, ...))` in a D test instead. The boundary
check rejects stray `.d` fixtures in this retired directory.
