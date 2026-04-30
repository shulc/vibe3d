# Undo / Redo design plan

Detailed implementation plan for Tier 0 of `feature_roadmap.md`.

## What we're modeling

MODO's behavior (from `Modo902/help/pages/modo_interface/standard_tool_controls.html`,
`modo_interface/viewports/list_info/command_history.html`, and the
official SDK at `LXSDK_661446/include/lxundo.h` / `lxcommand.h`):

- **Command history**: every user-visible action (`tool.attr poly.bevel
  inset 0.15`, `select.element`, `mesh.subdivide`, etc.) is logged as
  an atomic entry visible in the Command History viewport.
- **Undo navigation**: Ctrl+Z / Ctrl+Shift+Z. "All commands that
  change model state can be undone."
- **Tool sessions**: while a tool is active, Tool Properties edits
  and viewport hauls each fire a `tool.attr` (or implicit haul)
  command. Dropping the tool (Q / Space / select another) doesn't
  itself commit anything — the tool just deactivates.
- **Apply button** (on Tool Properties): runs the tool's pipe and
  drops it without keeping it active. Equivalent to "tool drop
  with apply".
- **Reset Tool Attributes** (Ctrl+D): zeroes the tool's params.

Translated to vibe3d:

- Every mutation = one atomic command on the undo stack.
- Each Tool Properties slider change OR each completed drag cycle
  produces ONE command (= one undo entry).
- Modeling ops (`mesh.bevel`, `mesh.poly_bevel`, future
  `mesh.delete`, etc.) are atomic from the user's standpoint and
  go on the stack as one entry each.
- Selection / edit-mode changes — separate path with their own
  small snapshot (lighter than mesh snapshot).

## Validation against the MODO SDK

Reading `LXSDK_661446/include/lxundo.h` and `lxcommand.h` confirms
the design above and adds three concrete refinements:

### MODO's "Refire" pattern == our "live command"

`lxcommand.h:2406-2423`:

> "Some commands are fired many times over and over again as the
> user changes a value. An example of this is the the Move Tool;
> each time the users drags the mouse, the Move Tool fires a new
> AddPosition command... Instead, the Move Tool should fire the
> AddPosition command effectively once with the final value, thus
> resulting in a single entry in the command history."
>
> "This process has been dubbed **Refiring**. On mouse down, a tool
> calls `CmdRefireBegin()`, and on mouse up calls `CmdRefireEnd()`.
> In between it fires commands using `CmdEntryFireArgs()`. **When a
> command is refired, the previous execution is undone just before
> the command is re-executed.**"
>
> "Each successive time `CmdEntryFire...()` is called within a
> refire block, the previously fired command is undone."

So MODO doesn't keep a "snapshot held by the live command" in the
sense I described — instead, each fire UNDOES the previous one and
RE-EXECUTES with the new params. Net stack effect = ONE undo entry
per refire block.

For vibe3d, this maps cleanly onto BevelTool's existing
`revertBevelTopology() + applyBevelTopology()` cycle. Wrap that pair
in a "refire" abstraction:

```d
class CommandHistory {
    private bool refireOpen = false;
    private Command pending;

    void refireBegin() { refireOpen = true; pending = null; }

    void fireRefire(Command cmd) {
        if (refireOpen && pending !is null) pending.revert();
        cmd.apply();
        pending = cmd;
    }

    void refireEnd() {
        if (pending !is null) {
            undoStack ~= pending;
            redoStack.length = 0;
        }
        refireOpen = false;
        pending = null;
    }
}
```

For Tool Properties slider edits (each ImGui DragFloat with
`IsItemDeactivatedAfterEdit`), wrap each edit cycle in
refireBegin/refireEnd. For viewport gizmo drags, wrap in
mousedown/mouseup. Result: each user-perceivable edit cycle = ONE
undo entry, regardless of how many internal `revert+reapply`
oscillations happened.

### Undo state machine (from `lxundo.h`)

