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

A file here without the `_test` suffix is a **harness** shared by the test
modules around it (`census_gate.d`, `ui/headless_panel.d`), not a mirror of a
`source/` module.

## Driving an ImGui widget (task 0870)

`ui/headless_panel.d` submits a panel body into a real ImGui context with a
display size and an input queue and nothing else — no window, no GL, no display
server — and drives its widgets with the same `ImGuiIO::AddXxxEvent` calls the
SDL2 backend makes: hover, press, drag, ctrl+click, type, Enter. Rows are
addressed by **index in submission order**, off ImGui's own layout cursor and
frame pitch, so nothing here carries a pixel constant.

It exists because a whole class of paths — anything whose input begins in a
widget — had no automated lane at all: `/api/play-events` synthesises SDL events
with no `windowID` (which the ImGui backend requires), `--test` drops real input,
and `/api/toolprops/ids` records which rows exist, not what typing into one does.
Task 0801 measured what that costs — a panel whose slider wrote a value the apply
never read, shipped for two months behind two green gates.

`ui/transform_panel_widget_test.d` is the worked example: it types `2.0` into the
Scale X row and asserts the mesh. About 0.4 ms per gesture.

## The census gate (task 0835)

`census_gate.d` counts `unittest` blocks and assertion tokens over
`source/` ∪ `tests/unit/` and fails the run when that count falls below the
highest this lane has already reached, unless a line in `census_ledger.txt`
accounts for the loss. It exists because task 0706 destroyed **279 blocks and
1492 assertions** behind a clean build and 179 passing modules; the only thing
that noticed was a human counting.

What it costs you:

| you are doing | what the gate asks |
|---|---|
| adding tests | nothing — growth is free, no number to bump |
| moving a block between files, splitting a module | nothing — the count is a sum over both roots, so a move is invisible |
| editing a test | nothing — only the count matters, not the text |
| **deleting tests** | one appended line in `census_ledger.txt` saying how many and why |

The last row is the whole ceremony. The numbers have to close exactly: the
failure message prints the shortfall it still sees and names the files that
lost blocks, so under-declaring stays red.

The baseline is git, not a checked-in number — deliberately. A stored total
would be one line every lane rewrites, which is a rebase conflict per lane; and
a total refreshed only sometimes silently accumulates slack until it stops
firing. Counting the lane's own revisions with the same scanner has neither
problem. Where there is no git branch point to compare against (a tarball), the
gate prints a `SKIPPED` line to stderr rather than passing quietly.

To count a tree by hand, or a historical one:

```bash
rdmd -version=CensusTool tests/unit/census_gate.d .                  # working tree
rdmd -version=CensusTool tests/unit/census_gate.d . --rev <sha>      # any revision
rdmd -version=CensusTool tests/unit/census_gate.d . --per-file       # per file
```
