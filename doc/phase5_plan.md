# Phase 5 Plan — MODO-style command history (argstring + replay)

## Goals

After phase 4, vibe3d accepts MODO-style scripts on the surface but history shows only short labels (`"Edge Bevel"`, `"bevel"`). Phase 5 brings history up to MODO's model:

1. **Each undo entry stores the full argstring** of the actual invocation, not just a label.
2. **Default values are hidden** in the argstring (only user-changed params shown).
3. **History is replayable** — clicking an entry re-executes it; the history doubles as a macro recording.
4. **Labels become localizable / context-aware** — derived from the command + active args.

What we explicitly DO NOT do in this phase:
- True i18n (`@table@key@` lookup machinery). Labels remain English strings.
- Block grouping (`BlockBegin/End` for multi-command transactions). Each Command remains one entry.
- Generic refire — the `BevelTool`-style manual snapshot-pair pattern stays as is.

## Reference

MODO's model lives in `lxcommand.h:280-292` (VALUE_SET flag), `:2400-2487` (block / refire). The phase 4.5 doc captures the mapping in detail.

## Principles

- Each subphase self-contained; build/tests/modo_diff stay green.
- HistoryEntry shape changes once (5.3); subsequent phases extend without further migration.
- Argstring serializer is the dual of phase 4.1's parser — round-trip is the test.
- Replay reuses the same dispatch path as `/api/script` — no new internal codepath.

---

## Subphase 5.1 — VALUE_SET tracking via value-vs-default comparison

**Goal:** know which Params are "user-set" vs "still default" without adding a parallel bookkeeping bool per field.

**Decision:** compute "is set" on demand by comparing the live storage value against the Param's recorded `default_`. Cheap, no new state, no risk of drift between flag and value. Edge case — user who explicitly sets a value equal to the default is treated as "not set" — acceptable, matches user intuition for history display.

**Implementation in `source/params.d`:**

```d
/// Returns true when the parameter's live storage value differs from the
/// default recorded by the factory. Used by toArgstring() to decide which
/// params to emit (default-equal params are omitted, matching MODO's
/// VALUE_SET semantics).
bool isUserSet(const ref Param p);
```

Logic per kind:
- `Bool` — `*p.bptr != p.default_.b`
- `Int` — `*p.iptr != p.default_.i`
- `Float` — `(*p.fptr != p.default_.f) && !(isNaN(*p.fptr) && isNaN(p.default_.f))` — NaN handled explicitly
- `Enum` — `*p.sptr != p.default_.s`
- `String` — `*p.sptr != p.default_.s`
- `Vec3_` — component-wise compare
- `IntEnum` — `*p.iePtr != p.default_.i`

No changes to existing commands or schema. Inline unittest for each kind.

**No tests added at integration level** — exercised in 5.2.

---

## Subphase 5.2 — Argstring serializer

**Goal:** dual of phase 4.1's `parseArgstring`. Given a Command (or `Param[]`), emit the canonical MODO-style argstring of its current state.

**New function in `source/argstring.d`:**

```d
/// Render `params` as a MODO-style argstring fragment (just the
/// "name:val name:val ..." part — no command name).
/// Skips params for which isUserSet returns false.
string serializeParams(Param[] params);

/// Convenience: full line with command name prefix.
string serializeCommand(string commandId, Param[] params);
```

Per-kind formatting:
- `Bool` → `true` / `false`
- `Int` → decimal
- `Float` → `%g` for compactness; round-trip via parser
- `String` / `Enum` → bareword if no whitespace/special chars, else `"quoted"` with `\"` / `\\` escapes
- `Vec3_` → `{x,y,z}` (no spaces, matches parser)
- `IntEnum` → wireTag from matching `IntEnumEntry`

**Round-trip property:** `parseArgstring(serializeCommand(id, params))` reproduces the same name+params object. Inline unittest verifies for each kind plus mixed-kind cases.

**No history changes yet** — purely a serialization helper. Existing tests stay green.

---

## Subphase 5.3 — HistoryEntry: command + args, not just label

**Goal:** record the full argstring on every command commit; expose it via `undoLabels()` (renamed) and over `/api/history`.

**Changes in `source/command_history.d`:**

```d
struct HistoryEntry {
    string  label;        // human-readable display (cmd.label())
    string  args;         // canonical argstring rendered at record time
    string  commandName;  // cmd.name() — used for replay dispatch
    string  commandId;    // alias of commandName, kept for clarity
    Command cmd;          // backing instance (for revert/redo)
    // ... existing fields preserved
}
```

`record(cmd)` becomes:

```d
HistoryEntry e;
e.label       = cmd.label();
e.commandName = cmd.name();
e.args        = serializeParams(cmd.params());   // empty for cmds without schema
e.cmd         = cmd;
undoStack ~= e;
```

Existing `undoLabels()` / `redoLabels()` retain their signature for backward compat — they now compose `label + " " + args` (with args trimmed if empty).

**Display format options:**
- `"Edge Bevel  width:0.1 mode:offset"` (label + args)
- `"mesh.bevel width:0.1 mode:offset"` (commandName + args)
- `"Edge Bevel"` (label only when args empty)

Pick the first — most informative. Test fixture verifies the rendered string for one bevel and one vert.merge invocation.

**HTTP `/api/history` payload extends:** existing endpoint adds `args`/`commandName` per entry. Backward compat: existing fields preserved.

