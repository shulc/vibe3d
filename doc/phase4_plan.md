# Phase 4 Plan — Variant A: generic `tool.*` + MODO script compatibility

## Goals

1. **Internal architecture**: one noun per operation. `BevelTool` becomes the canonical owner of bevel geometry and parameters. `MeshBevel` / `MeshPolyBevel` Command classes are deleted.
2. **Generic dispatch**: built-in commands `tool.set` / `tool.attr` / `tool.doApply` / `tool.reset` work for any Tool via an ILxTool-style contract.
3. **MODO script compatibility**: argstring parser (`name:value`) + line-by-line script runner. `mesh.bevel width:0.1 mode:offset` works identically to MODO's `lx.eval(...)`.
4. **Wire-format preservation**: existing `tools/modo_diff/cases/*.json` keep working as a test-descriptive format. modo_dump.py-style argstring evals also work. Both surfaces share the same internal dispatch.

## Principles

- Each subphase self-contained: build/tests/modo_diff stay green.
- Argstring and JSON are **dual surface formats** on one internal dispatch — modo_diff cases not rewritten.
- Command names match MODO (`vert.merge`, `mesh.bevel`, `select.element`, ...) — already aligned for current commands.
- Bit-for-bit parameter parity preserved (the contract validated by modo_diff).

---

## Subphase 4.1 — Argstring parser + dual-format `/api/command` + `/api/script`

**Goal:** vibe3d accepts MODO-style argstring alongside JSON. No existing command touched.

**New files:**
- `source/argstring.d` — `parseArgstring(string line) -> (string id, JSONValue params)`. Grammar:
  - `name:value` pairs only (positional args deferred to 4.3).
  - Values: bare identifiers, quoted strings (`"foo bar"`), numbers (int/float with sign), booleans (`true`/`false`), vec3 arrays (`{x,y,z}` — MODO syntax).
  - Skip empty lines and `#` comments → returns null id.

**Changes in `source/http_server.d`:**
- `/api/command` — sniff body: first non-whitespace char `{` → JSON path (current); otherwise argstring path: `parseArgstring` → identical internal dispatch (`commandHandler(id, paramsJson)`).
- New `/api/script` POST — body is multi-line text. Splits on `\n`, parses + executes each non-empty/non-comment line through the same dispatch. Returns `[{line, status, error?}, ...]`. Stops on first error (`?continue=true` to keep going).

**Tests:**
- New HTTP-based test exercising argstring on existing commands.
- Existing 31 tests + modo_diff 15/15 must remain green.

**Metric:** `curl -X POST /api/script -d 'mesh.poly_bevel insert:0.25 shift:0.2'` works identically to the equivalent JSON.

---

## Subphase 4.2 — `BevelParams` struct + Tool headless apply

**Goal:** prep for `MeshBevel` removal. `BevelTool` becomes the canonical owner.

**New struct in `source/bevel.d`:**
```d
struct BevelParams {
    // edge-mode
    float          width = 0.0f, widthR = 0.0f;
    bool           asymmetric = false;
    int            seg = 1;
    float          superR = 2.0f;
    BevelWidthMode mode = BevelWidthMode.Offset;
    MiterPattern   miterInner = MiterPattern.Sharp;
    bool           limit = true;
    // polygon-mode
    float          insertAmount = 0.0f;
    float          shiftAmount  = 0.0f;
    bool           groupPolygons = false;
}
```

**`BevelTool` refactor:**
- `ebWidth`/`ebMode`/`shiftAmount`/... collapsed into a single `BevelParams params_;` field.
- `params()` points at `&params_.field` for each entry.
- Extension to `Param`: int-backed enum support (`Param.enumInt_`) so native D enums (`BevelWidthMode`, `MiterPattern`) round-trip without string proxies.

**New virtual on `Tool`:**
```d
// Apply tool one-shot (headless / scripted path). Default no-op returns false.
// Caller wraps with snapshot pair for undo.
bool applyHeadless() { return false; }
```

**`BevelTool.applyHeadless` override:** dispatches by `*editMode` to edge or polygon variant. Doesn't snapshot itself, doesn't activate gizmo.

**Tests:** existing `test_bevel*` (12) keep working via `mesh.bevel` Command (still alive in 4.2). modo_diff 15/15.

---

## Subphase 4.3 — Generic `tool.*` commands

**Goal:** MODO-style command bridge.

**New commands in `source/commands/tool/`:**
- `ToolSetCommand` — `tool.set <toolId> [arg1:val1 ...]`. Activates tool by id; special arg `off` deactivates. Remaining args injected via `injectParamsInto` on `tool.params()`.
- `ToolAttrCommand` — `tool.attr <toolId> <name> <value>`. Sets one named param on the active (or specified) tool.
- `ToolDoApplyCommand` — `tool.doApply`. Snapshot pre → `activeTool.applyHeadless()` → snapshot post → record on undo.
- `ToolResetCommand` — `tool.reset [<toolId>]`. Resets attrs to defaults.

