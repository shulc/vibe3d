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
That census is paid by `dub test --config=tests`, which compiles the module
anyway, and it is checked in both directions: the D side asserts the property,
`token_census_gate` in the scanner checks that the D side's module list still
matches the `.d` files on disk — the half a compiler cannot see.

**A new fixture placed here would have no caller and would rot green.** That is
why `token_census_gate` refuses any `*.d` in this directory by name. If you need
to state that something must not compile, state it as
`static assert(!__traits(compiles, ...))` beside the census in that test file.