MODO has three undo states:

- **`LXiUNDO_INVALID`** — system not accepting undos. State changes
  here are "not generally valid" (= app startup, file load, certain
  internal reconfigurations).
- **`LXiUNDO_ACTIVE`** — normal operation. New undo objects added to
  the stack.
- **`LXiUNDO_SUSPEND`** — state changes happen but are NOT
  recorded. For previews, internal cleanup, animation playback, etc.

Vibe3d should mirror this. Concrete uses:

- **SUSPEND during file load**: loading an LXO replaces the entire
  mesh; undoing the load itself is one entry, but every internal
  step inside the load (vert add, face add) shouldn't be.
- **SUSPEND during apply()-internal mutations**: when a complex
  command does subcommands internally (e.g., `mesh.bevel` calls
  `mesh.weldCoincidentVertices` after-effect), those subcommands
  shouldn't push their own entries.
- **INVALID until ready**: pre-window-shown init pass; suppress any
  accidental command firing.

Add to `CommandHistory`:

```d
enum UndoState { Invalid, Active, Suspend }
UndoState state = UndoState.Active;

// Scoped helpers
struct UndoSuspend { ... } // RAII: state = Suspend on ctor, restore on dtor
```

### Two recording flavors: Apply vs Record (from `lxundo.h:79-89`)

```c
ILxUndoService.Apply(undo_obj):
    fires Forward() to apply the change
    if state==ACTIVE: record it on the stack
    if state==SUSPEND: release without recording

ILxUndoService.Record(undo_obj):
    assumes the change has ALREADY happened
    just registers Reverse() for if user undoes
```

Translation to vibe3d's `Command`:

- `apply()` → MODO's Forward (the operation runs, then the dispatcher
  decides whether to record based on `state`).
- `revert()` → MODO's Reverse.
- `record()` (NEW) → registers a Command that already ran (= the
  legacy bevel command pattern: it mutates `mesh` directly and
  hands a snapshot back to the dispatcher post-fact).

Both paths land at the same `undoStack.push`. The choice is
who runs `apply()`: the dispatcher (`Apply` flavor) or the caller
(`Record` flavor).

### Command flag taxonomy (from `lxcommand.h:3458-3466`)

MODO classifies every command by orthogonal flags:

| Flag | Meaning |
|---|---|
| `LXfCMD_MODEL` | Changes mesh state (geometry, topology, attributes). |
| `LXfCMD_UI` | Changes UI state only (panel layout, selection mode). |
| `LXfCMD_UNDO` = `MODEL \| UNDO_INTERNAL` | Model command, undoable. |
| `LXfCMD_UNDO_UI` = `UI \| UNDO_INTERNAL` | UI command, undoable. |
| `LXfCMD_SANDBOXED` | Runs in sandbox; **never undoable**. |
| `LXfCMD_UNDO_AFTER_EXEC` | Block flag: "undo actions are undone on completion" (post-mode). |

Vibe3d's existing `Command` should grow analogous flags:

```d
abstract class Command {
    enum Flag {
        Mutates        = 1 << 0,  // LXfCMD_MODEL — changes mesh
        Undoable       = 1 << 1,  // LXfCMD_UNDO  — push to stack
        UI             = 1 << 2,  // LXfCMD_UI    — UI-only change
        Sandboxed      = 1 << 3,  // never undoable
    }
    int flags() const { return Flag.Mutates | Flag.Undoable; }
    // existing isUndoable() == (flags & Undoable) != 0
}
```

### Plug-in vs application state separation (`lxundo.h:42-46`)

> "These undo objects should perform changes to the **internal
> plug-in state only**, not the application system state.
> **Application state changes are made with commands which undo
> themselves.**"

For vibe3d this maps to a clean layer separation:

- **Commands undo themselves**: every command's `revert()` is
  responsible for restoring whatever state the command's `apply()`
  changed. The history just calls `revert()` — it doesn't manage
  the snapshot itself.
