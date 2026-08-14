# `tests/unit/` — module unittest blocks that live OUTSIDE `source/`

This directory is compiled **only** by the `tests` dub configuration —
**`dub test --config=tests`**. It is not in `sourcePaths` of `modeling` /
`modeling-noai` / `with-render`, so nothing here ever reaches a shipped binary.

**Always pass `--config=tests`.** A bare `dub test` builds the *default*
configuration (`modeling`), which does not include this directory: it goes
green over fewer tests instead of failing. Two things in the run's own output
tell you which one you got — the binary name (`Running vibe3d-test-tests` vs
`vibe3d-test-modeling`) and the module count druntime prints at the end
(`N modules passed unittests`). The configuration is deliberately *not* named
`unittest`: dub treats that one name specially, using the configuration
verbatim with no test-main injection, which builds and runs the editor binary
itself. See the `_comment-name` note in `dub.json`.

Do not confuse the two test systems:

| what | where | how it runs |
|---|---|---|
| **module unittests** — `unittest { }` blocks over the public API | `source/**` *and* `tests/unit/**` | `dub test` |
| **HTTP integration tests** — one binary per file, drives a live `vibe3d --test` | `tests/test_*.d` | `./run_test.d` |

`run_test.d` builds its own binaries from `dub describe --config=modeling`, so
it never sees this directory — that is deliberate.

## What may move here

A `unittest` block can move out of `source/x.d` into `tests/unit/x_test.d`
**only if it compiles against the public API of `x`**. A block that reads or
writes a `private` member stays where it is; widening visibility to satisfy a
file move is not an acceptable trade (task 0706).

Naming: `tests/unit/<module_path>_test.d` mirroring the `source/` layout, with
`module tests.unit.<...>_test;` — the directory is a source root, so the module
name starts at `tests.unit`.