**Tests:**
- `tests/test_history_format.d` — invoke `mesh.bevel`, verify `/api/history` entry has expected `args` + `commandName`.
- Existing `test_undo_redo` keeps working unchanged (snapshot-based undo path untouched).

---

## Subphase 5.4 — Argstring labels for tool-driven commands

**Goal:** make labels for `ToolHeadlessCommand`, `mesh.move_vertex`, `ToolDoApplyCommand`, etc. as descriptive as the original `MeshBevel`. Now feasible because we have `cmd.params()` and `serializeParams` available.

**Approach:**
- `ToolHeadlessCommand.label()` — returns `"Edge Bevel"` / `"Polygon Bevel"` based on `*editMode`. Same convention as the legacy `MeshBevelEdit` interactive snapshot label.
- `MeshMoveVertex.label()` — returns `"Move Vertex"`.
- `ToolDoApplyCommand.label()` — captures `host.getActiveToolId()` at apply time into a field, returns `"Apply " ~ toolId`.

Combined with 5.3's `args` string, history reads naturally:
```
Edge Bevel  width:0.1 mode:offset
Move Vertex from:{-0.5,-0.5,-0.5} to:{0.4,-0.5,-0.5}
Merge Vertices range:fixed dist:0.001
Apply bevel
```

**Tests:** extend `test_history_format` with these scenarios.

---

## Subphase 5.5 — Replay from history

**Goal:** any past entry's argstring can be re-executed against the current state.

**New `CommandHistory` API:**

```d
/// Re-execute the argstring of the entry at `undoStack[index]`. Goes
/// through the same dispatch as /api/script — parses argstring, looks
/// up command by name, injects params, runs apply(), records as a new
/// undo entry. The original entry is unchanged.
bool replayEntry(size_t index);
```

Implementation:
- Look up `undoStack[index]` → get `commandName + args`.
- Build a single line: `commandName + " " + args` (works because `args` already in argstring form).
- Call same `commandHandler` that HTTP path uses (a delegate stored on `CommandHistory`).

**HTTP endpoint `/api/history/replay {"index": N}`:** thin wrapper.

**Tests:** `tests/test_history_replay.d`:
1. `mesh.move_vertex` from `(-0.5,-0.5,-0.5) → (0.4,-0.5,-0.5)`.
2. Mesh state has v0 at `(0.4,-0.5,-0.5)`.
3. `POST /api/history/replay {"index":0}` (or last entry).
4. Same op replays — but `from` no longer matches (vertex at `0.4,...` already), apply returns false. Edge case: replay validates against current state, gracefully no-ops if inputs don't match. Document this.

Replay across heterogeneous mesh states is tricky (selection commands aren't on the undo stack so a replayed bevel may target different elements). For phase 5.5 we accept this — replay is best-effort, useful as a "redo with edits" or macro source. Robust replay would require recording selection state per entry, which is its own future phase.

---

## Subphase 5.6 (optional) — UI: history panel shows args

**Goal:** floating History panel displays the new `label + args` format; click-to-replay button per entry.

Existing panel (`source/app.d:2233+`) renders bullet list of `undoLabels()` strings. After 5.3, those strings already include args. Just visual tweak: monospace font for args portion, optional collapse toggle for long argstrings.

Click-to-replay: button per entry that calls `history.replayEntry(i)`.

**Skippable** — backend parts (5.1-5.5) deliver the value; UI polish optional.

---

## Open architectural questions

1. **Selection state in entries.** Replaying a bevel against a different selection produces different geometry. MODO entries don't store selection either — replay is "execute against current state". This phase follows MODO. If we later want robust macros, store SelectionSnapshot per entry.
2. **Float formatting precision.** `%g` is compact but lossy across round-trip for high-precision floats. For a 3D mesh editor, single-precision floats and 6-7 significant digits are fine. If round-trip diverges, switch to `%.9g`.
3. **`mesh.vertex_edit` arrays.** Currently outside the schema (legacy cast block in `setCommandHandler`). Its history args would be huge if rendered (`indices:{1,5,7} before:{...} after:{...}`). Decision: skip serialization for params not in schema — entry has empty args, label still says "Edit". Acceptable.
4. **History command store.** `Command` instance is held in HistoryEntry for revert. After replay, the original instance in history is unchanged — replay creates a new instance via factory. Storage / lifecycle is the same as today.

---

## Success metrics

- Every undoable command produces a history entry with `label + args` matching what the user (or a test JSON case) actually invoked.
- Default-valued params do not appear in args (MODO-style minimal serialization).
- `/api/history` JSON gains `args` + `commandName` per entry.
- `POST /api/history/replay {"index":N}` re-executes an entry.
- All current 34 unit tests + 15 modo_diff cases continue to pass.

## Size

Phase 5 ≈ 600-800 LOC across six commits. Rough breakdown:
- 5.1 isUserSet — ~40 lines + tests
- 5.2 serializer — ~150 lines + round-trip tests
- 5.3 HistoryEntry args — ~80 lines (mostly api/history JSON layer)
- 5.4 label fixes — ~30 lines
- 5.5 replay endpoint — ~80 lines + integration test
- 5.6 (optional) UI — ~50 lines

Smallest valuable cut: 5.1 + 5.2 + 5.3 (entry shows args, no replay yet) — ~270 LOC.