- **Plugin internal state**: irrelevant for our codebase (no
  plug-in system yet).

So we can drop the idea of a generic "revertPayload" stored opaquely
in the history entry — every command holds its own snapshot
internally and exposes only `apply()` / `revert()`.

### Command blocks (grouping) — from `lxcommand.h:2461-2498`

MODO supports `BlockBegin(name, flags)` / `BlockEnd()` to bundle
multiple sub-commands into ONE undo entry. Useful flags:

- `PRESERVE_SELECTION`: snapshot the selection before the block,
  restore after — block can mutate selection freely without leaking.
- `UI`: block is allowed during refire without disrupting it.
- `UNDO_AFTER_EXEC`: undo actions are undone on completion (used
  by post-mode tools — actions are previews, undone unless
  explicitly committed).

Defer this for vibe3d — useful but Tier 0.4 work. Linear stack +
refire is enough for the first iteration. Add command blocks when
we have a feature that needs atomic composition (e.g., a Symmetry
tool that fires N parallel commands that must all undo together).

## Architecture

### Command lifecycle (extended)

Today `Command` has only `apply()`. Extend with three optional
hooks:

```d
abstract class Command {
    // Existing — runs the operation, returns true on success.
    abstract bool apply();

    // NEW — restore the pre-apply state. Default: no-op (used by
    // commands that don't need undo, e.g. read-only queries). Mesh-
    // mutating commands MUST override this.
    bool revert() { return false; }

    // NEW — true iff this command should be appended to the undo
    // history when apply() returns true. Default true. Override
    // false for read-only commands or non-undoable side effects.
    bool isUndoable() const { return true; }

    // NEW — short human-readable label for the Edit menu and the
    // history viewer ("Bevel edges", "Move 3 verts", "Inset polygons").
    string label() const { return name(); }
}
```