**Argstring requirement:** these commands take positional args. Parser (4.1) extension: collect positional args separately from named pairs.

**Registration:** `commandFactories["tool.set"]`, `["tool.attr"]`, `["tool.doApply"]`, `["tool.reset"]`.

**Tests:** new `tests/test_tool_set_apply.d` — multi-step sequence via `/api/script`, verify final mesh matches direct `mesh.bevel` invocation.

---

## Subphase 4.4 — `MeshBevel` / `MeshPolyBevel` removal + aliases

**Goal:** one noun per operation. `mesh.bevel` / `mesh.poly_bevel` become aliases that wrap the tool's headless path.

**New adapter `class ToolHeadlessCommand : Command`:**
- Constructor: `(string toolId, ToolFactory factory, ...)`.
- `params()` reads from the wrapped tool instance.
- `apply()`: snapshot pre → `tool.applyHeadless()` → snapshot post.
- `revert()`: restore pre snapshot.

**Registration changes in `app.d`:**
```d
// before
reg.commandFactories["mesh.bevel"]      = () => new MeshBevel(...);
reg.commandFactories["mesh.poly_bevel"] = () => new MeshPolyBevel(...);

// after
reg.commandFactories["mesh.bevel"]      = () => new ToolHeadlessCommand("edge.bevel",    ...);
reg.commandFactories["mesh.poly_bevel"] = () => new ToolHeadlessCommand("polygon.bevel", ...);
```

**Open question:** single `BevelTool` for both modes vs split into `EdgeBevelTool`/`PolygonBevelTool`. Recommend: single `BevelTool` for now, ToolHeadlessCommand passes mode hint via `BevelParams`. Splitting deferred to 4.6.

**Deletions:**
- `source/commands/mesh/bevel.d`
- `source/commands/mesh/poly_bevel.d`
- `MeshBevel` / `MeshPolyBevel` cast blocks in `app.d:setCommandHandler` (legacy path no longer needed — ToolHeadlessCommand exposes `params()`, generic `injectParamsInto` covers it).

**Tests:** `test_bevel*` (12) and `modo_diff` 15/15 are the gate. Bit-for-bit parity must hold.

---

## Subphase 4.5 — Selection commands shim (`select.*`)

**Goal:** close MODO script compatibility — multi-line script with selection + ops works end-to-end.

MODO scripts use:
- `select.typeFrom <vertex|edge|polygon>` — switch EditMode
- `select.drop <type>` — clear selection
- `select.element <type> <action> <indices>` — select elements (action: add/remove/replace)
- `select.convert <type>` — convert selection (vertex → edge, etc.)

Thin command shims wrapping vibe3d's existing selection API. All non-undoable (`isUndoable() => false`).

**Tests:** new `tests/test_modo_script_compat.d` — load multi-line MODO-style script via `/api/script`, verify final geometry/selection.

---

## Subphase 4.6 (optional) — Splitting `BevelTool`

If single `BevelTool` dispatching by `*editMode` becomes a maintenance burden, split:
- `class BevelToolBase` — common gizmo, drag state, snapshot management
- `class EdgeBevelTool : BevelToolBase`
- `class PolygonBevelTool : BevelToolBase`

Registered as `toolFactories["edge.bevel"]` and `toolFactories["polygon.bevel"]`. Not critical for MVP — done when single class breaks down.

---

## Open architectural questions

1. **`tool.attr` storage when no tool is active.** MODO permits `tool.attr` on a "pending" tool before `tool.set`. Implementation: instance created lazily on first `tool.set` or `tool.attr`, cached per-toolId until explicit reset. Detail, doesn't block plan.
2. **Single `BevelTool` vs split.** Single first, split in 4.6 if needed.
3. **Argstring grammar — positional args.** Required for `tool.attr` (4.3); deferred from 4.1 to keep 4.1 small.
4. **`select.delete` / `select.remove` aliases.** Yes — for compat with MODO scripts. Wrap existing `mesh.delete` / `mesh.remove`.
5. **Modo eval mechanics**: line continuation (`\`), variable substitution, `cmds.exec`, etc. Out of scope.

---

## Success metrics

After all subphases:
- `MeshBevel` / `MeshPolyBevel` classes deleted.
- `BevelTool` is the single owner of bevel geometry and parameters.
- MODO script runs: `vert.merge range:fixed dist:0.001` via `/api/script` is identical to JSON `/api/command` path.
- `tool.set <id>; tool.attr ...; tool.doApply` works for any Tool.
- modo_diff 15/15 PASS bit-for-bit (no regression).
- All unit tests green, plus new `test_argstring`, `test_tool_set_apply`, `test_modo_script_compat`.

## Size

Phase 4 ≈ phases 0-3 combined (~1000-1200 LOC). Six commits, one per subphase. Tight scope option: 4.1 + 4.3 first (script-compat win), then 4.2 + 4.4 (internal cleanup), then 4.5 (selection shims). 4.6 on a separate branch.