Each mutating command keeps its pre-apply snapshot in instance
fields. Pattern already used by `BevelOp.faceSnaps` / `origVertices`
(in `source/bevel.d`) and `PolyBevelOp.origEdges` / `sharedCorners`
(in `source/poly_bevel.d`). Generalize into a per-command struct;
revert reads it back. The Command instance is OWNED by the history
stack after apply (it's the single source of truth for revert).

### History stack

```d
class CommandHistory {
    private Command[] undoStack;
    private Command[] redoStack;
    private size_t    maxDepth = 200;   // configurable, hard cap to bound RAM

    // Called by app.d's central command dispatcher for every
    // command that comes back from cmd.apply() == true.
    void record(Command cmd) {
        if (!cmd.isUndoable) return;
        undoStack ~= cmd;
        if (undoStack.length > maxDepth) {
            undoStack = undoStack[$ - maxDepth .. $];
        }
        // Any new action invalidates the redo timeline.
        redoStack.length = 0;
    }

    bool undo() {
        if (undoStack.length == 0) return false;
        auto cmd = undoStack[$ - 1];
        undoStack.length -= 1;
        if (cmd.revert()) {
            redoStack ~= cmd;
            return true;
        }
        return false;
    }

    bool redo() {
        if (redoStack.length == 0) return false;
        auto cmd = redoStack[$ - 1];
        redoStack.length -= 1;
        if (cmd.apply()) {
            undoStack ~= cmd;
            return true;
        }
        return false;
    }
}
```

Owned by `app.d` alongside the command registry.

### Tool integration: refire blocks

Direct port of MODO's "refiring" pattern (see `lxcommand.h:2406`).
While a tool is interacting with the user (drag in viewport, drag
in Tool Properties slider), every fresh state IS its own command —
but each new fire UNDOES the previous one before re-executing.
Net stack effect: ONE undo entry per refire block, regardless of
how many sub-fires happened.

**API**:

```d
class CommandHistory {
    void refireBegin();           // open a refire block
    void fire(Command cmd);       // inside refire: undo prev + apply cmd
    void refireEnd();             // close: latest cmd lands on stack
}
```

Outside a refire block, `fire(cmd)` behaves like a plain HTTP
command: apply, push to undo stack.

**Refire boundary triggers** (when tools call refireBegin/End):

1. **Mouse button down** on a drag handle → `refireBegin`.
   **Mouse button up** → `refireEnd`.
2. **Tool Properties slider edit start** (first frame the value
   changes) → `refireBegin`. **Slider release**
   (`ImGui.IsItemDeactivatedAfterEdit()` returns true) → `refireEnd`.
3. **Checkbox / radio button change** in Tool Properties (single
   discrete event) → fire-with-no-block (= 1 command, 1 entry).
4. **Tool deactivation** while a refire block is open (= drag
   abandoned by switching tool / mode) → `refireEnd` first to
   commit the in-progress entry.

Within a session, user actions of the SAME KIND DO NOT coalesce
into one entry across multiple slider releases:

- Drag Width slider, release: 1 entry.
- Drag Inset slider, release: 2nd entry.
- Drag Width again, release: 3rd entry.

This matches MODO's command-history-per-edit-cycle behavior and the
user-stated requirement that each Tool Properties change be its
own undo step.

BevelTool's implementation (refire-based):

```d
class BevelTool : Tool {
    private CommandHistory history;
    private bool refireActive = false;

    // onMouseButtonDown on a drag handle:
    if (!refireActive) {
        history.refireBegin();
        refireActive = true;
    }

    // onMouseMotion (each pixel):
    auto cmd = new MeshBevel(...);
    cmd.setWidth(ebWidth);   // updated value
    history.fire(cmd);       // refire: undo previous, apply new

    // onMouseButtonUp:
    history.refireEnd();
    refireActive = false;
}
```

Inside `history.fire` while the refire block is open, the previous
`MeshBevel` instance's `revert()` is invoked (restoring the
pre-bevel mesh) before the new one's `apply()` runs. So the mesh
moves directly from "state before this drag" → "state with newest
params" — never accumulates multiple bevels. At `refireEnd`, the
latest `MeshBevel` instance lands on the undo stack as the single
entry for this drag.

For Tool Properties slider edits in `drawProperties()`:

```d
ImGui.DragFloat("Width", &ebWidth, 0.005f, 0.0f, 0.0f, "%.4f");
bool active   = ImGui.IsItemActive();
bool deactive = ImGui.IsItemDeactivatedAfterEdit();
bool changed  = active && (ebWidth != prevWidth);
if (active && !refireActive) { history.refireBegin(); refireActive = true; }
if (changed)                  { history.fire(makeBevelCmd()); }
if (deactive)                 { history.refireEnd(); refireActive = false; }
```

Same pattern for every slider; pure cut-and-paste for new tools.

Note: the existing `applyEdgeBevelTopology` / `revertEdgeBevelTopology`
+ `BevelOp` snapshot becomes `MeshBevel.apply()` / `revert()`. The
command instance OWNS the snapshot for the duration of its lifetime
on the undo stack.

### Tool Properties: per-edit granularity

User concern: "при изменении настроек в Tool Properties создается
отдельная команда". With the coalescing model above, EACH separate
slider edit (= one drag, ending in a release) becomes its own
undo entry. Confirmed by ImGui semantics:

```d
ImGui.DragFloat("Width", &ebWidth, 0.005f, 0.0f, 0.0f, "%.4f");
if (ImGui.IsItemDeactivatedAfterEdit()) {
    history.record(liveBevelCmd);
    liveBevelCmd = startNewCmd();   // restart session with current state
}
```

After this commit, the next drag of the SAME slider starts a fresh
command (so it's a separate undo entry).

If user Ctrl+Z after editing Width → Inset → Shift in succession:

| Stack | Entry |
|---|---|
| [3] | Set Shift 0 → 0.15 |
| [2] | Set Inset 0 → 0.10 |
| [1] | Set Width 0 → 0.20 |
| [0] | (initial bevel apply, e.g. Width=0 default) |

Three Ctrl+Z presses revert each property change in reverse order;
fourth Ctrl+Z reverts the initial bevel itself.

### Selection / edit-mode undo

Lightweight: a `SelectionSnapshot` struct captures `editMode`,
`selectedVertices/Edges/Faces` arrays + counters. A
`SelectCommand` wraps any selection mutation and uses the snapshot
for revert.

Coalescing: consecutive selection ops in the same edit mode merge
into one entry. So clicking 5 verts to add to selection produces
ONE undo entry (not 5). Implementation: when recording a new
SelectCommand, if the previous undo entry is a SelectCommand and
the editMode matches AND it was recorded < 1000ms ago, REPLACE its
"after" state instead of pushing a new entry.

Tunable: 1000ms is a heuristic for "active edit". Switch tools or
change edit mode → coalescing window closes.

### HTTP path

For non-interactive `mesh.bevel` etc. via HTTP:

- Each `apply()` returns success → `history.record(cmd)` is called
  by the dispatcher in `setCommandHandler` (`source/app.d`).
- No coalescing — each HTTP call is its own entry.
- Tests can assert undo round-trips by calling `mesh.bevel`, then
  `/api/undo`, then `/api/model` — and getting the original cube
  back.

NEW endpoints:

- `POST /api/undo` → `history.undo()`.
- `POST /api/redo` → `history.redo()`.
- `GET /api/history` → list of (label, timestamp) for current undo
  stack. Useful for tests + Edit menu rendering.

### Memory & performance

Concerns:

1. **Mesh snapshot size**: BevelOp already snapshots
   `origVertices` (Vec3[]) + `origEdges` (uint[2][]) +
   `origSelectedEdges` (bool[]) + `origEdgeOrder` (int[]) +
   `faceSnaps` (only modified faces, not all). Cube = trivial; a
   100k-vert mesh = ~3MB per command. With max stack depth 200
   that's 600MB worst case. **Action**: cap max-depth to ~50
   or compress snapshots (e.g. only diff-store in production
   builds). Keep verbose for dev builds.

2. **Selection snapshot**: bool[] arrays sized to mesh — couple
   of MB per snapshot for 100k-vert meshes. Coalesce aggressively
   (see above) and cap depth.

3. **Coalescing correctness**: the "in-progress live command"
   isn't on the stack yet — it's owned by the tool. If something
   throws between revert+reapply cycles and commit, mesh state
   could leak. Add a `scope(failure)` in tool code that commits
   any live command before propagating exceptions.

## Implementation order

1. **Phase A — `Command.revert()` virtual + history stack.** Add
   the new methods on Command; implement CommandHistory; wire
   Ctrl+Z / Ctrl+Y in app.d. NO tool integration yet — only the
   HTTP path triggers history records. Add `/api/undo`, `/api/redo`,
   `/api/history`.

   Test: `tests/test_undo_http.d` — runs `mesh.subdivide` (cheap)
   via HTTP, undoes, asserts mesh count back to 8/12. Adds basic
   round-trip coverage.

   Effort: 2 days. Touches `source/command.d` (virtual), each
   `commands/mesh/*.d` and `commands/select/*.d` (override
   `revert()`), `source/app.d` (dispatcher + key bindings),
   `source/http_server.d` (3 endpoints).

2. **Phase B — Per-command snapshot/revert audit.** Walk every
   existing command:

   - `mesh.bevel` (`MeshBevel`): snapshot is BevelOp; revert calls
     `revertEdgeBevelTopology(mesh, op)`.
   - `mesh.poly_bevel`: PolyBevelOp + `revertPolyBevel(mesh, op)`.
   - `mesh.subdivide`, `mesh.subdivide_faceted`: snapshot ALL
     (verts/edges/faces/selection) — these are global rebuilds.
   - `mesh.subpatch_toggle`: snapshot `isSubpatch[]`.
   - `mesh.split_edge`: snapshot affected face's vert list +
     edge list around that vert.
   - `mesh.move_vertex`: snapshot the moved vert's old position.
   - `select.*`: SelectionSnapshot.
   - `viewport.fit*`, `file.load`, `file.save`: not undoable
     (`isUndoable` returns false). file.load is a special case —
     replaces the whole mesh; could be undoable if we snapshot
     the whole pre-load state.

   Effort: 3 days. Each command is small but every one needs a
   focused diff + a unit test.

3. **Phase C — Tool live-command integration.** Extend the
   `Tool` base class with `activeLiveCommand` / `commitLiveCommand`.
   Refactor BevelTool first (most complex, sets the pattern).

   - On first user input that triggers `applyEdgeBevelTopology`:
     create the live command, capture snapshot.
   - On parameter changes: revert-snapshot + reapply with new
     params (no stack interaction).
   - On commit boundaries: history.record(liveCmd) + clear.

   Effort: 3 days for BevelTool; 1 day each for Move/Rotate/Scale
   /Box (simpler).

4. **Phase D — Selection coalescing.** Implement the SelectCommand
   pattern for `select.*` commands and the picking path
   (click-to-select). Handle the 1000ms-coalesce window.

   Effort: 2 days.

5. **Phase E — UI + UX polish.** Edit menu (Undo / Redo / Reset
   Tool Attributes). Optional: Command History panel showing the
   stack. ImGui integration. Keyboard shortcuts.

   Effort: 2 days.

**Total: ~2 weeks**, dominated by per-command audit + tool
refactor.

## Test strategy

Adds a new test file template `tests/test_undo_<cmd>.d` for each
mutating command. Each test:

```d
unittest {
    resetCube();              // 8V/6F
    selectFace(0);
    runCommand("mesh.poly_bevel", {insert:0.15, shift:0});
    auto m1 = getModel();     // 12V/10F (or whatever)
    
    runCommand("undo");
    auto m2 = getModel();
    assert(m2.vertices == initialCube.vertices);  // bit-for-bit
    
    runCommand("redo");
    auto m3 = getModel();
    assert(m3.vertices == m1.vertices);           // bit-for-bit
}
```

Plus an integration test that runs a long sequence of mixed
ops with random Ctrl+Z / Ctrl+Y interleaving — fuzzes the
snapshot/revert correctness across the whole command set.

Existing comparisons (blender_diff / modo_diff) don't need to
change: they apply commands fresh on each case and don't
interact with undo. But we add a new flag in the
`run.d` orchestrators for an optional "round-trip via undo"
mode that applies + undoes + asserts equality with the pre-apply
state. Catches commands that forgot to snapshot something.

## Open questions

1. **Live command ownership during exceptions**: if a tool crashes
   mid-edit, the live command's snapshot is lost. Should we
   `scope(failure) commitLiveCommand();` to at least preserve
   what's there, or `scope(failure) liveCmd.revert();` to bail
   to safe state? Lean toward revert for safety; commit if user
   manually re-activates the same tool.

2. **Persistent history across Save/Load**: out of scope for this
   plan. Tier 0.3 in `feature_roadmap.md`.

3. **Linear vs branched history**: linear (any new action wipes
   redo stack) is simpler and matches MODO. Branched ("undo tree")
   is power-user but a separate project. Default: linear.

4. **Memory cap policy**: 50 entries default cap, configurable
   via preferences. With 100k-vert meshes and ~3MB per snapshot
   that's 150MB — acceptable. Larger caps or compressed snapshots
   are a follow-up.

5. **What about `mesh.weldCoincidentVertices`** (called inside
   bevel command after-effect)? It mutates state but is part of a
   parent command's apply. The parent command's snapshot covers
   it. Don't expose `weldCoincidentVertices` as its own undoable
   command unless we make a user-facing `mesh.merge_verts`
   wrapper (which Tier 1.2 will).
